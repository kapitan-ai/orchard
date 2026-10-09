"""Cache-lease lifecycle under the pinned scheduler's real copy order.

The fake scheduler mirrors TensorFold 0.6.6 (cb2ebf05) for one request:
``prompt_fill._start_fill`` matches a stored prefix (a borrowed copy) and picks
history and stable-prefix boundaries with ``checkpoints.choose_checkpoints``;
``engine/family_prefill`` copies the working cache at each boundary into
``history_checkpoints``; ``engine/lane_family`` copies the finished cache; and
``scheduler._retire`` and ``_keep_checkpoints`` insert those copies into the
LRU ``CheckpointStore``. Sizes are synthetic accounting units.
"""

from threading import Event
from types import SimpleNamespace

import pytest

from orchard_tensorfold_http.native_factory import required_cache_leases
from orchard_tensorfold_http.tensorfold_driver import DriverBounds, DriverError, TensorFoldDriver


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


class Cancellation:
    cancelled = False

    def cancel(self):
        self.cancelled = True


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

    def _best(self, prompt):
        best = None
        for entry in self._entries:
            tokens = entry.tokens
            if 0 < len(tokens) < len(prompt) and prompt[: len(tokens)] == tokens:
                if best is None or len(tokens) > len(best.tokens):
                    best = entry
        return best

    def match(self, prompt, usable=None, *, take=False):
        best = self._best(prompt)
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

    def submit(self, job):
        job.stream = SimpleNamespace(finish_reason="stop", history_checkpoints=[])
        self.active = self.engine.active_count = 1
        prompt = job.prompt_ids
        hit = self.checkpoints.match(prompt)
        self._observe()
        cached, work, last = (0, [{"bytes": 1}], None) if hit is None else hit
        job.cached_tokens = cached
        boundaries = {*choose_checkpoints(job.history_len, cached, last, prompt)}
        boundaries |= {at for at in job.shared_prefix_lens if cached < at < len(prompt)}
        for at in sorted(boundaries):
            job.stream.history_checkpoints.append(
                (list(prompt[:at]), self.engine.copy_single_cache(work))
            )
            self._observe()
        reply = [6, 7]
        job.chunks.put(reply)
        finished = (list(prompt) + reply, self.engine.copy_single_cache(work))
        self._observe()
        if len(finished[0]) > len(prompt):
            self.checkpoints.insert(finished[0], finished[1], last_prompt=prompt)
        kept, job.stream.history_checkpoints = job.stream.history_checkpoints, []
        for tokens, snapshot in kept:
            self.checkpoints.insert(tokens, snapshot, last_prompt=prompt)
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
    return driver


def coding_session(turns):
    """Title, then a primary request whose history grows by a reply and a tool result per turn."""
    title = [30, 31, 32]
    system = [1, 2, 3, 4, 5]
    prompt = [*system, 8, 9]
    yield title, 2, ()
    for turn in range(turns):
        yield list(prompt), len(prompt) - 2, (len(system),)
        prompt = [*prompt, 6, 7, 10 + turn % 30, 11, 12]


def run_session(driver, turns):
    driver.start()
    leases_after, peaks = [], []
    for prompt, history, boundaries in coding_session(turns):
        driver.scheduler.peak_leases = 0
        list(
            driver.generate(
                prompt, history, 4, 1.0, sampling=None, checkpoint_boundaries=boundaries
            )
        )
        leases_after.append(driver._custody.snapshot().leases)
        peaks.append(driver.scheduler.peak_leases)
    return leases_after, peaks


def test_settled_leases_match_retained_checkpoints_over_a_long_session():
    driver = make_driver(required_cache_leases(2))
    leases_after, peaks = run_session(driver, 12)
    # No lease survives settlement unless a retained checkpoint still owns it.
    assert leases_after == [len(driver.checkpoints._entries)] * len(leases_after)
    assert max(leases_after) <= driver.bounds.checkpoint_slots
    assert max(peaks) < driver.bounds.max_cache_leases
    assert driver.settled and not driver.quarantined


def test_four_leases_refuse_a_continuation_that_needs_a_boundary_snapshot(caplog):
    # Run B2: two retained checkpoints, a borrowed prefix copy and one boundary
    # snapshot fill four leases, so the finished-cache copy is refused.
    caplog.set_level("WARNING", logger="orchard_tensorfold_http.tensorfold_driver")
    driver = make_driver(4)
    with pytest.raises(DriverError, match="^cache copy custody failed$"):
        run_session(driver, 3)
    message = next(
        r.getMessage() for r in caplog.records if "cache copy custody failed" in r.getMessage()
    )
    assert "reason=CacheCustodyError: cache lease limit exceeded" in message
    assert "leases=4 max_leases=4" in message
    assert "checkpoints=2" in message


def worst_case_request(driver):
    """Two retained checkpoints, then a hit with history, stable and two explicit boundaries."""
    first = list(range(1, 11))
    list(driver.generate(first, 8, 4, 1.0, sampling=None))
    assert len(driver.checkpoints._entries) == 2
    second = [*first[:9], 20, 21, 22, 23, 24, 25, 26]
    driver.scheduler.peak_leases = 0
    list(driver.generate(second, 12, 4, 1.0, sampling=None, checkpoint_boundaries=(10, 11)))
    return driver.scheduler.peak_leases


def test_worst_case_request_reaches_exactly_the_required_lease_count():
    driver = make_driver(required_cache_leases(2))
    driver.start()
    assert worst_case_request(driver) == required_cache_leases(2)
    assert driver._custody.snapshot().leases == len(driver.checkpoints._entries)


def test_one_lease_below_the_required_count_refuses_the_worst_case_request():
    driver = make_driver(required_cache_leases(2) - 1)
    driver.start()
    with pytest.raises(DriverError, match="^cache copy custody failed$"):
        worst_case_request(driver)
