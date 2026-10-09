"""C1 raw-token TensorFold scheduler integration inside an owned Worker.

Native loading belongs to the admitted runtime. Supplied byte bounds and native
settlement callbacks require qualification for that exact model implementation;
the driver does not infer completion from HTTP, queue terminals, or cache size.
"""

import logging
import math
import queue
import time
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from functools import partial
from pathlib import Path
from threading import Event, RLock
from typing import Any

from orchard_tensorfold_http.cache_custody import (
    CacheCopyCustody,
    CacheCustodyError,
    CacheLease,
    CacheOwner,
)
from orchard_tensorfold_http.token_buffer import TokenChunkBuffer

logger = logging.getLogger(__name__)
_PACKAGE_DIR = str(Path(__file__).resolve().parent)


class DriverError(RuntimeError):
    """A bounded driver operation could not establish its required state."""


def _emit(log: Callable[[], None]) -> bool:
    """Diagnostics are best effort and never change request or custody outcomes."""
    try:
        log()
    except Exception:
        return False
    return True


def _failure_reason(exc: BaseException) -> str:
    """Name a copy failure; show messages only for fixed Orchard reasons."""
    name = type(exc).__name__
    if isinstance(exc, CacheCustodyError | DriverError) or (
        isinstance(exc, ValueError) and _raised_in_package(exc)
    ):
        return f"{name}: {exc}"
    return name


def _raised_in_package(exc: BaseException) -> bool:
    tb = exc.__traceback__
    if tb is None:
        return False
    while tb.tb_next is not None:
        tb = tb.tb_next
    return tb.tb_frame.f_code.co_filename.startswith(_PACKAGE_DIR)


@dataclass(frozen=True)
class DriverBounds:
    total_budget_bytes: int
    working_bytes: int
    workspace_bytes: int
    checkpoint_budget_bytes: int
    checkpoint_slots: int
    max_cache_leases: int
    max_cache_layers: int
    max_buffer_chunks: int
    max_buffer_tokens: int
    max_chunk_tokens: int
    vocabulary_size: int
    max_input_tokens: int
    max_output_tokens: int
    max_context_tokens: int
    poll_seconds: float
    request_seconds: float
    cancel_seconds: float
    settlement_seconds: float

    def __post_init__(self) -> None:
        for name, value in vars(self).items():
            if name.endswith("seconds"):
                if type(value) not in (int, float) or not math.isfinite(value) or value <= 0:
                    raise ValueError("driver time bounds must be finite and positive")
            elif type(value) is not int or value < (0 if name == "workspace_bytes" else 1):
                raise ValueError("driver capacity bounds must be bounded integers")
        if self.working_bytes + self.workspace_bytes > self.total_budget_bytes:
            raise ValueError("working reservation exceeds driver budget")


@dataclass(frozen=True)
class DriverCompletion:
    cached_tokens: int
    finish_reason: str
    output_tokens: int
    cancelled: bool


@dataclass
class _CacheRecord:
    lease: CacheLease[list[Any]]
    cache: list[Any]
    owners: set[CacheOwner]
    bound: int


class _LeasedCache(list):
    pass


class _CheckpointBridge:
    def __init__(self, inner: Any, driver: "TensorFoldDriver"):
        self._inner, self._driver = inner, driver

    def __getattr__(self, name: str) -> Any:
        return getattr(self._inner, name)

    def insert(self, tokens: list[int], cache: list[Any], **options: Any) -> None:
        self._driver._record(cache)
        self._inner.insert(tokens, cache, **options)
        if any(entry.cache is cache for entry in self._inner._entries):
            self._driver._own(cache, "retained")

    def match(self, prompt: list[int], usable: Any = None, *, take: bool = False) -> Any:
        result = self._inner.match(prompt, usable, take=take)
        if result is not None:
            self._driver._own(result[1], "borrowed")
        return result


class TensorFoldDriver:
    """Wire bounded custody and raw tokens into the pinned scheduler's seams."""

    def __init__(
        self,
        engine: Any,
        *,
        scheduler_factory: Callable[..., Any],
        job_factory: Callable[..., Any],
        checkpoint_factory: Callable[..., Any],
        cancellation_factory: Callable[[], Any],
        bounds: DriverBounds,
        copy_bounds: Callable[[list[Any]], tuple[int, int]],
        copy_settlement: Callable[[Any, list[Any]], bool],
        request_settlement: Callable[[Any], bool],
        on_quarantine: Callable[[], None],
        eos_ids: frozenset[int],
    ):
        self.engine, self.bounds = engine, bounds
        self._job_factory, self._cancellation_factory = job_factory, cancellation_factory
        self._copy_bounds, self._copy_settlement = copy_bounds, copy_settlement
        self._request_settlement, self._on_quarantine = request_settlement, on_quarantine
        self._lock = RLock()
        self._started = self._quarantined = self._retired = False
        self._closing = self._normal_closed = self._normal_stop_expected = False
        self._active: Any = None
        self._cancel_requested = False
        self._completion: DriverCompletion | None = None
        self._records: dict[int, _CacheRecord] = {}
        self._custody = CacheCopyCustody[list[Any]](
            total_budget_bytes=bounds.total_budget_bytes,
            workspace_bytes=bounds.working_bytes + bounds.workspace_bytes,
            max_leases=bounds.max_cache_leases,
        )
        self._original_copy = engine.copy_single_cache
        engine.copy_single_cache = lambda cache: self._copy(cache, "staged")
        engine.retain_finished_caches = False
        inner = checkpoint_factory(
            bounds.checkpoint_slots,
            copier=lambda cache: self._copy(cache, "borrowed"),
            budget_bytes=bounds.checkpoint_budget_bytes,
            sizer=lambda cache: self._record(cache).bound,
            pinned_slots=0,
            on_evict=None,
        )
        inner.admit_oversize = False
        self.checkpoints = _CheckpointBridge(inner, self)
        self.scheduler = scheduler_factory(
            engine,
            lanes=1,
            eos_ids=eos_ids,
            checkpoints=self.checkpoints,
            proposer_factory=None,
            snapshot_dir=None,
            session_dir=None,
            prompt_memory=None,
            admission=None,
            decode_share=0,
        )
        self.scheduler.on_stop = self._scheduler_stopped

    @classmethod
    def from_tensorfold(cls, engine: Any, **options: Any) -> "TensorFoldDriver":
        """Bind real factories only after the runtime admits its native model."""
        from tensorfold.server.cancellation import Cancellation
        from tensorfold.server.checkpoints import CheckpointStore
        from tensorfold.server.scheduler import ChatJob, Scheduler

        return cls(
            engine,
            scheduler_factory=Scheduler,
            job_factory=ChatJob,
            checkpoint_factory=CheckpointStore,
            cancellation_factory=Cancellation,
            **options,
        )

    @property
    def quarantined(self) -> bool:
        with self._lock:
            return self._quarantined

    @property
    def retired(self) -> bool:
        with self._lock:
            return self._retired

    @property
    def normal_closed(self) -> bool:
        with self._lock:
            return self._normal_closed

    @property
    def settled(self) -> bool:
        with self._lock:
            return (
                self._active is None
                and not self._quarantined
                and not self._retired
                and not self._closing
            )

    @property
    def completion(self) -> DriverCompletion | None:
        with self._lock:
            return self._completion

    def _available(self, *, allow_closing: bool = False) -> None:
        if self._quarantined or self._retired or (self._closing and not allow_closing):
            raise DriverError("driver incarnation is unavailable")

    def _quarantine(self) -> None:
        with self._lock:
            if self._retired:
                return
            notify = not self._quarantined
            self._quarantined = True
        if notify:
            self._on_quarantine()

    def quarantine(self) -> None:
        """Reject reuse immediately; an independent runtime timer may call this."""
        self._quarantine()

    def _scheduler_stopped(self) -> None:
        with self._lock:
            expected = self._normal_stop_expected
        if not expected:
            self._quarantine()

    def _buffer_failure(self) -> None:
        self._quarantine()
        self.cancel()

    def _record(self, cache: list[Any]) -> _CacheRecord:
        record = self._records.get(id(cache))
        if record is None or record.cache is not cache:
            raise DriverError("cache lacks owned copy custody")
        return record

    def _own(self, cache: list[Any], owner: CacheOwner) -> None:
        record = self._record(cache)
        if owner not in record.owners:
            record.lease.retain(owner)
            record.owners.add(owner)

    def _copy(self, cache: list[Any], owner: CacheOwner) -> list[Any]:
        size = transient = 0
        try:
            with self._lock:
                self._available(allow_closing=True)
            if not isinstance(cache, list) or len(cache) > self.bounds.max_cache_layers:
                raise DriverError("cache implementation is unsupported")
            size, transient = self._copy_bounds(cache)

            def barrier(value: list[Any]) -> bool:
                if type(value) is not list or len(value) > self.bounds.max_cache_layers:
                    raise DriverError("copied cache implementation is unsupported")
                return self._copy_settlement(self.engine, value)

            lease = self._custody.copy(
                lambda: self._original_copy(cache),
                barrier,
                cache_bytes=size,
                transient_bytes=transient,
                owner=owner,
            )
            wrapped = _LeasedCache(lease.value)
            with self._lock:
                self._available(allow_closing=True)
                self._records[id(wrapped)] = _CacheRecord(lease, wrapped, {owner}, size)
            return wrapped
        except BaseException as exc:
            try:
                if not _emit(partial(self._log_copy_failure, exc, size, transient)):
                    _emit(
                        lambda: logger.warning(
                            "tensorfold cache copy custody failed reason=unavailable"
                        )
                    )
            finally:
                self._quarantine()
            raise DriverError("cache copy custody failed") from None

    @staticmethod
    def _log_start(job: Any, prompt_tokens: int, retained: int) -> None:
        cached = job.cached_tokens
        if type(cached) is not int or not 0 <= cached <= prompt_tokens:
            cached = -1
        logger.info(
            "tensorfold request started cached=%d prompt=%d checkpoints=%d",
            cached,
            prompt_tokens,
            retained,
        )

    def _log_copy_failure(self, exc: BaseException, size: Any, transient: Any) -> None:
        # Only fixed Orchard reasons and byte counts; never request content.
        snapshot = self._custody.snapshot()
        logger.warning(
            "tensorfold cache copy custody failed reason=%s requested=%s+%s total_budget=%d "
            "workspace_reserved=%d working=%d held=%d leases=%d max_leases=%d pending=%d+%d "
            "available=%d checkpoints=%d quarantined=%s",
            _failure_reason(exc),
            size if type(size) is int else "invalid",
            transient if type(transient) is int else "invalid",
            self.bounds.total_budget_bytes,
            snapshot.workspace_bytes,
            self.bounds.working_bytes,
            snapshot.held_bytes,
            snapshot.leases,
            self.bounds.max_cache_leases,
            snapshot.copy_bytes,
            snapshot.transient_bytes,
            snapshot.available_bytes,
            len(self.checkpoints._entries),
            snapshot.quarantined,
        )

    def start(self) -> None:
        with self._lock:
            self._available()
            if self._started:
                return
            self._started = True
        try:
            self.scheduler.start()
        except BaseException:
            self._quarantine()
            raise DriverError("scheduler startup failed") from None

    def cancel(self) -> None:
        with self._lock:
            job = self._active
            if job is None or self._cancel_requested:
                return
            self._cancel_requested = True
        try:
            self.scheduler.cancel(job.cancellation)
        except BaseException:
            self._quarantine()
            raise DriverError("scheduler cancellation failed") from None

    def _validate(
        self,
        prompt: list[int],
        history: int,
        maximum: int,
        temperature: float,
        boundaries: tuple[int, ...],
    ) -> int:
        b = self.bounds
        if type(prompt) is not list or not 0 < len(prompt) <= b.max_input_tokens:
            raise ValueError("prompt exceeds admitted token bounds")
        size = len(prompt)
        try:
            for index in range(size):
                token = prompt[index]
                if type(token) is not int or not 0 <= token < b.vocabulary_size:
                    raise ValueError("prompt token domain is unsupported")
        except IndexError:
            raise ValueError("prompt changed during admission") from None
        if len(prompt) != size:
            raise ValueError("prompt changed during admission")
        if type(history) is not int or not 0 <= history < len(prompt):
            raise ValueError("history boundary is unsupported")
        if type(maximum) is not int or not 0 < maximum <= b.max_output_tokens:
            raise ValueError("output exceeds admitted token bounds")
        if len(prompt) + maximum > b.max_context_tokens:
            raise ValueError("request exceeds admitted context bound")
        if (
            type(temperature) not in (int, float)
            or not math.isfinite(temperature)
            or temperature < 0
        ):
            raise ValueError("sampling temperature is unsupported")
        if type(boundaries) is not tuple or len(boundaries) > b.checkpoint_slots:
            raise ValueError("checkpoint boundaries exceed admitted bounds")
        if any(type(n) is not int or not 0 < n < len(prompt) for n in boundaries):
            raise ValueError("checkpoint boundary is unsupported")
        return size

    def _settle(self, job: Any) -> None:
        def finish(engine: Any) -> bool:
            if (
                not job.done.is_set()
                or self.scheduler.active
                or self.scheduler.waiting
                or self.scheduler.filling
                or engine.active_count
                or engine.finished_caches
                or engine.streams
                or getattr(engine, "_live", ())
            ):
                return False
            if self._request_settlement(engine) is not True:
                return False
            with self._lock:
                self._available()
                retained = {id(entry.cache) for entry in self.checkpoints._entries}
                if any(cache_id not in self._records for cache_id in retained):
                    raise DriverError("retained cache lacks owned custody")
                if job.stream is not None:
                    job.stream.history_checkpoints = []
                for cache_id, record in list(self._records.items()):
                    desired = {"retained"} if cache_id in retained else set()
                    for owner in record.owners - desired:
                        record.lease.dispose(owner)
                    record.owners.intersection_update(desired)
                    if not desired:
                        del self._records[cache_id]
            return True

        if self.scheduler.on_engine(finish, timeout=self.bounds.settlement_seconds) is not True:
            raise DriverError("native request settlement was not confirmed")

    def generate(
        self,
        prompt_ids: list[int],
        history_len: int,
        max_tokens: int,
        temperature: float,
        sampling: Any,
        *,
        cancel_event: Event | None = None,
        deadline_monotonic: float | None = None,
        checkpoint_boundaries: tuple[int, ...] = (),
    ) -> Iterator[list[int]]:
        """Yield raw markers too; only a native barrier establishes idle reuse."""
        size = self._validate(
            prompt_ids, history_len, max_tokens, temperature, checkpoint_boundaries
        )
        try:
            frozen_prompt = [prompt_ids[index] for index in range(size)]
        except IndexError:
            raise ValueError("prompt changed during admission") from None
        if len(prompt_ids) != size:
            raise ValueError("prompt changed during admission")
        self._validate(frozen_prompt, history_len, max_tokens, temperature, checkpoint_boundaries)
        prompt_ids = frozen_prompt
        if deadline_monotonic is not None and (
            type(deadline_monotonic) not in (int, float) or not math.isfinite(deadline_monotonic)
        ):
            raise ValueError("request deadline must be finite")
        deadline = min(
            time.monotonic() + self.bounds.request_seconds,
            math.inf if deadline_monotonic is None else deadline_monotonic,
        )
        if deadline <= time.monotonic():
            raise ValueError("request deadline expired before admission")
        with self._lock:
            self._available()
            if not self._started or self._active is not None:
                raise DriverError("driver is not ready for C1 admission")
            self._completion = None
            self._cancel_requested = False
            chunks = TokenChunkBuffer(
                max_chunks=self.bounds.max_buffer_chunks,
                max_buffered_tokens=self.bounds.max_buffer_tokens,
                max_chunk_tokens=self.bounds.max_chunk_tokens,
                vocabulary_size=self.bounds.vocabulary_size,
                on_failure=self._buffer_failure,
            )
            job = self._job_factory(
                job_id=f"owned-{time.monotonic_ns()}",
                prompt_ids=prompt_ids,
                max_tokens=max_tokens,
                temperature=temperature,
                history_len=history_len,
                shared_prefix_lens=checkpoint_boundaries,
                drafts=False,
                proposer=None,
                sampling=sampling,
                background=False,
                chunks=chunks,
                cancellation=self._cancellation_factory(),
            )
            self._active = job
            retained_checkpoints = len(self.checkpoints._entries)
        output = 0
        completed = False
        cancelling = False
        try:
            self.scheduler.submit(job)
            while True:
                with self._lock:
                    self._available()
                if cancel_event is not None and cancel_event.is_set():
                    self.cancel()
                if self._cancel_requested and not cancelling:
                    cancelling = True
                    deadline = min(deadline, time.monotonic() + self.bounds.cancel_seconds)
                left = deadline - time.monotonic()
                if left <= 0 or not self.scheduler._thread.is_alive():
                    raise DriverError("scheduler did not establish bounded completion")
                try:
                    chunk = chunks.get(timeout=min(self.bounds.poll_seconds, left))
                except queue.Empty:
                    continue
                if chunk is None:
                    break
                if output == 0:
                    _emit(lambda: self._log_start(job, len(prompt_ids), retained_checkpoints))
                output += len(chunk)
                if output > max_tokens:
                    raise DriverError("scheduler exceeded admitted output bound")
                if cancel_event is not None and cancel_event.is_set():
                    self.cancel()
                if self._cancel_requested and not cancelling:
                    cancelling = True
                    deadline = min(deadline, time.monotonic() + self.bounds.cancel_seconds)
                if not cancelling:
                    yield chunk
            self._settle(job)
            cached = job.cached_tokens
            if type(cached) is not int or not 0 <= cached <= len(prompt_ids):
                raise DriverError("scheduler cache metadata is unsupported")
            reason = "cancelled" if cancelling else getattr(job.stream, "finish_reason", "stop")
            if reason not in {"stop", "length", "tool_calls", "cancelled"}:
                raise DriverError("scheduler finish metadata is unsupported")
            with self._lock:
                self._available()
                if job.error is None or cancelling:
                    self._completion = DriverCompletion(cached, reason, output, cancelling)
                self._active = None
            completed = True
            if job.error is not None and not cancelling:
                raise DriverError("scheduler request failed after native settlement")
        finally:
            if not completed:
                with self._lock:
                    closing = self._closing or self._normal_closed
                if not closing:
                    self._quarantine()
                    self.cancel()

    def shutdown(self, timeout: float | None = None) -> None:
        """Close under a native barrier and prove both scheduler threads stopped.

        This retires the model driver, not its containing owned OS process.
        Cache leases survive any uncertain stop until positive owned reaping.
        """
        duration = (
            self.bounds.cancel_seconds + self.bounds.settlement_seconds
            if timeout is None
            else timeout
        )
        if type(duration) not in (int, float) or not math.isfinite(duration) or duration <= 0:
            raise ValueError("shutdown timeout must be finite and positive")
        deadline = time.monotonic() + duration
        with self._lock:
            if self._normal_closed:
                return
            self._available()
            if not self._started:
                raise DriverError("scheduler has not started")
            self._closing = True
            job = self._active

        def remaining() -> float:
            left = deadline - time.monotonic()
            if left <= 0:
                raise DriverError("normal shutdown deadline expired")
            return left

        def release_references(engine: Any) -> bool:
            if (
                (job is not None and not job.done.is_set())
                or self.scheduler.active
                or self.scheduler.waiting
                or self.scheduler.filling
                or engine.active_count
                or engine.finished_caches
                or engine.streams
                or getattr(engine, "_live", ())
            ):
                return False
            if self._request_settlement(engine) is not True:
                return False
            with self._lock:
                self._available(allow_closing=True)
                if any(id(entry.cache) not in self._records for entry in self.checkpoints._entries):
                    raise DriverError("retained cache lacks owned custody")
                with self.checkpoints._inner._lock:
                    self.checkpoints._inner._entries.clear()
                if job is not None and job.stream is not None:
                    job.stream.history_checkpoints.clear()
                    job.stream = None
                engine.release_rounds()
            return True

        try:
            self.cancel()
            if self.scheduler.on_engine(release_references, timeout=remaining()) is not True:
                raise DriverError("shutdown native settlement was not confirmed")
            with self._lock:
                self._available(allow_closing=True)
                self._normal_stop_expected = True
            self.scheduler.stop(timeout=remaining())
            for thread in (self.scheduler._thread, self.scheduler._watchdog):
                thread.join(timeout=remaining())
                if thread.is_alive():
                    raise DriverError("scheduler thread termination was not confirmed")
            with self._lock:
                self._available(allow_closing=True)
                for record in self._records.values():
                    for owner in tuple(record.owners):
                        record.lease.dispose(owner)
                    record.owners.clear()
                    record.cache.clear()
                self._records.clear()
                self._active = None
                self.engine.copy_single_cache = self._original_copy
                self._original_copy = None
                self.engine = self.scheduler.engine = None
                self._normal_closed = self._retired = True
                self._closing = False
        except BaseException:
            self._quarantine()
            raise DriverError("normal shutdown remained uncertain") from None

    def positive_owned_reap(self, proof: Callable[[], bool]) -> None:
        """Retire this incarnation after positive owned process-tree reaping."""
        self._quarantine()
        self._custody.positive_owned_reap(proof)
        with self._lock:
            self._retired = True
            self._active = None
            self._records.clear()
