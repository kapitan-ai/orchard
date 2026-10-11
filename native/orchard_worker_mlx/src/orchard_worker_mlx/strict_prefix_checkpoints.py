"""Strict-prefix checkpoint reuse for hybrid MLX prompt caches.

The trim-based caches in ``prefix_cache.py`` need a trimmable prompt cache.  A
hybrid cache, such as one with ``KVCache`` full-attention layers and
``ArraysCache`` linear-attention layers (convolution history plus recurrent
state), cannot be trimmed, so the loader turns those caches off for it.  This
module reuses a checkpoint only when its token key is a strictly shorter,
exact prefix of the request.  No cache state is ever truncated.

Capture point (held pin mlx-lm 0.31.3, ``generate_step``):
    Each prefill chunk runs ``mx.eval([c.state for c in prompt_cache])`` and
    then calls ``prompt_progress_callback(processed, total)`` with
    ``processed < total``.  That intermediate callback is the only capture
    point.  The final ``(total, total)`` callback runs after the first sampled
    token went through the lookahead step, so the cache already holds one
    generated token and is never captured.

Boundary choice:
    One checkpoint per request, at the last prefill chunk boundary at or before
    the last reply marker (the assistant reply prompt).  Boundaries are
    absolute multiples of the prefill step, so a request restored from a
    checkpoint prefills its suffix in the same chunks as an uncached request.

Ownership and memory:
    Each slot charges a fixed ``slot_bytes`` against the configured budget.  A
    capture reserves its slot before it copies, measures the source cache from
    array metadata before the copy, deep-copies, and only then retains the
    snapshot.  A copy that fails leaves its reservation held as ``uncertain``
    until the store is cleared at unload.  A restore deep-copies the retained
    snapshot while the slot is borrowed, so it cannot be evicted mid-copy.

This module uses only the standard library, like ``prefix_cache.py``.
"""

from __future__ import annotations

import copy
import logging
import threading
from collections.abc import Callable, Iterator, Sequence
from dataclasses import dataclass
from typing import Any

logger = logging.getLogger(__name__)

SUPPORTED_MLX_LM_VERSION = "0.31.3"
SUPPORTED_LAYER_TYPES = frozenset({"KVCache", "ArraysCache"})
DEFAULT_REPLY_MARKER = "<|im_start|>assistant"
MAX_SLOTS = 8

_STAGED = "staged"
_RETAINED = "retained"
_UNCERTAIN = "uncertain"

LOOKUP_HIT = "hit"
LOOKUP_MISS = "miss"
LOOKUP_RESTORE_FAILED = "restore_failed"

CAPTURE_STORED = "stored"
CAPTURE_NOT_REACHED = "not_reached"
CAPTURE_SKIPPED_EMPTY_KEY = "skipped_empty_key"
CAPTURE_SKIPPED_UNMEASURABLE = "skipped_unmeasurable"
CAPTURE_SKIPPED_OVERSIZE = "skipped_oversize"
CAPTURE_SKIPPED_NO_SLOT = "skipped_no_slot"
CAPTURE_COPY_FAILED = "copy_failed"
CAPTURE_FAILED = "capture_failed"


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _require_positive_int(name: str, value: Any) -> None:
    if not _is_int(value):
        raise ValueError(f"{name} must be int, got {type(value).__name__}")
    if value < 1:
        raise ValueError(f"{name} must be >= 1, got {value}")


@dataclass(slots=True, frozen=True)
class StrictPrefixCheckpointConfig:
    """Process-scoped settings for strict-prefix checkpoint reuse.

    The budget must hold every configured slot at its full charge, so a
    configuration that could not retain ``slots`` checkpoints is refused at
    startup instead of failing captures later.
    """

    slots: int = 1
    slot_bytes: int = 0
    budget_bytes: int = 0
    reply_marker: str = DEFAULT_REPLY_MARKER

    def __post_init__(self) -> None:
        _require_positive_int("slots", self.slots)
        if self.slots > MAX_SLOTS:
            raise ValueError(f"slots must be <= {MAX_SLOTS}, got {self.slots}")
        _require_positive_int("slot_bytes", self.slot_bytes)
        _require_positive_int("budget_bytes", self.budget_bytes)
        if self.slots * self.slot_bytes > self.budget_bytes:
            raise ValueError(
                f"budget_bytes {self.budget_bytes} cannot hold {self.slots} slots of "
                f"{self.slot_bytes} bytes"
            )
        if not isinstance(self.reply_marker, str) or not self.reply_marker:
            raise ValueError("reply_marker must be a non-empty string")


@dataclass(slots=True, frozen=True)
class CheckpointIdentity:
    """Execution identity a checkpoint is valid for.

    Cache state formats differ between mlx-lm releases, so the identity names
    the exact runtime versions and the prefill step that set chunk boundaries.
    """

    model_id: str
    model_version: str
    artifact_sha256: str | None
    mlx_version: str
    mlx_lm_version: str
    prefill_step_size: int
    layer_types: tuple[str, ...]


@dataclass(slots=True)
class StrictPrefixLookup:
    """Outcome of a strict-prefix lookup."""

    status: str
    prompt_cache: Any = None
    matched_length: int = 0
    remaining_ids: list[int] | None = None


@dataclass(slots=True, frozen=True)
class CaptureOutcome:
    """Outcome of one capture attempt."""

    status: str
    snapshot_bytes: int = 0


@dataclass(slots=True, frozen=True)
class StrictPrefixCheckpointStats:
    """Immutable snapshot of store state and cumulative counters."""

    slots: int
    slot_bytes: int
    retained: int
    staged: int
    uncertain: int
    reserved_bytes: int
    retained_snapshot_bytes: int
    hits: int
    misses: int
    restore_failures: int
    stores: int
    copy_failures: int
    skipped_oversize: int
    skipped_no_slot: int
    evictions: int


@dataclass(slots=True)
class _Slot:
    key: tuple[int, ...]
    state: str
    snapshot: Any = None
    snapshot_bytes: int = 0
    borrowed: bool = False
    last_used: int = 0


def measure_snapshot_bytes(prompt_cache: Any) -> int:
    """Return the bytes a deep copy of *prompt_cache* would hold.

    Reads each layer's ``nbytes`` from array metadata without copying.  For
    mlx-lm 0.31.3 ``KVCache`` this is the full key and value buffers, and for
    ``ArraysCache`` the convolution and recurrent state arrays.
    """
    total = 0
    for layer in prompt_cache:
        nbytes = layer.nbytes
        if not _is_int(nbytes) or nbytes < 0:
            raise ValueError(f"layer nbytes must be a non-negative int, got {nbytes!r}")
        total += nbytes
    return total


def snapshot_arrays(prompt_cache: Any) -> list[Any]:
    """Return the state arrays of every layer, for materialising a copy."""
    arrays: list[Any] = []
    for layer in prompt_cache:
        arrays.extend(item for item in _flatten(layer.state) if item is not None)
    return arrays


def _flatten(value: Any) -> Iterator[Any]:
    if isinstance(value, list | tuple):
        for item in value:
            yield from _flatten(item)
    else:
        yield value


def last_occurrence(token_ids: Sequence[int], marker_ids: Sequence[int]) -> int | None:
    """Return the start index of the last occurrence of *marker_ids*."""
    width = len(marker_ids)
    if width == 0:
        return None
    marker = list(marker_ids)
    first = marker[0]
    for start in range(len(token_ids) - width, -1, -1):
        if token_ids[start] == first and list(token_ids[start : start + width]) == marker:
            return start
    return None


def capture_boundary(
    prompt_ids: Sequence[int],
    *,
    matched_length: int,
    prefill_step_size: int,
    reply_marker_ids: Sequence[int],
) -> int | None:
    """Choose the absolute token boundary to checkpoint for this request.

    The boundary is the last multiple of *prefill_step_size* at or before the
    last reply marker.  ``None`` means no new checkpoint: the marker is absent,
    the boundary is not past the restored prefix, or the restored prefix is
    not chunk-aligned.
    """
    if prefill_step_size < 1 or matched_length % prefill_step_size != 0:
        return None
    reply_start = last_occurrence(prompt_ids, reply_marker_ids)
    if reply_start is None:
        return None
    boundary = (reply_start // prefill_step_size) * prefill_step_size
    if boundary <= matched_length:
        return None
    return boundary


class StrictPrefixCheckpointStore:
    """Fixed-slot store of deep-copied prompt-cache checkpoints.

    Keys are exact token prefixes.  Lookup returns a deep copy of the longest
    retained key that is a strictly shorter prefix of the query, so the
    caller always has a non-empty suffix to prefill and nothing is trimmed.
    """

    def __init__(
        self,
        *,
        identity: CheckpointIdentity,
        slots: int,
        slot_bytes: int,
        reply_marker_ids: Sequence[int],
        materialize: Callable[[list[Any]], Any] | None = None,
    ) -> None:
        _require_positive_int("slots", slots)
        _require_positive_int("slot_bytes", slot_bytes)
        marker = tuple(reply_marker_ids)
        if not marker or not all(_is_int(token) for token in marker):
            raise ValueError("reply_marker_ids must be a non-empty sequence of ints")
        self._identity = identity
        self._max_slots = slots
        self._slot_bytes = slot_bytes
        self._reply_marker_ids = marker
        self._materialize = materialize
        self._lock = threading.Lock()
        self._slots: list[_Slot] = []
        self._clock = 0
        self._hits = 0
        self._misses = 0
        self._restore_failures = 0
        self._stores = 0
        self._copy_failures = 0
        self._skipped_oversize = 0
        self._skipped_no_slot = 0
        self._evictions = 0

    @property
    def identity(self) -> CheckpointIdentity:
        return self._identity

    @property
    def reply_marker_ids(self) -> tuple[int, ...]:
        return self._reply_marker_ids

    def lookup(self, token_ids: Sequence[int]) -> StrictPrefixLookup:
        """Restore the longest retained strictly shorter exact prefix."""
        query = tuple(token_ids)
        with self._lock:
            best: _Slot | None = None
            for slot in self._slots:
                width = len(slot.key)
                if slot.state != _RETAINED or width >= len(query):
                    continue
                if query[:width] != slot.key:
                    continue
                if best is None or width > len(best.key):
                    best = slot
            if best is None:
                self._misses += 1
                return StrictPrefixLookup(status=LOOKUP_MISS)
            best.borrowed = True
            snapshot = best.snapshot

        try:
            restored = copy.deepcopy(snapshot)
        except Exception:
            logger.warning("strict_prefix_checkpoint restore copy failed", exc_info=True)
            with self._lock:
                best.borrowed = False
                self._restore_failures += 1
            return StrictPrefixLookup(status=LOOKUP_RESTORE_FAILED)

        width = len(best.key)
        with self._lock:
            best.borrowed = False
            best.last_used = self._tick_locked()
            self._hits += 1
        return StrictPrefixLookup(
            status=LOOKUP_HIT,
            prompt_cache=restored,
            matched_length=width,
            remaining_ids=list(query[width:]),
        )

    def capture(self, key: Sequence[int], prompt_cache: Any) -> CaptureOutcome:
        """Reserve a slot, then deep-copy *prompt_cache* into it."""
        frozen_key = tuple(key)
        if not frozen_key:
            return CaptureOutcome(status=CAPTURE_SKIPPED_EMPTY_KEY)
        try:
            snapshot_bytes = measure_snapshot_bytes(prompt_cache)
        except Exception:
            logger.warning("strict_prefix_checkpoint measure failed", exc_info=True)
            return CaptureOutcome(status=CAPTURE_SKIPPED_UNMEASURABLE)

        with self._lock:
            if snapshot_bytes > self._slot_bytes:
                self._skipped_oversize += 1
                return CaptureOutcome(CAPTURE_SKIPPED_OVERSIZE, snapshot_bytes)
            slot = self._reserve_locked(frozen_key)
            if slot is None:
                self._skipped_no_slot += 1
                return CaptureOutcome(CAPTURE_SKIPPED_NO_SLOT, snapshot_bytes)

        try:
            snapshot = copy.deepcopy(prompt_cache)
            if self._materialize is not None:
                self._materialize(snapshot_arrays(snapshot))
        except Exception:
            # The copy may hold memory we cannot account for, so the slot stays
            # charged until the store is cleared.
            logger.warning(
                "strict_prefix_checkpoint copy failed; slot stays reserved as uncertain",
                exc_info=True,
            )
            with self._lock:
                slot.state = _UNCERTAIN
                self._copy_failures += 1
            return CaptureOutcome(CAPTURE_COPY_FAILED, snapshot_bytes)

        with self._lock:
            slot.snapshot = snapshot
            slot.snapshot_bytes = snapshot_bytes
            slot.state = _RETAINED
            slot.last_used = self._tick_locked()
            self._stores += 1
        return CaptureOutcome(CAPTURE_STORED, snapshot_bytes)

    def stats(self) -> StrictPrefixCheckpointStats:
        with self._lock:
            counts = {_STAGED: 0, _RETAINED: 0, _UNCERTAIN: 0}
            for slot in self._slots:
                counts[slot.state] += 1
            return StrictPrefixCheckpointStats(
                slots=self._max_slots,
                slot_bytes=self._slot_bytes,
                retained=counts[_RETAINED],
                staged=counts[_STAGED],
                uncertain=counts[_UNCERTAIN],
                reserved_bytes=len(self._slots) * self._slot_bytes,
                retained_snapshot_bytes=sum(
                    slot.snapshot_bytes for slot in self._slots if slot.state == _RETAINED
                ),
                hits=self._hits,
                misses=self._misses,
                restore_failures=self._restore_failures,
                stores=self._stores,
                copy_failures=self._copy_failures,
                skipped_oversize=self._skipped_oversize,
                skipped_no_slot=self._skipped_no_slot,
                evictions=self._evictions,
            )

    def clear(self) -> None:
        """Drop every slot, including uncertain ones.  Called at unload."""
        with self._lock:
            self._slots.clear()

    def _tick_locked(self) -> int:
        self._clock += 1
        return self._clock

    def _reserve_locked(self, key: tuple[int, ...]) -> _Slot | None:
        replaced = next(
            (
                slot
                for slot in self._slots
                if slot.key == key and slot.state == _RETAINED and not slot.borrowed
            ),
            None,
        )
        if replaced is not None:
            self._slots.remove(replaced)
        elif len(self._slots) >= self._max_slots:
            victims = [
                slot for slot in self._slots if slot.state == _RETAINED and not slot.borrowed
            ]
            if not victims:
                return None
            victim = min(victims, key=lambda slot: slot.last_used)
            self._slots.remove(victim)
            self._evictions += 1
        slot = _Slot(key=key, state=_STAGED)
        self._slots.append(slot)
        return slot


class CaptureHook:
    """``prompt_progress_callback`` wrapper that captures one checkpoint.

    It captures when the intermediate callback reports exactly the target
    number of processed suffix tokens, then forwards every call unchanged.
    A callback with ``processed >= total`` is the final one and disarms it.
    """

    def __init__(
        self,
        *,
        store: StrictPrefixCheckpointStore,
        prompt_cache: Any,
        prompt_ids: Sequence[int],
        matched_length: int,
        boundary: int,
        forward: Callable[[int, int], None],
    ) -> None:
        if not matched_length < boundary <= len(prompt_ids):
            raise ValueError(
                f"boundary {boundary} must be past matched_length {matched_length} "
                f"and within {len(prompt_ids)} prompt tokens"
            )
        self._store = store
        self._prompt_cache = prompt_cache
        self._key = tuple(prompt_ids[:boundary])
        self._target_processed = boundary - matched_length
        self._forward = forward
        self._armed = True
        self.boundary = boundary
        self.outcome = CaptureOutcome(status=CAPTURE_NOT_REACHED)

    def __call__(self, processed: int, total: int) -> None:
        try:
            self._maybe_capture(processed, total)
        finally:
            self._forward(processed, total)

    def _maybe_capture(self, processed: int, total: int) -> None:
        if not self._armed or not _is_int(processed) or not _is_int(total):
            return
        if processed >= total:
            self._armed = False
            return
        if processed != self._target_processed:
            return
        self._armed = False
        try:
            self.outcome = self._store.capture(self._key, self._prompt_cache)
        except Exception:
            logger.warning("strict_prefix_checkpoint capture failed", exc_info=True)
            self.outcome = CaptureOutcome(status=CAPTURE_FAILED)
