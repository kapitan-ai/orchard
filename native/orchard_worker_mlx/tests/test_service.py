"""Unit tests for service.py: terminal hardening, event mapping, tombstone TTL."""

from __future__ import annotations

import json
import logging
import re
import threading
from collections.abc import Iterator
from types import SimpleNamespace
from typing import Any
from unittest.mock import MagicMock

import pytest

from orchard_worker_mlx.backends import (
    Backend,
    BackendError,
    BackendHealth,
    BackendStatus,
    StubBackend,
)
from orchard_worker_mlx.generated.orchard.worker.v1 import worker_runtime_pb2
from orchard_worker_mlx.model_loader import (
    GenerationRuntimeConfig,
    MemoryBudgetConfig,
    PrefixCacheLoadConfig,
)
from orchard_worker_mlx.service import (
    WorkerRuntimeServicer,
    _derive_server_max_workers,
    build_inference_event,
    build_server,
)

# ---------------------------------------------------------------------------
# Test helpers / fake backends
# ---------------------------------------------------------------------------


class HappyBackend:
    """Yields progress, usage, deltas, then completed."""

    def __init__(self, events: list[dict[str, Any]] | None = None) -> None:
        self._events = events or [
            {"kind": "progress", "stage": "prefill", "message": "processing 10 tokens"},
            {"kind": "output_text_delta", "delta": "hello "},
            {"kind": "output_text_delta", "delta": "world"},
            {
                "kind": "usage",
                "usage": {"input_tokens": 5, "output_tokens": 2, "total_tokens": 7},
            },
            {
                "kind": "completed",
                "finish_reason": "FINISH_REASON_STOP",
                "usage": {"input_tokens": 5, "output_tokens": 2, "total_tokens": 7},
            },
        ]
        self._loaded = False
        self._active = False
        self.recorded_fingerprints: list[str] = []

    def status(self) -> BackendStatus:
        return BackendStatus(loaded=self._loaded, active_request_count=int(self._active))

    def health(self) -> BackendHealth:
        return BackendHealth(ready=True, code="", message="")

    def prefix_cache_status(self) -> dict[str, Any]:
        return {
            "implementation": "unknown",
            "enabled": True,
            "entry_count": 0,
            "total_bytes": 0,
            "hits": 0,
            "misses": 0,
            "failures": 0,
            "stores": 0,
            "evictions": 0,
            "configured_max_entries": 0,
            "configured_max_bytes": 0,
            "status_code": "unavailable",
            "status_message": "prefix cache unavailable",
            "session_started_unix_ms": 0,
            "prefix_cache_fingerprints": list(self.recorded_fingerprints),
        }

    def load_model(self, *, model_id: str, version: str, model_path: str) -> None:
        self._loaded = True

    def unload_model(self) -> None:
        self._loaded = False

    def start_generation(self) -> None:
        self._active = True

    def finish_generation(self) -> None:
        self._active = False

    def record_fingerprint(self, fingerprint: str) -> None:
        self.recorded_fingerprints.append(fingerprint)

    def get_fingerprints(self) -> list[str]:
        return list(self.recorded_fingerprints)

    def generate(self, request: Any, cancel_event: threading.Event) -> Iterator[dict[str, Any]]:
        yield from self._events


class InvalidEventBackend(HappyBackend):
    """Emits an accepted event (invalid for workers)."""

    def __init__(self) -> None:
        super().__init__(
            events=[
                {"kind": "output_text_delta", "delta": "hi"},
                {"kind": "accepted"},  # INVALID
            ]
        )


class CrashingBackend(HappyBackend):
    """Raises RuntimeError during generate."""

    def generate(self, request: Any, cancel_event: threading.Event) -> Iterator[dict[str, Any]]:
        yield {"kind": "output_text_delta", "delta": "before crash"}
        raise RuntimeError("unexpected kaboom")


class MidIterationBackendErrorBackend(HappyBackend):
    """Raises BackendError mid-iteration after yielding one valid delta."""

    def generate(self, request: Any, cancel_event: threading.Event) -> Iterator[dict[str, Any]]:
        yield {"kind": "output_text_delta", "delta": "partial output"}
        raise BackendError(
            "generation_failed",
            "generation runner failed mid-stream",
            retryable=True,
        )


class MissingTerminalBackend(HappyBackend):
    """Yields only non-terminal events then stops."""

    def __init__(self) -> None:
        super().__init__(
            events=[
                {"kind": "output_text_delta", "delta": "chunk1"},
                {"kind": "output_text_delta", "delta": "chunk2"},
            ]
        )


class StartGenerationCrashBackend(HappyBackend):
    """Crashes in start_generation."""

    def start_generation(self) -> None:
        raise RuntimeError("start boom")


class ConcurrentGenerateBackend(HappyBackend):
    """Backend that allows two concurrent Generate calls and tracks peak concurrency."""

    def __init__(self) -> None:
        super().__init__(events=[])
        self._loaded = True
        self._active_count = 0
        self._peak_count = 0
        self._lock = threading.Lock()
        self._entered = threading.Event()

    @property
    def peak_count(self) -> int:
        with self._lock:
            return self._peak_count

    def start_generation(self) -> None:
        with self._lock:
            self._active = True
            self._active_count += 1
            self._peak_count = max(self._peak_count, self._active_count)
            if self._active_count >= 2:
                self._entered.set()

    def finish_generation(self) -> None:
        with self._lock:
            self._active_count = max(0, self._active_count - 1)
            self._active = self._active_count > 0

    def generate(self, request: Any, cancel_event: threading.Event) -> Iterator[dict[str, Any]]:
        self._entered.wait(timeout=2.0)
        if cancel_event.is_set():
            yield {
                "kind": "failed",
                "code": "cancelled",
                "message": "request cancelled",
                "retryable": False,
            }
            return

        yield {"kind": "output_text_delta", "delta": f"hello-{request.request_id}"}
        yield {
            "kind": "completed",
            "finish_reason": "FINISH_REASON_STOP",
            "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2},
        }


class _ClosableEventIterator:
    def __init__(self, events: list[dict[str, Any]]) -> None:
        self._iterator = iter(events)
        self.closed = False

    def __iter__(self) -> _ClosableEventIterator:
        return self

    def __next__(self) -> dict[str, Any]:
        return next(self._iterator)

    def close(self) -> None:
        self.closed = True


class TerminalBreakCloseBackend(HappyBackend):
    def __init__(self) -> None:
        super().__init__(events=[])
        self.iterator = _ClosableEventIterator(
            [
                {"kind": "output_text_delta", "delta": "before terminal"},
                {
                    "kind": "completed",
                    "finish_reason": "FINISH_REASON_STOP",
                    "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2},
                },
                {"kind": "output_text_delta", "delta": "after terminal"},
            ]
        )

    def generate(self, request: Any, cancel_event: threading.Event) -> Iterator[dict[str, Any]]:
        del request, cancel_event
        return self.iterator


# -- Helpers -----------------------------------------------------------------


def _make_servicer(
    backend: Backend,
    *,
    clock_time: float = 0.0,
    ttl: float = 60.0,
) -> WorkerRuntimeServicer:
    return WorkerRuntimeServicer(
        backend,
        clock=lambda: clock_time,
        cancel_tombstone_ttl_s=ttl,
    )


def _make_request(request_id: str = "req-1") -> MagicMock:
    req = MagicMock()
    req.request_id = request_id
    req.input_tokens = 5
    req.metadata_json = b""
    return req


def _fingerprint(seed: int) -> str:
    return f"hmac-sha256:{seed:064x}"


def _make_cancel_request(request_id: str = "req-1") -> MagicMock:
    req = MagicMock()
    req.request_id = request_id
    return req


def _collect_events(servicer: WorkerRuntimeServicer, request_id: str = "req-1"):
    """Run Generate and collect all proto events."""
    request = _make_request(request_id)
    context = MagicMock()
    return list(servicer.Generate(request, context))


def test_build_server_passes_config_objects_to_backend_factory() -> None:
    captured: dict[str, Any] = {}
    prefix_cache_config = PrefixCacheLoadConfig(mode="trie", max_entries=4)
    generation_config = GenerationRuntimeConfig(mode="batch", max_concurrent_generations=2)
    memory_budget_config = MemoryBudgetConfig(mode="observe", utilization=0.75)

    def backend_factory(name: str, **kwargs: Any) -> Backend:
        captured["name"] = name
        captured.update(kwargs)
        return StubBackend()

    server = build_server(
        "stub",
        backend_factory=backend_factory,
        prefix_cache_config=prefix_cache_config,
        generation_config=generation_config,
        memory_budget_config=memory_budget_config,
    )

    assert captured["name"] == "stub"
    assert captured["prefix_cache_config"] == prefix_cache_config
    assert captured["generation_config"] == generation_config
    assert captured["memory_budget_config"] == memory_budget_config
    server.stop(grace=0)


def test_derive_server_max_workers_defaults_to_minimum_for_stream() -> None:
    assert _derive_server_max_workers(None) == 4
    assert _derive_server_max_workers(GenerationRuntimeConfig(mode="stream")) == 4


def test_derive_server_max_workers_scales_with_batch_concurrency() -> None:
    config = GenerationRuntimeConfig(mode="batch", max_concurrent_generations=6)
    assert _derive_server_max_workers(config) == 8


# ---------------------------------------------------------------------------
# Test: progress and usage event mapping
# ---------------------------------------------------------------------------


def test_generate_records_valid_non_empty_fingerprint_and_get_status_publishes_it() -> None:
    backend = HappyBackend()
    servicer = _make_servicer(backend)
    request = _make_request("req-fingerprint")
    request.cache_affinity_fingerprint = _fingerprint(1)

    list(servicer.Generate(request, MagicMock()))
    status = servicer.GetStatus(worker_runtime_pb2.WorkerStatusRequest(), None)

    assert backend.recorded_fingerprints == [_fingerprint(1)]
    assert list(status.prefix_cache.prefix_cache_fingerprints) == [_fingerprint(1)]


def test_generate_ignores_empty_fingerprint() -> None:
    backend = HappyBackend()
    servicer = _make_servicer(backend)
    request = _make_request("req-empty-fingerprint")
    request.cache_affinity_fingerprint = ""

    list(servicer.Generate(request, MagicMock()))

    assert backend.recorded_fingerprints == []


def test_get_status_caps_fingerprints_to_protocol_limit() -> None:
    fingerprints = [_fingerprint(index) for index in range(70)]

    servicer = WorkerRuntimeServicer(
        PrefixCacheStatusBackend(
            prefix_cache_status={
                "implementation": "kv",
                "enabled": True,
                "entry_count": 1,
                "total_bytes": 128,
                "hits": 1,
                "misses": 0,
                "failures": 0,
                "stores": 1,
                "evictions": 0,
                "configured_max_entries": 8,
                "configured_max_bytes": 0,
                "status_code": "ok",
                "status_message": "",
                "session_started_unix_ms": 1,
                "prefix_cache_fingerprints": fingerprints,
            }
        )
    )

    status = servicer.GetStatus(worker_runtime_pb2.WorkerStatusRequest(), None)

    assert list(status.prefix_cache.prefix_cache_fingerprints) == fingerprints[:64]


def test_unload_model_clears_published_fingerprints_when_backend_clears_state() -> None:
    class ClearingFingerprintBackend(HappyBackend):
        def unload_model(self) -> None:
            self.recorded_fingerprints.clear()
            super().unload_model()

    backend = ClearingFingerprintBackend()
    servicer = _make_servicer(backend)

    request = _make_request("req-clear-fingerprint")
    request.cache_affinity_fingerprint = _fingerprint(1)
    list(servicer.Generate(request, MagicMock()))

    before_unload = servicer.GetStatus(worker_runtime_pb2.WorkerStatusRequest(), None)
    assert list(before_unload.prefix_cache.prefix_cache_fingerprints) == [_fingerprint(1)]

    ack = servicer.UnloadModel(MagicMock(), MagicMock())
    assert ack.ok is True

    after_unload = servicer.GetStatus(worker_runtime_pb2.WorkerStatusRequest(), None)
    assert list(after_unload.prefix_cache.prefix_cache_fingerprints) == []


def test_get_status_drops_malformed_backend_fingerprints() -> None:
    servicer = WorkerRuntimeServicer(
        PrefixCacheStatusBackend(
            prefix_cache_status={
                "implementation": "kv",
                "enabled": True,
                "entry_count": 1,
                "total_bytes": 128,
                "hits": 1,
                "misses": 0,
                "failures": 0,
                "stores": 1,
                "evictions": 0,
                "configured_max_entries": 8,
                "configured_max_bytes": 0,
                "status_code": "ok",
                "status_message": "",
                "session_started_unix_ms": 1,
                "prefix_cache_fingerprints": [
                    _fingerprint(1),
                    "hmac-sha256:" + "A" * 64,
                    "not-a-fingerprint",
                ],
            }
        )
    )

    status = servicer.GetStatus(worker_runtime_pb2.WorkerStatusRequest(), None)

    assert list(status.prefix_cache.prefix_cache_fingerprints) == [_fingerprint(1)]


def test_happy_path_maps_progress_usage_and_completed() -> None:
    servicer = _make_servicer(HappyBackend())
    events = _collect_events(servicer)

    kinds = [e.WhichOneof("event") for e in events]
    assert kinds == ["progress", "output_text_delta", "output_text_delta", "usage", "completed"]

    # Verify progress fields
    assert events[0].progress.stage == "prefill"
    assert events[0].progress.message == "processing 10 tokens"

    # Verify usage fields
    assert events[3].usage.usage.input_tokens == 5
    assert events[3].usage.usage.output_tokens == 2
    assert events[3].usage.usage.total_tokens == 7

    # Verify completed
    assert events[4].completed.usage.total_tokens == 7


# ---------------------------------------------------------------------------
# Test: accepted is rejected
# ---------------------------------------------------------------------------


def test_accepted_event_from_backend_produces_terminal_failure() -> None:
    servicer = _make_servicer(InvalidEventBackend())
    events = _collect_events(servicer)

    # Should see the first valid delta, then a terminal failure (accepted rejected)
    kinds = [e.WhichOneof("event") for e in events]
    assert kinds[-1] == "failed"
    assert events[-1].failed.code == "backend_invalid_event"
    assert "accepted" in events[-1].failed.message


# ---------------------------------------------------------------------------
# Test: unexpected backend exception becomes terminal failure
# ---------------------------------------------------------------------------


def test_backend_crash_produces_terminal_failure() -> None:
    servicer = _make_servicer(CrashingBackend())
    events = _collect_events(servicer)

    kinds = [e.WhichOneof("event") for e in events]
    assert kinds[-1] == "failed"
    assert events[-1].failed.code == "backend_crash"
    assert "kaboom" in events[-1].failed.message


def test_backend_error_mid_iteration_produces_terminal_failure() -> None:
    """BackendError raised mid-iteration preserves prior deltas and synthesizes terminal."""
    servicer = _make_servicer(MidIterationBackendErrorBackend())
    events = _collect_events(servicer)

    kinds = [e.WhichOneof("event") for e in events]
    assert kinds == ["output_text_delta", "failed"]

    # Prior delta preserved.
    assert events[0].output_text_delta.delta == "partial output"

    # Terminal failure from BackendError fields (not generic crash).
    assert events[-1].failed.code == "generation_failed"
    assert "mid-stream" in events[-1].failed.message
    assert events[-1].failed.retryable is True


def test_start_generation_crash_produces_terminal_failure() -> None:
    servicer = _make_servicer(StartGenerationCrashBackend())
    events = _collect_events(servicer)

    assert len(events) == 1
    assert events[0].failed.code == "backend_crash"
    assert "start boom" in events[0].failed.message


# ---------------------------------------------------------------------------
# Test: missing terminal becomes terminal failure
# ---------------------------------------------------------------------------


def test_missing_terminal_produces_backend_missing_terminal() -> None:
    servicer = _make_servicer(MissingTerminalBackend())
    events = _collect_events(servicer)

    kinds = [e.WhichOneof("event") for e in events]
    assert kinds == ["output_text_delta", "output_text_delta", "failed"]
    assert events[-1].failed.code == "backend_missing_terminal"


# ---------------------------------------------------------------------------
# Test: exactly one terminal event per generation
# ---------------------------------------------------------------------------


def test_no_events_after_terminal() -> None:
    """Backend yields events after completed; service should stop at terminal."""
    extra_after_terminal = HappyBackend(
        events=[
            {"kind": "output_text_delta", "delta": "ok"},
            {
                "kind": "completed",
                "finish_reason": "FINISH_REASON_STOP",
                "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2},
            },
            {"kind": "output_text_delta", "delta": "should not appear"},
        ]
    )
    servicer = _make_servicer(extra_after_terminal)
    events = _collect_events(servicer)

    kinds = [e.WhichOneof("event") for e in events]
    assert kinds == ["output_text_delta", "completed"]


# ---------------------------------------------------------------------------
# Test: cancel-before-generate within TTL stays deterministic
# ---------------------------------------------------------------------------


def test_cancel_before_generate_within_ttl() -> None:
    clock_time = 100.0
    servicer = _make_servicer(HappyBackend(), clock_time=clock_time, ttl=60.0)
    context = MagicMock()

    # Cancel first
    servicer.Cancel(_make_cancel_request("req-1"), context)

    # Generate should return immediate cancelled
    events = _collect_events(servicer, "req-1")
    assert len(events) == 1
    assert events[0].failed.code == "cancelled"
    assert events[0].failed.message == "request cancelled"


# ---------------------------------------------------------------------------
# Test: cancel tombstone TTL expires
# ---------------------------------------------------------------------------


def test_cancel_tombstone_expires_after_ttl() -> None:
    """After TTL expires, Generate proceeds normally (tombstone pruned)."""
    times = [100.0]  # mutable clock

    def clock() -> float:
        return times[0]

    servicer = WorkerRuntimeServicer(
        HappyBackend(),
        clock=clock,
        cancel_tombstone_ttl_s=10.0,
    )
    context = MagicMock()

    # Cancel at t=100 -> tombstone expires at t=110
    servicer.Cancel(_make_cancel_request("req-1"), context)

    # Advance clock past TTL
    times[0] = 111.0

    # Generate should proceed normally (tombstone expired)
    events = _collect_events(servicer, "req-1")
    kinds = [e.WhichOneof("event") for e in events]
    assert "completed" in kinds
    # No "cancelled" in the stream
    assert all(e.WhichOneof("event") != "failed" or e.failed.code != "cancelled" for e in events)


def test_cancel_tombstone_pruned_from_internal_state() -> None:
    """Verify expired tombstones are actually removed."""
    times = [100.0]

    def clock() -> float:
        return times[0]

    servicer = WorkerRuntimeServicer(
        HappyBackend(),
        clock=clock,
        cancel_tombstone_ttl_s=10.0,
    )
    context = MagicMock()

    # Create tombstones
    servicer.Cancel(_make_cancel_request("req-a"), context)
    servicer.Cancel(_make_cancel_request("req-b"), context)
    assert len(servicer._cancel_entries) == 2

    # Advance past TTL, trigger pruning via Cancel for a different request
    times[0] = 200.0
    servicer.Cancel(_make_cancel_request("req-c"), context)

    # req-a and req-b should be pruned, only req-c remains
    assert "req-a" not in servicer._cancel_entries
    assert "req-b" not in servicer._cancel_entries
    assert "req-c" in servicer._cancel_entries


# ---------------------------------------------------------------------------
# Test: UnloadModel during active generation
# ---------------------------------------------------------------------------


class BusyBackend(HappyBackend):
    """A backend that reports active generation on unload."""

    def __init__(self) -> None:
        super().__init__()
        self._loaded = True
        self._busy = True

    def unload_model(self) -> None:
        if self._busy:
            raise BackendError("model_busy", "cannot unload: active generation in progress")
        self._loaded = False


def test_unload_model_during_generation_returns_ack_false() -> None:
    servicer = _make_servicer(BusyBackend())
    request = MagicMock()
    context = MagicMock()
    ack = servicer.UnloadModel(request, context)
    assert ack.ok is False
    assert "model_busy" in ack.message


def test_unload_model_success_returns_ack_true() -> None:
    servicer = _make_servicer(HappyBackend())
    request = MagicMock()
    context = MagicMock()
    ack = servicer.UnloadModel(request, context)
    assert ack.ok is True
    assert ack.message == "model unloaded"


# ---------------------------------------------------------------------------
# Test: build_inference_event validation
# ---------------------------------------------------------------------------


def test_build_inference_event_rejects_accepted() -> None:
    with pytest.raises(BackendError) as exc_info:
        build_inference_event({"kind": "accepted"})
    assert exc_info.value.code == "backend_invalid_event"


def test_build_inference_event_rejects_unknown_kind() -> None:
    with pytest.raises(BackendError) as exc_info:
        build_inference_event({"kind": "magic_event"})
    assert exc_info.value.code == "backend_invalid_event"


def test_build_inference_event_rejects_missing_kind() -> None:
    with pytest.raises(BackendError) as exc_info:
        build_inference_event({"no_kind": True})
    assert exc_info.value.code == "backend_invalid_event"


def test_build_inference_event_validates_output_text_delta() -> None:
    with pytest.raises(BackendError) as exc_info:
        build_inference_event({"kind": "output_text_delta", "delta": 123})
    assert "must be str" in exc_info.value.message


def test_build_inference_event_validates_progress_stage() -> None:
    with pytest.raises(BackendError):
        build_inference_event({"kind": "progress", "stage": "", "message": "ok"})


def test_build_inference_event_validates_usage_totals() -> None:
    with pytest.raises(BackendError) as exc_info:
        build_inference_event(
            {
                "kind": "usage",
                "usage": {"input_tokens": 5, "output_tokens": 3, "total_tokens": 99},
            }
        )
    assert "total_tokens" in exc_info.value.message


def test_build_inference_event_validates_failed_code() -> None:
    with pytest.raises(BackendError):
        build_inference_event({"kind": "failed", "code": "", "message": "x", "retryable": False})


def test_build_inference_event_validates_failed_retryable_type() -> None:
    with pytest.raises(BackendError) as exc_info:
        build_inference_event({"kind": "failed", "code": "x", "message": "x", "retryable": 1})
    assert "retryable must be bool" in exc_info.value.message


def test_build_inference_event_progress_happy_path() -> None:
    event = build_inference_event({"kind": "progress", "stage": "prefill", "message": "50%"})
    assert event.progress.stage == "prefill"
    assert event.progress.message == "50%"


def test_build_inference_event_usage_happy_path() -> None:
    event = build_inference_event(
        {
            "kind": "usage",
            "usage": {"input_tokens": 10, "output_tokens": 5, "total_tokens": 15},
        }
    )
    assert event.usage.usage.total_tokens == 15


def test_build_inference_event_tool_call_delta_happy_path() -> None:
    event = build_inference_event(
        {
            "kind": "tool_call_delta",
            "tool_call_id": "call_0",
            "delta": {
                "index": 0,
                "type": "function",
                "function": {
                    "name": "lookup_weather",
                    "arguments_delta": '{"city":"Singapore"}',
                },
            },
        }
    )

    assert event.WhichOneof("event") == "tool_call_delta"
    assert event.tool_call_delta.tool_call_id == "call_0"
    assert json.loads(event.tool_call_delta.delta_json) == {
        "index": 0,
        "type": "function",
        "function": {
            "name": "lookup_weather",
            "arguments_delta": '{"city":"Singapore"}',
        },
    }


def test_build_inference_event_accepts_incremental_tool_call_delta_without_name() -> None:
    event = build_inference_event(
        {
            "kind": "tool_call_delta",
            "tool_call_id": "call_0",
            "delta": {
                "index": 0,
                "type": "function",
                "function": {
                    "arguments_delta": '{"city":"Sing',
                },
            },
        }
    )

    assert json.loads(event.tool_call_delta.delta_json) == {
        "index": 0,
        "type": "function",
        "function": {
            "arguments_delta": '{"city":"Sing',
        },
    }


def test_build_inference_event_accepts_name_only_tool_call_delta() -> None:
    event = build_inference_event(
        {
            "kind": "tool_call_delta",
            "tool_call_id": "call_0",
            "delta": {
                "index": 0,
                "function": {
                    "name": "lookup_weather",
                },
            },
        }
    )

    assert json.loads(event.tool_call_delta.delta_json) == {
        "index": 0,
        "function": {
            "name": "lookup_weather",
        },
    }


def test_build_inference_event_rejects_invalid_tool_call_delta_shape() -> None:
    with pytest.raises(BackendError) as exc_info:
        build_inference_event(
            {
                "kind": "tool_call_delta",
                "tool_call_id": "call_0",
                "delta": {"index": 0},
            }
        )
    assert exc_info.value.code == "backend_invalid_event"
    assert "tool_call_delta.delta" in exc_info.value.message


def test_build_inference_event_accepts_tool_calls_finish_reason() -> None:
    event = build_inference_event(
        {
            "kind": "completed",
            "finish_reason": "FINISH_REASON_TOOL_CALLS",
            "usage": {"input_tokens": 5, "output_tokens": 2, "total_tokens": 7},
        }
    )
    assert event.completed.finish_reason == 3


# ---------------------------------------------------------------------------
# Test: cancel-during-active-generation at service level (Task 4)
# ---------------------------------------------------------------------------


class SlowBackend(HappyBackend):
    """Backend that yields with a delay, allowing Cancel to arrive mid-stream."""

    def __init__(self, *, cancel_event_ref: list[threading.Event]) -> None:
        super().__init__(events=[])
        self._cancel_event_ref = cancel_event_ref

    def generate(self, request: Any, cancel_event: threading.Event) -> Iterator[dict[str, Any]]:
        self._cancel_event_ref.append(cancel_event)
        yield {"kind": "output_text_delta", "delta": "first"}
        # Wait for cancel to be set externally
        cancel_event.wait(timeout=2.0)
        if cancel_event.is_set():
            yield {
                "kind": "failed",
                "code": "cancelled",
                "message": "request cancelled",
                "retryable": False,
            }
            return
        yield {
            "kind": "completed",
            "finish_reason": "FINISH_REASON_STOP",
            "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2},
        }


def test_cancel_mid_stream_produces_single_terminal() -> None:
    """Cancel RPC arriving mid-stream produces exactly one terminal failure."""
    cancel_event_ref: list[threading.Event] = []
    backend = SlowBackend(cancel_event_ref=cancel_event_ref)
    servicer = _make_servicer(backend)
    context = MagicMock()
    request = _make_request("req-mid")

    # Start generate in a thread
    collected: list[Any] = []
    generate_done = threading.Event()

    def run_generate():
        for event in servicer.Generate(request, context):
            collected.append(event)
        generate_done.set()

    t = threading.Thread(target=run_generate)
    t.start()

    # Wait for the cancel event reference to be set (backend is running)
    import time

    for _ in range(100):
        if cancel_event_ref:
            break
        time.sleep(0.01)

    # Send Cancel RPC
    servicer.Cancel(_make_cancel_request("req-mid"), context)

    generate_done.wait(timeout=5.0)
    t.join(timeout=1.0)

    assert generate_done.is_set(), "Generate did not complete"

    kinds = [e.WhichOneof("event") for e in collected]
    # Should have the first delta + exactly one terminal
    assert "output_text_delta" in kinds
    terminals = [k for k in kinds if k in ("completed", "failed")]
    assert len(terminals) == 1
    assert terminals[0] == "failed"
    assert collected[-1].failed.code == "cancelled"


def test_generate_supports_two_concurrent_servicer_calls() -> None:
    backend = ConcurrentGenerateBackend()
    servicer = _make_servicer(backend)
    context = MagicMock()

    results: dict[str, list[Any]] = {}

    def run(req_id: str) -> None:
        results[req_id] = list(servicer.Generate(_make_request(req_id), context))

    t1 = threading.Thread(target=run, args=("req-1",))
    t2 = threading.Thread(target=run, args=("req-2",))
    t1.start()
    t2.start()
    t1.join(timeout=3.0)
    t2.join(timeout=3.0)

    assert t1.is_alive() is False
    assert t2.is_alive() is False
    assert backend.peak_count >= 2

    assert [event.WhichOneof("event") for event in results["req-1"]] == [
        "output_text_delta",
        "completed",
    ]
    assert [event.WhichOneof("event") for event in results["req-2"]] == [
        "output_text_delta",
        "completed",
    ]


def test_generate_closes_backend_iterator_after_terminal_break() -> None:
    backend = TerminalBreakCloseBackend()
    servicer = _make_servicer(backend)

    events = _collect_events(servicer)

    assert [event.WhichOneof("event") for event in events] == ["output_text_delta", "completed"]
    assert backend.iterator.closed is True


# ---------------------------------------------------------------------------
# Test: post-failed events suppressed at service level (Task 4)
# ---------------------------------------------------------------------------


class PostFailedBackend(HappyBackend):
    """Emits a failed event followed by more events."""

    def __init__(self) -> None:
        super().__init__(
            events=[
                {"kind": "output_text_delta", "delta": "before"},
                {
                    "kind": "failed",
                    "code": "generation_failed",
                    "message": "something went wrong",
                    "retryable": False,
                },
                {"kind": "output_text_delta", "delta": "after failed"},
                {
                    "kind": "completed",
                    "finish_reason": "FINISH_REASON_STOP",
                    "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2},
                },
            ]
        )


def test_post_failed_events_suppressed() -> None:
    """Events after a failed terminal are suppressed by service layer."""
    servicer = _make_servicer(PostFailedBackend())
    events = _collect_events(servicer)

    kinds = [e.WhichOneof("event") for e in events]
    assert kinds == ["output_text_delta", "failed"]
    assert events[-1].failed.code == "generation_failed"


# ---------------------------------------------------------------------------
# Lifecycle logging tests
# ---------------------------------------------------------------------------


def test_load_model_logs_lifecycle(caplog: pytest.LogCaptureFixture) -> None:
    """LoadModel emits start and ok log lines."""
    from orchard_worker_mlx.generated.orchard.worker.v1 import worker_runtime_pb2

    servicer = _make_servicer(StubBackend())
    # Create a model path that exists
    import tempfile

    with tempfile.TemporaryDirectory() as td:
        with caplog.at_level(logging.INFO):
            ack = servicer.LoadModel(
                worker_runtime_pb2.LoadModelRequest(
                    model_id="test/model", version="v1", model_path=td
                ),
                None,
            )
    assert ack.ok is True
    messages = [r.message for r in caplog.records]
    assert any("load_model start" in m for m in messages)
    assert any("load_model ok" in m for m in messages)


def test_unload_model_logs_lifecycle(caplog: pytest.LogCaptureFixture) -> None:
    """UnloadModel emits start and ok log lines."""
    from orchard_worker_mlx.generated.cluster.v1 import runtime_pb2
    from orchard_worker_mlx.generated.orchard.worker.v1 import worker_runtime_pb2

    servicer = _make_servicer(StubBackend())
    import tempfile

    with tempfile.TemporaryDirectory() as td:
        servicer.LoadModel(
            worker_runtime_pb2.LoadModelRequest(model_id="test/model", version="v1", model_path=td),
            None,
        )
    with caplog.at_level(logging.INFO):
        ack = servicer.UnloadModel(
            runtime_pb2.UnloadModelRequest(model_id="test/model", version="v1"),
            None,
        )
    assert ack.ok is True
    messages = [r.message for r in caplog.records]
    assert any("unload_model start" in m for m in messages)
    assert any("unload_model ok" in m for m in messages)


def test_cancel_logs_request_id(caplog: pytest.LogCaptureFixture) -> None:
    """Cancel emits a log line with the request_id."""
    from orchard_worker_mlx.generated.cluster.v1 import runtime_pb2

    servicer = _make_servicer(StubBackend())
    with caplog.at_level(logging.INFO):
        ack = servicer.Cancel(
            runtime_pb2.CancelInferenceRequest(
                request_id="req-log-test",
                controller_session_id="s1",
            ),
            None,
        )
    assert ack.ok is True
    messages = [r.message for r in caplog.records]
    assert any("cancel request_id=req-log-test" in m for m in messages)


# ---------------------------------------------------------------------------
# GetStatus health fields + LoadModel health gate
# ---------------------------------------------------------------------------


class UnhealthyBackend(HappyBackend):
    """Backend that reports unhealthy."""

    def health(self) -> BackendHealth:
        return BackendHealth(
            ready=False,
            code="mlx_backend_unavailable",
            message="MLX not installed",
        )


class BudgetStatusBackend(HappyBackend):
    def __init__(self, *, memory_budget: Any) -> None:
        super().__init__()
        self._loaded = True
        self._memory_budget = memory_budget

    def status(self) -> BackendStatus:
        return BackendStatus(
            loaded=True,
            active_request_count=0,
            memory_budget=self._memory_budget,
        )


class PrefixCacheStatusBackend(HappyBackend):
    def __init__(self, *, prefix_cache_status: Any) -> None:
        super().__init__()
        self._prefix_cache_status = prefix_cache_status

    def prefix_cache_status(self) -> Any:
        return self._prefix_cache_status


def test_get_status_includes_health_fields_healthy() -> None:
    """GetStatus includes ready=True and empty code/message for healthy backend."""
    servicer = _make_servicer(HappyBackend())
    status = servicer.GetStatus(worker_runtime_pb2.WorkerStatusRequest(), None)
    assert status.ready is True
    assert status.health_code == ""
    assert status.health_message == ""


def test_get_status_includes_health_fields_unhealthy() -> None:
    """GetStatus includes ready=False with code/message for unhealthy backend."""
    servicer = _make_servicer(UnhealthyBackend())
    status = servicer.GetStatus(worker_runtime_pb2.WorkerStatusRequest(), None)
    assert status.ready is False
    assert status.health_code == "mlx_backend_unavailable"
    assert status.health_message == "MLX not installed"


def test_get_status_includes_memory_budget_fields() -> None:
    servicer = _make_servicer(
        BudgetStatusBackend(
            memory_budget={
                "mode": "observe",
                "budget_available": True,
                "headroom_available": True,
                "status_code": "ok",
                "status_message": "",
                "source": "mlx.core.device_info.max_recommended_working_set_size",
                "max_recommended_working_set_size_bytes": 8_000_000_000,
                "utilization": 0.75,
                "target_working_set_bytes": 6_000_000_000,
                "overhead_bytes": 268_435_456,
                "resident_memory_bytes": 2_048_000,
                "estimated_headroom_bytes": 5_731_516_544,
                "kv_cache_bytes_per_token": 16_384,
                "prefill_workspace_bytes_per_token": 2_048,
            }
        )
    )
    status = servicer.GetStatus(worker_runtime_pb2.WorkerStatusRequest(), None)
    assert status.memory_budget.mode == "observe"
    assert status.memory_budget.budget_available is True
    assert status.memory_budget.status_code == "ok"
    assert status.memory_budget.target_working_set_bytes == 6_000_000_000
    assert status.memory_budget.estimated_headroom_bytes == 5_731_516_544
    assert status.memory_budget.prefill_workspace_bytes_per_token == 2_048


def test_get_status_degrades_invalid_memory_budget_status() -> None:
    servicer = _make_servicer(BudgetStatusBackend(memory_budget="not-a-map"))
    status = servicer.GetStatus(worker_runtime_pb2.WorkerStatusRequest(), None)
    assert status.memory_budget.mode == "observe"
    assert status.memory_budget.budget_available is False
    assert status.memory_budget.headroom_available is False
    assert status.memory_budget.status_code == "invalid_status"
    assert status.memory_budget.status_message == "backend memory budget status was invalid"


def test_get_status_downgrades_invalid_memory_budget_uint64_fields() -> None:
    servicer = _make_servicer(
        BudgetStatusBackend(
            memory_budget={
                "mode": "observe",
                "budget_available": True,
                "headroom_available": True,
                "status_code": "ok",
                "status_message": "",
                "source": "mlx.core.device_info.max_recommended_working_set_size",
                "max_recommended_working_set_size_bytes": -1,
                "utilization": 0.75,
                "target_working_set_bytes": 2**64,
                "overhead_bytes": True,
                "resident_memory_bytes": "2048",
                "estimated_headroom_bytes": 2**64 - 1,
                "kv_cache_bytes_per_token": 16_384,
                "prefill_workspace_bytes_per_token": None,
            }
        )
    )
    status = servicer.GetStatus(worker_runtime_pb2.WorkerStatusRequest(), None)
    assert status.memory_budget.mode == "observe"
    assert status.memory_budget.budget_available is False
    assert status.memory_budget.headroom_available is False
    assert status.memory_budget.status_code == "invalid_status"
    assert (
        status.memory_budget.status_message
        == "memory budget status contained invalid numeric fields"
    )
    assert status.memory_budget.max_recommended_working_set_size_bytes == 0
    assert status.memory_budget.target_working_set_bytes == 0
    assert status.memory_budget.overhead_bytes == 0
    assert status.memory_budget.resident_memory_bytes == 0
    assert status.memory_budget.estimated_headroom_bytes == 0
    assert status.memory_budget.kv_cache_bytes_per_token == 0
    assert status.memory_budget.prefill_workspace_bytes_per_token == 0
    assert status.memory_budget.utilization == 0.0


@pytest.mark.parametrize("utilization", [float("nan"), float("inf"), float("-inf")])
def test_get_status_downgrades_non_finite_memory_budget_utilization(utilization: float) -> None:
    servicer = _make_servicer(
        BudgetStatusBackend(
            memory_budget={
                "mode": "observe",
                "budget_available": True,
                "headroom_available": True,
                "status_code": "ok",
                "status_message": "",
                "source": "mlx.core.device_info.max_recommended_working_set_size",
                "max_recommended_working_set_size_bytes": 8_000_000_000,
                "utilization": utilization,
                "target_working_set_bytes": 6_000_000_000,
                "overhead_bytes": 268_435_456,
                "resident_memory_bytes": 2_048_000,
                "estimated_headroom_bytes": 5_731_516_544,
                "kv_cache_bytes_per_token": 16_384,
                "prefill_workspace_bytes_per_token": 2_048,
            }
        )
    )
    status = servicer.GetStatus(worker_runtime_pb2.WorkerStatusRequest(), None)
    assert status.memory_budget.mode == "observe"
    assert status.memory_budget.budget_available is False
    assert status.memory_budget.headroom_available is False
    assert status.memory_budget.status_code == "invalid_status"
    assert (
        status.memory_budget.status_message
        == "memory budget status contained invalid numeric fields"
    )
    assert status.memory_budget.utilization == 0.0
    assert status.memory_budget.target_working_set_bytes == 0


def test_get_status_downgrades_huge_integer_memory_budget_utilization_without_raising() -> None:
    servicer = _make_servicer(
        BudgetStatusBackend(
            memory_budget={
                "mode": "observe",
                "budget_available": True,
                "headroom_available": True,
                "status_code": "ok",
                "status_message": "",
                "source": "mlx.core.device_info.max_recommended_working_set_size",
                "max_recommended_working_set_size_bytes": 8_000_000_000,
                "utilization": 10**10_000,
                "target_working_set_bytes": 6_000_000_000,
                "overhead_bytes": 268_435_456,
                "resident_memory_bytes": 2_048_000,
                "estimated_headroom_bytes": 5_731_516_544,
                "kv_cache_bytes_per_token": 16_384,
                "prefill_workspace_bytes_per_token": 2_048,
            }
        )
    )
    status = servicer.GetStatus(worker_runtime_pb2.WorkerStatusRequest(), None)
    assert status.memory_budget.mode == "observe"
    assert status.memory_budget.budget_available is False
    assert status.memory_budget.headroom_available is False
    assert status.memory_budget.status_code == "invalid_status"
    assert (
        status.memory_budget.status_message
        == "memory budget status contained invalid numeric fields"
    )
    assert status.memory_budget.utilization == 0.0
    assert status.memory_budget.target_working_set_bytes == 0


def test_get_status_downgrades_memory_budget_missing_required_numeric_field() -> None:
    servicer = _make_servicer(
        BudgetStatusBackend(
            memory_budget={
                "mode": "observe",
                "budget_available": True,
                "headroom_available": True,
                "status_code": "ok",
                "status_message": "",
                "source": "mlx.core.device_info.max_recommended_working_set_size",
                "max_recommended_working_set_size_bytes": 8_000_000_000,
                "utilization": 0.75,
                "overhead_bytes": 268_435_456,
                "resident_memory_bytes": 2_048_000,
                "estimated_headroom_bytes": 5_731_516_544,
                "kv_cache_bytes_per_token": 16_384,
                "prefill_workspace_bytes_per_token": 2_048,
            }
        )
    )
    status = servicer.GetStatus(worker_runtime_pb2.WorkerStatusRequest(), None)
    assert status.memory_budget.budget_available is False
    assert status.memory_budget.headroom_available is False
    assert status.memory_budget.status_code == "invalid_status"
    assert (
        status.memory_budget.status_message
        == "memory budget status contained invalid numeric fields"
    )
    assert status.memory_budget.target_working_set_bytes == 0


def test_get_status_prefix_cache_disabled_config_is_authoritative() -> None:
    backend = PrefixCacheStatusBackend(
        prefix_cache_status={
            "implementation": "kv",
            "enabled": True,
            "entry_count": 2,
            "total_bytes": 128,
            "hits": 1,
            "misses": 0,
            "failures": 0,
            "stores": 1,
            "evictions": 0,
            "configured_max_entries": 8,
            "configured_max_bytes": 0,
            "status_code": "ok",
            "status_message": "",
            "session_started_unix_ms": 123,
        }
    )
    backend.prefix_cache_status = MagicMock(side_effect=backend.prefix_cache_status)
    servicer = WorkerRuntimeServicer(
        backend,
        prefix_cache_config=PrefixCacheLoadConfig(mode="disabled"),
    )

    status = servicer.GetStatus(worker_runtime_pb2.WorkerStatusRequest(), None)

    assert status.prefix_cache.status_code == "disabled"
    assert status.prefix_cache.enabled is False
    backend.prefix_cache_status.assert_not_called()


def test_get_status_prefix_cache_ok_emits_backend_stats() -> None:
    servicer = WorkerRuntimeServicer(
        PrefixCacheStatusBackend(
            prefix_cache_status={
                "implementation": "trie",
                "enabled": True,
                "entry_count": 3,
                "total_bytes": 2048,
                "hits": 5,
                "misses": 2,
                "failures": 1,
                "stores": 7,
                "evictions": 4,
                "configured_max_entries": 16,
                "configured_max_bytes": 1024,
                "status_code": "ok",
                "status_message": "",
                "session_started_unix_ms": 999,
            }
        ),
        prefix_cache_config=PrefixCacheLoadConfig(mode="trie", max_entries=16, max_bytes=1024),
    )

    status = servicer.GetStatus(worker_runtime_pb2.WorkerStatusRequest(), None)

    assert status.prefix_cache.status_code == "ok"
    assert status.prefix_cache.enabled is True
    assert status.prefix_cache.implementation == "trie"
    assert status.prefix_cache.entry_count == 3
    assert status.prefix_cache.total_bytes == 2048
    assert status.prefix_cache.hits == 5
    assert status.prefix_cache.misses == 2
    assert status.prefix_cache.failures == 1
    assert status.prefix_cache.stores == 7
    assert status.prefix_cache.evictions == 4
    assert status.prefix_cache.session_started_unix_ms == 999


def test_get_status_prefix_cache_unavailable_no_session_stays_enabled() -> None:
    servicer = WorkerRuntimeServicer(
        PrefixCacheStatusBackend(
            prefix_cache_status={
                "implementation": "unknown",
                "enabled": True,
                "entry_count": 0,
                "total_bytes": 0,
                "hits": 0,
                "misses": 0,
                "failures": 0,
                "stores": 0,
                "evictions": 0,
                "configured_max_entries": 8,
                "configured_max_bytes": 0,
                "status_code": "unavailable",
                "status_message": "model session is not loaded",
                "session_started_unix_ms": 0,
            }
        )
    )

    status = servicer.GetStatus(worker_runtime_pb2.WorkerStatusRequest(), None)

    assert status.prefix_cache.status_code == "unavailable"
    assert status.prefix_cache.enabled is True


def test_get_status_prefix_cache_error_stays_enabled() -> None:
    servicer = WorkerRuntimeServicer(
        PrefixCacheStatusBackend(
            prefix_cache_status={
                "implementation": "unknown",
                "enabled": True,
                "entry_count": 0,
                "total_bytes": 0,
                "hits": 0,
                "misses": 0,
                "failures": 0,
                "stores": 0,
                "evictions": 0,
                "configured_max_entries": 8,
                "configured_max_bytes": 0,
                "status_code": "error",
                "status_message": "prefix cache stats read failed: boom",
                "session_started_unix_ms": 555,
            }
        )
    )

    status = servicer.GetStatus(worker_runtime_pb2.WorkerStatusRequest(), None)

    assert status.prefix_cache.status_code == "error"
    assert status.prefix_cache.enabled is True


def test_get_status_prefix_cache_invalid_status_on_malformed_backend_payload() -> None:
    servicer = WorkerRuntimeServicer(
        PrefixCacheStatusBackend(
            prefix_cache_status={
                "implementation": "kv",
                "enabled": True,
                "entry_count": "bad",
                "total_bytes": 1,
                "hits": 1,
                "misses": 1,
                "failures": 0,
                "stores": 1,
                "evictions": 0,
                "configured_max_entries": 8,
                "configured_max_bytes": 0,
                "status_code": "ok",
                "status_message": "",
                "session_started_unix_ms": 1,
            }
        )
    )

    status = servicer.GetStatus(worker_runtime_pb2.WorkerStatusRequest(), None)

    assert status.prefix_cache.status_code == "invalid_status"
    assert status.prefix_cache.enabled is True


def test_get_status_prefix_cache_backend_exception_returns_error_status() -> None:
    class PrefixCacheRaisesBackend(HappyBackend):
        def prefix_cache_status(self) -> dict[str, Any]:
            raise RuntimeError("telemetry boom")

    servicer = WorkerRuntimeServicer(PrefixCacheRaisesBackend())

    status = servicer.GetStatus(worker_runtime_pb2.WorkerStatusRequest(), None)

    assert status.prefix_cache.status_code == "error"
    assert status.prefix_cache.status_message == "telemetry boom"
    assert status.prefix_cache.enabled is True


def test_get_status_prefix_cache_caps_configured_max_entries_to_uint32_max() -> None:
    servicer = WorkerRuntimeServicer(
        PrefixCacheStatusBackend(
            prefix_cache_status={
                "implementation": "trie",
                "enabled": True,
                "entry_count": 1,
                "total_bytes": 128,
                "hits": 1,
                "misses": 0,
                "failures": 0,
                "stores": 1,
                "evictions": 0,
                "configured_max_entries": 1,
                "configured_max_bytes": 128,
                "status_code": "ok",
                "status_message": "",
                "session_started_unix_ms": 1,
            }
        ),
        prefix_cache_config=SimpleNamespace(mode="trie", max_entries=2**32 + 1, max_bytes=128),
    )

    status = servicer.GetStatus(worker_runtime_pb2.WorkerStatusRequest(), None)

    assert status.prefix_cache.configured_max_entries == 4_294_967_295


def test_load_model_rejected_when_unhealthy() -> None:
    """LoadModel returns ok=False when backend is unhealthy."""
    servicer = _make_servicer(UnhealthyBackend())
    ack = servicer.LoadModel(
        worker_runtime_pb2.LoadModelRequest(model_id="m", version="v", model_path="/fake"),
        None,
    )
    assert ack.ok is False
    assert "mlx_backend_unavailable" in ack.message


def test_load_model_unhealthy_does_not_call_backend_load() -> None:
    """LoadModel should not call backend.load_model when unhealthy."""
    load_called = [False]

    class TrackingUnhealthyBackend(UnhealthyBackend):
        def load_model(self, **kwargs):
            load_called[0] = True

    servicer = _make_servicer(TrackingUnhealthyBackend())
    ack = servicer.LoadModel(
        worker_runtime_pb2.LoadModelRequest(model_id="m", version="v", model_path="/fake"),
        None,
    )
    assert ack.ok is False
    assert not load_called[0]


def test_load_model_succeeds_when_healthy() -> None:
    """LoadModel proceeds normally when backend is healthy."""
    servicer = _make_servicer(HappyBackend())
    ack = servicer.LoadModel(
        worker_runtime_pb2.LoadModelRequest(model_id="m", version="v", model_path="/fake"),
        None,
    )
    assert ack.ok is True


# ---------------------------------------------------------------------------
# Task 4.5: Ack.message contract lock
# ---------------------------------------------------------------------------

_ACK_MESSAGE_PATTERN = re.compile(r"^[a-z_]+: .+")


def test_load_model_health_gate_ack_message_format() -> None:
    """Health-gated LoadModel failure follows 'code: message' format."""
    servicer = _make_servicer(UnhealthyBackend())
    ack = servicer.LoadModel(
        worker_runtime_pb2.LoadModelRequest(model_id="m", version="v", model_path="/fake"),
        None,
    )
    assert ack.ok is False
    assert _ACK_MESSAGE_PATTERN.match(ack.message), (
        f"Ack.message does not follow 'code: message' format: {ack.message!r}"
    )


class LoadFailingBackend(HappyBackend):
    """Backend that raises BackendError during load_model."""

    def load_model(self, *, model_id: str, version: str, model_path: str) -> None:
        raise BackendError(
            code="manifest_not_found",
            message="manifest.json not found in bundle",
        )


def test_load_model_backend_error_ack_message_format() -> None:
    """BackendError-triggered LoadModel failure follows 'code: message' format."""
    servicer = _make_servicer(LoadFailingBackend())
    ack = servicer.LoadModel(
        worker_runtime_pb2.LoadModelRequest(model_id="m", version="v", model_path="/fake"),
        None,
    )
    assert ack.ok is False
    assert _ACK_MESSAGE_PATTERN.match(ack.message), (
        f"Ack.message does not follow 'code: message' format: {ack.message!r}"
    )
    # Verify exact code is preserved
    assert ack.message.startswith("manifest_not_found:")
