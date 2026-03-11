"""Unit tests for generation.py: real MLX generation logic with fake deps."""

from __future__ import annotations

import threading
from dataclasses import dataclass
from typing import Any
from unittest.mock import MagicMock

import pytest

from orchard_worker_mlx.backends import BackendError
from orchard_worker_mlx.generation import GenerationDeps, generate_events


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
) -> Any:
    """Create a minimal fake LoadedModelSession for generation tests."""
    session = MagicMock()
    session.model = MagicMock(name="FakeModel")
    session.tokenizer = MagicMock(name="FakeTokenizer")
    session.tokenizer.encode.return_value = [1, 2, 3]
    session.eos_token_ids = eos_token_ids
    return session


def _make_fake_request(
    *,
    prompt: bytes | str = b"hello world",
    input_tokens: int = 3,
    max_output_tokens: int = 16,
    temperature: float = 0.0,
    top_p: float = 0.0,
) -> Any:
    """Create a minimal fake ExecuteInferenceRequest."""
    request = MagicMock()
    request.rendered_prompt_utf8 = prompt
    request.input_tokens = input_tokens
    params = MagicMock()
    params.max_output_tokens = max_output_tokens
    params.temperature = temperature
    params.top_p = top_p
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
    assert completed["usage"]["output_tokens"] == 2
    assert completed["usage"]["total_tokens"] == 7


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
    """Empty text segments from stream_generate are suppressed."""
    responses = [
        FakeGenerationResponse(text="", token=10),  # empty prefill segment
        FakeGenerationResponse(text="Hi", token=11),
        FakeGenerationResponse(text="", token=12, finish_reason="stop"),
    ]
    session = _make_fake_session()
    request = _make_fake_request()
    deps = _make_deps(responses)

    events = _collect_events(session, request, deps)
    deltas = [e for e in events if e["kind"] == "output_text_delta"]
    assert len(deltas) == 1
    assert deltas[0]["delta"] == "Hi"


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
    assert usage["output_tokens"] == 3
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
