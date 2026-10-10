"""Request-scoped memory diagnostics for the TensorFold Worker experiment.

These samples only observe. They set no limit, clear no cache and add no
native barrier. MLX counters describe the whole process. MLX resets the peak to
zero, so a request's peak is the highest active memory seen at an allocation
since submission, not bytes the request owned. Copy sizes are array-byte
estimates, never physical allocations. Nothing here logs request content.

The calling thread only reads counters and queues a tuple of numbers; one
background writer per process formats and logs it, so diagnostics never log on
the settlement path. When the bounded queue is full, the sample is dropped and
counted. The writer still shares the Worker's log handlers and stream.
"""

import atexit
import logging
import queue
import threading
import time
from collections.abc import Callable
from typing import Any

logger = logging.getLogger(__name__)

Counter = Callable[[], int | None]
UNAVAILABLE = "unavailable"
EXIT_FLUSH_SECONDS = 2.0
_FORMAT = (
    "tensorfold memory phase=%s seq=%d active=%s cache=%s peak=%s footprint=%s "
    "leases=%d held=%d checkpoints=%d copies=%d copy_bytes_est=%s "
    "max_pass_width=%d pass_cache_raises=%d dropped=%d"
)


class LogWriter:
    """Formats queued samples on its own daemon thread."""

    def __init__(self, capacity: int = 64):
        self._lines: queue.Queue[tuple[Any, ...]] = queue.Queue(maxsize=capacity)
        self._lock = threading.Lock()
        self._thread: threading.Thread | None = None
        self.dropped = 0

    def submit(self, line: tuple[Any, ...]) -> None:
        with self._lock:
            if self._thread is None:
                self._thread = threading.Thread(
                    target=self._drain, name="tensorfold-memory-log", daemon=True
                )
                self._thread.start()
        try:
            self._lines.put_nowait(line)
        except queue.Full:
            self.dropped += 1

    def join(self) -> None:
        """Wait until every queued sample has been logged (tests and shutdown only)."""
        self._lines.join()

    def flush(self, timeout: float) -> bool:
        """Wait up to `timeout` seconds for queued samples; never called on a request path."""
        deadline = time.monotonic() + timeout
        with self._lines.all_tasks_done:
            while self._lines.unfinished_tasks:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return False
                self._lines.all_tasks_done.wait(remaining)
        return True

    def _drain(self) -> None:
        while True:
            line = self._lines.get()
            try:
                logger.info(_FORMAT, *line)
            except Exception:
                pass
            finally:
                self._lines.task_done()


_shared_lock = threading.Lock()
_shared_writer: LogWriter | None = None


def shared_writer() -> LogWriter:
    """The one writer thread for this process, started on first use."""
    global _shared_writer
    with _shared_lock:
        if _shared_writer is None:
            _shared_writer = LogWriter()
            # Best effort: log samples still queued at a normal exit.
            atexit.register(_shared_writer.flush, EXIT_FLUSH_SECONDS)
        return _shared_writer


class MemoryObserver:
    """Samples memory at request phases; never raises and never blocks on logging."""

    def __init__(
        self,
        *,
        active: Counter,
        cache: Counter,
        peak: Counter,
        reset_peak: Callable[[], Any],
        footprint: Counter,
        estimate: Callable[[list[Any]], int],
        writer: LogWriter | None = None,
    ):
        self._active, self._cache, self._peak = active, cache, peak
        self._reset_peak, self._footprint, self._estimate = reset_peak, footprint, estimate
        self._writer = shared_writer() if writer is None else writer
        self._sequence = 0
        self._peak_valid = False
        # (copies, estimated bytes or None once an estimate fails), replaced whole.
        self._copy_totals: tuple[int, int | None] = (0, 0)

    def request_start(self, custody: Any, checkpoints: int) -> None:
        """Sample before submission, then start a new peak interval."""
        self._sequence += 1
        self._copy_totals = (0, 0)
        self._peak_valid = False
        self.phase("request_start", custody, checkpoints)
        try:
            self._reset_peak()
        except Exception:
            return
        self._peak_valid = True

    def copied(self, cache: list[Any]) -> None:
        copies, total = self._copy_totals
        try:
            size = int(self._estimate(cache))
        except Exception:
            size = -1
        if total is None or size < 0:
            self._copy_totals = (copies + 1, None)
        else:
            self._copy_totals = (copies + 1, total + size)

    def phase(self, name: str, custody: Any, checkpoints: int, stream: Any = None) -> None:
        try:
            copies, total = self._copy_totals
            widths = [int(w) for w in getattr(stream, "prefill_widths", None) or ()]
            raised = sum(1 for r in getattr(stream, "prefill_raised", None) or () if r)
            peak = _read(self._peak)
            line = (
                name,
                self._sequence,
                _read(self._active),
                _read(self._cache),
                peak if self._peak_valid or name == "request_start" else UNAVAILABLE,
                _read(self._footprint),
                int(custody.leases),
                int(custody.held_bytes),
                int(checkpoints),
                copies,
                UNAVAILABLE if total is None else str(total),
                max(widths, default=0),
                raised,
                self._writer.dropped,
            )
        except Exception:
            return
        try:
            self._writer.submit(line)
        except Exception:
            return


def _read(counter: Counter) -> str:
    try:
        value = counter()
    except Exception:
        return UNAVAILABLE
    return str(value) if type(value) is int and value >= 0 else UNAVAILABLE
