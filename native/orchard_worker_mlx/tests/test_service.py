"""Unit tests for service.py: terminal hardening, event mapping, tombstone TTL."""

from __future__ import annotations

import threading
from collections.abc import Iterator
from dataclasses import dataclass
from typing import Any
from unittest.mock import MagicMock

import pytest

from orchard_worker_mlx.backends import Backend, BackendError, BackendStatus, StubBackend
from orchard_worker_mlx.service import (
    CancelEntry,
    WorkerRuntimeServicer,
    build_failed_event,
    build_inference_event,
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

    def status(self) -> BackendStatus:
        return BackendStatus(loaded=self._loaded, active_request_count=int(self._active))

    def load_model(self, *, model_id: str, version: str, model_path: str) -> None:
        self._loaded = True

    def unload_model(self) -> None:
        self._loaded = False

    def start_generation(self) -> None:
        self._active = True

    def finish_generation(self) -> None:
        self._active = False

    def generate(
        self, request: Any, cancel_event: threading.Event
    ) -> Iterator[dict[str, Any]]:
        yield from self._events


class InvalidEventBackend(HappyBackend):
    """Emits an accepted event (invalid for workers)."""

    def __init__(self) -> None:
        super().__init__(events=[
            {"kind": "output_text_delta", "delta": "hi"},
            {"kind": "accepted"},  # INVALID
        ])


class CrashingBackend(HappyBackend):
    """Raises RuntimeError during generate."""

    def generate(
        self, request: Any, cancel_event: threading.Event
    ) -> Iterator[dict[str, Any]]:
        yield {"kind": "output_text_delta", "delta": "before crash"}
        raise RuntimeError("unexpected kaboom")


class MidIterationBackendErrorBackend(HappyBackend):
    """Raises BackendError mid-iteration after yielding one valid delta."""

    def generate(
        self, request: Any, cancel_event: threading.Event
    ) -> Iterator[dict[str, Any]]:
        yield {"kind": "output_text_delta", "delta": "partial output"}
        raise BackendError(
            "generation_failed",
            "generation runner failed mid-stream",
            retryable=True,
        )


class MissingTerminalBackend(HappyBackend):
    """Yields only non-terminal events then stops."""

    def __init__(self) -> None:
        super().__init__(events=[
            {"kind": "output_text_delta", "delta": "chunk1"},
            {"kind": "output_text_delta", "delta": "chunk2"},
        ])


class StartGenerationCrashBackend(HappyBackend):
    """Crashes in start_generation."""

    def start_generation(self) -> None:
        raise RuntimeError("start boom")


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


def _make_cancel_request(request_id: str = "req-1") -> MagicMock:
    req = MagicMock()
    req.request_id = request_id
    return req


def _collect_events(servicer: WorkerRuntimeServicer, request_id: str = "req-1"):
    """Run Generate and collect all proto events."""
    request = _make_request(request_id)
    context = MagicMock()
    return list(servicer.Generate(request, context))


# ---------------------------------------------------------------------------
# Test: progress and usage event mapping
# ---------------------------------------------------------------------------


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
    extra_after_terminal = HappyBackend(events=[
        {"kind": "output_text_delta", "delta": "ok"},
        {
            "kind": "completed",
            "finish_reason": "FINISH_REASON_STOP",
            "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2},
        },
        {"kind": "output_text_delta", "delta": "should not appear"},
    ])
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
        build_inference_event({
            "kind": "usage",
            "usage": {"input_tokens": 5, "output_tokens": 3, "total_tokens": 99},
        })
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
    event = build_inference_event({
        "kind": "usage",
        "usage": {"input_tokens": 10, "output_tokens": 5, "total_tokens": 15},
    })
    assert event.usage.usage.total_tokens == 15


# ---------------------------------------------------------------------------
# Test: cancel-during-active-generation at service level (Task 4)
# ---------------------------------------------------------------------------


class SlowBackend(HappyBackend):
    """Backend that yields with a delay, allowing Cancel to arrive mid-stream."""

    def __init__(self, *, cancel_event_ref: list[threading.Event]) -> None:
        super().__init__(events=[])
        self._cancel_event_ref = cancel_event_ref

    def generate(
        self, request: Any, cancel_event: threading.Event
    ) -> Iterator[dict[str, Any]]:
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


# ---------------------------------------------------------------------------
# Test: post-failed events suppressed at service level (Task 4)
# ---------------------------------------------------------------------------


class PostFailedBackend(HappyBackend):
    """Emits a failed event followed by more events."""

    def __init__(self) -> None:
        super().__init__(events=[
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
        ])


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

import logging


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
            worker_runtime_pb2.LoadModelRequest(
                model_id="test/model", version="v1", model_path=td
            ),
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
