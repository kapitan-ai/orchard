## Context

The stock Worker uses mlx-lm 0.31.3 at a pinned commit. Its `generate_step` prefills a prompt in chunks of `prefill_step_size` tokens. After each chunk it evaluates the cache state and calls `prompt_progress_callback(processed, total)` with `processed < total`. After the last prompt token, the decode loop feeds the first sampled token through a lookahead step, and only then calls `prompt_progress_callback(total, total)`.

The existing `kv` and `trie` caches restore a cache and trim it back to the request's matching prefix. A hybrid cache cannot be trimmed, because its recurrent state has no per-token history. The loader therefore builds no prefix cache for such a model.

## Goals and non-goals

Goals:

- Reuse a checkpoint across turns for a non-trimmable hybrid cache, with output identical to an uncached run under greedy decoding.
- Bound checkpoint memory with an explicit, reserved budget.
- Keep every current behavior unchanged when the setting is off.

Non-goals:

- Concurrency above one generation slot, or batch mode.
- Other mlx-lm versions, or other cache layer types.
- Published prefix-cache status, cache-affinity fingerprints, or scheduler effects.
- Message-aware checkpoint placement inside a prompt.

## Decisions

### Capture at an intermediate progress callback

The capture hook wraps `prompt_progress_callback`. It copies the request's own working cache when the callback reports exactly the target number of processed suffix tokens, with `processed < total`. At that point `generate_step` has evaluated the cache state for exactly those tokens. The final `(total, total)` callback is excluded because the cache already holds the first sampled token. Capturing at the end of a response is excluded because recurrent state has advanced through the output.

This needs no change inside mlx-lm.

### Boundary aligned to the prefill step

The target boundary is the last multiple of `prefill_step_size` at or before the last occurrence of the reply marker (default `<|im_start|>assistant`). Checkpoints are therefore always at absolute step multiples. A restored request prefills its suffix in the same chunk positions as an uncached run of the full prompt, which is what makes the output exact.

### Strictly shorter, exact prefix lookup

A lookup restores the longest retained key that equals the first tokens of the query and is shorter than it. An equal-length query misses, so a restored request always has a suffix to prefill. A change anywhere in the stored prefix misses.

### Ownership and memory

Each checkpoint occupies one of a fixed number of slots, and each slot charges a fixed `slot_bytes`. A capture measures the source cache from array `nbytes` metadata, reserves a slot (`staged`), deep-copies and materializes the copy, then marks it `retained`. A copy or materialize failure leaves the slot `uncertain` and charged until the store is cleared at unload. A key that is already held in any state is not captured again. A restore borrows the slot during its deep copy and materializes the restored copy. A restore failure is a miss: the request prefills cold, and the unrestorable checkpoint is dropped.

On the pinned MLX, deep-copying an evaluated array shares its buffer, and MLX updates are functional. A checkpoint's memory therefore becomes separate when the working cache next writes, not at the copy. The slot charge is the accounting bound for that memory. The pinned hybrid layers store convolution history with `mx.contiguous`, which copies, so `nbytes` bounds what a checkpoint keeps alive.

### Configuration and refusals

The Worker reads the setting from its environment, so no Controller or Node Agent change is needed. When the setting is on, startup or load is refused unless all of these hold:

- the backend is `mlx`, in stream mode, with prefix-cache mode `disabled`;
- memory-budget mode is `disabled` or `observe`, because retained checkpoints sit outside the working-set target;
- mlx-lm is 0.31.3, installed from the pinned commit;
- the model cache uses only `KVCache` and `ArraysCache` layers;
- the budget holds every slot, and fits the estimated headroom when the Worker knows it.

## Alternatives considered

- **Relax the trimmability gate in the existing caches.** Rejected: trimming a hybrid cache would truncate recurrent state and give wrong output.
- **Use upstream `LRUPromptCache` directly.** It reuses shorter exact prefixes, but it is built for the mlx-lm server, has no reservation before copy, and does not align boundaries to Orchard's prefill step.
- **Capture at the end of a response.** Rejected: the state then includes generated tokens and the lookahead token.

## Risks

- The capture point depends on the pinned `generate_step` callback order. The commit gate refuses any other mlx-lm build.
- Published headroom and recommended context do not subtract the checkpoint budget.
- The strict path registers no cache-affinity fingerprints, so a follow-up routed to another Node misses.
- Prefill is still not cancellable in the stock Worker.
- A load refusal reaches the Controller as a generic internal load failure. The Worker log carries the specific code and message.
