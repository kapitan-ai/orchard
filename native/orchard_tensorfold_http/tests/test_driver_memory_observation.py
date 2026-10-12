"""Memory diagnostics follow the driver's admission and settlement phases.

They observe custody; they never change it, quarantine on their own failure, or
add native work.
"""

import gc
import logging
import threading
import weakref
from types import SimpleNamespace

import pytest
from test_tensorfold_driver import (
    Cancellation,
    Checkpoints,
    Engine,
    Scheduler,
    job_factory,
    run,
)
from test_tensorfold_driver import bounds as bounds
from test_tensorfold_driver import receipt as receipt

from orchard_tensorfold_http.memory_observation import LogWriter, MemoryObserver
from orchard_tensorfold_http.tensorfold_driver import DriverError, TensorFoldDriver


class Recorder:
    def __init__(self, fail=False):
        self.events = []
        self.fail = fail

    def request_start(self, custody, checkpoints):
        self.events.append(("request_start", custody.leases, checkpoints))
        if self.fail:
            raise RuntimeError("observer failed")

    def copied(self, cache):
        self.events.append(("copied", len(cache)))
        if self.fail:
            raise RuntimeError("observer failed")

    def phase(self, name, custody, checkpoints, stream=None):
        self.events.append((name, custody.leases, checkpoints))
        if self.fail:
            raise RuntimeError("observer failed")


def make_driver(bounds, receipt, observer, engine=None, scheduler=Scheduler):
    def quarantine():
        receipt.quarantines += 1

    def copy_barrier(engine, cache):
        receipt.copy_barriers += 1
        return receipt.copy_settle

    def request_barrier(engine):
        receipt.request_barriers += 1
        return receipt.settle

    driver = TensorFoldDriver(
        Engine() if engine is None else engine,
        scheduler_factory=scheduler,
        job_factory=job_factory,
        checkpoint_factory=Checkpoints,
        cancellation_factory=Cancellation,
        bounds=bounds,
        copy_bounds=lambda cache: (sum(layer["bytes"] for layer in cache), 5),
        copy_settlement=copy_barrier,
        request_settlement=request_barrier,
        on_quarantine=quarantine,
        eos_ids=frozenset({19}),
        memory_observer=observer,
    )
    driver.start()
    return driver


def test_phases_follow_admission_copies_and_settlement_in_order(bounds, receipt):
    recorder = Recorder()
    driver = make_driver(bounds, receipt, recorder)
    assert run(driver) == [[6, 7]]
    assert [event[0] for event in recorder.events] == [
        "request_start",
        "copied",
        "settled_before_release",
        "settled_after_release",
    ]
    # One staged copy is still owned before release; afterwards only the retained one remains.
    start, _, before, after = recorder.events
    assert start[1:] == (0, 0)
    assert before[1] == 1 and after[1] == len(driver.checkpoints._entries) == 1
    assert receipt.request_barriers == 1 and receipt.quarantines == 0


def test_observation_does_not_change_custody_or_completion(bounds, receipt):
    plain = make_driver(bounds, receipt, None)
    observed = make_driver(bounds, receipt, Recorder())
    for driver in (plain, observed):
        assert run(driver) == [[6, 7]]
        assert run(driver, prompt=[1, 2, 3, 4], history=3) == [[6, 7]]
    assert plain._custody.snapshot() == observed._custody.snapshot()
    assert plain.completion == observed.completion
    assert plain.engine.copies == observed.engine.copies


def test_a_failing_observer_never_quarantines_or_blocks_reuse(bounds, receipt):
    driver = make_driver(bounds, receipt, Recorder(fail=True))
    assert run(driver) == [[6, 7]]
    assert run(driver, prompt=[1, 2, 3, 4], history=3) == [[6, 7]]
    assert receipt.quarantines == 0 and driver.settled


def test_uncertain_requests_are_observed_and_still_quarantine(bounds, receipt):
    recorder = Recorder()
    driver = make_driver(bounds, receipt, recorder)
    receipt.settle = False
    with pytest.raises(DriverError, match="settlement was not confirmed"):
        run(driver)
    names = [event[0] for event in recorder.events]
    assert names[-1] == "request_uncertain"
    assert "settled_before_release" not in names
    assert receipt.quarantines == 1 and driver.quarantined
    # Uncertain custody keeps its leases; observation released nothing.
    assert driver._custody.snapshot().leases == recorder.events[-1][1] > 0


def test_an_observer_whose_copy_hook_lookup_fails_never_quarantines(bounds, receipt):
    class BrokenLookup(Recorder):
        @property
        def copied(self):
            raise RuntimeError("lookup failed")

    driver = make_driver(bounds, receipt, BrokenLookup())
    assert run(driver) == [[6, 7]]
    assert run(driver, prompt=[1, 2, 3, 4], history=3) == [[6, 7]]
    assert receipt.quarantines == 0 and driver.settled


def test_the_uncertain_sample_follows_quarantine_and_cancellation(bounds, receipt):
    seen = []

    class AtUncertain(Recorder):
        def phase(self, name, custody, checkpoints, stream=None):
            if name == "request_uncertain":
                seen.append(receipt.quarantines)
            super().phase(name, custody, checkpoints, stream)

    driver = make_driver(bounds, receipt, AtUncertain())
    receipt.settle = False
    with pytest.raises(DriverError):
        run(driver)
    assert seen == [1]


def test_a_blocked_log_handler_cannot_delay_settlement(bounds, receipt):
    gate = threading.Event()

    class Blocking(logging.Handler):
        def emit(self, record):
            gate.wait(5)

    log = logging.getLogger("orchard_tensorfold_http.memory_observation")
    handler = Blocking()
    log.addHandler(handler)
    log.setLevel(logging.INFO)
    counter = lambda: 1  # noqa: E731 - synthetic counter
    observer = MemoryObserver(
        active=counter,
        cache=counter,
        peak=counter,
        reset_peak=lambda: None,
        footprint=counter,
        estimate=lambda cache: 1,
        writer=LogWriter(capacity=1),
    )
    try:
        driver = make_driver(bounds, receipt, observer)
        results = []
        worker = threading.Thread(target=lambda: results.append(run(driver)))
        worker.start()
        worker.join(2)
        assert results == [[[6, 7]]]
        assert receipt.quarantines == 0 and driver.settled
    finally:
        gate.set()
        log.removeHandler(handler)


class Layer(dict):
    """A copied cache layer that a weak reference can watch."""


class TrackingEngine(Engine):
    def __init__(self):
        super().__init__()
        self.layers = []

    def copy_single_cache(self, cache):
        self.copies += 1
        copied = [Layer(layer) for layer in cache]
        self.layers.extend(weakref.ref(layer) for layer in copied)
        return copied


def test_released_copies_are_unreachable_when_the_after_release_sample_is_taken(bounds, receipt):
    live = []

    class AfterRelease(Recorder):
        def phase(self, name, custody, checkpoints, stream=None):
            if name == "settled_after_release":
                gc.collect()
                live.append(sum(1 for ref in driver.engine.layers if ref() is not None))
            super().phase(name, custody, checkpoints, stream)

    driver = make_driver(bounds, receipt, AfterRelease(), TrackingEngine())
    assert run(driver) == [[6, 7]]
    # The second request borrows a copy and evicts the first snapshot; both are
    # released at settlement, so only the new retained snapshot stays alive.
    assert run(driver, prompt=[1, 2, 3, 4], history=3) == [[6, 7]]
    assert live == [1, 1]


def test_a_snapshot_the_store_rejects_is_unreachable_at_the_after_release_sample(bounds, receipt):
    live = []

    class AfterRelease(Recorder):
        def phase(self, name, custody, checkpoints, stream=None):
            if name == "settled_after_release":
                gc.collect()
                live.append(sum(1 for ref in driver.engine.layers if ref() is not None))
            super().phase(name, custody, checkpoints, stream)

    driver = make_driver(bounds, receipt, AfterRelease(), TrackingEngine())
    # Over the checkpoint budget: the store refuses the snapshot, so its copy
    # is the last record released at settlement.
    driver._copy_bounds = lambda cache: (30, 5)
    assert run(driver) == [[6, 7]]
    assert not driver.checkpoints._entries
    assert live == [0]


class RequestError(ValueError):
    """errors.py:1-2 at cb2ebf05."""


class PrefillFailure(Scheduler):
    """A prefill that fails after a stored-prefix hit, as TensorFold 0.6.6 reports it.

    ``_start_fill`` hands the borrowed copy to the engine's prefill steps
    (family_prefill.py:148-197), whose frame keeps it as the working cache. A
    generic failure there reaches ``_end_fill`` (prompt_fill.py:195-226), which
    stores it on the job with its traceback; only ``RequestError`` loses its
    frames. A failed prefill leaves the stream's finish reason empty.
    """

    finish_reason = ""

    def submit(self, job):
        if self.behavior != "prefill_error":
            return super().submit(job)
        self.jobs.append(job)
        self.active = self.engine.active_count = 1
        _, cache, _ = self.checkpoints.match(job.prompt_ids)
        job.stream = SimpleNamespace(finish_reason=self.finish_reason, history_checkpoints=[])
        steps = self._prefill_steps(cache)
        del cache
        try:
            next(steps)
        except Exception as exc:
            self._end_fill(job, exc)

    @staticmethod
    def _prefill_steps(cache):
        try:
            cache[0].pop("missing")
        except KeyError:
            # Chained, so the context's traceback holds this frame too.
            raise RuntimeError("prefill failed")  # noqa: B904
        yield

    def _end_fill(self, job, error):
        try:
            raise error
        except Exception as exc:
            job.error = exc.with_traceback(None) if isinstance(exc, RequestError) else exc
            job.chunks.put(None)
            self.active = self.engine.active_count = 0
            job.done.set()


@pytest.mark.parametrize(
    "finish_reason,failure",
    [("", "finish metadata is unsupported"), ("stop", "failed after native settlement")],
)
def test_a_failed_prefill_error_keeps_no_released_borrowed_copy_reachable(
    bounds, receipt, finish_reason, failure
):
    driver = make_driver(bounds, receipt, None, TrackingEngine(), PrefillFailure)
    assert run(driver) == [[6, 7]]
    driver.scheduler.behavior = "prefill_error"
    driver.scheduler.finish_reason = finish_reason
    copies = len(driver.engine.layers)
    with pytest.raises(DriverError, match=failure):
        run(driver, prompt=[1, 2, 3, 4], history=3)
    [borrowed] = driver.engine.layers[copies:]
    job = driver.scheduler.jobs[-1]
    # Settlement released the borrowed lease; the job still holds its error.
    assert driver._custody.snapshot().leases == len(driver.checkpoints._entries) == 1
    gc.collect()
    assert borrowed() is None
    assert type(job.error) is RuntimeError and str(job.error) == "prefill failed"
    assert job.error.__traceback__ is job.error.__context__ is None
