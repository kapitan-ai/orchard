"""Unit tests for prefix_cache.py: standalone KV prefix cache.

All tests use fake cache objects with .offset attributes — no real MLX needed.
Test style matches test_generation.py / test_model_loader.py.
"""

from __future__ import annotations

from typing import Any

import pytest

from orchard_worker_mlx.prefix_cache import (
    CacheHit,
    KVPrefixCache,
    PrefixCache,
    PrefixCacheStats,
    TriePrefixCache,
    prompt_cache_length,
)


# ---------------------------------------------------------------------------
# Fake cache entries (simulate MLX cache objects without MLX imports)
# ---------------------------------------------------------------------------


class FakeOffsetEntry:
    """Simulates KVCache / QuantizedKVCache with .offset attribute."""

    def __init__(self, offset: int) -> None:
        self.offset = offset
        # Mutable nested field for deep-copy isolation testing.
        self.data: list[int] = list(range(offset))


class FakeSizeEntry:
    """Simulates ChunkedKVCache with .size() method."""

    def __init__(self, length: int) -> None:
        self._length = length
        self.data: list[int] = list(range(length))

    def size(self) -> int:
        return self._length


def _make_fake_cache(length: int) -> list[FakeOffsetEntry]:
    """Create a fake prompt-cache list with the given token length."""
    return [FakeOffsetEntry(length)]


def _make_mixed_cache(offset_len: int, size_len: int) -> list[Any]:
    """Create a cache with both offset-backed and size-backed entries."""
    return [FakeOffsetEntry(offset_len), FakeSizeEntry(size_len)]


# ---------------------------------------------------------------------------
# Fake trim functions
# ---------------------------------------------------------------------------


def fake_trim(cache: Any, n: int) -> int:
    """Trim helper that adjusts fake cache entry offsets/lengths.

    Matches the contract of mlx_lm.generate.trim_prompt_cache: trims *n*
    tokens from each entry and returns *n*.
    """
    for entry in cache:
        if hasattr(entry, "offset"):
            entry.offset = max(0, entry.offset - n)
            entry.data = entry.data[: entry.offset]
        elif hasattr(entry, "_length"):
            entry._length = max(0, entry._length - n)
            entry.data = entry.data[: entry._length]
    return n


def failing_trim(cache: Any, n: int) -> int:
    """Trim helper that always raises."""
    raise RuntimeError("trim failed")


def wrong_count_trim(cache: Any, n: int) -> int:
    """Trim helper that returns wrong trimmed count."""
    return n + 1


# ---------------------------------------------------------------------------
# Tests: prompt_cache_length helper
# ---------------------------------------------------------------------------


class TestPromptCacheLength:
    def test_offset_entry(self) -> None:
        cache = [FakeOffsetEntry(42)]
        assert prompt_cache_length(cache) == 42

    def test_size_entry(self) -> None:
        cache = [FakeSizeEntry(17)]
        assert prompt_cache_length(cache) == 17

    def test_mixed_returns_max(self) -> None:
        """When cache has both offset and size entries, return the max."""
        cache = _make_mixed_cache(offset_len=10, size_len=20)
        assert prompt_cache_length(cache) == 20

        cache2 = _make_mixed_cache(offset_len=30, size_len=5)
        assert prompt_cache_length(cache2) == 30

    def test_empty_cache(self) -> None:
        assert prompt_cache_length([]) == 0

    def test_non_iterable(self) -> None:
        assert prompt_cache_length(None) == 0
        assert prompt_cache_length(42) == 0

    def test_entry_without_offset_or_size(self) -> None:
        """Entries with neither .offset nor .size() contribute 0."""
        cache = [object()]
        assert prompt_cache_length(cache) == 0

    def test_bool_offset_ignored(self) -> None:
        """bool is a subclass of int; .offset = True should not be treated as 1."""

        class BoolEntry:
            offset = True

        cache = [BoolEntry()]
        assert prompt_cache_length(cache) == 0


# ---------------------------------------------------------------------------
# Tests: KVPrefixCache basic operations
# ---------------------------------------------------------------------------


class TestKVPrefixCacheBasic:
    def test_starts_empty(self) -> None:
        cache = KVPrefixCache(max_entries=4)
        assert len(cache) == 0

    def test_store_and_len(self) -> None:
        cache = KVPrefixCache(max_entries=4)
        cache.store([1, 2, 3], _make_fake_cache(3))
        assert len(cache) == 1

    def test_clear_empties_cache(self) -> None:
        cache = KVPrefixCache(max_entries=4)
        cache.store([1, 2, 3], _make_fake_cache(3))
        cache.store([4, 5, 6], _make_fake_cache(3))
        assert len(cache) == 2
        cache.clear()
        assert len(cache) == 0
        # Lookup after clear should miss.
        assert cache.lookup([1, 2, 3], trim_fn=fake_trim) is None

    def test_lookup_empty_cache_returns_none(self) -> None:
        cache = KVPrefixCache()
        assert cache.lookup([1, 2, 3], trim_fn=fake_trim) is None

    def test_lookup_empty_query_returns_none(self) -> None:
        cache = KVPrefixCache()
        cache.store([1, 2, 3], _make_fake_cache(3))
        assert cache.lookup([], trim_fn=fake_trim) is None

    def test_lookup_no_prefix_match_returns_none(self) -> None:
        cache = KVPrefixCache()
        cache.store([1, 2, 3], _make_fake_cache(3))
        assert cache.lookup([9, 8, 7], trim_fn=fake_trim) is None


# ---------------------------------------------------------------------------
# Tests: Longest-prefix lookup
# ---------------------------------------------------------------------------


class TestLongestPrefixLookup:
    def test_longest_prefix_wins(self) -> None:
        """With multiple stored entries, the one sharing the longest prefix wins."""
        cache = KVPrefixCache()
        # Entry A: tokens [1, 2]
        cache.store([1, 2], _make_fake_cache(2))
        # Entry B: tokens [1, 2, 3, 4, 5]
        cache.store([1, 2, 3, 4, 5], _make_fake_cache(5))

        # Query [1, 2, 3, 4, 5, 6, 7] — B shares 5 tokens, A shares 2.
        hit = cache.lookup([1, 2, 3, 4, 5, 6, 7], trim_fn=fake_trim)
        assert hit is not None
        assert hit.matched_length == 5
        assert hit.remaining_ids == [6, 7]

    def test_partial_match(self) -> None:
        """Partial prefix match returns correct split."""
        cache = KVPrefixCache()
        cache.store([10, 20, 30, 40], _make_fake_cache(4))

        hit = cache.lookup([10, 20, 99], trim_fn=fake_trim)
        assert hit is not None
        assert hit.matched_length == 2
        assert hit.remaining_ids == [99]
        # Restored cache should be trimmed to matched_length.
        assert prompt_cache_length(hit.prompt_cache) == 2

    def test_returns_cache_hit_dataclass(self) -> None:
        cache = KVPrefixCache()
        cache.store([1, 2, 3], _make_fake_cache(3))

        hit = cache.lookup([1, 2, 3, 4], trim_fn=fake_trim)
        assert isinstance(hit, CacheHit)
        assert hit.matched_length == 3
        assert hit.remaining_ids == [4]


# ---------------------------------------------------------------------------
# Tests: Exact / full-query coverage
# ---------------------------------------------------------------------------


class TestExactMatchHandling:
    def test_full_query_coverage_trims_to_len_minus_one(self) -> None:
        """When stored key fully covers the query, trim to len(query)-1.

        This ensures stream_generate() receives at least 1 token.
        """
        cache = KVPrefixCache()
        # Stored key is longer than query (simulates prompt + generated tokens).
        cache.store([1, 2, 3, 4, 5], _make_fake_cache(5))

        # Query [1, 2, 3] is fully covered by the stored [1, 2, 3, 4, 5].
        hit = cache.lookup([1, 2, 3], trim_fn=fake_trim)
        assert hit is not None
        assert hit.matched_length == 3
        assert hit.remaining_ids == [3]  # last query token
        # Cache trimmed to len(query) - 1 = 2.
        assert prompt_cache_length(hit.prompt_cache) == 2

    def test_exact_same_key_trims_to_len_minus_one(self) -> None:
        """Query exactly equals stored key — also trims to len - 1."""
        cache = KVPrefixCache()
        cache.store([1, 2, 3, 4], _make_fake_cache(4))

        hit = cache.lookup([1, 2, 3, 4], trim_fn=fake_trim)
        assert hit is not None
        assert hit.matched_length == 4
        assert hit.remaining_ids == [4]  # last token
        assert prompt_cache_length(hit.prompt_cache) == 3

    def test_single_token_full_hit_returns_none(self) -> None:
        """1-token query fully matched → restore_pos=0 → None."""
        cache = KVPrefixCache()
        cache.store([42], _make_fake_cache(1))

        assert cache.lookup([42], trim_fn=fake_trim) is None

    def test_two_token_full_hit_succeeds(self) -> None:
        """2-token query fully matched → restore_pos=1 → OK."""
        cache = KVPrefixCache()
        cache.store([10, 20], _make_fake_cache(2))

        hit = cache.lookup([10, 20], trim_fn=fake_trim)
        assert hit is not None
        assert hit.matched_length == 2
        assert hit.remaining_ids == [20]
        assert prompt_cache_length(hit.prompt_cache) == 1


# ---------------------------------------------------------------------------
# Tests: trim_fn failure (fail-open)
# ---------------------------------------------------------------------------


class TestTrimFailure:
    def test_trim_raises_returns_none(self) -> None:
        cache = KVPrefixCache()
        cache.store([1, 2, 3, 4, 5], _make_fake_cache(5))

        # Partial match requiring trim, but trim_fn raises.
        hit = cache.lookup([1, 2, 3], trim_fn=failing_trim)
        assert hit is None

    def test_trim_wrong_count_returns_none(self) -> None:
        cache = KVPrefixCache()
        cache.store([1, 2, 3, 4, 5], _make_fake_cache(5))

        hit = cache.lookup([1, 2, 3], trim_fn=wrong_count_trim)
        assert hit is None

    def test_no_trim_needed_skips_trim_fn(self) -> None:
        """When stored cache length equals restore_pos, trim_fn is not called."""
        cache = KVPrefixCache()
        # Stored key [1, 2, 3] with cache length 3.
        # Query [1, 2, 3, 4] — partial match of 3, restore_pos=3, tokens_to_trim=0.
        cache.store([1, 2, 3], _make_fake_cache(3))

        # Even a failing trim_fn should be fine — it shouldn't be called.
        hit = cache.lookup([1, 2, 3, 4], trim_fn=failing_trim)
        assert hit is not None
        assert hit.matched_length == 3
        assert hit.remaining_ids == [4]


# ---------------------------------------------------------------------------
# Tests: Deep-copy boundaries
# ---------------------------------------------------------------------------


class TestDeepCopyFailure:
    def test_deepcopy_failure_in_lookup_returns_none(self) -> None:
        """If deep-copying the stored cache fails, lookup returns None (fail-open)."""

        class UncopyableEntry:
            offset = 5

            def __deepcopy__(self, memo: dict) -> None:
                raise RuntimeError("cannot deepcopy")

        cache = KVPrefixCache()
        # Store succeeds because the first deepcopy (on store) works on a
        # list containing the uncopyable entry — list deepcopy recurses.
        # We need a cache that stores fine but fails on retrieve deepcopy.
        # Use a normal cache for store, then swap the stored value.
        cache.store([1, 2, 3, 4, 5], _make_fake_cache(5))

        # Replace the stored value with an uncopyable object via internals.
        key = (1, 2, 3, 4, 5)
        cache._entries[key] = [UncopyableEntry()]

        hit = cache.lookup([1, 2, 3, 4, 5, 6], trim_fn=fake_trim)
        assert hit is None
        # Cache should still have the entry (not corrupted by failed lookup).
        assert len(cache) == 1


class TestMaxEntriesValidation:
    def test_zero_raises(self) -> None:
        with pytest.raises(ValueError, match="max_entries must be >= 1"):
            KVPrefixCache(max_entries=0)

    def test_negative_raises(self) -> None:
        with pytest.raises(ValueError, match="max_entries must be >= 1"):
            KVPrefixCache(max_entries=-1)

    def test_one_is_valid(self) -> None:
        cache = KVPrefixCache(max_entries=1)
        assert len(cache) == 0


class TestDeepCopyBoundaries:
    def test_store_deepcopies_isolation(self) -> None:
        """Post-store mutation of the original cache does not corrupt stored state."""
        cache = KVPrefixCache()
        original = _make_fake_cache(5)

        cache.store([1, 2, 3, 4, 5], original)

        # Mutate the original after store.
        original[0].offset = 999
        original[0].data = [999]

        # Lookup should return the original stored state, unaffected.
        hit = cache.lookup([1, 2, 3, 4, 5, 6], trim_fn=fake_trim)
        assert hit is not None
        assert prompt_cache_length(hit.prompt_cache) == 5

    def test_retrieve_deepcopies_isolation(self) -> None:
        """Post-retrieve mutation does not corrupt stored state for next lookup."""
        cache = KVPrefixCache()
        cache.store([1, 2, 3, 4, 5], _make_fake_cache(5))

        # First lookup: mutate the returned cache.
        hit1 = cache.lookup([1, 2, 3, 4, 5, 6], trim_fn=fake_trim)
        assert hit1 is not None
        hit1.prompt_cache[0].offset = 0
        hit1.prompt_cache[0].data = []

        # Second lookup: should get a clean copy.
        hit2 = cache.lookup([1, 2, 3, 4, 5, 6], trim_fn=fake_trim)
        assert hit2 is not None
        assert prompt_cache_length(hit2.prompt_cache) == 5


# ---------------------------------------------------------------------------
# Tests: LRU eviction
# ---------------------------------------------------------------------------


class TestLRUEviction:
    def test_evicts_oldest_on_overflow(self) -> None:
        """When capacity is exceeded, the oldest (LRU) entry is evicted."""
        cache = KVPrefixCache(max_entries=2)
        cache.store([1, 1], _make_fake_cache(2))  # Entry A
        cache.store([2, 2], _make_fake_cache(2))  # Entry B
        cache.store([3, 3], _make_fake_cache(2))  # Entry C — evicts A

        assert len(cache) == 2
        # A should be gone.
        assert cache.lookup([1, 1, 9], trim_fn=fake_trim) is None
        # B and C should remain.
        assert cache.lookup([2, 2, 9], trim_fn=fake_trim) is not None
        assert cache.lookup([3, 3, 9], trim_fn=fake_trim) is not None

    def test_hit_refreshes_recency(self) -> None:
        """A successful lookup refreshes the entry's recency (protects from eviction)."""
        cache = KVPrefixCache(max_entries=2)
        cache.store([1, 1], _make_fake_cache(2))  # Entry A (oldest)
        cache.store([2, 2], _make_fake_cache(2))  # Entry B (newest)

        # Lookup A — refreshes A to MRU.
        hit = cache.lookup([1, 1, 9], trim_fn=fake_trim)
        assert hit is not None

        # Store C — B is now oldest, should be evicted.
        cache.store([3, 3], _make_fake_cache(2))

        assert len(cache) == 2
        # B should be evicted (was oldest after A's refresh).
        assert cache.lookup([2, 2, 9], trim_fn=fake_trim) is None
        # A and C should remain.
        assert cache.lookup([1, 1, 9], trim_fn=fake_trim) is not None
        assert cache.lookup([3, 3, 9], trim_fn=fake_trim) is not None

    def test_duplicate_store_refreshes_mru(self) -> None:
        """Storing the same key again refreshes MRU and replaces value."""
        cache = KVPrefixCache(max_entries=2)
        cache.store([1, 1], _make_fake_cache(2))  # Entry A
        cache.store([2, 2], _make_fake_cache(2))  # Entry B

        # Re-store A with a new cache value — refreshes it to MRU.
        # Use a two-entry (multi-layer) cache to distinguish from the original.
        replacement_cache = [FakeOffsetEntry(2), FakeOffsetEntry(2)]
        cache.store([1, 1], replacement_cache)

        # Store C — B should be evicted (A was refreshed to MRU).
        cache.store([3, 3], _make_fake_cache(2))

        assert len(cache) == 2
        assert cache.lookup([2, 2, 9], trim_fn=fake_trim) is None  # B evicted
        # A should remain and return the replacement cache (2 entries).
        hit_a = cache.lookup([1, 1, 9], trim_fn=fake_trim)
        assert hit_a is not None
        assert len(hit_a.prompt_cache) == 2  # replaced value has 2 entries

    def test_max_entries_one(self) -> None:
        """Edge case: max_entries=1 keeps only the most recent."""
        cache = KVPrefixCache(max_entries=1)
        cache.store([1, 1], _make_fake_cache(2))
        cache.store([2, 2], _make_fake_cache(2))

        assert len(cache) == 1
        assert cache.lookup([1, 1, 9], trim_fn=fake_trim) is None
        assert cache.lookup([2, 2, 9], trim_fn=fake_trim) is not None


# ---------------------------------------------------------------------------
# Stats, byte accounting, and thread safety
# ---------------------------------------------------------------------------


class TestKVPrefixCacheStats:
    """Tests for PrefixCacheStats, byte accounting, and counter semantics."""

    def test_initial_stats_snapshot(self) -> None:
        """Fresh cache returns zeroed stats with implementation='kv'."""
        cache = KVPrefixCache()
        s = cache.stats()
        assert isinstance(s, PrefixCacheStats)
        assert s.implementation == "kv"
        assert s.entry_count == 0
        assert s.total_bytes == 0
        assert s.hits == 0
        assert s.misses == 0
        assert s.failures == 0
        assert s.stores == 0
        assert s.evictions == 0

    def test_kv_store_returns_true(self) -> None:
        """KVPrefixCache.store() always returns True (no rejection)."""
        cache = KVPrefixCache()
        assert cache.store([1, 2, 3], _make_fake_cache(3)) is True
        assert cache.store([1, 2, 3], _make_fake_cache(5)) is True  # replacement

    def test_store_increments_stores_counter(self) -> None:
        """Each successful store() increments the stores counter."""
        cache = KVPrefixCache()
        cache.store([1, 2, 3], _make_fake_cache(3))
        cache.store([4, 5, 6], _make_fake_cache(3))
        s = cache.stats()
        assert s.stores == 2
        assert s.entry_count == 2

    def test_hit_increments_hits_counter(self) -> None:
        """Successful lookup() increments hits counter."""
        cache = KVPrefixCache()
        cache.store([1, 2, 3], _make_fake_cache(3))
        hit = cache.lookup([1, 2, 3, 4], trim_fn=fake_trim)
        assert hit is not None
        s = cache.stats()
        assert s.hits == 1
        assert s.misses == 0

    def test_miss_increments_misses_counter(self) -> None:
        """Lookup on empty cache or no-match increments misses."""
        cache = KVPrefixCache()
        # Miss on empty cache.
        assert cache.lookup([1, 2], trim_fn=fake_trim) is None
        # Miss on empty query.
        cache.store([1, 2], _make_fake_cache(2))
        assert cache.lookup([], trim_fn=fake_trim) is None
        # Miss on no-match.
        assert cache.lookup([9, 9], trim_fn=fake_trim) is None
        s = cache.stats()
        assert s.misses == 3
        assert s.hits == 0

    def test_single_token_exact_hit_counted_as_miss(self) -> None:
        """Single-token exact hit has restore_pos=0, counted as miss.

        When the stored key exactly matches a 1-token query, the restore
        position is len(query)-1 = 0, which is unusable for
        stream_generate().  This is classified as a *miss* (matched but
        unusable), not a failure (no internal error occurred).
        """
        cache = KVPrefixCache()
        cache.store([42], _make_fake_cache(1))
        result = cache.lookup([42], trim_fn=fake_trim)
        assert result is None
        s = cache.stats()
        assert s.misses == 1
        assert s.failures == 0
        assert s.hits == 0

    def test_failure_on_trim_exception(self) -> None:
        """Trim exception during lookup increments failures, not misses."""
        cache = KVPrefixCache()
        # Store a long key so full-query coverage lookup triggers trim.
        cache.store([1, 2, 3, 4, 5], _make_fake_cache(5))

        def bad_trim(cache: Any, n: int) -> int:
            raise RuntimeError("trim boom")

        # Lookup shorter query -> full-query coverage -> needs trim.
        result = cache.lookup([1, 2, 3], trim_fn=bad_trim)
        assert result is None
        s = cache.stats()
        assert s.failures == 1
        assert s.misses == 0
        assert s.hits == 0

    def test_failure_on_trim_wrong_count(self) -> None:
        """Trim returning wrong count increments failures."""
        cache = KVPrefixCache()
        # Store a long key so full-query coverage lookup triggers trim.
        cache.store([1, 2, 3, 4, 5], _make_fake_cache(5))

        def wrong_trim(cache: Any, n: int) -> int:
            return n + 1  # wrong count

        # Lookup shorter query -> full-query coverage -> trim called.
        result = cache.lookup([1, 2, 3], trim_fn=wrong_trim)
        assert result is None
        s = cache.stats()
        assert s.failures == 1

    def test_failure_on_deepcopy_exception_in_lookup(self) -> None:
        """Deepcopy failure during lookup increments failures."""
        cache = KVPrefixCache()

        class UncopiableCache:
            offset = 5

            def __deepcopy__(self, memo: Any) -> None:
                raise RuntimeError("copy boom")

        # Store with a normal cache, then replace internal entry with uncopiable.
        cache.store([1, 2, 3, 4, 5], _make_fake_cache(5))
        key = (1, 2, 3, 4, 5)
        cache._entries[key] = [UncopiableCache()]

        result = cache.lookup([1, 2, 3, 4, 5, 6], trim_fn=fake_trim)
        assert result is None
        s = cache.stats()
        assert s.failures == 1

    def test_store_failure_increments_failures_and_reraises(self) -> None:
        """Deepcopy failure during store increments failures and re-raises."""
        cache = KVPrefixCache()

        class UncopiableObj:
            offset = 3

            def __deepcopy__(self, memo: Any) -> None:
                raise RuntimeError("store copy boom")

        with pytest.raises(RuntimeError, match="store copy boom"):
            cache.store([1, 2, 3], [UncopiableObj()])

        s = cache.stats()
        assert s.failures == 1
        assert s.stores == 0
        assert s.entry_count == 0

    def test_eviction_counter(self) -> None:
        """Capacity-driven eviction increments evictions counter."""
        cache = KVPrefixCache(max_entries=1)
        cache.store([1, 1], _make_fake_cache(2))
        cache.store([2, 2], _make_fake_cache(2))
        s = cache.stats()
        assert s.stores == 2
        assert s.evictions == 1
        assert s.entry_count == 1

    def test_replacement_does_not_count_as_eviction(self) -> None:
        """Replacing an existing key does not increment evictions."""
        cache = KVPrefixCache(max_entries=2)
        cache.store([1, 2], _make_fake_cache(2))
        cache.store([1, 2], _make_fake_cache(5))  # replace same key
        s = cache.stats()
        assert s.stores == 2
        assert s.evictions == 0
        assert s.entry_count == 1

    # -- Byte accounting ---------------------------------------------------

    def test_bytes_per_token_none_yields_zero(self) -> None:
        """When bytes_per_token is None, total_bytes is always 0."""
        cache = KVPrefixCache(bytes_per_token=None)
        cache.store([1, 2, 3], _make_fake_cache(3))
        s = cache.stats()
        assert s.total_bytes == 0

    def test_bytes_per_token_tracks_total(self) -> None:
        """With bytes_per_token set, total_bytes reflects entry sizes."""
        cache = KVPrefixCache(bytes_per_token=100)
        cache.store([1, 2, 3], _make_fake_cache(3))  # 3 tokens * 100 = 300
        cache.store([4, 5], _make_fake_cache(5))  # 5 tokens * 100 = 500
        s = cache.stats()
        assert s.total_bytes == 800
        assert s.entry_count == 2

    def test_bytes_updated_on_replacement(self) -> None:
        """Replacing a key updates total_bytes to new entry size."""
        cache = KVPrefixCache(bytes_per_token=100)
        cache.store([1, 2], _make_fake_cache(2))  # 200
        assert cache.stats().total_bytes == 200
        cache.store([1, 2], _make_fake_cache(5))  # replace: 500
        s = cache.stats()
        assert s.total_bytes == 500
        assert s.entry_count == 1

    def test_bytes_updated_on_eviction(self) -> None:
        """Eviction subtracts the evicted entry's byte estimate."""
        cache = KVPrefixCache(max_entries=1, bytes_per_token=100)
        cache.store([1, 1], _make_fake_cache(3))  # 300
        cache.store([2, 2], _make_fake_cache(5))  # 500, evicts first
        s = cache.stats()
        assert s.total_bytes == 500
        assert s.evictions == 1

    # -- clear() semantics -------------------------------------------------

    def test_clear_resets_current_state_not_counters(self) -> None:
        """clear() zeroes entry_count and total_bytes, keeps counters."""
        cache = KVPrefixCache(bytes_per_token=100)
        cache.store([1, 2, 3], _make_fake_cache(3))
        cache.lookup([1, 2, 3, 4], trim_fn=fake_trim)
        cache.lookup([9, 9], trim_fn=fake_trim)  # miss

        cache.clear()
        s = cache.stats()
        assert s.entry_count == 0
        assert s.total_bytes == 0
        # Cumulative counters survive clear.
        assert s.stores == 1
        assert s.hits == 1
        assert s.misses == 1
        assert s.evictions == 0

    # -- Constructor validation --------------------------------------------

    def test_bytes_per_token_rejects_bool(self) -> None:
        """Boolean values are rejected for bytes_per_token."""
        with pytest.raises(ValueError):
            KVPrefixCache(bytes_per_token=True)  # type: ignore[arg-type]

    def test_bytes_per_token_rejects_negative(self) -> None:
        """Negative bytes_per_token is rejected."""
        with pytest.raises(ValueError):
            KVPrefixCache(bytes_per_token=-1)

    def test_bytes_per_token_zero_allowed(self) -> None:
        """Zero bytes_per_token is valid (yields zero-byte estimates)."""
        cache = KVPrefixCache(bytes_per_token=0)
        cache.store([1, 2], _make_fake_cache(3))
        assert cache.stats().total_bytes == 0

    # -- Protocol conformance ----------------------------------------------

    def test_kv_prefix_cache_satisfies_protocol(self) -> None:
        """KVPrefixCache is a structural match for PrefixCache protocol."""
        cache = KVPrefixCache()
        assert isinstance(cache, PrefixCache)


# ===========================================================================
# TriePrefixCache tests
# ===========================================================================


class TestTriePrefixCacheBasic:
    """Basic construction, protocol conformance, and empty-state behavior."""

    def test_empty_stats(self) -> None:
        """Fresh trie cache returns zeroed stats with implementation='trie'."""
        cache = TriePrefixCache()
        s = cache.stats()
        assert isinstance(s, PrefixCacheStats)
        assert s.implementation == "trie"
        assert s.entry_count == 0
        assert s.total_bytes == 0
        assert s.hits == 0
        assert s.misses == 0

    def test_satisfies_protocol(self) -> None:
        """TriePrefixCache is a structural match for PrefixCache protocol."""
        cache = TriePrefixCache()
        assert isinstance(cache, PrefixCache)

    def test_constructor_validates_max_entries(self) -> None:
        with pytest.raises(ValueError):
            TriePrefixCache(max_entries=0)

    def test_constructor_validates_bytes_per_token(self) -> None:
        with pytest.raises(ValueError):
            TriePrefixCache(bytes_per_token=-1)
        with pytest.raises(ValueError):
            TriePrefixCache(bytes_per_token=True)  # type: ignore[arg-type]

    def test_constructor_validates_max_bytes(self) -> None:
        with pytest.raises(ValueError):
            TriePrefixCache(max_bytes=-1)
        with pytest.raises(ValueError):
            TriePrefixCache(max_bytes=True)  # type: ignore[arg-type]

    def test_max_bytes_zero_treated_as_disabled(self) -> None:
        """max_bytes=0 is treated as None (disabled)."""
        cache = TriePrefixCache(max_bytes=0, bytes_per_token=100)
        cache.store([1, 2, 3], _make_fake_cache(3))
        assert len(cache) == 1  # not rejected


class TestTrieLongestPrefixLookup:
    """Trie lookup correctly finds the longest matching prefix."""

    def test_partial_prefix_hit(self) -> None:
        """Stored [1,2,3] matches query [1,2,3,4,5]."""
        cache = TriePrefixCache()
        cache.store([1, 2, 3], _make_fake_cache(3))
        hit = cache.lookup([1, 2, 3, 4, 5], trim_fn=fake_trim)
        assert hit is not None
        assert hit.matched_length == 3
        assert hit.remaining_ids == [4, 5]

    def test_longer_prefix_wins(self) -> None:
        """Among [1,2] and [1,2,3], the longer prefix matches [1,2,3,4]."""
        cache = TriePrefixCache()
        cache.store([1, 2], _make_fake_cache(2))
        cache.store([1, 2, 3], _make_fake_cache(3))
        hit = cache.lookup([1, 2, 3, 4], trim_fn=fake_trim)
        assert hit is not None
        assert hit.matched_length == 3
        assert hit.remaining_ids == [4]

    def test_no_match_returns_none(self) -> None:
        """Query sharing no prefix returns None."""
        cache = TriePrefixCache()
        cache.store([1, 2, 3], _make_fake_cache(3))
        result = cache.lookup([9, 8, 7], trim_fn=fake_trim)
        assert result is None
        assert cache.stats().misses == 1

    def test_empty_cache_miss(self) -> None:
        cache = TriePrefixCache()
        assert cache.lookup([1, 2], trim_fn=fake_trim) is None
        assert cache.stats().misses == 1

    def test_empty_query_miss(self) -> None:
        cache = TriePrefixCache()
        cache.store([1, 2], _make_fake_cache(2))
        assert cache.lookup([], trim_fn=fake_trim) is None
        assert cache.stats().misses == 1


class TestTrieFullQueryCoverage:
    """Full-query coverage via exact key or stored descendant."""

    def test_exact_key_hit(self) -> None:
        """Stored [1,2,3] exactly matches query [1,2,3]."""
        cache = TriePrefixCache()
        cache.store([1, 2, 3], _make_fake_cache(3))
        hit = cache.lookup([1, 2, 3], trim_fn=fake_trim)
        assert hit is not None
        # Full-query coverage: restore_pos = len(query) - 1 = 2.
        assert hit.matched_length == 3
        assert hit.remaining_ids == [3]  # trailing token

    def test_stored_descendant_covers_query(self) -> None:
        """Stored [1,2,3,4,5] covers shorter query [1,2,3]."""
        cache = TriePrefixCache()
        cache.store([1, 2, 3, 4, 5], _make_fake_cache(5))
        hit = cache.lookup([1, 2, 3], trim_fn=fake_trim)
        assert hit is not None
        assert hit.matched_length == 3
        assert hit.remaining_ids == [3]  # trailing token

    def test_single_token_full_coverage_is_miss(self) -> None:
        """Single-token exact hit has restore_pos=0, counted as miss."""
        cache = TriePrefixCache()
        cache.store([42], _make_fake_cache(1))
        result = cache.lookup([42], trim_fn=fake_trim)
        assert result is None
        s = cache.stats()
        assert s.misses == 1
        assert s.failures == 0


class TestTrieLRUBehavior:
    """Access-LRU promotion and eviction ordering."""

    def test_lookup_promotes_to_mru(self) -> None:
        """Successful lookup promotes entry; eviction removes oldest."""
        cache = TriePrefixCache(max_entries=2)
        cache.store([1, 1], _make_fake_cache(2))
        cache.store([2, 2], _make_fake_cache(2))
        # Lookup [1,1,...] promotes it to MRU.
        cache.lookup([1, 1, 9], trim_fn=fake_trim)
        # Storing a third entry should evict [2,2] (oldest after promotion).
        cache.store([3, 3], _make_fake_cache(2))
        assert len(cache) == 2
        assert cache.lookup([2, 2, 9], trim_fn=fake_trim) is None
        assert cache.lookup([1, 1, 9], trim_fn=fake_trim) is not None

    def test_store_replacement_refreshes_mru(self) -> None:
        """Replacing an existing key moves it to MRU."""
        cache = TriePrefixCache(max_entries=2)
        cache.store([1, 1], _make_fake_cache(2))
        cache.store([2, 2], _make_fake_cache(2))
        # Replace [1,1] -> MRU.
        cache.store([1, 1], _make_fake_cache(5))
        # New entry should evict [2,2].
        cache.store([3, 3], _make_fake_cache(2))
        assert cache.lookup([2, 2, 9], trim_fn=fake_trim) is None
        assert cache.lookup([1, 1, 9], trim_fn=fake_trim) is not None

    def test_entry_count_eviction(self) -> None:
        """Exceeding max_entries evicts the oldest entry."""
        cache = TriePrefixCache(max_entries=1)
        cache.store([1, 1], _make_fake_cache(2))
        cache.store([2, 2], _make_fake_cache(2))
        assert len(cache) == 1
        assert cache.lookup([1, 1, 9], trim_fn=fake_trim) is None
        assert cache.lookup([2, 2, 9], trim_fn=fake_trim) is not None
        assert cache.stats().evictions == 1


class TestTrieByteBudgetEviction:
    """Byte-budget eviction via max_bytes."""

    def test_byte_cap_evicts_oldest(self) -> None:
        """Exceeding byte budget evicts oldest entries."""
        # Each fake cache with length=3 at 100 bytes/token = 300 bytes.
        cache = TriePrefixCache(
            max_entries=10,
            max_bytes=500,
            bytes_per_token=100,
        )
        cache.store([1, 1], _make_fake_cache(3))  # 300
        cache.store([2, 2], _make_fake_cache(3))  # 300 -> total 600 > 500
        assert len(cache) == 1
        s = cache.stats()
        assert s.evictions == 1
        assert s.total_bytes == 300

    def test_byte_stats_track_correctly(self) -> None:
        cache = TriePrefixCache(max_bytes=10000, bytes_per_token=100)
        cache.store([1, 2, 3], _make_fake_cache(3))  # 300
        cache.store([4, 5], _make_fake_cache(5))  # 500
        s = cache.stats()
        assert s.total_bytes == 800
        assert s.entry_count == 2

    def test_no_byte_cap_when_disabled(self) -> None:
        """Without max_bytes, only entry count matters."""
        cache = TriePrefixCache(
            max_entries=10,
            bytes_per_token=100,
        )  # max_bytes=None
        for i in range(10):
            cache.store([i, i], _make_fake_cache(100))  # 10000 bytes each
        assert len(cache) == 10
        assert cache.stats().evictions == 0


class TestTrieStoreReturnValues:
    """store() returns True on accept, False on rejection."""

    def test_accepted_insert_returns_true(self) -> None:
        cache = TriePrefixCache()
        assert cache.store([1, 2, 3], _make_fake_cache(3)) is True

    def test_accepted_replacement_returns_true(self) -> None:
        cache = TriePrefixCache()
        cache.store([1, 2, 3], _make_fake_cache(3))
        assert cache.store([1, 2, 3], _make_fake_cache(5)) is True


class TestTrieOversizeRejection:
    """Oversize entries are silently skipped."""

    def test_oversize_entry_skipped(self) -> None:
        """Entry exceeding max_bytes is silently rejected and returns False."""
        cache = TriePrefixCache(
            max_bytes=100,
            bytes_per_token=100,
        )
        result = cache.store([1, 2], _make_fake_cache(2))  # 200 > 100
        assert result is False
        assert len(cache) == 0
        s = cache.stats()
        assert s.stores == 0  # not counted as a store
        assert s.failures == 0  # not a failure

    def test_existing_entries_preserved_on_rejection(self) -> None:
        """Rejecting oversize entry doesn't affect existing entries."""
        cache = TriePrefixCache(
            max_bytes=300,
            bytes_per_token=100,
        )
        cache.store([1, 1], _make_fake_cache(2))  # 200 <= 300, accepted
        cache.store([2, 2], _make_fake_cache(5))  # 500 > 300, rejected
        assert len(cache) == 1
        assert cache.lookup([1, 1, 9], trim_fn=fake_trim) is not None


class TestTriePrefixDeduplication:
    """Storing a longer key removes proper-prefix entries."""

    def test_proper_prefix_removed(self) -> None:
        """Storing [1,2,3] removes existing [1,2]."""
        cache = TriePrefixCache()
        cache.store([1, 2], _make_fake_cache(2))
        assert len(cache) == 1
        cache.store([1, 2, 3], _make_fake_cache(3))
        assert len(cache) == 1  # [1,2] deduped

    def test_dedup_does_not_count_as_eviction(self) -> None:
        """Dedup removals do not increment the evictions counter."""
        cache = TriePrefixCache()
        cache.store([1, 2], _make_fake_cache(2))
        cache.store([1, 2, 3], _make_fake_cache(3))
        assert cache.stats().evictions == 0

    def test_partial_lookup_after_dedup_via_descendant(self) -> None:
        """After dedup removes [1,2], query [1,2,9] still hits via [1,2,3]."""
        cache = TriePrefixCache()
        cache.store([1, 2], _make_fake_cache(2))
        cache.store([1, 2, 3], _make_fake_cache(3))
        # [1,2] was deduped, but [1,2,3] covers the [1,2] prefix.
        hit = cache.lookup([1, 2, 9], trim_fn=fake_trim)
        assert hit is not None
        assert hit.matched_length == 2
        assert hit.remaining_ids == [9]

    def test_dedup_multiple_prefixes(self) -> None:
        """Storing [1,2,3,4] removes both [1,2] and [1,2,3]."""
        cache = TriePrefixCache()
        cache.store([1, 2], _make_fake_cache(2))
        cache.store([1, 2, 3], _make_fake_cache(3))
        cache.store([1, 2, 3, 4], _make_fake_cache(4))
        assert len(cache) == 1  # only [1,2,3,4] remains

    def test_dedup_does_not_remove_siblings(self) -> None:
        """Storing [1,2,3] does not remove [1,3] (not a proper prefix)."""
        cache = TriePrefixCache()
        cache.store([1, 3], _make_fake_cache(2))
        cache.store([1, 2, 3], _make_fake_cache(3))
        assert len(cache) == 2

    def test_bytes_updated_after_dedup(self) -> None:
        """Byte total reflects removal of deduped entries."""
        cache = TriePrefixCache(bytes_per_token=100)
        cache.store([1, 2], _make_fake_cache(2))  # 200
        cache.store([1, 2, 3], _make_fake_cache(3))  # 300, dedup removes 200
        assert cache.stats().total_bytes == 300


class TestTrieFailureSemantics:
    """Fail-open behavior and failure counter semantics."""

    def test_trim_exception_is_failure(self) -> None:
        cache = TriePrefixCache()
        cache.store([1, 2, 3, 4, 5], _make_fake_cache(5))

        def bad_trim(c: Any, n: int) -> int:
            raise RuntimeError("boom")

        result = cache.lookup([1, 2, 3], trim_fn=bad_trim)
        assert result is None
        assert cache.stats().failures == 1

    def test_trim_wrong_count_is_failure(self) -> None:
        cache = TriePrefixCache()
        cache.store([1, 2, 3, 4, 5], _make_fake_cache(5))

        def wrong_trim(c: Any, n: int) -> int:
            return n + 1

        result = cache.lookup([1, 2, 3], trim_fn=wrong_trim)
        assert result is None
        assert cache.stats().failures == 1

    def test_deepcopy_failure_in_lookup(self) -> None:
        cache = TriePrefixCache()

        class Uncopiable:
            offset = 5

            def __deepcopy__(self, memo: Any) -> None:
                raise RuntimeError("copy boom")

        cache.store([1, 2, 3, 4, 5], _make_fake_cache(5))
        # Replace internal snapshot with uncopiable object.
        entry = cache._entries[(1, 2, 3, 4, 5)]
        entry.prompt_cache = [Uncopiable()]
        result = cache.lookup([1, 2, 3, 4, 5, 6], trim_fn=fake_trim)
        assert result is None
        assert cache.stats().failures == 1

    def test_store_deepcopy_failure_reraises(self) -> None:
        cache = TriePrefixCache()

        class Uncopiable:
            offset = 3

            def __deepcopy__(self, memo: Any) -> None:
                raise RuntimeError("store boom")

        with pytest.raises(RuntimeError, match="store boom"):
            cache.store([1, 2, 3], [Uncopiable()])
        s = cache.stats()
        assert s.failures == 1
        assert s.stores == 0
        assert s.entry_count == 0


class TestTrieDeepCopyBoundaries:
    """Mutation isolation at store and lookup boundaries."""

    def test_store_isolation(self) -> None:
        """Mutating original after store does not affect stored snapshot."""
        cache = TriePrefixCache()
        original = _make_fake_cache(5)
        cache.store([1, 2, 3, 4, 5], original)
        # Mutate original.
        original[0].offset = 999
        hit = cache.lookup([1, 2, 3, 4, 5, 6], trim_fn=fake_trim)
        assert hit is not None
        assert hit.prompt_cache[0].offset != 999

    def test_lookup_isolation(self) -> None:
        """Mutating returned cache does not affect stored snapshot."""
        cache = TriePrefixCache()
        cache.store([1, 2, 3, 4, 5], _make_fake_cache(5))
        hit1 = cache.lookup([1, 2, 3, 4, 5, 6], trim_fn=fake_trim)
        assert hit1 is not None
        hit1.prompt_cache[0].offset = 999
        hit2 = cache.lookup([1, 2, 3, 4, 5, 6], trim_fn=fake_trim)
        assert hit2 is not None
        assert hit2.prompt_cache[0].offset != 999


class TestTrieClearAndStats:
    """Clear resets current state but preserves cumulative counters."""

    def test_clear_semantics(self) -> None:
        cache = TriePrefixCache(bytes_per_token=100)
        cache.store([1, 2, 3], _make_fake_cache(3))
        cache.lookup([1, 2, 3, 4], trim_fn=fake_trim)
        cache.lookup([9, 9], trim_fn=fake_trim)  # miss

        cache.clear()
        s = cache.stats()
        assert s.entry_count == 0
        assert s.total_bytes == 0
        # Cumulative counters survive clear.
        assert s.stores == 1
        assert s.hits == 1
        assert s.misses == 1

    def test_clear_allows_fresh_inserts(self) -> None:
        """Cache is usable after clear."""
        cache = TriePrefixCache()
        cache.store([1, 2, 3], _make_fake_cache(3))
        cache.clear()
        cache.store([4, 5, 6], _make_fake_cache(3))
        assert len(cache) == 1
        assert cache.lookup([4, 5, 6, 7], trim_fn=fake_trim) is not None
