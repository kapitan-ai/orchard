"""Memory diagnostics only observe: no limits, no clearing, no failure propagation."""

from types import SimpleNamespace

import pytest

from orchard_tensorfold_http.memory_observation import MemoryObserver

CUSTODY = SimpleNamespace(leases=3, held_bytes=36)


class Counters:
    def __init__(self):
        self.calls = []
        self.values = {"active": 100, "cache": 20, "peak": 150, "footprint": 400}

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


def observer(counters, estimate=lambda cache: 7):
    return MemoryObserver(
        active=counters.read("active"),
        cache=counters.read("cache"),
        peak=counters.read("peak"),
        reset_peak=counters.reset,
        footprint=counters.read("footprint"),
        estimate=estimate,
    )


def lines(caplog):
    return [r.getMessage() for r in caplog.records if "tensorfold memory phase=" in r.getMessage()]


@pytest.fixture(autouse=True)
def info_logs(caplog):
    caplog.set_level("INFO", logger="orchard_tensorfold_http.memory_observation")


def test_request_start_samples_before_it_resets_the_peak(caplog):
    counters = Counters()
    observer(counters).request_start(CUSTODY, 2)
    assert counters.calls == ["active", "cache", "peak", "footprint", "reset_peak"]
    assert lines(caplog) == [
        "tensorfold memory phase=request_start seq=1 active=100 cache=20 peak=150 "
        "footprint=400 leases=3 held=36 checkpoints=2 copies=0 copy_bytes_est=0 "
        "max_pass_width=0 pass_cache_raises=0"
    ]


def test_copies_and_prefill_shape_are_summarized_per_request(caplog):
    counters = Counters()
    watch = observer(counters, estimate=lambda cache: len(cache) * 10)
    watch.request_start(CUSTODY, 0)
    watch.copied([1, 2])
    watch.copied([1, 2, 3])
    stream = SimpleNamespace(prefill_widths=[1, 8, 3], prefill_raised=[False, True, True])
    watch.phase("settled_before_release", CUSTODY, 1, stream)
    assert lines(caplog)[-1].endswith(
        "copies=2 copy_bytes_est=50 max_pass_width=8 pass_cache_raises=2"
    )
    watch.request_start(CUSTODY, 1)
    assert "seq=2" in lines(caplog)[-1] and "copies=0 copy_bytes_est=0" in lines(caplog)[-1]


@pytest.mark.parametrize("value", [None, -1, True, 1.5, RuntimeError("no counter")])
def test_unreadable_counters_are_reported_as_unavailable_never_zero(caplog, value):
    counters = Counters()
    counters.values["footprint"] = value
    observer(counters).phase("settled_after_release", CUSTODY, 0)
    assert "footprint=unavailable" in lines(caplog)[0]


def test_failures_never_escape_and_the_peak_is_still_reset(caplog):
    counters = Counters()

    def broken_estimate(cache):
        raise RuntimeError("estimate failed")

    watch = observer(counters, estimate=broken_estimate)
    broken_custody = SimpleNamespace()
    watch.request_start(broken_custody, 0)
    assert counters.calls[-1] == "reset_peak"
    watch.copied([1])
    watch.phase("request_uncertain", CUSTODY, 0, stream=SimpleNamespace(prefill_widths="x"))
    counters.reset = lambda: (_ for _ in ()).throw(RuntimeError("reset failed"))
    observer(counters).request_start(CUSTODY, 0)
    assert lines(caplog)[-1].startswith("tensorfold memory phase=request_start")
