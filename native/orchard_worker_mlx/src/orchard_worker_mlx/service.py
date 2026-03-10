from __future__ import annotations

import signal
import threading
from collections.abc import Iterator
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from types import FrameType
from typing import Any

import grpc

from orchard_worker_mlx.backends import BackendError, build_backend
from orchard_worker_mlx.generated.cluster.v1 import common_pb2, events_pb2, runtime_pb2
from orchard_worker_mlx.generated.orchard.worker.v1 import (
    worker_runtime_pb2,
    worker_runtime_pb2_grpc,
)


class WorkerRuntimeServicer(worker_runtime_pb2_grpc.WorkerRuntimeServiceServicer):
    def __init__(self, backend_name: str) -> None:
        self._backend = build_backend(backend_name)
        self._cancel_events: dict[str, threading.Event] = {}
        self._lock = threading.Lock()

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
        self._backend.unload_model()
        return common_pb2.Ack(ok=True, message="model unloaded")

    def Generate(
        self, request: runtime_pb2.ExecuteInferenceRequest, context: grpc.ServicerContext
    ) -> Iterator[events_pb2.InferenceEvent]:
        cancel_event = threading.Event()

        with self._lock:
            self._cancel_events[request.request_id] = cancel_event

        try:
            self._backend.start_generation()
            for event in self._backend.generate(request, cancel_event):
                yield build_inference_event(event)
        except BackendError as exc:
            yield build_failed_event(exc.code, exc.message, exc.retryable)
        finally:
            with self._lock:
                self._cancel_events.pop(request.request_id, None)

            self._backend.finish_generation()

    def Cancel(
        self, request: runtime_pb2.CancelInferenceRequest, context: grpc.ServicerContext
    ) -> common_pb2.Ack:
        with self._lock:
            cancel_event = self._cancel_events.get(request.request_id)

        if cancel_event is not None:
            cancel_event.set()

        return common_pb2.Ack(ok=True, message="cancel accepted")


def build_server(backend_name: str) -> grpc.Server:
    server = grpc.server(ThreadPoolExecutor(max_workers=4))
    worker_runtime_pb2_grpc.add_WorkerRuntimeServiceServicer_to_server(
        WorkerRuntimeServicer(backend_name),
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


def build_inference_event(event: dict[str, Any]) -> events_pb2.InferenceEvent:
    kind = event["kind"]

    if kind == "output_text_delta":
        return events_pb2.InferenceEvent(
            output_text_delta=events_pb2.OutputTextDelta(delta=event["delta"])
        )

    if kind == "completed":
        usage = event["usage"]
        return events_pb2.InferenceEvent(
            completed=events_pb2.Completed(
                finish_reason=event["finish_reason"],
                usage=common_pb2.TokenUsage(
                    input_tokens=usage["input_tokens"],
                    output_tokens=usage["output_tokens"],
                    total_tokens=usage["total_tokens"],
                ),
            )
        )

    if kind == "failed":
        return build_failed_event(event["code"], event["message"], event["retryable"])

    raise RuntimeError(f"unsupported event kind: {kind}")


def build_failed_event(code: str, message: str, retryable: bool) -> events_pb2.InferenceEvent:
    return events_pb2.InferenceEvent(
        failed=events_pb2.Failed(code=code, message=message, retryable=retryable)
    )


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
