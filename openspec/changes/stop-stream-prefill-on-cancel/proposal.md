## Why

The stock MLX-LM Worker could not cancel during prefill. mlx-lm's `generate_step` has no cancel hook, so a cancel took effect only after the first output token. At about 131k prompt tokens, prefill takes about 600 to 780 s on Apple Silicon. A cancelled, timed-out or disconnected request therefore kept the Worker's only generation slot for up to about 10 minutes.

`generate_step` calls `prompt_progress_callback(processed, total)` after it evaluates each prefill chunk. That callback is a safe point to stop: no evaluation is in flight, and the cache holds a complete state for the processed tokens.

## What Changes

- In stream mode, wrap the prefill progress callback. When the request's cancel event is set at an intermediate callback (`processed < total`), raise an internal exception that ends the stream loop. The existing end-of-stream path emits the `cancelled` terminal and clears the session cache.
- Run the wrapped callback first, so a strict-prefix checkpoint captured at that boundary completes before the stop.
- Keep the final `(total, total)` callback and decode on the existing decode cancel stride.
- Leave the shared batch runtime unchanged.

## Impact

SPEC.md behavior change. §12.4 states that, for any cancel, a stream-mode MLX-LM Worker stops a cancelled prefill at the next intermediate prefill chunk boundary, and that a cancel during the last chunk or after prefill uses the decode cancel stride. §6.4 no longer says that prefill is not interruptible; it says an enforcement abort cancels every active generation, and that a generation still in prefill stops according to its runtime's cancellation behavior. A cancelled prefill does not update the prefill-workspace memory estimate, because its memory sample comes from a partial prefill. No public API, Controller, Node Agent or wire-format change. The Controller cancel drain cap and quarantine rules in §12.4 are unchanged.
