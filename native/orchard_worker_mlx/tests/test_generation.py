"""Unit tests for generation.py: real MLX generation logic with fake deps."""

from __future__ import annotations

import threading
from collections import deque
from dataclasses import dataclass
from typing import Any
from unittest.mock import MagicMock

import pytest

from orchard_worker_mlx.backends import BackendError
from orchard_worker_mlx.generation import (
    GenerationDeps,
    StopSequenceBuffer,
    _make_prefill_progress_callback,
    generate_events,
)


# ---------------------------------------------------------------------------
# Fake GenerationResponse (mirrors mlx_lm.generate.GenerationResponse)
# ---------------------------------------------------------------------------


@dataclass
class FakeGenerationResponse:
    """Minimal stand-in for mlx_lm.generate.GenerationResponse."""

    text: str
    token: int
    finish_reason: str | None = None


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_fake_session(
    *,
    eos_token_ids: tuple[int, ...] = (),
    decode_cancel_stride: int = 1,
    prefill_step_size: int = 2048,
    clear_cache: Any = None,
) -> Any:
    """Create a minimal fake LoadedModelSession for generation tests."""
    session = MagicMock()
    session.model = MagicMock(name="FakeModel")
    session.tokenizer = MagicMock(name="FakeTokenizer")
    session.tokenizer.encode.return_value = [1, 2, 3]
    session.eos_token_ids = eos_token_ids
    session.decode_cancel_stride = decode_cancel_stride
    session.prefill_step_size = prefill_step_size
    session.clear_cache = clear_cache if clear_cache is not None else MagicMock(name="clear_cache")
    return session


def _make_fake_request(
    *,
    prompt: bytes | str = b"hello world",
    input_tokens: int = 3,
    max_output_tokens: int = 16,
    temperature: float = 0.0,
    top_p: float = 0.0,
    stop_sequences: list[str] | None = None,
) -> Any:
    """Create a minimal fake ExecuteInferenceRequest."""
    request = MagicMock()
    request.rendered_prompt_utf8 = prompt
    request.input_tokens = input_tokens
    params = MagicMock()
    params.max_output_tokens = max_output_tokens
    params.temperature = temperature
    params.top_p = top_p
    params.stop_sequences = stop_sequences or []
    request.params = params
    return request


def _make_deps(responses: list[FakeGenerationResponse]) -> GenerationDeps:
    """Create GenerationDeps that yields the given responses."""

    def fake_stream_generate(model, tokenizer, prompt_ids, **kwargs):
        yield from responses

    def fake_make_sampler(**kwargs):
        return MagicMock(name="FakeSampler")

    return GenerationDeps(
        stream_generate=fake_stream_generate,
        make_sampler=fake_make_sampler,
    )


def _collect_events(
    session: Any,
    request: Any,
    deps: GenerationDeps,
    cancel_event: threading.Event | None = None,
) -> list[dict[str, Any]]:
    """Collect all events from generate_events."""
    if cancel_event is None:
        cancel_event = threading.Event()
    return list(generate_events(session, request, cancel_event, deps=deps))


# ===========================================================================
# Happy path: normal generation
# ===========================================================================


def test_basic_generation_emits_deltas_and_completed() -> None:
    """Standard generation emits output_text_delta events + terminal completed."""
    responses = [
        FakeGenerationResponse(text="Hello", token=10),
        FakeGenerationResponse(text=" world", token=11),
        FakeGenerationResponse(text="", token=12, finish_reason="stop"),
    ]
    session = _make_fake_session()
    request = _make_fake_request(input_tokens=5)
    deps = _make_deps(responses)

    events = _collect_events(session, request, deps)

    deltas = [e for e in events if e["kind"] == "output_text_delta"]
    assert len(deltas) == 2
    assert deltas[0]["delta"] == "Hello"
    assert deltas[1]["delta"] == " world"

    completed = events[-1]
    assert completed["kind"] == "completed"
    assert completed["finish_reason"] == "FINISH_REASON_STOP"
    assert completed["usage"]["input_tokens"] == 5
    assert completed["usage"]["output_tokens"] == 3  # all 3 responses counted (incl. empty-text terminal)
    assert completed["usage"]["total_tokens"] == 8


def test_input_tokens_from_request_not_retokenized() -> None:
    """input_tokens in usage comes from the request, not re-counted."""
    responses = [
        FakeGenerationResponse(text="ok", token=10, finish_reason="stop"),
    ]
    session = _make_fake_session()
    request = _make_fake_request(input_tokens=42)
    deps = _make_deps(responses)

    events = _collect_events(session, request, deps)
    completed = events[-1]
    assert completed["usage"]["input_tokens"] == 42
    assert completed["usage"]["output_tokens"] == 1
    assert completed["usage"]["total_tokens"] == 43


def test_empty_text_chunks_not_emitted() -> None:
    """Empty text segments are suppressed for deltas but still counted in usage."""
    responses = [
        FakeGenerationResponse(text="", token=10),  # empty prefill segment
        FakeGenerationResponse(text="Hi", token=11),
        FakeGenerationResponse(text="", token=12, finish_reason="stop"),
    ]
    session = _make_fake_session()
    request = _make_fake_request(input_tokens=5)
    deps = _make_deps(responses)

    events = _collect_events(session, request, deps)
    deltas = [e for e in events if e["kind"] == "output_text_delta"]
    assert len(deltas) == 1
    assert deltas[0]["delta"] == "Hi"

    # All 3 responses count toward usage, even empty-text ones.
    completed = events[-1]
    assert completed["usage"]["output_tokens"] == 3
    assert completed["usage"]["total_tokens"] == 8


# ===========================================================================
# Finish reasons
# ===========================================================================


def test_finish_reason_stop() -> None:
    """EOS termination maps to FINISH_REASON_STOP."""
    responses = [
        FakeGenerationResponse(text="done", token=10, finish_reason="stop"),
    ]
    events = _collect_events(
        _make_fake_session(), _make_fake_request(), _make_deps(responses)
    )
    assert events[-1]["finish_reason"] == "FINISH_REASON_STOP"


def test_finish_reason_length() -> None:
    """Max tokens termination maps to FINISH_REASON_LENGTH."""
    responses = [
        FakeGenerationResponse(text="cut", token=10, finish_reason="length"),
    ]
    events = _collect_events(
        _make_fake_session(), _make_fake_request(), _make_deps(responses)
    )
    assert events[-1]["finish_reason"] == "FINISH_REASON_LENGTH"


def test_max_output_tokens_zero_emits_immediate_length() -> None:
    """max_output_tokens <= 0 emits immediate completed with FINISH_REASON_LENGTH."""
    session = _make_fake_session()
    request = _make_fake_request(input_tokens=10, max_output_tokens=0)
    deps = _make_deps([])  # stream_generate never called

    events = _collect_events(session, request, deps)
    assert len(events) == 1
    assert events[0]["kind"] == "completed"
    assert events[0]["finish_reason"] == "FINISH_REASON_LENGTH"
    assert events[0]["usage"]["output_tokens"] == 0
    assert events[0]["usage"]["input_tokens"] == 10


# ===========================================================================
# Invalid prompt UTF-8
# ===========================================================================


def test_invalid_utf8_prompt_raises_backend_error() -> None:
    """Invalid UTF-8 in rendered_prompt_utf8 raises BackendError."""
    session = _make_fake_session()
    request = _make_fake_request(prompt=b"\xff\xfe")
    deps = _make_deps([])

    with pytest.raises(BackendError) as exc_info:
        _collect_events(session, request, deps)
    assert exc_info.value.code == "invalid_prompt_utf8"


def test_none_prompt_raises_backend_error() -> None:
    """Missing prompt raises BackendError."""
    session = _make_fake_session()
    request = _make_fake_request()
    request.rendered_prompt_utf8 = None
    deps = _make_deps([])

    with pytest.raises(BackendError) as exc_info:
        _collect_events(session, request, deps)
    assert exc_info.value.code == "invalid_prompt_utf8"


def test_string_prompt_accepted() -> None:
    """String prompt (not bytes) is accepted."""
    responses = [
        FakeGenerationResponse(text="ok", token=10, finish_reason="stop"),
    ]
    session = _make_fake_session()
    request = _make_fake_request(prompt="hello string")
    deps = _make_deps(responses)

    events = _collect_events(session, request, deps)
    assert events[-1]["kind"] == "completed"


# ===========================================================================
# Cancellation
# ===========================================================================


def test_cancel_before_generate() -> None:
    """Pre-set cancel event yields immediate cancelled failure."""
    session = _make_fake_session()
    request = _make_fake_request()
    deps = _make_deps([])  # Never called

    cancel = threading.Event()
    cancel.set()

    events = _collect_events(session, request, deps, cancel_event=cancel)
    assert len(events) == 1
    assert events[0]["kind"] == "failed"
    assert events[0]["code"] == "cancelled"


def test_cancel_mid_generation() -> None:
    """Cancel during decode yields cancelled failure after partial output."""
    cancel = threading.Event()

    def cancelling_stream(model, tokenizer, prompt_ids, **kwargs):
        yield FakeGenerationResponse(text="first", token=10)
        cancel.set()  # Cancel after first token
        yield FakeGenerationResponse(text="second", token=11)

    deps = GenerationDeps(
        stream_generate=cancelling_stream,
        make_sampler=lambda **kw: MagicMock(),
    )
    session = _make_fake_session()
    request = _make_fake_request()

    events = _collect_events(session, request, deps, cancel_event=cancel)

    # First delta emitted, then cancelled on the next iteration
    deltas = [e for e in events if e["kind"] == "output_text_delta"]
    assert len(deltas) == 1
    assert deltas[0]["delta"] == "first"

    terminal = events[-1]
    assert terminal["kind"] == "failed"
    assert terminal["code"] == "cancelled"


# ===========================================================================
# Tokenizer encoding
# ===========================================================================


def test_encode_uses_add_special_tokens_false() -> None:
    """Tokenizer.encode is called with add_special_tokens=False."""
    session = _make_fake_session()
    request = _make_fake_request(prompt=b"test prompt")

    # Make stream_generate return something immediately
    responses = [
        FakeGenerationResponse(text="ok", token=10, finish_reason="stop"),
    ]
    deps = _make_deps(responses)
    _collect_events(session, request, deps)

    session.tokenizer.encode.assert_called_once_with(
        "test prompt", add_special_tokens=False
    )


def test_tokenizer_encode_failure_raises_backend_error() -> None:
    """Tokenizer encode failure raises BackendError."""
    session = _make_fake_session()
    session.tokenizer.encode.side_effect = RuntimeError("encode boom")
    request = _make_fake_request()
    deps = _make_deps([])

    with pytest.raises(BackendError) as exc_info:
        _collect_events(session, request, deps)
    assert exc_info.value.code == "generation_failed"
    assert "encode boom" in exc_info.value.message


# ===========================================================================
# Sampler construction
# ===========================================================================


def test_temperature_passed_to_sampler() -> None:
    """Temperature > 0 is passed as 'temp' to make_sampler."""
    captured_kwargs: list[dict] = []

    def capturing_make_sampler(**kwargs):
        captured_kwargs.append(kwargs)
        return MagicMock()

    responses = [
        FakeGenerationResponse(text="x", token=10, finish_reason="stop"),
    ]

    deps = GenerationDeps(
        stream_generate=lambda m, t, p, **kw: iter(responses),
        make_sampler=capturing_make_sampler,
    )
    session = _make_fake_session()
    request = _make_fake_request(temperature=0.8, top_p=0.95)
    _collect_events(session, request, deps)

    assert len(captured_kwargs) == 1
    assert captured_kwargs[0]["temp"] == 0.8
    assert captured_kwargs[0]["top_p"] == 0.95


def test_zero_temperature_omits_temp_kwarg() -> None:
    """Temperature == 0 omits 'temp' kwarg (greedy/argmax)."""
    captured_kwargs: list[dict] = []

    def capturing_make_sampler(**kwargs):
        captured_kwargs.append(kwargs)
        return MagicMock()

    responses = [
        FakeGenerationResponse(text="x", token=10, finish_reason="stop"),
    ]

    deps = GenerationDeps(
        stream_generate=lambda m, t, p, **kw: iter(responses),
        make_sampler=capturing_make_sampler,
    )
    session = _make_fake_session()
    request = _make_fake_request(temperature=0.0, top_p=0.0)
    _collect_events(session, request, deps)

    assert len(captured_kwargs) == 1
    assert "temp" not in captured_kwargs[0]
    assert "top_p" not in captured_kwargs[0]


# ===========================================================================
# stream_generate arguments
# ===========================================================================


def test_stream_generate_receives_correct_args() -> None:
    """stream_generate receives model, tokenizer, prompt_ids, max_tokens, and sampler."""
    captured_calls: list[dict] = []

    def capturing_stream(model, tokenizer, prompt_ids, **kwargs):
        captured_calls.append(
            {"model": model, "tokenizer": tokenizer, "prompt_ids": prompt_ids, **kwargs}
        )
        yield FakeGenerationResponse(text="ok", token=10, finish_reason="stop")

    deps = GenerationDeps(
        stream_generate=capturing_stream,
        make_sampler=lambda **kw: MagicMock(name="Sampler"),
    )
    session = _make_fake_session()
    session.tokenizer.encode.return_value = [100, 200, 300]
    request = _make_fake_request(max_output_tokens=32)
    _collect_events(session, request, deps)

    assert len(captured_calls) == 1
    call = captured_calls[0]
    assert call["model"] is session.model
    assert call["tokenizer"] is session.tokenizer
    assert call["prompt_ids"] == [100, 200, 300]
    assert call["max_tokens"] == 32
    assert "sampler" in call


# ===========================================================================
# Iterator exhaustion without finish_reason (defensive)
# ===========================================================================


def test_exhausted_iterator_emits_completed_stop() -> None:
    """If stream_generate ends without finish_reason, emit FINISH_REASON_STOP."""

    def bare_stream(model, tokenizer, prompt_ids, **kwargs):
        yield FakeGenerationResponse(text="hello", token=10)
        # No final response with finish_reason
        return

    deps = GenerationDeps(
        stream_generate=bare_stream,
        make_sampler=lambda **kw: MagicMock(),
    )
    session = _make_fake_session()
    request = _make_fake_request(input_tokens=3)
    events = _collect_events(session, request, deps)

    assert events[-1]["kind"] == "completed"
    assert events[-1]["finish_reason"] == "FINISH_REASON_STOP"
    assert events[-1]["usage"]["output_tokens"] == 1


# ===========================================================================
# Usage arithmetic validation
# ===========================================================================


def test_usage_total_equals_sum() -> None:
    """total_tokens always equals input_tokens + output_tokens."""
    responses = [
        FakeGenerationResponse(text="a", token=1),
        FakeGenerationResponse(text="b", token=2),
        FakeGenerationResponse(text="c", token=3),
        FakeGenerationResponse(text="", token=4, finish_reason="stop"),
    ]
    session = _make_fake_session()
    request = _make_fake_request(input_tokens=10)
    events = _collect_events(session, request, _make_deps(responses))

    completed = events[-1]
    usage = completed["usage"]
    assert usage["input_tokens"] == 10
    assert usage["output_tokens"] == 4  # all 4 responses counted (incl. empty-text terminal)
    assert usage["total_tokens"] == usage["input_tokens"] + usage["output_tokens"]


# ===========================================================================
# Final response with text in finish_reason response
# ===========================================================================


def test_final_response_text_is_emitted() -> None:
    """mlx_lm emits remaining text in the final response with finish_reason set."""
    responses = [
        FakeGenerationResponse(text="Hello", token=10),
        FakeGenerationResponse(text=" world!", token=11, finish_reason="stop"),
    ]
    session = _make_fake_session()
    request = _make_fake_request(input_tokens=2)
    events = _collect_events(session, request, _make_deps(responses))

    deltas = [e for e in events if e["kind"] == "output_text_delta"]
    assert len(deltas) == 2
    assert deltas[0]["delta"] == "Hello"
    assert deltas[1]["delta"] == " world!"

    completed = events[-1]
    assert completed["usage"]["output_tokens"] == 2


# ===========================================================================
# Buffered detokenization (regression: output_tokens must count all responses)
# ===========================================================================


def test_buffered_detokenization_counts_all_tokens() -> None:
    """Multiple empty-text responses (BPE buffering) are counted in usage.

    With byte-pair encoding, stream_generate may yield several responses
    with empty text before a non-empty flush.  Each response represents
    one generated token and must be counted in usage.output_tokens, even
    though only the non-empty flush emits a delta event.
    """
    responses = [
        FakeGenerationResponse(text="", token=1),      # buffered
        FakeGenerationResponse(text="", token=2),      # buffered
        FakeGenerationResponse(text="flush", token=3), # flush
        FakeGenerationResponse(text="", token=4, finish_reason="stop"),  # terminal, empty
    ]
    session = _make_fake_session()
    request = _make_fake_request(input_tokens=7)
    deps = _make_deps(responses)

    events = _collect_events(session, request, deps)

    # Only one delta emitted (the flush).
    deltas = [e for e in events if e["kind"] == "output_text_delta"]
    assert len(deltas) == 1
    assert deltas[0]["delta"] == "flush"

    # All 4 generated tokens counted in usage.
    completed = events[-1]
    assert completed["kind"] == "completed"
    assert completed["usage"]["output_tokens"] == 4
    assert completed["usage"]["total_tokens"] == 11  # 7 + 4


# ===========================================================================
# StopSequenceBuffer unit tests
# ===========================================================================


class TestStopSequenceBuffer:
    """Direct unit tests for StopSequenceBuffer in isolation."""

    def test_no_stop_sequences_passthrough(self) -> None:
        """With no stop sequences, push returns delta unchanged."""
        buf = StopSequenceBuffer(stop_sequences=(), max_stop_len=0)
        text, matched = buf.push("hello")
        assert text == "hello"
        assert matched is False
        assert buf.flush() == ""

    def test_stop_found_in_single_push(self) -> None:
        """Stop sequence found entirely within one push."""
        buf = StopSequenceBuffer(stop_sequences=("<stop>",), max_stop_len=6)
        text, matched = buf.push("hello<stop>world")
        assert text == "hello"
        assert matched is True

    def test_stop_split_across_pushes(self) -> None:
        """Stop sequence split across two pushes."""
        buf = StopSequenceBuffer(stop_sequences=("END",), max_stop_len=3)
        text1, m1 = buf.push("helloE")
        assert m1 is False
        # "helloE" -> safe prefix is "hello", retain "E" (max_stop_len-1=2)
        assert text1 == "hell"

        text2, m2 = buf.push("ND")
        assert m2 is True
        assert text2 == "o"  # text before match

    def test_flush_returns_remaining(self) -> None:
        """Flush returns withheld text."""
        buf = StopSequenceBuffer(stop_sequences=("END",), max_stop_len=3)
        buf.push("hi")
        flushed = buf.flush()
        assert flushed == "hi"
        assert buf.flush() == ""  # second flush is empty

    def test_earliest_stop_wins(self) -> None:
        """When multiple stops match, earliest position wins."""
        buf = StopSequenceBuffer(
            stop_sequences=("BB", "AA"),
            max_stop_len=2,
        )
        text, matched = buf.push("xxAAyyBB")
        assert matched is True
        assert text == "xx"  # AA at pos 2 is earliest

    def test_longest_on_tie(self) -> None:
        """When stops match at same position, longest wins."""
        buf = StopSequenceBuffer(
            stop_sequences=("<s>", "<stop>"),
            max_stop_len=6,
        )
        text, matched = buf.push("hello<stop>world")
        assert matched is True
        assert text == "hello"  # <stop> is longer and matches at same pos

    def test_unicode_stop_sequence(self) -> None:
        """Stop sequences work with multi-byte Unicode."""
        buf = StopSequenceBuffer(stop_sequences=("\u2603",), max_stop_len=1)  # snowman
        text, matched = buf.push("snow\u2603man")
        assert matched is True
        assert text == "snow"

    def test_partial_unicode_stop_across_chunks(self) -> None:
        """Multi-char Unicode stop sequence split across chunks."""
        buf = StopSequenceBuffer(stop_sequences=("\u2603\u2764",), max_stop_len=2)
        text1, m1 = buf.push("hello\u2603")
        assert m1 is False
        text2, m2 = buf.push("\u2764world")
        assert m2 is True
        assert (text1 + text2) == "hello"  # everything before the stop

    def test_empty_delta_push(self) -> None:
        """Pushing empty string doesn't break buffer."""
        buf = StopSequenceBuffer(stop_sequences=("END",), max_stop_len=3)
        text, matched = buf.push("")
        assert text == ""
        assert matched is False


# ===========================================================================
# Stop-sequence integration with generate_events
# ===========================================================================


def test_stop_sequence_suppressed_single_chunk() -> None:
    """Stop sequence in a single response delta is suppressed."""
    responses = [
        FakeGenerationResponse(text="Hello<stop>world", token=10),
        FakeGenerationResponse(text="after", token=11, finish_reason="stop"),
    ]
    session = _make_fake_session()
    request = _make_fake_request(stop_sequences=["<stop>"])
    deps = _make_deps(responses)

    events = _collect_events(session, request, deps)

    deltas = [e for e in events if e["kind"] == "output_text_delta"]
    assert len(deltas) == 1
    assert deltas[0]["delta"] == "Hello"

    completed = events[-1]
    assert completed["kind"] == "completed"
    assert completed["finish_reason"] == "FINISH_REASON_STOP"
    assert completed["usage"]["output_tokens"] == 1  # stopped at first response


def test_stop_sequence_split_across_chunks() -> None:
    """Stop sequence split across two response deltas is caught."""
    responses = [
        FakeGenerationResponse(text="helloEN", token=10),
        FakeGenerationResponse(text="Dworld", token=11),
        FakeGenerationResponse(text="never", token=12, finish_reason="stop"),
    ]
    session = _make_fake_session()
    request = _make_fake_request(stop_sequences=["END"])
    deps = _make_deps(responses)

    events = _collect_events(session, request, deps)

    # "hello" should be emitted, "END" suppressed, "world" never seen
    deltas = [e for e in events if e["kind"] == "output_text_delta"]
    all_text = "".join(d["delta"] for d in deltas)
    assert all_text == "hello"

    completed = events[-1]
    assert completed["kind"] == "completed"
    assert completed["finish_reason"] == "FINISH_REASON_STOP"


def test_stop_sequence_at_very_start() -> None:
    """Stop sequence at the very beginning of generated text."""
    responses = [
        FakeGenerationResponse(text="<stop>rest", token=10),
        FakeGenerationResponse(text="more", token=11, finish_reason="stop"),
    ]
    session = _make_fake_session()
    request = _make_fake_request(stop_sequences=["<stop>"])
    deps = _make_deps(responses)

    events = _collect_events(session, request, deps)

    deltas = [e for e in events if e["kind"] == "output_text_delta"]
    assert len(deltas) == 0  # no text before stop

    completed = events[-1]
    assert completed["kind"] == "completed"
    assert completed["finish_reason"] == "FINISH_REASON_STOP"


def test_no_stop_sequences_passes_through() -> None:
    """Without stop_sequences, behavior matches pre-Task4 (no buffering delay)."""
    responses = [
        FakeGenerationResponse(text="Hello", token=10),
        FakeGenerationResponse(text=" world", token=11),
        FakeGenerationResponse(text="", token=12, finish_reason="stop"),
    ]
    session = _make_fake_session()
    request = _make_fake_request()  # no stop_sequences
    deps = _make_deps(responses)

    events = _collect_events(session, request, deps)

    deltas = [e for e in events if e["kind"] == "output_text_delta"]
    assert len(deltas) == 2
    assert deltas[0]["delta"] == "Hello"
    assert deltas[1]["delta"] == " world"


def test_stop_sequence_buffer_flushed_on_length_termination() -> None:
    """Buffered text is flushed when mlx_lm terminates with length."""
    responses = [
        FakeGenerationResponse(text="he", token=10),
        FakeGenerationResponse(text="ll", token=11),
        FakeGenerationResponse(text="o", token=12, finish_reason="length"),
    ]
    session = _make_fake_session()
    request = _make_fake_request(stop_sequences=["END"])
    deps = _make_deps(responses)

    events = _collect_events(session, request, deps)

    deltas = [e for e in events if e["kind"] == "output_text_delta"]
    all_text = "".join(d["delta"] for d in deltas)
    assert all_text == "hello"  # all text flushed, no stop found

    completed = events[-1]
    assert completed["finish_reason"] == "FINISH_REASON_LENGTH"


def test_stop_sequence_buffer_flushed_on_cancel() -> None:
    """Buffered text is flushed on cancellation (not silently dropped)."""
    cancel = threading.Event()

    def cancelling_stream(model, tokenizer, prompt_ids, **kwargs):
        yield FakeGenerationResponse(text="buff", token=10)
        cancel.set()  # cancel after first token
        yield FakeGenerationResponse(text="er", token=11)

    deps = GenerationDeps(
        stream_generate=cancelling_stream,
        make_sampler=lambda **kw: MagicMock(),
    )
    session = _make_fake_session()
    request = _make_fake_request(stop_sequences=["END"])

    events = _collect_events(session, request, deps, cancel_event=cancel)

    # Buffered text should be flushed before cancel terminal.
    deltas = [e for e in events if e["kind"] == "output_text_delta"]
    all_text = "".join(d["delta"] for d in deltas)
    assert "buff" in all_text  # at minimum the first chunk is preserved

    terminal = events[-1]
    assert terminal["kind"] == "failed"
    assert terminal["code"] == "cancelled"


def test_multiple_stop_sequences_earliest_wins() -> None:
    """When multiple stop sequences could match, earliest position wins."""
    responses = [
        FakeGenerationResponse(text="xxAAyyBBzz", token=10, finish_reason="stop"),
    ]
    session = _make_fake_session()
    request = _make_fake_request(stop_sequences=["BB", "AA"])
    deps = _make_deps(responses)

    events = _collect_events(session, request, deps)

    deltas = [e for e in events if e["kind"] == "output_text_delta"]
    all_text = "".join(d["delta"] for d in deltas)
    assert all_text == "xx"  # AA at pos 2 is earliest

    assert events[-1]["finish_reason"] == "FINISH_REASON_STOP"


# ===========================================================================
# Orchard-level EOS detection
# ===========================================================================


def test_orchard_eos_terminates_without_upstream_finish() -> None:
    """Orchard EOS token triggers stop even when mlx_lm hasn't terminated."""
    responses = [
        FakeGenerationResponse(text="Hello", token=10),
        FakeGenerationResponse(text=" world", token=99),  # EOS token
        FakeGenerationResponse(text="after", token=12),   # should not be reached
        FakeGenerationResponse(text="", token=13, finish_reason="stop"),
    ]
    session = _make_fake_session(eos_token_ids=(99,))
    request = _make_fake_request()
    deps = _make_deps(responses)

    events = _collect_events(session, request, deps)

    deltas = [e for e in events if e["kind"] == "output_text_delta"]
    all_text = "".join(d["delta"] for d in deltas)
    assert all_text == "Hello world"

    completed = events[-1]
    assert completed["kind"] == "completed"
    assert completed["finish_reason"] == "FINISH_REASON_STOP"
    assert completed["usage"]["output_tokens"] == 2


def test_orchard_eos_overrides_upstream_length() -> None:
    """Orchard EOS in a response also marked 'length' produces STOP.

    When both Orchard EOS and upstream finish_reason are present on the
    same response, the EOS path runs first (since finish_reason is not None
    check happens separately).  But since upstream also terminates, the
    upstream terminal path fires.  Orchard EOS only fires when
    finish_reason is None.
    """
    # This tests the case where EOS token is seen on a non-terminal response
    # (finish_reason is None), overriding what would eventually be "length".
    responses = [
        FakeGenerationResponse(text="Hello", token=10),
        FakeGenerationResponse(text=" end", token=99),  # EOS, no finish_reason
    ]
    session = _make_fake_session(eos_token_ids=(99,))
    request = _make_fake_request()
    deps = _make_deps(responses)

    events = _collect_events(session, request, deps)

    completed = events[-1]
    assert completed["finish_reason"] == "FINISH_REASON_STOP"  # EOS wins


def test_orchard_eos_with_stop_buffer_flushes() -> None:
    """Orchard EOS flushes stop-sequence buffer before terminating."""
    responses = [
        FakeGenerationResponse(text="hel", token=10),
        FakeGenerationResponse(text="lo", token=99),  # EOS token
    ]
    session = _make_fake_session(eos_token_ids=(99,))
    request = _make_fake_request(stop_sequences=["END"])
    deps = _make_deps(responses)

    events = _collect_events(session, request, deps)

    deltas = [e for e in events if e["kind"] == "output_text_delta"]
    all_text = "".join(d["delta"] for d in deltas)
    assert all_text == "hello"  # entire text flushed

    assert events[-1]["finish_reason"] == "FINISH_REASON_STOP"


def test_empty_eos_token_ids_does_not_trigger() -> None:
    """Empty eos_token_ids disables Orchard-level EOS detection."""
    responses = [
        FakeGenerationResponse(text="Hello", token=99),
        FakeGenerationResponse(text="end", token=99, finish_reason="length"),
    ]
    session = _make_fake_session(eos_token_ids=())  # empty
    request = _make_fake_request()
    deps = _make_deps(responses)

    events = _collect_events(session, request, deps)

    completed = events[-1]
    assert completed["finish_reason"] == "FINISH_REASON_LENGTH"  # no EOS override


# ===========================================================================
# Strided cancel
# ===========================================================================


def test_strided_cancel_skips_intermediate_tokens() -> None:
    """With stride=3, cancel is only checked every 3rd token."""
    cancel = threading.Event()
    tokens_yielded = 0

    def counting_stream(model, tokenizer, prompt_ids, **kwargs):
        nonlocal tokens_yielded
        for i in range(10):
            tokens_yielded += 1
            yield FakeGenerationResponse(text=f"t{i}", token=i)
            if i == 0:
                cancel.set()  # cancel after first token

    deps = GenerationDeps(
        stream_generate=counting_stream,
        make_sampler=lambda **kw: MagicMock(),
    )
    session = _make_fake_session(decode_cancel_stride=3)
    request = _make_fake_request()

    events = _collect_events(session, request, deps, cancel_event=cancel)

    # Cancel set after token 0 (output_tokens=1).
    # Stride=3: next check at output_tokens=3 (token index 2).
    # Tokens 0, 1, 2 are generated; cancel fires when processing token 2.
    terminal = events[-1]
    assert terminal["kind"] == "failed"
    assert terminal["code"] == "cancelled"

    # Exactly 3 tokens should have been produced.
    deltas = [e for e in events if e["kind"] == "output_text_delta"]
    # With stride=3, cancel check fires at output_tokens=3 (after incrementing)
    # before processing the response text, so only tokens 0 and 1 emit deltas.
    assert len(deltas) == 2  # t0 and t1


def test_stride_1_cancels_every_token() -> None:
    """With stride=1 (default), cancel is checked every token."""
    cancel = threading.Event()

    def cancelling_stream(model, tokenizer, prompt_ids, **kwargs):
        yield FakeGenerationResponse(text="first", token=10)
        cancel.set()
        yield FakeGenerationResponse(text="second", token=11)

    deps = GenerationDeps(
        stream_generate=cancelling_stream,
        make_sampler=lambda **kw: MagicMock(),
    )
    session = _make_fake_session(decode_cancel_stride=1)
    request = _make_fake_request()

    events = _collect_events(session, request, deps, cancel_event=cancel)

    deltas = [e for e in events if e["kind"] == "output_text_delta"]
    assert len(deltas) == 1
    assert deltas[0]["delta"] == "first"

    assert events[-1]["kind"] == "failed"
    assert events[-1]["code"] == "cancelled"


def test_invalid_stride_falls_back_to_1() -> None:
    """Invalid decode_cancel_stride falls back to 1."""
    cancel = threading.Event()

    def cancelling_stream(model, tokenizer, prompt_ids, **kwargs):
        yield FakeGenerationResponse(text="first", token=10)
        cancel.set()
        yield FakeGenerationResponse(text="second", token=11)

    deps = GenerationDeps(
        stream_generate=cancelling_stream,
        make_sampler=lambda **kw: MagicMock(),
    )
    session = _make_fake_session()
    session.decode_cancel_stride = -5  # invalid
    request = _make_fake_request()

    events = _collect_events(session, request, deps, cancel_event=cancel)

    # Should behave as stride=1: cancel fires immediately after second yield.
    deltas = [e for e in events if e["kind"] == "output_text_delta"]
    assert len(deltas) == 1
    assert events[-1]["code"] == "cancelled"


def test_boolean_stride_falls_back_to_1() -> None:
    """Boolean decode_cancel_stride (True) falls back to 1."""
    cancel = threading.Event()

    def cancelling_stream(model, tokenizer, prompt_ids, **kwargs):
        yield FakeGenerationResponse(text="first", token=10)
        cancel.set()
        yield FakeGenerationResponse(text="second", token=11)

    deps = GenerationDeps(
        stream_generate=cancelling_stream,
        make_sampler=lambda **kw: MagicMock(),
    )
    session = _make_fake_session()
    session.decode_cancel_stride = True  # bool, should fall back to 1
    request = _make_fake_request()

    events = _collect_events(session, request, deps, cancel_event=cancel)

    deltas = [e for e in events if e["kind"] == "output_text_delta"]
    assert len(deltas) == 1
    assert events[-1]["code"] == "cancelled"


# ===========================================================================
# Terminal guarantees in generation layer
# ===========================================================================


def test_exactly_one_terminal_on_stop_sequence() -> None:
    """Stop-sequence match produces exactly one terminal event."""
    responses = [
        FakeGenerationResponse(text="Hello<stop>extra", token=10),
        FakeGenerationResponse(text="more", token=11, finish_reason="stop"),
    ]
    session = _make_fake_session()
    request = _make_fake_request(stop_sequences=["<stop>"])
    deps = _make_deps(responses)

    events = _collect_events(session, request, deps)

    terminals = [e for e in events if e["kind"] in ("completed", "failed")]
    assert len(terminals) == 1
    assert terminals[0]["kind"] == "completed"


def test_exactly_one_terminal_on_eos() -> None:
    """Orchard EOS produces exactly one terminal event."""
    responses = [
        FakeGenerationResponse(text="Hello", token=99),  # EOS
        FakeGenerationResponse(text="more", token=11, finish_reason="stop"),
    ]
    session = _make_fake_session(eos_token_ids=(99,))
    request = _make_fake_request()
    deps = _make_deps(responses)

    events = _collect_events(session, request, deps)

    terminals = [e for e in events if e["kind"] in ("completed", "failed")]
    assert len(terminals) == 1


def test_exactly_one_terminal_on_cancel() -> None:
    """Cancel produces exactly one terminal failed event."""
    cancel = threading.Event()
    cancel.set()

    responses = [
        FakeGenerationResponse(text="a", token=10),
        FakeGenerationResponse(text="b", token=11, finish_reason="stop"),
    ]
    session = _make_fake_session()
    request = _make_fake_request()
    deps = _make_deps(responses)

    events = _collect_events(session, request, deps, cancel_event=cancel)

    terminals = [e for e in events if e["kind"] in ("completed", "failed")]
    assert len(terminals) == 1
    assert terminals[0]["kind"] == "failed"
    assert terminals[0]["code"] == "cancelled"


def test_no_completed_after_cancel() -> None:
    """No completed event after a cancel terminal."""
    cancel = threading.Event()

    def cancelling_stream(model, tokenizer, prompt_ids, **kwargs):
        yield FakeGenerationResponse(text="a", token=10)
        cancel.set()
        yield FakeGenerationResponse(text="b", token=11)
        yield FakeGenerationResponse(text="c", token=12, finish_reason="stop")

    deps = GenerationDeps(
        stream_generate=cancelling_stream,
        make_sampler=lambda **kw: MagicMock(),
    )
    session = _make_fake_session()
    request = _make_fake_request()

    events = _collect_events(session, request, deps, cancel_event=cancel)

    kinds = [e["kind"] for e in events]
    # No completed should appear after failed
    assert "completed" not in kinds
    assert kinds[-1] == "failed"  # type is failed
    assert events[-1]["code"] == "cancelled"


def test_stop_sequence_with_buffered_text_and_iterator_exhaustion() -> None:
    """Buffered text flushed on iterator exhaustion (no finish_reason)."""
    def bare_stream(model, tokenizer, prompt_ids, **kwargs):
        yield FakeGenerationResponse(text="he", token=10)
        yield FakeGenerationResponse(text="llo", token=11)
        # No final response with finish_reason

    deps = GenerationDeps(
        stream_generate=bare_stream,
        make_sampler=lambda **kw: MagicMock(),
    )
    session = _make_fake_session()
    request = _make_fake_request(stop_sequences=["END"])

    events = _collect_events(session, request, deps)

    deltas = [e for e in events if e["kind"] == "output_text_delta"]
    all_text = "".join(d["delta"] for d in deltas)
    assert all_text == "hello"  # fully flushed

    completed = events[-1]
    assert completed["kind"] == "completed"
    assert completed["finish_reason"] == "FINISH_REASON_STOP"


def test_stop_sequence_never_leaked_end_to_end() -> None:
    """Stop sequence text never appears in any emitted delta."""
    stop = "<|endoftext|>"
    responses = [
        FakeGenerationResponse(text="Hello world", token=10),
        FakeGenerationResponse(text="! The answer is 42.", token=11),
        FakeGenerationResponse(text=f" And{stop}done", token=12),
        FakeGenerationResponse(text="extra", token=13, finish_reason="stop"),
    ]
    session = _make_fake_session()
    request = _make_fake_request(stop_sequences=[stop])
    deps = _make_deps(responses)

    events = _collect_events(session, request, deps)

    all_text = "".join(
        e["delta"] for e in events if e["kind"] == "output_text_delta"
    )
    assert stop not in all_text
    assert "done" not in all_text  # text after stop also suppressed
    assert all_text == "Hello world! The answer is 42. And"


# ===========================================================================
# Prefill progress callback bridge (Task 5)
# ===========================================================================


def test_prefill_progress_emitted_before_first_delta() -> None:
    """Progress events from callback appear before first output_text_delta."""
    progress_calls: list[tuple[int, int]] = []

    def stream_with_callback(model, tokenizer, prompt_ids, **kwargs):
        # The callback is invoked synchronously during prefill.
        cb = kwargs.get("prompt_progress_callback")
        if cb:
            cb(0, 100)    # initial zero — should be filtered
            cb(50, 100)   # real progress
            cb(100, 100)  # done
            progress_calls.extend([(50, 100), (100, 100)])
        # Then yield decode tokens.
        yield FakeGenerationResponse(text="Hello", token=10)
        yield FakeGenerationResponse(text=" world", token=11, finish_reason="stop")

    deps = GenerationDeps(
        stream_generate=stream_with_callback,
        make_sampler=lambda **kw: MagicMock(),
    )
    session = _make_fake_session()
    request = _make_fake_request()

    events = _collect_events(session, request, deps)

    kinds = [e["kind"] for e in events]
    # Progress events come first, then deltas, then terminal.
    progress_events = [e for e in events if e["kind"] == "progress"]
    assert len(progress_events) == 2
    assert progress_events[0]["stage"] == "prefill"
    assert "50/100" in progress_events[0]["message"]
    assert "100/100" in progress_events[1]["message"]

    # Verify ordering: all progress before first delta.
    first_delta_idx = kinds.index("output_text_delta")
    for i, k in enumerate(kinds):
        if k == "progress":
            assert i < first_delta_idx


def test_prefill_progress_multiple_chunks() -> None:
    """Multiple callback updates emit multiple progress events in order."""

    def stream_with_multi_chunk(model, tokenizer, prompt_ids, **kwargs):
        cb = kwargs.get("prompt_progress_callback")
        if cb:
            cb(2048, 8192)
            cb(4096, 8192)
            cb(6144, 8192)
            cb(8192, 8192)
        yield FakeGenerationResponse(text="ok", token=10, finish_reason="stop")

    deps = GenerationDeps(
        stream_generate=stream_with_multi_chunk,
        make_sampler=lambda **kw: MagicMock(),
    )
    session = _make_fake_session()
    request = _make_fake_request()

    events = _collect_events(session, request, deps)

    progress_events = [e for e in events if e["kind"] == "progress"]
    assert len(progress_events) == 4
    assert "2048/8192" in progress_events[0]["message"]
    assert "8192/8192" in progress_events[3]["message"]


def test_prefill_progress_no_callback_no_progress_events() -> None:
    """When no callback is invoked, no progress events are emitted."""
    responses = [
        FakeGenerationResponse(text="Hi", token=10, finish_reason="stop"),
    ]
    session = _make_fake_session()
    request = _make_fake_request()
    deps = _make_deps(responses)

    events = _collect_events(session, request, deps)

    progress_events = [e for e in events if e["kind"] == "progress"]
    assert len(progress_events) == 0


def test_prefill_progress_no_events_after_terminal() -> None:
    """No progress events appear after any terminal event."""

    def stream_with_progress(model, tokenizer, prompt_ids, **kwargs):
        cb = kwargs.get("prompt_progress_callback")
        if cb:
            cb(100, 100)
        yield FakeGenerationResponse(text="done", token=10, finish_reason="stop")

    deps = GenerationDeps(
        stream_generate=stream_with_progress,
        make_sampler=lambda **kw: MagicMock(),
    )
    session = _make_fake_session()
    request = _make_fake_request()

    events = _collect_events(session, request, deps)

    # Find terminal event.
    terminal_idx = None
    for i, e in enumerate(events):
        if e["kind"] in ("completed", "failed"):
            terminal_idx = i
            break
    assert terminal_idx is not None
    # No progress after terminal.
    for e in events[terminal_idx + 1:]:
        assert e["kind"] != "progress"


def test_prefill_progress_passes_prefill_step_size() -> None:
    """stream_generate receives prefill_step_size from session."""
    captured_kwargs: list[dict[str, Any]] = []

    def capturing_stream(model, tokenizer, prompt_ids, **kwargs):
        captured_kwargs.append(kwargs)
        yield FakeGenerationResponse(text="x", token=10, finish_reason="stop")

    deps = GenerationDeps(
        stream_generate=capturing_stream,
        make_sampler=lambda **kw: MagicMock(),
    )
    session = _make_fake_session(prefill_step_size=4096)
    request = _make_fake_request()

    _collect_events(session, request, deps)

    assert len(captured_kwargs) == 1
    assert captured_kwargs[0]["prefill_step_size"] == 4096
    assert "prompt_progress_callback" in captured_kwargs[0]
    assert callable(captured_kwargs[0]["prompt_progress_callback"])


def test_prefill_progress_default_step_size() -> None:
    """Default prefill_step_size is 2048 when session has no attribute."""
    captured_kwargs: list[dict[str, Any]] = []

    def capturing_stream(model, tokenizer, prompt_ids, **kwargs):
        captured_kwargs.append(kwargs)
        yield FakeGenerationResponse(text="x", token=10, finish_reason="stop")

    deps = GenerationDeps(
        stream_generate=capturing_stream,
        make_sampler=lambda **kw: MagicMock(),
    )
    # Session without prefill_step_size attribute.
    session = MagicMock()
    session.model = MagicMock()
    session.tokenizer = MagicMock()
    session.tokenizer.encode.return_value = [1, 2, 3]
    session.eos_token_ids = ()
    session.decode_cancel_stride = 1
    session.clear_cache = MagicMock()
    del session.prefill_step_size  # remove auto-created attr

    request = _make_fake_request()
    _collect_events(session, request, deps)

    assert captured_kwargs[0]["prefill_step_size"] == 2048


# ===========================================================================
# Prefill progress callback sanitization (unit tests)
# ===========================================================================


def test_callback_rejects_zero_processed() -> None:
    q: deque[tuple[int, int]] = deque()
    cb = _make_prefill_progress_callback(q)
    cb(0, 100)
    assert len(q) == 0


def test_callback_rejects_negative_total() -> None:
    q: deque[tuple[int, int]] = deque()
    cb = _make_prefill_progress_callback(q)
    cb(5, -1)
    assert len(q) == 0


def test_callback_rejects_boolean_values() -> None:
    q: deque[tuple[int, int]] = deque()
    cb = _make_prefill_progress_callback(q)
    cb(True, 100)  # type: ignore[arg-type]
    cb(50, False)  # type: ignore[arg-type]
    assert len(q) == 0


def test_callback_clamps_processed_to_total() -> None:
    q: deque[tuple[int, int]] = deque()
    cb = _make_prefill_progress_callback(q)
    cb(200, 100)  # processed > total
    assert len(q) == 1
    assert q[0] == (100, 100)  # clamped


def test_callback_drops_non_monotonic_updates() -> None:
    q: deque[tuple[int, int]] = deque()
    cb = _make_prefill_progress_callback(q)
    cb(50, 100)
    cb(30, 100)  # backwards — dropped
    cb(50, 100)  # same as last — dropped
    assert len(q) == 1


def test_callback_drops_decreasing_total() -> None:
    q: deque[tuple[int, int]] = deque()
    cb = _make_prefill_progress_callback(q)
    cb(50, 100)
    cb(40, 80)  # total decreased — dropped
    assert len(q) == 1


def test_callback_accepts_increasing_total() -> None:
    """Total can increase (model reestimates total tokens)."""
    q: deque[tuple[int, int]] = deque()
    cb = _make_prefill_progress_callback(q)
    cb(50, 100)
    cb(60, 200)  # total increased, processed also advanced
    assert len(q) == 2


# ===========================================================================
# Post-generation memory cleanup (Task 5)
# ===========================================================================


def test_clear_cache_called_on_completed() -> None:
    """session.clear_cache called on normal completion."""
    clear_mock = MagicMock(name="clear_cache")
    responses = [
        FakeGenerationResponse(text="Hi", token=10, finish_reason="stop"),
    ]
    session = _make_fake_session(clear_cache=clear_mock)
    request = _make_fake_request()
    deps = _make_deps(responses)

    _collect_events(session, request, deps)
    clear_mock.assert_called()


def test_clear_cache_called_on_cancel() -> None:
    """session.clear_cache called on cancellation during decode."""
    clear_mock = MagicMock(name="clear_cache")
    cancel = threading.Event()

    def stream_then_cancel(model, tokenizer, prompt_ids, **kwargs):
        yield FakeGenerationResponse(text="a", token=10)
        # Set cancel after first token so pre-cancel check passes.
        cancel.set()
        yield FakeGenerationResponse(text="b", token=11)

    deps = GenerationDeps(
        stream_generate=stream_then_cancel,
        make_sampler=lambda **kw: MagicMock(),
    )
    session = _make_fake_session(decode_cancel_stride=1, clear_cache=clear_mock)
    request = _make_fake_request()

    events = _collect_events(session, request, deps, cancel_event=cancel)

    assert events[-1]["kind"] == "failed"
    assert events[-1]["code"] == "cancelled"
    clear_mock.assert_called()


def test_clear_cache_called_on_stop_sequence() -> None:
    """session.clear_cache called when stop sequence terminates generation."""
    clear_mock = MagicMock(name="clear_cache")
    responses = [
        FakeGenerationResponse(text="Hello STOP world", token=10),
    ]
    session = _make_fake_session(clear_cache=clear_mock)
    request = _make_fake_request(stop_sequences=["STOP"])
    deps = _make_deps(responses)

    _collect_events(session, request, deps)
    clear_mock.assert_called()


def test_clear_cache_called_on_eos() -> None:
    """session.clear_cache called on Orchard EOS detection."""
    clear_mock = MagicMock(name="clear_cache")
    responses = [
        FakeGenerationResponse(text="end", token=999),
    ]
    session = _make_fake_session(eos_token_ids=(999,), clear_cache=clear_mock)
    request = _make_fake_request()
    deps = _make_deps(responses)

    _collect_events(session, request, deps)
    clear_mock.assert_called()


def test_clear_cache_called_on_iterator_exhaustion() -> None:
    """session.clear_cache called when iterator exhausts without finish_reason."""
    clear_mock = MagicMock(name="clear_cache")

    def bare_stream(model, tokenizer, prompt_ids, **kwargs):
        yield FakeGenerationResponse(text="partial", token=10)
        # No finish_reason on final response.

    deps = GenerationDeps(
        stream_generate=bare_stream,
        make_sampler=lambda **kw: MagicMock(),
    )
    session = _make_fake_session(clear_cache=clear_mock)
    request = _make_fake_request()

    _collect_events(session, request, deps)
    clear_mock.assert_called()


def test_clear_cache_failure_does_not_block_terminal() -> None:
    """clear_cache exception does not prevent terminal event emission."""
    clear_mock = MagicMock(side_effect=RuntimeError("cache boom"))
    responses = [
        FakeGenerationResponse(text="Hi", token=10, finish_reason="stop"),
    ]
    session = _make_fake_session(clear_cache=clear_mock)
    request = _make_fake_request()
    deps = _make_deps(responses)

    events = _collect_events(session, request, deps)

    # Terminal event should still appear despite cache cleanup failure.
    assert events[-1]["kind"] == "completed"


def test_clear_cache_called_on_mid_iteration_exception() -> None:
    """session.clear_cache called when stream iterator raises mid-iteration.

    Regression test for review finding MF1: if stream_generate()'s iterator
    raises (e.g., MLX Metal error, OOM), the exception propagates to
    service.py which synthesizes a terminal failed event.  The try/finally
    in generate_events() guarantees cache cleanup on this path.
    """
    clear_mock = MagicMock(name="clear_cache")

    def stream_then_explode(model, tokenizer, prompt_ids, **kwargs):
        yield FakeGenerationResponse(text="partial", token=10)
        raise RuntimeError("MLX Metal error")

    deps = GenerationDeps(
        stream_generate=stream_then_explode,
        make_sampler=lambda **kw: MagicMock(),
    )
    session = _make_fake_session(clear_cache=clear_mock)
    request = _make_fake_request()

    # Use staged iteration to prove the exception happens after a successful yield.
    it = generate_events(session, request, threading.Event(), deps=deps)

    # First event should be the output_text_delta from the successful yield.
    first = next(it)
    assert first["kind"] == "output_text_delta"
    assert first["delta"] == "partial"

    # Consuming the rest should raise the RuntimeError from the stream.
    with pytest.raises(RuntimeError, match="MLX Metal error"):
        list(it)

    # Despite the exception, cache cleanup must have run via finally.
    clear_mock.assert_called_once()
