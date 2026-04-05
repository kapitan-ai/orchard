"""Standalone KV prefix cache for MLX prompt-cache reuse.

Stores deep-copied MLX prompt-cache snapshots keyed by full token sequences
(prompt + generated).  On each request, longest-prefix matching finds the best
cached entry; on exact match the cache is trimmed to ``len(prompt) - 1`` so
``stream_generate()`` still receives at least one token.

This module is intentionally standalone — no imports from ``generation.py`` or
``model_loader.py``.  It uses only the standard library so it remains importable
without optional MLX dependencies.

Design decisions (see plan-kv-prefix-cache.md Phase 1):

- Entry-count LRU eviction (not memory-pressure), default ``max_entries=8``.
- Deep-copy at BOTH boundaries (store and retrieve).  ``stream_generate()``
  mutates ``prompt_cache`` in-place during prefill and decode.
- ``trim_fn`` failure in ``lookup()`` → return ``None`` (fail-open).
- Linear scan for longest-prefix match is correct because ``max_entries`` is
  intentionally small.
"""

from __future__ import annotations

import copy
import threading
from collections import OrderedDict
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from typing import Any, Protocol, runtime_checkable


# ---------------------------------------------------------------------------
# Public types
# ---------------------------------------------------------------------------


@dataclass(slots=True)
class CacheHit:
    """Result of a successful prefix-cache lookup.

    Attributes:
        prompt_cache: Deep-copied, trimmed prompt-cache snapshot ready for
            ``stream_generate()``.
        matched_length: Number of query tokens matched by the cached entry.
        remaining_ids: Tokens the caller must still feed to ``stream_generate()``.
    """

    prompt_cache: Any
    matched_length: int
    remaining_ids: list[int]


@dataclass(slots=True, frozen=True)
class PrefixCacheStats:
    """Immutable snapshot of prefix-cache state and cumulative counters.

    Current-state fields (``entry_count``, ``total_bytes``) reflect the
    cache at snapshot time.  Cumulative counters (``hits``, ``misses``,
    ``failures``, ``stores``, ``evictions``) survive ``clear()`` and
    accumulate for the lifetime of the cache object.
    """

    implementation: str
    entry_count: int
    total_bytes: int
    hits: int
    misses: int
    failures: int
    stores: int
    evictions: int


@runtime_checkable
class PrefixCache(Protocol):
    """Structural protocol for prefix-cache implementations.

    Both ``KVPrefixCache`` and future ``TriePrefixCache`` conform to this
    interface.  Production code currently uses duck typing via
    ``session.prefix_cache``; this protocol formalises the contract for
    type-checking and documentation.
    """

    def store(self, token_ids: Sequence[int], prompt_cache: Any) -> None: ...

    def lookup(
        self,
        token_ids: Sequence[int],
        *,
        trim_fn: Callable[[Any, int], Any],
    ) -> CacheHit | None: ...

    def clear(self) -> None: ...

    def stats(self) -> PrefixCacheStats: ...

    def __len__(self) -> int: ...


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def prompt_cache_length(prompt_cache: Any) -> int:
    """Best-effort token-length discovery from a prompt-cache object.

    Inspects each cache entry for ``.offset`` (preferred) or ``.size()``
    (fallback) and returns the maximum discovered length.  Returns ``0``
    for empty or unreadable caches.

    This mirrors upstream mlx-lm cache conventions (``KVCache.offset``,
    ``QuantizedKVCache.offset``, ``ChunkedKVCache.size()``) without
    importing any MLX types.
    """
    max_len = 0
    try:
        entries = iter(prompt_cache)
    except TypeError:
        return 0

    for entry in entries:
        length = _entry_length(entry)
        if length > max_len:
            max_len = length

    return max_len


def _entry_length(entry: Any) -> int:
    """Extract token length from a single cache entry."""
    # Prefer .offset (KVCache, QuantizedKVCache)
    offset = getattr(entry, "offset", None)
    if isinstance(offset, int) and not isinstance(offset, bool):
        return offset

    # Fallback to .size() (ChunkedKVCache)
    size_fn = getattr(entry, "size", None)
    if callable(size_fn):
        try:
            val = size_fn()
            if isinstance(val, int) and not isinstance(val, bool):
                return val
        except Exception:
            pass

    return 0


def _common_prefix_length(
    query: tuple[int, ...], candidate: tuple[int, ...]
) -> int:
    """Return the number of leading tokens shared by *query* and *candidate*."""
    limit = min(len(query), len(candidate))
    for i in range(limit):
        if query[i] != candidate[i]:
            return i
    return limit


# ---------------------------------------------------------------------------
# KVPrefixCache
# ---------------------------------------------------------------------------


class KVPrefixCache:
    """Entry-count LRU cache for prompt-cache snapshots keyed by token sequences.

    Parameters:
        max_entries: Maximum number of cached entries.  When exceeded, the
            least-recently-used entry is evicted.
        bytes_per_token: Optional byte-cost multiplier for estimating entry
            sizes.  When provided, ``stats().total_bytes`` reports the
            estimated memory footprint of cached snapshots.
    """

    def __init__(
        self,
        *,
        max_entries: int = 8,
        bytes_per_token: int | None = None,
    ) -> None:
        if max_entries < 1:
            raise ValueError(f"max_entries must be >= 1, got {max_entries}")
        if bytes_per_token is not None:
            if isinstance(bytes_per_token, bool) or not isinstance(bytes_per_token, int):
                raise ValueError(f"bytes_per_token must be int or None, got {type(bytes_per_token).__name__}")
            if bytes_per_token < 0:
                raise ValueError(f"bytes_per_token must be >= 0, got {bytes_per_token}")
        self._max_entries = max_entries
        self._bytes_per_token = bytes_per_token
        self._lock = threading.RLock()
        # Keys: full token sequences (tuple[int, ...]).
        # Values: deep-copied prompt-cache snapshots.
        # Order: oldest (LRU) → newest (MRU).
        self._entries: OrderedDict[tuple[int, ...], Any] = OrderedDict()
        # Per-key byte estimates for accounting.
        self._entry_bytes: dict[tuple[int, ...], int] = {}
        self._total_bytes: int = 0
        # Cumulative counters (survive clear(), accumulate for cache lifetime).
        self._hits: int = 0
        self._misses: int = 0
        self._failures: int = 0
        self._stores: int = 0
        self._evictions: int = 0

    # -- public API ---------------------------------------------------------

    def store(self, token_ids: Sequence[int], prompt_cache: Any) -> None:
        """Deep-copy and store a prompt-cache snapshot.

        If *token_ids* already exists, the entry is replaced and refreshed
        to MRU position.  Oldest entries are evicted when capacity is exceeded.
        """
        key = _normalize_key(token_ids)
        try:
            snapshot = copy.deepcopy(prompt_cache)
        except Exception:
            self._failures += 1
            raise
        entry_bytes = self._estimate_entry_bytes(snapshot)
        with self._lock:
            # Subtract old byte estimate on replacement.
            if key in self._entries:
                self._total_bytes -= self._entry_bytes.get(key, 0)
            self._entries[key] = snapshot
            self._entry_bytes[key] = entry_bytes
            self._total_bytes += entry_bytes
            self._entries.move_to_end(key, last=True)  # MRU
            self._stores += 1
            self._evict_if_needed()

    def lookup(
        self,
        token_ids: Sequence[int],
        *,
        trim_fn: Callable[[Any, int], Any],
    ) -> CacheHit | None:
        """Find the longest cached prefix matching *token_ids*.

        Parameters:
            token_ids: Query token sequence.
            trim_fn: Callable with signature ``trim_fn(cache, num_tokens)``
                that trims *num_tokens* from the end of the cache **in place**
                and returns the number of tokens actually trimmed.  Should
                match ``mlx_lm.generate.trim_prompt_cache`` semantics.

        Returns:
            A :class:`CacheHit` on success, or ``None`` on miss or any
            fail-open condition (trim failure, deep-copy failure, etc.).
        """
        with self._lock:
            if not self._entries:
                self._misses += 1
                return None

            query = _normalize_key(token_ids)
            if len(query) == 0:
                self._misses += 1
                return None

            # --- Find best prefix match ------------------------------------
            best_key: tuple[int, ...] | None = None
            best_match_len = 0

            for candidate_key in self._entries:
                match_len = _common_prefix_length(query, candidate_key)
                if match_len > best_match_len:
                    best_match_len = match_len
                    best_key = candidate_key

            if best_key is None or best_match_len == 0:
                self._misses += 1
                return None

            # --- Determine restore position --------------------------------
            # "Full-query coverage" means every query token is matched by
            # the stored key (the stored key may be longer).  In that case
            # we trim to len(query) - 1 so the caller still has at least
            # one token to feed stream_generate().
            full_query_coverage = best_match_len >= len(query)
            if full_query_coverage:
                restore_pos = len(query) - 1
            else:
                restore_pos = best_match_len

            if restore_pos <= 0:
                self._misses += 1
                return None

            # --- Deep-copy + trim ------------------------------------------
            try:
                copied_cache = copy.deepcopy(self._entries[best_key])
            except Exception:
                self._failures += 1
                return None

            stored_length = prompt_cache_length(copied_cache)
            tokens_to_trim = stored_length - restore_pos

            if tokens_to_trim < 0:
                # Stored length is shorter than expected — inconsistent.
                self._failures += 1
                return None

            if tokens_to_trim > 0:
                try:
                    trimmed = trim_fn(copied_cache, tokens_to_trim)
                except Exception:
                    self._failures += 1
                    return None

                # Validate trim_fn contract.
                if trimmed != tokens_to_trim:
                    self._failures += 1
                    return None

            # --- Build result ----------------------------------------------
            matched_length = (
                best_match_len if not full_query_coverage else len(query)
            )
            remaining_ids = list(query[restore_pos:])

            # Refresh recency only on successful lookup.
            self._entries.move_to_end(best_key, last=True)
            self._hits += 1

            return CacheHit(
                prompt_cache=copied_cache,
                matched_length=matched_length,
                remaining_ids=remaining_ids,
            )

    def clear(self) -> None:
        """Remove all cached entries.

        Resets current-state fields (entry count, byte totals) but preserves
        cumulative counters (hits, misses, failures, stores, evictions).
        """
        with self._lock:
            self._entries.clear()
            self._entry_bytes.clear()
            self._total_bytes = 0

    def stats(self) -> PrefixCacheStats:
        """Return an immutable snapshot of cache state and counters."""
        with self._lock:
            return PrefixCacheStats(
                implementation="kv",
                entry_count=len(self._entries),
                total_bytes=self._total_bytes,
                hits=self._hits,
                misses=self._misses,
                failures=self._failures,
                stores=self._stores,
                evictions=self._evictions,
            )

    def __len__(self) -> int:
        """Return the number of cached entries."""
        with self._lock:
            return len(self._entries)

    # -- private helpers ----------------------------------------------------

    def _estimate_entry_bytes(self, prompt_cache: Any) -> int:
        """Estimate byte cost of a prompt-cache snapshot."""
        if self._bytes_per_token is None:
            return 0
        return prompt_cache_length(prompt_cache) * self._bytes_per_token

    def _evict_if_needed(self) -> None:
        """Evict oldest entries until within capacity.

        Must be called while holding ``_lock``.
        """
        while len(self._entries) > self._max_entries:
            key, _ = self._entries.popitem(last=False)  # Remove oldest
            self._total_bytes -= self._entry_bytes.pop(key, 0)
            self._evictions += 1


def _normalize_key(token_ids: Sequence[int]) -> tuple[int, ...]:
    """Convert any int sequence to a hashable tuple key."""
    if isinstance(token_ids, tuple):
        return token_ids
    return tuple(token_ids)
