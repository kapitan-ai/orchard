"""Owned executable lifecycle; only CPU fakes and a local fake-engine UDS."""

import json
import tempfile
import threading
from dataclasses import asdict
from pathlib import Path
from unittest.mock import Mock

import grpc
import pytest
from orchard_worker_mlx.backends import BackendError
from orchard_worker_mlx.generated.cluster.v1 import runtime_pb2
from orchard_worker_mlx.generated.orchard.worker.v1 import (
    worker_runtime_pb2,
    worker_runtime_pb2_grpc,
)
from test_admission import profile as profile
from test_admission import request_for
from test_backend import runtime as runtime
from test_native_factory import native_bounds
from test_tensorfold_driver import bounds as bounds

from orchard_tensorfold_http import cli


def test_real_uds_status_offer_generation_unload_and_owned_cleanup(runtime):
    # macOS UDS path limit is 103 bytes; pytest's default temp path exceeds it.
    owned_directory = tempfile.TemporaryDirectory(prefix="tf-", dir="/tmp")
    socket = Path(owned_directory.name) / "worker.sock"
    stop = threading.Event()
    result = []
    failures = []

    def run():
        try:
            result.append(cli.run_worker(socket, runtime.backend, stop_event=stop))
        except Exception as exc:
            failures.append(exc)

    thread = threading.Thread(target=run)
    thread.start()
    channel = grpc.insecure_channel(f"unix://{socket}")
    try:
        try:
            grpc.channel_ready_future(channel).result(timeout=3)
        except grpc.FutureTimeoutError:
            assert not failures, str(failures)
            raise
        stub = worker_runtime_pb2_grpc.WorkerRuntimeServiceStub(channel)
        status = stub.GetStatus(worker_runtime_pb2.WorkerStatusRequest(), timeout=1)
        binding = json.loads(status.tensorfold_profile_admission_json)
        assert binding == runtime.backend.profile.binding(runtime.backend.incarnation)
        assert len(status.tensorfold_profile_admission_json) <= 4096
        request = request_for(runtime.backend.profile, binding["incarnation"])
        events = list(stub.Generate(request, timeout=2))
        assert events[-1].WhichOneof("event") == "completed"
        assert "".join(e.output_text_delta.delta for e in events) == "opaque</think>\n\nfinal"
        assert stub.UnloadModel(runtime_pb2.UnloadModelRequest(), timeout=2).ok
        status = stub.GetStatus(worker_runtime_pb2.WorkerStatusRequest(), timeout=1)
        assert not status.loaded and not status.tensorfold_profile_admission_json
    finally:
        channel.close()
        stop.set()
        thread.join(timeout=3)
    assert not thread.is_alive() and not failures and result == [0]
    assert not socket.exists()
    owned_directory.cleanup()


def test_refuses_unowned_existing_socket_without_deleting(tmp_path):
    socket = tmp_path / "worker.sock"
    socket.write_text("other owner")
    backend = Mock()
    with pytest.raises(BackendError, match="already exists"):
        cli.run_worker(socket, backend)
    assert socket.read_text() == "other owner"
    backend.shutdown.assert_not_called()


@pytest.mark.parametrize("failure", ["bind", "start", "unexpected_stop", "shutdown"])
def test_bootstrap_and_shutdown_faults_cleanup_only_owned_inode(tmp_path, monkeypatch, failure):
    socket = tmp_path / "worker.sock"
    backend, server = Mock(), Mock()
    stopped = threading.Event()
    stopped.set()

    def bind(_target):
        if failure == "bind":
            return 0
        socket.write_text("created by owned bind")
        return 1

    server.add_insecure_port.side_effect = bind
    if failure == "start":
        server.start.side_effect = RuntimeError("start failed")
    if failure == "shutdown":
        backend.shutdown.side_effect = RuntimeError("uncertain")
    if failure == "unexpected_stop":
        stopped.clear()
        server.wait_for_termination.return_value = False
    monkeypatch.setattr(cli, "build_server", lambda *_a, **_kw: server)
    if failure in {"bind", "start", "unexpected_stop"}:
        with pytest.raises((BackendError, RuntimeError)):
            cli.run_worker(socket, backend, stop_event=stopped)
    else:
        assert cli.run_worker(socket, backend, stop_event=stopped) == 1
    backend.shutdown.assert_called_once()
    server.stop.assert_called_once_with(grace=0)
    assert not socket.exists()


def test_replaced_socket_is_preserved_during_cleanup(tmp_path, monkeypatch):
    socket = tmp_path / "worker.sock"
    server, backend = Mock(), Mock()
    stopped = threading.Event()
    stopped.set()

    def bind(_target):
        socket.write_text("owned")
        return 1

    def shutdown():
        replacement = tmp_path / "replacement"
        replacement.write_text("another owner")
        replacement.replace(socket)

    server.add_insecure_port.side_effect = bind
    backend.shutdown.side_effect = shutdown
    monkeypatch.setattr(cli, "build_server", lambda *_a, **_kw: server)
    assert cli.run_worker(socket, backend, stop_event=stopped) == 0
    assert socket.read_text() == "another owner"


@pytest.mark.parametrize(
    "extra",
    [
        [],
        ["--experimental-tensorfold", "--prefix-cache-max-entries", "-1"],
        ["--experimental-tensorfold", "--memory-budget-overhead-bytes", "1"],
    ],
)
def test_explicit_selector_and_frozen_controls_before_factory(tmp_path, extra):
    factory = Mock()
    with pytest.raises(SystemExit):
        cli.main(
            [
                "--backend",
                "tensorfold",
                "--profile-file",
                str(tmp_path / "profile.json"),
                "--socket-path",
                str(tmp_path / "worker.sock"),
                *extra,
            ],
            backend_factory=factory,
        )
    factory.assert_not_called()


def test_setup_errors_are_constant_and_return_failure(tmp_path, caplog):
    factory = Mock(side_effect=ValueError("private configuration"))
    assert (
        cli.main(
            [
                "--experimental-tensorfold",
                "--backend",
                "tensorfold",
                "--profile-file",
                str(tmp_path / "profile.json"),
                "--socket-path",
                str(tmp_path / "worker.sock"),
            ],
            backend_factory=factory,
        )
        == 1
    )
    assert "private configuration" not in caplog.text


def test_explicit_node_worker_argument_shape_accepts_inert_cache_entries(tmp_path, monkeypatch):
    # WorkerRuntimeAdapter.worker_cli_args always includes a positive entries
    # hint, even when Node.worker_prefix_cache_mode is disabled.
    factory = Mock(return_value=Mock())
    run = Mock(return_value=0)
    monkeypatch.setattr(cli, "run_worker", run)
    monkeypatch.setattr(cli, "_configure_logging", Mock())
    socket, profile_file = tmp_path / "worker.sock", tmp_path / "profile.json"
    node_args = [
        "--socket-path",
        str(socket),
        "--backend",
        "tensorfold",
        "--log-file",
        str(tmp_path / "worker.log"),
        "--prefix-cache-mode",
        "disabled",
        "--prefix-cache-max-entries",
        "8",
        "--prefix-cache-max-bytes",
        "0",
        "--generation-mode",
        "stream",
        "--max-concurrent-generations",
        "1",
        "--auto-max-concurrent-generations",
        "1",
        "--memory-budget-mode",
        "disabled",
        "--memory-budget-utilization",
        "0.9",
        "--memory-budget-overhead-bytes",
        "0",
    ]
    assert (
        cli.main(
            ["--experimental-tensorfold", "--profile-file", str(profile_file), *node_args],
            backend_factory=factory,
        )
        == 0
    )
    factory.assert_called_once_with(profile_file)
    run.assert_called_once_with(socket, factory.return_value)


def test_local_configuration_constructs_explicit_backend_without_loading(tmp_path, profile, bounds):
    path = tmp_path / "profile.json"
    config = {
        "profile": asdict(profile),
        "bounds": asdict(native_bounds(bounds)),
        "native": {
            "model_path": str(tmp_path / "model"),
            "max_bundle_files": 10,
            "max_bundle_bytes": 10000,
            "prefill_step": 2,
            "cache_limit_bytes": 64,
        },
    }
    path.write_text(json.dumps(config))
    backend = cli.configured_backend(path)
    assert backend.profile == profile and not backend.status()["loaded"]
    assert backend.tensorfold_profile_admission() == b""
    config["unexpected"] = "control"
    path.write_text(json.dumps(config))
    with pytest.raises(ValueError, match="unsupported"):
        cli.configured_backend(path)
    path.write_bytes(b" " * 65537)
    with pytest.raises(ValueError, match="bound"):
        cli.configured_backend(path)


def test_local_configuration_refuses_a_lease_bound_below_the_copy_peak(tmp_path, profile, bounds):
    path = tmp_path / "profile.json"
    short = native_bounds(bounds, leases=bounds.max_cache_leases - 1)
    config = {
        "profile": asdict(profile),
        "bounds": asdict(short),
        "native": {
            "model_path": str(tmp_path / "model"),
            "max_bundle_files": 10,
            "max_bundle_bytes": 10000,
            "prefill_step": 2,
            "cache_limit_bytes": 64,
        },
    }
    path.write_text(json.dumps(config))
    with pytest.raises(ValueError, match="cache lease bound is below"):
        cli.configured_backend(path)


def test_local_configuration_requires_an_explicit_cache_limit(tmp_path, profile, bounds):
    path = tmp_path / "profile.json"
    native = {
        "model_path": str(tmp_path / "model"),
        "max_bundle_files": 10,
        "max_bundle_bytes": 10000,
        "prefill_step": 2,
    }
    config = {"profile": asdict(profile), "bounds": asdict(native_bounds(bounds)), "native": native}
    path.write_text(json.dumps(config))
    with pytest.raises(ValueError, match="unsupported native configuration"):
        cli.configured_backend(path)
    native["cache_limit_bytes"] = 17179869184
    path.write_text(json.dumps(config))
    assert cli.configured_backend(path)._loader.cache_limit_bytes == 17179869184
