from __future__ import annotations

import argparse
from collections.abc import Sequence

from orchard_worker_mlx import __version__
from orchard_worker_mlx.service import serve


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="orchard-worker-mlx",
        description="Orchard MLX worker runtime entrypoint.",
    )
    parser.add_argument(
        "--socket-path", required=True, help="Unix domain socket path for the worker server"
    )
    parser.add_argument(
        "--backend",
        choices=["mlx", "stub"],
        default="stub",
        help="worker backend implementation",
    )
    parser.add_argument("--version", action="store_true", help="print the package version and exit")
    args = parser.parse_args(argv)

    if args.version:
        print(__version__)
        return 0

    serve(args.socket_path, args.backend)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
