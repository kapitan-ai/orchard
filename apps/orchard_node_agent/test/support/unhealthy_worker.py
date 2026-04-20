#!/usr/bin/env python3
"""Minimal gRPC worker that always reports ready=false.

Used by Elixir integration tests to verify fail-fast readiness polling.
Accepts the same CLI args as the real worker (--socket-path, --backend, --log-file)
but ignores --backend and --log-file.
"""

import argparse
import signal
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

# Imports resolve via ``uv run --directory .../native/orchard_worker_mlx``
# in the shell wrapper (unhealthy-worker), which puts the worker package
# on the Python path automatically.
import grpc
from orchard_worker_mlx.generated.cluster.v1 import common_pb2
from orchard_worker_mlx.generated.orchard.worker.v1 import (
    worker_runtime_pb2,
    worker_runtime_pb2_grpc,
)


class UnhealthyServicer(worker_runtime_pb2_grpc.WorkerRuntimeServiceServicer):
    def GetStatus(self, request, context):
        return worker_runtime_pb2.WorkerStatusResponse(
            loaded=False,
            active_request_count=0,
            ready=False,
            health_code="mlx_backend_unavailable",
            health_message="MLX dependencies not available (test fixture)",
        )

    def LoadModel(self, request, context):
        return common_pb2.Ack(
            ok=False,
            message="mlx_backend_unavailable: worker is unhealthy",
        )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket-path", required=True)
    parser.add_argument("--backend", default="stub")
    parser.add_argument("--log-file", default=None)
    parser.add_argument("--prefix-cache-mode", default="kv")
    parser.add_argument("--prefix-cache-max-entries", type=int, default=8)
    parser.add_argument("--prefix-cache-max-bytes", type=int, default=0)
    parser.add_argument("--generation-mode", default="stream")
    parser.add_argument("--max-concurrent-generations", type=int, default=1)
    parser.add_argument("--memory-budget-mode", default="observe")
    parser.add_argument("--memory-budget-utilization", type=float, default=0.90)
    parser.add_argument("--memory-budget-overhead-bytes", type=int, default=1_073_741_824)
    args = parser.parse_args()

    socket_path = Path(args.socket_path)
    socket_path.parent.mkdir(parents=True, exist_ok=True)
    if socket_path.exists():
        socket_path.unlink()

    server = grpc.server(ThreadPoolExecutor(max_workers=2))
    worker_runtime_pb2_grpc.add_WorkerRuntimeServiceServicer_to_server(
        UnhealthyServicer(), server
    )
    server.add_insecure_port(f"unix://{args.socket_path}")

    def shutdown(signum, frame):
        server.stop(grace=0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    server.start()
    print(f"unhealthy worker listening on {args.socket_path}", flush=True)
    server.wait_for_termination()


if __name__ == "__main__":
    main()
