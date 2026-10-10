"""Experiment-only memory switches for the KAP-128 A/B run. Not for merge.

Each switch is read from the Worker environment at native load. Unset means
today's behavior. Values are positive byte counts, or "1" for the clear switch.
"""

import logging
import os
from collections.abc import Mapping
from dataclasses import dataclass

logger = logging.getLogger(__name__)

CACHE_LIMIT_ENV = "ORCHARD_TENSORFOLD_AB_CACHE_LIMIT_BYTES"
MEMORY_LIMIT_ENV = "ORCHARD_TENSORFOLD_AB_MEMORY_LIMIT_BYTES"
CLEAR_ENV = "ORCHARD_TENSORFOLD_AB_CLEAR_AFTER_RELEASE"


@dataclass(frozen=True)
class MemorySwitches:
    cache_limit: int | None = None
    memory_limit: int | None = None
    clear_after_release: bool = False


def _bytes(environ: Mapping[str, str], name: str) -> int | None:
    value = environ.get(name)
    if value is None or value == "":
        return None
    if not value.isdigit() or int(value) <= 0:
        raise ValueError(f"{name} must be a positive byte count")
    return int(value)


def read_switches(environ: Mapping[str, str] | None = None) -> MemorySwitches:
    environ = os.environ if environ is None else environ
    clear = environ.get(CLEAR_ENV, "")
    if clear not in ("", "0", "1"):
        raise ValueError(f"{CLEAR_ENV} must be 0 or 1")
    return MemorySwitches(
        cache_limit=_bytes(environ, CACHE_LIMIT_ENV),
        memory_limit=_bytes(environ, MEMORY_LIMIT_ENV),
        clear_after_release=clear == "1",
    )


def apply_switches(mx, switches: MemorySwitches) -> None:
    """Set the requested MLX limits before weights load, and log the variant."""
    if switches.cache_limit is not None:
        mx.set_cache_limit(switches.cache_limit)
    if switches.memory_limit is not None:
        mx.set_memory_limit(switches.memory_limit)
    logger.warning(
        "tensorfold memory A/B cache_limit=%s memory_limit=%s clear_after_release=%s",
        switches.cache_limit if switches.cache_limit is not None else "default",
        switches.memory_limit if switches.memory_limit is not None else "default",
        switches.clear_after_release,
    )
