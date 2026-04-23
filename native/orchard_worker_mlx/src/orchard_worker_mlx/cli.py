from __future__ import annotations

import argparse
import logging
import os
import sys
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

    stdout_handler = logging.StreamHandler(stream=sys.stdout)
    stdout_handler.setFormatter(formatter)
    root.addHandler(stdout_handler)

    if log_file is not None:
        parent_dir = os.path.dirname(log_file)
        if parent_dir:
            os.makedirs(parent_dir, exist_ok=True)
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
    parser.add_argument(
        "--prefix-cache-mode",
        choices=["disabled", "kv", "trie"],
        default="kv",
        help="prefix cache implementation (default: kv)",
    )
    parser.add_argument(
        "--prefix-cache-max-entries",
        type=int,
        default=8,
        help="maximum prefix cache entries (default: 8)",
    )
    parser.add_argument(
        "--prefix-cache-max-bytes",
        type=int,
        default=0,
        help="maximum prefix cache byte budget; 0 disables (default: 0)",
    )
    parser.add_argument(
        "--max-fingerprint-buffer-size",
        type=int,
        default=8,
        help="maximum published prefix-cache fingerprints, capped at 64 (default: 8)",
    )
    parser.add_argument(
        "--generation-mode",
        choices=["stream", "batch"],
        default="stream",
        help=(
            "generation runtime mode "
            "(default: stream; batch enables real concurrent generation in the mlx worker path)"
        ),
    )
    parser.add_argument(
        "--max-concurrent-generations",
        type=int,
        default=1,
        help=(
            "maximum concurrent generations in batch mode "
            "(default: 1; applies when --generation-mode=batch)"
        ),
    )
    parser.add_argument(
        "--memory-budget-mode",
        choices=["disabled", "observe"],
        default="observe",
        help="memory-budget mode (default: observe; enforce is not yet supported)",
    )
    parser.add_argument(
        "--memory-budget-utilization",
        type=float,
        default=0.90,
        help="fraction of max recommended working set to target (default: 0.90)",
    )
    parser.add_argument(
        "--memory-budget-overhead-bytes",
        type=int,
        default=1_073_741_824,
        help="fixed memory-budget overhead in bytes (default: 1073741824)",
    )
    args = parser.parse_args(argv)

    if args.version:
        print(__version__)
        return 0

    if args.backend == "stub" and args.generation_mode == "batch":
        parser.error("backend=stub does not support --generation-mode=batch")

    _configure_logging(args.log_file)

    from orchard_worker_mlx.model_loader import (
        GenerationRuntimeConfig,
        MemoryBudgetConfig,
        PrefixCacheLoadConfig,
    )

    try:
        prefix_cache_config = PrefixCacheLoadConfig(
            mode=args.prefix_cache_mode,
            max_entries=args.prefix_cache_max_entries,
            max_bytes=args.prefix_cache_max_bytes,
            max_fingerprint_buffer_size=args.max_fingerprint_buffer_size,
        )
        generation_config = GenerationRuntimeConfig(
            mode=args.generation_mode,
            max_concurrent_generations=args.max_concurrent_generations,
        )
        memory_budget_config = MemoryBudgetConfig(
            mode=args.memory_budget_mode,
            utilization=args.memory_budget_utilization,
            overhead_bytes=args.memory_budget_overhead_bytes,
        )
    except ValueError as exc:
        parser.error(str(exc))

    serve(
        args.socket_path,
        args.backend,
        prefix_cache_config=prefix_cache_config,
        generation_config=generation_config,
        memory_budget_config=memory_budget_config,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
