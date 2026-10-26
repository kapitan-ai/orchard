# Tasks: stop a cancelled stream-mode prefill at the next chunk boundary

## 1. Contract

- [x] 1.1 State the stop rule in SPEC.md §12.4, and remove the "prefill is not interruptible" sentence from §6.4.
- [x] 1.2 Run strict OpenSpec validation for this change package.

## 2. Implementation

- [x] 2.1 Wrap the stream-mode progress callback with a guard that raises an internal exception at an intermediate boundary once the request is cancelled.
- [x] 2.2 End the stream loop on that exception, so the existing end-of-stream path emits the cancelled terminal and clears the cache.
- [x] 2.3 Keep the shared batch runtime unchanged.

## 3. Tests

- [x] 3.1 Model-free: stop at the next chunk boundary, final-callback cancel on the decode stride, batch runtime not interrupted, other stream errors propagate, cache cleared, strict-prefix checkpoint kept at the cancel boundary.
- [x] 3.2 Real-MLX with the `mlx` extra: a tiny random model prefills through the pinned `stream_generate`, stops at the next chunk boundary, and generates normally on the next request.
- [x] 3.3 Mutation checks for the guard, the loop wrapper, the final-callback exclusion and the batch-runtime exclusion.
- [ ] 3.4 Native: cancel at about 30 s and at about 440 s into a cold 131k prefill on Apple Silicon, and measure the time from cancel to the settled terminal.
- [ ] 3.5 After archive or sync, review generated specs and remove placeholder prose such as "Purpose TBD".
