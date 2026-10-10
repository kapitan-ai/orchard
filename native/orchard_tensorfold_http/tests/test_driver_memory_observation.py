"""Memory diagnostics follow the driver's admission and settlement phases.

They observe custody; they never change it, quarantine on their own failure, or
add native work.
"""

import logging
import threading

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


def make_driver(bounds, receipt, observer):
    def quarantine():
        receipt.quarantines += 1

    def copy_barrier(engine, cache):
        receipt.copy_barriers += 1
        return receipt.copy_settle

    def request_barrier(engine):
        receipt.request_barriers += 1
        return receipt.settle

    driver = TensorFoldDriver(
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
