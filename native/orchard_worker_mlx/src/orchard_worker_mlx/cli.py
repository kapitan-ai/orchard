from __future__ import annotations

import argparse
import logging
import os
import sys
from collections.abc import Mapping, Sequence

from orchard_worker_mlx import __version__
from orchard_worker_mlx.service import serve
from orchard_worker_mlx.strict_prefix_checkpoints import (
    DEFAULT_REPLY_MARKER,
    StrictPrefixCheckpointConfig,
)

_LOG_FORMAT = "[%(levelname)s] %(name)s %(message)s"

STRICT_PREFIX_ENV = "ORCHARD_WORKER_STRICT_PREFIX_CHECKPOINTS"
STRICT_PREFIX_SLOTS_ENV = "ORCHARD_WORKER_STRICT_PREFIX_SLOTS"
STRICT_PREFIX_SLOT_BYTES_ENV = "ORCHARD_WORKER_STRICT_PREFIX_SLOT_BYTES"
STRICT_PREFIX_BUDGET_BYTES_ENV = "ORCHARD_WORKER_STRICT_PREFIX_BUDGET_BYTES"
STRICT_PREFIX_REPLY_MARKER_ENV = "ORCHARD_WORKER_STRICT_PREFIX_REPLY_MARKER"


def _env_int(environ: Mapping[str, str], name: str, default: int | None = None) -> int:
    raw = environ.get(name)
    if raw is None or raw == "":
        if default is None:
            raise ValueError(f"{name} is required when {STRICT_PREFIX_ENV}=enabled")
        return default
    try:
        return int(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer, got {raw!r}") from exc


def strict_prefix_config_from_env(
    environ: Mapping[str, str],
) -> StrictPrefixCheckpointConfig | None:
    """Read the default-off strict-prefix checkpoint settings.

    The Worker inherits these from the node-agent environment.  Unset or
    ``disabled`` keeps current behavior.
    """
    mode = environ.get(STRICT_PREFIX_ENV, "disabled") or "disabled"
    if mode == "disabled":
        return None
    if mode != "enabled":
        raise ValueError(f"{STRICT_PREFIX_ENV} must be disabled|enabled, got {mode!r}")
    return StrictPrefixCheckpointConfig(
        slots=_env_int(environ, STRICT_PREFIX_SLOTS_ENV, default=1),
        slot_bytes=_env_int(environ, STRICT_PREFIX_SLOT_BYTES_ENV),
        budget_bytes=_env_int(environ, STRICT_PREFIX_BUDGET_BYTES_ENV),
        reply_marker=environ.get(STRICT_PREFIX_REPLY_MARKER_ENV) or DEFAULT_REPLY_MARKER,
    )


def _positive_int_or_auto(value: str) -> int | str:
    if value == "auto":
        return "auto"
    try:
        parsed = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be a positive integer or 'auto'") from exc
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be a positive integer or 'auto'")
    return parsed


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
    argv_list = list(argv) if argv is not None else sys.argv[1:]
    parser = argparse.ArgumentParser(
        prog="orchard-worker-mlx",
        description="Orchard MLX worker runtime entrypoint.",
    )
    parser.add_argument(
        "--socket-path", required=True, help="Unix domain socket path for the worker server"
    )
    parser.add_argument(
        "--backend",
        choices=["mlx", "stub", "vllm_poc"],
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
        default="batch",
        help=(
            "generation runtime mode "
            "(default: batch; enables real concurrent generation in the mlx worker path)"
        ),
    )
    parser.add_argument(
        "--max-concurrent-generations",
        type=_positive_int_or_auto,
        default="auto",
        help=(
            "maximum concurrent generations in batch mode "
            "(default: auto; applies when --generation-mode=batch)"
        ),
    )
    parser.add_argument(
        "--auto-max-concurrent-generations",
        type=int,
        default=3,
        help=(
            "upper bound for auto concurrency in batch mode "
            "(default: 3; applies when --max-concurrent-generations=auto)"
        ),
    )
    parser.add_argument(
        "--memory-budget-mode",
        choices=["disabled", "observe", "enforce"],
        default="observe",
        help=(
            "memory-budget mode (default: observe; enforce aborts active "
            "generations without unloading the model when the sampled working "
            "set exceeds the budget target)"
        ),
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
    args = parser.parse_args(argv_list)

    if args.version:
        print(__version__)
        return 0

    if args.backend in {"stub", "vllm_poc"} and "--generation-mode" not in argv_list:
        args.generation_mode = "stream"

    if args.backend in {"stub", "vllm_poc"} and args.generation_mode == "batch":
        parser.error(f"backend={args.backend} does not support --generation-mode=batch")

    _configure_logging(args.log_file)

    from orchard_worker_mlx.model_loader import (
        GenerationRuntimeConfig,
        MemoryBudgetConfig,
        PrefixCacheLoadConfig,
    )

    try:
        strict_prefix = strict_prefix_config_from_env(os.environ)
        if strict_prefix is not None:
            if args.backend != "mlx":
                raise ValueError(f"{STRICT_PREFIX_ENV}=enabled requires --backend=mlx")
            if args.prefix_cache_mode != "disabled":
                raise ValueError(
                    f"{STRICT_PREFIX_ENV}=enabled requires --prefix-cache-mode disabled "
                    "(ORCHARD_WORKER_PREFIX_CACHE_MODE=disabled)"
                )
            if args.generation_mode != "stream":
                raise ValueError(f"{STRICT_PREFIX_ENV}=enabled requires --generation-mode=stream")
            if args.memory_budget_mode == "enforce":
                raise ValueError(
                    f"{STRICT_PREFIX_ENV}=enabled requires --memory-budget-mode disabled or observe"
                )
        prefix_cache_config = PrefixCacheLoadConfig(
            mode=args.prefix_cache_mode,
            max_entries=args.prefix_cache_max_entries,
            max_bytes=args.prefix_cache_max_bytes,
            max_fingerprint_buffer_size=args.max_fingerprint_buffer_size,
            strict_prefix=strict_prefix,
        )
        generation_config = GenerationRuntimeConfig(
            mode=args.generation_mode,
            max_concurrent_generations=args.max_concurrent_generations,
            auto_max_concurrent_generations=args.auto_max_concurrent_generations,
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
