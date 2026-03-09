from __future__ import annotations

import argparse
import json
from collections.abc import Sequence
from typing import Any

from orchard_worker_mlx import __version__


def build_placeholder_response(socket_path: str | None = None) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "component": "orchard_worker_mlx",
        "status": "not_implemented",
        "message": "MLX worker scaffold only; gRPC runtime server lands in R5.",
    }

    if socket_path is not None:
        payload["socket_path"] = socket_path

    return payload


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="orchard-worker-mlx",
        description="Orchard MLX worker scaffold entrypoint.",
    )
    parser.add_argument(
        "--socket-path", help="future Unix domain socket path for the worker server"
    )
    parser.add_argument("--version", action="store_true", help="print the package version and exit")
    args = parser.parse_args(argv)

    if args.version:
        print(__version__)
        return 0

    print(json.dumps(build_placeholder_response(socket_path=args.socket_path)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
