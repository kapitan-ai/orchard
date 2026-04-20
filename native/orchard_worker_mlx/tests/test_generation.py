"""Unit tests for generation.py: real MLX generation logic with fake deps."""

from __future__ import annotations

import logging
import threading
import time
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any, cast
from unittest.mock import MagicMock

import pytest

from orchard_worker_mlx.backends import BackendError
from orchard_worker_mlx.generation import (
    BatchGenerationDeps,
    BatchGeneratorRuntime,
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
    prefix_cache: Any = None,
    tool_calling: dict[str, Any] | None = None,
    tool_parser: Any = None,
    tool_call_start: str | None = None,
    tool_call_end: str | None = None,
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
    session.prefix_cache = prefix_cache
    session.tool_calling = tool_calling or {"supported": False, "parser_type": None}
    session.tokenizer.tool_parser = tool_parser
    session.tokenizer.tool_call_start = tool_call_start
    session.tokenizer.tool_call_end = tool_call_end
    return session


def _make_fake_request(
    *,
    prompt: bytes | str = b"hello world",
    input_tokens: int = 3,
    max_output_tokens: int = 16,
    temperature: float = 0.0,
    top_p: float = 0.0,
    stop_sequences: list[str] | None = None,
    tools_json: bytes | str = b"",
    tool_choice_json: bytes | str = b"",
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
    params.tools_json = tools_json
    params.tool_choice_json = tool_choice_json
    request.params = params
    return request


def _make_deps(
    responses: list[FakeGenerationResponse],
    *,
    make_prompt_cache: Any = None,
    trim_prompt_cache: Any = None,
) -> GenerationDeps:
    """Create GenerationDeps that yields the given responses."""

    def fake_stream_generate(model, tokenizer, prompt_ids, **kwargs):
        yield from responses

    def fake_make_sampler(**kwargs):
        return MagicMock(name="FakeSampler")

    return GenerationDeps(
        stream_generate=fake_stream_generate,
        make_sampler=fake_make_sampler,
        make_prompt_cache=make_prompt_cache,
        trim_prompt_cache=trim_prompt_cache,
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


class _ToyDetokenizer:
    def __init__(self, tokenizer: _ToyTokenizer) -> None:
        self._tokenizer = tokenizer
        self.reset()

    def reset(self) -> None:
        self.offset = 0
        self.text = ""
        self.tokens: list[int] = []

    def add_token(self, token: int) -> None:
        self.tokens.append(token)
        self.text += self._tokenizer.decode([token])

    def finalize(self) -> None:
        return None

    @property
    def last_segment(self) -> str:
        segment = self.text[self.offset :]
        self.offset = len(self.text)
        return segment


class _ToyTokenizer:
    def __init__(self) -> None:
        self._map = {11: "A", 12: "B", 21: "X", 22: "Y"}

    def encode(self, _prompt: str, add_special_tokens: bool = False) -> list[int]:
        assert add_special_tokens is False
        return [1, 2, 3]

    def decode(self, token_ids: list[int]) -> str:
        return "".join(self._map.get(token_id, "?") for token_id in token_ids)

    @property
    def detokenizer(self) -> _ToyDetokenizer:
        return _ToyDetokenizer(self)


class _SharedDetokenizerTokenizer(_ToyTokenizer):
    def __init__(self) -> None:
        super().__init__()
        self._shared = _ToyDetokenizer(self)

    @property
    def detokenizer(self) -> _ToyDetokenizer:
        return self._shared


class _ExplodingResetDetokenizer:
    def __init__(self, tokenizer: _ToyTokenizer) -> None:
        self._tokenizer = tokenizer
        self.offset = 0
        self.text = ""

    def reset(self) -> None:
        raise RuntimeError("detokenizer reset boom")

    def add_token(self, token: int) -> None:
        self.text += self._tokenizer.decode([token])

    def finalize(self) -> None:
        return None

    @property
    def last_segment(self) -> str:
        segment = self.text[self.offset :]
        self.offset = len(self.text)
        return segment


class _ExplodingResetTokenizer(_ToyTokenizer):
    def make_detokenizer(self) -> _ExplodingResetDetokenizer:
        return _ExplodingResetDetokenizer(self)


class _FakeBatchGenerator:
    def __init__(self, _model: Any, **kwargs: Any) -> None:
        self._prompt_progress_callback = kwargs.get("prompt_progress_callback")
        self._next_uid = 0
        self._active: list[dict[str, Any]] = []

    def insert(
        self,
        prompts: list[list[int]],
        max_tokens: list[int],
        caches: list[Any] | None = None,
        samplers: list[Any] | None = None,
        logits_processors: list[Any] | None = None,
    ) -> list[int]:
        del prompts, samplers, logits_processors
        caches = caches or [None] * len(max_tokens)
        uids: list[int] = []
        for i, limit in enumerate(max_tokens):
            uid = self._next_uid
            self._next_uid += 1
            base_tokens = [11, 12] if uid % 2 == 0 else [21, 22]
            tokens = base_tokens[: max(1, min(limit, len(base_tokens)))]
            self._active.append(
                {
                    "uid": uid,
                    "tokens": tokens,
                    "index": 0,
                    "cache": caches[i],
                    "progress_emitted": False,
                }
            )
            uids.append(uid)
        return uids

    def next(self) -> list[Any]:
        responses: list[Any] = []
        survivors: list[dict[str, Any]] = []

        for item in self._active:
            uid = item["uid"]
            tokens: list[int] = item["tokens"]
            index = item["index"]

            if not item["progress_emitted"] and callable(self._prompt_progress_callback):
                self._prompt_progress_callback([(uid, 1, 3)])
                item["progress_emitted"] = True

            token = tokens[index]
            index += 1
            finish_reason = "stop" if index >= len(tokens) else None
            item["index"] = index

            cache_snapshot = [f"cache-{uid}"]
            responses.append(
                type(
                    "BatchResp",
                    (),
                    {
                        "uid": uid,
                        "token": token,
                        "finish_reason": finish_reason,
                        "prompt_cache": (lambda snap=cache_snapshot: snap),
                    },
                )()
            )

            if finish_reason is None:
                survivors.append(item)

        self._active = survivors
        return responses

    def close(self) -> None:
        return None


def test_batch_generator_runtime_streams_through_generate_events() -> None:
    session = _make_fake_session()
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_FakeBatchGenerator),
    )

    request = _make_fake_request(input_tokens=3, max_output_tokens=2)

    try:
        events = _collect_events(session, request, runtime.generation_deps())
    finally:
        runtime.close()

    deltas = [event["delta"] for event in events if event["kind"] == "output_text_delta"]
    assert deltas == ["A", "B"]
    assert events[-1]["kind"] == "completed"
    assert events[-1]["finish_reason"] == "FINISH_REASON_STOP"


def test_batch_generator_runtime_rejects_shared_detokenizer_instances() -> None:
    session = _make_fake_session()
    session.tokenizer = _SharedDetokenizerTokenizer()

    with pytest.raises(BackendError) as exc_info:
        BatchGeneratorRuntime(
            session,
            generation_deps=GenerationDeps(
                stream_generate=lambda *_args, **_kwargs: iter([]),
                make_sampler=lambda **_kw: MagicMock(),
            ),
            batch_deps=BatchGenerationDeps(batch_generator_cls=_FakeBatchGenerator),
        )

    assert exc_info.value.code == "batch_runtime_unavailable"
    assert "shared detokenizer" in exc_info.value.message


def test_batch_generator_runtime_rolls_back_submit_state_on_stream_init_failure() -> None:
    session = _make_fake_session()
    session.tokenizer = _ExplodingResetTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_FakeBatchGenerator),
    )

    request = _make_fake_request(input_tokens=3, max_output_tokens=2)
    with pytest.raises(RuntimeError, match="detokenizer reset boom"):
        list(generate_events(session, request, threading.Event(), deps=runtime.generation_deps()))

    assert runtime._requests_by_id == {}
    assert runtime._pending_by_id == {}
    assert runtime._active_by_uid == {}
    assert runtime._active_detokenizer_ids == set()

    runtime.close()


def test_batch_generator_runtime_supports_two_concurrent_requests() -> None:
    session = _make_fake_session()
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_FakeBatchGenerator),
    )

    req_a = _make_fake_request(input_tokens=3, max_output_tokens=2)
    req_b = _make_fake_request(input_tokens=3, max_output_tokens=2)

    results: dict[str, list[dict[str, Any]]] = {}

    def run_request(name: str, request: Any) -> None:
        results[name] = _collect_events(session, request, runtime.generation_deps())

    thread_a = threading.Thread(target=run_request, args=("a", req_a))
    thread_b = threading.Thread(target=run_request, args=("b", req_b))

    thread_a.start()
    thread_b.start()
    thread_a.join(timeout=2.0)
    thread_b.join(timeout=2.0)

    runtime.close()

    assert set(results.keys()) == {"a", "b"}
    text_a = "".join(
        event["delta"] for event in results["a"] if event["kind"] == "output_text_delta"
    )
    text_b = "".join(
        event["delta"] for event in results["b"] if event["kind"] == "output_text_delta"
    )
    assert {text_a, text_b} == {"AB", "XY"}
    assert results["a"][-1]["kind"] == "completed"
    assert results["b"][-1]["kind"] == "completed"


class _NeverFinishingBatchGenerator:
    def __init__(self, _model: Any, **_kwargs: Any) -> None:
        self._next_uid = 0
        self._active_uids: list[int] = []
        self.closed = False

    def insert(
        self,
        prompts: list[list[int]],
        max_tokens: list[int],
        caches: list[Any] | None = None,
        samplers: list[Any] | None = None,
        logits_processors: list[Any] | None = None,
    ) -> list[int]:
        del max_tokens, caches, samplers, logits_processors
        uids: list[int] = []
        for _ in range(len(prompts)):
            uid = self._next_uid
            self._next_uid += 1
            self._active_uids.append(uid)
            uids.append(uid)
        return uids

    def next(self) -> list[Any]:
        if not self._active_uids:
            return []
        return [
            type(
                "BatchResp",
                (),
                {
                    "uid": uid,
                    "token": 11,
                    "finish_reason": None,
                    "prompt_cache": lambda: [],
                },
            )()
            for uid in self._active_uids
        ]

    def close(self) -> None:
        self.closed = True


class _StopVsLongBatchGenerator:
    def __init__(self, _model: Any, **_kwargs: Any) -> None:
        self._next_uid = 0
        self._active: list[dict[str, Any]] = []

    def insert(
        self,
        prompts: list[list[int]],
        max_tokens: list[int],
        caches: list[Any] | None = None,
        samplers: list[Any] | None = None,
        logits_processors: list[Any] | None = None,
    ) -> list[int]:
        del prompts, caches, samplers, logits_processors
        uids: list[int] = []

        for i, _max_tokens in enumerate(max_tokens):
            uid = self._next_uid
            self._next_uid += 1
            if i == 0:
                tokens = [11, 12, 12, 12, 12, 12]  # starts with "A"
            else:
                tokens = [21] * 8  # long-running request
            self._active.append({"uid": uid, "tokens": tokens, "index": 0})
            uids.append(uid)
        return uids

    def next(self) -> list[Any]:
        responses: list[Any] = []
        survivors: list[dict[str, Any]] = []

        for item in self._active:
            uid = item["uid"]
            tokens: list[int] = item["tokens"]
            index = item["index"]
            token = tokens[index]
            index += 1
            item["index"] = index
            finish_reason = "stop" if index >= len(tokens) else None

            responses.append(
                type(
                    "BatchResp",
                    (),
                    {
                        "uid": uid,
                        "token": token,
                        "finish_reason": finish_reason,
                        "prompt_cache": lambda: [],
                    },
                )()
            )
            if finish_reason is None:
                survivors.append(item)

        self._active = survivors
        threading.Event().wait(0.1)
        return responses


class _BlockingNextBatchGenerator:
    def __init__(self, _model: Any, **_kwargs: Any) -> None:
        self._next_uid = 0
        self._active: list[int] = []
        self.allow_next = threading.Event()
        self.close_called = False

    def insert(
        self,
        prompts: list[list[int]],
        max_tokens: list[int],
        caches: list[Any] | None = None,
        samplers: list[Any] | None = None,
        logits_processors: list[Any] | None = None,
    ) -> list[int]:
        del max_tokens, caches, samplers, logits_processors
        uids: list[int] = []
        for _ in prompts:
            uid = self._next_uid
            self._next_uid += 1
            self._active.append(uid)
            uids.append(uid)
        return uids

    def next(self) -> list[Any]:
        self.allow_next.wait(timeout=5.0)
        responses: list[Any] = []
        active = list(self._active)
        self._active.clear()

        for uid in active:
            responses.append(
                type(
                    "BatchResp",
                    (),
                    {
                        "uid": uid,
                        "token": 11,
                        "finish_reason": "stop",
                        "prompt_cache": lambda: [],
                    },
                )()
            )

        return responses

    def close(self) -> None:
        self.close_called = True


class _StopThenNeverFinishBatchGenerator:
    def __init__(self, _model: Any, **_kwargs: Any) -> None:
        self._next_uid = 0
        self._active: list[int] = []
        self.close_called = False

    def insert(
        self,
        prompts: list[list[int]],
        max_tokens: list[int],
        caches: list[Any] | None = None,
        samplers: list[Any] | None = None,
        logits_processors: list[Any] | None = None,
    ) -> list[int]:
        del max_tokens, caches, samplers, logits_processors
        uids: list[int] = []
        for _ in prompts:
            uid = self._next_uid
            self._next_uid += 1
            self._active.append(uid)
            uids.append(uid)
        return uids

    def next(self) -> list[Any]:
        if not self._active:
            threading.Event().wait(0.05)
            return []

        return [
            type(
                "BatchResp",
                (),
                {
                    "uid": uid,
                    "token": 11,
                    "finish_reason": None,
                    "prompt_cache": lambda: ["late-cache"],
                },
            )()
            for uid in self._active
        ]

    def close(self) -> None:
        self.close_called = True


def test_batch_generator_runtime_cancel_resets_after_bounded_drain_timeout() -> None:
    session = _make_fake_session()
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_NeverFinishingBatchGenerator),
    )

    req_a = _make_fake_request(input_tokens=3, max_output_tokens=128)
    req_b = _make_fake_request(input_tokens=3, max_output_tokens=128)

    cancel_event_a = threading.Event()
    cancel_event_b = threading.Event()

    events_a: list[dict[str, Any]] = []
    events_b: list[dict[str, Any]] = []
    error_b: list[BackendError] = []

    def run_a() -> None:
        events_a.extend(
            generate_events(session, req_a, cancel_event_a, deps=runtime.generation_deps())
        )

    def run_b() -> None:
        try:
            events_b.extend(
                generate_events(session, req_b, cancel_event_b, deps=runtime.generation_deps())
            )
        except BackendError as exc:
            error_b.append(exc)

    thread_a = threading.Thread(target=run_a)
    thread_b = threading.Thread(target=run_b)
    thread_a.start()
    thread_b.start()

    cancel_event_a.set()
    thread_a.join(timeout=2.0)
    thread_b.join(timeout=3.0)

    runtime.close()

    assert thread_a.is_alive() is False
    assert thread_b.is_alive() is False
    assert events_a[-1]["kind"] == "failed"
    assert events_a[-1]["code"] == "cancelled"
    assert error_b
    assert error_b[0].code == "generation_failed"
    assert "reset" in error_b[0].message


def test_batch_generator_runtime_watchdog_resets_when_next_is_blocked() -> None:
    class _WatchdogBlockedNextBatchGenerator:
        instances: list[_WatchdogBlockedNextBatchGenerator] = []
        expected_initial_requests = 2

        def __init__(self, _model: Any, **_kwargs: Any) -> None:
            self.instance_index = len(type(self).instances)
            type(self).instances.append(self)
            self._next_uid = 0
            self._active: dict[int, bool] = {}
            self._second_token_emitted = False
            self.allow_second_next = threading.Event()
            self.entered_blocking_next = threading.Event()
            self.close_called = threading.Event()

        def insert(
            self,
            prompts: list[list[int]],
            max_tokens: list[int],
            caches: list[Any] | None = None,
            samplers: list[Any] | None = None,
            logits_processors: list[Any] | None = None,
        ) -> list[int]:
            del max_tokens, caches, samplers, logits_processors
            uids: list[int] = []
            for _ in prompts:
                uid = self._next_uid
                self._next_uid += 1
                self._active[uid] = False
                uids.append(uid)
            return uids

        def next(self) -> list[Any]:
            active = list(self._active)
            if not active:
                threading.Event().wait(0.01)
                return []

            if self.instance_index > 0:
                self._active.clear()
                return [
                    self._response(uid, token=11, finish_reason="stop")
                    for uid in active
                ]

            first_token_uids = [uid for uid, emitted in self._active.items() if not emitted]
            if first_token_uids:
                for uid in first_token_uids:
                    self._active[uid] = True

                return [
                    self._response(uid, token=11, finish_reason=None)
                    for uid in first_token_uids
                ]

            if len(self._active) < self.expected_initial_requests:
                threading.Event().wait(0.01)
                return []

            if not self._second_token_emitted:
                self.allow_second_next.wait(timeout=5.0)
                self._second_token_emitted = True
                return [
                    self._response(uid, token=12, finish_reason=None)
                    for uid in active
                ]

            self.entered_blocking_next.set()
            self.close_called.wait(timeout=5.0)
            return []

        def close(self) -> None:
            self.allow_second_next.set()
            self.close_called.set()

        def _response(self, uid: int, *, token: int, finish_reason: str | None) -> Any:
            return type(
                "BatchResp",
                (),
                {
                    "uid": uid,
                    "token": token,
                    "finish_reason": finish_reason,
                    "prompt_cache": lambda: [],
                },
            )()

    def wait_for(predicate: Callable[[], bool], timeout: float = 2.0) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            threading.Event().wait(0.01)
        raise AssertionError("timed out waiting for condition")

    session = _make_fake_session()
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_WatchdogBlockedNextBatchGenerator),
    )

    req_cancel = _make_fake_request(input_tokens=3, max_output_tokens=128)
    req_waiter = _make_fake_request(input_tokens=3, max_output_tokens=128)
    cancel_event_cancel = threading.Event()
    cancel_event_waiter = threading.Event()

    events_cancel: list[dict[str, Any]] = []
    events_waiter: list[dict[str, Any]] = []
    errors_cancel: list[BackendError] = []
    errors_waiter: list[BackendError] = []

    def run_cancel() -> None:
        try:
            events_cancel.extend(
                generate_events(
                    session,
                    req_cancel,
                    cancel_event_cancel,
                    deps=runtime.generation_deps(),
                )
            )
        except BackendError as exc:
            errors_cancel.append(exc)

    def run_waiter() -> None:
        try:
            events_waiter.extend(
                generate_events(
                    session,
                    req_waiter,
                    cancel_event_waiter,
                    deps=runtime.generation_deps(),
                )
            )
        except BackendError as exc:
            errors_waiter.append(exc)

    thread_cancel = threading.Thread(target=run_cancel)
    thread_waiter = threading.Thread(target=run_waiter)
    thread_cancel.start()
    thread_waiter.start()

    try:
        wait_for(
            lambda: sum(1 for event in events_cancel if event["kind"] == "output_text_delta") >= 1
            and sum(1 for event in events_waiter if event["kind"] == "output_text_delta") >= 1
        )

        first_generator = _WatchdogBlockedNextBatchGenerator.instances[0]
        cancel_event_cancel.set()
        first_generator.allow_second_next.set()

        wait_for(lambda: bool(events_cancel) and events_cancel[-1]["kind"] == "failed")
        wait_for(first_generator.entered_blocking_next.is_set)
        wait_for(first_generator.close_called.is_set, timeout=2.0)

        thread_cancel.join(timeout=2.0)
        thread_waiter.join(timeout=2.0)

        wait_for(lambda: len(_WatchdogBlockedNextBatchGenerator.instances) >= 2)

        fresh_request = _make_fake_request(input_tokens=3, max_output_tokens=8)
        fresh_events = list(
            generate_events(
                session,
                fresh_request,
                threading.Event(),
                deps=runtime.generation_deps(),
            )
        )
    finally:
        runtime.close()
        thread_cancel.join(timeout=2.0)
        thread_waiter.join(timeout=2.0)

    assert thread_cancel.is_alive() is False
    assert thread_waiter.is_alive() is False
    assert errors_cancel == []
    assert events_cancel[-1]["kind"] == "failed"
    assert events_cancel[-1]["code"] == "cancelled"
    assert first_generator.entered_blocking_next.is_set() is True
    assert first_generator.close_called.is_set() is True
    assert errors_waiter
    assert errors_waiter[0].code == "generation_failed"
    assert errors_waiter[0].retryable is True
    assert "cancellation drain timeout" in errors_waiter[0].message
    assert fresh_events[-1]["kind"] == "completed"
    assert fresh_events[-1]["finish_reason"] == "FINISH_REASON_STOP"



def test_batch_generator_runtime_cleans_request_state_on_normal_completion() -> None:
    session = _make_fake_session()
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_FakeBatchGenerator),
    )

    request = _make_fake_request(input_tokens=3, max_output_tokens=2)
    events = list(
        generate_events(session, request, threading.Event(), deps=runtime.generation_deps())
    )

    assert events[-1]["kind"] == "completed"
    assert runtime._requests_by_id == {}
    assert runtime._pending_by_id == {}

    runtime.close()


def test_batch_generator_runtime_releases_detokenizer_after_terminal_service_break() -> None:
    session = _make_fake_session()
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_FakeBatchGenerator),
    )

    request = _make_fake_request(input_tokens=3, max_output_tokens=2)
    iterator = generate_events(session, request, threading.Event(), deps=runtime.generation_deps())

    try:
        for event in iterator:
            if event["kind"] in ("completed", "failed"):
                break
    finally:
        iterator.close()

    assert runtime._active_detokenizer_ids == set()

    runtime.close()


def test_batch_generator_runtime_close_raises_if_pump_cannot_stop_after_generator_close() -> None:
    session = _make_fake_session()
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_BlockingNextBatchGenerator),
    )

    request = _make_fake_request(input_tokens=3, max_output_tokens=4)
    thread_errors: list[Exception] = []

    def run() -> None:
        try:
            list(
                generate_events(session, request, threading.Event(), deps=runtime.generation_deps())
            )
        except Exception as exc:  # pragma: no cover - should stay empty
            thread_errors.append(exc)

    thread = threading.Thread(target=run)
    thread.start()

    deadline = time.monotonic() + 1.0
    while time.monotonic() < deadline and not runtime._active_by_uid:
        threading.Event().wait(0.01)

    assert runtime._active_by_uid

    generator = cast(_BlockingNextBatchGenerator, runtime._batch_generator)

    with pytest.raises(BackendError) as exc_info:
        runtime.close()

    assert exc_info.value.code == "batch_runtime_close_timeout"
    assert runtime._pump.is_alive() is True
    assert generator.close_called is True

    generator.allow_next.set()
    thread.join(timeout=2.0)
    runtime.close()

    assert thread.is_alive() is False
    assert len(thread_errors) == 1
    assert isinstance(thread_errors[0], BackendError)
    assert thread_errors[0].code == "generation_failed"
    assert "batch runtime closed" in thread_errors[0].message


def test_batch_generator_runtime_cleans_request_state_on_cancel_close() -> None:
    session = _make_fake_session()
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_NeverFinishingBatchGenerator),
    )

    request = _make_fake_request(input_tokens=3, max_output_tokens=128)
    cancel_event = threading.Event()

    events: list[dict[str, Any]] = []

    def run() -> None:
        events.extend(
            generate_events(session, request, cancel_event, deps=runtime.generation_deps())
        )

    thread = threading.Thread(target=run)
    thread.start()
    cancel_event.set()
    thread.join(timeout=2.0)

    assert thread.is_alive() is False
    assert events[-1]["kind"] == "failed"
    assert events[-1]["code"] == "cancelled"
    assert runtime._requests_by_id == {}

    runtime.close()



def test_batch_generator_runtime_cancel_event_wakes_blocked_waiter() -> None:
    class _BlockAfterFirstTokenBatchGenerator:
        def __init__(self, _model: Any, **_kwargs: Any) -> None:
            self._next_uid = 0
            self._active: list[int] = []
            self._next_calls = 0
            self._release_block = threading.Event()

        def insert(
            self,
            prompts: list[list[int]],
            max_tokens: list[int],
            caches: list[Any] | None = None,
            samplers: list[Any] | None = None,
            logits_processors: list[Any] | None = None,
        ) -> list[int]:
            del max_tokens, caches, samplers, logits_processors
            uids: list[int] = []
            for _ in prompts:
                uid = self._next_uid
                self._next_uid += 1
                self._active.append(uid)
                uids.append(uid)
            return uids

        def next(self) -> list[Any]:
            active = list(self._active)
            if not active:
                threading.Event().wait(0.01)
                return []

            self._next_calls += 1
            if self._next_calls == 1:
                return [
                    type(
                        "BatchResp",
                        (),
                        {
                            "uid": uid,
                            "token": 11,
                            "finish_reason": None,
                            "prompt_cache": lambda: [],
                        },
                    )()
                    for uid in active
                ]

            self._release_block.wait(timeout=5.0)
            return []

        def close(self) -> None:
            self._release_block.set()

    session = _make_fake_session()
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_BlockAfterFirstTokenBatchGenerator),
    )

    request = _make_fake_request(input_tokens=3, max_output_tokens=128)
    cancel_event = threading.Event()
    events: list[dict[str, Any]] = []

    def run() -> None:
        events.extend(
            generate_events(session, request, cancel_event, deps=runtime.generation_deps())
        )

    thread = threading.Thread(target=run)
    thread.start()

    deadline = time.monotonic() + 1.0
    while time.monotonic() < deadline and not events:
        threading.Event().wait(0.01)

    cancel_event.set()
    thread.join(timeout=2.0)

    assert thread.is_alive() is False
    assert events[-1]["kind"] == "failed"
    assert events[-1]["code"] == "cancelled"

    runtime.close()


def test_batch_generator_runtime_cleans_request_state_on_runtime_close() -> None:
    session = _make_fake_session()
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_NeverFinishingBatchGenerator),
    )

    request = _make_fake_request(input_tokens=3, max_output_tokens=128)
    errors: list[BackendError] = []

    def run() -> None:
        try:
            list(
                generate_events(session, request, threading.Event(), deps=runtime.generation_deps())
            )
        except BackendError as exc:
            errors.append(exc)

    thread = threading.Thread(target=run)
    thread.start()
    threading.Event().wait(0.1)
    runtime.close()
    thread.join(timeout=2.0)

    assert thread.is_alive() is False
    assert errors
    assert errors[0].code == "generation_failed"
    assert runtime._requests_by_id == {}


def test_batch_generator_runtime_suppresses_terminal_stop_token_text() -> None:
    session = _make_fake_session(eos_token_ids=(12,))
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_FakeBatchGenerator),
    )

    request = _make_fake_request(input_tokens=3, max_output_tokens=2)
    events = list(
        generate_events(session, request, threading.Event(), deps=runtime.generation_deps())
    )

    deltas = [event["delta"] for event in events if event["kind"] == "output_text_delta"]
    assert deltas == ["A"]
    assert events[-1]["kind"] == "completed"

    runtime.close()


def test_batch_generator_runtime_rejects_stop_sequences_before_batch_submission() -> None:
    clear_mock = MagicMock(name="clear_cache")
    session = _make_fake_session(clear_cache=clear_mock)
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_StopThenNeverFinishBatchGenerator),
    )

    request = _make_fake_request(input_tokens=3, max_output_tokens=8, stop_sequences=["A"])
    events = list(
        generate_events(session, request, threading.Event(), deps=runtime.generation_deps())
    )

    assert events == [
        {
            "kind": "failed",
            "code": "unsupported_generation_params",
            "message": "stop_sequences are not supported with generation_mode=batch",
            "retryable": False,
        }
    ]
    assert runtime._requests_by_id == {}
    assert runtime._pending_by_id == {}
    assert runtime._active_by_uid == {}
    clear_mock.assert_not_called()

    runtime.close()


def test_batch_runtime_zero_token_early_exit_does_not_clear_session_cache() -> None:
    clear_mock = MagicMock(name="clear_cache")
    session = _make_fake_session(clear_cache=clear_mock)
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_FakeBatchGenerator),
    )

    request = _make_fake_request(input_tokens=3, max_output_tokens=0)
    events = list(
        generate_events(session, request, threading.Event(), deps=runtime.generation_deps())
    )

    assert events[-1]["kind"] == "completed"
    assert events[-1]["finish_reason"] == "FINISH_REASON_LENGTH"
    clear_mock.assert_not_called()

    runtime.close()



def test_batch_runtime_does_not_clear_session_cache_per_request() -> None:
    clear_mock = MagicMock(name="clear_cache")
    session = _make_fake_session(clear_cache=clear_mock)
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_FakeBatchGenerator),
    )

    request = _make_fake_request(input_tokens=3, max_output_tokens=2)
    events = list(
        generate_events(session, request, threading.Event(), deps=runtime.generation_deps())
    )

    assert events[-1]["kind"] == "completed"
    clear_mock.assert_not_called()

    runtime.close()


def test_batch_generator_runtime_generator_close_marks_request_cancelled_not_local_close() -> None:
    session = _make_fake_session()
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_NeverFinishingBatchGenerator),
    )

    request = _make_fake_request(input_tokens=3, max_output_tokens=32)
    iterator = generate_events(session, request, threading.Event(), deps=runtime.generation_deps())

    try:
        first_event = next(iterator)
        assert first_event["kind"] == "output_text_delta"

        iterator.close()

        deadline = time.monotonic() + 1.0
        state = None
        while time.monotonic() < deadline:
            active_states = list(runtime._active_by_uid.values())
            if active_states:
                state = active_states[0]
                if state.cancel_deadline_monotonic is not None:
                    break
            threading.Event().wait(0.01)

        assert state is not None
        assert state.cancel_deadline_monotonic is not None
        assert state.local_close_deadline_monotonic is None
    finally:
        runtime.close()


def test_batch_stop_sequence_request_does_not_affect_other_batch_requests() -> None:
    session = _make_fake_session()
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_FakeBatchGenerator),
    )

    req_stop = _make_fake_request(input_tokens=3, max_output_tokens=16, stop_sequences=["A"])
    req_long = _make_fake_request(input_tokens=3, max_output_tokens=16)

    events_stop: list[dict[str, Any]] = []
    events_long: list[dict[str, Any]] = []
    long_errors: list[BackendError] = []

    def run_long() -> None:
        try:
            events_long.extend(
                generate_events(
                    session,
                    req_long,
                    threading.Event(),
                    deps=runtime.generation_deps(),
                )
            )
        except BackendError as exc:
            long_errors.append(exc)

    t_long = threading.Thread(target=run_long)
    t_long.start()

    deadline = time.monotonic() + 1.0
    while time.monotonic() < deadline and not runtime._active_by_uid:
        threading.Event().wait(0.01)

    events_stop.extend(
        generate_events(session, req_stop, threading.Event(), deps=runtime.generation_deps())
    )

    t_long.join(timeout=2.0)
    runtime.close()

    assert t_long.is_alive() is False
    assert events_stop == [
        {
            "kind": "failed",
            "code": "unsupported_generation_params",
            "message": "stop_sequences are not supported with generation_mode=batch",
            "retryable": False,
        }
    ]
    assert long_errors == []
    assert events_long[-1]["kind"] == "completed"
    assert events_long[-1]["finish_reason"] == "FINISH_REASON_STOP"


class _MalformedBatchResponseGenerator:
    def __init__(self, _model: Any, **_kwargs: Any) -> None:
        self._next_uid = 0

    def insert(
        self,
        prompts: list[list[int]],
        max_tokens: list[int],
        caches: list[Any] | None = None,
        samplers: list[Any] | None = None,
        logits_processors: list[Any] | None = None,
    ) -> list[int]:
        del max_tokens, caches, samplers, logits_processors
        uids = list(range(self._next_uid, self._next_uid + len(prompts)))
        self._next_uid += len(prompts)
        return uids

    def next(self) -> list[Any]:
        return [
            type(
                "BadResp",
                (),
                {
                    "uid": 0,
                    "token": "bad-token",
                    "finish_reason": None,
                    "prompt_cache": lambda: [],
                },
            )()
        ]


class _BadThenGoodInsertBatchGenerator:
    def __init__(self, _model: Any, **_kwargs: Any) -> None:
        self._insert_calls = 0
        self._active: list[dict[str, Any]] = []

    def insert(
        self,
        prompts: list[list[int]],
        max_tokens: list[int],
        caches: list[Any] | None = None,
        samplers: list[Any] | None = None,
        logits_processors: list[Any] | None = None,
    ) -> list[int]:
        del caches, samplers, logits_processors
        self._insert_calls += 1
        if self._insert_calls == 1:
            return [1, 1]

        self._active = [
            {"uid": 100 + i, "remaining": max(1, max_tokens[i])} for i in range(len(prompts))
        ]
        return [item["uid"] for item in self._active]

    def next(self) -> list[Any]:
        responses: list[Any] = []
        survivors: list[dict[str, Any]] = []

        for item in self._active:
            item["remaining"] -= 1
            finish_reason = "stop" if item["remaining"] <= 0 else None
            responses.append(
                type(
                    "Resp",
                    (),
                    {
                        "uid": item["uid"],
                        "token": 11,
                        "finish_reason": finish_reason,
                        "prompt_cache": lambda: [],
                    },
                )()
            )
            if finish_reason is None:
                survivors.append(item)

        self._active = survivors
        return responses


def test_batch_generator_runtime_malformed_payload_fails_request_without_stranding_waiter() -> None:
    session = _make_fake_session()
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_MalformedBatchResponseGenerator),
    )

    request = _make_fake_request(input_tokens=3, max_output_tokens=2)

    with pytest.raises(BackendError) as exc_info:
        list(generate_events(session, request, threading.Event(), deps=runtime.generation_deps()))

    runtime.close()

    assert exc_info.value.code == "generation_failed"
    assert "token" in exc_info.value.message


def test_batch_generator_runtime_invalid_insert_uids_fail_request_and_keep_runtime_alive() -> None:
    session = _make_fake_session()
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_BadThenGoodInsertBatchGenerator),
    )

    bad_request = _make_fake_request(input_tokens=3, max_output_tokens=1)

    with pytest.raises(BackendError) as exc_info:
        list(
            generate_events(session, bad_request, threading.Event(), deps=runtime.generation_deps())
        )

    assert exc_info.value.code == "generation_failed"
    assert "insert" in exc_info.value.message

    good_request = _make_fake_request(input_tokens=3, max_output_tokens=1)
    good_events = list(
        generate_events(session, good_request, threading.Event(), deps=runtime.generation_deps())
    )

    runtime.close()

    assert good_events[-1]["kind"] == "completed"


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
    assert (
        completed["usage"]["output_tokens"] == 3
    )  # all 3 responses counted (incl. empty-text terminal)
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
    events = _collect_events(_make_fake_session(), _make_fake_request(), _make_deps(responses))
    assert events[-1]["finish_reason"] == "FINISH_REASON_STOP"


def test_finish_reason_length() -> None:
    """Max tokens termination maps to FINISH_REASON_LENGTH."""
    responses = [
        FakeGenerationResponse(text="cut", token=10, finish_reason="length"),
    ]
    events = _collect_events(_make_fake_session(), _make_fake_request(), _make_deps(responses))
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

    session.tokenizer.encode.assert_called_once_with("test prompt", add_special_tokens=False)


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
        FakeGenerationResponse(text="", token=1),  # buffered
        FakeGenerationResponse(text="", token=2),  # buffered
        FakeGenerationResponse(text="flush", token=3),  # flush
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
        FakeGenerationResponse(text="after", token=12),  # should not be reached
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

    all_text = "".join(e["delta"] for e in events if e["kind"] == "output_text_delta")
    assert stop not in all_text
    assert "done" not in all_text  # text after stop also suppressed
    assert all_text == "Hello world! The answer is 42. And"


# ===========================================================================
# Tool calling integration (Phase 4 Tasks 9-11)
# ===========================================================================


def _tool_call_tools_json() -> bytes:
    return b'[{"type":"function","function":{"name":"lookup_weather","parameters":{}}}]'


def test_tool_choice_auto_emits_incremental_tool_call_deltas_and_tool_calls_finish_reason() -> None:
    def parser(text: str, tools: Any) -> dict[str, Any]:
        assert tools == [
            {"type": "function", "function": {"name": "lookup_weather", "parameters": {}}}
        ]
        assert text == '{"city":"Singapore"}'
        return {"id": "call_weather", "name": "lookup_weather", "arguments": {"city": "Singapore"}}

    responses = [
        FakeGenerationResponse(text="<tool_call>", token=10),
        FakeGenerationResponse(text='{"city":"Sing', token=11),
        FakeGenerationResponse(text='apore"}', token=12),
        FakeGenerationResponse(text="</tool_call>", token=13, finish_reason="stop"),
    ]
    session = _make_fake_session(
        tool_calling={"supported": True, "parser_type": "json_tools"},
        tool_parser=parser,
        tool_call_start="<tool_call>",
        tool_call_end="</tool_call>",
    )
    request = _make_fake_request(tools_json=_tool_call_tools_json())

    events = _collect_events(session, request, _make_deps(responses))

    assert [event["kind"] for event in events] == [
        "tool_call_delta",
        "tool_call_delta",
        "completed",
    ]
    assert [event["tool_call_id"] for event in events[:-1]] == ["call_0", "call_0"]
    assert events[0]["delta"] == {
        "index": 0,
        "type": "function",
        "function": {
            "name": "lookup_weather",
            "arguments_delta": '{"city":"Sing',
        },
    }
    assert events[1]["delta"] == {
        "index": 0,
        "function": {
            "arguments_delta": 'apore"}',
        },
    }
    assert events[-1]["finish_reason"] == "FINISH_REASON_TOOL_CALLS"


def test_tool_call_markers_can_share_chunks_with_text() -> None:
    def parser(text: str, tools: Any) -> dict[str, Any]:
        assert text == '{"city":"Singapore"}'
        return {"name": "lookup_weather", "arguments": text}

    responses = [
        FakeGenerationResponse(
            text='Before <tool_call>{"city":"Singapore"}</tool_call> after',
            token=10,
            finish_reason="stop",
        ),
    ]
    session = _make_fake_session(
        tool_calling={"supported": True, "parser_type": "json_tools"},
        tool_parser=parser,
        tool_call_start="<tool_call>",
        tool_call_end="</tool_call>",
    )
    request = _make_fake_request(tools_json=_tool_call_tools_json())

    events = _collect_events(session, request, _make_deps(responses))

    assert [event["kind"] for event in events] == [
        "output_text_delta",
        "tool_call_delta",
        "output_text_delta",
        "completed",
    ]
    assert events[0]["delta"] == "Before "
    assert events[1]["delta"]["function"] == {
        "name": "lookup_weather",
        "arguments_delta": '{"city":"Singapore"}',
    }
    assert events[2]["delta"] == " after"
    assert events[-1]["finish_reason"] == "FINISH_REASON_TOOL_CALLS"


def test_multi_tool_auto_emits_late_name_delta_after_argument_fragments() -> None:
    tools_json = (
        b"["
        b'{"type":"function","function":{"name":"lookup_weather","parameters":{}}},'
        b'{"type":"function","function":{"name":"lookup_time","parameters":{}}}'
        b"]"
    )

    def parser(text: str, tools: Any) -> dict[str, Any]:
        assert text == '{"city":"Singapore"}'
        assert len(tools) == 2
        return {"name": "lookup_time", "arguments": text}

    responses = [
        FakeGenerationResponse(text="<tool_call>", token=10),
        FakeGenerationResponse(text='{"city":"Sing', token=11),
        FakeGenerationResponse(text='apore"}', token=12),
        FakeGenerationResponse(text="</tool_call>", token=13, finish_reason="stop"),
    ]
    session = _make_fake_session(
        tool_calling={"supported": True, "parser_type": "json_tools"},
        tool_parser=parser,
        tool_call_start="<tool_call>",
        tool_call_end="</tool_call>",
    )
    request = _make_fake_request(tools_json=tools_json)

    events = _collect_events(session, request, _make_deps(responses))

    assert [event["kind"] for event in events] == [
        "tool_call_delta",
        "tool_call_delta",
        "tool_call_delta",
        "completed",
    ]
    assert events[0]["delta"] == {
        "index": 0,
        "type": "function",
        "function": {"arguments_delta": '{"city":"Sing'},
    }
    assert events[1]["delta"] == {
        "index": 0,
        "function": {"arguments_delta": 'apore"}'},
    }
    assert events[2]["delta"] == {
        "index": 0,
        "function": {"name": "lookup_time"},
    }
    assert events[-1]["finish_reason"] == "FINISH_REASON_TOOL_CALLS"


def test_tool_choice_required_fails_when_no_tool_call_is_emitted() -> None:
    responses = [
        FakeGenerationResponse(text="plain text", token=10, finish_reason="stop"),
    ]
    session = _make_fake_session(
        tool_calling={"supported": True, "parser_type": "json_tools"},
        tool_parser=lambda text, tools: {},
        tool_call_start="<tool_call>",
        tool_call_end="</tool_call>",
    )
    request = _make_fake_request(
        tools_json=_tool_call_tools_json(),
        tool_choice_json=b'"required"',
    )

    events = _collect_events(session, request, _make_deps(responses))

    assert events[-1]["kind"] == "failed"
    assert events[-1]["code"] == "tool_choice_not_satisfied"
    assert len([event for event in events if event["kind"] in {"completed", "failed"}]) == 1


def test_required_tool_choice_without_tools_raises_backend_error() -> None:
    session = _make_fake_session(
        tool_calling={"supported": True, "parser_type": "json_tools"},
        tool_parser=lambda text, tools: {"name": "lookup_weather", "arguments": text},
        tool_call_start="<tool_call>",
        tool_call_end="</tool_call>",
    )
    request = _make_fake_request(tool_choice_json=b'"required"')

    with pytest.raises(BackendError) as exc_info:
        _collect_events(session, request, _make_deps([]))

    assert exc_info.value.code == "invalid_generation_params"


def test_named_tool_choice_fails_when_model_uses_wrong_function() -> None:
    def parser(text: str, tools: Any) -> dict[str, Any]:
        return {"name": "lookup_time", "arguments": {"city": "Singapore"}}

    responses = [
        FakeGenerationResponse(text="<tool_call>", token=10),
        FakeGenerationResponse(text='{"city":"Singapore"}', token=11),
        FakeGenerationResponse(text="</tool_call>", token=12, finish_reason="stop"),
    ]
    session = _make_fake_session(
        tool_calling={"supported": True, "parser_type": "json_tools"},
        tool_parser=parser,
        tool_call_start="<tool_call>",
        tool_call_end="</tool_call>",
    )
    request = _make_fake_request(
        tools_json=_tool_call_tools_json(),
        tool_choice_json=b'{"type":"function","function":{"name":"lookup_weather"}}',
    )

    events = _collect_events(session, request, _make_deps(responses))

    assert events[0]["kind"] == "tool_call_delta"
    assert events[0]["delta"]["function"] == {
        "name": "lookup_weather",
        "arguments_delta": '{"city":"Singapore"}',
    }
    assert events[-1]["kind"] == "failed"
    assert events[-1]["code"] == "tool_choice_not_satisfied"
    assert len([event for event in events if event["kind"] in {"completed", "failed"}]) == 1


def test_cancel_mid_tool_call_emits_partial_tool_call_before_cancelled_terminal() -> None:
    cancel = threading.Event()

    def stream_with_cancel(model, tokenizer, prompt_ids, **kwargs):
        yield FakeGenerationResponse(text="<tool_call>", token=10)
        yield FakeGenerationResponse(text='{"city":"Sing', token=11)
        cancel.set()
        yield FakeGenerationResponse(text='apore"}', token=12)

    deps = GenerationDeps(
        stream_generate=stream_with_cancel,
        make_sampler=lambda **kw: MagicMock(),
    )
    session = _make_fake_session(
        tool_calling={"supported": True, "parser_type": "json_tools"},
        tool_parser=lambda text, tools: {"name": "lookup_weather", "arguments": text},
        tool_call_start="<tool_call>",
        tool_call_end="</tool_call>",
    )
    request = _make_fake_request(tools_json=_tool_call_tools_json())

    events = _collect_events(session, request, deps, cancel_event=cancel)

    assert events[:-1] == [
        {
            "kind": "tool_call_delta",
            "tool_call_id": "call_0",
            "delta": {
                "index": 0,
                "type": "function",
                "function": {
                    "name": "lookup_weather",
                    "arguments_delta": '{"city":"Sing',
                },
            },
        }
    ]
    assert events[-1]["kind"] == "failed"
    assert events[-1]["code"] == "cancelled"
    assert len([event for event in events if event["kind"] in {"completed", "failed"}]) == 1


def test_stop_sequences_do_not_truncate_tool_call_arguments() -> None:
    def parser(text: str, tools: Any) -> dict[str, Any]:
        return {"name": "lookup_weather", "arguments": text}

    responses = [
        FakeGenerationResponse(text="<tool_call>", token=10),
        FakeGenerationResponse(text='{"city":"Singapore"}', token=11),
        FakeGenerationResponse(text="</tool_call>", token=12, finish_reason="stop"),
    ]
    session = _make_fake_session(
        tool_calling={"supported": True, "parser_type": "json_tools"},
        tool_parser=parser,
        tool_call_start="<tool_call>",
        tool_call_end="</tool_call>",
    )
    request = _make_fake_request(
        tools_json=_tool_call_tools_json(),
        stop_sequences=["Singapore", "}"],
    )

    events = _collect_events(session, request, _make_deps(responses))

    assert events[0]["delta"]["function"]["arguments_delta"] == '{"city":"Singapore"}'
    assert events[-1]["finish_reason"] == "FINISH_REASON_TOOL_CALLS"


def test_tool_choice_none_disables_tool_call_parsing() -> None:
    responses = [
        FakeGenerationResponse(text="<tool_call>", token=10),
        FakeGenerationResponse(text='{"city":"Singapore"}', token=11),
        FakeGenerationResponse(text="</tool_call>", token=12, finish_reason="stop"),
    ]
    session = _make_fake_session(
        tool_calling={"supported": True, "parser_type": "json_tools"},
        tool_parser=lambda text, tools: {"name": "lookup_weather", "arguments": text},
        tool_call_start="<tool_call>",
        tool_call_end="</tool_call>",
    )
    request = _make_fake_request(
        tools_json=_tool_call_tools_json(),
        tool_choice_json=b'"none"',
    )

    events = _collect_events(session, request, _make_deps(responses))

    assert [event["kind"] for event in events] == [
        "output_text_delta",
        "output_text_delta",
        "output_text_delta",
        "completed",
    ]
    assert events[-1]["finish_reason"] == "FINISH_REASON_STOP"


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
            cb(0, 100)  # initial zero — should be filtered
            cb(50, 100)  # real progress
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
    for e in events[terminal_idx + 1 :]:
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


# ===========================================================================
# KV prefix-cache integration (Task 6 Phase 3)
# ===========================================================================


class FakePrefixCache:
    """Spy/fake for KVPrefixCache used by generation integration tests.

    Verifies orchestration logic without re-testing prefix_cache.py internals.
    """

    def __init__(
        self,
        *,
        lookup_result: Any = None,
        lookup_side_effect: Exception | None = None,
        store_side_effect: Exception | None = None,
        store_result: bool = True,
    ) -> None:
        self.lookup_result = lookup_result
        self.lookup_side_effect = lookup_side_effect
        self.store_side_effect = store_side_effect
        self.store_result = store_result
        self.lookup_calls: list[tuple[list[int], Any]] = []
        self.store_calls: list[tuple[list[int], Any]] = []

    def lookup(self, token_ids, *, trim_fn):
        self.lookup_calls.append((list(token_ids), trim_fn))
        if self.lookup_side_effect is not None:
            raise self.lookup_side_effect
        return self.lookup_result

    def store(self, token_ids, prompt_cache):
        self.store_calls.append((list(token_ids), prompt_cache))
        if self.store_side_effect is not None:
            raise self.store_side_effect
        return self.store_result


@dataclass
class FakeCacheHit:
    """Minimal stand-in for prefix_cache.CacheHit."""

    prompt_cache: Any
    matched_length: int
    remaining_ids: list[int]


def _cache_deps(
    responses: list[FakeGenerationResponse],
    *,
    captured_kwargs: list[dict[str, Any]] | None = None,
) -> tuple[GenerationDeps, MagicMock, MagicMock]:
    """Create deps with prompt-cache helpers for prefix cache tests.

    Returns ``(deps, make_prompt_cache_mock, trim_prompt_cache_mock)``.
    The ``make_prompt_cache_mock`` returns a fresh MagicMock per call.
    """
    make_mock = MagicMock(name="make_prompt_cache")
    make_mock.side_effect = lambda model: MagicMock(name="FreshCache")
    trim_mock = MagicMock(name="trim_prompt_cache")

    def fake_stream(model, tokenizer, prompt_ids, **kwargs):
        if captured_kwargs is not None:
            captured_kwargs.append(kwargs)
        yield from responses

    deps = GenerationDeps(
        stream_generate=fake_stream,
        make_sampler=lambda **kw: MagicMock(name="Sampler"),
        make_prompt_cache=make_mock,
        trim_prompt_cache=trim_mock,
    )
    return deps, make_mock, trim_mock


# --- Cache preparation / stream input tests ---


def test_cache_miss_creates_fresh_prompt_cache() -> None:
    """Cache enabled, lookup miss → stream_generate receives fresh prompt_cache."""
    captured_kwargs: list[dict[str, Any]] = []
    responses = [
        FakeGenerationResponse(text="ok", token=10, finish_reason="stop"),
    ]
    fake_cache = FakePrefixCache(lookup_result=None)  # miss
    deps, make_mock, _ = _cache_deps(responses, captured_kwargs=captured_kwargs)

    session = _make_fake_session(prefix_cache=fake_cache)
    request = _make_fake_request()
    events = _collect_events(session, request, deps)

    assert events[-1]["kind"] == "completed"
    # make_prompt_cache called once (for fresh cache on miss)
    make_mock.assert_called_once()
    # stream_generate received prompt_cache kwarg
    assert len(captured_kwargs) == 1
    assert "prompt_cache" in captured_kwargs[0]


def test_cache_hit_uses_restored_cache_and_remaining_ids() -> None:
    """Cache hit → stream_generate receives restored cache and remaining IDs."""
    restored_cache = MagicMock(name="RestoredCache")
    hit = FakeCacheHit(
        prompt_cache=restored_cache,
        matched_length=2,
        remaining_ids=[3],
    )
    fake_cache = FakePrefixCache(lookup_result=hit)
    captured_kwargs: list[dict[str, Any]] = []
    captured_prompt_ids: list[list[int]] = []

    responses = [
        FakeGenerationResponse(text="ok", token=10, finish_reason="stop"),
    ]

    def stream_with_capture(model, tokenizer, prompt_ids, **kwargs):
        captured_prompt_ids.append(list(prompt_ids))
        captured_kwargs.append(kwargs)
        yield from responses

    deps = GenerationDeps(
        stream_generate=stream_with_capture,
        make_sampler=lambda **kw: MagicMock(),
        make_prompt_cache=MagicMock(),
        trim_prompt_cache=MagicMock(),
    )
    session = _make_fake_session(prefix_cache=fake_cache)
    request = _make_fake_request()
    events = _collect_events(session, request, deps)

    assert events[-1]["kind"] == "completed"
    # stream_generate received remaining_ids, not original prompt_ids
    assert captured_prompt_ids[0] == [3]
    # stream_generate received the restored cache
    assert captured_kwargs[0]["prompt_cache"] is restored_cache


def test_exact_hit_honors_single_token_remaining() -> None:
    """Full-query coverage hit returns remaining_ids=[last_token]."""
    restored = MagicMock(name="TrimmedCache")
    hit = FakeCacheHit(
        prompt_cache=restored,
        matched_length=3,
        remaining_ids=[3],  # exact hit: only last token
    )
    fake_cache = FakePrefixCache(lookup_result=hit)
    captured_prompt_ids: list[list[int]] = []

    responses = [
        FakeGenerationResponse(text="ok", token=10, finish_reason="stop"),
    ]

    def stream_capture(model, tokenizer, prompt_ids, **kwargs):
        captured_prompt_ids.append(list(prompt_ids))
        yield from responses

    deps = GenerationDeps(
        stream_generate=stream_capture,
        make_sampler=lambda **kw: MagicMock(),
        make_prompt_cache=MagicMock(),
        trim_prompt_cache=MagicMock(),
    )
    session = _make_fake_session(prefix_cache=fake_cache)
    request = _make_fake_request()
    _collect_events(session, request, deps)

    assert captured_prompt_ids[0] == [3]


def test_lookup_failure_falls_back_uncached() -> None:
    """prefix_cache.lookup raises → generation completes without prompt_cache."""
    fake_cache = FakePrefixCache(lookup_side_effect=RuntimeError("boom"))
    captured_kwargs: list[dict[str, Any]] = []
    responses = [
        FakeGenerationResponse(text="ok", token=10, finish_reason="stop"),
    ]
    deps, _, _ = _cache_deps(responses, captured_kwargs=captured_kwargs)
    session = _make_fake_session(prefix_cache=fake_cache)
    request = _make_fake_request()
    events = _collect_events(session, request, deps)

    assert events[-1]["kind"] == "completed"
    # No prompt_cache kwarg since lookup exception triggers full fallback
    assert "prompt_cache" not in captured_kwargs[0]


def test_make_prompt_cache_failure_falls_back_uncached() -> None:
    """make_prompt_cache raises on miss → generation completes without prompt_cache."""
    fake_cache = FakePrefixCache(lookup_result=None)  # miss
    captured_kwargs: list[dict[str, Any]] = []
    responses = [
        FakeGenerationResponse(text="ok", token=10, finish_reason="stop"),
    ]
    failing_make = MagicMock(side_effect=RuntimeError("OOM"))

    def fake_stream(model, tokenizer, prompt_ids, **kwargs):
        captured_kwargs.append(kwargs)
        yield from responses

    deps = GenerationDeps(
        stream_generate=fake_stream,
        make_sampler=lambda **kw: MagicMock(),
        make_prompt_cache=failing_make,
        trim_prompt_cache=MagicMock(),
    )
    session = _make_fake_session(prefix_cache=fake_cache)
    request = _make_fake_request()
    events = _collect_events(session, request, deps)

    assert events[-1]["kind"] == "completed"
    # Fell back to uncached generation
    assert "prompt_cache" not in captured_kwargs[0]


def test_cache_disabled_omits_prompt_cache_kwarg() -> None:
    """With prefix_cache=None, stream_generate gets no prompt_cache kwarg."""
    captured_kwargs: list[dict[str, Any]] = []
    responses = [
        FakeGenerationResponse(text="ok", token=10, finish_reason="stop"),
    ]
    deps, _, _ = _cache_deps(responses, captured_kwargs=captured_kwargs)
    session = _make_fake_session(prefix_cache=None)
    request = _make_fake_request()
    events = _collect_events(session, request, deps)

    assert events[-1]["kind"] == "completed"
    assert "prompt_cache" not in captured_kwargs[0]


def test_deps_missing_cache_helpers_falls_back_uncached() -> None:
    """prefix_cache live but deps lack make/trim helpers → uncached generation."""
    fake_cache = FakePrefixCache(lookup_result=None)
    captured_kwargs: list[dict[str, Any]] = []

    responses = [
        FakeGenerationResponse(text="ok", token=10, finish_reason="stop"),
    ]

    def fake_stream(model, tokenizer, prompt_ids, **kwargs):
        captured_kwargs.append(kwargs)
        yield from responses

    # Deps with make_prompt_cache=None, trim_prompt_cache=None (defaults)
    deps = GenerationDeps(
        stream_generate=fake_stream,
        make_sampler=lambda **kw: MagicMock(),
    )
    session = _make_fake_session(prefix_cache=fake_cache)
    request = _make_fake_request()
    events = _collect_events(session, request, deps)

    assert events[-1]["kind"] == "completed"
    assert "prompt_cache" not in captured_kwargs[0]
    # No lookup attempted because deps lack helpers
    assert len(fake_cache.lookup_calls) == 0
    assert len(fake_cache.store_calls) == 0


def test_pre_cancel_skips_cache_lookup() -> None:
    """cancel_event already set before generation → no cache work at all."""
    cancel = threading.Event()
    cancel.set()  # pre-cancelled

    fake_cache = FakePrefixCache(lookup_result=None)
    deps, make_mock, _ = _cache_deps([])
    session = _make_fake_session(prefix_cache=fake_cache)
    request = _make_fake_request()
    events = _collect_events(session, request, deps, cancel_event=cancel)

    assert len(events) == 1
    assert events[0]["kind"] == "failed"
    assert events[0]["code"] == "cancelled"
    # No cache interactions at all
    assert len(fake_cache.lookup_calls) == 0
    assert len(fake_cache.store_calls) == 0
    make_mock.assert_not_called()


# --- Store-on-success tests ---


def test_completed_stores_full_sequence_key() -> None:
    """Successful generation stores prompt_ids + generated_token_ids."""
    fake_cache = FakePrefixCache(lookup_result=None)
    responses = [
        FakeGenerationResponse(text="A", token=50),
        FakeGenerationResponse(text="B", token=51),
        FakeGenerationResponse(text="", token=52, finish_reason="stop"),
    ]
    deps, _, _ = _cache_deps(responses)
    session = _make_fake_session(prefix_cache=fake_cache)
    session.tokenizer.encode.return_value = [1, 2, 3]
    request = _make_fake_request()
    events = _collect_events(session, request, deps)

    assert events[-1]["kind"] == "completed"
    assert len(fake_cache.store_calls) == 1
    stored_key, stored_cache = fake_cache.store_calls[0]
    # Key is prompt_ids + generated_token_ids
    assert stored_key == [1, 2, 3, 50, 51, 52]


def test_stop_sequence_terminal_stores() -> None:
    """Stop-sequence match still stores the cache."""
    fake_cache = FakePrefixCache(lookup_result=None)
    responses = [
        FakeGenerationResponse(text="Hello<stop>world", token=50),
    ]
    deps, _, _ = _cache_deps(responses)
    session = _make_fake_session(prefix_cache=fake_cache)
    request = _make_fake_request(stop_sequences=["<stop>"])
    events = _collect_events(session, request, deps)

    assert events[-1]["kind"] == "completed"
    assert events[-1]["finish_reason"] == "FINISH_REASON_STOP"
    assert len(fake_cache.store_calls) == 1


def test_orchard_eos_terminal_stores() -> None:
    """Orchard EOS early termination still stores the cache."""
    fake_cache = FakePrefixCache(lookup_result=None)
    responses = [
        FakeGenerationResponse(text="end", token=999),
    ]
    deps, _, _ = _cache_deps(responses)
    session = _make_fake_session(eos_token_ids=(999,), prefix_cache=fake_cache)
    request = _make_fake_request()
    events = _collect_events(session, request, deps)

    assert events[-1]["kind"] == "completed"
    assert len(fake_cache.store_calls) == 1


def test_iterator_exhaustion_success_stores() -> None:
    """Defensive iterator exhaustion (no finish_reason, no cancel) stores."""
    fake_cache = FakePrefixCache(lookup_result=None)

    def bare_stream(model, tokenizer, prompt_ids, **kwargs):
        yield FakeGenerationResponse(text="hello", token=10)

    deps = GenerationDeps(
        stream_generate=bare_stream,
        make_sampler=lambda **kw: MagicMock(),
        make_prompt_cache=MagicMock(side_effect=lambda m: MagicMock(name="Fresh")),
        trim_prompt_cache=MagicMock(),
    )
    session = _make_fake_session(prefix_cache=fake_cache)
    request = _make_fake_request()
    events = _collect_events(session, request, deps)

    assert events[-1]["kind"] == "completed"
    assert len(fake_cache.store_calls) == 1


# --- No-store tests ---


def test_batch_stop_sequence_rejection_does_not_store() -> None:
    fake_cache = FakePrefixCache(lookup_result=None)
    session = _make_fake_session(prefix_cache=fake_cache)
    session.tokenizer = _ToyTokenizer()

    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
            make_prompt_cache=lambda _model: ["fresh-cache"],
            trim_prompt_cache=lambda cache, _n: cache,
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_StopThenNeverFinishBatchGenerator),
    )

    request = _make_fake_request(input_tokens=3, max_output_tokens=8, stop_sequences=["A"])
    events = list(
        generate_events(session, request, threading.Event(), deps=runtime.generation_deps())
    )

    assert events == [
        {
            "kind": "failed",
            "code": "unsupported_generation_params",
            "message": "stop_sequences are not supported with generation_mode=batch",
            "retryable": False,
        }
    ]
    assert len(fake_cache.store_calls) == 0

    runtime.close()


def test_cancel_does_not_store() -> None:
    """Mid-generation cancel → store never called."""
    cancel = threading.Event()
    fake_cache = FakePrefixCache(lookup_result=None)

    def cancelling_stream(model, tokenizer, prompt_ids, **kwargs):
        yield FakeGenerationResponse(text="first", token=10)
        cancel.set()
        yield FakeGenerationResponse(text="second", token=11)

    deps = GenerationDeps(
        stream_generate=cancelling_stream,
        make_sampler=lambda **kw: MagicMock(),
        make_prompt_cache=MagicMock(side_effect=lambda m: MagicMock()),
        trim_prompt_cache=MagicMock(),
    )
    session = _make_fake_session(prefix_cache=fake_cache)
    request = _make_fake_request()
    events = _collect_events(session, request, deps, cancel_event=cancel)

    assert events[-1]["kind"] == "failed"
    assert events[-1]["code"] == "cancelled"
    assert len(fake_cache.store_calls) == 0


def test_stream_exception_does_not_store() -> None:
    """Stream iterator raises → store never called, exception propagates."""
    fake_cache = FakePrefixCache(lookup_result=None)

    def exploding_stream(model, tokenizer, prompt_ids, **kwargs):
        yield FakeGenerationResponse(text="partial", token=10)
        raise RuntimeError("Metal error")

    deps = GenerationDeps(
        stream_generate=exploding_stream,
        make_sampler=lambda **kw: MagicMock(),
        make_prompt_cache=MagicMock(side_effect=lambda m: MagicMock()),
        trim_prompt_cache=MagicMock(),
    )
    session = _make_fake_session(prefix_cache=fake_cache)
    request = _make_fake_request()

    with pytest.raises(RuntimeError, match="Metal error"):
        _collect_events(session, request, deps)

    assert len(fake_cache.store_calls) == 0


def test_immediate_length_completion_does_not_store() -> None:
    """max_output_tokens <= 0 → no cache prep, no store."""
    fake_cache = FakePrefixCache(lookup_result=None)
    deps, make_mock, _ = _cache_deps([])
    session = _make_fake_session(prefix_cache=fake_cache)
    request = _make_fake_request(max_output_tokens=0)
    events = _collect_events(session, request, deps)

    assert events[-1]["kind"] == "completed"
    assert events[-1]["finish_reason"] == "FINISH_REASON_LENGTH"
    assert len(fake_cache.store_calls) == 0
    assert len(fake_cache.lookup_calls) == 0
    make_mock.assert_not_called()


def test_missing_token_id_disables_store() -> None:
    """A response with token=None disables store for entire request."""
    fake_cache = FakePrefixCache(lookup_result=None)
    responses = [
        FakeGenerationResponse(text="A", token=50),
        FakeGenerationResponse(text="B", token=cast(Any, None)),  # intentionally invalid
        FakeGenerationResponse(text="C", token=52, finish_reason="stop"),
    ]
    deps, _, _ = _cache_deps(responses)
    session = _make_fake_session(prefix_cache=fake_cache)
    request = _make_fake_request()
    events = _collect_events(session, request, deps)

    assert events[-1]["kind"] == "completed"
    assert len(fake_cache.store_calls) == 0


def test_store_failure_is_fail_open() -> None:
    """prefix_cache.store raises → completed event still emitted."""
    fake_cache = FakePrefixCache(
        lookup_result=None,
        store_side_effect=RuntimeError("store boom"),
    )
    responses = [
        FakeGenerationResponse(text="ok", token=10, finish_reason="stop"),
    ]
    deps, _, _ = _cache_deps(responses)
    session = _make_fake_session(prefix_cache=fake_cache)
    request = _make_fake_request()
    events = _collect_events(session, request, deps)

    # completed still emitted despite store failure
    assert events[-1]["kind"] == "completed"
    assert events[-1]["finish_reason"] == "FINISH_REASON_STOP"


# ===========================================================================
# Prefix-cache logging tests (Task 4)
# ===========================================================================


def _parse_cache_log(record: logging.LogRecord) -> dict[str, str]:
    """Parse key=value pairs from a prefix_cache_request log message."""
    msg = record.getMessage()
    if not msg.startswith("prefix_cache_request "):
        return {}
    pairs = msg.split(" ")[1:]  # skip prefix
    result = {}
    for pair in pairs:
        if "=" in pair:
            k, v = pair.split("=", 1)
            result[k] = v
    return result


def _find_cache_log(caplog: pytest.LogCaptureFixture) -> dict[str, str]:
    """Find the single cache log record and parse it."""
    records = [
        r
        for r in caplog.records
        if r.name == "orchard_worker_mlx.generation"
        and r.getMessage().startswith("prefix_cache_request ")
    ]
    assert len(records) == 1, f"Expected 1 cache log, got {len(records)}"
    return _parse_cache_log(records[0])


def test_cache_log_on_completion(caplog: pytest.LogCaptureFixture) -> None:
    """Exactly one cache log on normal completion."""
    responses = [
        FakeGenerationResponse(text="Hi", token=10, finish_reason="stop"),
    ]
    session = _make_fake_session()
    request = _make_fake_request()
    deps = _make_deps(responses)

    with caplog.at_level(logging.INFO, logger="orchard_worker_mlx.generation"):
        _collect_events(session, request, deps)

    log = _find_cache_log(caplog)
    assert log["lookup_status"] == "disabled"
    assert log["store_status"] == "skipped_unavailable"  # no prefix_cache on session
    assert "prompt_tokens" in log
    assert "lookup_ms" in log
    assert "store_ms" in log
    assert "entry_count" in log
    assert "total_bytes" in log


def test_cache_log_on_cancel(caplog: pytest.LogCaptureFixture) -> None:
    """Exactly one cache log on cancellation."""
    cancel = threading.Event()

    def streaming_cancel(model, tokenizer, ids, **kwargs):
        cancel.set()
        yield FakeGenerationResponse(text="a", token=1)

    deps = GenerationDeps(
        stream_generate=streaming_cancel,
        make_sampler=lambda **kw: MagicMock(),
    )
    session = _make_fake_session(decode_cancel_stride=1)
    request = _make_fake_request()

    with caplog.at_level(logging.INFO, logger="orchard_worker_mlx.generation"):
        _collect_events(session, request, deps, cancel_event=cancel)

    log = _find_cache_log(caplog)
    assert log["lookup_status"] == "disabled"
    assert log["store_status"] == "not_attempted"


def test_cache_log_on_stream_exception(caplog: pytest.LogCaptureFixture) -> None:
    """Exactly one cache log when stream raises."""

    def exploding_stream(model, tokenizer, ids, **kwargs):
        raise RuntimeError("metal error")

    deps = GenerationDeps(
        stream_generate=exploding_stream,
        make_sampler=lambda **kw: MagicMock(),
    )
    session = _make_fake_session()
    request = _make_fake_request()

    with caplog.at_level(logging.INFO, logger="orchard_worker_mlx.generation"):
        with pytest.raises(RuntimeError, match="metal error"):
            _collect_events(session, request, deps)

    log = _find_cache_log(caplog)
    assert log["lookup_status"] == "disabled"
    assert log["store_status"] == "not_attempted"


def test_cache_log_with_prefix_cache_hit(caplog: pytest.LogCaptureFixture) -> None:
    """Cache log reports partial_hit when prefix cache matches a prefix."""
    # matched_length=2 < prompt_tokens=3 → partial_hit
    fake_cache = FakePrefixCache(
        lookup_result=FakeCacheHit(
            prompt_cache=MagicMock(),
            matched_length=2,
            remaining_ids=[3, 4],
        )
    )
    responses = [
        FakeGenerationResponse(text="ok", token=10, finish_reason="stop"),
    ]
    deps, _, _ = _cache_deps(responses)
    session = _make_fake_session(prefix_cache=fake_cache)
    request = _make_fake_request()

    with caplog.at_level(logging.INFO, logger="orchard_worker_mlx.generation"):
        _collect_events(session, request, deps)

    log = _find_cache_log(caplog)
    assert log["lookup_status"] == "partial_hit"
    assert log["matched_tokens"] == "2"
    assert log["remaining_tokens"] == "2"


def test_cache_log_with_prefix_cache_miss(caplog: pytest.LogCaptureFixture) -> None:
    """Cache log reports miss when prefix cache has no match."""
    fake_cache = FakePrefixCache(lookup_result=None)
    responses = [
        FakeGenerationResponse(text="ok", token=10, finish_reason="stop"),
    ]
    deps, _, _ = _cache_deps(responses)
    session = _make_fake_session(prefix_cache=fake_cache)
    request = _make_fake_request()

    with caplog.at_level(logging.INFO, logger="orchard_worker_mlx.generation"):
        _collect_events(session, request, deps)

    log = _find_cache_log(caplog)
    assert log["lookup_status"] == "miss"


def test_cache_log_on_early_return_max_tokens_zero(caplog: pytest.LogCaptureFixture) -> None:
    """Cache log emitted even on max_output_tokens=0 early return."""
    session = _make_fake_session()
    request = _make_fake_request(max_output_tokens=0)
    deps = _make_deps([])

    with caplog.at_level(logging.INFO, logger="orchard_worker_mlx.generation"):
        _collect_events(session, request, deps)

    log = _find_cache_log(caplog)
    assert log["lookup_status"] == "disabled"
    assert log["prompt_tokens"] == "0"


def test_cache_log_store_oversize_rejection(caplog: pytest.LogCaptureFixture) -> None:
    """When store() returns False (oversize), log reports skipped_oversize."""
    fake_cache = FakePrefixCache(
        lookup_result=None,
        store_result=False,  # simulate oversize rejection
    )
    responses = [
        FakeGenerationResponse(text="ok", token=10, finish_reason="stop"),
    ]
    deps, _, _ = _cache_deps(responses)
    session = _make_fake_session(prefix_cache=fake_cache)
    request = _make_fake_request()

    with caplog.at_level(logging.INFO, logger="orchard_worker_mlx.generation"):
        events = _collect_events(session, request, deps)

    # Completed event still emitted.
    assert events[-1]["kind"] == "completed"

    log = _find_cache_log(caplog)
    assert log["store_status"] == "skipped_oversize"


def test_cache_log_full_hit(caplog: pytest.LogCaptureFixture) -> None:
    """Cache log reports full_hit when matched_length >= prompt_tokens."""
    # matched_length=3 == prompt_tokens=3 -> full_hit
    fake_cache = FakePrefixCache(
        lookup_result=FakeCacheHit(
            prompt_cache=MagicMock(),
            matched_length=3,
            remaining_ids=[3],
        )
    )
    responses = [
        FakeGenerationResponse(text="ok", token=10, finish_reason="stop"),
    ]
    deps, _, _ = _cache_deps(responses)
    session = _make_fake_session(prefix_cache=fake_cache)
    request = _make_fake_request()

    with caplog.at_level(logging.INFO, logger="orchard_worker_mlx.generation"):
        _collect_events(session, request, deps)

    log = _find_cache_log(caplog)
    assert log["lookup_status"] == "full_hit"
    assert log["matched_tokens"] == "3"
    assert log["remaining_tokens"] == "1"


def test_cache_log_lookup_failed_via_stats_delta(caplog: pytest.LogCaptureFixture) -> None:
    """Cache log reports lookup_failed when stats.failures increases."""
    from orchard_worker_mlx.prefix_cache import PrefixCacheStats

    call_count = 0

    class FailOpenCache:
        """Cache that returns None but increments failures (simulates fail-open)."""

        def lookup(self, token_ids, *, trim_fn):
            return None  # fail-open return

        def store(self, token_ids, prompt_cache):
            return True

        def stats(self):
            nonlocal call_count
            call_count += 1
            # First call (pre-lookup): failures=0
            # Second call (post-lookup): failures=1 -> delta detected
            return PrefixCacheStats(
                implementation="test",
                entry_count=0,
                total_bytes=0,
                hits=0,
                misses=0,
                failures=0 if call_count <= 1 else 1,
                stores=0,
                evictions=0,
            )

    responses = [
        FakeGenerationResponse(text="ok", token=10, finish_reason="stop"),
    ]
    deps, _, _ = _cache_deps(responses)
    session = _make_fake_session(prefix_cache=FailOpenCache())
    request = _make_fake_request()

    with caplog.at_level(logging.INFO, logger="orchard_worker_mlx.generation"):
        _collect_events(session, request, deps)

    log = _find_cache_log(caplog)
    assert log["lookup_status"] == "lookup_failed"
