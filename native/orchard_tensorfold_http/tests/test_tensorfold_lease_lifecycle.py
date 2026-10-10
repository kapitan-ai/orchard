"""Cache-lease lifecycle under the pinned scheduler's real copy order.

The fake scheduler mirrors one request under TensorFold 0.6.6 (cb2ebf05) as
Orchard configures it:

- ``prompt_fill._start_fill`` matches a stored prefix at a chunk start with
  ``take=False`` (no prompt memory), so the store copies the entry. It picks
  boundaries with ``checkpoints.choose_checkpoints``, floors them to chunk
  starts and unions them with the floored explicit boundaries.
- ``engine/family_prefill`` copies the working cache at each boundary into
  ``history_checkpoints``. A prefill stopped between chunks also copies its
  progress when that chunk start is not already kept.
- ``prompt_fill._end_fill`` inserts those copies into the LRU
  ``CheckpointStore`` before decode, on success and on cancellation.
- No finished-cache copy: the engine keeps a decoded cache only without a
  prefill plan and with ``retain_finished_caches``. Orchard sets a prefill
  plan and disables finished-cache retention.

Sizes are synthetic accounting units.
"""

from threading import Event
from types import SimpleNamespace

import pytest

from orchard_tensorfold_http.tensorfold_driver import (
    DriverBounds,
    DriverError,
    TensorFoldDriver,
    required_cache_leases,
)

STEP = 2


def choose_checkpoints(history_len, cached, last_prompt, prompt):
    # checkpoints.py:27-37 at cb2ebf05.
    candidates = {int(history_len)}
    if last_prompt:
        stable = 0
        for a, b in zip(last_prompt, prompt, strict=False):
            if a != b:
                break
            stable += 1
        if 0 < stable < int(history_len) and stable >= int(history_len) // 2:
            candidates.add(stable)
    return sorted(at for at in candidates if int(cached) < at < len(prompt))


class Starts:
    """PromptChunks on a fixed step grid (prefill_plan.py:85-98)."""

    def __init__(self, length):
        self.length = length

    def __contains__(self, n):
        return 0 < n < self.length and n % STEP == 0

    def floor(self, n):
        n = max(0, min(int(n), self.length))
        return n - n % STEP


class RequestCancelled(Exception):
    pass


class Cancellation:
    cancelled = False

    def cancel(self):
        self.cancelled = True

    def check(self):
        if self.cancelled:
            raise RequestCancelled


class Engine:
    def __init__(self):
        self.active_count = 0
        self.finished_caches = {}
        self.streams = []

    def copy_single_cache(self, cache):
        return [dict(layer) for layer in cache]

    def release_rounds(self):
        pass


class Store:
    """CheckpointStore insert/match/evict semantics (checkpoints.py:121-296)."""

    def __init__(self, slots, **options):
        self.slots = slots
        self.copier, self.sizer = options["copier"], options["sizer"]
        self.budget_bytes = options["budget_bytes"]
        self.admit_oversize = False
        self._entries = []

    def _best(self, prompt, usable):
        best = None
        for entry in self._entries:
            tokens = entry.tokens
            if 0 < len(tokens) < len(prompt) and prompt[: len(tokens)] == tokens:
                if usable(len(tokens)) and (best is None or len(tokens) > len(best.tokens)):
                    best = entry
        return best

    def match(self, prompt, usable=None, *, take=False):
        assert take is False
        best = self._best(prompt, usable or (lambda n: True))
        if best is None:
            return None
        self._entries.remove(best)
        previous = list(best.last_prompt)
        self._entries.insert(0, best)
        best.last_prompt = list(prompt)
        return len(best.tokens), self.copier(best.cache), previous

    def insert(self, tokens, cache, *, last_prompt, pinned=False):
        if not tokens:
            return
        nbytes = self.sizer(cache)
        if nbytes > self.budget_bytes:
            return
        kept = [entry for entry in self._entries if entry.tokens != list(tokens)]
        entry = SimpleNamespace(
            tokens=list(tokens),
            cache=cache,
            last_prompt=list(last_prompt),
            nbytes=nbytes,
            born=len(last_prompt),
        )
        entries = [entry, *kept]
        while len(entries) > self.slots or (
            len(entries) > 1 and sum(e.nbytes for e in entries) > self.budget_bytes
        ):
            entries.pop(self._victim(entries))
        self._entries = entries

    @staticmethod
    def _victim(entries):
        candidates = list(range(1, len(entries)))
        for i in reversed(candidates):
            entry = entries[i]
            if any(
                other.born > entry.born and other.tokens[: len(entry.tokens)] == entry.tokens
                for other in entries
            ):
                return i
        return candidates[-1]


class Scheduler:
    def __init__(self, engine, **options):
        self.engine = engine
        self.checkpoints = options["checkpoints"]
        self.active = self.waiting = 0
        self.filling = []
        self._thread = SimpleNamespace(is_alive=lambda: True, join=lambda timeout: None)
        self._watchdog = SimpleNamespace(is_alive=lambda: True, join=lambda timeout: None)
        self.peak_leases = 0
        self.leases = None
        self.cancel_after = None
        self.borrowed = None
        self.on_cancel_point = None

    def start(self):
        pass

    def stop(self, *, timeout):
        self.on_stop()

    def cancel(self, cancellation):
        cancellation.cancel()

    def on_engine(self, operation, *, timeout):
        return operation(self.engine)

    def _observe(self):
        self.peak_leases = max(self.peak_leases, self.leases())

    def _copy(self, work):
        snapshot = self.engine.copy_single_cache(work)
        self._observe()
        return snapshot

    def _feed(self, job, work, begin, end, whole):
        # family_prefill.py:60-104: the guard checks cancellation before each chunk.
        for at in range(begin, end, STEP):
            if at == self.cancel_after:
                self.on_cancel_point()
            job.cancellation.check()
            whole[0] = min(at + STEP, end)

    def _prefill(self, job, starts, work, cached, checkpoints_at):
        # family_prefill.py:170-197.
        prompt = job.prompt_ids
        start, whole = cached, [cached]
        try:
            for boundary in sorted({starts.floor(b) for b in checkpoints_at}):
                if not start < boundary < len(prompt):
                    continue
                self._feed(job, work, start, boundary, whole)
                job.stream.history_checkpoints.append((list(prompt[:boundary]), self._copy(work)))
                start = boundary
            self._feed(job, work, start, len(prompt), whole)
        except BaseException:
            at = whole[0]
            kept = [len(tokens) for tokens, _ in job.stream.history_checkpoints]
            if at in starts and at not in kept:
                job.stream.history_checkpoints.append((list(prompt[:at]), self._copy(work)))
            raise

    def _keep_checkpoints(self, job):
        kept, job.stream.history_checkpoints = job.stream.history_checkpoints, []
        for tokens, snapshot in kept:
            self.checkpoints.insert(tokens, snapshot, last_prompt=job.prompt_ids)

    def submit(self, job):
        # prompt_fill.py:57-99 and 197-226, run inline.
        job.stream = SimpleNamespace(finish_reason="stop", history_checkpoints=[])
        self.active = self.engine.active_count = 1
        prompt = job.prompt_ids
        starts = Starts(len(prompt))
        shared_at = {starts.floor(n) for n in job.shared_prefix_lens} - {0}
        hit = self.checkpoints.match(prompt, usable=lambda n: n in starts, take=False)
        self._observe()
        cached, work, last = (0, [{"bytes": 1}], None) if hit is None else hit
        self.borrowed = cached
        chosen = choose_checkpoints(job.history_len, cached, last, prompt)
        checkpoints_at = sorted(
            at
            for at in {*(starts.floor(n) for n in chosen), *shared_at}
            if cached < at < len(prompt)
        )
        try:
            self._prefill(job, starts, work, cached, checkpoints_at)
            self._keep_checkpoints(job)
            job.cached_tokens = cached
            job.chunks.put([6, 7])
        except RequestCancelled:
            self._keep_checkpoints(job)
        except Exception as exc:
            job.error = exc
            self._keep_checkpoints(job)
        job.chunks.put(None)
        self.active = self.engine.active_count = 0
        job.done.set()


def job_factory(**values):
    return SimpleNamespace(done=Event(), error=None, stream=None, cached_tokens=0, **values)


def make_driver(max_cache_leases):
    # B2 ratios: 12 working, 16 workspace, 24 checkpoint budget, 2 slots.
    bounds = DriverBounds(
        total_budget_bytes=12 * (max_cache_leases + 1) + 28,
        working_bytes=12,
        workspace_bytes=16,
        checkpoint_budget_bytes=24,
        checkpoint_slots=2,
        max_cache_leases=max_cache_leases,
        max_cache_layers=2,
        max_buffer_chunks=4,
        max_buffer_tokens=8,
        max_chunk_tokens=4,
        vocabulary_size=50,
        max_input_tokens=400,
        max_output_tokens=4,
        max_context_tokens=404,
        poll_seconds=0.001,
        request_seconds=1.0,
        cancel_seconds=0.05,
        settlement_seconds=0.05,
    )
    driver = TensorFoldDriver(
        Engine(),
        scheduler_factory=Scheduler,
        job_factory=job_factory,
        checkpoint_factory=Store,
        cancellation_factory=Cancellation,
        bounds=bounds,
        copy_bounds=lambda cache: (12, 12),
        copy_settlement=lambda engine, cache: True,
        request_settlement=lambda engine: True,
        on_quarantine=lambda: None,
        eos_ids=frozenset({19}),
    )
    driver.scheduler.leases = lambda: driver._custody.snapshot().leases
    driver.start()
    return driver


def coding_session(turns):
    """Title, then a primary request whose history grows by a reply and a tool result per turn."""
    title = [30, 31, 32]
    system = [1, 2, 3, 4, 5]
    prompt = [*system, 8, 9]
    yield title, 2
    for turn in range(turns):
        yield list(prompt), len(prompt) - 2
        prompt = [*prompt, 6, 7, 10 + turn % 30, 11, 12]


def run_session(driver, turns):
    leases_after, peaks = [], []
    for prompt, history in coding_session(turns):
        driver.scheduler.peak_leases = 0
        # backend.py sends exactly the history boundary.
        list(
            driver.generate(
                prompt, history, 4, 1.0, sampling=None, checkpoint_boundaries=(history,)
            )
        )
        leases_after.append((driver._custody.snapshot().leases, len(driver.checkpoints._entries)))
        peaks.append(driver.scheduler.peak_leases)
    return leases_after, peaks


def test_settled_leases_match_retained_checkpoints_over_a_long_session():
    driver = make_driver(required_cache_leases(2))
    leases_after, peaks = run_session(driver, 12)
    # No lease survives settlement unless a retained checkpoint still owns it.
    assert all(leases == retained for leases, retained in leases_after)
    assert max(retained for _, retained in leases_after) == driver.bounds.checkpoint_slots
    # A completed request never needs the interrupted-prefill lease.
    assert max(peaks) == required_cache_leases(2) - 1
    assert driver.settled and not driver.quarantined


def test_four_leases_refuse_a_continuation_that_needs_a_second_boundary_snapshot(caplog):
    # Run B2: two retained checkpoints, a borrowed prefix copy and the stable-prefix
    # snapshot fill four leases, so the history-boundary snapshot is refused.
    caplog.set_level("WARNING", logger="orchard_tensorfold_http.tensorfold_driver")
    driver = make_driver(4)
    with pytest.raises(DriverError):
        run_session(driver, 3)
    message = next(
        r.getMessage() for r in caplog.records if "cache copy custody failed" in r.getMessage()
    )
    assert "reason=CacheCustodyError: cache lease limit exceeded" in message
    assert "leases=4 max_leases=4" in message
    assert "checkpoints=2" in message
    assert driver.quarantined


FIRST = list(range(1, 11))
OTHER = [40, 41, 42, 43, 44, 45]
# Shares FIRST[:8], so the stable prefix (8) and the history boundary (12) are
# both new cuts past the reused prefix at 4.
CONTINUATION = [*FIRST[:8], 20, 21, 22, 23, 24, 25, 26, 27]


def worst_case_request(driver, *, cancel_after=None):
    """Two retained checkpoints, then a hit with a stable prefix and a history boundary."""
    list(driver.generate(FIRST, 4, 4, 1.0, sampling=None, checkpoint_boundaries=(4,)))
    list(driver.generate(OTHER, 2, 4, 1.0, sampling=None, checkpoint_boundaries=(2,)))
    assert len(driver.checkpoints._entries) == 2
    driver.scheduler.peak_leases = 0
    driver.scheduler.cancel_after = cancel_after
    driver.scheduler.on_cancel_point = driver.cancel
    list(driver.generate(CONTINUATION, 12, 4, 1.0, sampling=None, checkpoint_boundaries=(12,)))
    assert driver.scheduler.borrowed == 4
    return driver.scheduler.peak_leases


def test_completed_worst_case_request_needs_one_lease_below_the_bound():
    driver = make_driver(required_cache_leases(2))
    assert worst_case_request(driver) == required_cache_leases(2) - 1
    assert driver.completion.finish_reason == "stop"
    assert driver.completion.cached_tokens == 4
    assert driver._custody.snapshot().leases == len(driver.checkpoints._entries)


def test_prefill_cancelled_after_its_last_boundary_reaches_exactly_the_bound():
    driver = make_driver(required_cache_leases(2))
    # Cancelled before the chunk at 14: the progress at 14 is a new copy.
    assert worst_case_request(driver, cancel_after=14) == required_cache_leases(2)
    assert driver.completion.finish_reason == "cancelled"
    assert driver.completion.cached_tokens == 0
    assert driver._custody.snapshot().leases == len(driver.checkpoints._entries)
    assert driver.settled and not driver.quarantined


def test_prefill_cancelled_at_a_kept_boundary_takes_no_progress_copy():
    driver = make_driver(required_cache_leases(2))
    # Cancelled before the chunk at 12, which the history snapshot already holds.
    assert worst_case_request(driver, cancel_after=12) == required_cache_leases(2) - 1
    assert driver.completion.finish_reason == "cancelled"


def test_cold_prefill_cancelled_before_its_first_chunk_takes_no_copy():
    driver = make_driver(required_cache_leases(2))
    driver.scheduler.peak_leases = 0
    driver.scheduler.cancel_after = 0
    driver.scheduler.on_cancel_point = driver.cancel
    list(driver.generate(FIRST, 8, 4, 1.0, sampling=None, checkpoint_boundaries=(8,)))
    assert driver.scheduler.peak_leases == 0
    assert driver.completion.finish_reason == "cancelled"
    assert driver._custody.snapshot().leases == len(driver.checkpoints._entries) == 0


def test_one_lease_below_the_bound_refuses_the_cancelled_worst_case():
    driver = make_driver(required_cache_leases(2) - 1)
    with pytest.raises(DriverError):
        worst_case_request(driver, cancel_after=14)
    assert driver.quarantined


def test_explicit_boundary_that_floors_to_the_history_cut_adds_no_snapshot():
    driver = make_driver(required_cache_leases(2))
    driver.scheduler.peak_leases = 0
    # 13 floors to 12, the history cut, on the chunk grid.
    list(driver.generate(CONTINUATION, 12, 4, 1.0, sampling=None, checkpoint_boundaries=(12,)))
    plain = driver.scheduler.peak_leases
    driver = make_driver(required_cache_leases(2, 1))
    driver.scheduler.peak_leases = 0
    list(driver.generate(CONTINUATION, 12, 4, 1.0, sampling=None, checkpoint_boundaries=(12, 13)))
    assert driver.scheduler.peak_leases == plain


def test_extra_explicit_boundary_is_refused_at_admission_without_lease_room():
    driver = make_driver(required_cache_leases(2))
    with pytest.raises(ValueError, match="exceed the cache lease bound"):
        list(
            driver.generate(CONTINUATION, 12, 4, 1.0, sampling=None, checkpoint_boundaries=(12, 6))
        )
    assert not driver.quarantined
    driver = make_driver(required_cache_leases(2, 1))
    list(driver.generate(CONTINUATION, 12, 4, 1.0, sampling=None, checkpoint_boundaries=(12, 6)))
    assert driver._custody.snapshot().leases == len(driver.checkpoints._entries)
