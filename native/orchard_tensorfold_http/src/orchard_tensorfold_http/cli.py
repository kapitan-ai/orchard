"""An explicit source-experiment executable for the existing Node process owner."""

import argparse
import json
import logging
import signal
import threading
from collections.abc import Callable, Sequence
from pathlib import Path
from types import SimpleNamespace
from typing import Any

from orchard_worker_mlx.backends import BackendError
from orchard_worker_mlx.cli import _configure_logging
from orchard_worker_mlx.service import build_server

from orchard_tensorfold_http.admission import ExperimentProfile
from orchard_tensorfold_http.backend import TensorFoldBackend
from orchard_tensorfold_http.native_factory import NativeFactory
from orchard_tensorfold_http.tensorfold_driver import DriverBounds

logger = logging.getLogger(__name__)


def configured_backend(path: Path) -> TensorFoldBackend:
    """Read local operator configuration; never import caller-selected code."""
    if path.stat().st_size > 65536:
        raise ValueError("experiment configuration exceeds fixed schema bound")
    config = json.loads(path.read_bytes())
    if set(config) != {"profile", "bounds", "native"}:
        raise ValueError("unsupported experiment configuration")
    profile = ExperimentProfile(**config["profile"])
    bounds = DriverBounds(**config["bounds"])
    native = config["native"]
    if set(native) != {
        "model_path",
        "max_bundle_files",
        "max_bundle_bytes",
        "prefill_step",
        "cache_limit_bytes",
    }:
        raise ValueError("unsupported native configuration")
    factory = NativeFactory(bounds=bounds, **{**native, "model_path": Path(native["model_path"])})
    return TensorFoldBackend(profile, factory, enabled=True)


def run_worker(
    socket_path: Path,
    backend: TensorFoldBackend,
    *,
    stop_event: threading.Event | None = None,
) -> int:
    """Use one Node-owned PID and the existing Worker RPC/event implementation.

    No HTTP service or additional child process is launched. An uncertain native
    shutdown is reported as failure; only the external Node owner can positively
    prove this process has exited/reaped and admit a fresh incarnation.
    """
    if socket_path.exists() or socket_path.is_symlink():
        raise BackendError("owned_socket_conflict", "worker socket already exists", False)
    socket_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    stop = stop_event or threading.Event()
    server = build_server(
        "tensorfold",
        backend_factory=lambda *_a, **_kw: backend,
        generation_config=SimpleNamespace(mode="stream", max_concurrent_generations=1),
        memory_sampler=lambda: None,
    )
    handlers: dict[int, Any] = {}
    owned_identity: tuple[int, int] | None = None
    code = 0
    try:
        if not server.add_insecure_port(f"unix://{socket_path}"):
            raise BackendError("socket_bind_failed", "owned Worker socket could not bind", False)
        # gRPC creates the socket during binding. Remember only our own inode,
        # including the case where start subsequently fails.
        info = socket_path.lstat()
        owned_identity = (info.st_dev, info.st_ino)
        if threading.current_thread() is threading.main_thread():
            for signum in (signal.SIGTERM, signal.SIGINT):
                handlers[signum] = signal.getsignal(signum)
                signal.signal(signum, lambda *_args: stop.set())
        server.start()
        logger.info("experimental Worker listening")
        while not stop.wait(0.1):
            if server.wait_for_termination(timeout=0):
                # grpc returns True on timeout and False on termination.
                continue
            raise BackendError("server_stopped", "owned Worker server stopped unexpectedly", False)
    finally:
        try:
            backend.shutdown()
        except Exception:
            logger.error("owned Worker shutdown remained uncertain")
            code = 1
        finally:
            server.stop(grace=0).wait(timeout=1)
            for signum, handler in handlers.items():
                signal.signal(signum, handler)
            if socket_path.exists() or socket_path.is_symlink():
                info = socket_path.lstat()
                if (info.st_dev, info.st_ino) == owned_identity:
                    socket_path.unlink()
    return code


def main(
    argv: Sequence[str] | None = None,
    *,
    backend_factory: Callable[[Path], TensorFoldBackend] = configured_backend,
) -> int:
    parser = argparse.ArgumentParser(prog="orchard-worker-tensorfold")
    parser.add_argument("--experimental-tensorfold", action="store_true")
    parser.add_argument("--profile-file", type=Path, required=True)
    parser.add_argument("--socket-path", type=Path, required=True)
    parser.add_argument("--backend", choices=["tensorfold"], required=True)
    parser.add_argument("--log-file")
    parser.add_argument("--prefix-cache-mode", choices=["disabled"], default="disabled")
    parser.add_argument("--prefix-cache-max-entries", type=int, default=0)
    parser.add_argument("--prefix-cache-max-bytes", type=int, default=0)
    parser.add_argument("--generation-mode", choices=["stream"], default="stream")
    parser.add_argument("--max-concurrent-generations", choices=["1"], default="1")
    parser.add_argument("--auto-max-concurrent-generations", type=int, default=1)
    parser.add_argument("--memory-budget-mode", choices=["disabled"], default="disabled")
    parser.add_argument("--memory-budget-utilization", type=float, default=0.9)
    parser.add_argument("--memory-budget-overhead-bytes", type=int, default=0)
    args = parser.parse_args(argv)
    if not args.experimental_tensorfold:
        parser.error("the source experiment must be explicitly enabled")
    if (
        args.prefix_cache_max_bytes != 0
        or not 0 <= args.prefix_cache_max_entries <= 4294967295
        or args.auto_max_concurrent_generations != 1
        or args.memory_budget_overhead_bytes != 0
        or args.memory_budget_utilization != 0.9
    ):
        parser.error("unsupported legacy Worker configuration")
    # Node supplies a positive legacy entries hint even in disabled mode.
    # It remains inert: only the frozen DriverBounds controls TF checkpoints.
    _configure_logging(args.log_file)
    try:
        backend = backend_factory(args.profile_file)
        return run_worker(args.socket_path, backend)
    except (BackendError, ValueError, OSError, TypeError):
        logger.error("experimental Worker setup failed")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
