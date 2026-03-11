from __future__ import annotations

import signal
import threading
import time
from collections.abc import Callable, Iterator
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
from types import FrameType
from typing import Any, Literal

import grpc

from orchard_worker_mlx.backends import Backend, BackendError, build_backend
from orchard_worker_mlx.generated.cluster.v1 import common_pb2, events_pb2, runtime_pb2
from orchard_worker_mlx.generated.orchard.worker.v1 import (
    worker_runtime_pb2,
    worker_runtime_pb2_grpc,
)

# Default TTL for cancel tombstones (seconds).
_DEFAULT_CANCEL_TOMBSTONE_TTL_S = 60.0


@dataclass(slots=True)
class CancelEntry:
    """Tracks a cancellation signal for a request.

    ``phase`` distinguishes pre-Generate tombstones from active generations.
    Tombstones have an ``expires_at_monotonic`` after which they are pruned.
    """

    event: threading.Event
    phase: Literal["tombstone", "active"] = "tombstone"
    expires_at_monotonic: float | None = None


class WorkerRuntimeServicer(worker_runtime_pb2_grpc.WorkerRuntimeServiceServicer):
    def __init__(
        self,
        backend: Backend,
        *,
        clock: Callable[[], float] = time.monotonic,
        cancel_tombstone_ttl_s: float = _DEFAULT_CANCEL_TOMBSTONE_TTL_S,
    ) -> None:
        self._backend = backend
        self._cancel_entries: dict[str, CancelEntry] = {}
        self._lock = threading.Lock()
        self._clock = clock
        self._cancel_tombstone_ttl_s = cancel_tombstone_ttl_s

    def GetStatus(
        self, request: worker_runtime_pb2.WorkerStatusRequest, context: grpc.ServicerContext
    ) -> worker_runtime_pb2.WorkerStatusResponse:
        status = self._backend.status()
        return worker_runtime_pb2.WorkerStatusResponse(
            loaded=bool(status["loaded"]),
            active_request_count=int(status["active_request_count"]),
        )

    def LoadModel(
        self, request: worker_runtime_pb2.LoadModelRequest, context: grpc.ServicerContext
    ) -> common_pb2.Ack:
        try:
            self._backend.load_model(
                model_id=request.model_id,
                version=request.version,
                model_path=request.model_path,
            )
        except BackendError as exc:
            return common_pb2.Ack(ok=False, message=f"{exc.code}: {exc.message}")

        return common_pb2.Ack(ok=True, message="model loaded")

    def UnloadModel(
        self, request: runtime_pb2.UnloadModelRequest, context: grpc.ServicerContext
    ) -> common_pb2.Ack:
        try:
            self._backend.unload_model()
        except BackendError as exc:
            return common_pb2.Ack(ok=False, message=f"{exc.code}: {exc.message}")

        return common_pb2.Ack(ok=True, message="model unloaded")

    def Generate(
        self, request: runtime_pb2.ExecuteInferenceRequest, context: grpc.ServicerContext
    ) -> Iterator[events_pb2.InferenceEvent]:
        # --- claim or create cancel entry ---
        with self._lock:
            self._prune_expired_tombstones()
            entry = self._cancel_entries.get(request.request_id)
            if entry is None:
                entry = CancelEntry(event=threading.Event(), phase="active")
                self._cancel_entries[request.request_id] = entry
            else:
                # Tombstone -> active: reuse the (possibly set) event.
                entry.phase = "active"
                entry.expires_at_monotonic = None

        cancel_event = entry.event

        # Short-circuit if Cancel arrived before Generate.
        if cancel_event.is_set():
            yield build_failed_event("cancelled", "request cancelled", False)
            with self._lock:
                self._cancel_entries.pop(request.request_id, None)
            return

        generation_started = False
        terminal_emitted = False
        try:
            self._backend.start_generation()
            generation_started = True

            for backend_event in self._backend.generate(request, cancel_event):
                try:
                    proto_event = build_inference_event(backend_event)
                except BackendError as conv_exc:
                    # Invalid backend event -> synthesize terminal failure.
                    if not terminal_emitted:
                        yield build_failed_event(
                            conv_exc.code, conv_exc.message, conv_exc.retryable
                        )
                        terminal_emitted = True
                    break

                yield proto_event

                if _is_terminal_proto_event(proto_event):
                    terminal_emitted = True
                    break

            # Backend iterator ended without a terminal event.
            if not terminal_emitted:
                yield build_failed_event(
                    "backend_missing_terminal",
                    "backend ended without terminal event",
                    False,
                )
                terminal_emitted = True

        except BackendError as exc:
            if not terminal_emitted:
                yield build_failed_event(exc.code, exc.message, exc.retryable)
                terminal_emitted = True
        except Exception as exc:
            if not terminal_emitted:
                yield build_failed_event(
                    "backend_crash",
                    f"backend crashed: {exc}",
                    False,
                )
                terminal_emitted = True
        finally:
            with self._lock:
                self._cancel_entries.pop(request.request_id, None)

            if generation_started:
                try:
                    self._backend.finish_generation()
                except Exception:
                    pass  # terminal already emitted or about to be; don't double-emit

    def Cancel(
        self, request: runtime_pb2.CancelInferenceRequest, context: grpc.ServicerContext
    ) -> common_pb2.Ack:
        with self._lock:
            self._prune_expired_tombstones()
            entry = self._cancel_entries.get(request.request_id)
            if entry is None:
                event = threading.Event()
                event.set()
                self._cancel_entries[request.request_id] = CancelEntry(
                    event=event,
                    phase="tombstone",
                    expires_at_monotonic=self._clock() + self._cancel_tombstone_ttl_s,
                )
            else:
                entry.event.set()

        return common_pb2.Ack(ok=True, message="cancel accepted")

    # -- internal helpers --

    def _prune_expired_tombstones(self) -> None:
        """Remove expired tombstone entries.  Must be called with ``_lock`` held."""
        now = self._clock()
        expired = [
            rid
            for rid, entry in self._cancel_entries.items()
            if entry.phase == "tombstone"
            and entry.expires_at_monotonic is not None
            and entry.expires_at_monotonic <= now
        ]
        for rid in expired:
            del self._cancel_entries[rid]


def build_server(
    backend_name: str,
    *,
    backend_factory: Callable[[str], Backend] = build_backend,
    clock: Callable[[], float] = time.monotonic,
    cancel_tombstone_ttl_s: float = _DEFAULT_CANCEL_TOMBSTONE_TTL_S,
) -> grpc.Server:
    backend = backend_factory(backend_name)
    server = grpc.server(ThreadPoolExecutor(max_workers=4))
    worker_runtime_pb2_grpc.add_WorkerRuntimeServiceServicer_to_server(
        WorkerRuntimeServicer(
            backend,
            clock=clock,
            cancel_tombstone_ttl_s=cancel_tombstone_ttl_s,
        ),
        server,
    )
    return server


def serve(socket_path: str, backend_name: str) -> None:
    socket = Path(socket_path)
    socket.parent.mkdir(parents=True, exist_ok=True)

    if socket.exists():
        socket.unlink()

    server = build_server(backend_name)
    bind_target = f"unix://{socket_path}"
    bound_port = server.add_insecure_port(bind_target)

    if bound_port == 0:
        raise RuntimeError(f"failed to bind worker socket at {socket_path}")

    previous_handlers = install_signal_handlers(server)
    server.start()

    try:
        server.wait_for_termination()
    finally:
        restore_signal_handlers(previous_handlers)
        server.stop(grace=0).wait(timeout=1.0)
        if socket.exists():
            socket.unlink()


# ---------------------------------------------------------------------------
# Event building
# ---------------------------------------------------------------------------

# Terminal proto event kinds.
_TERMINAL_ONEOFS = frozenset({"completed", "failed"})


def _is_terminal_proto_event(event: events_pb2.InferenceEvent) -> bool:
    return event.WhichOneof("event") in _TERMINAL_ONEOFS


def build_inference_event(event: dict[str, Any]) -> events_pb2.InferenceEvent:
    """Convert a backend dict event to a proto ``InferenceEvent``.

    Raises ``BackendError`` for invalid or unsupported event shapes so the
    caller can synthesize a terminal failure.
    """
    kind = event.get("kind")

    if kind == "accepted":
        raise BackendError(
            "backend_invalid_event",
            "backend must not emit accepted events",
            False,
        )

    if kind == "output_text_delta":
        delta = event.get("delta")
        if not isinstance(delta, str):
            raise BackendError(
                "backend_invalid_event",
                f"output_text_delta.delta must be str, got {type(delta).__name__}",
                False,
            )
        return events_pb2.InferenceEvent(
            output_text_delta=events_pb2.OutputTextDelta(delta=delta)
        )

    if kind == "progress":
        stage = event.get("stage", "")
        message = event.get("message", "")
        if not isinstance(stage, str) or not stage:
            raise BackendError(
                "backend_invalid_event",
                "progress.stage must be a non-empty string",
                False,
            )
        if not isinstance(message, str) or not message:
            raise BackendError(
                "backend_invalid_event",
                "progress.message must be a non-empty string",
                False,
            )
        return events_pb2.InferenceEvent(
            progress=events_pb2.Progress(stage=stage, message=message)
        )

    if kind == "usage":
        return _build_usage_event(event)

    if kind == "completed":
        return _build_completed_event(event)

    if kind == "failed":
        return _build_failed_from_dict(event)

    raise BackendError(
        "backend_invalid_event",
        f"unsupported event kind: {kind}",
        False,
    )


def _validate_token_usage(usage: dict[str, Any]) -> common_pb2.TokenUsage:
    """Validate and convert a token usage dict to proto."""
    input_tokens = usage.get("input_tokens")
    output_tokens = usage.get("output_tokens")
    total_tokens = usage.get("total_tokens")

    for name, value in [
        ("input_tokens", input_tokens),
        ("output_tokens", output_tokens),
        ("total_tokens", total_tokens),
    ]:
        if not isinstance(value, int) or value < 0:
            raise BackendError(
                "backend_invalid_event",
                f"usage.{name} must be a non-negative integer, got {value!r}",
                False,
            )

    if total_tokens != input_tokens + output_tokens:
        raise BackendError(
            "backend_invalid_event",
            f"usage.total_tokens ({total_tokens}) != input_tokens ({input_tokens}) + output_tokens ({output_tokens})",
            False,
        )

    return common_pb2.TokenUsage(
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        total_tokens=total_tokens,
    )


def _build_usage_event(event: dict[str, Any]) -> events_pb2.InferenceEvent:
    usage = event.get("usage")
    if not isinstance(usage, dict):
        raise BackendError(
            "backend_invalid_event",
            "usage event must contain a 'usage' dict",
            False,
        )
    return events_pb2.InferenceEvent(
        usage=events_pb2.UsageUpdate(usage=_validate_token_usage(usage))
    )


def _build_completed_event(event: dict[str, Any]) -> events_pb2.InferenceEvent:
    usage_dict = event.get("usage")
    if not isinstance(usage_dict, dict):
        raise BackendError(
            "backend_invalid_event",
            "completed event must contain a 'usage' dict",
            False,
        )
    return events_pb2.InferenceEvent(
        completed=events_pb2.Completed(
            finish_reason=event.get("finish_reason", "FINISH_REASON_STOP"),
            usage=_validate_token_usage(usage_dict),
        )
    )


def _build_failed_from_dict(event: dict[str, Any]) -> events_pb2.InferenceEvent:
    code = event.get("code", "")
    message = event.get("message", "")
    retryable = event.get("retryable", False)
    if not isinstance(code, str) or not code:
        raise BackendError(
            "backend_invalid_event",
            "failed.code must be a non-empty string",
            False,
        )
    if not isinstance(message, str) or not message:
        raise BackendError(
            "backend_invalid_event",
            "failed.message must be a non-empty string",
            False,
        )
    if not isinstance(retryable, bool):
        raise BackendError(
            "backend_invalid_event",
            f"failed.retryable must be bool, got {type(retryable).__name__}",
            False,
        )
    return build_failed_event(code, message, retryable)


def build_failed_event(code: str, message: str, retryable: bool) -> events_pb2.InferenceEvent:
    return events_pb2.InferenceEvent(
        failed=events_pb2.Failed(code=code, message=message, retryable=retryable)
    )


# ---------------------------------------------------------------------------
# Signal handling
# ---------------------------------------------------------------------------


def install_signal_handlers(server: grpc.Server) -> dict[signal.Signals, Any]:
    previous_handlers: dict[signal.Signals, Any] = {}

    def _request_shutdown(_signum: int, _frame: FrameType | None) -> None:
        server.stop(grace=0)

    for signum in (signal.SIGTERM, signal.SIGINT):
        previous_handlers[signum] = signal.getsignal(signum)
        signal.signal(signum, _request_shutdown)

    return previous_handlers


def restore_signal_handlers(previous_handlers: dict[signal.Signals, Any]) -> None:
    for signum, handler in previous_handlers.items():
        signal.signal(signum, handler)
