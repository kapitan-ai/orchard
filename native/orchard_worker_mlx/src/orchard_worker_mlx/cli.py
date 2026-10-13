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

STRICT_PREFIX_MODE = "strict_prefix"
# The spike enabled strict-prefix reuse through this inherited variable.  The
# Node Agent now launches Workers without it; a Worker that still sees it was
# started by an older Node, so it refuses instead of enabling reuse for every
# model on that Node.
LEGACY_STRICT_PREFIX_ENV = "ORCHARD_WORKER_STRICT_PREFIX_CHECKPOINTS"


def refuse_legacy_strict_prefix_env(environ: Mapping[str, str]) -> None:
    value = environ.get(LEGACY_STRICT_PREFIX_ENV, "")
    if value not in ("", "disabled"):
        raise ValueError(
            f"{LEGACY_STRICT_PREFIX_ENV}={value} is no longer supported; unset it and enable "
            "strict-prefix reuse per model with --prefix-cache-mode strict_prefix"
        )


def strict_prefix_config_from_args(args: argparse.Namespace) -> StrictPrefixCheckpointConfig | None:
    """Build strict-prefix settings from the CLI, or refuse a bad combination."""
    strict_flags = {
        "--strict-prefix-slots": args.strict_prefix_slots,
        "--strict-prefix-slot-bytes": args.strict_prefix_slot_bytes,
        "--strict-prefix-budget-bytes": args.strict_prefix_budget_bytes,
        "--strict-prefix-reply-marker": args.strict_prefix_reply_marker,
    }
    if args.prefix_cache_mode != STRICT_PREFIX_MODE:
        given = sorted(flag for flag, value in strict_flags.items() if value is not None)
        if given:
            raise ValueError(f"{', '.join(given)} require --prefix-cache-mode {STRICT_PREFIX_MODE}")
        return None

    missing = [
        flag
        for flag in ("--strict-prefix-slot-bytes", "--strict-prefix-budget-bytes")
        if strict_flags[flag] is None
    ]
    if missing:
        raise ValueError(
            f"--prefix-cache-mode {STRICT_PREFIX_MODE} requires {' and '.join(missing)}"
        )
    if args.backend != "mlx":
        raise ValueError(f"--prefix-cache-mode {STRICT_PREFIX_MODE} requires --backend=mlx")
    if args.generation_mode != "stream":
        raise ValueError(
            f"--prefix-cache-mode {STRICT_PREFIX_MODE} requires --generation-mode=stream"
        )
    if args.memory_budget_mode != "observe":
        raise ValueError(
            f"--prefix-cache-mode {STRICT_PREFIX_MODE} requires --memory-budget-mode observe"
        )
    return StrictPrefixCheckpointConfig(
        slots=1 if args.strict_prefix_slots is None else args.strict_prefix_slots,
        slot_bytes=args.strict_prefix_slot_bytes,
        budget_bytes=args.strict_prefix_budget_bytes,
        reply_marker=args.strict_prefix_reply_marker or DEFAULT_REPLY_MARKER,
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
        choices=["disabled", "kv", "trie", STRICT_PREFIX_MODE],
        default="kv",
        help="prefix cache implementation (default: kv)",
    )
    parser.add_argument(
        "--strict-prefix-slots",
        type=int,
        default=None,
        help="strict_prefix only: checkpoint slots (default: 1)",
    )
    parser.add_argument(
        "--strict-prefix-slot-bytes",
        type=int,
        default=None,
        help="strict_prefix only: fixed charge per checkpoint slot in bytes",
    )
    parser.add_argument(
        "--strict-prefix-budget-bytes",
        type=int,
        default=None,
        help="strict_prefix only: checkpoint budget in bytes; must hold every slot",
    )
    parser.add_argument(
        "--strict-prefix-reply-marker",
        default=None,
        help=f"strict_prefix only: reply marker text (default: {DEFAULT_REPLY_MARKER!r})",
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

    if args.backend == "stub" and "--generation-mode" not in argv_list:
        args.generation_mode = "stream"

    if args.backend == "stub" and args.generation_mode == "batch":
        parser.error("backend=stub does not support --generation-mode=batch")

    _configure_logging(args.log_file)

    from orchard_worker_mlx.model_loader import (
        GenerationRuntimeConfig,
        MemoryBudgetConfig,
        PrefixCacheLoadConfig,
    )

    try:
        refuse_legacy_strict_prefix_env(os.environ)
        strict_prefix = strict_prefix_config_from_args(args)
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
