from __future__ import annotations

import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from uuid import uuid4

import grpc

from orchard_worker_mlx import __version__
from orchard_worker_mlx.generated.cluster.v1 import runtime_pb2
from orchard_worker_mlx.generated.orchard.worker.v1 import (
    worker_runtime_pb2,
    worker_runtime_pb2_grpc,
)
from orchard_worker_mlx.service import build_failed_event


def test_worker_server_smoke_supports_load_generate_cancel_and_unload(tmp_path: Path) -> None:
    socket_path = Path("/tmp") / f"orchard-worker-{uuid4().hex[:8]}.sock"
    model_path = tmp_path / "models" / "phi-3" / "main"
    model_path.mkdir(parents=True)

    process = start_worker(socket_path)

    try:
        channel = wait_for_channel(socket_path)
        stub = worker_runtime_pb2_grpc.WorkerRuntimeServiceStub(channel)

        status = stub.GetStatus(worker_runtime_pb2.WorkerStatusRequest())
        assert status.loaded is False
        assert status.active_request_count == 0

        ack = stub.LoadModel(
            worker_runtime_pb2.LoadModelRequest(
                model_id="mlx-community/phi-3",
                version="main",
                model_path=str(model_path),
            )
        )
        assert ack.ok is True

        status = stub.GetStatus(worker_runtime_pb2.WorkerStatusRequest())
        assert status.loaded is True

        request = runtime_pb2.ExecuteInferenceRequest(
            request_id="req-worker-generate",
            controller_session_id="controller-session-1",
            model_id="mlx-community/phi-3",
            version="main",
            rendered_prompt_utf8=b"hello orchard",
            input_tokens=2,
            metadata_json=b'{"worker_chunks":["mlx ","worker"]}',
        )

        events = list(stub.Generate(request))
        assert [event.output_text_delta.delta for event in events[:-1]] == ["mlx ", "worker"]
        assert events[-1].completed.usage.total_tokens == 4

        cancel_request = runtime_pb2.ExecuteInferenceRequest(
            request_id="req-worker-cancel",
            controller_session_id="controller-session-2",
            model_id="mlx-community/phi-3",
            version="main",
            rendered_prompt_utf8=b"hello orchard",
            input_tokens=2,
            metadata_json=b'{"worker_delay_ms":50}',
        )

        # Server-streaming RPCs don't support .future(); run Generate in a
        # background thread so we can send Cancel concurrently.
        with ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(lambda: list(stub.Generate(cancel_request)))
            time.sleep(0.05)
            cancel_ack = stub.Cancel(
                runtime_pb2.CancelInferenceRequest(
                    request_id="req-worker-cancel",
                    controller_session_id="controller-session-2",
                )
            )
            assert cancel_ack.ok is True
            cancelled_events = future.result(timeout=5)
            assert cancelled_events[-1].failed.code == "cancelled"

        unload_ack = stub.UnloadModel(
            runtime_pb2.UnloadModelRequest(model_id="mlx-community/phi-3", version="main")
        )
        assert unload_ack.ok is True
    finally:
        process.terminate()
        process.wait(timeout=5)
        assert not socket_path.exists()


def test_cancel_before_generate_returns_cancelled_immediately(tmp_path: Path) -> None:
    """Cancel arriving before Generate should produce an immediate cancelled failure."""
    socket_path = Path("/tmp") / f"orchard-worker-{uuid4().hex[:8]}.sock"
    model_path = tmp_path / "models" / "phi-3" / "main"
    model_path.mkdir(parents=True)

    process = start_worker(socket_path)

    try:
        channel = wait_for_channel(socket_path)
        stub = worker_runtime_pb2_grpc.WorkerRuntimeServiceStub(channel)

        # Load model first (required for generation)
        ack = stub.LoadModel(
            worker_runtime_pb2.LoadModelRequest(
                model_id="mlx-community/phi-3",
                version="main",
                model_path=str(model_path),
            )
        )
        assert ack.ok is True

        # Cancel BEFORE Generate
        request_id = "req-pre-cancel"
        cancel_ack = stub.Cancel(
            runtime_pb2.CancelInferenceRequest(
                request_id=request_id,
                controller_session_id="controller-session-pre",
            )
        )
        assert cancel_ack.ok is True

        # Now Generate with the same request_id — should return cancelled immediately
        request = runtime_pb2.ExecuteInferenceRequest(
            request_id=request_id,
            controller_session_id="controller-session-pre",
            model_id="mlx-community/phi-3",
            version="main",
            rendered_prompt_utf8=b"hello orchard",
            input_tokens=2,
            metadata_json=b'{"worker_delay_ms":2000}',
        )

        events = list(stub.Generate(request))
        assert len(events) == 1
        assert events[0].failed.code == "cancelled"
        assert events[0].failed.message == "request cancelled"
    finally:
        process.terminate()
        process.wait(timeout=5)


def test_build_failed_event_maps_expected_shape() -> None:
    event = build_failed_event("worker_failed", "boom", False)
    assert event.failed.code == "worker_failed"
    assert event.failed.message == "boom"


def test_main_prints_version(capsys) -> None:
    from orchard_worker_mlx.cli import main

    assert main(["--socket-path", "/tmp/orchard-worker.sock", "--version"]) == 0
    assert capsys.readouterr().out.strip() == __version__


def start_worker(socket_path: Path) -> subprocess.Popen[str]:
    return subprocess.Popen(
        [
            sys.executable,
            "-m",
            "orchard_worker_mlx.cli",
            "--socket-path",
            str(socket_path),
            "--backend",
            "stub",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        text=True,
    )


def wait_for_channel(socket_path: Path) -> grpc.Channel:
    deadline = time.monotonic() + 5.0
    target = f"unix://{socket_path}"

    # Create a fresh channel on each attempt.  gRPC channels that receive
    # GOAWAY during initial setup may enter a broken state where subsequent
    # RPCs on the same channel never reconnect.
    while time.monotonic() < deadline:
        channel = grpc.insecure_channel(target)
        stub = worker_runtime_pb2_grpc.WorkerRuntimeServiceStub(channel)
        try:
            stub.GetStatus(worker_runtime_pb2.WorkerStatusRequest(), timeout=0.5)
            return channel
        except grpc.RpcError:
            channel.close()
            time.sleep(0.1)

    raise AssertionError("worker server did not become ready in time")
