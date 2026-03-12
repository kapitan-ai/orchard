"""Real MLX token generation via mlx_lm.stream_generate().

This module owns request-time generation only: prompt decode/encode, sampler
construction, stream_generate invocation, stop-sequence buffering, Orchard-
level EOS detection, delta normalization, terminal event emission, usage
accounting, and strided decode-phase cancel checks.

It does NOT own model lifecycle, gRPC/proto conversion, accepted/progress
events, or prefix cache (Task 6).

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
"""

from __future__ import annotations

import threading
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from typing import Any

from orchard_worker_mlx.backends import BackendError, cancelled_event


# ---------------------------------------------------------------------------
# Dependency injection seam (mirrors MLXDeps in model_loader.py)
# ---------------------------------------------------------------------------


@dataclass(slots=True, frozen=True)
class GenerationDeps:
    """Narrow test seam for mocked MLX generation."""

    stream_generate: Callable[..., Iterator[Any]]
    make_sampler: Callable[..., Any]


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

    return GenerationDeps(
        stream_generate=stream_generate,
        make_sampler=make_sampler,
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

    - ``{"kind": "output_text_delta", "delta": "..."}``
    - ``{"kind": "completed", "finish_reason": "...", "usage": {...}}``
    - ``{"kind": "failed", "code": "...", ...}``  (via ``cancelled_event()``)

    Stop sequences are suppressed via ``StopSequenceBuffer``.  Orchard-level
    EOS detection checks ``session.eos_token_ids`` per response.  Cancel is
    checked every ``session.decode_cancel_stride`` tokens.

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

    # Pre-cancel check
    if cancel_event.is_set():
        yield cancelled_event()
        return

    # --- Step 6: call stream_generate ---
    stream = deps.stream_generate(
        session.model,
        session.tokenizer,
        prompt_ids,
        max_tokens=max_output_tokens,
        sampler=sampler,
    )

    # --- Step 7: per-item decode loop ---
    output_tokens = 0
    for response in stream:
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
            yield _completed_event("FINISH_REASON_STOP", input_tokens, output_tokens)
            return

        if finish_reason is not None:
            # Upstream terminal from mlx_lm.  Flush all buffered text.
            if safe_text:
                yield {"kind": "output_text_delta", "delta": safe_text}
            flush_text = buf.flush()
            if flush_text:
                yield {"kind": "output_text_delta", "delta": flush_text}

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
    flush_text = buf.flush()
    if flush_text:
        yield {"kind": "output_text_delta", "delta": flush_text}
    if cancel_event.is_set():
        yield cancelled_event()
    else:
        yield _completed_event("FINISH_REASON_STOP", input_tokens, output_tokens)


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
