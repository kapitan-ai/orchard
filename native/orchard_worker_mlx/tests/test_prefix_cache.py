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
