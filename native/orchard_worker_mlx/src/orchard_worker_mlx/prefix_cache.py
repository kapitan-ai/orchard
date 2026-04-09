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

    def store(self, token_ids: Sequence[int], prompt_cache: Any) -> bool:
        """Store a snapshot.  Returns True if stored, False if rejected."""
        ...

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


def _common_prefix_length(query: tuple[int, ...], candidate: tuple[int, ...]) -> int:
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
                raise ValueError(
                    f"bytes_per_token must be int or None, got {type(bytes_per_token).__name__}"
                )
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

    def store(self, token_ids: Sequence[int], prompt_cache: Any) -> bool:
        """Deep-copy and store a prompt-cache snapshot.

        If *token_ids* already exists, the entry is replaced and refreshed
        to MRU position.  Oldest entries are evicted when capacity is exceeded.

        Returns ``True`` (always accepted; KVPrefixCache has no rejection).
        Raises on deep-copy failure.
        """
        key = _normalize_key(token_ids)
        try:
            snapshot = copy.deepcopy(prompt_cache)
        except Exception:
            with self._lock:
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
        return True

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
            matched_length = best_match_len if not full_query_coverage else len(query)
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


# ---------------------------------------------------------------------------
# Trie internals (private)
# ---------------------------------------------------------------------------


class _TrieNode:
    """Internal trie node for ``TriePrefixCache``."""

    __slots__ = ("token", "parent", "children", "terminal_entry", "subtree_representative")

    def __init__(
        self,
        token: int | None = None,
        parent: _TrieNode | None = None,
    ) -> None:
        self.token = token
        self.parent = parent
        self.children: dict[int, _TrieNode] = {}
        self.terminal_entry: _CacheEntry | None = None
        # Any terminal entry reachable from this subtree (including self).
        # Used by lookup to resolve partial-prefix matches after dedup.
        self.subtree_representative: _CacheEntry | None = None


@dataclass(slots=True)
class _CacheEntry:
    """Internal entry stored in ``TriePrefixCache``."""

    key: tuple[int, ...]
    prompt_cache: Any
    byte_size: int
    node: _TrieNode


# ---------------------------------------------------------------------------
# TriePrefixCache
# ---------------------------------------------------------------------------


class TriePrefixCache:
    """Trie-based prefix cache with byte-budget eviction.

    Uses a token trie for ``O(token_len)`` prefix lookup and an
    ``OrderedDict`` for global access-LRU ordering.  Conforms to the
    :class:`PrefixCache` protocol with the same behavioral contracts
    as :class:`KVPrefixCache`:

    - Deep-copy at both store and lookup boundaries.
    - Trailing-token remainder on exact/full-query hits.
    - Access-LRU promotion on successful lookup.
    - Fail-open lookup (never raises cache-internal errors).

    Additional features over ``KVPrefixCache``:

    - **Byte-budget eviction** via ``max_bytes``.
    - **Prefix deduplication** on store: proper-prefix entries of the
      new key are removed because the longer key subsumes them.
    - **Oversize entry rejection**: entries exceeding ``max_bytes``
      are silently skipped.

    Parameters:
        max_entries: Maximum number of cached entries (secondary cap).
        max_bytes: Maximum estimated bytes across all entries.  ``None``
            or ``0`` disables byte-budget eviction.
        bytes_per_token: Byte-cost multiplier for estimating entry sizes.
    """

    def __init__(
        self,
        *,
        max_entries: int = 8,
        max_bytes: int | None = None,
        bytes_per_token: int | None = None,
    ) -> None:
        if max_entries < 1:
            raise ValueError(f"max_entries must be >= 1, got {max_entries}")
        if bytes_per_token is not None:
            if isinstance(bytes_per_token, bool) or not isinstance(bytes_per_token, int):
                raise ValueError(
                    f"bytes_per_token must be int or None, got {type(bytes_per_token).__name__}"
                )
            if bytes_per_token < 0:
                raise ValueError(f"bytes_per_token must be >= 0, got {bytes_per_token}")
        if max_bytes is not None:
            if isinstance(max_bytes, bool) or not isinstance(max_bytes, int):
                raise ValueError(f"max_bytes must be int or None, got {type(max_bytes).__name__}")
            if max_bytes < 0:
                raise ValueError(f"max_bytes must be >= 0, got {max_bytes}")
        self._max_entries = max_entries
        # Treat 0 as disabled (same as None).
        self._max_bytes: int | None = max_bytes if max_bytes else None
        self._bytes_per_token = bytes_per_token
        self._lock = threading.RLock()
        self._root = _TrieNode()
        # Global access-LRU: oldest → newest.
        self._entries: OrderedDict[tuple[int, ...], _CacheEntry] = OrderedDict()
        self._total_bytes: int = 0
        # Cumulative counters (survive clear()).
        self._hits: int = 0
        self._misses: int = 0
        self._failures: int = 0
        self._stores: int = 0
        self._evictions: int = 0

    # -- public API ---------------------------------------------------------

    def store(self, token_ids: Sequence[int], prompt_cache: Any) -> bool:
        """Deep-copy and store a prompt-cache snapshot.

        If *token_ids* already exists, the entry is replaced.  Entries
        whose keys are proper prefixes of the new key are deduplicated.
        Oldest entries are evicted when capacity or byte budget is exceeded.

        Returns ``True`` if the entry was accepted, ``False`` if it was
        rejected (e.g., exceeds ``max_bytes``).  Raises on deep-copy
        failure.
        """
        key = _normalize_key(token_ids)
        try:
            snapshot = copy.deepcopy(prompt_cache)
        except Exception:
            with self._lock:
                self._failures += 1
            raise
        entry_bytes = self._estimate_entry_bytes(snapshot)

        # Reject oversize entries before taking the lock.
        if self._max_bytes is not None and entry_bytes > self._max_bytes:
            return False

        with self._lock:
            # --- Same-key replacement --------------------------------------
            if key in self._entries:
                old = self._entries[key]
                old.prompt_cache = snapshot
                self._total_bytes -= old.byte_size
                old.byte_size = entry_bytes
                self._total_bytes += entry_bytes
                self._entries.move_to_end(key, last=True)
                self._stores += 1
                self._evict_if_needed()
                return True

            # --- Insert new entry ------------------------------------------
            node = self._ensure_path(key)
            entry = _CacheEntry(
                key=key,
                prompt_cache=snapshot,
                byte_size=entry_bytes,
                node=node,
            )
            node.terminal_entry = entry
            self._entries[key] = entry
            self._total_bytes += entry_bytes
            self._refresh_representative_upward(node)

            # --- Prefix deduplication --------------------------------------
            self._dedup_proper_prefixes(key)

            self._stores += 1
            self._evict_if_needed()
        return True

    def lookup(
        self,
        token_ids: Sequence[int],
        *,
        trim_fn: Callable[[Any, int], Any],
    ) -> CacheHit | None:
        """Find the longest cached prefix matching *token_ids*.

        Uses trie traversal with subtree-representative metadata for
        ``O(token_len)`` lookup.  Returns ``None`` on miss or any
        fail-open condition.
        """
        with self._lock:
            if not self._entries:
                self._misses += 1
                return None

            query = _normalize_key(token_ids)
            if len(query) == 0:
                self._misses += 1
                return None

            # --- Trie walk -------------------------------------------------
            best_entry: _CacheEntry | None = None
            best_match_len = 0
            current = self._root

            for depth_idx, tok in enumerate(query, start=1):
                child = current.children.get(tok)
                if child is None:
                    break
                current = child
                if current.subtree_representative is not None:
                    best_entry = current.subtree_representative
                    best_match_len = depth_idx

            if best_entry is None or best_match_len == 0:
                self._misses += 1
                return None

            # --- Determine restore position --------------------------------
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
                copied_cache = copy.deepcopy(best_entry.prompt_cache)
            except Exception:
                self._failures += 1
                return None

            stored_length = prompt_cache_length(copied_cache)
            tokens_to_trim = stored_length - restore_pos

            if tokens_to_trim < 0:
                self._failures += 1
                return None

            if tokens_to_trim > 0:
                try:
                    trimmed = trim_fn(copied_cache, tokens_to_trim)
                except Exception:
                    self._failures += 1
                    return None

                if trimmed != tokens_to_trim:
                    self._failures += 1
                    return None

            # --- Build result ----------------------------------------------
            matched_length = len(query) if full_query_coverage else best_match_len
            remaining_ids = list(query[restore_pos:])

            # Promote matched entry to MRU.
            self._entries.move_to_end(best_entry.key, last=True)
            self._hits += 1

            return CacheHit(
                prompt_cache=copied_cache,
                matched_length=matched_length,
                remaining_ids=remaining_ids,
            )

    def clear(self) -> None:
        """Remove all cached entries.

        Resets trie structure and byte totals but preserves cumulative
        counters.
        """
        with self._lock:
            self._root = _TrieNode()
            self._entries.clear()
            self._total_bytes = 0

    def stats(self) -> PrefixCacheStats:
        """Return an immutable snapshot of cache state and counters."""
        with self._lock:
            return PrefixCacheStats(
                implementation="trie",
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

    # -- private helpers (must be called with _lock held) -------------------

    def _estimate_entry_bytes(self, prompt_cache: Any) -> int:
        """Estimate byte cost of a prompt-cache snapshot."""
        if self._bytes_per_token is None:
            return 0
        return prompt_cache_length(prompt_cache) * self._bytes_per_token

    def _ensure_path(self, key: tuple[int, ...]) -> _TrieNode:
        """Create trie nodes along *key*, returning the terminal node."""
        current = self._root
        for tok in key:
            child = current.children.get(tok)
            if child is None:
                child = _TrieNode(token=tok, parent=current)
                current.children[tok] = child
            current = child
        return current

    def _remove_entry(self, entry: _CacheEntry) -> None:
        """Remove *entry* from trie, LRU, and byte accounting.

        Prunes empty nodes upward and refreshes subtree representatives.
        """
        node = entry.node
        node.terminal_entry = None
        del self._entries[entry.key]
        self._total_bytes -= entry.byte_size

        # Prune empty leaf nodes upward.
        self._prune_upward(node)
        # Refresh representative pointers along the affected path.
        self._refresh_representative_upward(node)

    def _prune_upward(self, node: _TrieNode) -> None:
        """Remove empty non-root leaf nodes upward."""
        current = node
        while (
            current.parent is not None and current.terminal_entry is None and not current.children
        ):
            parent = current.parent
            if current.token is not None:
                parent.children.pop(current.token, None)
            current = parent

    def _refresh_representative_upward(self, node: _TrieNode) -> None:
        """Recompute ``subtree_representative`` from *node* up to root."""
        current: _TrieNode | None = node
        while current is not None:
            current.subtree_representative = self._recompute_representative(current)
            current = current.parent

    def _recompute_representative(self, node: _TrieNode) -> _CacheEntry | None:
        """Return a representative terminal entry for *node*'s subtree."""
        if node.terminal_entry is not None:
            return node.terminal_entry
        for child in node.children.values():
            if child.subtree_representative is not None:
                return child.subtree_representative
        return None

    def _dedup_proper_prefixes(self, key: tuple[int, ...]) -> None:
        """Remove entries whose keys are proper prefixes of *key*.

        Does NOT increment ``_evictions`` — dedup is not capacity-driven.
        """
        current = self._root
        for i, tok in enumerate(key[:-1]):  # exclude terminal position
            child = current.children.get(tok)
            if child is None:
                break
            current = child
            if current.terminal_entry is not None:
                prefix_entry = current.terminal_entry
                # Verify it's actually a proper prefix of our key.
                if prefix_entry.key == key[: i + 1]:
                    self._remove_entry(prefix_entry)

    def _evict_if_needed(self) -> None:
        """Evict oldest entries until within capacity and byte budget."""
        while len(self._entries) > self._max_entries:
            _, oldest = self._entries.popitem(last=False)
            oldest.node.terminal_entry = None
            self._total_bytes -= oldest.byte_size
            self._prune_upward(oldest.node)
            self._refresh_representative_upward(oldest.node)
            self._evictions += 1

        if self._max_bytes is not None:
            while self._total_bytes > self._max_bytes and self._entries:
                _, oldest = self._entries.popitem(last=False)
                oldest.node.terminal_entry = None
                self._total_bytes -= oldest.byte_size
                self._prune_upward(oldest.node)
                self._refresh_representative_upward(oldest.node)
                self._evictions += 1
