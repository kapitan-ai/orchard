"""Model-free driver integration through the pinned scheduler's factory shapes."""

import time
from dataclasses import replace
from threading import Event, Lock, Thread
from types import SimpleNamespace

import pytest

from orchard_tensorfold_http import tensorfold_driver as driver_module
from orchard_tensorfold_http.tensorfold_driver import DriverBounds, DriverError, TensorFoldDriver


class Cancellation:
    cancelled = False

    def cancel(self):
        self.cancelled = True


class Engine:
    def __init__(self):
        self.active_count = 0
        self.finished_caches = {}
        self.streams = []
        self.copies = 0
        self.round_releases = 0

    def copy_single_cache(self, cache):
        self.copies += 1
        return [dict(layer) for layer in cache]

    def release_rounds(self):
        self.round_releases += 1


class Checkpoints:
    def __init__(self, slots, **options):
        self.slots = slots
        self.copier, self.sizer = options["copier"], options["sizer"]
        self.budget_bytes = options["budget_bytes"]
        self.pinned_slots = options["pinned_slots"]
        self.on_evict = options["on_evict"]
        self.admit_oversize = False
        self._entries = []
        self._lock = Lock()

    def insert(self, tokens, cache, *, last_prompt, pinned=False):
        size = self.sizer(cache)
        if size > self.budget_bytes and not self.admit_oversize:
            return
        self._entries = [
            SimpleNamespace(tokens=list(tokens), cache=cache, nbytes=size),
            *(entry for entry in self._entries if entry.tokens != tokens),
        ]
        while (
            len(self._entries) > self.slots
            or sum(e.nbytes for e in self._entries) > self.budget_bytes
        ):
            self._entries.pop()

    def match(self, prompt, usable=None, *, take=False):
        candidates = [
            entry
            for entry in self._entries
            if 0 < len(entry.tokens) < len(prompt) and prompt[: len(entry.tokens)] == entry.tokens
        ]
        if not candidates:
            return None
        entry = max(candidates, key=lambda e: len(e.tokens))
        if take:
            self._entries.remove(entry)
            cache = entry.cache
        else:
            cache = self.copier(entry.cache)
        return len(entry.tokens), cache, list(entry.tokens)


class Scheduler:
    def __init__(self, engine, **options):
        self.engine, self.options = engine, options
        self.checkpoints = options["checkpoints"]
        self.active = self.waiting = 0
        self.filling = []
        self._thread = SimpleNamespace(is_alive=lambda: self.alive, join=lambda timeout: None)
        self._watchdog = SimpleNamespace(
            is_alive=lambda: self.watchdog_alive, join=lambda timeout: None
        )
        self.alive = False
        self.watchdog_alive = False
        self.behavior = "normal"
        self.jobs = []
        self.cancel_calls = 0
        self.stop_calls = 0

    def start(self):
        self.alive = True
        self.watchdog_alive = True

    def stop(self, *, timeout):
        self.stop_calls += 1
        self.alive = self.behavior == "stop_stuck"
        self.watchdog_alive = self.behavior == "watchdog_stuck"
        self.on_stop()

    def submit(self, job):
        self.jobs.append(job)
        job.stream = SimpleNamespace(finish_reason="stop", history_checkpoints=[])
        self.active = self.engine.active_count = 1
        hit = self.checkpoints.match(job.prompt_ids, take=self.behavior == "take")
        job.cached_tokens, cache = (0, [{"bytes": 10}]) if hit is None else (hit[0], hit[1])
        snapshot = self.engine.copy_single_cache(cache)
        self.checkpoints.insert(
            job.prompt_ids[: job.history_len], snapshot, last_prompt=job.prompt_ids
        )
        if self.behavior == "fault":
            self.alive = False
            return
        if self.behavior == "hang":
            return
        if self.behavior == "hang_after_chunk":
            job.chunks.put([6, 7])
            return
        if self.behavior == "overflow":
            job.chunks.put([1, 2, 3, 4])
        else:
            job.chunks.put([6, 7])
        job.chunks.put(None)
        self.active = self.engine.active_count = 0
        if self.behavior == "public_done_only":
            self.engine.streams = [job.stream]
        job.done.set()

    def cancel(self, cancellation):
        self.cancel_calls += 1
        cancellation.cancel()

    def on_engine(self, operation, *, timeout):
        return operation(self.engine)


def job_factory(**values):
    return SimpleNamespace(done=Event(), error=None, stream=None, cached_tokens=0, **values)


@pytest.fixture
def bounds():
    # Synthetic experiment bounds; no production memory or latency claim.
    return DriverBounds(
        total_budget_bytes=100,
        working_bytes=20,
        workspace_bytes=10,
        checkpoint_budget_bytes=20,
        checkpoint_slots=1,
        max_cache_leases=5,
        max_cache_layers=2,
        max_buffer_chunks=2,
        max_buffer_tokens=6,
        max_chunk_tokens=3,
        vocabulary_size=20,
        max_input_tokens=8,
        max_output_tokens=4,
        max_context_tokens=12,
        poll_seconds=0.001,
        request_seconds=0.05,
        cancel_seconds=0.01,
        settlement_seconds=0.01,
    )


@pytest.fixture
def receipt():
    return SimpleNamespace(
        quarantines=0, copy_barriers=0, request_barriers=0, settle=True, copy_settle=True
    )


@pytest.fixture
def driver(bounds, receipt):
    def quarantine():
        receipt.quarantines += 1

    def copy_barrier(engine, cache):
        receipt.copy_barriers += 1
        return receipt.copy_settle

    def request_barrier(engine):
        receipt.request_barriers += 1
        return receipt.settle

    return TensorFoldDriver(
        Engine(),
        scheduler_factory=Scheduler,
        job_factory=job_factory,
        checkpoint_factory=Checkpoints,
        cancellation_factory=Cancellation,
        bounds=bounds,
        copy_bounds=lambda cache: (sum(layer["bytes"] for layer in cache), 5),
        copy_settlement=copy_barrier,
        request_settlement=request_barrier,
        on_quarantine=quarantine,
        eos_ids=frozenset({19}),
    )


def run(driver, prompt=None, history=2, **options):
    return list(
        driver.generate(
            [1, 2, 3] if prompt is None else prompt, history, 4, 1.0, sampling=None, **options
        )
    )


def test_actual_factory_options_install_c1_ram_only_raw_buffer_and_copy_hook(driver, receipt):
    options = driver.scheduler.options
    assert options["lanes"] == 1
    assert options["proposer_factory"] is None
    assert options["snapshot_dir"] is options["session_dir"] is None
    assert options["prompt_memory"] is options["admission"] is None
    assert not driver.engine.retain_finished_caches
    assert not driver.checkpoints.admit_oversize
    assert driver.checkpoints.pinned_slots == 0
    assert driver.checkpoints.on_evict is None
    driver.start()
    assert run(driver) == [[6, 7]]
    job = driver.scheduler.jobs[0]
    assert job.drafts is False and job.proposer is None and not job.background
    assert receipt.copy_barriers == receipt.request_barriers == 1
    assert driver.completion.cached_tokens == 0
    assert driver.completion.output_tokens == 2
    assert driver.settled and not driver.quarantined


@pytest.mark.parametrize("take", [False, True])
def test_natural_prefix_continuation_reconciles_staged_retained_and_borrowed_custody(driver, take):
    driver.start()
    assert run(driver) == [[6, 7]]
    assert driver._custody.snapshot().held_bytes == 10
    if take:
        driver.scheduler.behavior = "take"
    assert run(driver, prompt=[1, 2, 3, 4], history=3) == [[6, 7]]
    assert driver.completion.cached_tokens == 2
    assert driver._custody.snapshot().held_bytes == 10
    assert driver._custody.snapshot().leases == 1
    assert len(driver._records) == 1
    assert next(iter(driver._records.values())).owners == {"retained"}


def test_staged_and_retained_custody_stays_until_positive_native_settlement(driver, receipt):
    receipt.settle = False
    driver.start()
    with pytest.raises(DriverError, match="settlement"):
        run(driver)
    assert driver.quarantined and not driver.settled
    assert receipt.quarantines == 1
    assert driver._custody.snapshot().held_bytes == 10
    assert next(iter(driver._records.values())).owners == {"staged", "retained"}
    assert driver.completion is None
    with pytest.raises(DriverError, match="unavailable"):
        run(driver)
    with pytest.raises(RuntimeError, match="reaping"):
        driver.positive_owned_reap(lambda: False)
    assert not driver.retired
    assert driver._custody.snapshot().held_bytes == 10
    driver.positive_owned_reap(lambda: True)
    assert driver.retired
    assert driver._custody.snapshot().held_bytes == 0
    assert not driver._records
    with pytest.raises(DriverError, match="unavailable"):
        driver.start()


def test_terminal_and_done_without_idle_native_state_cannot_establish_reuse(driver, receipt):
    driver.scheduler.behavior = "public_done_only"
    driver.start()
    with pytest.raises(DriverError, match="settlement"):
        run(driver)
    assert receipt.request_barriers == 0
    assert driver.quarantined


def test_safe_cancellation_can_settle_and_admit_a_later_request(driver):
    driver.start()
    cancelled = Event()
    cancelled.set()
    assert run(driver, cancel_event=cancelled) == []
    assert driver.completion.cancelled
    assert driver.completion.finish_reason == "cancelled"
    assert driver.settled and not driver.quarantined
    assert driver.scheduler.cancel_calls == 1
    assert run(driver) == [[6, 7]]


@pytest.mark.parametrize("behavior", ["fault", "hang", "overflow"])
def test_thread_fault_deadline_and_producer_overflow_quarantine_without_readmission(
    driver, receipt, behavior
):
    driver.scheduler.behavior = behavior
    driver.start()
    with pytest.raises(RuntimeError):
        run(driver)
    assert driver.quarantined and not driver.settled
    assert receipt.quarantines == 1
    assert driver._custody.snapshot().held_bytes == 10
    with pytest.raises(DriverError, match="unavailable"):
        run(driver)


def test_abandoned_iterator_cancels_and_quarantines_instead_of_implying_release(driver, receipt):
    driver.start()
    iterator = driver.generate([1, 2, 3], 2, 4, 1.0, None)
    assert next(iterator) == [6, 7]
    iterator.close()
    assert driver.quarantined
    assert receipt.request_barriers == 0
    assert driver.scheduler.cancel_calls == 1


def test_c1_busy_admission_does_not_queue_or_poison_the_existing_request(driver, receipt):
    driver.start()
    iterator = driver.generate([1, 2, 3], 2, 4, 1.0, None)
    assert next(iterator) == [6, 7]
    with pytest.raises(DriverError, match="C1"):
        run(driver)
    assert receipt.quarantines == 0
    assert list(iterator) == []
    assert driver.settled


def test_copy_failure_never_releases_failed_copy_budget(driver, receipt):
    receipt.copy_settle = False
    driver.start()
    with pytest.raises(DriverError, match="copy custody"):
        run(driver)
    snapshot = driver._custody.snapshot()
    assert snapshot.quarantined
    assert (snapshot.copy_bytes, snapshot.transient_bytes) == (10, 5)
    assert driver.quarantined


@pytest.mark.parametrize("value", [None, True, -1, float("inf")])
def test_unknown_copy_bounds_are_rejected_before_native_copy(driver, value):
    driver._copy_bounds = lambda cache: (value, 0)
    driver.start()
    with pytest.raises(DriverError, match="copy custody"):
        run(driver)
    assert driver.engine.copies == 0
    assert driver.quarantined


@pytest.mark.parametrize(
    "changes",
    [
        {"poll_seconds": 0},
        {"request_seconds": float("inf")},
        {"working_bytes": 101},
        {"max_cache_leases": False},
        {"workspace_bytes": -1},
    ],
)
def test_experiment_bounds_fail_closed(bounds, changes):
    with pytest.raises(ValueError):
        replace(bounds, **changes)


@pytest.mark.parametrize(
    "prompt,history,maximum,temperature,options",
    [
        ([], 0, 1, 0.0, {}),
        ([True], 0, 1, 0.0, {}),
        ([20], 0, 1, 0.0, {}),
        ([1, 2], True, 1, 0.0, {}),
        ([1, 2], 2, 1, 0.0, {}),
        ([1, 2], 0, 5, 0.0, {}),
        ([1, 2], 0, 1, float("nan"), {}),
        ([1, 2], 0, 1, 0.0, {"checkpoint_boundaries": (True,)}),
        ([1, 2], 0, 1, 0.0, {"deadline_monotonic": float("nan")}),
    ],
)
def test_invalid_request_is_refused_before_submission(
    driver, prompt, history, maximum, temperature, options
):
    driver.start()
    with pytest.raises(ValueError):
        list(driver.generate(prompt, history, maximum, temperature, None, **options))
    assert not driver.scheduler.jobs
    assert driver.settled and not driver.quarantined


def test_external_absolute_deadline_is_honored(driver):
    driver.scheduler.behavior = "hang"
    driver.start()
    with pytest.raises(DriverError, match="bounded completion"):
        run(driver, deadline_monotonic=time.monotonic() + 0.002)
    assert driver.quarantined


def test_expired_deadline_is_refused_before_native_submission(driver):
    driver.start()
    with pytest.raises(ValueError, match="expired before admission"):
        run(driver, deadline_monotonic=time.monotonic() - 1)
    assert not driver.scheduler.jobs
    assert driver.settled


@pytest.mark.parametrize("change", ["grow", "shrink", "domain"])
def test_mutation_after_initial_validation_cannot_expand_or_bypass_prompt_bounds(
    driver, monkeypatch, change
):
    prompt = [1, 2, 3]
    original = driver._validate
    called = []

    def validate(*args):
        size = original(*args)
        if not called:
            called.append(True)
            if change == "grow":
                prompt.extend(range(1000))
            elif change == "shrink":
                prompt.clear()
            else:
                prompt[0] = True
        return size

    monkeypatch.setattr(driver, "_validate", validate)
    driver.start()
    with pytest.raises(ValueError, match="changed during admission|token domain"):
        run(driver, prompt=prompt)
    assert not driver.scheduler.jobs
    assert driver.settled


def test_external_cancel_after_first_chunk_can_settle_safely(driver):
    driver.start()
    iterator = driver.generate([1, 2, 3], 2, 4, 1.0, None)
    assert next(iterator) == [6, 7]
    driver.cancel()
    assert list(iterator) == []
    assert driver.completion.cancelled
    assert driver.settled


class LateCancel:
    # Unset at the loop top; set by the time the first chunk arrives.
    def __init__(self):
        self.checks = 0

    def is_set(self):
        self.checks += 1
        return self.checks > 1


def test_cancel_observed_after_a_chunk_still_bounds_unsettled_cancellation(driver, receipt):
    driver.bounds = replace(driver.bounds, request_seconds=5.0)
    driver.scheduler.behavior = "hang_after_chunk"
    driver.start()
    started = time.monotonic()
    with pytest.raises(DriverError, match="bounded completion"):
        run(driver, cancel_event=LateCancel())
    assert time.monotonic() - started < 1.0
    assert driver.scheduler.cancel_calls == 1
    assert driver.quarantined and receipt.quarantines == 1


def test_job_error_after_positive_settlement_does_not_publish_success_metadata(driver, monkeypatch):
    original = driver.scheduler.submit

    def submit(job):
        original(job)
        job.error = RuntimeError("injected request error")

    monkeypatch.setattr(driver.scheduler, "submit", submit)
    driver.start()
    with pytest.raises(DriverError, match="failed after native settlement"):
        run(driver)
    assert driver.completion is None
    assert driver.settled


def test_checkpoint_rejected_by_store_budget_is_disposed_only_after_request_barrier(driver):
    driver._copy_bounds = lambda cache: (30, 5)
    driver.start()
    assert run(driver) == [[6, 7]]
    assert not driver.checkpoints._entries
    assert driver._custody.snapshot().held_bytes == 0
    assert driver._custody.snapshot().leases == 0


def test_normal_shutdown_releases_caches_and_verifies_both_threads_without_process_reap(
    driver, receipt
):
    driver.start()
    run(driver)
    engine = driver.engine
    record = next(iter(driver._records.values()))
    driver.shutdown()
    assert driver.normal_closed and driver.retired
    assert not driver.quarantined and not driver.settled
    assert receipt.quarantines == 0
    assert receipt.request_barriers == 2
    assert engine.round_releases == 1
    assert driver.engine is driver.scheduler.engine is None
    assert not driver.scheduler._thread.is_alive()
    assert not driver.scheduler._watchdog.is_alive()
    assert not driver.checkpoints._entries
    assert not record.cache and not record.owners
    assert driver._custody.snapshot().held_bytes == 0
    assert not driver._custody.snapshot().reaped
    driver.shutdown()
    assert driver.scheduler.stop_calls == 1
    with pytest.raises(DriverError, match="unavailable"):
        driver.start()
    driver.quarantine()  # A late timer cannot turn confirmed closure into reuse.
    assert not driver.quarantined


def test_shutdown_active_iterator_cancels_and_closes_under_native_barrier(driver, receipt):
    driver.start()
    iterator = driver.generate([1, 2, 3], 2, 4, 1.0, None)
    assert next(iterator) == [6, 7]
    job = driver.scheduler.jobs[0]
    driver.shutdown(timeout=1)
    assert driver.scheduler.cancel_calls == 1
    assert job.cancellation.cancelled
    assert job.stream is None
    assert driver.normal_closed
    assert driver.completion is None
    assert receipt.quarantines == 0
    with pytest.raises(DriverError, match="unavailable"):
        next(iterator)
    assert receipt.quarantines == 0


@pytest.mark.parametrize(
    "failure", ["barrier_false", "barrier_timeout", "stop_stuck", "watchdog_stuck"]
)
def test_uncertain_shutdown_preserves_leases_and_requires_owned_reap(
    driver, receipt, monkeypatch, failure
):
    driver.start()
    run(driver)
    if failure == "barrier_false":
        receipt.settle = False
    elif failure == "barrier_timeout":

        def timeout(*args, **options):
            raise TimeoutError("injected settlement timeout")

        monkeypatch.setattr(driver.scheduler, "on_engine", timeout)
    else:
        driver.scheduler.behavior = failure
    with pytest.raises(DriverError, match="shutdown remained uncertain"):
        driver.shutdown(timeout=1)
    assert driver.quarantined and not driver.normal_closed
    assert receipt.quarantines == 1
    assert driver._custody.snapshot().held_bytes == 10
    assert driver._records
    assert driver.engine is not None
    with pytest.raises(DriverError, match="unavailable"):
        driver.shutdown()
    driver.positive_owned_reap(lambda: True)
    assert driver.retired
    assert driver._custody.snapshot().held_bytes == 0


def test_public_quarantine_rejects_reuse_without_disposing_custody(driver, receipt):
    driver.start()
    run(driver)
    driver.quarantine()
    driver.quarantine()
    assert receipt.quarantines == 1
    assert driver._custody.snapshot().held_bytes == 10
    with pytest.raises(DriverError, match="unavailable"):
        run(driver)


def test_late_shutdown_engine_callback_cannot_release_after_timeout(driver, monkeypatch):
    driver.start()
    run(driver)
    callbacks = []

    def timeout(operation, *, timeout):
        callbacks.append(operation)
        raise TimeoutError("injected wait deadline")

    monkeypatch.setattr(driver.scheduler, "on_engine", timeout)
    with pytest.raises(DriverError, match="shutdown remained uncertain"):
        driver.shutdown(timeout=1)
    record = next(iter(driver._records.values()))
    with pytest.raises(DriverError, match="unavailable"):
        callbacks[0](driver.engine)
    assert driver.quarantined and not driver.normal_closed
    assert driver.checkpoints._entries
    assert record.cache and record.owners == {"retained"}
    assert driver._custody.snapshot().held_bytes == 10
    assert driver.scheduler.stop_calls == 0


@pytest.mark.parametrize("timeout", [0, -1, True, float("nan"), float("inf")])
def test_invalid_shutdown_timeout_cannot_begin_teardown(driver, timeout):
    driver.start()
    with pytest.raises(ValueError, match="shutdown timeout"):
        driver.shutdown(timeout)
    assert driver.settled and not driver.quarantined
    assert driver.scheduler.stop_calls == 0


def test_shutdown_closing_gate_preserves_cancellation_snapshot_until_barrier(driver, monkeypatch):
    driver.start()
    run(driver)
    original = driver.scheduler.on_engine

    def on_engine(operation, *, timeout):
        cache = driver.engine.copy_single_cache([{"bytes": 10}])
        assert driver._record(cache).owners == {"staged"}
        return original(operation, timeout=timeout)

    monkeypatch.setattr(driver.scheduler, "on_engine", on_engine)
    driver.shutdown(timeout=1)
    assert driver.normal_closed
    assert driver._custody.snapshot().held_bytes == 0


def test_shutdown_does_not_dispose_or_admit_while_native_barrier_is_blocked(driver, receipt):
    driver.start()
    run(driver)
    entered, finish = Event(), Event()
    failures = []

    def barrier(engine):
        entered.set()
        assert finish.wait(2)
        return True

    driver._request_settlement = barrier

    def close():
        try:
            driver.shutdown(timeout=2)
        except DriverError as error:
            failures.append(str(error))

    worker = Thread(target=close)
    worker.start()
    try:
        assert entered.wait(1)
        assert driver._custody.snapshot().held_bytes == 10
        assert driver.checkpoints._entries
        assert driver.scheduler.stop_calls == 0
        with pytest.raises(DriverError, match="unavailable"):
            run(driver)
    finally:
        finish.set()
        worker.join(2)
    assert not worker.is_alive()
    assert failures == []
    assert driver.normal_closed
    assert receipt.quarantines == 0


DRIVER_LOGGER = "orchard_tensorfold_http.tensorfold_driver"


def copy_failure_records(caplog):
    return [
        r
        for r in caplog.records
        if r.name == DRIVER_LOGGER and "cache copy custody failed" in r.getMessage()
    ]


def test_copy_envelope_failure_logs_custody_reason_and_snapshot(driver, caplog):
    caplog.set_level("INFO", logger=DRIVER_LOGGER)
    driver._copy_bounds = lambda cache: (60, 20)
    driver.start()
    with pytest.raises(DriverError, match="^cache copy custody failed$"):
        run(driver)
    assert driver.quarantined
    [record] = copy_failure_records(caplog)
    assert record.levelname == "WARNING"
    message = record.getMessage()
    assert "reason=CacheCustodyError: cache copy exceeds reserved envelope" in message
    for field in (
        "requested=60+20",
        "total_budget=100",
        "workspace_reserved=30",
        "working=20",
        "held=0",
        "leases=0",
        "max_leases=5",
        "checkpoints=0",
        "quarantined=False",
    ):
        assert field in message


def test_copy_failure_quarantines_even_when_logging_fails(driver, monkeypatch):
    def broken_snapshot():
        raise RuntimeError("snapshot unavailable")

    driver._copy_bounds = lambda cache: (60, 20)
    driver.start()
    monkeypatch.setattr(driver._custody, "snapshot", broken_snapshot)
    with pytest.raises(DriverError, match="^cache copy custody failed$"):
        run(driver)
    assert driver.quarantined


def test_copy_failure_keeps_fixed_error_when_log_sink_fails(driver, monkeypatch):
    def broken_sink(*_args, **_kwargs):
        raise RuntimeError("log sink unavailable")

    driver._copy_bounds = lambda cache: (60, 20)
    driver.start()
    monkeypatch.setattr(driver_module.logger, "warning", broken_sink)
    with pytest.raises(DriverError, match="^cache copy custody failed$"):
        run(driver)
    assert driver.quarantined


def test_request_succeeds_when_start_log_sink_fails(driver, monkeypatch):
    def broken_sink(*_args, **_kwargs):
        raise RuntimeError("log sink unavailable")

    driver.start()
    monkeypatch.setattr(driver_module.logger, "info", broken_sink)
    assert run(driver) == [[6, 7]]
    assert driver.settled and not driver.quarantined


def test_copy_lease_limit_failure_logs_custody_reason(driver, caplog):
    caplog.set_level("INFO", logger=DRIVER_LOGGER)
    driver.start()
    assert run(driver) == [[6, 7]]
    driver._custody._max_leases = 1
    with pytest.raises(DriverError, match="^cache copy custody failed$"):
        run(driver, prompt=[1, 2, 3, 4], history=3)
    message = copy_failure_records(caplog)[0].getMessage()
    assert "reason=CacheCustodyError: cache lease limit exceeded" in message
    assert "leases=1" in message and "held=10" in message and "checkpoints=1" in message


def test_foreign_copy_exception_logs_only_its_class(driver, caplog):
    caplog.set_level("INFO", logger=DRIVER_LOGGER)

    def failing_copy(cache):
        raise KeyError("private prompt fragment 1 2 3")

    driver._original_copy = failing_copy
    driver.start()
    with pytest.raises(DriverError, match="^cache copy custody failed$"):
        run(driver)
    message = copy_failure_records(caplog)[0].getMessage()
    assert "reason=KeyError" in message
    assert "private prompt fragment" not in message


def test_foreign_value_error_logs_only_its_class(driver, caplog):
    caplog.set_level("INFO", logger=DRIVER_LOGGER)

    def failing_copy(cache):
        raise ValueError("private prompt fragment 4 5 6")

    driver._original_copy = failing_copy
    driver.start()
    with pytest.raises(DriverError, match="^cache copy custody failed$"):
        run(driver)
    message = copy_failure_records(caplog)[0].getMessage()
    assert "reason=ValueError requested=" in message
    assert "private prompt fragment" not in message


def test_package_value_error_logs_its_fixed_message(driver, caplog):
    caplog.set_level("INFO", logger=DRIVER_LOGGER)
    driver._copy_bounds = lambda cache: (-1, 0)
    driver.start()
    with pytest.raises(DriverError, match="^cache copy custody failed$"):
        run(driver)
    message = copy_failure_records(caplog)[0].getMessage()
    assert "reason=ValueError: copy bound must be a bounded positive integer" in message
    assert "requested=-1+0" in message


def test_request_start_logs_cached_prompt_and_checkpoint_counts(driver, caplog):
    caplog.set_level("INFO", logger=DRIVER_LOGGER)
    driver.start()
    assert run(driver) == [[6, 7]]
    assert run(driver, prompt=[1, 2, 3, 4], history=3) == [[6, 7]]
    starts = [
        r.getMessage()
        for r in caplog.records
        if r.name == DRIVER_LOGGER and r.getMessage().startswith("tensorfold request started")
    ]
    assert starts == [
        "tensorfold request started cached=0 prompt=3 checkpoints=0",
        "tensorfold request started cached=2 prompt=4 checkpoints=1",
    ]
    for record in caplog.records:
        assert "[1, 2" not in record.getMessage()
        assert all(not isinstance(arg, list | tuple) for arg in record.args or ())
