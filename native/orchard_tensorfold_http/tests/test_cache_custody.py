"""Model-free custody checks for the isolated centralized cache-copy seam."""

import gc
import weakref
from threading import Event, Thread

import pytest

from orchard_tensorfold_http.cache_custody import CacheCopyCustody, CacheCustodyError


@pytest.fixture
def guard():
    # Synthetic byte counts exercise boundaries, not approved deployment limits.
    return CacheCopyCustody(total_budget_bytes=100, workspace_bytes=20, max_leases=3)


def copy(guard, *, size=30, transient=10, owner="staged"):
    return guard.copy(
        lambda: ["copied"],
        lambda value: True,
        cache_bytes=size,
        transient_bytes=transient,
        owner=owner,
    )


def fail():
    raise RuntimeError("injected failure")


@pytest.mark.parametrize("size", [None, True, -1, 0, 1.5, float("inf")])
def test_unknown_or_unbounded_copy_size_rejected_before_copy(guard, size):
    called = []
    with pytest.raises(ValueError, match="copy bound"):
        guard.copy(
            lambda: called.append("copy"),
            lambda value: called.append("barrier"),
            cache_bytes=size,
            transient_bytes=0,
            owner="staged",
        )
    assert called == []
    assert guard.snapshot().available_bytes == 80


@pytest.mark.parametrize("transient", [None, False, -1, 0.5, float("inf")])
def test_unknown_transient_bound_rejected_before_copy(guard, transient):
    with pytest.raises(ValueError, match="transient bound"):
        guard.copy(fail, fail, cache_bytes=1, transient_bytes=transient, owner="staged")
    assert guard.snapshot().available_bytes == 80


@pytest.mark.parametrize(
    "options",
    [
        {"total_budget_bytes": 0},
        {"total_budget_bytes": True},
        {"workspace_bytes": -1},
        {"workspace_bytes": 101},
        {"max_leases": 0},
    ],
)
def test_invalid_fixed_envelope_is_rejected(options):
    with pytest.raises(ValueError):
        CacheCopyCustody(
            **{"total_budget_bytes": 100, "workspace_bytes": 20, "max_leases": 3, **options}
        )


def test_oversize_includes_workspace_and_transient_and_does_not_call_provider(guard):
    with pytest.raises(CacheCustodyError, match="exceeds reserved envelope"):
        guard.copy(fail, fail, cache_bytes=70, transient_bytes=11, owner="staged")
    assert guard.snapshot().available_bytes == 80
    lease = copy(guard, size=70, transient=10)
    assert lease.value == ["copied"]
    assert guard.snapshot().available_bytes == 10


def test_staged_retained_and_borrowed_share_one_settled_reservation(guard):
    lease = copy(guard)
    lease.retain("retained")
    lease.retain("borrowed")
    assert guard.snapshot().held_bytes == 30
    lease.dispose("staged")
    lease.dispose("retained")
    assert guard.snapshot().held_bytes == 30
    assert lease.value == ["copied"]
    lease.dispose("borrowed")
    assert guard.snapshot().held_bytes == 0
    assert guard.snapshot().available_bytes == 80
    with pytest.raises(CacheCustodyError, match="disposed"):
        _ = lease.value
    with pytest.raises(CacheCustodyError, match="disposed"):
        lease.retain("staged")
    with pytest.raises(CacheCustodyError, match="disposed"):
        lease.dispose("borrowed")


def test_all_pending_bytes_remain_reserved_through_positive_settlement(guard):
    existing = copy(guard, size=15, transient=0, owner="retained")
    observed = []

    def provider():
        observed.append(guard.snapshot())
        with pytest.raises(CacheCustodyError, match="already in flight"):
            existing.dispose("retained")
        return ["next"]

    def barrier(value):
        assert value == ["next"]
        observed.append(guard.snapshot())
        return True

    lease = guard.copy(provider, barrier, cache_bytes=30, transient_bytes=10, owner="staged")
    for snapshot in observed:
        assert (snapshot.workspace_bytes, snapshot.held_bytes) == (20, 15)
        assert (snapshot.copy_bytes, snapshot.transient_bytes) == (30, 10)
        assert snapshot.available_bytes == 25
    assert lease.value == ["next"]
    assert guard.snapshot().held_bytes == 45
    assert guard.snapshot().transient_bytes == guard.snapshot().copy_bytes == 0


def test_forgotten_lease_does_not_release_on_garbage_collection(guard):
    lease = copy(guard)
    ref = weakref.ref(lease)
    del lease
    gc.collect()
    assert ref() is not None
    assert guard.snapshot().held_bytes == 30
    guard.positive_owned_reap(lambda: True)
    gc.collect()
    assert ref() is None


def test_lease_limit_bounds_state_even_when_bytes_remain(guard):
    for _ in range(3):
        copy(guard, size=1, transient=0)
    with pytest.raises(CacheCustodyError, match="lease limit"):
        copy(guard, size=1, transient=0)
    assert guard.snapshot().leases == 3


def test_owner_categories_are_bounded_and_duplicate_actions_are_rejected(guard):
    with pytest.raises(ValueError, match="unsupported cache owner"):
        copy(guard, owner="unbounded identifier")
    lease = copy(guard)
    with pytest.raises(ValueError, match="unsupported cache owner"):
        lease.retain("other")
    with pytest.raises(CacheCustodyError, match="already holds"):
        lease.retain("staged")
    with pytest.raises(CacheCustodyError, match="does not hold"):
        lease.dispose("borrowed")
    assert guard.snapshot().held_bytes == 30


@pytest.mark.parametrize("error", [RuntimeError("copy failure"), KeyboardInterrupt()])
def test_copy_failure_preserves_custody_until_owned_reap(guard, error):
    settled = copy(guard, size=15, transient=0)

    def failing_copy():
        raise error

    with pytest.raises(type(error)):
        guard.copy(failing_copy, fail, cache_bytes=30, transient_bytes=10, owner="staged")
    snapshot = guard.snapshot()
    assert (snapshot.held_bytes, snapshot.copy_bytes, snapshot.transient_bytes) == (15, 30, 10)
    assert snapshot.quarantined
    assert snapshot.available_bytes == 0
    with pytest.raises(CacheCustodyError, match="unavailable"):
        settled.dispose("staged")
    with pytest.raises(CacheCustodyError, match="unavailable"):
        copy(guard)
    guard.positive_owned_reap(lambda: True)
    snapshot = guard.snapshot()
    assert (snapshot.workspace_bytes, snapshot.held_bytes, snapshot.copy_bytes) == (0, 0, 0)
    assert snapshot.transient_bytes == snapshot.available_bytes == 0
    assert snapshot.reaped


@pytest.mark.parametrize("settlement", [False, None, 1, "yes"])
def test_nonpositive_settlement_retains_result_and_reservations(guard, settlement):
    class Cache:
        pass

    value = Cache()
    ref = weakref.ref(value)
    with pytest.raises(CacheCustodyError, match="settlement was not confirmed"):
        guard.copy(
            lambda cache=value: cache,
            lambda result: settlement,
            cache_bytes=30,
            transient_bytes=10,
            owner="staged",
        )
    del value
    gc.collect()
    assert ref() is not None
    assert guard.snapshot().leases == 0
    assert guard.snapshot().copy_bytes == 30
    assert guard.snapshot().transient_bytes == 10
    assert guard.snapshot().available_bytes == 0
    guard.positive_owned_reap(lambda: True)
    gc.collect()
    assert ref() is None


def test_settlement_exception_quarantines_without_publishing_lease(guard):
    def barrier(value):
        fail()

    with pytest.raises(RuntimeError, match="injected failure"):
        guard.copy(lambda: [], barrier, cache_bytes=30, transient_bytes=10, owner="staged")
    assert guard.snapshot().quarantined
    assert guard.snapshot().leases == 0
    assert guard.snapshot().copy_bytes == 30


def test_missing_copy_result_quarantines_before_barrier_or_publication(guard):
    called = []
    with pytest.raises(CacheCustodyError, match="returned no value"):
        guard.copy(
            lambda: None,
            lambda value: called.append("barrier"),
            cache_bytes=30,
            transient_bytes=10,
            owner="staged",
        )
    assert called == []
    snapshot = guard.snapshot()
    assert snapshot.quarantined
    assert (snapshot.leases, snapshot.copy_bytes, snapshot.transient_bytes) == (0, 30, 10)


@pytest.mark.parametrize("proof", [lambda: False, lambda: None, fail])
@pytest.mark.parametrize("pending", [False, True])
def test_unconfirmed_reaping_preserves_held_pending_and_workspace(guard, proof, pending):
    lease = copy(guard)
    if pending:
        with pytest.raises(RuntimeError, match="injected failure"):
            guard.copy(fail, fail, cache_bytes=30, transient_bytes=10, owner="staged")
    before = guard.snapshot()
    with pytest.raises((CacheCustodyError, RuntimeError)):
        guard.positive_owned_reap(proof)
    snapshot = guard.snapshot()
    assert snapshot.quarantined
    assert snapshot.held_bytes == before.held_bytes
    assert snapshot.copy_bytes == before.copy_bytes
    assert snapshot.transient_bytes == before.transient_bytes
    assert snapshot.workspace_bytes == before.workspace_bytes
    assert snapshot.available_bytes == 0
    with pytest.raises(CacheCustodyError, match="unavailable"):
        _ = lease.value
    guard.positive_owned_reap(lambda: True)
    with pytest.raises(CacheCustodyError, match="unavailable"):
        lease.retain("borrowed")
    with pytest.raises(CacheCustodyError, match="already reaped"):
        guard.positive_owned_reap(fail)


def test_copy_admission_is_c1_and_does_not_queue(guard):
    def provider():
        with pytest.raises(CacheCustodyError, match="already in flight"):
            copy(guard)
        return ["only"]

    lease = guard.copy(
        provider, lambda value: True, cache_bytes=30, transient_bytes=10, owner="staged"
    )
    assert lease.value == ["only"]
    assert not guard.snapshot().quarantined


@pytest.mark.parametrize("phase", ["copy", "settlement"])
def test_owned_reaping_during_copy_or_barrier_cannot_be_undone_by_late_completion(guard, phase):
    entered, finish = Event(), Event()
    errors = []

    def wait():
        entered.set()
        assert finish.wait(2)

    def provider():
        if phase == "copy":
            wait()
        return ["late"]

    def barrier(value):
        if phase == "settlement":
            wait()
        return True

    def run():
        try:
            guard.copy(provider, barrier, cache_bytes=30, transient_bytes=10, owner="staged")
        except CacheCustodyError as error:
            errors.append(error)

    worker = Thread(target=run)
    worker.start()
    try:
        assert entered.wait(2)
        guard.positive_owned_reap(lambda: True)
    finally:
        finish.set()
        worker.join(2)
    assert not worker.is_alive()
    assert len(errors) == 1
    assert str(errors[0]) == "cache custody is unavailable"
    snapshot = guard.snapshot()
    assert snapshot.reaped
    assert (snapshot.leases, snapshot.copy_bytes, snapshot.transient_bytes) == (0, 0, 0)
    assert snapshot.available_bytes == 0
    with pytest.raises(CacheCustodyError, match="unavailable"):
        copy(guard)


def test_reentrant_owned_reap_is_rejected_without_releasing_before_proof(guard):
    copy(guard)

    def proof():
        with pytest.raises(CacheCustodyError, match="reaping is already in flight"):
            guard.positive_owned_reap(fail)
        assert guard.snapshot().held_bytes == 30
        return True

    guard.positive_owned_reap(proof)
    assert guard.snapshot().reaped


def test_copy_return_during_unconfirmed_reaping_retains_result_until_positive_reap(guard):
    class Cache:
        pass

    copy_entered, copy_finish, proof_entered, proof_finish = (Event() for _ in range(4))
    refs, errors = [], []

    def provider():
        value = Cache()
        refs.append(weakref.ref(value))
        copy_entered.set()
        assert copy_finish.wait(2)
        return value

    def proof():
        proof_entered.set()
        assert proof_finish.wait(2)
        return False

    def run_copy():
        try:
            guard.copy(
                provider, lambda value: True, cache_bytes=30, transient_bytes=10, owner="staged"
            )
        except CacheCustodyError as error:
            errors.append(str(error))

    def run_reap():
        try:
            guard.positive_owned_reap(proof)
        except CacheCustodyError as error:
            errors.append(str(error))

    copier, reaper = Thread(target=run_copy), Thread(target=run_reap)
    copier.start()
    try:
        assert copy_entered.wait(2)
        reaper.start()
        assert proof_entered.wait(2)
        copy_finish.set()
        copier.join(2)
        assert not copier.is_alive()
        gc.collect()
        assert refs[0]() is not None
    finally:
        copy_finish.set()
        proof_finish.set()
        copier.join(2)
        if reaper.ident is not None:
            reaper.join(2)
    assert not reaper.is_alive()
    assert sorted(errors) == sorted(
        ["cache custody is unavailable", "owned process reaping was not confirmed"]
    )
    gc.collect()
    assert refs[0]() is not None
    snapshot = guard.snapshot()
    assert snapshot.quarantined
    assert (snapshot.leases, snapshot.copy_bytes, snapshot.transient_bytes) == (0, 30, 10)
    guard.positive_owned_reap(lambda: True)
    gc.collect()
    assert refs[0]() is None
