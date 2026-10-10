"""Experiment-only KAP-128 A/B memory switches. Not for merge."""

from unittest.mock import Mock

import pytest
from test_driver_memory_observation import Recorder, make_driver, run
from test_tensorfold_driver import bounds as bounds
from test_tensorfold_driver import receipt as receipt

from orchard_tensorfold_http.memory_ab import (
    CACHE_LIMIT_ENV,
    CLEAR_ENV,
    MEMORY_LIMIT_ENV,
    MemorySwitches,
    apply_switches,
    read_switches,
)


def test_unset_switches_keep_todays_behavior():
    mx = Mock()
    switches = read_switches({})
    assert switches == MemorySwitches()
    apply_switches(mx, switches)
    mx.set_cache_limit.assert_not_called()
    mx.set_memory_limit.assert_not_called()


def test_switches_set_limits_before_load():
    mx = Mock()
    switches = read_switches(
        {CACHE_LIMIT_ENV: "17179869184", MEMORY_LIMIT_ENV: "103079215104", CLEAR_ENV: "1"}
    )
    apply_switches(mx, switches)
    mx.set_cache_limit.assert_called_once_with(17179869184)
    mx.set_memory_limit.assert_called_once_with(103079215104)
    assert switches.clear_after_release


@pytest.mark.parametrize(
    "environ",
    [
        {CACHE_LIMIT_ENV: "0"},
        {MEMORY_LIMIT_ENV: "-1"},
        {CACHE_LIMIT_ENV: "16G"},
        {CLEAR_ENV: "yes"},
    ],
)
def test_invalid_switches_refuse_startup(environ):
    with pytest.raises(ValueError):
        read_switches(environ)


def test_clear_after_release_runs_after_release_and_is_sampled(bounds, receipt):
    order = []

    class Ordered(Recorder):
        def phase(self, name, custody, checkpoints, stream=None):
            order.append(name)
            super().phase(name, custody, checkpoints, stream)

    driver = make_driver(bounds, receipt, Ordered())
    driver._after_release = lambda: order.append("clear")
    assert run(driver) == [[6, 7]]
    assert order[-3:] == ["settled_after_release", "clear", "settled_after_clear"]
