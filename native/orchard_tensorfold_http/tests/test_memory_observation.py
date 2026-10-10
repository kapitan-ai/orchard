"""Memory diagnostics only observe: no limits, no clearing, no failure propagation."""

import logging
import threading
import time
from types import SimpleNamespace

import pytest

from orchard_tensorfold_http.memory_observation import LogWriter, MemoryObserver

CUSTODY = SimpleNamespace(leases=3, held_bytes=36)


class Counters:
    def __init__(self):
        self.calls = []
        self.values = {"active": 100, "cache": 20, "peak": 150, "footprint": 400}
        self.reset_error = None

    def read(self, name):
        def counter():
            self.calls.append(name)
            value = self.values[name]
            if isinstance(value, Exception):
                raise value
            return value

        return counter

    def reset(self):
        self.calls.append("reset_peak")
        if self.reset_error is not None:
            raise self.reset_error


def observer(counters, estimate=lambda cache: 7, writer=None):
    return MemoryObserver(
        active=counters.read("active"),
        cache=counters.read("cache"),
        peak=counters.read("peak"),
        reset_peak=counters.reset,
        footprint=counters.read("footprint"),
        estimate=estimate,
        writer=writer,
    )


@pytest.fixture
def writer(caplog):
    caplog.set_level("INFO", logger="orchard_tensorfold_http.memory_observation")
    return LogWriter()


def lines(caplog, writer):
    writer.join()
    return [r.getMessage() for r in caplog.records if "tensorfold memory phase=" in r.getMessage()]


def test_request_start_samples_before_it_resets_the_peak(caplog, writer):
    counters = Counters()
    observer(counters, writer=writer).request_start(CUSTODY, 2)
    assert counters.calls == ["peak", "active", "cache", "footprint", "reset_peak"]
    assert lines(caplog, writer) == [
        "tensorfold memory phase=request_start seq=1 active=100 cache=20 peak=150 "
        "footprint=400 leases=3 held=36 checkpoints=2 copies=0 copy_bytes_est=0 "
        "max_pass_width=0 pass_cache_raises=0 dropped=0"
    ]


def test_copies_and_prefill_shape_are_summarized_per_request(caplog, writer):
    watch = observer(Counters(), estimate=lambda cache: len(cache) * 10, writer=writer)
    watch.request_start(CUSTODY, 0)
    watch.copied([1, 2])
    watch.copied([1, 2, 3])
    stream = SimpleNamespace(prefill_widths=[1, 8, 3], prefill_raised=[False, True, True])
    watch.phase("settled_before_release", CUSTODY, 1, stream)
    watch.request_start(CUSTODY, 1)
    first, settled, second = lines(caplog, writer)
    assert settled.endswith(
        "copies=2 copy_bytes_est=50 max_pass_width=8 pass_cache_raises=2 dropped=0"
    )
    assert "seq=2" in second and "copies=0 copy_bytes_est=0" in second


@pytest.mark.parametrize("value", [None, -1, True, 1.5, RuntimeError("no counter")])
def test_unreadable_counters_are_reported_as_unavailable_never_zero(caplog, writer, value):
    counters = Counters()
    counters.values["footprint"] = value
    observer(counters, writer=writer).phase("settled_after_release", CUSTODY, 0)
    assert "footprint=unavailable" in lines(caplog, writer)[0]


def test_a_failed_estimate_or_peak_reset_is_never_shown_as_a_valid_number(caplog, writer):
    counters = Counters()
    counters.reset_error = RuntimeError("reset failed")

    def estimate(cache):
        if cache == ["bad"]:
            raise RuntimeError("estimate failed")
        return 5

    watch = observer(counters, estimate=estimate, writer=writer)
    watch.request_start(CUSTODY, 0)
    watch.copied(["good"])
    watch.copied(["bad"])
    watch.copied(["good"])
    watch.phase("settled_after_release", CUSTODY, 0)
    settled = lines(caplog, writer)[-1]
    assert "peak=unavailable" in settled
    assert "copies=3 copy_bytes_est=unavailable" in settled


def test_failures_never_escape(caplog, writer):
    counters = Counters()
    watch = observer(counters, writer=writer)
    watch.request_start(SimpleNamespace(), 0)
    assert counters.calls[-1] == "reset_peak"
    watch.phase("request_uncertain", CUSTODY, 0, stream=SimpleNamespace(prefill_widths="x"))

    class BrokenWriter:
        dropped = 0

        def submit(self, line):
            raise RuntimeError("writer failed")

    observer(counters, writer=BrokenWriter()).request_start(CUSTODY, 0)
    assert lines(caplog, writer) == []


def test_a_blocked_log_handler_never_blocks_the_sampling_thread(caplog):
    gate = threading.Event()

    class Blocking(logging.Handler):
        def emit(self, record):
            gate.wait(5)

    log = logging.getLogger("orchard_tensorfold_http.memory_observation")
    handler = Blocking()
    log.addHandler(handler)
    log.setLevel(logging.INFO)
    try:
        writer = LogWriter(capacity=2)
        watch = observer(Counters(), writer=writer)
        started = time.monotonic()
        for _ in range(6):
            watch.phase("settled_before_release", CUSTODY, 0)
        assert time.monotonic() - started < 1.0
        assert writer.dropped >= 3
        gate.set()
        writer.join()
    finally:
        gate.set()
        log.removeHandler(handler)


def test_totals_read_during_an_estimate_stay_consistent(caplog, writer):
    entered, release = threading.Event(), threading.Event()

    def slow_estimate(cache):
        entered.set()
        release.wait(5)
        return 9

    watch = observer(Counters(), estimate=slow_estimate, writer=writer)
    watch.request_start(CUSTODY, 0)
    copier = threading.Thread(target=watch.copied, args=([1],))
    copier.start()
    assert entered.wait(5)
    watch.phase("request_uncertain", CUSTODY, 0)
    release.set()
    copier.join(5)
    watch.phase("settled_after_release", CUSTODY, 0)
    _, during, after = lines(caplog, writer)
    assert "copies=0 copy_bytes_est=0" in during
    assert "copies=1 copy_bytes_est=9" in after
