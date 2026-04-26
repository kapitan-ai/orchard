from __future__ import annotations

import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from uuid import uuid4

import grpc
import pytest

from orchard_worker_mlx import __version__
from orchard_worker_mlx.generated.cluster.v1 import common_pb2, runtime_pb2
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


def test_main_help_describes_real_batch_concurrency_in_mlx_path(capsys) -> None:
    from orchard_worker_mlx.cli import main

    with pytest.raises(SystemExit) as exc_info:
        main(["--help"])

    assert exc_info.value.code == 0
    help_text = " ".join(capsys.readouterr().out.split())
    assert "default: batch; enables real concurrent generation in the mlx worker path" in help_text
    assert "applies when --generation-mode=batch" in help_text


def test_main_passes_generation_and_memory_config_to_serve(monkeypatch) -> None:
    from orchard_worker_mlx import cli

    captured: dict[str, object] = {}

    def fake_serve(socket_path: str, backend: str, **kwargs: object) -> None:
        captured["socket_path"] = socket_path
        captured["backend"] = backend
        captured.update(kwargs)

    monkeypatch.setattr(cli, "serve", fake_serve)

    assert (
        cli.main(
            [
                "--socket-path",
                "/tmp/orchard-worker.sock",
                "--backend",
                "mlx",
                "--generation-mode",
                "batch",
                "--max-concurrent-generations",
                "3",
                "--auto-max-concurrent-generations",
                "4",
                "--memory-budget-mode",
                "observe",
                "--memory-budget-utilization",
                "0.75",
                "--memory-budget-overhead-bytes",
                "268435456",
                "--max-fingerprint-buffer-size",
                "16",
            ]
        )
        == 0
    )

    prefix_cache_config = captured["prefix_cache_config"]
    generation_config = captured["generation_config"]
    memory_budget_config = captured["memory_budget_config"]

    assert captured["socket_path"] == "/tmp/orchard-worker.sock"
    assert captured["backend"] == "mlx"
    assert prefix_cache_config.max_fingerprint_buffer_size == 16
    assert generation_config.mode == "batch"
    assert generation_config.max_concurrent_generations == 3
    assert generation_config.auto_max_concurrent_generations == 4
    assert memory_budget_config.mode == "observe"
    assert memory_budget_config.utilization == 0.75
    assert memory_budget_config.overhead_bytes == 268_435_456


def test_main_rejects_stub_backend_with_batch_mode(monkeypatch) -> None:
    from orchard_worker_mlx import cli

    monkeypatch.setattr(cli, "serve", lambda *_args, **_kwargs: None)

    with pytest.raises(SystemExit):
        cli.main(
            [
                "--socket-path",
                "/tmp/orchard-worker.sock",
                "--backend",
                "stub",
                "--generation-mode",
                "batch",
            ]
        )


def test_main_uses_generation_and_memory_defaults(monkeypatch) -> None:
    from orchard_worker_mlx import cli

    captured: dict[str, object] = {}

    def fake_serve(socket_path: str, backend: str, **kwargs: object) -> None:
        captured["socket_path"] = socket_path
        captured["backend"] = backend
        captured.update(kwargs)

    monkeypatch.setattr(cli, "serve", fake_serve)

    assert cli.main(["--socket-path", "/tmp/orchard-worker.sock", "--backend", "stub"]) == 0

    prefix_cache_config = captured["prefix_cache_config"]
    generation_config = captured["generation_config"]
    memory_budget_config = captured["memory_budget_config"]

    assert prefix_cache_config.max_fingerprint_buffer_size == 8
    assert generation_config.mode == "stream"
    assert generation_config.max_concurrent_generations == "auto"
    assert generation_config.auto_max_concurrent_generations == 3
    assert memory_budget_config.mode == "observe"
    assert memory_budget_config.utilization == 0.90
    assert memory_budget_config.overhead_bytes == 1_073_741_824


def test_main_rejects_invalid_generation_and_memory_config(monkeypatch) -> None:
    from orchard_worker_mlx import cli

    monkeypatch.setattr(cli, "serve", lambda *_args, **_kwargs: None)

    with pytest.raises(SystemExit):
        cli.main(
            [
                "--socket-path",
                "/tmp/orchard-worker.sock",
                "--max-concurrent-generations",
                "0",
            ]
        )

    with pytest.raises(SystemExit):
        cli.main(
            [
                "--socket-path",
                "/tmp/orchard-worker.sock",
                "--memory-budget-utilization",
                "0",
            ]
        )

    with pytest.raises(SystemExit):
        cli.main(
            [
                "--socket-path",
                "/tmp/orchard-worker.sock",
                "--memory-budget-utilization",
                "1.5",
            ]
        )

    with pytest.raises(SystemExit):
        cli.main(
            [
                "--socket-path",
                "/tmp/orchard-worker.sock",
                "--memory-budget-overhead-bytes",
                "-1",
            ]
        )

    with pytest.raises(SystemExit):
        cli.main(
            [
                "--socket-path",
                "/tmp/orchard-worker.sock",
                "--memory-budget-mode",
                "enforce",
            ]
        )

    with pytest.raises(SystemExit):
        cli.main(
            [
                "--socket-path",
                "/tmp/orchard-worker.sock",
                "--max-fingerprint-buffer-size",
                "0",
            ]
        )

    with pytest.raises(SystemExit):
        cli.main(
            [
                "--socket-path",
                "/tmp/orchard-worker.sock",
                "--max-fingerprint-buffer-size",
                "65",
            ]
        )


def test_log_file_written_with_lifecycle_logs(tmp_path: Path) -> None:
    """Worker subprocess writes lifecycle logs to --log-file."""
    socket_path = Path("/tmp") / f"orchard-worker-{uuid4().hex[:8]}.sock"
    model_path = tmp_path / "models" / "phi-3" / "main"
    model_path.mkdir(parents=True)
    log_file = tmp_path / "worker.log"

    process = start_worker(socket_path, log_file=log_file)

    try:
        channel = wait_for_channel(socket_path)
        stub = worker_runtime_pb2_grpc.WorkerRuntimeServiceStub(channel)

        # Load + Unload to produce lifecycle logs
        ack = stub.LoadModel(
            worker_runtime_pb2.LoadModelRequest(
                model_id="mlx-community/phi-3",
                version="main",
                model_path=str(model_path),
            )
        )
        assert ack.ok is True

        stub.UnloadModel(
            runtime_pb2.UnloadModelRequest(model_id="mlx-community/phi-3", version="main")
        )
    finally:
        process.terminate()
        process.wait(timeout=5)

    assert log_file.exists(), "log file should be created"
    content = log_file.read_text()
    assert "[INFO]" in content, "log file should contain INFO-level lines"
    assert "load_model" in content, "log file should contain load_model lifecycle logs"
    assert "unload_model" in content, "log file should contain unload_model lifecycle logs"


def test_log_file_truncated_per_spawn(tmp_path: Path) -> None:
    """Each worker spawn truncates the log file (mode='w')."""
    socket_path = Path("/tmp") / f"orchard-worker-{uuid4().hex[:8]}.sock"
    model_path = tmp_path / "models" / "phi-3" / "main"
    model_path.mkdir(parents=True)
    log_file = tmp_path / "worker.log"

    # First spawn
    p1 = start_worker(socket_path, log_file=log_file)
    try:
        ch = wait_for_channel(socket_path)
        stub = worker_runtime_pb2_grpc.WorkerRuntimeServiceStub(ch)
        stub.LoadModel(
            worker_runtime_pb2.LoadModelRequest(
                model_id="mlx-community/phi-3",
                version="main",
                model_path=str(model_path),
            )
        )
    finally:
        p1.terminate()
        p1.wait(timeout=5)

    first_content = log_file.read_text()
    first_load_count = first_content.count("load_model start")

    # Second spawn — same log file should be truncated
    p2 = start_worker(socket_path, log_file=log_file)
    try:
        ch2 = wait_for_channel(socket_path)
        stub2 = worker_runtime_pb2_grpc.WorkerRuntimeServiceStub(ch2)
        stub2.LoadModel(
            worker_runtime_pb2.LoadModelRequest(
                model_id="mlx-community/phi-3",
                version="main",
                model_path=str(model_path),
            )
        )
    finally:
        p2.terminate()
        p2.wait(timeout=5)

    second_content = log_file.read_text()
    second_load_count = second_content.count("load_model start")

    # If truncated, second file should have the same count (1), not accumulated (2)
    assert first_load_count == 1
    assert second_load_count == 1


def test_configure_logging_direct(tmp_path: Path) -> None:
    """Direct test of _configure_logging writing to file."""
    import logging

    from orchard_worker_mlx.cli import _configure_logging

    log_file = tmp_path / "test.log"
    _configure_logging(str(log_file))

    test_logger = logging.getLogger("test_configure_logging_direct")
    test_logger.info("hello from test")

    content = log_file.read_text()
    assert "[INFO] test_configure_logging_direct hello from test" in content


def test_configure_logging_writes_to_stdout_not_stderr(capsys) -> None:
    """StreamHandler must target stdout explicitly, not stderr (the stdlib default)."""
    import logging

    from orchard_worker_mlx.cli import _configure_logging

    _configure_logging()  # no file, just stream handler

    test_logger = logging.getLogger("test_stdout_check")
    test_logger.info("stdout marker")

    captured = capsys.readouterr()
    assert "stdout marker" in captured.out, "log output should appear on stdout"
    assert "stdout marker" not in captured.err, "log output must not appear on stderr"


def test_configure_logging_bare_filename(tmp_path, monkeypatch) -> None:
    """Bare filename (no directory component) must not crash on os.makedirs('')."""
    import logging

    from orchard_worker_mlx.cli import _configure_logging

    monkeypatch.chdir(tmp_path)
    _configure_logging("worker.log")

    test_logger = logging.getLogger("test_bare_filename")
    test_logger.info("bare file test")

    log_path = tmp_path / "worker.log"
    assert log_path.exists(), "bare filename log file should be created in cwd"
    content = log_path.read_text()
    assert "bare file test" in content


# ---------------------------------------------------------------------------
# Opt-in MLX smoke test (requires mlx extra + real model bundle)
# ---------------------------------------------------------------------------

_MLX_SMOKE_MODEL_PATH = os.environ.get("ORCHARD_MLX_SMOKE_MODEL_PATH")


@pytest.mark.skipif(
    _MLX_SMOKE_MODEL_PATH is None,
    reason="Set ORCHARD_MLX_SMOKE_MODEL_PATH to a real Orchard bundle to run MLX smoke tests",
)
def test_mlx_backend_real_load_unload(tmp_path: Path) -> None:
    """Opt-in smoke: prove real MLX load/unload works end-to-end via gRPC."""
    from orchard_worker_mlx.model_loader import load_manifest

    bundle_path = Path(_MLX_SMOKE_MODEL_PATH)  # type: ignore[arg-type]
    manifest = load_manifest(bundle_path)

    socket_path = Path("/tmp") / f"orchard-worker-mlx-smoke-{uuid4().hex[:8]}.sock"
    process = start_worker(socket_path, backend="mlx", verbose=True)

    try:
        channel = wait_for_channel(socket_path, timeout=30.0)
        stub = worker_runtime_pb2_grpc.WorkerRuntimeServiceStub(channel)

        # Load
        ack = stub.LoadModel(
            worker_runtime_pb2.LoadModelRequest(
                model_id=manifest.model_id,
                version=manifest.version,
                model_path=str(bundle_path),
            ),
            timeout=120,
        )
        assert ack.ok is True, f"LoadModel failed: {ack.message}"

        status = stub.GetStatus(worker_runtime_pb2.WorkerStatusRequest())
        assert status.loaded is True

        # Unload
        unload_ack = stub.UnloadModel(
            runtime_pb2.UnloadModelRequest(
                model_id=manifest.model_id,
                version=manifest.version,
            )
        )
        assert unload_ack.ok is True

        status = stub.GetStatus(worker_runtime_pb2.WorkerStatusRequest())
        assert status.loaded is False
    finally:
        process.terminate()
        process.wait(timeout=10)


@pytest.mark.skipif(
    _MLX_SMOKE_MODEL_PATH is None,
    reason="Set ORCHARD_MLX_SMOKE_MODEL_PATH to a real Orchard bundle to run MLX smoke tests",
)
def test_mlx_backend_real_generation(tmp_path: Path) -> None:
    """Opt-in smoke: prove real MLX generation works end-to-end via gRPC."""
    from orchard_worker_mlx.model_loader import load_manifest

    bundle_path = Path(_MLX_SMOKE_MODEL_PATH)  # type: ignore[arg-type]
    manifest = load_manifest(bundle_path)

    socket_path = Path("/tmp") / f"orchard-worker-mlx-gen-{uuid4().hex[:8]}.sock"
    process = start_worker(socket_path, backend="mlx", verbose=True)

    try:
        channel = wait_for_channel(socket_path, timeout=30.0)
        stub = worker_runtime_pb2_grpc.WorkerRuntimeServiceStub(channel)

        # Load model
        ack = stub.LoadModel(
            worker_runtime_pb2.LoadModelRequest(
                model_id=manifest.model_id,
                version=manifest.version,
                model_path=str(bundle_path),
            ),
            timeout=120,
        )
        assert ack.ok is True, f"LoadModel failed: {ack.message}"

        # Generate
        request = runtime_pb2.ExecuteInferenceRequest(
            request_id="req-mlx-gen-smoke",
            controller_session_id="smoke-session",
            model_id=manifest.model_id,
            version=manifest.version,
            rendered_prompt_utf8=b"The capital of France is",
            input_tokens=6,
            params=common_pb2.GenerationParams(
                max_output_tokens=8,
                temperature=0.0,
            ),
        )

        events = list(stub.Generate(request, timeout=60))
        assert len(events) >= 2, f"Expected at least 2 events (delta + terminal), got {len(events)}"

        # Verify at least one output_text_delta
        delta_events = [e for e in events if e.HasField("output_text_delta")]
        assert len(delta_events) >= 1, "Expected at least one output_text_delta"

        # Verify no accepted event from worker
        accepted_events = [e for e in events if e.HasField("accepted")]
        assert len(accepted_events) == 0, "Worker must not emit accepted events"

        # Verify terminal event is completed
        terminal = events[-1]
        assert terminal.HasField("completed"), f"Expected completed, got: {terminal}"

        # Verify usage arithmetic
        usage = terminal.completed.usage
        assert usage.input_tokens == 6
        assert usage.output_tokens > 0
        assert usage.total_tokens == usage.input_tokens + usage.output_tokens

        # Verify finish_reason is valid
        fr = terminal.completed.finish_reason
        assert fr in (
            common_pb2.FINISH_REASON_STOP,
            common_pb2.FINISH_REASON_LENGTH,
        )

        # Unload
        stub.UnloadModel(
            runtime_pb2.UnloadModelRequest(
                model_id=manifest.model_id,
                version=manifest.version,
            )
        )
    finally:
        process.terminate()
        process.wait(timeout=10)


def start_worker(
    socket_path: Path,
    *,
    backend: str = "stub",
    log_file: Path | None = None,
    verbose: bool = False,
) -> subprocess.Popen[str]:
    cmd = [
        sys.executable,
        "-m",
        "orchard_worker_mlx.cli",
        "--socket-path",
        str(socket_path),
        "--backend",
        backend,
    ]
    if log_file is not None:
        cmd.extend(["--log-file", str(log_file)])
    return subprocess.Popen(
        cmd,
        stdout=None if verbose else subprocess.DEVNULL,
        stderr=None if verbose else subprocess.DEVNULL,
        text=True,
    )


def wait_for_channel(socket_path: Path, *, timeout: float = 5.0) -> grpc.Channel:
    deadline = time.monotonic() + timeout
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
