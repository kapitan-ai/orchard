"""Unit tests for generation.py: real MLX generation logic with fake deps."""

from __future__ import annotations

import gc
import json
import logging
import threading
import time
import weakref
from collections import deque
from collections.abc import Callable
from contextlib import contextmanager
from dataclasses import dataclass
from types import SimpleNamespace
from typing import Any, cast
from unittest.mock import MagicMock

import pytest

from orchard_worker_mlx.backends import BackendError
from orchard_worker_mlx.generation import (
    BatchGenerationDeps,
    BatchGeneratorRuntime,
    GenerationDeps,
    StopSequenceBuffer,
    _build_wired_limit_context,
    _make_prefill_progress_callback,
    _update_session_prefill_workspace_bytes_per_token_high_water,
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


@dataclass
class FakePromptResponse:
    """Minimal stand-in for mlx_lm.generate PromptProcessingBatch.Response."""

    uid: int
    progress: tuple[Any, Any]


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
    memory_budget_status: Any | None = None,
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
    session.memory_budget_status = memory_budget_status or SimpleNamespace(
        budget_available=False,
        target_working_set_bytes=0,
    )
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
    prompt_token_ids: list[int] | None = None,
    return_token_ids: bool = False,
    return_logprobs: bool = False,
) -> Any:
    """Create a minimal fake ExecuteInferenceRequest."""
    request = MagicMock()
    request.rendered_prompt_utf8 = prompt
    request.input_tokens = input_tokens
    request.prompt_token_ids = prompt_token_ids or []
    request.return_token_ids = return_token_ids
    request.return_logprobs = return_logprobs
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
    responses: list[FakeGenerationResponse] | None = None,
    *,
    stream_generate: Any = None,
    make_prompt_cache: Any = None,
    trim_prompt_cache: Any = None,
    synchronize: Callable[[], None] | None = None,
) -> GenerationDeps:
    """Create GenerationDeps that yields the given responses."""
    responses = responses or []

    def fake_stream_generate(model, tokenizer, prompt_ids, **kwargs):
        yield from responses

    def fake_make_sampler(**kwargs):
        return MagicMock(name="FakeSampler")

    return GenerationDeps(
        stream_generate=stream_generate or fake_stream_generate,
        make_sampler=fake_make_sampler,
        make_prompt_cache=make_prompt_cache,
        trim_prompt_cache=trim_prompt_cache,
        synchronize=synchronize,
    )


def _wait_until(predicate: Callable[[], bool], *, timeout_s: float = 1.0) -> bool:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if predicate():
            return True
        threading.Event().wait(0.01)
    return predicate()


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


def _without_usage_events(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [event for event in events if event["kind"] != "usage"]


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


class _InsertProgressOnlyBatchGenerator:
    instances: list[_InsertProgressOnlyBatchGenerator] = []

    def __init__(self, _model: Any, **kwargs: Any) -> None:
        self.constructor_kwargs = kwargs
        self._next_uid = 0
        self._active: list[int] = []
        self.insert_returned_flat_uids = False
        self.__class__.instances.append(self)

    def insert(
        self,
        prompts: list[list[int]],
        max_tokens: list[int],
        caches: list[Any] | None = None,
        samplers: list[Any] | None = None,
        logits_processors: list[Any] | None = None,
        **_kwargs: Any,
    ) -> list[int]:
        del max_tokens, caches, samplers, logits_processors
        uids: list[int] = []
        for _ in prompts:
            uid = self._next_uid
            self._next_uid += 1
            self._active.append(uid)
            uids.append(uid)
        self.insert_returned_flat_uids = True
        return uids

    def next(self) -> tuple[list[Any], list[Any]]:
        prompt_responses = [_prompt_response(999_999, 1, 3)]
        responses = [
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
            for uid in self._active
        ]
        self._active = []
        return (prompt_responses, responses)

    def close(self) -> None:
        return None


def _prompt_response(uid: int, processed: Any = 1, total: Any = 3) -> FakePromptResponse:
    return FakePromptResponse(uid=uid, progress=(processed, total))


def _batch_response(uid: int, *, token: int = 11, finish_reason: str | None = None) -> Any:
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


class _AttributionBatchGenerator:
    progress_by_next_call: list[list[tuple[int, Any, Any]]] = []
    responses_by_next_call: list[list[tuple[int, int, str | None]]] = []
    instances: list[_AttributionBatchGenerator] = []

    def __init__(self, _model: Any, **_kwargs: Any) -> None:
        self._next_uid = 0
        self._active: list[int] = []
        self._next_calls = 0
        self.insert_sizes: list[int] = []
        self.__class__.instances.append(self)

    def insert(
        self,
        prompts: list[list[int]],
        max_tokens: list[int],
        caches: list[Any] | None = None,
        samplers: list[Any] | None = None,
        logits_processors: list[Any] | None = None,
        **_kwargs: Any,
    ) -> list[int]:
        del max_tokens, caches, samplers, logits_processors
        uids: list[int] = []
        for _ in prompts:
            uid = self._next_uid
            self._next_uid += 1
            self._active.append(uid)
            uids.append(uid)
        self.insert_sizes.append(len(prompts))
        return uids

    def next(self) -> tuple[list[Any], list[Any]]:
        call_index = self._next_calls
        self._next_calls += 1

        prompt_responses: list[Any] = []
        if call_index < len(self.progress_by_next_call):
            prompt_responses = [
                _prompt_response(self._active[uid_index], processed, total)
                for uid_index, processed, total in self.progress_by_next_call[call_index]
                if uid_index < len(self._active)
            ]

        if call_index < len(self.responses_by_next_call):
            response_plan = self.responses_by_next_call[call_index]
        else:
            response_plan = [(uid_index, 11, "stop") for uid_index in range(len(self._active))]

        responses: list[Any] = []
        terminal_uids: set[int] = set()
        for uid_index, token, finish_reason in response_plan:
            if uid_index >= len(self._active):
                continue
            uid = self._active[uid_index]
            responses.append(_batch_response(uid, token=token, finish_reason=finish_reason))
            if finish_reason is not None:
                terminal_uids.add(uid)

        self._active = [uid for uid in self._active if uid not in terminal_uids]
        return (prompt_responses, responses)

    def close(self) -> None:
        return None

    @classmethod
    def reset_plan(
        cls,
        *,
        progress_by_next_call: list[list[tuple[int, Any, Any]]] | None = None,
        responses_by_next_call: list[list[tuple[int, int, str | None]]] | None = None,
    ) -> None:
        cls.progress_by_next_call = progress_by_next_call or []
        cls.responses_by_next_call = responses_by_next_call or []
        cls.instances = []


class _FakeBatchGenerator:
    response_includes_logprobs = False

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
        **_kwargs: Any,
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

    def next(self) -> tuple[list[Any], list[Any]]:
        prompt_responses: list[Any] = []
        responses: list[Any] = []
        survivors: list[dict[str, Any]] = []

        for item in self._active:
            uid = item["uid"]
            tokens: list[int] = item["tokens"]
            index = item["index"]

            if not item["progress_emitted"]:
                prompt_responses.append(_prompt_response(uid, 1, 3))
                item["progress_emitted"] = True

            token = tokens[index]
            index += 1
            finish_reason = "stop" if index >= len(tokens) else None
            item["index"] = index

            cache_snapshot = [f"cache-{uid}"]
            attrs = {
                "uid": uid,
                "token": token,
                "finish_reason": finish_reason,
                "prompt_cache": (lambda snap=cache_snapshot: snap),
            }
            if self.response_includes_logprobs:
                logprobs = [0.0] * 32
                logprobs[token] = token / 100.0
                attrs["logprobs"] = logprobs
            responses.append(type("BatchResp", (), attrs)())

            if finish_reason is None:
                survivors.append(item)

        self._active = survivors
        return (prompt_responses, responses)

    def close(self) -> None:
        return None


def _make_memory_budget_status(prefill_workspace_bytes_per_token: int = 0) -> Any:
    from orchard_worker_mlx.model_loader import MemoryBudgetStatus

    return MemoryBudgetStatus(
        mode="observe",
        budget_available=True,
        headroom_available=True,
        status_code="ok",
        status_message="",
        source="seed",
        max_recommended_working_set_size_bytes=8_000_000_000,
        utilization=0.75,
        target_working_set_bytes=6_000_000_000,
        overhead_bytes=268_435_456,
        resident_memory_bytes=2_048_000,
        estimated_headroom_bytes=5_731_516_544,
        kv_cache_bytes_per_token=16_384,
        prefill_workspace_bytes_per_token=prefill_workspace_bytes_per_token,
    )


def _make_attribution_runtime(
    session: Any,
    *,
    memory_probe: Callable[[], Any] | None,
    batch_generator_cls: type = _AttributionBatchGenerator,
) -> BatchGeneratorRuntime:
    return BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
            current_memory_bytes=memory_probe,
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=batch_generator_cls),
    )


def _queue_batch_stream(runtime: BatchGeneratorRuntime, prompt_ids: list[int]) -> Any:
    return runtime.stream_generate(
        runtime._session.model,
        runtime.tokenizer,
        prompt_ids,
        max_tokens=2,
        sampler=MagicMock(),
        prompt_progress_callback=lambda _processed, _total: None,
    )


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


class _LogprobsBatchGenerator(_FakeBatchGenerator):
    response_includes_logprobs = True


def test_batch_pre_cancelled_request_does_not_enter_runtime_or_affect_peer() -> None:
    """Issue #409: pre-cancelled work leaves a batch peer and runtime state isolated."""
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
    cancelled = threading.Event()
    cancelled.set()

    try:
        cancelled_events = list(
            generate_events(
                session,
                _make_fake_request(input_tokens=3, max_output_tokens=2),
                cancelled,
                deps=runtime.generation_deps(),
            )
        )
        assert runtime._next_request_id == 0
        assert runtime._requests_by_id == {}
        assert runtime._active_by_uid == {}

        peer_events = list(
            generate_events(
                session,
                _make_fake_request(input_tokens=3, max_output_tokens=2),
                threading.Event(),
                deps=runtime.generation_deps(),
            )
        )
        assert runtime._next_request_id == 1
        assert runtime._requests_by_id == {}
        assert runtime._active_by_uid == {}
    finally:
        runtime.close()

    assert cancelled_events == [
        {
            "kind": "failed",
            "code": "cancelled",
            "message": "request cancelled",
            "retryable": False,
        }
    ]
    assert [event["delta"] for event in peer_events if event["kind"] == "output_text_delta"] == [
        "A",
        "B",
    ]
    assert [event["kind"] for event in peer_events].count("completed") == 1
    assert peer_events[-1]["usage"]["output_tokens"] == 2


def test_batch_generator_runtime_opt_in_off_emits_no_token_delta_events() -> None:
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

    assert [event["kind"] for event in events].count("token_delta") == 0


def test_batch_generator_runtime_return_token_ids_emits_ordered_token_deltas() -> None:
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
    request = _make_fake_request(
        input_tokens=3,
        max_output_tokens=2,
        return_token_ids=True,
    )

    try:
        events = _collect_events(session, request, runtime.generation_deps())
    finally:
        runtime.close()

    token_deltas = [event for event in events if event["kind"] == "token_delta"]
    assert [event["token_ids"] for event in token_deltas] == [[11], [12]]
    assert [event.get("logprobs", []) for event in token_deltas] == [[], []]


def test_batch_generator_runtime_return_logprobs_aligns_with_token_ids() -> None:
    session = _make_fake_session()
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_LogprobsBatchGenerator),
    )
    request = _make_fake_request(
        input_tokens=3,
        max_output_tokens=2,
        return_logprobs=True,
    )

    try:
        events = _collect_events(session, request, runtime.generation_deps())
    finally:
        runtime.close()

    token_deltas = [event for event in events if event["kind"] == "token_delta"]
    assert [event["token_ids"] for event in token_deltas] == [[11], [12]]
    assert [event["logprobs"] for event in token_deltas] == [[0.11], [0.12]]


def test_batch_generator_runtime_missing_logprobs_fail_open() -> None:
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
    request = _make_fake_request(
        input_tokens=3,
        max_output_tokens=2,
        return_logprobs=True,
    )

    try:
        events = _collect_events(session, request, runtime.generation_deps())
    finally:
        runtime.close()

    token_deltas = [event for event in events if event["kind"] == "token_delta"]
    assert [event["token_ids"] for event in token_deltas] == [[11], [12]]
    assert [event.get("logprobs", []) for event in token_deltas] == [[], []]
    assert events[-1]["kind"] == "completed"


def test_batch_generator_runtime_emits_no_token_delta_after_terminal() -> None:
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
    request = _make_fake_request(
        input_tokens=3,
        max_output_tokens=2,
        return_token_ids=True,
    )

    try:
        events = _collect_events(session, request, runtime.generation_deps())
    finally:
        runtime.close()

    terminal_index = next(
        index for index, event in enumerate(events) if event["kind"] == "completed"
    )
    assert all(event["kind"] != "token_delta" for event in events[terminal_index + 1 :])


def test_batch_generator_runtime_realigns_row_state_before_next() -> None:
    class _MisalignedRowStateBatchGenerator:
        instances: list[_MisalignedRowStateBatchGenerator] = []

        def __init__(self, _model: Any, **_kwargs: Any) -> None:
            self._next_uid = 0
            self._next_calls = 0
            self.samplers_by_uid: dict[int, Any] = {}
            self._generation_batch = SimpleNamespace(uids=[], samplers=[], logits_processors=[])
            self.captured_rows: list[tuple[list[Any], list[Any]]] = []
            self.__class__.instances.append(self)

        def insert(
            self,
            prompts: list[list[int]],
            max_tokens: list[int],
            caches: list[Any] | None = None,
            samplers: list[Any] | None = None,
            logits_processors: list[Any] | None = None,
            **_kwargs: Any,
        ) -> list[int]:
            del prompts, max_tokens, caches, logits_processors
            inserted_samplers = samplers or []
            uids = list(range(self._next_uid, self._next_uid + len(inserted_samplers)))
            self._next_uid += len(inserted_samplers)
            for uid, sampler in zip(uids, inserted_samplers, strict=True):
                self.samplers_by_uid[uid] = sampler

            if uids == [0]:
                self._generation_batch.uids = [0]
                self._generation_batch.samplers = [self.samplers_by_uid[0]]
                self._generation_batch.logits_processors = [[]]
            elif uids == [1]:
                self._generation_batch.uids = [0, 1]
                self._generation_batch.samplers = [
                    self.samplers_by_uid[1],
                    self.samplers_by_uid[0],
                ]
                self._generation_batch.logits_processors = [None, ["stale"]]

            return uids

        def next(self) -> tuple[list[Any], list[Any]]:
            self._next_calls += 1
            self.captured_rows.append(
                (
                    list(self._generation_batch.samplers),
                    list(self._generation_batch.logits_processors),
                )
            )
            if self._next_calls == 1:
                return ([], [_batch_response(0, token=11, finish_reason=None)])
            if self._generation_batch.uids != [0, 1]:
                return ([], [])
            return (
                [],
                [
                    _batch_response(0, token=12, finish_reason="stop"),
                    _batch_response(1, token=21, finish_reason="stop"),
                ],
            )

        def close(self) -> None:
            return None

    session = _make_fake_session()
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_MisalignedRowStateBatchGenerator),
    )
    sampler_a = object()
    sampler_b = object()

    try:
        stream_a = runtime.stream_generate(
            session.model,
            session.tokenizer,
            [1, 2, 3],
            max_tokens=2,
            sampler=sampler_a,
        )
        assert next(stream_a).text == "A"
        stream_b = runtime.stream_generate(
            session.model,
            session.tokenizer,
            [4, 5, 6],
            max_tokens=1,
            sampler=sampler_b,
        )
        assert [chunk.text for chunk in stream_b] == ["X"]
        assert [chunk.text for chunk in stream_a] == ["B"]
        generator = _MisalignedRowStateBatchGenerator.instances[0]
    finally:
        runtime.close()

    assert generator.captured_rows[-1] == ([sampler_a, sampler_b], [[], []])


def test_batch_generator_runtime_row_realign_fail_open_without_uids() -> None:
    class _NoUidBatchGenerator:
        def __init__(self, _model: Any, **_kwargs: Any) -> None:
            self._next_uid = 0
            self._generation_batch = SimpleNamespace(samplers=[object()])

        def insert(
            self,
            prompts: list[list[int]],
            max_tokens: list[int],
            caches: list[Any] | None = None,
            samplers: list[Any] | None = None,
            logits_processors: list[Any] | None = None,
            **_kwargs: Any,
        ) -> list[int]:
            del max_tokens, caches, samplers, logits_processors
            uids = list(range(self._next_uid, self._next_uid + len(prompts)))
            self._next_uid += len(prompts)
            return uids

        def next(self) -> tuple[list[Any], list[Any]]:
            return ([], [_batch_response(0, token=11, finish_reason="stop")])

        def close(self) -> None:
            return None

    session = _make_fake_session()
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_NoUidBatchGenerator),
    )

    try:
        events = _collect_events(
            session, _make_fake_request(max_output_tokens=1), runtime.generation_deps()
        )
    finally:
        runtime.close()

    assert [event["kind"] for event in _without_usage_events(events)] == [
        "output_text_delta",
        "completed",
    ]


def test_batch_generator_runtime_row_realign_keeps_unregistered_uid_slot() -> None:
    class _UnregisteredUidBatchGenerator:
        instances: list[_UnregisteredUidBatchGenerator] = []

        def __init__(self, _model: Any, **_kwargs: Any) -> None:
            self.extra_sampler = object()
            self.extra_processors = [object()]
            self._generation_batch = SimpleNamespace(uids=[], samplers=[], logits_processors=[])
            self.captured_samplers: list[Any] = []
            self.captured_processors: list[Any] = []
            self.__class__.instances.append(self)

        def insert(
            self,
            prompts: list[list[int]],
            max_tokens: list[int],
            caches: list[Any] | None = None,
            samplers: list[Any] | None = None,
            logits_processors: list[Any] | None = None,
            **_kwargs: Any,
        ) -> list[int]:
            del prompts, max_tokens, caches, logits_processors
            sampler = (samplers or [None])[0]
            self._generation_batch.uids = [0, 999]
            self._generation_batch.samplers = [object(), self.extra_sampler]
            self._generation_batch.logits_processors = [None, self.extra_processors]
            self.registered_sampler = sampler
            return [0]

        def next(self) -> tuple[list[Any], list[Any]]:
            self.captured_samplers = list(self._generation_batch.samplers)
            self.captured_processors = list(self._generation_batch.logits_processors)
            return ([], [_batch_response(0, token=11, finish_reason="stop")])

        def close(self) -> None:
            return None

    session = _make_fake_session()
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_UnregisteredUidBatchGenerator),
    )
    sampler = object()

    try:
        stream = runtime.stream_generate(
            session.model,
            session.tokenizer,
            [1, 2, 3],
            max_tokens=1,
            sampler=sampler,
        )
        assert [chunk.text for chunk in stream] == ["A"]
        generator = _UnregisteredUidBatchGenerator.instances[0]
    finally:
        runtime.close()

    assert generator.captured_samplers == [sampler, generator.extra_sampler]
    assert generator.captured_processors == [[], generator.extra_processors]


def test_batch_generator_runtime_row_drift_warning_fires_once(
    caplog: pytest.LogCaptureFixture,
) -> None:
    class _RepeatedDriftBatchGenerator:
        def __init__(self, _model: Any, **_kwargs: Any) -> None:
            self._next_calls = 0
            self.wrong_sampler = object()
            self._generation_batch = SimpleNamespace(uids=[], samplers=[], logits_processors=[])

        def insert(
            self,
            prompts: list[list[int]],
            max_tokens: list[int],
            caches: list[Any] | None = None,
            samplers: list[Any] | None = None,
            logits_processors: list[Any] | None = None,
            **_kwargs: Any,
        ) -> list[int]:
            del prompts, max_tokens, caches, logits_processors
            self._generation_batch.uids = [0]
            self._generation_batch.samplers = [self.wrong_sampler]
            self._generation_batch.logits_processors = [None]
            return [0]

        def next(self) -> tuple[list[Any], list[Any]]:
            self._next_calls += 1
            self._generation_batch.samplers = [self.wrong_sampler]
            self._generation_batch.logits_processors = [None]
            if self._next_calls == 1:
                return ([], [_batch_response(0, token=11, finish_reason=None)])
            return ([], [_batch_response(0, token=12, finish_reason="stop")])

        def close(self) -> None:
            return None

    session = _make_fake_session()
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_RepeatedDriftBatchGenerator),
    )

    try:
        with caplog.at_level(logging.WARNING, logger="orchard_worker_mlx.generation"):
            events = _collect_events(
                session,
                _make_fake_request(max_output_tokens=2),
                runtime.generation_deps(),
            )
    finally:
        runtime.close()

    assert [event["kind"] for event in _without_usage_events(events)] == [
        "output_text_delta",
        "output_text_delta",
        "completed",
    ]
    warning_records = [
        record
        for record in caplog.records
        if record.levelno == logging.WARNING
        and "positional row state drifted" in record.getMessage()
    ]
    assert len(warning_records) == 1


def test_batch_generator_runtime_builds_batch_generator_with_0_31_3_contract() -> None:
    _InsertProgressOnlyBatchGenerator.instances = []
    session = _make_fake_session(eos_token_ids=(12, 13), prefill_step_size=4096)
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_InsertProgressOnlyBatchGenerator),
    )

    request = _make_fake_request(input_tokens=3, max_output_tokens=1)

    try:
        events = _collect_events(session, request, runtime.generation_deps())
    finally:
        runtime.close()

    generator = _InsertProgressOnlyBatchGenerator.instances[0]
    assert generator.constructor_kwargs["stop_tokens"] == [[12], [13]]
    assert generator.constructor_kwargs["prefill_step_size"] == 4096
    assert "prompt_progress_callback" not in generator.constructor_kwargs
    assert generator.insert_returned_flat_uids is True
    assert [event["kind"] for event in _without_usage_events(events)] == [
        "output_text_delta",
        "completed",
    ]


def test_batch_generator_runtime_uses_none_stop_tokens_when_session_has_no_eos() -> None:
    _InsertProgressOnlyBatchGenerator.instances = []
    session = _make_fake_session(eos_token_ids=())
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_InsertProgressOnlyBatchGenerator),
    )

    try:
        _collect_events(session, _make_fake_request(), runtime.generation_deps())
    finally:
        runtime.close()

    assert _InsertProgressOnlyBatchGenerator.instances[0].constructor_kwargs["stop_tokens"] is None


def test_batch_prefill_attribution_updates_memory_budget_from_shared_runtime() -> None:
    _AttributionBatchGenerator.reset_plan(
        progress_by_next_call=[[(0, 10, 100)]],
        responses_by_next_call=[[(0, 11, "stop")]],
    )
    memory_samples = iter([1_000, 5_000])
    session = _make_fake_session(memory_budget_status=_make_memory_budget_status())
    session.tokenizer = _ToyTokenizer()
    runtime = _make_attribution_runtime(session, memory_probe=lambda: next(memory_samples))

    try:
        events = _collect_events(session, _make_fake_request(), runtime.generation_deps())
    finally:
        runtime.close()

    assert [event["kind"] for event in _without_usage_events(events)] == [
        "progress",
        "output_text_delta",
        "completed",
    ]
    assert session.memory_budget_status.prefill_workspace_bytes_per_token == 400
    assert runtime._prefill_attribution_by_insert_set_id == {}


def test_batch_prefill_attribution_is_high_water_only() -> None:
    _AttributionBatchGenerator.reset_plan(
        progress_by_next_call=[[(0, 10, 100)]],
        responses_by_next_call=[[(0, 11, "stop")]],
    )
    memory_samples = iter([1_000, 3_000])
    session = _make_fake_session(memory_budget_status=_make_memory_budget_status(500))
    session.tokenizer = _ToyTokenizer()
    runtime = _make_attribution_runtime(session, memory_probe=lambda: next(memory_samples))

    try:
        events = _collect_events(session, _make_fake_request(), runtime.generation_deps())
    finally:
        runtime.close()

    assert events[-1]["kind"] == "completed"
    assert session.memory_budget_status.prefill_workspace_bytes_per_token == 500
    assert runtime._prefill_attribution_by_insert_set_id == {}


@pytest.mark.parametrize(
    ("samples", "expected_calls"),
    [
        ([None], 1),
        ([True], 1),
        (["bad"], 1),
        ([-1], 1),
        ([1_000, None], 2),
        ([1_000, True], 2),
        ([1_000, "bad"], 2),
        ([1_000, -1], 2),
        ([5_000, 1_000], 2),
    ],
)
def test_batch_prefill_attribution_invalid_probe_values_fail_open(
    samples: list[Any],
    expected_calls: int,
) -> None:
    _AttributionBatchGenerator.reset_plan(
        progress_by_next_call=[[(0, 10, 100)]],
        responses_by_next_call=[[(0, 11, "stop")]],
    )
    calls = 0
    sample_iter = iter(samples)

    def memory_probe() -> Any:
        nonlocal calls
        calls += 1
        return next(sample_iter)

    session = _make_fake_session(memory_budget_status=_make_memory_budget_status(123))
    session.tokenizer = _ToyTokenizer()
    runtime = _make_attribution_runtime(session, memory_probe=memory_probe)

    try:
        events = _collect_events(session, _make_fake_request(), runtime.generation_deps())
    finally:
        runtime.close()

    assert events[-1]["kind"] == "completed"
    assert calls == expected_calls
    assert session.memory_budget_status.prefill_workspace_bytes_per_token == 123
    assert runtime._prefill_attribution_by_insert_set_id == {}


@pytest.mark.parametrize("raise_on_call", [1, 2])
def test_batch_prefill_attribution_probe_exceptions_fail_open(raise_on_call: int) -> None:
    _AttributionBatchGenerator.reset_plan(
        progress_by_next_call=[[(0, 10, 100)]],
        responses_by_next_call=[[(0, 11, "stop")]],
    )
    calls = 0

    def memory_probe() -> int:
        nonlocal calls
        calls += 1
        if calls == raise_on_call:
            raise RuntimeError("probe boom")
        return 1_000 if calls == 1 else 5_000

    session = _make_fake_session(memory_budget_status=_make_memory_budget_status(123))
    session.tokenizer = _ToyTokenizer()
    runtime = _make_attribution_runtime(session, memory_probe=memory_probe)

    try:
        events = _collect_events(session, _make_fake_request(), runtime.generation_deps())
    finally:
        runtime.close()

    assert events[-1]["kind"] == "completed"
    assert session.memory_budget_status.prefill_workspace_bytes_per_token == 123
    assert runtime._prefill_attribution_by_insert_set_id == {}


def test_batch_prefill_attribution_sanitizes_denominator_without_changing_progress_bridge() -> None:
    _AttributionBatchGenerator.reset_plan(
        progress_by_next_call=[
            [
                (0, 0, 100),
                (0, 8, 6),
                (0, 7, 20),
                (0, 7, 20),
                (0, 5, 20),
                (0, 10, 20),
            ]
        ],
        responses_by_next_call=[[(0, 11, "stop")]],
    )
    memory_samples = iter([1_000, 5_000])
    session = _make_fake_session(memory_budget_status=_make_memory_budget_status())
    session.tokenizer = _ToyTokenizer()
    runtime = _make_attribution_runtime(session, memory_probe=lambda: next(memory_samples))

    try:
        events = _collect_events(session, _make_fake_request(), runtime.generation_deps())
    finally:
        runtime.close()

    progress_messages = [event["message"] for event in events if event["kind"] == "progress"]
    assert progress_messages == [
        "processed 6/6 prompt tokens",
        "processed 7/20 prompt tokens",
        "processed 10/20 prompt tokens",
    ]
    assert session.memory_budget_status.prefill_workspace_bytes_per_token == 400
    assert runtime._prefill_attribution_by_insert_set_id == {}


def test_batch_prefill_progress_monotonic_after_queue_drain() -> None:
    _AttributionBatchGenerator.reset_plan(
        progress_by_next_call=[
            [(0, 10, 100)],
            [(0, 10, 100), (0, 9, 100), (0, 20, 100)],
        ],
        responses_by_next_call=[[(0, 11, None)], [(0, 12, "stop")]],
    )
    memory_samples = iter([1_000, 2_000])
    session = _make_fake_session(memory_budget_status=_make_memory_budget_status())
    session.tokenizer = _ToyTokenizer()
    runtime = _make_attribution_runtime(session, memory_probe=lambda: next(memory_samples))

    try:
        events = _collect_events(session, _make_fake_request(), runtime.generation_deps())
    finally:
        runtime.close()

    progress_messages = [event["message"] for event in events if event["kind"] == "progress"]
    assert progress_messages == [
        "processed 10/100 prompt tokens",
        "processed 20/100 prompt tokens",
    ]


def test_batch_prefill_attribution_finalizes_once_per_insert_set() -> None:
    _AttributionBatchGenerator.reset_plan(
        progress_by_next_call=[[(0, 10, 100)], []],
        responses_by_next_call=[[(0, 11, None)], [(0, 12, "stop")]],
    )
    samples = [1_000, 5_000]
    calls = 0

    def memory_probe() -> int:
        nonlocal calls
        calls += 1
        return samples[calls - 1]

    session = _make_fake_session(memory_budget_status=_make_memory_budget_status())
    session.tokenizer = _ToyTokenizer()
    runtime = _make_attribution_runtime(session, memory_probe=memory_probe)

    try:
        events = _collect_events(session, _make_fake_request(), runtime.generation_deps())
    finally:
        runtime.close()

    assert [event["kind"] for event in _without_usage_events(events)] == [
        "progress",
        "output_text_delta",
        "output_text_delta",
        "completed",
    ]
    assert calls == 2
    assert session.memory_budget_status.prefill_workspace_bytes_per_token == 400
    assert runtime._prefill_attribution_by_insert_set_id == {}


def test_batch_prefill_attribution_uses_one_update_for_multi_member_insert_set(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _AttributionBatchGenerator.reset_plan(
        progress_by_next_call=[[(0, 10, 100), (1, 20, 100)]],
        responses_by_next_call=[[(0, 11, "stop"), (1, 21, "stop")]],
    )
    samples = [1_000, 7_000]
    calls = 0

    def memory_probe() -> int:
        nonlocal calls
        calls += 1
        return samples[calls - 1]

    delayed_pumps: list[threading.Thread] = []
    original_start = threading.Thread.start

    def delay_pump_start(thread: threading.Thread) -> None:
        if thread.name == "mlx-batch-generator":
            delayed_pumps.append(thread)
            return
        original_start(thread)

    monkeypatch.setattr(threading.Thread, "start", delay_pump_start)

    session = _make_fake_session(memory_budget_status=_make_memory_budget_status())
    session.tokenizer = _ToyTokenizer()
    runtime = _make_attribution_runtime(session, memory_probe=memory_probe)

    try:
        stream_a = _queue_batch_stream(runtime, [1, 2, 3])
        stream_b = _queue_batch_stream(runtime, [4, 5, 6])
        assert delayed_pumps
        original_start(delayed_pumps[0])

        assert [chunk.text for chunk in stream_a] == ["A"]
        assert [chunk.text for chunk in stream_b] == ["X"]
    finally:
        runtime.close()

    assert _AttributionBatchGenerator.instances[0].insert_sizes == [2]
    assert calls == 2
    assert session.memory_budget_status.prefill_workspace_bytes_per_token == 300
    assert runtime._prefill_attribution_by_insert_set_id == {}


def test_batch_prefill_attribution_finalize_runs_after_notify() -> None:
    _AttributionBatchGenerator.reset_plan(
        progress_by_next_call=[[(0, 10, 100)]],
        responses_by_next_call=[[(0, 11, "stop")]],
    )
    final_probe_entered = threading.Event()
    release_final_probe = threading.Event()
    calls = 0

    def memory_probe() -> int:
        nonlocal calls
        calls += 1
        if calls == 1:
            return 1_000
        final_probe_entered.set()
        release_final_probe.wait(timeout=5.0)
        return 5_000

    session = _make_fake_session(memory_budget_status=_make_memory_budget_status())
    session.tokenizer = _ToyTokenizer()
    runtime = _make_attribution_runtime(session, memory_probe=memory_probe)
    events: list[dict[str, Any]] = []

    def run_request() -> None:
        events.extend(_collect_events(session, _make_fake_request(), runtime.generation_deps()))

    thread = threading.Thread(target=run_request)
    thread.start()

    try:
        assert final_probe_entered.wait(timeout=2.0)
        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline:
            if events and events[-1]["kind"] == "completed":
                break
            threading.Event().wait(0.01)
        assert [event["kind"] for event in _without_usage_events(events)] == [
            "progress",
            "output_text_delta",
            "completed",
        ]
        release_final_probe.set()
        thread.join(timeout=2.0)
    finally:
        release_final_probe.set()
        runtime.close()
        thread.join(timeout=2.0)

    assert thread.is_alive() is False
    assert session.memory_budget_status.prefill_workspace_bytes_per_token == 400
    assert runtime._prefill_attribution_by_insert_set_id == {}


def test_batch_prefill_attribution_interleaved_insert_sets_do_not_bleed() -> None:
    class _InterleavedInsertSetBatchGenerator:
        def __init__(self, _model: Any, **_kwargs: Any) -> None:
            self._next_uid = 0
            self._active: list[int] = []
            self._next_calls = 0
            self.insert_sizes: list[int] = []

        def insert(
            self,
            prompts: list[list[int]],
            max_tokens: list[int],
            caches: list[Any] | None = None,
            samplers: list[Any] | None = None,
            logits_processors: list[Any] | None = None,
            **_kwargs: Any,
        ) -> list[int]:
            del max_tokens, caches, samplers, logits_processors
            uids: list[int] = []
            for _ in prompts:
                uid = self._next_uid
                self._next_uid += 1
                self._active.append(uid)
                uids.append(uid)
            self.insert_sizes.append(len(prompts))
            return uids

        def next(self) -> tuple[list[Any], list[Any]]:
            self._next_calls += 1
            if self._next_calls == 1:
                return (
                    [_prompt_response(self._active[0], 10, 100)],
                    [_batch_response(self._active[0], token=11, finish_reason=None)],
                )

            if len(self._active) < 2:
                threading.Event().wait(0.01)
                return ([], [])
            prompt_responses = [_prompt_response(self._active[1], 20, 100)]
            responses = [
                _batch_response(self._active[0], token=12, finish_reason="stop"),
                _batch_response(self._active[1], token=21, finish_reason="stop"),
            ]
            self._active = []
            return (prompt_responses, responses)

        def close(self) -> None:
            return None

    samples = [1_000, 3_000, 5_000, 11_000]
    calls = 0

    def memory_probe() -> int:
        nonlocal calls
        calls += 1
        return samples[calls - 1]

    session = _make_fake_session(memory_budget_status=_make_memory_budget_status())
    session.tokenizer = _ToyTokenizer()
    runtime = _make_attribution_runtime(
        session,
        memory_probe=memory_probe,
        batch_generator_cls=_InterleavedInsertSetBatchGenerator,
    )

    try:
        stream_a = _queue_batch_stream(runtime, [1, 2, 3])
        assert next(stream_a).text == "A"
        stream_b = _queue_batch_stream(runtime, [4, 5, 6])
        assert [chunk.text for chunk in stream_b] == ["X"]
        assert [chunk.text for chunk in stream_a] == ["B"]
        generator = cast(_InterleavedInsertSetBatchGenerator, runtime._batch_generator)
    finally:
        runtime.close()

    assert generator.insert_sizes == [1, 1]
    assert calls == 4
    assert session.memory_budget_status.prefill_workspace_bytes_per_token == 300
    assert runtime._prefill_attribution_by_insert_set_id == {}


def test_batch_prefill_attribution_runtime_close_clears_insert_set_state() -> None:
    class _BlockForeverAfterProgressBatchGenerator:
        instances: list[_BlockForeverAfterProgressBatchGenerator] = []

        def __init__(self, _model: Any, **_kwargs: Any) -> None:
            self._next_uid = 0
            self._active: list[int] = []
            self.progress_emitted = threading.Event()
            self.closed = threading.Event()
            self.__class__.instances.append(self)

        def insert(
            self,
            prompts: list[list[int]],
            max_tokens: list[int],
            caches: list[Any] | None = None,
            samplers: list[Any] | None = None,
            logits_processors: list[Any] | None = None,
            **_kwargs: Any,
        ) -> list[int]:
            del max_tokens, caches, samplers, logits_processors
            uids: list[int] = []
            for _ in prompts:
                uid = self._next_uid
                self._next_uid += 1
                self._active.append(uid)
                uids.append(uid)
            return uids

        def next(self) -> tuple[list[Any], list[Any]]:
            prompt_responses: list[Any] = []
            if self._active and not self.progress_emitted.is_set():
                prompt_responses = [_prompt_response(self._active[0], 10, 100)]
                self.progress_emitted.set()
            self.closed.wait(timeout=5.0)
            return (prompt_responses, [])

        def close(self) -> None:
            self.closed.set()

    session = _make_fake_session(memory_budget_status=_make_memory_budget_status())
    session.tokenizer = _ToyTokenizer()
    runtime = _make_attribution_runtime(
        session,
        memory_probe=lambda: 1_000,
        batch_generator_cls=_BlockForeverAfterProgressBatchGenerator,
    )
    errors: list[BackendError] = []

    def run_request() -> None:
        try:
            list(
                generate_events(
                    session, _make_fake_request(), threading.Event(), deps=runtime.generation_deps()
                )
            )
        except BackendError as exc:
            errors.append(exc)

    thread = threading.Thread(target=run_request)
    thread.start()
    generator = _BlockForeverAfterProgressBatchGenerator.instances[0]
    assert generator.progress_emitted.wait(timeout=2.0)

    runtime.close()
    thread.join(timeout=2.0)

    assert thread.is_alive() is False
    assert errors
    assert errors[0].code == "generation_failed"
    assert runtime._prefill_attribution_by_insert_set_id == {}


def test_batch_prefill_attribution_mark_all_failed_clears_insert_set_state() -> None:
    class _RaiseAfterProgressBatchGenerator:
        def __init__(self, _model: Any, **_kwargs: Any) -> None:
            self._next_uid = 0
            self._active: list[int] = []
            self._next_calls = 0

        def insert(
            self,
            prompts: list[list[int]],
            max_tokens: list[int],
            caches: list[Any] | None = None,
            samplers: list[Any] | None = None,
            logits_processors: list[Any] | None = None,
            **_kwargs: Any,
        ) -> list[int]:
            del max_tokens, caches, samplers, logits_processors
            uids = list(range(self._next_uid, self._next_uid + len(prompts)))
            self._next_uid += len(prompts)
            self._active.extend(uids)
            return uids

        def next(self) -> tuple[list[Any], list[Any]]:
            self._next_calls += 1
            if self._next_calls == 1:
                return ([_prompt_response(self._active[0], 10, 100)], [])
            raise RuntimeError("next boom")

        def close(self) -> None:
            return None

    session = _make_fake_session(memory_budget_status=_make_memory_budget_status(123))
    session.tokenizer = _ToyTokenizer()
    runtime = _make_attribution_runtime(
        session,
        memory_probe=lambda: 1_000,
        batch_generator_cls=_RaiseAfterProgressBatchGenerator,
    )

    try:
        with pytest.raises(BackendError) as exc_info:
            _collect_events(session, _make_fake_request(), runtime.generation_deps())
    finally:
        runtime.close()

    assert exc_info.value.code == "generation_failed"
    assert session.memory_budget_status.prefill_workspace_bytes_per_token == 123
    assert runtime._prefill_attribution_by_insert_set_id == {}


def test_batch_prefill_attribution_fail_active_request_clears_insert_set_state() -> None:
    class _BadTokenAfterProgressBatchGenerator:
        def __init__(self, _model: Any, **_kwargs: Any) -> None:
            self._next_uid = 0
            self._active: list[int] = []

        def insert(
            self,
            prompts: list[list[int]],
            max_tokens: list[int],
            caches: list[Any] | None = None,
            samplers: list[Any] | None = None,
            logits_processors: list[Any] | None = None,
            **_kwargs: Any,
        ) -> list[int]:
            del max_tokens, caches, samplers, logits_processors
            uids = list(range(self._next_uid, self._next_uid + len(prompts)))
            self._next_uid += len(prompts)
            self._active.extend(uids)
            return uids

        def next(self) -> tuple[list[Any], list[Any]]:
            return (
                [_prompt_response(self._active[0], 10, 100)],
                [
                    type(
                        "BadResp",
                        (),
                        {"uid": self._active[0], "token": "bad", "finish_reason": None},
                    )()
                ],
            )

        def close(self) -> None:
            return None

    session = _make_fake_session(memory_budget_status=_make_memory_budget_status(123))
    session.tokenizer = _ToyTokenizer()
    runtime = _make_attribution_runtime(
        session,
        memory_probe=lambda: 1_000,
        batch_generator_cls=_BadTokenAfterProgressBatchGenerator,
    )

    try:
        with pytest.raises(BackendError) as exc_info:
            _collect_events(session, _make_fake_request(), runtime.generation_deps())
    finally:
        runtime.close()

    assert exc_info.value.code == "generation_failed"
    assert session.memory_budget_status.prefill_workspace_bytes_per_token == 123
    assert runtime._prefill_attribution_by_insert_set_id == {}


def test_batch_prefill_attribution_reset_during_insert_does_not_bind_stale_state() -> None:
    class _BlockingInsertBatchGenerator:
        instances: list[_BlockingInsertBatchGenerator] = []

        def __init__(self, _model: Any, **_kwargs: Any) -> None:
            self.insert_started = threading.Event()
            self.release_insert = threading.Event()
            self._next_uid = 0
            self.__class__.instances.append(self)

        def insert(
            self,
            prompts: list[list[int]],
            max_tokens: list[int],
            caches: list[Any] | None = None,
            samplers: list[Any] | None = None,
            logits_processors: list[Any] | None = None,
            **_kwargs: Any,
        ) -> list[int]:
            del max_tokens, caches, samplers, logits_processors
            self.insert_started.set()
            self.release_insert.wait(timeout=5.0)
            uids = list(range(self._next_uid, self._next_uid + len(prompts)))
            self._next_uid += len(prompts)
            return uids

        def next(self) -> tuple[list[Any], list[Any]]:
            return ([], [])

        def close(self) -> None:
            self.release_insert.set()

    session = _make_fake_session(memory_budget_status=_make_memory_budget_status(123))
    session.tokenizer = _ToyTokenizer()
    runtime = _make_attribution_runtime(
        session,
        memory_probe=lambda: 1_000,
        batch_generator_cls=_BlockingInsertBatchGenerator,
    )
    errors: list[BackendError] = []

    def run_request() -> None:
        try:
            list(
                generate_events(
                    session,
                    _make_fake_request(),
                    threading.Event(),
                    deps=runtime.generation_deps(),
                )
            )
        except BackendError as exc:
            errors.append(exc)

    thread = threading.Thread(target=run_request)
    thread.start()
    generator = _BlockingInsertBatchGenerator.instances[0]
    assert generator.insert_started.wait(timeout=2.0)

    with runtime._cv:
        stale_generator = runtime._request_reset_locked("test reset during insert")
    assert stale_generator is not None
    stale_generator.close()

    try:
        thread.join(timeout=2.0)
    finally:
        runtime.close()
        thread.join(timeout=2.0)

    assert thread.is_alive() is False
    assert errors
    assert errors[0].code == "generation_failed"
    assert runtime._active_by_uid == {}
    assert runtime._prefill_attribution_by_insert_set_id == {}
    assert session.memory_budget_status.prefill_workspace_bytes_per_token == 123


def test_batch_prefill_attribution_cancel_during_insert_does_not_bind_stale_state() -> None:
    class _BlockingInsertBatchGenerator:
        instances: list[_BlockingInsertBatchGenerator] = []

        def __init__(self, _model: Any, **_kwargs: Any) -> None:
            self.insert_started = threading.Event()
            self.release_insert = threading.Event()
            self._next_uid = 0
            self.__class__.instances.append(self)

        def insert(
            self,
            prompts: list[list[int]],
            max_tokens: list[int],
            caches: list[Any] | None = None,
            samplers: list[Any] | None = None,
            logits_processors: list[Any] | None = None,
            **_kwargs: Any,
        ) -> list[int]:
            del max_tokens, caches, samplers, logits_processors
            self.insert_started.set()
            self.release_insert.wait(timeout=5.0)
            uids = list(range(self._next_uid, self._next_uid + len(prompts)))
            self._next_uid += len(prompts)
            return uids

        def next(self) -> tuple[list[Any], list[Any]]:
            return ([], [])

        def close(self) -> None:
            self.release_insert.set()

    session = _make_fake_session(memory_budget_status=_make_memory_budget_status(123))
    session.tokenizer = _ToyTokenizer()
    runtime = _make_attribution_runtime(
        session,
        memory_probe=lambda: 1_000,
        batch_generator_cls=_BlockingInsertBatchGenerator,
    )

    stream = _queue_batch_stream(runtime, [1, 2, 3])
    generator = _BlockingInsertBatchGenerator.instances[0]
    assert generator.insert_started.wait(timeout=2.0)

    stream.close(cancelled=True)
    generator.release_insert.set()

    deadline = time.monotonic() + 2.0
    try:
        while time.monotonic() < deadline:
            with runtime._cv:
                if (
                    runtime._active_by_uid == {}
                    and runtime._prefill_attribution_by_insert_set_id == {}
                    and runtime._reset_requested is None
                ):
                    break
            threading.Event().wait(0.01)
    finally:
        runtime.close()

    with runtime._cv:
        assert runtime._active_by_uid == {}
        assert runtime._requests_by_id == {}
        assert runtime._prefill_attribution_by_insert_set_id == {}
        assert runtime._reset_requested is None
    assert session.memory_budget_status.prefill_workspace_bytes_per_token == 123


@pytest.mark.parametrize("cancelled", [True, False])
def test_batch_prefill_attribution_detaches_closed_member_before_finalize(
    monkeypatch: pytest.MonkeyPatch,
    cancelled: bool,
) -> None:
    class _BlockAfterProgressBatchGenerator:
        instances: list[_BlockAfterProgressBatchGenerator] = []

        def __init__(self, _model: Any, **_kwargs: Any) -> None:
            self._next_uid = 0
            self._active: list[int] = []
            self.progress_emitted = threading.Event()
            self.release_response = threading.Event()
            self.__class__.instances.append(self)

        def insert(
            self,
            prompts: list[list[int]],
            max_tokens: list[int],
            caches: list[Any] | None = None,
            samplers: list[Any] | None = None,
            logits_processors: list[Any] | None = None,
            **_kwargs: Any,
        ) -> list[int]:
            del max_tokens, caches, samplers, logits_processors
            uids: list[int] = []
            for _ in prompts:
                uid = self._next_uid
                self._next_uid += 1
                self._active.append(uid)
                uids.append(uid)
            return uids

        def next(self) -> tuple[list[Any], list[Any]]:
            if len(self._active) >= 2 and not self.progress_emitted.is_set():
                prompt_responses = [
                    _prompt_response(self._active[0], 100, 100),
                    _prompt_response(self._active[1], 10, 100),
                ]
                self.progress_emitted.set()
                self.release_response.wait(timeout=5.0)
                return (
                    prompt_responses,
                    [_batch_response(self._active[1], token=21, finish_reason="stop")],
                )
            threading.Event().wait(0.01)
            return ([], [])

        def close(self) -> None:
            self.release_response.set()

    samples = [1_000, 3_000]
    calls = 0

    def memory_probe() -> int:
        nonlocal calls
        calls += 1
        return samples[calls - 1]

    delayed_pumps: list[threading.Thread] = []
    original_start = threading.Thread.start

    def delay_pump_start(thread: threading.Thread) -> None:
        if thread.name == "mlx-batch-generator":
            delayed_pumps.append(thread)
            return
        original_start(thread)

    monkeypatch.setattr(threading.Thread, "start", delay_pump_start)

    session = _make_fake_session(memory_budget_status=_make_memory_budget_status())
    session.tokenizer = _ToyTokenizer()
    runtime = _make_attribution_runtime(
        session,
        memory_probe=memory_probe,
        batch_generator_cls=_BlockAfterProgressBatchGenerator,
    )

    try:
        stream_cancelled = _queue_batch_stream(runtime, [1, 2, 3])
        stream_survivor = _queue_batch_stream(runtime, [4, 5, 6])
        assert delayed_pumps
        original_start(delayed_pumps[0])

        generator = _BlockAfterProgressBatchGenerator.instances[0]
        assert generator.progress_emitted.wait(timeout=2.0)
        stream_cancelled.close(cancelled=cancelled)
        generator.release_response.set()

        assert [chunk.text for chunk in stream_survivor] == ["X"]
    finally:
        runtime.close()

    assert calls == 2
    assert session.memory_budget_status.prefill_workspace_bytes_per_token == 200
    assert runtime._prefill_attribution_by_insert_set_id == {}


def test_batch_partial_prefill_cancel_preserves_peer_events_until_batch_cleanup(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Issue #409: cancelling one prefill peer does not terminalize the other peer."""

    class _PartialPrefillBatchGenerator:
        instances: list[_PartialPrefillBatchGenerator] = []

        def __init__(self, _model: Any, **_kwargs: Any) -> None:
            self._next_uid = 0
            self._active: list[int] = []
            self.prefill_started = threading.Event()
            self.release_responses = threading.Event()
            self.__class__.instances.append(self)

        def insert(
            self,
            prompts: list[list[int]],
            max_tokens: list[int],
            caches: list[Any] | None = None,
            samplers: list[Any] | None = None,
            logits_processors: list[Any] | None = None,
            **_kwargs: Any,
        ) -> list[int]:
            del max_tokens, caches, samplers, logits_processors
            uids = list(range(self._next_uid, self._next_uid + len(prompts)))
            self._next_uid += len(prompts)
            self._active.extend(uids)
            return uids

        def next(self) -> tuple[list[Any], list[Any]]:
            if not self.prefill_started.is_set():
                self.prefill_started.set()
                self.release_responses.wait(timeout=5.0)

            active = list(self._active)
            self._active.clear()
            return (
                [
                    _prompt_response(active[0], 10, 100),
                    _prompt_response(active[1], 20, 100),
                ],
                [
                    _batch_response(active[0], token=11, finish_reason="stop"),
                    _batch_response(active[1], token=21, finish_reason="stop"),
                ],
            )

        def close(self) -> None:
            self.release_responses.set()

    delayed_pumps: list[threading.Thread] = []
    original_start = threading.Thread.start

    def delay_pump_start(thread: threading.Thread) -> None:
        if thread.name == "mlx-batch-generator":
            delayed_pumps.append(thread)
            return
        original_start(thread)

    monkeypatch.setattr(threading.Thread, "start", delay_pump_start)

    session = _make_fake_session()
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_PartialPrefillBatchGenerator),
    )
    cancelled = threading.Event()
    cancelled_events: list[dict[str, Any]] = []
    peer_events: list[dict[str, Any]] = []

    def run(events: list[dict[str, Any]], request: Any, cancel_event: threading.Event) -> None:
        events.extend(
            generate_events(session, request, cancel_event, deps=runtime.generation_deps())
        )

    cancelled_thread = threading.Thread(
        target=run,
        args=(cancelled_events, _make_fake_request(input_tokens=3, max_output_tokens=2), cancelled),
    )
    peer_thread = threading.Thread(
        target=run,
        args=(
            peer_events,
            _make_fake_request(input_tokens=3, max_output_tokens=2),
            threading.Event(),
        ),
    )

    try:
        cancelled_thread.start()
        assert _wait_until(lambda: len(runtime._requests_by_id) == 1)
        peer_thread.start()
        assert _wait_until(lambda: len(runtime._requests_by_id) == 2)
        assert delayed_pumps
        original_start(delayed_pumps[0])

        generator = _PartialPrefillBatchGenerator.instances[0]
        assert generator.prefill_started.wait(timeout=2.0)
        cancelled.set()
        assert _wait_until(
            lambda: len([event for event in cancelled_events if event["kind"] == "failed"]) == 1
        )

        with runtime._cv:
            assert len(runtime._active_by_uid) == 2
            assert len(runtime._active_detokenizer_ids) == 1

        generator.release_responses.set()
        cancelled_thread.join(timeout=2.0)
        peer_thread.join(timeout=2.0)

        assert cancelled_thread.is_alive() is False
        assert peer_thread.is_alive() is False
        assert [
            event["kind"] for event in cancelled_events if event["kind"] in {"failed", "completed"}
        ] == ["failed"]
        assert cancelled_events[-1]["code"] == "cancelled"
        assert [
            event["delta"] for event in peer_events if event["kind"] == "output_text_delta"
        ] == ["X"]
        assert [
            event["kind"] for event in peer_events if event["kind"] in {"failed", "completed"}
        ] == ["completed"]
        assert peer_events[-1]["usage"] == {
            "input_tokens": 3,
            "output_tokens": 1,
            "total_tokens": 4,
        }
        assert _wait_until(
            lambda: (
                runtime._active_by_uid == {}
                and runtime._requests_by_id == {}
                and runtime._active_detokenizer_ids == set()
            )
        )
        assert runtime._active_by_uid == {}
        assert runtime._requests_by_id == {}
        assert runtime._active_detokenizer_ids == set()
    finally:
        runtime.close()
        cancelled_thread.join(timeout=2.0)
        peer_thread.join(timeout=2.0)


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
        **_kwargs: Any,
    ) -> list[int]:
        del max_tokens, caches, samplers, logits_processors
        uids: list[int] = []
        for _ in range(len(prompts)):
            uid = self._next_uid
            self._next_uid += 1
            self._active_uids.append(uid)
            uids.append(uid)
        return uids

    def next(self) -> tuple[list[Any], list[Any]]:
        if not self._active_uids:
            return ([], [])
        return (
            [],
            [
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
            ],
        )

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
        **_kwargs: Any,
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

    def next(self) -> tuple[list[Any], list[Any]]:
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
        return ([], responses)


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
        **_kwargs: Any,
    ) -> list[int]:
        del max_tokens, caches, samplers, logits_processors
        uids: list[int] = []
        for _ in prompts:
            uid = self._next_uid
            self._next_uid += 1
            self._active.append(uid)
            uids.append(uid)
        return uids

    def next(self) -> tuple[list[Any], list[Any]]:
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

        return ([], responses)

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
        **_kwargs: Any,
    ) -> list[int]:
        del max_tokens, caches, samplers, logits_processors
        uids: list[int] = []
        for _ in prompts:
            uid = self._next_uid
            self._next_uid += 1
            self._active.append(uid)
            uids.append(uid)
        return uids

    def next(self) -> tuple[list[Any], list[Any]]:
        if not self._active:
            threading.Event().wait(0.05)
            return ([], [])

        return (
            [],
            [
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
            ],
        )

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
            **_kwargs: Any,
        ) -> list[int]:
            del max_tokens, caches, samplers, logits_processors
            uids: list[int] = []
            for _ in prompts:
                uid = self._next_uid
                self._next_uid += 1
                self._active[uid] = False
                uids.append(uid)
            return uids

        def next(self) -> tuple[list[Any], list[Any]]:
            active = list(self._active)
            if not active:
                threading.Event().wait(0.01)
                return ([], [])

            if self.instance_index > 0:
                self._active.clear()
                return ([], [self._response(uid, token=11, finish_reason="stop") for uid in active])

            first_token_uids = [uid for uid, emitted in self._active.items() if not emitted]
            if first_token_uids:
                for uid in first_token_uids:
                    self._active[uid] = True

                return (
                    [],
                    [self._response(uid, token=11, finish_reason=None) for uid in first_token_uids],
                )

            if len(self._active) < self.expected_initial_requests:
                threading.Event().wait(0.01)
                return ([], [])

            if not self._second_token_emitted:
                self.allow_second_next.wait(timeout=5.0)
                self._second_token_emitted = True
                return ([], [self._response(uid, token=12, finish_reason=None) for uid in active])

            self.entered_blocking_next.set()
            self.close_called.wait(timeout=5.0)
            return ([], [])

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
            lambda: (
                sum(1 for event in events_cancel if event["kind"] == "output_text_delta") >= 1
                and sum(1 for event in events_waiter if event["kind"] == "output_text_delta") >= 1
            )
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
        cast(Any, iterator).close()

    assert runtime._active_detokenizer_ids == set()

    runtime.close()


def test_batch_generator_runtime_close_drops_load_scope_aliases() -> None:
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

    runtime.close()
    gc.collect()

    assert runtime._session is None
    assert runtime._batch_generator is None
    assert runtime._detokenizer_factory is None


def test_batch_generator_runtime_tokenizer_fails_after_close() -> None:
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

    runtime.close()

    with pytest.raises(BackendError) as exc_info:
        _ = runtime.tokenizer

    assert exc_info.value.code == "generation_failed"
    assert "batch runtime is closed" in exc_info.value.message


def test_batch_generator_runtime_double_close_keeps_aliases_dropped() -> None:
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

    runtime.close()
    runtime.close()

    assert runtime._session is None
    assert runtime._batch_generator is None
    assert runtime._detokenizer_factory is None


def test_batch_generator_runtime_close_raises_if_pump_cannot_stop_after_generator_close() -> None:
    tracker = _WiredLimitTracker()
    session = _make_fake_session(
        memory_budget_status=SimpleNamespace(
            budget_available=True,
            target_working_set_bytes=123_456,
        )
    )
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
            wired_limit=tracker,
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
    assert runtime._session is session
    assert runtime._batch_generator is generator
    assert callable(runtime._detokenizer_factory)
    assert generator.close_called is True
    assert tracker.enter_count == 0
    assert tracker.exit_count == 0

    generator.allow_next.set()
    thread.join(timeout=2.0)
    runtime.close()

    assert tracker.exit_count == 0

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
            **_kwargs: Any,
        ) -> list[int]:
            del max_tokens, caches, samplers, logits_processors
            uids: list[int] = []
            for _ in prompts:
                uid = self._next_uid
                self._next_uid += 1
                self._active.append(uid)
                uids.append(uid)
            return uids

        def next(self) -> tuple[list[Any], list[Any]]:
            active = list(self._active)
            if not active:
                threading.Event().wait(0.01)
                return ([], [])

            self._next_calls += 1
            if self._next_calls == 1:
                return (
                    [],
                    [
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
                    ],
                )

            self._release_block.wait(timeout=5.0)
            return ([], [])

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


def test_batch_runtime_clears_once_when_runtime_goes_idle() -> None:
    calls: list[str] = []

    def synchronize() -> None:
        calls.append("synchronize")

    def clear_cache() -> None:
        calls.append("clear")

    session = _make_fake_session(clear_cache=clear_cache)
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
            synchronize=synchronize,
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_FakeBatchGenerator),
    )

    try:
        request = _make_fake_request(input_tokens=3, max_output_tokens=2)
        events = list(
            generate_events(session, request, threading.Event(), deps=runtime.generation_deps())
        )

        assert events[-1]["kind"] == "completed"
        assert _wait_until(lambda: calls == ["synchronize", "clear"])
        threading.Event().wait(0.05)
        assert calls == ["synchronize", "clear"]
    finally:
        runtime.close()


def test_batch_runtime_does_not_clear_while_request_is_active() -> None:
    calls: list[str] = []
    session = _make_fake_session(clear_cache=lambda: calls.append("clear"))
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
            synchronize=lambda: calls.append("synchronize"),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_NeverFinishingBatchGenerator),
    )

    request = _make_fake_request(input_tokens=3, max_output_tokens=32)
    iterator = generate_events(session, request, threading.Event(), deps=runtime.generation_deps())

    try:
        first_event = next(event for event in iterator if event["kind"] != "usage")
        assert first_event["kind"] == "output_text_delta"
        assert _wait_until(lambda: bool(runtime._active_by_uid))
        threading.Event().wait(0.05)
        assert calls == []
    finally:
        cast(Any, iterator).close()
        runtime.close()


def test_batch_runtime_idle_clear_is_fail_open_without_sync_or_clear_cache() -> None:
    session = _make_fake_session()
    del session.clear_cache
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
            synchronize=None,
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_FakeBatchGenerator),
    )

    try:
        request = _make_fake_request(input_tokens=3, max_output_tokens=2)
        events = list(
            generate_events(session, request, threading.Event(), deps=runtime.generation_deps())
        )

        assert events[-1]["kind"] == "completed"
        assert _wait_until(lambda: not runtime._idle_cache_clear_needed)
    finally:
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
        first_event = next(event for event in iterator if event["kind"] != "usage")
        assert first_event["kind"] == "output_text_delta"

        cast(Any, iterator).close()

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


class _FlatNextBatchGenerator:
    def __init__(self, _model: Any, **_kwargs: Any) -> None:
        self._next_uid = 0

    def insert(
        self,
        prompts: list[list[int]],
        max_tokens: list[int],
        caches: list[Any] | None = None,
        samplers: list[Any] | None = None,
        logits_processors: list[Any] | None = None,
        **_kwargs: Any,
    ) -> list[int]:
        del max_tokens, caches, samplers, logits_processors
        uids = list(range(self._next_uid, self._next_uid + len(prompts)))
        self._next_uid += len(prompts)
        return uids

    def next(self) -> list[Any]:
        return [_batch_response(0, token=11, finish_reason="stop")]


class _MalformedPromptResponseBatchGenerator:
    prompt_response: Any = None

    def __init__(self, _model: Any, **_kwargs: Any) -> None:
        self._next_uid = 0

    def insert(
        self,
        prompts: list[list[int]],
        max_tokens: list[int],
        caches: list[Any] | None = None,
        samplers: list[Any] | None = None,
        logits_processors: list[Any] | None = None,
        **_kwargs: Any,
    ) -> list[int]:
        del max_tokens, caches, samplers, logits_processors
        uids = list(range(self._next_uid, self._next_uid + len(prompts)))
        self._next_uid += len(prompts)
        return uids

    def next(self) -> tuple[list[Any], list[Any]]:
        return ([self.prompt_response], [_batch_response(0, token=11, finish_reason="stop")])


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
        **_kwargs: Any,
    ) -> list[int]:
        del max_tokens, caches, samplers, logits_processors
        uids = list(range(self._next_uid, self._next_uid + len(prompts)))
        self._next_uid += len(prompts)
        return uids

    def next(self) -> tuple[list[Any], list[Any]]:
        return (
            [],
            [
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
            ],
        )


class _ExplodingIterable:
    def __iter__(self) -> Any:
        raise RuntimeError("response iteration boom")


class _ExplodingPromptResponsesBatchGenerator(_MalformedPromptResponseBatchGenerator):
    def next(self) -> tuple[Any, list[Any]]:
        return (_ExplodingIterable(), [_batch_response(0, token=11, finish_reason="stop")])


class _ExplodingGenerationResponsesBatchGenerator(_MalformedPromptResponseBatchGenerator):
    def next(self) -> tuple[list[Any], Any]:
        return ([], _ExplodingIterable())


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
        **_kwargs: Any,
    ) -> list[int]:
        del caches, samplers, logits_processors
        self._insert_calls += 1
        if self._insert_calls == 1:
            return [1, 1]

        self._active = [
            {"uid": 100 + i, "remaining": max(1, max_tokens[i])} for i in range(len(prompts))
        ]
        return [item["uid"] for item in self._active]

    def next(self) -> tuple[list[Any], list[Any]]:
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
        return ([], responses)


def test_batch_generator_runtime_rejects_flat_next_response_container() -> None:
    session = _make_fake_session()
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_FlatNextBatchGenerator),
    )

    try:
        with pytest.raises(BackendError) as exc_info:
            list(
                generate_events(
                    session,
                    _make_fake_request(),
                    threading.Event(),
                    deps=runtime.generation_deps(),
                )
            )
    finally:
        runtime.close()

    assert exc_info.value.code == "generation_failed"
    assert "invalid response container" in exc_info.value.message


@pytest.mark.parametrize(
    "prompt_response",
    [
        SimpleNamespace(uid=True, progress=(1, 3)),
        SimpleNamespace(uid=0, progress=(True, 3)),
        SimpleNamespace(uid=0, progress=(1, False)),
        SimpleNamespace(uid=0, progress=(1,)),
        SimpleNamespace(uid=0, progress=None),
    ],
)
def test_batch_generator_runtime_rejects_malformed_prompt_responses(
    prompt_response: Any,
) -> None:
    _MalformedPromptResponseBatchGenerator.prompt_response = prompt_response
    session = _make_fake_session()
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_MalformedPromptResponseBatchGenerator),
    )

    try:
        with pytest.raises(BackendError) as exc_info:
            list(
                generate_events(
                    session,
                    _make_fake_request(),
                    threading.Event(),
                    deps=runtime.generation_deps(),
                )
            )
    finally:
        runtime.close()

    assert exc_info.value.code == "generation_failed"
    assert "malformed response payload" in exc_info.value.message


@pytest.mark.parametrize(
    "batch_generator_cls",
    [_ExplodingPromptResponsesBatchGenerator, _ExplodingGenerationResponsesBatchGenerator],
)
def test_batch_generator_runtime_rejects_exploding_response_iterables(
    batch_generator_cls: type,
) -> None:
    session = _make_fake_session()
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=batch_generator_cls),
    )

    try:
        with pytest.raises(BackendError) as exc_info:
            list(
                generate_events(
                    session,
                    _make_fake_request(),
                    threading.Event(),
                    deps=runtime.generation_deps(),
                )
            )
    finally:
        runtime.close()

    assert exc_info.value.code == "generation_failed"
    assert "malformed response payload" in exc_info.value.message


def test_batch_generator_runtime_closes_old_generator_before_reset_rebuild_once() -> None:
    class _ResetCloseOrderBatchGenerator:
        instances: list[_ResetCloseOrderBatchGenerator] = []
        rebuilt_after_old_closed = False

        def __init__(self, _model: Any, **_kwargs: Any) -> None:
            self.close_count = 0
            if self.instances:
                self.__class__.rebuilt_after_old_closed = self.instances[0].close_count == 1
            self.instances.append(self)

        def insert(
            self,
            prompts: list[list[int]],
            max_tokens: list[int],
            caches: list[Any] | None = None,
            samplers: list[Any] | None = None,
            logits_processors: list[Any] | None = None,
            **_kwargs: Any,
        ) -> list[int]:
            del max_tokens, caches, samplers, logits_processors
            return list(range(len(prompts)))

        def next(self) -> tuple[list[Any], list[Any]]:
            return ([], [])

        def close(self) -> None:
            self.close_count += 1

    session = _make_fake_session()
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_ResetCloseOrderBatchGenerator),
    )

    old_generator = _ResetCloseOrderBatchGenerator.instances[0]
    with runtime._cv:
        returned_old_generator = runtime._request_reset_locked("test reset")
    assert returned_old_generator is old_generator

    runtime._perform_requested_reset()
    runtime._close_batch_generator_best_effort(returned_old_generator)
    runtime.close()

    assert len(_ResetCloseOrderBatchGenerator.instances) == 2
    assert _ResetCloseOrderBatchGenerator.rebuilt_after_old_closed is True
    assert old_generator.close_count == 1
    assert _ResetCloseOrderBatchGenerator.instances[1].close_count == 1


def test_batch_generator_runtime_reset_rebuild_failure_drops_closed_generator_reference() -> None:
    class _ResetRebuildFailureBatchGenerator:
        instances: list[_ResetRebuildFailureBatchGenerator] = []

        def __init__(self, _model: Any, **_kwargs: Any) -> None:
            if self.instances:
                raise RuntimeError("rebuild boom")
            self.close_count = 0
            self.instances.append(self)

        def insert(
            self,
            prompts: list[list[int]],
            max_tokens: list[int],
            caches: list[Any] | None = None,
            samplers: list[Any] | None = None,
            logits_processors: list[Any] | None = None,
            **_kwargs: Any,
        ) -> list[int]:
            del max_tokens, caches, samplers, logits_processors
            return list(range(len(prompts)))

        def next(self) -> tuple[list[Any], list[Any]]:
            return ([], [])

        def close(self) -> None:
            self.close_count += 1

    session = _make_fake_session()
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_ResetRebuildFailureBatchGenerator),
    )

    old_generator = _ResetRebuildFailureBatchGenerator.instances[0]
    with runtime._cv:
        returned_old_generator = runtime._request_reset_locked("test reset")
    assert returned_old_generator is old_generator

    runtime._perform_requested_reset()
    runtime.close()

    assert old_generator.close_count == 1
    assert runtime._batch_generator is None
    assert runtime._batch_generator_closed is True


def test_batch_generator_runtime_does_not_retain_closed_batch_generators() -> None:
    close_calls: list[str] = []

    class _WeakOnlyCloseTracked:
        __slots__ = ("close_calls", "__weakref__")
        __hash__ = None

        def __init__(self, close_calls: list[str]) -> None:
            self.close_calls = close_calls

        def __eq__(self, other: object) -> bool:
            return self is other

        def close(self) -> None:
            self.close_calls.append("close")

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

    generator = _WeakOnlyCloseTracked(close_calls)
    generator_ref = weakref.ref(generator)

    runtime._close_batch_generator_best_effort(generator)
    runtime._close_batch_generator_best_effort(generator)
    assert close_calls == ["close"]

    del generator
    gc.collect()
    runtime.close()

    assert generator_ref() is None


def test_batch_generator_runtime_closes_rebuilt_generator_if_closed_during_reset() -> None:
    class _ResetCloseRaceBatchGenerator:
        def __init__(self, _model: Any, **_kwargs: Any) -> None:
            self.close_count = 0

        def next(self) -> tuple[list[Any], list[Any]]:
            return ([], [])

        def close(self) -> None:
            self.close_count += 1

    session = _make_fake_session()
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_ResetCloseRaceBatchGenerator),
    )
    rebuilt_generators: list[_ResetCloseRaceBatchGenerator] = []

    def build_and_mark_runtime_closed(_session: Any) -> _ResetCloseRaceBatchGenerator:
        generator = _ResetCloseRaceBatchGenerator(_session.model)
        rebuilt_generators.append(generator)
        with runtime._cv:
            runtime._closed = True
        return generator

    runtime._build_batch_generator = build_and_mark_runtime_closed  # type: ignore[method-assign]
    with runtime._cv:
        runtime._request_reset_locked("test reset")

    runtime._perform_requested_reset()
    runtime.close()

    assert len(rebuilt_generators) == 1
    assert rebuilt_generators[0].close_count == 1


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


def test_spec_7_5_3a_emits_cumulative_usage_before_completed() -> None:
    responses = [
        FakeGenerationResponse(text="Hello", token=10),
        FakeGenerationResponse(text=" world", token=11),
        FakeGenerationResponse(text="", token=12, finish_reason="stop"),
    ]
    session = _make_fake_session()
    request = _make_fake_request(input_tokens=5)

    events = _collect_events(session, request, _make_deps(responses))

    usage_events = [event for event in events if event["kind"] == "usage"]
    assert [event["usage"] for event in usage_events] == [
        {"input_tokens": 5, "output_tokens": 1, "total_tokens": 6},
        {"input_tokens": 5, "output_tokens": 2, "total_tokens": 7},
        {"input_tokens": 5, "output_tokens": 3, "total_tokens": 8},
    ]
    assert all(set(event) == {"kind", "usage"} for event in usage_events)
    assert events.index(usage_events[-1]) < len(events) - 1
    assert events[-1]["kind"] == "completed"
    assert events[-1]["usage"] == usage_events[-1]["usage"]


def test_spec_7_5_3a_paces_cumulative_usage_on_the_decode_cancel_stride() -> None:
    responses = [
        FakeGenerationResponse(text="a", token=10),
        FakeGenerationResponse(text="b", token=11),
        FakeGenerationResponse(text="c", token=12),
        FakeGenerationResponse(text="d", token=13),
        FakeGenerationResponse(text="e", token=14, finish_reason="stop"),
    ]
    session = _make_fake_session(decode_cancel_stride=2)
    request = _make_fake_request(input_tokens=5)

    events = _collect_events(session, request, _make_deps(responses))

    usage_events = [event for event in events if event["kind"] == "usage"]
    assert [event["usage"]["output_tokens"] for event in usage_events] == [2, 4, 5]
    assert events[-2] == {
        "kind": "usage",
        "usage": {"input_tokens": 5, "output_tokens": 5, "total_tokens": 10},
    }
    assert events[-1]["kind"] == "completed"
    assert events[-1]["usage"] == usage_events[-1]["usage"]


def test_spec_7_5_3a_emits_final_cumulative_usage_before_cancelled_terminal() -> None:
    cancel = threading.Event()

    def cancelling_stream(model, tokenizer, prompt_ids, **kwargs):
        yield FakeGenerationResponse(text="a", token=10)
        cancel.set()
        yield FakeGenerationResponse(text="b", token=11)

    deps = GenerationDeps(
        stream_generate=cancelling_stream,
        make_sampler=lambda **kw: MagicMock(),
    )
    session = _make_fake_session(decode_cancel_stride=8)
    request = _make_fake_request(input_tokens=3)

    events = _collect_events(session, request, deps, cancel_event=cancel)

    assert [event for event in events if event["kind"] == "usage"] == [
        {"kind": "usage", "usage": {"input_tokens": 3, "output_tokens": 2, "total_tokens": 5}}
    ]
    assert events[-2]["kind"] == "usage"
    assert events[-1]["kind"] == "failed"
    assert events[-1]["code"] == "cancelled"


def test_spec_7_5_3a_omits_cumulative_usage_when_no_tokens_are_generated() -> None:
    session = _make_fake_session()
    request = _make_fake_request(input_tokens=3)

    events = _collect_events(session, request, _make_deps([]))

    assert not any(event["kind"] == "usage" for event in events)
    assert events[-1]["kind"] == "completed"
    assert events[-1]["usage"] == {"input_tokens": 3, "output_tokens": 0, "total_tokens": 3}


def test_non_batch_token_delta_opt_in_does_not_forward_unknown_kwargs() -> None:
    calls: list[list[int]] = []

    def strict_stream_generate(
        model,
        tokenizer,
        prompt_ids,
        *,
        max_tokens,
        sampler,
        prefill_step_size,
        prompt_progress_callback,
    ):
        del model, tokenizer, max_tokens, sampler, prefill_step_size, prompt_progress_callback
        calls.append(list(prompt_ids))
        yield SimpleNamespace(text="A", token=11, finish_reason=None, logprob=-0.11)
        yield SimpleNamespace(text="B", token=12, finish_reason="stop", logprob=-0.12)

    session = _make_fake_session()
    request = _make_fake_request(
        input_tokens=3,
        return_token_ids=True,
        return_logprobs=True,
    )
    deps = _make_deps(stream_generate=strict_stream_generate)

    events = _collect_events(session, request, deps)

    assert calls == [[1, 2, 3]]
    token_deltas = [event for event in events if event["kind"] == "token_delta"]
    assert [event["token_ids"] for event in token_deltas] == [[11], [12]]
    assert [event["logprobs"] for event in token_deltas] == [[-0.11], [-0.12]]


def test_non_batch_token_delta_extracts_indexed_logprobs_vector() -> None:
    def strict_stream_generate(
        model,
        tokenizer,
        prompt_ids,
        *,
        max_tokens,
        sampler,
        prefill_step_size,
        prompt_progress_callback,
    ):
        del model, tokenizer, prompt_ids, max_tokens, sampler, prefill_step_size
        del prompt_progress_callback
        first_logprobs = [0.0] * 32
        first_logprobs[11] = -1.25
        second_logprobs = [0.0] * 32
        second_logprobs[12] = -1.5
        yield SimpleNamespace(text="A", token=11, finish_reason=None, logprobs=first_logprobs)
        yield SimpleNamespace(text="B", token=12, finish_reason="stop", logprobs=second_logprobs)

    session = _make_fake_session()
    request = _make_fake_request(input_tokens=3, return_logprobs=True)
    deps = _make_deps(stream_generate=strict_stream_generate)

    events = _collect_events(session, request, deps)

    token_deltas = [event for event in events if event["kind"] == "token_delta"]
    assert [event["token_ids"] for event in token_deltas] == [[11], [12]]
    assert [event["logprobs"] for event in token_deltas] == [[-1.25], [-1.5]]


def test_input_tokens_from_request_not_retokenized() -> None:
    """input_tokens in usage comes from the request when prompt IDs are supplied."""
    responses = [
        FakeGenerationResponse(text="ok", token=10, finish_reason="stop"),
    ]
    session = _make_fake_session()
    request = _make_fake_request(input_tokens=3, prompt_token_ids=[101, 102, 103])
    deps = _make_deps(responses)

    events = _collect_events(session, request, deps)
    completed = events[-1]
    assert completed["usage"]["input_tokens"] == 3
    assert completed["usage"]["output_tokens"] == 1
    assert completed["usage"]["total_tokens"] == 4
    session.tokenizer.encode.assert_not_called()


def test_prompt_token_ids_are_used_without_reencoding() -> None:
    calls: list[list[int]] = []

    def recording_stream_generate(model, tokenizer, prompt_ids, **kwargs):
        del model, tokenizer, kwargs
        calls.append(list(prompt_ids))
        yield FakeGenerationResponse(text="ok", token=10, finish_reason="stop")

    session = _make_fake_session()
    request = _make_fake_request(input_tokens=3, prompt_token_ids=[10, 20, 30])
    deps = _make_deps(stream_generate=recording_stream_generate)

    events = _collect_events(session, request, deps)

    assert calls == [[10, 20, 30]]
    session.tokenizer.encode.assert_not_called()
    assert events[-1]["kind"] == "completed"


def test_prompt_token_ids_length_mismatch_fails_before_stream_generate() -> None:
    calls: list[list[int]] = []

    def recording_stream_generate(model, tokenizer, prompt_ids, **kwargs):
        del model, tokenizer, kwargs
        calls.append(list(prompt_ids))
        yield FakeGenerationResponse(text="ok", token=10, finish_reason="stop")

    session = _make_fake_session()
    request = _make_fake_request(input_tokens=2, prompt_token_ids=[10, 20, 30])
    deps = _make_deps(stream_generate=recording_stream_generate)

    with pytest.raises(BackendError) as exc_info:
        _collect_events(session, request, deps)

    assert exc_info.value.code == "prompt_token_ids_length_mismatch"
    assert calls == []


def test_prompt_token_ids_length_mismatch_fails_before_invalid_prompt_decode() -> None:
    calls: list[list[int]] = []

    def recording_stream_generate(model, tokenizer, prompt_ids, **kwargs):
        del model, tokenizer, kwargs
        calls.append(list(prompt_ids))
        yield FakeGenerationResponse(text="ok", token=10, finish_reason="stop")

    session = _make_fake_session()
    request = _make_fake_request(
        prompt=b"\xff\xfe",
        input_tokens=2,
        prompt_token_ids=[10, 20, 30],
    )
    deps = _make_deps(stream_generate=recording_stream_generate)

    with pytest.raises(BackendError) as exc_info:
        _collect_events(session, request, deps)

    assert exc_info.value.code == "prompt_token_ids_length_mismatch"
    session.tokenizer.encode.assert_not_called()
    assert calls == []


def test_prompt_token_ids_length_mismatch_fails_before_max_output_tokens_zero() -> None:
    calls: list[list[int]] = []

    def recording_stream_generate(model, tokenizer, prompt_ids, **kwargs):
        del model, tokenizer, kwargs
        calls.append(list(prompt_ids))
        yield FakeGenerationResponse(text="ok", token=10, finish_reason="stop")

    session = _make_fake_session()
    request = _make_fake_request(
        input_tokens=2,
        max_output_tokens=0,
        prompt_token_ids=[10, 20, 30],
    )
    deps = _make_deps(stream_generate=recording_stream_generate)

    with pytest.raises(BackendError) as exc_info:
        _collect_events(session, request, deps)

    assert exc_info.value.code == "prompt_token_ids_length_mismatch"
    assert calls == []


def test_prompt_token_ids_absent_falls_back_to_reencode() -> None:
    calls: list[list[int]] = []

    def recording_stream_generate(model, tokenizer, prompt_ids, **kwargs):
        del model, tokenizer, kwargs
        calls.append(list(prompt_ids))
        yield FakeGenerationResponse(text="ok", token=10, finish_reason="stop")

    session = _make_fake_session()
    request = _make_fake_request(input_tokens=3, prompt_token_ids=[])
    deps = _make_deps(stream_generate=recording_stream_generate)

    _collect_events(session, request, deps)

    assert calls == [[1, 2, 3]]
    session.tokenizer.encode.assert_called_once_with("hello world", add_special_tokens=False)


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


class _WiredLimitTracker:
    def __init__(self) -> None:
        self.calls: list[int] = []
        self.enter_count = 0
        self.exit_count = 0

    def __call__(self, bytes_limit: int):
        self.calls.append(bytes_limit)

        @contextmanager
        def _scope():
            self.enter_count += 1
            try:
                yield
            finally:
                self.exit_count += 1

        return _scope()


class _ExplodingEnterWiredLimit:
    def __init__(self) -> None:
        self.calls: list[int] = []
        self.enter_count = 0
        self.exit_count = 0

    def __call__(self, bytes_limit: int):
        self.calls.append(bytes_limit)
        return self

    def __enter__(self):
        self.enter_count += 1
        raise RuntimeError("wired_limit enter failed")

    def __exit__(self, exc_type, exc, traceback):
        self.exit_count += 1
        return None


class _FakeMXWiredLimit:
    def __init__(self) -> None:
        self.set_calls: list[int] = []
        self.synchronize_count = 0

    def set_wired_limit(self, bytes_limit: int) -> int:
        self.set_calls.append(bytes_limit)
        return 999_999

    def synchronize(self) -> None:
        self.synchronize_count += 1


def test_wired_limit_context_sets_target_bytes_and_restores_previous_limit() -> None:
    fake_mx = _FakeMXWiredLimit()
    wired_limit = _build_wired_limit_context(fake_mx)

    with wired_limit(123_456):
        assert fake_mx.set_calls == [123_456]
        assert fake_mx.synchronize_count == 0

    assert fake_mx.set_calls == [123_456, 999_999]
    assert fake_mx.synchronize_count == 1


def test_batch_generator_runtime_cleans_partial_startup_after_pump_start(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    tracker = _WiredLimitTracker()
    started_pumps: list[threading.Thread] = []

    class _StartupFailureBatchGenerator:
        instances: list[_StartupFailureBatchGenerator] = []

        def __init__(self, _model: Any, **_kwargs: Any) -> None:
            self.close_called = False
            type(self).instances.append(self)

        def close(self) -> None:
            self.close_called = True

    original_start = threading.Thread.start

    def start_or_fail(thread: threading.Thread) -> None:
        if thread.name == "mlx-batch-generator":
            started_pumps.append(thread)
            original_start(thread)
            return
        if thread.name == "mlx-batch-generator-watchdog":
            raise RuntimeError("watchdog start boom")
        original_start(thread)

    monkeypatch.setattr(threading.Thread, "start", start_or_fail)

    session = _make_fake_session(
        memory_budget_status=SimpleNamespace(
            budget_available=True,
            target_working_set_bytes=123_456,
        )
    )
    session.tokenizer = _ToyTokenizer()

    with pytest.raises(RuntimeError, match="watchdog start boom"):
        BatchGeneratorRuntime(
            session,
            generation_deps=GenerationDeps(
                stream_generate=lambda *_args, **_kwargs: iter([]),
                make_sampler=lambda **_kw: MagicMock(),
                wired_limit=tracker,
            ),
            batch_deps=BatchGenerationDeps(batch_generator_cls=_StartupFailureBatchGenerator),
        )

    assert len(_StartupFailureBatchGenerator.instances) == 1
    assert _StartupFailureBatchGenerator.instances[0].close_called is True
    assert started_pumps
    assert all(not thread.is_alive() for thread in started_pumps)
    assert tracker.enter_count == 0
    assert tracker.exit_count == 0


def test_batch_generator_runtime_cleans_partial_startup_before_threads_start(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    tracker = _WiredLimitTracker()
    started_threads: list[str] = []

    class _PumpStartFailureBatchGenerator:
        instances: list[_PumpStartFailureBatchGenerator] = []

        def __init__(self, _model: Any, **_kwargs: Any) -> None:
            self.close_called = False
            type(self).instances.append(self)

        def close(self) -> None:
            self.close_called = True

    original_start = threading.Thread.start

    def start_or_fail(thread: threading.Thread) -> None:
        if thread.name == "mlx-batch-generator":
            raise RuntimeError("pump start boom")
        started_threads.append(thread.name)
        original_start(thread)

    monkeypatch.setattr(threading.Thread, "start", start_or_fail)

    session = _make_fake_session(
        memory_budget_status=SimpleNamespace(
            budget_available=True,
            target_working_set_bytes=123_456,
        )
    )
    session.tokenizer = _ToyTokenizer()

    with pytest.raises(RuntimeError, match="pump start boom"):
        BatchGeneratorRuntime(
            session,
            generation_deps=GenerationDeps(
                stream_generate=lambda *_args, **_kwargs: iter([]),
                make_sampler=lambda **_kw: MagicMock(),
                wired_limit=tracker,
            ),
            batch_deps=BatchGenerationDeps(batch_generator_cls=_PumpStartFailureBatchGenerator),
        )

    assert len(_PumpStartFailureBatchGenerator.instances) == 1
    assert _PumpStartFailureBatchGenerator.instances[0].close_called is True
    assert started_threads == []
    assert tracker.calls == []
    assert tracker.enter_count == 0
    assert tracker.exit_count == 0


def test_batch_generator_runtime_leaves_wired_limit_to_batch_generator() -> None:
    tracker = _WiredLimitTracker()
    session = _make_fake_session(
        memory_budget_status=SimpleNamespace(
            budget_available=True,
            target_working_set_bytes=123_456,
        )
    )
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
            wired_limit=tracker,
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_FakeBatchGenerator),
    )

    try:
        events = _collect_events(session, _make_fake_request(), runtime.generation_deps())
        assert events[-1]["kind"] == "completed"
        assert tracker.calls == []
        assert tracker.enter_count == 0
        assert tracker.exit_count == 0
    finally:
        runtime.close()

    assert tracker.exit_count == 0


def test_batch_generator_runtime_close_does_not_close_orchard_wired_limit() -> None:
    tracker = _WiredLimitTracker()
    session = _make_fake_session(
        memory_budget_status=SimpleNamespace(
            budget_available=True,
            target_working_set_bytes=123_456,
        )
    )
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
            wired_limit=tracker,
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_FakeBatchGenerator),
    )

    assert tracker.calls == []
    assert tracker.enter_count == 0
    assert tracker.exit_count == 0

    runtime.close()

    assert tracker.exit_count == 0

    runtime.close()

    assert tracker.exit_count == 0


def test_batch_generator_runtime_wired_limit_entry_failure_is_fail_open() -> None:
    tracker = _ExplodingEnterWiredLimit()
    session = _make_fake_session(
        memory_budget_status=SimpleNamespace(
            budget_available=True,
            target_working_set_bytes=123_456,
        )
    )
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
            wired_limit=tracker,
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_FakeBatchGenerator),
    )

    try:
        events = _collect_events(session, _make_fake_request(), runtime.generation_deps())
        assert events[-1]["kind"] == "completed"
        assert tracker.calls == []
        assert tracker.enter_count == 0
        assert tracker.exit_count == 0
    finally:
        runtime.close()


def test_batch_generator_runtime_skips_wired_limit_without_available_budget() -> None:
    tracker = _WiredLimitTracker()
    session = _make_fake_session(
        memory_budget_status=SimpleNamespace(
            budget_available=False,
            target_working_set_bytes=123_456,
        )
    )
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
            wired_limit=tracker,
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_FakeBatchGenerator),
    )

    try:
        events = _collect_events(session, _make_fake_request(), runtime.generation_deps())
        assert events[-1]["kind"] == "completed"
        assert tracker.calls == []
        assert tracker.enter_count == 0
        assert tracker.exit_count == 0
    finally:
        runtime.close()


def test_wired_limit_used_with_expected_target_working_set_bytes() -> None:
    tracker = _WiredLimitTracker()
    responses = [
        FakeGenerationResponse(text="x", token=10, finish_reason="stop"),
    ]

    deps = GenerationDeps(
        stream_generate=lambda m, t, p, **kw: iter(responses),
        make_sampler=lambda **kw: MagicMock(),
        wired_limit=tracker,
    )
    session = _make_fake_session(
        memory_budget_status=SimpleNamespace(
            budget_available=True,
            target_working_set_bytes=123_456,
        )
    )
    request = _make_fake_request()

    events = _collect_events(session, request, deps)

    assert events[-1]["kind"] == "completed"
    assert tracker.calls == [123_456]
    assert tracker.enter_count == 1
    assert tracker.exit_count == 1


def test_wired_limit_unavailable_is_noop() -> None:
    stream_calls = 0
    responses = [
        FakeGenerationResponse(text="x", token=10, finish_reason="stop"),
    ]

    def stream_generate(model, tokenizer, prompt_ids, **kwargs):
        nonlocal stream_calls
        stream_calls += 1
        yield from responses

    deps = GenerationDeps(
        stream_generate=stream_generate,
        make_sampler=lambda **kw: MagicMock(),
        wired_limit=None,
    )
    session = _make_fake_session(
        memory_budget_status=SimpleNamespace(
            budget_available=True,
            target_working_set_bytes=123_456,
        )
    )
    request = _make_fake_request()

    events = _collect_events(session, request, deps)

    assert events[-1]["kind"] == "completed"
    assert stream_calls == 1


def test_wired_limit_callable_failure_is_fail_open() -> None:
    calls: list[int] = []
    stream_calls = 0
    responses = [
        FakeGenerationResponse(text="x", token=10, finish_reason="stop"),
    ]

    def wired_limit(bytes_limit: int):
        calls.append(bytes_limit)
        raise RuntimeError("wired_limit failed")

    def stream_generate(model, tokenizer, prompt_ids, **kwargs):
        nonlocal stream_calls
        stream_calls += 1
        yield from responses

    deps = GenerationDeps(
        stream_generate=stream_generate,
        make_sampler=lambda **kw: MagicMock(),
        wired_limit=wired_limit,
    )
    session = _make_fake_session(
        memory_budget_status=SimpleNamespace(
            budget_available=True,
            target_working_set_bytes=123_456,
        )
    )
    request = _make_fake_request()

    events = _collect_events(session, request, deps)

    assert events[-1]["kind"] == "completed"
    assert stream_calls == 1
    assert calls == [123_456]


def test_wired_limit_context_entry_failure_is_fail_open() -> None:
    tracker = _ExplodingEnterWiredLimit()
    stream_calls = 0
    responses = [
        FakeGenerationResponse(text="x", token=10, finish_reason="stop"),
    ]

    def stream_generate(model, tokenizer, prompt_ids, **kwargs):
        nonlocal stream_calls
        stream_calls += 1
        yield from responses

    deps = GenerationDeps(
        stream_generate=stream_generate,
        make_sampler=lambda **kw: MagicMock(),
        wired_limit=tracker,
    )
    session = _make_fake_session(
        memory_budget_status=SimpleNamespace(
            budget_available=True,
            target_working_set_bytes=123_456,
        )
    )
    request = _make_fake_request()

    events = _collect_events(session, request, deps)

    assert events[-1]["kind"] == "completed"
    assert stream_calls == 1
    assert tracker.calls == [123_456]
    assert tracker.enter_count == 1
    assert tracker.exit_count == 0


class _BudgetStatusTargetRaises:
    budget_available = True

    @property
    def target_working_set_bytes(self) -> int:
        raise RuntimeError("target lookup boom")


def test_wired_limit_target_lookup_failure_is_fail_open() -> None:
    tracker = _WiredLimitTracker()
    stream_calls = 0
    responses = [
        FakeGenerationResponse(text="x", token=10, finish_reason="stop"),
    ]

    def stream_generate(model, tokenizer, prompt_ids, **kwargs):
        nonlocal stream_calls
        stream_calls += 1
        yield from responses

    deps = GenerationDeps(
        stream_generate=stream_generate,
        make_sampler=lambda **kw: MagicMock(),
        wired_limit=tracker,
    )
    session = _make_fake_session(memory_budget_status=_BudgetStatusTargetRaises())
    request = _make_fake_request()

    events = _collect_events(session, request, deps)

    assert events[-1]["kind"] == "completed"
    assert stream_calls == 1
    assert tracker.calls == []
    assert tracker.enter_count == 0
    assert tracker.exit_count == 0


def test_wired_limit_target_lookup_failure_is_fail_open_for_batch_runtime() -> None:
    tracker = _WiredLimitTracker()
    session = _make_fake_session(memory_budget_status=_BudgetStatusTargetRaises())
    session.tokenizer = _ToyTokenizer()
    runtime = BatchGeneratorRuntime(
        session,
        generation_deps=GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: iter([]),
            make_sampler=lambda **_kw: MagicMock(),
            wired_limit=tracker,
        ),
        batch_deps=BatchGenerationDeps(batch_generator_cls=_FakeBatchGenerator),
    )

    try:
        events = _collect_events(session, _make_fake_request(), runtime.generation_deps())
        assert events[-1]["kind"] == "completed"
        assert tracker.calls == []
        assert tracker.enter_count == 0
        assert tracker.exit_count == 0
    finally:
        runtime.close()


def test_wired_limit_skipped_for_shared_batch_runtime_with_budget_available() -> None:
    tracker = _WiredLimitTracker()
    responses = [
        FakeGenerationResponse(text="x", token=10, finish_reason="stop"),
    ]

    deps = GenerationDeps(
        stream_generate=lambda m, t, p, **kw: iter(responses),
        make_sampler=lambda **kw: MagicMock(),
        wired_limit=tracker,
        uses_shared_batch_runtime=True,
    )
    session = _make_fake_session(
        memory_budget_status=SimpleNamespace(
            budget_available=True,
            target_working_set_bytes=123_456,
        )
    )
    request = _make_fake_request()

    events = _collect_events(session, request, deps)

    assert events[-1]["kind"] == "completed"
    assert tracker.calls == []
    assert tracker.enter_count == 0
    assert tracker.exit_count == 0


def test_budget_unavailable_skips_wired_limit() -> None:
    tracker = _WiredLimitTracker()
    responses = [
        FakeGenerationResponse(text="x", token=10, finish_reason="stop"),
    ]

    deps = GenerationDeps(
        stream_generate=lambda m, t, p, **kw: iter(responses),
        make_sampler=lambda **kw: MagicMock(),
        wired_limit=tracker,
    )
    session = _make_fake_session(
        memory_budget_status=SimpleNamespace(
            budget_available=False,
            target_working_set_bytes=123_456,
        )
    )
    request = _make_fake_request()

    events = _collect_events(session, request, deps)

    assert events[-1]["kind"] == "completed"
    assert tracker.calls == []


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


def test_eos_union_flushes_partial_multi_token_stop_sequence() -> None:
    """Issue #409: every normalized EOS ID stops independently of text stops."""
    responses = [
        FakeGenerationResponse(text="answerEN", token=73),
        FakeGenerationResponse(text="D-after-eos", token=11),
    ]
    session = _make_fake_session(eos_token_ids=(41, 73))
    request = _make_fake_request(stop_sequences=["END"])

    events = _collect_events(session, request, _make_deps(responses))

    assert [event["delta"] for event in events if event["kind"] == "output_text_delta"] == [
        "answer",
        "EN",
    ]
    assert events[-1]["kind"] == "completed"
    assert events[-1]["finish_reason"] == "FINISH_REASON_STOP"
    assert events[-1]["usage"]["output_tokens"] == 1


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
    assert events[-2] == {
        "kind": "usage",
        "usage": {"input_tokens": 3, "output_tokens": 2, "total_tokens": 5},
    }
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


def test_tool_choice_auto_emits_parsed_tool_call_and_tool_calls_finish_reason() -> None:
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

    visible_events = _without_usage_events(events)
    assert [event["kind"] for event in visible_events] == [
        "tool_call_delta",
        "completed",
    ]
    assert visible_events[0]["tool_call_id"] == "call_0"
    assert visible_events[0]["delta"] == {
        "index": 0,
        "type": "function",
        "function": {
            "name": "lookup_weather",
            "arguments_delta": '{"city":"Singapore"}',
        },
    }
    assert events[-1]["finish_reason"] == "FINISH_REASON_TOOL_CALLS"


def test_tool_call_markers_can_share_chunks_with_text() -> None:
    def parser(text: str, tools: Any) -> dict[str, Any]:
        assert text == '{"city":"Singapore"}'
        return {"name": "lookup_weather", "arguments": json.loads(text)}

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

    visible_events = _without_usage_events(events)
    assert [event["kind"] for event in visible_events] == [
        "output_text_delta",
        "tool_call_delta",
        "output_text_delta",
        "completed",
    ]
    assert visible_events[0]["delta"] == "Before "
    assert visible_events[1]["delta"]["function"] == {
        "name": "lookup_weather",
        "arguments_delta": '{"city":"Singapore"}',
    }
    assert visible_events[2]["delta"] == " after"
    assert visible_events[-1]["finish_reason"] == "FINISH_REASON_TOOL_CALLS"


def test_multi_tool_auto_emits_parser_selected_name_with_normalized_arguments() -> None:
    tools_json = (
        b"["
        b'{"type":"function","function":{"name":"lookup_weather","parameters":{}}},'
        b'{"type":"function","function":{"name":"lookup_time","parameters":{}}}'
        b"]"
    )

    def parser(text: str, tools: Any) -> dict[str, Any]:
        assert text == '{"city":"Singapore"}'
        assert len(tools) == 2
        return {"name": "lookup_time", "arguments": json.loads(text)}

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

    visible_events = _without_usage_events(events)
    assert [event["kind"] for event in visible_events] == [
        "tool_call_delta",
        "completed",
    ]
    assert visible_events[0]["delta"] == {
        "index": 0,
        "type": "function",
        "function": {"name": "lookup_time", "arguments_delta": '{"city":"Singapore"}'},
    }
    assert visible_events[-1]["finish_reason"] == "FINISH_REASON_TOOL_CALLS"


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
        tool_parser=lambda text, tools: {"name": "lookup_weather", "arguments": json.loads(text)},
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

    assert not any(event["kind"] == "tool_call_delta" for event in events)
    assert events[-1]["kind"] == "failed"
    assert events[-1]["code"] == "tool_choice_not_satisfied"
    assert len([event for event in events if event["kind"] in {"completed", "failed"}]) == 1


def test_cancel_mid_tool_call_discards_unparsed_call_before_cancelled_terminal() -> None:
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
        tool_parser=lambda text, tools: {"name": "lookup_weather", "arguments": json.loads(text)},
        tool_call_start="<tool_call>",
        tool_call_end="</tool_call>",
    )
    request = _make_fake_request(tools_json=_tool_call_tools_json())

    events = _collect_events(session, request, deps, cancel_event=cancel)

    visible_events = _without_usage_events(events)
    assert visible_events[:-1] == []
    assert visible_events[-1]["kind"] == "failed"
    assert visible_events[-1]["code"] == "cancelled"
    assert len([event for event in events if event["kind"] in {"completed", "failed"}]) == 1


def test_stop_sequences_do_not_truncate_tool_call_arguments() -> None:
    def parser(text: str, tools: Any) -> dict[str, Any]:
        return {"name": "lookup_weather", "arguments": json.loads(text)}

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

    tool_call_event = next(event for event in events if event["kind"] == "tool_call_delta")
    assert tool_call_event["delta"]["function"]["arguments_delta"] == '{"city":"Singapore"}'
    assert events[-1]["finish_reason"] == "FINISH_REASON_TOOL_CALLS"


def test_tool_choice_none_disables_tool_call_parsing() -> None:
    responses = [
        FakeGenerationResponse(text="<tool_call>", token=10),
        FakeGenerationResponse(text='{"city":"Singapore"}', token=11),
        FakeGenerationResponse(text="</tool_call>", token=12, finish_reason="stop"),
    ]
    session = _make_fake_session(
        tool_calling={"supported": True, "parser_type": "json_tools"},
        tool_parser=lambda text, tools: {"name": "lookup_weather", "arguments": json.loads(text)},
        tool_call_start="<tool_call>",
        tool_call_end="</tool_call>",
    )
    request = _make_fake_request(
        tools_json=_tool_call_tools_json(),
        tool_choice_json=b'"none"',
    )

    events = _collect_events(session, request, _make_deps(responses))

    assert [event["kind"] for event in _without_usage_events(events)] == [
        "output_text_delta",
        "output_text_delta",
        "output_text_delta",
        "completed",
    ]
    assert events[-1]["finish_reason"] == "FINISH_REASON_STOP"


@pytest.mark.parametrize("finish_reason", ["stop", "length", None])
@pytest.mark.parametrize("closing_marker", ["</tool_call>", ""])
def test_spec_7_5_2_unclosed_tool_block_requires_clean_delimiter_free_stop(
    finish_reason: str | None, closing_marker: str
) -> None:
    parser = MagicMock(return_value={"name": "lookup_weather", "arguments": {"city": "Paris"}})
    session = _make_fake_session(
        tool_calling={"supported": True, "parser_type": "json_tools"},
        tool_parser=parser,
        tool_call_start="<tool_call>",
        tool_call_end=closing_marker,
    )
    responses = [
        FakeGenerationResponse(text="<tool_call>", token=10),
        FakeGenerationResponse(text='{"city":"Paris"}', token=11, finish_reason=finish_reason),
    ]
    request = _make_fake_request(tools_json=_tool_call_tools_json())
    events = _collect_events(session, request, _make_deps(responses))

    if closing_marker == "" and finish_reason == "stop":
        parser.assert_called_once()
        visible_events = _without_usage_events(events)
        assert visible_events[0]["kind"] == "tool_call_delta"
        assert visible_events[-1]["finish_reason"] == "FINISH_REASON_TOOL_CALLS"
    else:
        parser.assert_not_called()
        assert not any(event["kind"] == "tool_call_delta" for event in events)
        assert events[-1]["kind"] == "failed"
        assert events[-1]["code"] == "tool_call_parse_failed"


def test_spec_7_5_2_required_tool_choice_rejects_length_limit_without_a_call() -> None:
    session = _make_fake_session(
        tool_calling={"supported": True, "parser_type": "json_tools"},
        tool_parser=MagicMock(),
        tool_call_start="<tool_call>",
        tool_call_end="</tool_call>",
    )
    request = _make_fake_request(tools_json=_tool_call_tools_json(), tool_choice_json=b'"required"')
    events = _collect_events(
        session,
        request,
        _make_deps([FakeGenerationResponse(text="No call", token=10, finish_reason="length")]),
    )
    assert events[-1]["kind"] == "failed"
    assert events[-1]["code"] == "tool_choice_not_satisfied"


# ===========================================================================
# Tool-call parser robustness fixtures (issue #62)
# ===========================================================================


def test_tool_call_arguments_with_braces_escaped_quotes_and_nesting_stream_intact() -> None:
    """Braces, brackets, and escaped quotes inside JSON string values are safe.

    The parser detects boundaries via explicit markers, not brace counting, so
    structural characters inside string values must reach the tool parser
    verbatim even when fragments split mid-escape-sequence.
    """
    argument_text = (
        '{"query":"say \\"hi\\" {ok} [list]","filters":{"tags":["a","}"],"opts":{"deep":{"x":1}}}}'
    )
    seen: list[str] = []

    def parser(text: str, tools: Any) -> dict[str, Any]:
        seen.append(text)
        return {"name": "lookup_weather", "arguments": json.loads(text)}

    # Split points chosen to break mid-escape (after the backslash at index 14)
    # and inside nested structures.
    splits = [0, 15, 30, 52, len(argument_text)]
    fragments = [argument_text[a:b] for a, b in zip(splits, splits[1:], strict=False)]
    responses = [
        FakeGenerationResponse(text="<tool_call>", token=10),
        *[
            FakeGenerationResponse(text=fragment, token=11 + i)
            for i, fragment in enumerate(fragments)
        ],
        FakeGenerationResponse(text="</tool_call>", token=20, finish_reason="stop"),
    ]
    session = _make_fake_session(
        tool_calling={"supported": True, "parser_type": "json_tools"},
        tool_parser=parser,
        tool_call_start="<tool_call>",
        tool_call_end="</tool_call>",
    )
    request = _make_fake_request(tools_json=_tool_call_tools_json())

    events = _collect_events(session, request, _make_deps(responses))

    assert seen == [argument_text]
    deltas = [
        event["delta"]["function"].get("arguments_delta", "")
        for event in events
        if event["kind"] == "tool_call_delta"
    ]
    assert "".join(deltas) == argument_text
    assert events[-1]["kind"] == "completed"
    assert events[-1]["finish_reason"] == "FINISH_REASON_TOOL_CALLS"


def test_tool_call_end_marker_split_across_response_chunks() -> None:
    def parser(text: str, tools: Any) -> dict[str, Any]:
        assert text == '{"city":"Paris"}'
        return {"name": "lookup_weather", "arguments": json.loads(text)}

    responses = [
        FakeGenerationResponse(text="<tool_call>", token=10),
        FakeGenerationResponse(text='{"city":"Paris"}', token=11),
        FakeGenerationResponse(text="</tool_", token=12),
        FakeGenerationResponse(text="call>", token=13, finish_reason="stop"),
    ]
    session = _make_fake_session(
        tool_calling={"supported": True, "parser_type": "json_tools"},
        tool_parser=parser,
        tool_call_start="<tool_call>",
        tool_call_end="</tool_call>",
    )
    request = _make_fake_request(tools_json=_tool_call_tools_json())

    events = _collect_events(session, request, _make_deps(responses))

    assert events[-1]["kind"] == "completed"
    assert events[-1]["finish_reason"] == "FINISH_REASON_TOOL_CALLS"


def test_tool_call_end_marker_lookalike_prefix_is_kept_in_arguments() -> None:
    """A buffered partial-marker prefix that never completes belongs to the arguments."""
    expected = '{"note":"</tool_x end"}'

    def parser(text: str, tools: Any) -> dict[str, Any]:
        assert text == expected
        return {"name": "lookup_weather", "arguments": json.loads(text)}

    responses = [
        FakeGenerationResponse(text="<tool_call>", token=10),
        FakeGenerationResponse(text='{"note":"</tool_', token=11),
        FakeGenerationResponse(text='x end"}', token=12),
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

    deltas = [
        event["delta"]["function"].get("arguments_delta", "")
        for event in events
        if event["kind"] == "tool_call_delta"
    ]
    assert "".join(deltas) == expected
    assert events[-1]["kind"] == "completed"
    assert events[-1]["finish_reason"] == "FINISH_REASON_TOOL_CALLS"


def test_tool_call_end_marker_inside_string_argument_fails_loudly() -> None:
    """Characterization of the issue #62 hazard: end-marker text inside a JSON
    string argument triggers premature finalization.

    The parser then sees truncated JSON and the request fails with
    tool_call_parse_failed rather than emitting a silently wrong tool call.
    String-aware scanning is deferred until raw-brace boundary models are
    supported; if that lands, this test should assert successful parsing of
    the full argument text instead.
    """
    seen: list[str] = []

    def parser(text: str, tools: Any) -> dict[str, Any]:
        seen.append(text)
        return {"name": "lookup_weather", "arguments": json.loads(text)}

    responses = [
        FakeGenerationResponse(text="<tool_call>", token=10),
        FakeGenerationResponse(text='{"note":"see </tool_call> tag"}', token=11),
        FakeGenerationResponse(text="</tool_call>", token=12, finish_reason="stop"),
    ]
    session = _make_fake_session(
        tool_calling={"supported": True, "parser_type": "json_tools"},
        tool_parser=parser,
        tool_call_start="<tool_call>",
        tool_call_end="</tool_call>",
    )
    request = _make_fake_request(tools_json=_tool_call_tools_json())

    events = _collect_events(session, request, _make_deps(responses))

    assert seen == ['{"note":"see ']
    assert events[-1]["kind"] == "failed"
    assert events[-1]["code"] == "tool_call_parse_failed"
    assert len([event for event in events if event["kind"] in {"completed", "failed"}]) == 1


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


def test_prefill_probe_finalizes_without_response_when_progress_is_queued() -> None:
    from orchard_worker_mlx.model_loader import MemoryBudgetStatus

    memory_samples = iter([1_000, 5_000])

    def stream_with_prefill_no_response(model, tokenizer, prompt_ids, **kwargs):
        cb = kwargs.get("prompt_progress_callback")
        if cb:
            cb(10, 100)
        if False:
            yield FakeGenerationResponse(text="never", token=10, finish_reason="stop")

    deps = GenerationDeps(
        stream_generate=stream_with_prefill_no_response,
        make_sampler=lambda **kw: MagicMock(),
        current_memory_bytes=lambda: next(memory_samples),
    )
    session = _make_fake_session(
        memory_budget_status=MemoryBudgetStatus(
            mode="observe",
            budget_available=True,
            headroom_available=True,
            status_code="ok",
            status_message="",
            source="seed",
            max_recommended_working_set_size_bytes=8_000_000_000,
            utilization=0.75,
            target_working_set_bytes=6_000_000_000,
            overhead_bytes=268_435_456,
            resident_memory_bytes=2_048_000,
            estimated_headroom_bytes=5_731_516_544,
            kv_cache_bytes_per_token=16_384,
            prefill_workspace_bytes_per_token=0,
        )
    )

    events = _collect_events(session, _make_fake_request(), deps)

    assert session.memory_budget_status.prefill_workspace_bytes_per_token == 400
    assert events[-1]["kind"] == "completed"


def test_prefill_workspace_probe_updates_memory_budget_from_stream_prefill() -> None:
    from orchard_worker_mlx.model_loader import MemoryBudgetStatus

    memory_samples = iter([1_000, 5_000])

    def stream_with_prefill(model, tokenizer, prompt_ids, **kwargs):
        cb = kwargs.get("prompt_progress_callback")
        if cb:
            cb(10, 100)
        yield FakeGenerationResponse(text="ok", token=10, finish_reason="stop")

    deps = GenerationDeps(
        stream_generate=stream_with_prefill,
        make_sampler=lambda **kw: MagicMock(),
        current_memory_bytes=lambda: next(memory_samples),
    )
    session = _make_fake_session(
        memory_budget_status=MemoryBudgetStatus(
            mode="observe",
            budget_available=True,
            headroom_available=True,
            status_code="ok",
            status_message="",
            source="seed",
            max_recommended_working_set_size_bytes=8_000_000_000,
            utilization=0.75,
            target_working_set_bytes=6_000_000_000,
            overhead_bytes=268_435_456,
            resident_memory_bytes=2_048_000,
            estimated_headroom_bytes=5_731_516_544,
            kv_cache_bytes_per_token=16_384,
            prefill_workspace_bytes_per_token=0,
        )
    )

    _collect_events(session, _make_fake_request(), deps)

    assert session.memory_budget_status.prefill_workspace_bytes_per_token == 400


def test_prefill_workspace_probe_is_high_water_only() -> None:
    from orchard_worker_mlx.model_loader import MemoryBudgetStatus

    memory_samples = iter([2_000, 4_000])

    def stream_with_prefill(model, tokenizer, prompt_ids, **kwargs):
        cb = kwargs.get("prompt_progress_callback")
        if cb:
            cb(10, 100)
        yield FakeGenerationResponse(text="ok", token=10, finish_reason="stop")

    deps = GenerationDeps(
        stream_generate=stream_with_prefill,
        make_sampler=lambda **kw: MagicMock(),
        current_memory_bytes=lambda: next(memory_samples),
    )
    session = _make_fake_session(
        memory_budget_status=MemoryBudgetStatus(
            mode="observe",
            budget_available=True,
            headroom_available=True,
            status_code="ok",
            status_message="",
            source="seed",
            max_recommended_working_set_size_bytes=8_000_000_000,
            utilization=0.75,
            target_working_set_bytes=6_000_000_000,
            overhead_bytes=268_435_456,
            resident_memory_bytes=2_048_000,
            estimated_headroom_bytes=5_731_516_544,
            kv_cache_bytes_per_token=16_384,
            prefill_workspace_bytes_per_token=300,
        )
    )

    _collect_events(session, _make_fake_request(), deps)

    assert session.memory_budget_status.prefill_workspace_bytes_per_token == 300


def test_prefill_workspace_probe_fail_open_paths_leave_value_unchanged() -> None:
    from orchard_worker_mlx.model_loader import MemoryBudgetStatus

    def _run_with(stream_fn, probe_fn):
        session = _make_fake_session(
            memory_budget_status=MemoryBudgetStatus(
                prefill_workspace_bytes_per_token=111,
            )
        )
        deps = GenerationDeps(
            stream_generate=stream_fn,
            make_sampler=lambda **kw: MagicMock(),
            current_memory_bytes=probe_fn,
        )
        _collect_events(session, _make_fake_request(), deps)
        return session.memory_budget_status.prefill_workspace_bytes_per_token

    def stream_with_zero_tokens(model, tokenizer, prompt_ids, **kwargs):
        cb = kwargs.get("prompt_progress_callback")
        if cb:
            cb(0, 100)
        yield FakeGenerationResponse(text="ok", token=10, finish_reason="stop")

    def stream_with_progress(model, tokenizer, prompt_ids, **kwargs):
        cb = kwargs.get("prompt_progress_callback")
        if cb:
            cb(10, 100)
        yield FakeGenerationResponse(text="ok", token=10, finish_reason="stop")

    assert _run_with(stream_with_progress, lambda: None) == 111
    assert _run_with(stream_with_progress, lambda: True) == 111
    assert _run_with(stream_with_progress, lambda: False) == 111
    assert _run_with(stream_with_progress, lambda: "bad") == 111
    assert _run_with(stream_with_progress, lambda: -1) == 111
    assert _run_with(stream_with_progress, lambda: 2**64) == 111

    def raising_probe():
        raise RuntimeError("boom")

    assert _run_with(stream_with_progress, raising_probe) == 111
    assert _run_with(stream_with_zero_tokens, lambda: 1_000) == 111

    negative_delta_samples = iter([5_000, 1_000])
    assert _run_with(stream_with_progress, lambda: next(negative_delta_samples)) == 111


def test_prefill_workspace_probe_skips_shared_batch_runtime_without_probe_calls() -> None:
    from orchard_worker_mlx.model_loader import MemoryBudgetStatus

    probe_calls = 0

    def current_memory_bytes() -> int:
        nonlocal probe_calls
        probe_calls += 1
        return 1_000

    def stream_shared_runtime(model, tokenizer, prompt_ids, **kwargs):
        cb = kwargs.get("prompt_progress_callback")
        if cb:
            cb(10, 100)
        yield FakeGenerationResponse(text="ok", token=10, finish_reason="stop")

    deps = GenerationDeps(
        stream_generate=stream_shared_runtime,
        make_sampler=lambda **kw: MagicMock(),
        current_memory_bytes=current_memory_bytes,
        uses_shared_batch_runtime=True,
    )
    session = _make_fake_session(
        memory_budget_status=MemoryBudgetStatus(prefill_workspace_bytes_per_token=123)
    )

    _collect_events(session, _make_fake_request(), deps)

    assert probe_calls == 0
    assert session.memory_budget_status.prefill_workspace_bytes_per_token == 123


def test_prefill_workspace_update_helper_skips_invalid_budget_container() -> None:
    session = _make_fake_session(memory_budget_status={"prefill_workspace_bytes_per_token": 100})

    _update_session_prefill_workspace_bytes_per_token_high_water(session, 250)

    assert session.memory_budget_status == {"prefill_workspace_bytes_per_token": 100}


def test_prefill_workspace_update_helper_preserves_other_budget_fields() -> None:
    from orchard_worker_mlx.model_loader import MemoryBudgetStatus

    session = _make_fake_session(
        memory_budget_status=MemoryBudgetStatus(
            mode="observe",
            budget_available=True,
            headroom_available=True,
            status_code="ok",
            status_message="ready",
            source="seed",
            max_recommended_working_set_size_bytes=8_000_000_000,
            utilization=0.75,
            target_working_set_bytes=6_000_000_000,
            overhead_bytes=268_435_456,
            resident_memory_bytes=2_048_000,
            estimated_headroom_bytes=5_731_516_544,
            kv_cache_bytes_per_token=16_384,
            prefill_workspace_bytes_per_token=100,
        )
    )

    original = session.memory_budget_status
    _update_session_prefill_workspace_bytes_per_token_high_water(session, 250)

    updated = session.memory_budget_status
    assert updated is not original
    assert updated.prefill_workspace_bytes_per_token == 250
    assert updated.status_code == "ok"
    assert updated.target_working_set_bytes == 6_000_000_000
    assert updated.kv_cache_bytes_per_token == 16_384


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


def test_callback_drops_processed_regression_when_total_increases() -> None:
    q: deque[tuple[int, int]] = deque()
    cb = _make_prefill_progress_callback(q)
    cb(90, 100)
    cb(50, 200)  # processed regressed even though total increased
    assert len(q) == 1
    assert q[0] == (90, 100)


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


def test_stream_finally_synchronizes_before_clear() -> None:
    calls: list[str] = []
    responses = [
        FakeGenerationResponse(text="Hi", token=10, finish_reason="stop"),
    ]
    session = _make_fake_session(clear_cache=lambda: calls.append("clear"))
    request = _make_fake_request()
    deps = _make_deps(responses, synchronize=lambda: calls.append("synchronize"))

    _collect_events(session, request, deps)

    assert calls == ["synchronize", "clear"]


def test_stream_finally_clears_when_synchronize_raises() -> None:
    calls: list[str] = []
    responses = [
        FakeGenerationResponse(text="Hi", token=10, finish_reason="stop"),
    ]

    def synchronize() -> None:
        calls.append("synchronize")
        raise RuntimeError("sync boom")

    session = _make_fake_session(clear_cache=lambda: calls.append("clear"))
    request = _make_fake_request()
    deps = _make_deps(responses, synchronize=synchronize)

    _collect_events(session, request, deps)

    assert calls == ["synchronize", "clear"]


def test_stream_finally_without_synchronize_still_clears_fail_open() -> None:
    clear_mock = MagicMock(name="clear_cache")
    responses = [
        FakeGenerationResponse(text="Hi", token=10, finish_reason="stop"),
    ]
    session = _make_fake_session(clear_cache=clear_mock)
    request = _make_fake_request()
    deps = _make_deps(responses, synchronize=None)

    _collect_events(session, request, deps)

    clear_mock.assert_called_once()


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
    first = next(event for event in it if event["kind"] != "usage")
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
        self.register_calls: list[tuple[str, tuple[int, ...]]] = []

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

    def register_fingerprint(self, fingerprint: str, entry_key: tuple[int, ...]) -> None:
        self.register_calls.append((fingerprint, entry_key))


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


def test_completed_store_registers_valid_cache_affinity_fingerprint() -> None:
    fake_cache = FakePrefixCache(lookup_result=None)
    responses = [
        FakeGenerationResponse(text="A", token=50),
        FakeGenerationResponse(text="", token=51, finish_reason="stop"),
    ]
    deps, _, _ = _cache_deps(responses)
    session = _make_fake_session(prefix_cache=fake_cache)
    session.tokenizer.encode.return_value = [1, 2, 3]
    request = _make_fake_request()
    request.cache_affinity_fingerprint = "hmac-sha256:" + "a" * 64

    events = _collect_events(session, request, deps)

    assert events[-1]["kind"] == "completed"
    assert fake_cache.register_calls == [
        (request.cache_affinity_fingerprint, (1, 2, 3, 50, 51)),
    ]


def test_skipped_or_failed_store_does_not_register_fingerprint() -> None:
    request = _make_fake_request()
    request.cache_affinity_fingerprint = "hmac-sha256:" + "a" * 64

    truthy_cache = FakePrefixCache(lookup_result=None, store_result=1)
    truthy_deps, _, _ = _cache_deps(
        [FakeGenerationResponse(text="ok", token=1, finish_reason="stop")]
    )
    truthy_session = _make_fake_session(prefix_cache=truthy_cache)
    _collect_events(truthy_session, request, truthy_deps)

    skipped_cache = FakePrefixCache(lookup_result=None, store_result=False)
    skipped_deps, _, _ = _cache_deps(
        [FakeGenerationResponse(text="ok", token=1, finish_reason="stop")]
    )
    skipped_session = _make_fake_session(prefix_cache=skipped_cache)
    _collect_events(skipped_session, request, skipped_deps)

    failed_cache = FakePrefixCache(lookup_result=None, store_side_effect=RuntimeError("boom"))
    failed_deps, _, _ = _cache_deps(
        [FakeGenerationResponse(text="ok", token=1, finish_reason="stop")]
    )
    failed_session = _make_fake_session(prefix_cache=failed_cache)
    _collect_events(failed_session, request, failed_deps)

    assert truthy_cache.register_calls == []
    assert skipped_cache.register_calls == []
    assert failed_cache.register_calls == []


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
