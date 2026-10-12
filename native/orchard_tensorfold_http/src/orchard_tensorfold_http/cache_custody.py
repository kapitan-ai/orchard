"""Explicit copy custody for an isolated TensorFold ``copy_single_cache`` hook.

The caller must supply conservative bounds for a known cache implementation,
including allocation while copying. This primitive does not size working KV or
workspace, install a live engine hook, or establish a physical memory limit.
"""

from collections.abc import Callable
from dataclasses import dataclass
from threading import Lock
from typing import Generic, Literal, TypeVar

CacheOwner = Literal["staged", "retained", "borrowed"]
_OWNERS = frozenset({"staged", "retained", "borrowed"})
T = TypeVar("T")


class CacheCustodyError(RuntimeError):
    """A copy cannot be admitted or its custody cannot be established."""


def _bytes(value: int, name: str, *, positive: bool = False) -> int:
    if type(value) is not int or value < int(positive):
        raise ValueError(
            f"{name} must be a bounded {'positive' if positive else 'nonnegative'} integer"
        )
    return value


def _owner(value: CacheOwner) -> CacheOwner:
    if value not in _OWNERS:
        raise ValueError("unsupported cache owner")
    return value


@dataclass(frozen=True)
class CacheCustodySnapshot:
    workspace_bytes: int
    held_bytes: int
    copy_bytes: int
    transient_bytes: int
    available_bytes: int
    leases: int
    quarantined: bool
    reaped: bool


class CacheLease(Generic[T]):
    """One settled cache reservation shared by explicit C1 custody categories.

    Disposing an owner asserts it has relinquished all references and uses of
    the cache. Garbage collection never disposes a reservation.
    """

    def __init__(self, guard: "CacheCopyCustody[T]", value: T, size: int, owner: CacheOwner):
        self._guard = guard
        self._value: T | None = value
        self._size = size
        self._owners = {_owner(owner)}

    @property
    def value(self) -> T:
        return self._guard._value(self)

    def retain(self, owner: CacheOwner) -> None:
        self._guard._retain(self, _owner(owner))

    def dispose(self, owner: CacheOwner) -> None:
        self._guard._dispose(self, _owner(owner))


@dataclass
class _CopyReservation(Generic[T]):
    cache_bytes: int
    transient_bytes: int
    value: T | None = None


class CacheCopyCustody(Generic[T]):
    """A bounded C1 copy ledger for one immutable owned child incarnation.

    Settlement callbacks must positively confirm completion of native copy
    work. Failure retains every reservation and result until owned reaping is
    positively confirmed. A reaped ledger cannot serve another incarnation.
    """

    def __init__(self, *, total_budget_bytes: int, workspace_bytes: int, max_leases: int):
        self._budget = _bytes(total_budget_bytes, "total budget", positive=True)
        self._workspace = _bytes(workspace_bytes, "workspace reservation")
        self._max_leases = _bytes(max_leases, "maximum leases", positive=True)
        if self._workspace > self._budget:
            raise ValueError("workspace reservation exceeds total budget")
        self._lock = Lock()
        self._leases: set[CacheLease[T]] = set()
        self._pending: _CopyReservation[T] | None = None
        self._quarantined = False
        self._reaped = False
        self._reaping = False

    def _require_available(self) -> None:
        if self._quarantined or self._reaped:
            raise CacheCustodyError("cache custody is unavailable")

    def _reserved(self) -> int:
        pending = self._pending
        return (
            self._workspace
            + sum(lease._size for lease in self._leases)
            + (0 if pending is None else pending.cache_bytes + pending.transient_bytes)
        )

    def snapshot(self) -> CacheCustodySnapshot:
        with self._lock:
            pending = self._pending
            return CacheCustodySnapshot(
                workspace_bytes=self._workspace,
                held_bytes=sum(lease._size for lease in self._leases),
                copy_bytes=0 if pending is None else pending.cache_bytes,
                transient_bytes=0 if pending is None else pending.transient_bytes,
                available_bytes=(
                    0 if self._quarantined or self._reaped else self._budget - self._reserved()
                ),
                leases=len(self._leases),
                quarantined=self._quarantined,
                reaped=self._reaped,
            )

    def copy(
        self,
        copy_call: Callable[[], T],
        settlement_barrier: Callable[[T], bool],
        *,
        cache_bytes: int,
        transient_bytes: int,
        owner: CacheOwner,
    ) -> CacheLease[T]:
        """Reserve before calling the centralized copy seam; never queue a copy."""
        size = _bytes(cache_bytes, "copy bound", positive=True)
        transient = _bytes(transient_bytes, "transient bound")
        owner = _owner(owner)
        with self._lock:
            self._require_available()
            if self._pending is not None:
                raise CacheCustodyError("a cache copy is already in flight")
            if len(self._leases) >= self._max_leases:
                raise CacheCustodyError("cache lease limit exceeded")
            if self._reserved() + size + transient > self._budget:
                raise CacheCustodyError("cache copy exceeds reserved envelope")
            pending = self._pending = _CopyReservation[T](size, transient)
        try:
            value = copy_call()
            with self._lock:
                if not self._reaped and self._pending is pending:
                    pending.value = value
                self._require_available()
            if value is None:
                raise CacheCustodyError("cache copy returned no value")
            if settlement_barrier(value) is not True:
                raise CacheCustodyError("native copy settlement was not confirmed")
            with self._lock:
                self._require_available()
                lease = CacheLease(self, value, size, owner)
                self._leases.add(lease)
                self._pending = None
                return lease
        except BaseException:
            # An interrupted copy may still own native work and allocations.
            with self._lock:
                self._quarantined = True
            raise

    def _require_lease(self, lease: CacheLease[T]) -> None:
        self._require_available()
        if lease not in self._leases:
            raise CacheCustodyError("cache lease is disposed")

    def _value(self, lease: CacheLease[T]) -> T:
        with self._lock:
            self._require_lease(lease)
            # None is not a supported copied cache value.
            if lease._value is None:
                raise CacheCustodyError("cache copy returned no value")
            return lease._value

    def _retain(self, lease: CacheLease[T], owner: CacheOwner) -> None:
        with self._lock:
            self._require_lease(lease)
            if owner in lease._owners:
                raise CacheCustodyError("cache owner already holds this lease")
            lease._owners.add(owner)

    def _dispose(self, lease: CacheLease[T], owner: CacheOwner) -> None:
        with self._lock:
            self._require_lease(lease)
            if owner not in lease._owners:
                raise CacheCustodyError("cache owner does not hold this lease")
            if self._pending is not None:
                raise CacheCustodyError("a cache copy is already in flight")
            lease._owners.remove(owner)
            if not lease._owners:
                self._leases.remove(lease)
                lease._value = None

    def positive_owned_reap(self, confirm_owned_reap: Callable[[], bool]) -> None:
        """Clear custody only after ownership-specific process reaping succeeds."""
        with self._lock:
            if self._reaped:
                raise CacheCustodyError("owned incarnation was already reaped")
            if self._reaping:
                raise CacheCustodyError("owned process reaping is already in flight")
            self._quarantined = True
            self._reaping = True
        try:
            if confirm_owned_reap() is not True:
                raise CacheCustodyError("owned process reaping was not confirmed")
        except BaseException:
            with self._lock:
                self._reaping = False
            raise
        with self._lock:
            for lease in self._leases:
                lease._value = None
                lease._owners.clear()
            self._leases.clear()
            self._pending = None
            self._workspace = 0
            self._reaped = True
            self._reaping = False
