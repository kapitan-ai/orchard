"""Model-free tests for strict-prefix checkpoint reuse on hybrid prompt caches.

The fakes mirror the mlx-lm 0.31.3 shapes that matter here: ``KVCache``
appends keys per token, and ``ArraysCache`` keeps a short convolution history
plus a recurrent state that folds in every token.  Both mutate in place, so a
shallow copy would leak later mutation into a retained checkpoint.
"""

from __future__ import annotations

import copy
import threading
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from types import SimpleNamespace
from typing import Any
from unittest.mock import MagicMock

import pytest

from orchard_worker_mlx.generation import GenerationDeps, generate_events
from orchard_worker_mlx.strict_prefix_checkpoints import (
    CAPTURE_COPY_FAILED,
    CAPTURE_FAILED,
    CAPTURE_NOT_REACHED,
    CAPTURE_SKIPPED_NO_SLOT,
    CAPTURE_SKIPPED_OVERSIZE,
    CAPTURE_SKIPPED_UNMEASURABLE,
    CAPTURE_STORED,
    LOOKUP_HIT,
    LOOKUP_MISS,
    LOOKUP_RESTORE_FAILED,
    CaptureHook,
    CheckpointIdentity,
    StrictPrefixCheckpointConfig,
    StrictPrefixCheckpointStore,
    capture_boundary,
    last_occurrence,
    measure_snapshot_bytes,
    snapshot_arrays,
)

STEP = 4
MARKER = (90, 91)
GENERATED_TOKEN = 77
SLOT_BYTES = 10_000


# ---------------------------------------------------------------------------
# Hybrid cache fakes
# ---------------------------------------------------------------------------


class _Array:
    """Mutable stand-in for an MLX array."""

    def __init__(self, values: list[int] | None = None) -> None:
        self.values = list(values or [])

    def __eq__(self, other: object) -> bool:
        return isinstance(other, _Array) and self.values == other.values

    __hash__ = None  # type: ignore[assignment]

    def __repr__(self) -> str:
        return f"_Array({self.values})"


class KVCache:
    """Full-attention layer: one key and one value per consumed token."""

    def __init__(self) -> None:
        self.keys = _Array()
        self.values = _Array()

    def feed(self, tokens: list[int]) -> None:
        self.keys.values.extend(tokens)
        self.values.values.extend(-token for token in tokens)

    @property
    def nbytes(self) -> int:
        return 16 * len(self.keys.values)

    @property
    def state(self) -> tuple[_Array, _Array]:
        return (self.keys, self.values)


class ArraysCache:
    """Linear-attention layer: convolution history plus recurrent state."""

    def __init__(self) -> None:
        self.cache = [_Array(), _Array([0])]

    def feed(self, tokens: list[int]) -> None:
        conv, recurrent = (array.values for array in self.cache)
        conv.extend(tokens)
        del conv[:-3]
        for token in tokens:
            recurrent[0] = (recurrent[0] * 31 + token) % 1_000_003

    @property
    def nbytes(self) -> int:
        return 64

    @property
    def state(self) -> list[_Array]:
        return self.cache


def _make_hybrid_cache(_model: Any = None) -> list[Any]:
    return [ArraysCache(), ArraysCache(), ArraysCache(), KVCache()]


def _feed(prompt_cache: list[Any], tokens: list[int]) -> None:
    for layer in prompt_cache:
        layer.feed(tokens)


def _state(prompt_cache: list[Any]) -> list[Any]:
    return [copy.deepcopy(layer.state) for layer in prompt_cache]


def _reference_state(tokens: list[int]) -> list[Any]:
    cache = _make_hybrid_cache()
    _feed(cache, tokens)
    return _state(cache)


@dataclass
class _Response:
    text: str
    token: int
    finish_reason: str | None = None


class _FaithfulStream:
    """Mirror of mlx-lm 0.31.3 ``generate_step`` prefill and lookahead order."""

    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []
        self.callback_log: list[tuple[int, int, list[Any]]] = []

    def __call__(
        self,
        _model: Any,
        _tokenizer: Any,
        prompt_ids: list[int],
        **kwargs: Any,
    ) -> Iterator[_Response]:
        self.calls.append({"prompt_ids": list(prompt_ids), **kwargs})
        prompt_cache = kwargs["prompt_cache"]
        step = kwargs["prefill_step_size"]
        callback = kwargs["prompt_progress_callback"]

        def report(processed: int, total: int) -> None:
            self.callback_log.append((processed, total, _state(prompt_cache)))
            callback(processed, total)

        prompt = list(prompt_ids)
        total = len(prompt)
        processed = 0
        report(processed, total)
        while total - processed > 1:
            n = min(step, total - processed - 1)
            _feed(prompt_cache, prompt[:n])
            processed += n
            report(processed, total)
            prompt = prompt[n:]
        _feed(prompt_cache, prompt)
        # Lookahead: the first sampled token goes through the model before the
        # final callback, exactly like ``_step(y)`` in generate_step.
        _feed(prompt_cache, [GENERATED_TOKEN])
        report(total, total)
        yield _Response(text="ok", token=GENERATED_TOKEN, finish_reason="stop")


# ---------------------------------------------------------------------------
# Builders
# ---------------------------------------------------------------------------


def _identity(step: int = STEP) -> CheckpointIdentity:
    return CheckpointIdentity(
        model_id="test-org/hybrid",
        model_version="v1",
        artifact_sha256=None,
        mlx_version="0.31.2",
        mlx_lm_version="0.31.3",
        mlx_lm_commit="ab1806e8f5d6aa035973af194a1b9198ab4754dc",
        prefill_step_size=step,
        layer_types=("ArraysCache", "ArraysCache", "ArraysCache", "KVCache"),
    )


def _store(
    *,
    slots: int = 1,
    slot_bytes: int = SLOT_BYTES,
    materialize: Callable[[list[Any]], Any] | None = None,
) -> StrictPrefixCheckpointStore:
    return StrictPrefixCheckpointStore(
        identity=_identity(),
        slots=slots,
        slot_bytes=slot_bytes,
        reply_marker_ids=MARKER,
        materialize=materialize,
    )


def _cache_for(tokens: list[int]) -> list[Any]:
    cache = _make_hybrid_cache()
    _feed(cache, tokens)
    return cache


def _session(store: Any, *, step: int = STEP) -> Any:
    session = MagicMock()
    session.model = MagicMock(name="FakeModel")
    session.tokenizer = MagicMock(name="FakeTokenizer")
    session.eos_token_ids = ()
    session.decode_cancel_stride = 1
    session.prefill_step_size = step
    session.prefix_cache = None
    session.strict_prefix_checkpoints = store
    session.memory_budget_status = MagicMock(budget_available=False, target_working_set_bytes=0)
    session.tool_calling = {"supported": False, "parser_type": None}
    return session


def _request(prompt_ids: list[int]) -> Any:
    request = MagicMock()
    request.rendered_prompt_utf8 = b"unused"
    request.input_tokens = len(prompt_ids)
    request.prompt_token_ids = list(prompt_ids)
    request.return_token_ids = False
    request.return_logprobs = False
    request.cache_affinity_fingerprint = ""
    params = MagicMock()
    params.max_output_tokens = 4
    params.temperature = 0.0
    params.top_p = 0.0
    params.stop_sequences = []
    params.tools_json = b""
    params.tool_choice_json = b""
    request.params = params
    return request


def _deps(stream: Any) -> GenerationDeps:
    return GenerationDeps(
        stream_generate=stream,
        make_sampler=lambda **_kwargs: MagicMock(name="FakeSampler"),
        make_prompt_cache=_make_hybrid_cache,
    )


def _run(session: Any, prompt_ids: list[int], stream: _FaithfulStream) -> list[dict[str, Any]]:
    return list(
        generate_events(session, _request(prompt_ids), threading.Event(), deps=_deps(stream))
    )


# Turn 1: 13 prompt tokens, reply marker at index 10, so the boundary is 8.
TURN_1 = [11, 12, 13, 14, 15, 16, 17, 18, 19, 20, *MARKER, 5]
# Turn 2 keeps turn 1's first 10 tokens, adds a reply and a new user turn.
TURN_2 = [*TURN_1[:10], 40, 41, 42, 43, 44, 45, 46, *MARKER, 6]


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------


def test_config_requires_slot_and_budget_bytes() -> None:
    with pytest.raises(TypeError):
        StrictPrefixCheckpointConfig()  # type: ignore[call-arg]


def test_config_refuses_budget_that_cannot_hold_configured_slots() -> None:
    with pytest.raises(ValueError, match="cannot hold 2 slots"):
        StrictPrefixCheckpointConfig(slots=2, slot_bytes=100, budget_bytes=199)

    config = StrictPrefixCheckpointConfig(slots=2, slot_bytes=100, budget_bytes=200)
    assert config.slots == 2


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [
        ({"slots": 0, "slot_bytes": 1, "budget_bytes": 1}, "slots must be >= 1"),
        ({"slots": 9, "slot_bytes": 1, "budget_bytes": 9}, "slots must be <= 8"),
        ({"slots": True, "slot_bytes": 1, "budget_bytes": 1}, "slots must be int"),
        ({"slot_bytes": 0, "budget_bytes": 1}, "slot_bytes must be >= 1"),
        ({"slot_bytes": 1, "budget_bytes": 0}, "budget_bytes must be >= 1"),
        ({"slot_bytes": 1, "budget_bytes": 1, "reply_marker": ""}, "reply_marker"),
    ],
)
def test_config_rejects_invalid_values(kwargs: dict[str, Any], message: str) -> None:
    with pytest.raises(ValueError, match=message):
        StrictPrefixCheckpointConfig(**kwargs)


def test_store_rejects_empty_reply_marker() -> None:
    with pytest.raises(ValueError, match="reply_marker_ids"):
        StrictPrefixCheckpointStore(
            identity=_identity(), slots=1, slot_bytes=1, reply_marker_ids=()
        )


# ---------------------------------------------------------------------------
# Lookup: strictly shorter exact prefix only
# ---------------------------------------------------------------------------


def test_strict_prefix_hit_restores_shorter_exact_prefix() -> None:
    store = _store()
    assert store.capture(TURN_1[:8], _cache_for(TURN_1[:8])).status == CAPTURE_STORED

    lookup = store.lookup(TURN_2)

    assert lookup.status == LOOKUP_HIT
    assert lookup.matched_length == 8
    assert lookup.remaining_ids == TURN_2[8:]
    assert _state(lookup.prompt_cache) == _reference_state(TURN_2[:8])
    assert store.stats().hits == 1


def test_lookup_misses_when_no_retained_key_is_a_prefix() -> None:
    store = _store()
    store.capture(TURN_1[:8], _cache_for(TURN_1[:8]))

    assert store.lookup([99, *TURN_1]).status == LOOKUP_MISS
    assert store.lookup(TURN_1[:5]).status == LOOKUP_MISS
    assert store.stats().misses == 2


def test_lookup_misses_on_an_equal_length_query() -> None:
    """A hit must leave a non-empty suffix; an equal key cannot be restored."""
    store = _store()
    store.capture(TURN_1[:8], _cache_for(TURN_1[:8]))

    assert store.lookup(TURN_1[:8]).status == LOOKUP_MISS
    assert store.lookup(TURN_1[:9]).status == LOOKUP_HIT


def test_changed_earlier_turn_misses() -> None:
    store = _store()
    store.capture(TURN_1[:8], _cache_for(TURN_1[:8]))
    edited = list(TURN_2)
    edited[2] = 999

    assert store.lookup(edited).status == LOOKUP_MISS


def test_longest_strict_prefix_wins() -> None:
    store = _store(slots=2)
    store.capture(TURN_1[:4], _cache_for(TURN_1[:4]))
    store.capture(TURN_1[:8], _cache_for(TURN_1[:8]))

    lookup = store.lookup(TURN_2)

    assert lookup.matched_length == 8


def test_restore_copy_failure_is_a_harmless_miss() -> None:
    store = _store()
    cache = _cache_for(TURN_1[:8])
    store.capture(TURN_1[:8], cache)
    store._slots[0].snapshot = _Uncopyable()

    lookup = store.lookup(TURN_2)

    assert lookup.status == LOOKUP_RESTORE_FAILED
    assert lookup.prompt_cache is None
    stats = store.stats()
    assert (stats.restore_failures, stats.retained, stats.reserved_bytes) == (1, 0, 0)
    # The unrestorable checkpoint is dropped, so it is not retried.
    assert store.lookup(TURN_2).status == LOOKUP_MISS


def test_restore_materialize_failure_is_a_harmless_miss() -> None:
    calls: list[int] = []

    def materialize(_arrays: list[Any]) -> None:
        calls.append(len(calls))
        if len(calls) == 2:
            raise MemoryError("restore eval failed")

    store = _store(materialize=materialize)
    store.capture(TURN_1[:8], _cache_for(TURN_1[:8]))

    lookup = store.lookup(TURN_2)

    assert lookup.status == LOOKUP_RESTORE_FAILED
    assert lookup.prompt_cache is None
    stats = store.stats()
    assert (stats.restore_failures, stats.retained, stats.hits, stats.evictions) == (1, 0, 0, 1)
    assert store.lookup(TURN_2).status == LOOKUP_MISS
    assert store.capture(TURN_1[:8], _cache_for(TURN_1[:8])).status == CAPTURE_STORED


def test_restore_failure_falls_back_to_a_cold_prefill() -> None:
    calls: list[int] = []

    def materialize(_arrays: list[Any]) -> None:
        calls.append(len(calls))
        if len(calls) == 2:
            raise MemoryError("restore eval failed")

    store = _store(materialize=materialize)
    _run(_session(store), TURN_1, _FaithfulStream())
    stream = _FaithfulStream()

    events = _run(_session(store), TURN_2, stream)

    assert events[-1]["kind"] == "completed"
    [call] = stream.calls
    assert call["prompt_ids"] == TURN_2
    assert _state(call["prompt_cache"]) == _reference_state([*TURN_2, GENERATED_TOKEN])


# ---------------------------------------------------------------------------
# Ownership: deep copy on store and on restore
# ---------------------------------------------------------------------------


def test_retained_snapshot_is_isolated_from_later_working_cache_mutation() -> None:
    store = _store()
    working = _cache_for(TURN_1[:8])
    store.capture(TURN_1[:8], working)

    _feed(working, TURN_1[8:] + [GENERATED_TOKEN])

    restored = store.lookup(TURN_2).prompt_cache
    assert _state(restored) == _reference_state(TURN_1[:8])


def test_restored_copy_is_isolated_from_the_retained_snapshot() -> None:
    store = _store()
    store.capture(TURN_1[:8], _cache_for(TURN_1[:8]))

    first = store.lookup(TURN_2).prompt_cache
    _feed(first, TURN_2[8:])
    second = store.lookup(TURN_2).prompt_cache

    assert _state(second) == _reference_state(TURN_1[:8])


# ---------------------------------------------------------------------------
# Memory: reserve before copy; uncertain copies keep their reservation
# ---------------------------------------------------------------------------


class _Uncopyable:
    nbytes = 8
    state: list[Any] = []

    def __deepcopy__(self, _memo: Any) -> Any:
        raise MemoryError("copy failed")


class _ObservedLayer(KVCache):
    """Records the store's reservation state at the moment it is copied."""

    def __init__(self, observe: Callable[[], Any]) -> None:
        super().__init__()
        self._observe = observe
        self.observed: list[Any] = []

    def __deepcopy__(self, memo: Any) -> KVCache:
        self.observed.append(self._observe())
        return _plain_copy(self)


def _plain_copy(layer: KVCache) -> KVCache:
    clone = KVCache()
    clone.keys = copy.deepcopy(layer.keys)
    clone.values = copy.deepcopy(layer.values)
    return clone


def test_slot_is_reserved_before_the_copy_starts() -> None:
    store = _store()
    layer = _ObservedLayer(store.stats)
    layer.feed(TURN_1[:8])

    outcome = store.capture(TURN_1[:8], [layer])

    assert outcome.status == CAPTURE_STORED
    [during_copy] = layer.observed
    assert during_copy.staged == 1
    assert during_copy.reserved_bytes == SLOT_BYTES
    assert during_copy.retained == 0
    after = store.stats()
    assert (after.staged, after.retained, after.reserved_bytes) == (0, 1, SLOT_BYTES)
    assert after.retained_snapshot_bytes == outcome.snapshot_bytes


def test_failed_copy_keeps_its_reservation_as_uncertain() -> None:
    store = _store(slots=1)

    outcome = store.capture(TURN_1[:8], [_Uncopyable()])

    assert outcome.status == CAPTURE_COPY_FAILED
    stats = store.stats()
    assert (stats.uncertain, stats.retained, stats.reserved_bytes) == (1, 0, SLOT_BYTES)
    assert stats.copy_failures == 1
    # The uncertain slot is not reusable, so the next capture finds no slot.
    assert store.capture(TURN_2[:8], _cache_for(TURN_2[:8])).status == CAPTURE_SKIPPED_NO_SLOT
    assert store.lookup(TURN_2).status == LOOKUP_MISS

    store.clear()
    assert store.stats().reserved_bytes == 0
    assert store.capture(TURN_2[:8], _cache_for(TURN_2[:8])).status == CAPTURE_STORED


def test_failed_materialize_keeps_its_reservation_as_uncertain() -> None:
    def materialize(_arrays: list[Any]) -> None:
        raise RuntimeError("eval failed")

    store = _store(materialize=materialize)

    outcome = store.capture(TURN_1[:8], _cache_for(TURN_1[:8]))

    assert outcome.status == CAPTURE_COPY_FAILED
    assert store.stats().uncertain == 1
    assert store.stats().reserved_bytes == SLOT_BYTES


def test_materialize_receives_every_state_array_of_the_copy() -> None:
    seen: list[list[Any]] = []
    store = _store(materialize=seen.append)
    source = _cache_for(TURN_1[:8])

    store.capture(TURN_1[:8], source)

    [arrays] = seen
    assert arrays == snapshot_arrays(source)
    assert all(not any(a is b for b in snapshot_arrays(source)) for a in arrays)


def test_oversize_snapshot_is_skipped_without_a_reservation() -> None:
    store = _store(slot_bytes=10)

    outcome = store.capture(TURN_1[:8], _cache_for(TURN_1[:8]))

    assert outcome.status == CAPTURE_SKIPPED_OVERSIZE
    assert outcome.snapshot_bytes == measure_snapshot_bytes(_cache_for(TURN_1[:8]))
    assert store.stats().reserved_bytes == 0


def test_empty_key_is_never_captured() -> None:
    store = _store()

    assert store.capture([], _cache_for([])).status == "skipped_empty_key"
    assert store.stats().reserved_bytes == 0


def test_fresh_cache_failure_falls_back_to_uncached_generation() -> None:
    store = _store()
    calls: list[dict[str, Any]] = []

    def stream(
        _model: Any, _tokenizer: Any, prompt_ids: list[int], **kwargs: Any
    ) -> Iterator[_Response]:
        calls.append(kwargs)
        yield _Response(text="ok", token=1, finish_reason="stop")

    def broken_cache(_model: Any) -> Any:
        raise MemoryError("no room")

    deps = GenerationDeps(
        stream_generate=stream,
        make_sampler=lambda **_kwargs: None,
        make_prompt_cache=broken_cache,
    )
    events = list(generate_events(_session(store), _request(TURN_1), threading.Event(), deps=deps))

    assert events[-1]["kind"] == "completed"
    [kwargs] = calls
    assert "prompt_cache" not in kwargs
    assert store.stats().stores == 0


def test_unmeasurable_cache_is_skipped_without_a_reservation() -> None:
    layer = MagicMock()
    layer.nbytes = "lots"
    store = _store()

    assert store.capture(TURN_1[:8], [layer]).status == CAPTURE_SKIPPED_UNMEASURABLE
    assert store.stats().reserved_bytes == 0


def test_full_store_evicts_least_recently_used_retained_slot() -> None:
    store = _store(slots=2)
    store.capture([1, 2, 3, 4], _cache_for([1, 2, 3, 4]))
    store.capture([5, 6, 7, 8], _cache_for([5, 6, 7, 8]))
    assert store.lookup([1, 2, 3, 4, 9]).status == LOOKUP_HIT

    store.capture([9, 9, 9, 9], _cache_for([9, 9, 9, 9]))

    assert store.lookup([5, 6, 7, 8, 9]).status == LOOKUP_MISS
    assert store.lookup([1, 2, 3, 4, 9]).status == LOOKUP_HIT
    stats = store.stats()
    assert (stats.retained, stats.evictions, stats.reserved_bytes) == (2, 1, 2 * SLOT_BYTES)


def test_recapturing_the_same_key_replaces_it_in_place() -> None:
    store = _store(slots=2)
    store.capture(TURN_1[:8], _cache_for(TURN_1[:8]))
    store.capture(TURN_1[:8], _cache_for(TURN_1[:8]))

    stats = store.stats()
    assert (stats.retained, stats.evictions, stats.stores) == (1, 0, 2)


def test_borrowed_slot_is_not_evicted_while_it_is_being_restored() -> None:
    store = _store(slots=1)
    nested: list[Any] = []

    class _CaptureDuringRestore(KVCache):
        def __deepcopy__(self, memo: Any) -> KVCache:
            if store.stats().retained == 1 and not nested:
                nested.append(store.capture([7, 7, 7, 7], _cache_for([7, 7, 7, 7])))
            return _plain_copy(self)

    layer = _CaptureDuringRestore()
    layer.feed(TURN_1[:8])
    store._slots.append(_retained_slot(tuple(TURN_1[:8]), [layer], measure_snapshot_bytes([layer])))

    lookup = store.lookup(TURN_2)

    assert lookup.status == LOOKUP_HIT
    assert [outcome.status for outcome in nested] == [CAPTURE_SKIPPED_NO_SLOT]


def _retained_slot(key: tuple[int, ...], snapshot: Any, snapshot_bytes: int) -> Any:
    from orchard_worker_mlx.strict_prefix_checkpoints import _Slot

    return _Slot(key=key, state="retained", snapshot=snapshot, snapshot_bytes=snapshot_bytes)


# ---------------------------------------------------------------------------
# Boundary choice and the capture hook
# ---------------------------------------------------------------------------


def test_last_occurrence_finds_the_final_marker() -> None:
    assert last_occurrence([1, 90, 91, 2, 90, 91, 3], MARKER) == 4
    assert last_occurrence([1, 90, 2, 91], MARKER) is None
    assert last_occurrence([1, 2], ()) is None


def test_capture_boundary_is_the_last_step_multiple_at_or_before_the_reply_marker() -> None:
    assert (
        capture_boundary(TURN_1, matched_length=0, prefill_step_size=4, reply_marker_ids=MARKER)
        == 8
    )
    marker_on_boundary = [1, 2, 3, 4, 5, 6, 7, 8, *MARKER, 9]
    assert (
        capture_boundary(
            marker_on_boundary, matched_length=0, prefill_step_size=4, reply_marker_ids=MARKER
        )
        == 8
    )


@pytest.mark.parametrize(
    ("prompt", "matched", "step"),
    [
        ([1, 2, 3, 4, 5, 6], 0, 4),  # no reply marker
        ([1, 2, *MARKER, 3], 0, 4),  # marker before the first boundary
        (TURN_1, 8, 4),  # boundary not past the restored prefix
        (TURN_1, 6, 4),  # restored prefix not chunk aligned
        (TURN_1, 0, 0),  # invalid step
    ],
)
def test_capture_boundary_declines(prompt: list[int], matched: int, step: int) -> None:
    assert (
        capture_boundary(
            prompt, matched_length=matched, prefill_step_size=step, reply_marker_ids=MARKER
        )
        is None
    )


def test_capture_hook_never_captures_at_the_final_callback() -> None:
    """Even a target equal to the prompt length is not captured at ``(total, total)``."""
    store = _store()
    forwarded: list[tuple[int, int]] = []
    hook = CaptureHook(
        store=store,
        prompt_cache=_cache_for(TURN_1[:8]),
        prompt_ids=TURN_1[:8],
        matched_length=0,
        boundary=8,
        forward=lambda processed, total: forwarded.append((processed, total)),
    )

    hook(8, 8)

    assert hook.outcome.status == CAPTURE_NOT_REACHED
    assert store.stats().stores == 0
    assert forwarded == [(8, 8)]


def test_capture_hook_captures_once_at_its_target_and_forwards_every_call() -> None:
    store = _store()
    forwarded: list[tuple[int, int]] = []
    working = _cache_for(TURN_1[:8])
    hook = CaptureHook(
        store=store,
        prompt_cache=working,
        prompt_ids=TURN_1,
        matched_length=4,
        boundary=8,
        forward=lambda processed, total: forwarded.append((processed, total)),
    )

    for processed in (0, 4, 4, 8):
        hook(processed, 9)

    assert hook.outcome.status == CAPTURE_STORED
    assert store.stats().stores == 1
    assert forwarded == [(0, 9), (4, 9), (4, 9), (8, 9)]


def test_capture_hook_ignores_non_int_progress() -> None:
    store = _store()
    hook = CaptureHook(
        store=store,
        prompt_cache=_cache_for(TURN_1[:8]),
        prompt_ids=TURN_1,
        matched_length=0,
        boundary=8,
        forward=lambda _processed, _total: None,
    )

    hook(True, 13)  # type: ignore[arg-type]
    hook(8.0, 13)  # type: ignore[arg-type]

    assert hook.outcome.status == CAPTURE_NOT_REACHED


def test_capture_hook_survives_an_unexpected_store_error() -> None:
    store = MagicMock()
    store.capture.side_effect = RuntimeError("boom")
    forwarded: list[tuple[int, int]] = []
    hook = CaptureHook(
        store=store,
        prompt_cache=[],
        prompt_ids=TURN_1,
        matched_length=0,
        boundary=8,
        forward=lambda processed, total: forwarded.append((processed, total)),
    )

    hook(8, 13)

    assert hook.outcome.status == CAPTURE_FAILED
    assert forwarded == [(8, 13)]


def test_capture_hook_rejects_a_boundary_that_is_not_past_the_restored_prefix() -> None:
    with pytest.raises(ValueError, match="boundary"):
        CaptureHook(
            store=_store(),
            prompt_cache=[],
            prompt_ids=TURN_1,
            matched_length=8,
            boundary=8,
            forward=lambda _processed, _total: None,
        )


# ---------------------------------------------------------------------------
# End to end through generate_events with a faithful stream fake
# ---------------------------------------------------------------------------


def test_cold_request_captures_the_boundary_before_the_reply_prompt() -> None:
    store = _store()
    stream = _FaithfulStream()

    events = _run(_session(store), TURN_1, stream)

    assert events[-1]["kind"] == "completed"
    [call] = stream.calls
    assert call["prompt_ids"] == TURN_1
    assert isinstance(call["prompt_progress_callback"], CaptureHook)
    assert [(p, t) for p, t, _ in stream.callback_log] == [
        (0, 13),
        (4, 13),
        (8, 13),
        (12, 13),
        (13, 13),
    ]
    stats = store.stats()
    assert (stats.stores, stats.retained) == (1, 1)
    restored = store.lookup(TURN_2).prompt_cache
    assert _state(restored) == _reference_state(TURN_1[:8])
    # The checkpoint equals the cache state the intermediate callback saw.
    assert _state(restored) == stream.callback_log[2][2]


def test_follow_up_restores_and_prefills_only_the_suffix_exactly() -> None:
    store = _store()
    _run(_session(store), TURN_1, _FaithfulStream())
    stream = _FaithfulStream()

    _run(_session(store), TURN_2, stream)

    [call] = stream.calls
    assert call["prompt_ids"] == TURN_2[8:]
    # Exactness by design: the restored cache ends in the same state as an
    # uncached run of the full prompt, including the lookahead token.
    assert _state(call["prompt_cache"]) == _reference_state([*TURN_2, GENERATED_TOKEN])
    # Suffix chunks stay aligned with an uncached run: 8 + 4 = 12, 8 + 8 = 16.
    assert [p for p, _t, _s in stream.callback_log] == [0, 4, 8, 11, 12]
    # Turn 2's reply marker sits at 17, so its checkpoint covers 16 tokens.
    lookup = store.lookup([*TURN_2, 1])
    assert lookup.matched_length == 16
    assert _state(lookup.prompt_cache) == _reference_state(TURN_2[:16])


def test_changed_earlier_turn_prefills_from_scratch() -> None:
    store = _store()
    _run(_session(store), TURN_1, _FaithfulStream())
    edited = list(TURN_2)
    edited[1] = 999
    stream = _FaithfulStream()

    _run(_session(store), edited, stream)

    [call] = stream.calls
    assert call["prompt_ids"] == edited
    assert _state(call["prompt_cache"]) == _reference_state([*edited, GENERATED_TOKEN])


def test_no_checkpoint_is_taken_when_no_boundary_precedes_the_reply_prompt() -> None:
    store = _store()
    stream = _FaithfulStream()

    _run(_session(store), [1, 2, *MARKER, 3], stream)

    [call] = stream.calls
    assert not isinstance(call["prompt_progress_callback"], CaptureHook)
    assert store.stats().stores == 0


def test_strict_path_logs_one_structured_line(caplog: pytest.LogCaptureFixture) -> None:
    store = _store()
    caplog.set_level("INFO", logger="orchard_worker_mlx.generation")

    _run(_session(store), TURN_1, _FaithfulStream())

    [line] = [
        r.getMessage()
        for r in caplog.records
        if "strict_prefix_checkpoint_request" in r.getMessage()
    ]
    assert "lookup_status=miss" in line
    assert "capture_status=stored" in line
    assert "capture_boundary=8" in line


def test_strict_path_skips_the_prefill_workspace_probe() -> None:
    """A checkpoint pins memory during prefill that is not prefill workspace."""
    samples: list[int] = []

    def current_memory_bytes() -> int:
        samples.append(1)
        return 1 << 30

    store = _store()
    deps = GenerationDeps(
        stream_generate=_FaithfulStream(),
        make_sampler=lambda **_kwargs: MagicMock(name="FakeSampler"),
        make_prompt_cache=_make_hybrid_cache,
        current_memory_bytes=current_memory_bytes,
    )
    session = _session(store)

    list(generate_events(session, _request(TURN_1), threading.Event(), deps=deps))

    assert store.stats().stores == 1
    assert samples == []


def test_identity_step_mismatch_disables_reuse_for_the_request() -> None:
    store = _store()
    stream = _FaithfulStreamWithoutCache()

    _run(_session(store, step=8), TURN_1, stream)

    [call] = stream.calls
    assert "prompt_cache" not in call
    assert store.stats().stores == 0


def test_missing_prompt_cache_helper_disables_reuse_for_the_request() -> None:
    store = _store()
    calls: list[dict[str, Any]] = []

    def stream(
        _model: Any, _tokenizer: Any, prompt_ids: list[int], **kwargs: Any
    ) -> Iterator[_Response]:
        calls.append(kwargs)
        yield _Response(text="ok", token=1, finish_reason="stop")

    deps = GenerationDeps(stream_generate=stream, make_sampler=lambda **_kwargs: None)
    list(generate_events(_session(store), _request(TURN_1), threading.Event(), deps=deps))

    [kwargs] = calls
    assert "prompt_cache" not in kwargs


def test_setting_off_leaves_the_stream_call_unchanged() -> None:
    """With no store on the session, generation takes the existing path."""
    for store in (None, MagicMock(name="NotAStore")):
        stream = _FaithfulStreamWithoutCache()
        session = _session(store)

        events = _run(session, TURN_1, stream)

        assert events[-1]["kind"] == "completed"
        [call] = stream.calls
        assert "prompt_cache" not in call
        assert not isinstance(call["prompt_progress_callback"], CaptureHook)
        assert call["prompt_ids"] == TURN_1


@pytest.mark.parametrize("store", [None, MagicMock(name="NotAStore")])
def test_setting_off_keeps_the_trim_cache_path(
    store: Any, caplog: pytest.LogCaptureFixture
) -> None:
    """With no store, a trimmable model still uses the existing prefix cache."""
    caplog.set_level("INFO", logger="orchard_worker_mlx.generation")
    prefix_cache = MagicMock(name="KVPrefixCache")
    prefix_cache.lookup.return_value = None
    prefix_cache.store.return_value = True
    prefix_cache.stats.return_value = SimpleNamespace(
        implementation="kv", entry_count=0, total_bytes=0, failures=0
    )
    session = _session(store)
    session.prefix_cache = prefix_cache
    stream = _FaithfulStream()
    deps = GenerationDeps(
        stream_generate=stream,
        make_sampler=lambda **_kwargs: MagicMock(name="FakeSampler"),
        make_prompt_cache=_make_hybrid_cache,
        trim_prompt_cache=lambda _cache, n: n,
    )

    list(generate_events(session, _request(TURN_1), threading.Event(), deps=deps))

    prefix_cache.lookup.assert_called_once()
    prefix_cache.store.assert_called_once()
    [call] = stream.calls
    assert call["prompt_ids"] == TURN_1
    assert not isinstance(call["prompt_progress_callback"], CaptureHook)
    assert not [r for r in caplog.records if "strict_prefix_checkpoint" in r.getMessage()]


class _FaithfulStreamWithoutCache(_FaithfulStream):
    def __call__(
        self, _model: Any, _tokenizer: Any, prompt_ids: list[int], **kwargs: Any
    ) -> Iterator[_Response]:
        self.calls.append({"prompt_ids": list(prompt_ids), **kwargs})
        yield _Response(text="ok", token=GENERATED_TOKEN, finish_reason="stop")
