"""Real MLX token generation via mlx_lm.stream_generate().

This module owns request-time generation only: prompt decode/encode, sampler
construction, stream_generate invocation, prefill progress bridging, stop-
sequence buffering, Orchard-level EOS detection, delta normalization, terminal
event emission, usage accounting, and strided decode-phase cancel checks.

It does NOT own model lifecycle, gRPC/proto conversion, or accepted events.

Request-local KV prefix-cache lookup/store (Task 6):
    When ``session.prefix_cache`` is a live ``KVPrefixCache`` and the
    generation deps include prompt-cache helpers, this module performs
    cache lookup before ``stream_generate()`` and stores the mutated
    cache on successful completion only.  All cache operations are
    fail-open: errors fall through to uncached generation.

Key invariant — add_special_tokens=False:
    ``request.rendered_prompt_utf8`` arrives fully rendered by the controller
    (chat template, system prompt scaffolding, BOS tokens already applied).
    This module tokenizes the rendered prompt **without** adding tokenizer-
    level special tokens.  Violating this would duplicate BOS/chat-template
    tokens, alter prompt semantics, and skew usage counts.

Stop-sequence buffering (Task 4):
    Deltas emitted to downstream consumers are irreversible (gRPC stream).
    ``StopSequenceBuffer`` withholds a trailing suffix that could still match
    a configured stop sequence, emitting only the safe prefix.  When a stop
    is found the marker is suppressed and ``finish_reason = STOP`` is set.
    On non-stop terminals (EOS, length, cancel) the buffer is flushed.

Orchard-level EOS detection (Task 4):
    ``mlx_lm.stream_generate()`` only honors ``tokenizer.eos_token_id``
    (singular).  Models with config-only EOS IDs are not covered.  This
    module checks each ``response.token`` against ``session.eos_token_ids``
    (computed at load time by ``_normalize_eos_token_ids()``) for
    comprehensive stop handling.

Prefill progress bridging (Task 5):
    ``mlx_lm.stream_generate()`` accepts ``prompt_progress_callback`` and
    ``prefill_step_size`` kwargs.  The callback is invoked synchronously
    during prefill with ``(processed_tokens, total_tokens)``.  This module
    bridges the synchronous callback into yielded ``progress`` events by
    queuing updates in a request-local deque and draining them before each
    token delta.  Prefill cancel is NOT cleanly interruptible — upstream
    ``generate_step()`` has no cancel hook; cancellation applies only after
    control returns from prefill (i.e., during decode).
"""

from __future__ import annotations

import threading
from collections import deque
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from typing import Any

from orchard_worker_mlx.backends import BackendError, cancelled_event


# ---------------------------------------------------------------------------
# Dependency injection seam (mirrors MLXDeps in model_loader.py)
# ---------------------------------------------------------------------------


@dataclass(slots=True, frozen=True)
class GenerationDeps:
    """Narrow test seam for mocked MLX generation.

    NOTE: ``stream_generate`` is also injected in ``model_loader.MLXDeps``
    for warmup inference during load.  The two injection points are
    intentionally separate (different lifecycle: load-time warmup vs
    request-time generation), but both import from
    ``mlx_lm.generate.stream_generate`` in production.  Keep them in sync
    if the upstream API changes.
    """

    stream_generate: Callable[..., Iterator[Any]]
    make_sampler: Callable[..., Any]
    make_prompt_cache: Callable[[Any], Any] | None = None
    trim_prompt_cache: Callable[[Any, int], int] | None = None


def _default_generation_deps() -> GenerationDeps:
    """Import real MLX generation dependencies lazily."""
    try:
        from mlx_lm.generate import stream_generate
        from mlx_lm.sample_utils import make_sampler
    except ImportError as exc:
        raise BackendError(
            "mlx_backend_unavailable",
            f"MLX generation dependencies not available: {exc}",
        ) from exc

    # Optional prompt-cache helpers — fail-open if unavailable.
    _make_prompt_cache: Callable[[Any], Any] | None = None
    _trim_prompt_cache: Callable[[Any, int], int] | None = None
    try:
        from mlx_lm.models.cache import (
            make_prompt_cache as _make,
            trim_prompt_cache as _trim,
        )
        _make_prompt_cache = _make
        _trim_prompt_cache = _trim
    except (ImportError, AttributeError):
        pass

    return GenerationDeps(
        stream_generate=stream_generate,
        make_sampler=make_sampler,
        make_prompt_cache=_make_prompt_cache,
        trim_prompt_cache=_trim_prompt_cache,
    )


# ---------------------------------------------------------------------------
# Stop-sequence buffer
# ---------------------------------------------------------------------------


@dataclass(slots=True)
class StopSequenceBuffer:
    """Buffer that withholds text that could still match a stop sequence.

    Operates on Python ``str`` (already decoded from MLX).  Multi-byte UTF-8
    is safe because Python string indexing operates on Unicode code points.

    When no stop sequences are configured, ``push()`` passes text through
    immediately and ``flush()`` is a no-op.
    """

    stop_sequences: tuple[str, ...]
    max_stop_len: int
    pending: str = ""

    def push(self, delta: str) -> tuple[str, bool]:
        """Append *delta* and return ``(safe_text, matched_stop)``.

        *safe_text* is the prefix that cannot be part of a stop sequence.
        *matched_stop* is ``True`` when a stop sequence was found and
        suppressed.
        """
        if not self.stop_sequences:
            return (delta, False)

        self.pending += delta

        # Search for the earliest (and longest on tie) stop sequence.
        best_pos: int | None = None
        best_len: int = 0
        for seq in self.stop_sequences:
            pos = self.pending.find(seq)
            if pos != -1:
                if best_pos is None or pos < best_pos or (
                    pos == best_pos and len(seq) > best_len
                ):
                    best_pos = pos
                    best_len = len(seq)

        if best_pos is not None:
            emit = self.pending[:best_pos]
            self.pending = ""
            return (emit, True)

        # No match: retain a suffix that could still become a partial match.
        retain = self.max_stop_len - 1
        if retain <= 0:
            emit = self.pending
            self.pending = ""
            return (emit, False)

        if len(self.pending) <= retain:
            return ("", False)

        emit = self.pending[:-retain]
        self.pending = self.pending[-retain:]
        return (emit, False)

    def flush(self) -> str:
        """Return all remaining pending text and clear the buffer."""
        text = self.pending
        self.pending = ""
        return text


# ---------------------------------------------------------------------------
# Stop / cancel / EOS helpers
# ---------------------------------------------------------------------------


def _normalize_stop_sequences(params: Any) -> tuple[str, ...]:
    """Extract and deduplicate stop sequences from request params.

    Returns an empty tuple when no valid stop sequences are present.
    Invalid entries (non-string, empty) are silently dropped.
    """
    raw = getattr(params, "stop_sequences", None) if params else None
    if not raw:
        return ()
    seen: set[str] = set()
    result: list[str] = []
    for item in raw:
        if isinstance(item, str) and item and item not in seen:
            seen.add(item)
            result.append(item)
    return tuple(result)


def _decode_cancel_stride(session: Any) -> int:
    """Read cancel stride from session, clamping invalid values to 1."""
    raw = getattr(session, "decode_cancel_stride", 1)
    if isinstance(raw, bool) or not isinstance(raw, int) or raw < 1:
        return 1
    return raw


def _response_token_id(response: Any) -> int | None:
    """Extract token ID from a generation response, or None."""
    token = getattr(response, "token", None)
    if isinstance(token, bool) or not isinstance(token, int):
        return None
    return token


def _close_stream(stream: Any) -> None:
    """Best-effort close of a stream_generate iterator."""
    close = getattr(stream, "close", None)
    if close is not None:
        try:
            close()
        except Exception:
            pass


def _prefill_step_size(session: Any) -> int:
    """Read prefill step size from session, defaulting to 2048."""
    raw = getattr(session, "prefill_step_size", 2048)
    if isinstance(raw, bool) or not isinstance(raw, int) or raw < 1:
        return 2048
    return raw


def _make_prefill_progress_callback(
    queue: deque[tuple[int, int]],
) -> Callable[[int, int], None]:
    """Build a callback for ``prompt_progress_callback`` that queues updates.

    The callback is invoked synchronously by ``mlx_lm.generate_step()``
    during chunked prefill with ``(processed_tokens, total_tokens)``.

    THREAD-SAFETY: Both ``queue`` (``collections.deque``) and ``last``
    (plain list used as mutable closure cell) are **unsynchronized**.  This
    is correct because upstream ``mlx_lm.stream_generate()`` invokes the
    callback synchronously on the same thread that drives the iterator.
    All callback invocations complete before the first ``yield`` from the
    iterator, so there is no concurrent access between callback writes
    and ``generate_events()``'s drain reads.  If upstream ever changes to
    invoke the callback from a background thread, this bridge must be
    updated to use a ``threading.Lock`` around ``last`` and a thread-safe
    queue.

    Sanitization rules:
    - Reject booleans and non-ints.
    - Reject ``total <= 0``.
    - Clamp ``processed`` to ``[0, total]``.
    - Reject ``processed == 0`` (initial zero-progress call is noise).
    - Drop duplicate or non-monotonic updates.
    """
    last: list[tuple[int, int]] = []  # mutable cell: [(last_processed, last_total)]

    def callback(processed: int, total: int) -> None:
        # Type guards.
        if isinstance(processed, bool) or not isinstance(processed, int):
            return
        if isinstance(total, bool) or not isinstance(total, int):
            return
        if total <= 0:
            return

        # Clamp processed into [0, total].
        processed = max(0, min(processed, total))

        # Skip initial zero-progress call.
        if processed == 0:
            return

        # Monotonicity check.
        if last:
            prev_processed, prev_total = last[0]
            if total < prev_total:
                return  # total decreased — nonsensical
            if total == prev_total and processed <= prev_processed:
                return  # not advancing

        last.clear()
        last.append((processed, total))
        queue.append((processed, total))

    return callback


def _drain_prefill_progress(
    queue: deque[tuple[int, int]],
) -> Iterator[dict[str, Any]]:
    """Yield queued prefill progress as ``progress`` event dicts."""
    while queue:
        processed, total = queue.popleft()
        yield {
            "kind": "progress",
            "stage": "prefill",
            "message": f"processed {processed}/{total} prompt tokens",
        }


def _safe_clear_session_cache(session: Any) -> None:
    """Best-effort post-generation memory cleanup."""
    clear_fn = getattr(session, "clear_cache", None)
    if callable(clear_fn):
        try:
            clear_fn()
        except Exception:
            pass


# ---------------------------------------------------------------------------
# KV prefix-cache helpers (Task 6)
# ---------------------------------------------------------------------------


def _prepare_prompt_cache(
    session: Any,
    prompt_ids: list[int],
    *,
    deps: GenerationDeps,
) -> tuple[Any | None, list[int]]:
    """Prepare a request-local prompt cache and adjusted prompt IDs.

    Returns ``(request_prompt_cache, ids_for_stream)``.  On any failure
    or when caching is disabled, returns ``(None, prompt_ids)`` so the
    caller falls through to uncached generation.
    """
    prefix_cache = getattr(session, "prefix_cache", None)
    if prefix_cache is None:
        return (None, prompt_ids)
    if deps.make_prompt_cache is None or deps.trim_prompt_cache is None:
        return (None, prompt_ids)

    try:
        hit = prefix_cache.lookup(prompt_ids, trim_fn=deps.trim_prompt_cache)
        if hit is not None:
            return (hit.prompt_cache, hit.remaining_ids)
        # Miss: create a fresh request-local prompt cache so a successful
        # generation can seed a future store.
        fresh = deps.make_prompt_cache(session.model)
        return (fresh, prompt_ids)
    except Exception:
        return (None, prompt_ids)


def _maybe_store_prompt_cache(
    session: Any,
    prompt_ids: list[int],
    generated_token_ids: list[int],
    *,
    prompt_cache: Any | None,
) -> None:
    """Best-effort store of mutated prompt cache after successful generation.

    Stores the full sequence (``prompt_ids + generated_token_ids``) as the
    cache key.  All exceptions are swallowed (fail-open).
    """
    prefix_cache = getattr(session, "prefix_cache", None)
    if prefix_cache is None or prompt_cache is None:
        return
    try:
        full_key = prompt_ids + generated_token_ids
        prefix_cache.store(full_key, prompt_cache)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def generate_events(
    session: Any,
    request: Any,
    cancel_event: threading.Event,
    *,
    deps: GenerationDeps | None = None,
) -> Iterator[dict[str, Any]]:
    """Generate inference events from a loaded model session.

    Yields dicts matching ``service.py``'s ``build_inference_event()``
    expectations:

    - ``{"kind": "progress", "stage": "prefill", "message": "..."}``
    - ``{"kind": "output_text_delta", "delta": "..."}``
    - ``{"kind": "completed", "finish_reason": "...", "usage": {...}}``
    - ``{"kind": "failed", "code": "...", ...}``  (via ``cancelled_event()``)

    Prefill progress is bridged from ``prompt_progress_callback`` into
    yielded ``progress`` events before token deltas.  Stop sequences are
    suppressed via ``StopSequenceBuffer``.  Orchard-level EOS detection
    checks ``session.eos_token_ids`` per response.  Cancel is checked every
    ``session.decode_cancel_stride`` tokens during decode.

    NOTE(task-5): Prefill cancel is NOT cleanly interruptible.  Upstream
    ``generate_step()`` has no cancel hook.  Cancellation applies only
    after control returns from prefill (i.e., during decode).  This is a
    known limitation documented rather than worked around.

    Raises ``BackendError`` for setup-time failures (invalid prompt, etc.).
    """
    if deps is None:
        deps = _default_generation_deps()

    # --- Step 1: decode the prompt ---
    prompt_text = _decode_prompt(request.rendered_prompt_utf8)

    # --- Step 2: read generation params ---
    params = getattr(request, "params", None)
    max_output_tokens = _safe_int(getattr(params, "max_output_tokens", 0) if params else 0)
    temperature = _safe_float(getattr(params, "temperature", 0.0) if params else 0.0)
    top_p = _safe_float(getattr(params, "top_p", 0.0) if params else 0.0)
    input_tokens = _safe_int(getattr(request, "input_tokens", 0))
    stop_sequences = _normalize_stop_sequences(params)

    # max_output_tokens <= 0: immediate completed with FINISH_REASON_LENGTH
    if max_output_tokens <= 0:
        yield _completed_event("FINISH_REASON_LENGTH", input_tokens, 0)
        return

    # --- Step 3: encode prompt ---
    prompt_ids = _encode_prompt(session.tokenizer, prompt_text)

    # --- Step 4: build sampler ---
    sampler = _build_sampler(temperature, top_p, deps)

    # --- Step 5: prepare request-local state ---
    stride = _decode_cancel_stride(session)
    eos_ids: frozenset[int] = frozenset(getattr(session, "eos_token_ids", ()))
    max_stop_len = max((len(s) for s in stop_sequences), default=0)
    buf = StopSequenceBuffer(
        stop_sequences=stop_sequences,
        max_stop_len=max_stop_len,
    )

    # Prefill progress queue: callback appends, loop drains before deltas.
    progress_queue: deque[tuple[int, int]] = deque()
    progress_callback = _make_prefill_progress_callback(progress_queue)

    # Pre-cancel check
    if cancel_event.is_set():
        yield cancelled_event()
        return

    # --- Step 5b: prefix-cache lookup (Task 6) ---
    request_prompt_cache, stream_prompt_ids = _prepare_prompt_cache(
        session, prompt_ids, deps=deps,
    )

    # --- Step 6: call stream_generate ---
    # NOTE(task-5): prefill_step_size and prompt_progress_callback are
    # forwarded by stream_generate() to generate_step().  Upstream handles
    # chunked prefill; Orchard bridges the callback into yielded events.
    stream_kwargs: dict[str, Any] = {
        "max_tokens": max_output_tokens,
        "sampler": sampler,
        "prefill_step_size": _prefill_step_size(session),
        "prompt_progress_callback": progress_callback,
    }
    if request_prompt_cache is not None:
        stream_kwargs["prompt_cache"] = request_prompt_cache

    stream = deps.stream_generate(
        session.model,
        session.tokenizer,
        stream_prompt_ids,
        **stream_kwargs,
    )

    # --- Step 7: per-item decode loop ---
    # Wrap stream consumption in try/finally to guarantee post-generation
    # cache cleanup on ALL exit paths — including mid-iteration exceptions
    # from the MLX stream (e.g., Metal errors, OOM) which would otherwise
    # propagate to service.py without cleanup.
    try:
        output_tokens = 0
        generated_token_ids: list[int] = []
        can_store = True
        for response in stream:
            # Drain any queued prefill progress before handling token deltas.
            # The callback is synchronous — all prefill updates are already
            # queued by the time the first response arrives.
            yield from _drain_prefill_progress(progress_queue)

            # Every yielded GenerationResponse represents one generated token,
            # even when detokenization buffers produce empty text.  Count it
            # unconditionally for usage; only emit a delta when text is present.
            output_tokens += 1

            # --- Strided cancel check ---
            if output_tokens % stride == 0 and cancel_event.is_set():
                # Flush buffered text: cancellation removes future ambiguity,
                # so withheld text should not be silently dropped.
                flush_text = buf.flush()
                if flush_text:
                    yield {"kind": "output_text_delta", "delta": flush_text}
                _close_stream(stream)
                yield cancelled_event()
                return

            delta_text = response.text
            finish_reason = response.finish_reason

            # --- Orchard-level EOS detection ---
            # mlx_lm only honors tokenizer.eos_token_id (singular); check the
            # full session.eos_token_ids set for config-only stop tokens.
            token_id = _response_token_id(response)
            orchard_eos = (
                token_id is not None
                and bool(eos_ids)
                and token_id in eos_ids
                and finish_reason is None  # upstream didn't already terminate
            )

            # --- Cache store key tracking (Task 6) ---
            if token_id is None:
                can_store = False
            elif can_store:
                generated_token_ids.append(token_id)

            # --- Push text through stop-sequence buffer ---
            if delta_text:
                safe_text, stop_matched = buf.push(delta_text)
            else:
                safe_text, stop_matched = "", False

            if stop_matched:
                # Stop sequence found: emit pre-match text, suppress marker.
                if safe_text:
                    yield {"kind": "output_text_delta", "delta": safe_text}
                _close_stream(stream)
                if can_store:
                    _maybe_store_prompt_cache(
                        session, prompt_ids, generated_token_ids,
                        prompt_cache=request_prompt_cache,
                    )
                yield _completed_event("FINISH_REASON_STOP", input_tokens, output_tokens)
                return

            if orchard_eos:
                # Orchard-level EOS: flush buffer and terminate.
                if safe_text:
                    yield {"kind": "output_text_delta", "delta": safe_text}
                flush_text = buf.flush()
                if flush_text:
                    yield {"kind": "output_text_delta", "delta": flush_text}
                _close_stream(stream)
                if can_store:
                    _maybe_store_prompt_cache(
                        session, prompt_ids, generated_token_ids,
                        prompt_cache=request_prompt_cache,
                    )
                yield _completed_event("FINISH_REASON_STOP", input_tokens, output_tokens)
                return

            if finish_reason is not None:
                # Upstream terminal from mlx_lm.  Flush all buffered text.
                if safe_text:
                    yield {"kind": "output_text_delta", "delta": safe_text}
                flush_text = buf.flush()
                if flush_text:
                    yield {"kind": "output_text_delta", "delta": flush_text}

                if can_store:
                    _maybe_store_prompt_cache(
                        session, prompt_ids, generated_token_ids,
                        prompt_cache=request_prompt_cache,
                    )
                if finish_reason == "stop":
                    yield _completed_event("FINISH_REASON_STOP", input_tokens, output_tokens)
                else:  # "length"
                    yield _completed_event("FINISH_REASON_LENGTH", input_tokens, output_tokens)
                return

            # Non-terminal: emit safe text if non-empty.
            if safe_text:
                yield {"kind": "output_text_delta", "delta": safe_text}

        # --- Step 8: iterator exhaustion without finish_reason ---
        # Defensive: mlx_lm should always yield a final response with
        # finish_reason set, but handle gracefully.
        # Drain any remaining prefill progress (edge case: zero decode tokens).
        yield from _drain_prefill_progress(progress_queue)
        flush_text = buf.flush()
        if flush_text:
            yield {"kind": "output_text_delta", "delta": flush_text}
        if cancel_event.is_set():
            yield cancelled_event()
        else:
            if can_store:
                _maybe_store_prompt_cache(
                    session, prompt_ids, generated_token_ids,
                    prompt_cache=request_prompt_cache,
                )
            yield _completed_event("FINISH_REASON_STOP", input_tokens, output_tokens)
    finally:
        _safe_clear_session_cache(session)


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _decode_prompt(payload: bytes | str | None) -> str:
    """Decode rendered_prompt_utf8 into a string.

    Raises ``BackendError("invalid_prompt_utf8")`` on decode failure.
    """
    if payload is None:
        raise BackendError(
            "invalid_prompt_utf8",
            "rendered_prompt_utf8 is missing",
            False,
        )
    if isinstance(payload, str):
        return payload
    if isinstance(payload, (bytes, bytearray, memoryview)):
        try:
            return bytes(payload).decode("utf-8")
        except UnicodeDecodeError as exc:
            raise BackendError(
                "invalid_prompt_utf8",
                f"rendered_prompt_utf8 is not valid UTF-8: {exc}",
                False,
            ) from exc
    raise BackendError(
        "invalid_prompt_utf8",
        f"rendered_prompt_utf8 has unsupported type: {type(payload).__name__}",
        False,
    )


def _encode_prompt(tokenizer: Any, prompt_text: str) -> list[int]:
    """Encode prompt text into token IDs.

    Uses ``add_special_tokens=False`` because the controller already renders
    the final prompt (chat template, BOS, system scaffolding).  Do not change
    this without coordinating with the controller's prompt pipeline.
    """
    try:
        # WARNING: add_special_tokens must stay False — see module docstring.
        return tokenizer.encode(prompt_text, add_special_tokens=False)
    except Exception as exc:
        raise BackendError(
            "generation_failed",
            f"prompt tokenization failed: {exc}",
            False,
        ) from exc


def _build_sampler(temperature: float, top_p: float, deps: GenerationDeps) -> Any:
    """Build a sampler from request parameters."""
    kwargs: dict[str, Any] = {}
    if temperature > 0:
        kwargs["temp"] = temperature
    if 0 < top_p < 1.0:
        kwargs["top_p"] = top_p
    return deps.make_sampler(**kwargs)


def _completed_event(
    finish_reason: str, input_tokens: int, output_tokens: int
) -> dict[str, Any]:
    """Build a terminal completed event dict."""
    return {
        "kind": "completed",
        "finish_reason": finish_reason,
        "usage": {
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "total_tokens": input_tokens + output_tokens,
        },
    }


def _safe_int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _safe_float(value: Any, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default
