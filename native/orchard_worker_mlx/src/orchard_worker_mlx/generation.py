"""Real MLX token generation via mlx_lm.stream_generate().

This module owns request-time generation only: prompt decode/encode, sampler
construction, stream_generate invocation, delta normalization, EOS detection,
terminal event emission, usage accounting, and decode-phase cancel checks.

It does NOT own model lifecycle, gRPC/proto conversion, accepted/progress
events, stop-sequence buffering (Task 4), or prefix cache (Task 6).
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

    # max_output_tokens <= 0: immediate completed with FINISH_REASON_LENGTH
    if max_output_tokens <= 0:
        yield _completed_event("FINISH_REASON_LENGTH", input_tokens, 0)
        return

    # --- Step 3: encode prompt ---
    prompt_ids = _encode_prompt(session.tokenizer, prompt_text)

    # --- Step 4: build sampler ---
    sampler = _build_sampler(temperature, top_p, deps)

    # --- Step 5: call stream_generate ---
    # Pre-cancel check
    if cancel_event.is_set():
        yield cancelled_event()
        return

    stream = deps.stream_generate(
        session.model,
        session.tokenizer,
        prompt_ids,
        max_tokens=max_output_tokens,
        sampler=sampler,
    )

    # --- Step 6: per-item decode loop ---
    output_tokens = 0
    for response in stream:
        # Cancel check (every token for now; Task 5 will stride)
        if cancel_event.is_set():
            yield cancelled_event()
            return

        delta_text = response.text
        finish_reason = response.finish_reason

        if finish_reason is not None:
            # This is the final response from stream_generate.
            # Emit any remaining text delta.
            if delta_text:
                output_tokens += 1
                yield {"kind": "output_text_delta", "delta": delta_text}

            # Map mlx_lm finish reasons to our proto constants.
            if finish_reason == "stop":
                yield _completed_event("FINISH_REASON_STOP", input_tokens, output_tokens)
            else:  # "length"
                yield _completed_event("FINISH_REASON_LENGTH", input_tokens, output_tokens)
            return

        # Non-terminal: emit text delta if non-empty.
        if delta_text:
            output_tokens += 1
            yield {"kind": "output_text_delta", "delta": delta_text}

    # --- Step 7: iterator exhaustion without finish_reason ---
    # This shouldn't normally happen with mlx_lm.stream_generate (it always
    # yields a final response with finish_reason set), but handle defensively.
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

    Uses ``add_special_tokens=False`` because prompts are already rendered
    by the controller.
    """
    try:
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
