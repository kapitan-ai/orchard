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
