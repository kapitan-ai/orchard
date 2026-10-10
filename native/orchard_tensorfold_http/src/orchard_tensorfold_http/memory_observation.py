"""Request-scoped memory diagnostics for the TensorFold Worker experiment.

These samples only observe. They set no limit, clear no cache and add no
native barrier. MLX counters describe the whole process, so a request's peak
is the process high-water mark while that request ran, not bytes it owned.
Copy sizes are array-byte estimates, never physical allocations. Nothing here
logs request content.
"""

import logging
from collections.abc import Callable
from typing import Any

logger = logging.getLogger(__name__)

Counter = Callable[[], int]


class MemoryObserver:
    """Logs one line per request phase; every failure is swallowed."""

    def __init__(
        self,
        *,
        active: Counter,
        cache: Counter,
        peak: Counter,
        reset_peak: Callable[[], Any],
        footprint: Callable[[], int | None],
        estimate: Callable[[list[Any]], int],
    ):
        self._active, self._cache, self._peak = active, cache, peak
        self._reset_peak, self._footprint, self._estimate = reset_peak, footprint, estimate
        self._sequence = 0
        self._copies = 0
        self._copy_bytes = 0

    def request_start(self, custody: Any, checkpoints: int) -> None:
        """Sample before submission, then start a new peak interval."""
        self._sequence += 1
        self._copies = self._copy_bytes = 0
        self.phase("request_start", custody, checkpoints)
        try:
            self._reset_peak()
        except Exception:
            logger.debug("tensorfold memory peak reset unavailable")

    def copied(self, cache: list[Any]) -> None:
        self._copies += 1
        try:
            self._copy_bytes += max(0, int(self._estimate(cache)))
        except Exception:
            logger.debug("tensorfold memory copy estimate unavailable")

    def phase(self, name: str, custody: Any, checkpoints: int, stream: Any = None) -> None:
        try:
            widths = [int(w) for w in getattr(stream, "prefill_widths", None) or ()]
            raised = sum(1 for r in getattr(stream, "prefill_raised", None) or () if r)
            logger.info(
                "tensorfold memory phase=%s seq=%d active=%s cache=%s peak=%s footprint=%s "
                "leases=%d held=%d checkpoints=%d copies=%d copy_bytes_est=%d "
                "max_pass_width=%d pass_cache_raises=%d",
                name,
                self._sequence,
                _read(self._active),
                _read(self._cache),
                _read(self._peak),
                _read(self._footprint),
                custody.leases,
                custody.held_bytes,
                checkpoints,
                self._copies,
                self._copy_bytes,
                max(widths, default=0),
                raised,
            )
        except Exception:
            logger.debug("tensorfold memory sample unavailable")


def _read(counter: Callable[[], int | None]) -> str:
    try:
        value = counter()
    except Exception:
        return "unavailable"
    return str(value) if type(value) is int and value >= 0 else "unavailable"
