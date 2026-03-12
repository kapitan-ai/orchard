from __future__ import annotations

import argparse
import logging
import os
from collections.abc import Sequence

from orchard_worker_mlx import __version__
from orchard_worker_mlx.service import serve

_LOG_FORMAT = "[%(levelname)s] %(name)s %(message)s"


def _configure_logging(log_file: str | None = None) -> None:
    """Configure stdlib logging with stdout stream + optional file handler."""
    root = logging.getLogger()
    # Clear any existing handlers for repeatable calls (e.g. tests).
    root.handlers.clear()
    root.setLevel(logging.INFO)

    formatter = logging.Formatter(_LOG_FORMAT)

    stdout_handler = logging.StreamHandler()
    stdout_handler.setFormatter(formatter)
    root.addHandler(stdout_handler)

    if log_file is not None:
        os.makedirs(os.path.dirname(log_file), exist_ok=True)
        file_handler = logging.FileHandler(log_file, mode="w", encoding="utf-8")
        file_handler.setFormatter(formatter)
        root.addHandler(file_handler)


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
    parser.add_argument(
        "--log-file",
        default=None,
        help="optional path for a persistent log file (truncated per spawn)",
    )
    parser.add_argument("--version", action="store_true", help="print the package version and exit")
    args = parser.parse_args(argv)

    if args.version:
        print(__version__)
        return 0

    _configure_logging(args.log_file)
    serve(args.socket_path, args.backend)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
