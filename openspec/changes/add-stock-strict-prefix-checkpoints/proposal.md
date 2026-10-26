## Why

The stock MLX-LM Worker reuses prompt prefixes only through the trim-based `kv` and `trie` caches. A hybrid model whose prompt cache mixes `KVCache` layers with `ArraysCache` layers (convolution history and recurrent state) cannot be trimmed, so the Worker runs it with no prefix reuse. Every follow-up turn prefills its whole prompt again. At about 131k tokens this costs about 600 to 780 s per turn on Apple Silicon.

Reuse does not need trimming when the stored state covers an exact, strictly shorter prefix of the new prompt. This change adds that path to the stock Worker as an off-by-default experiment, so Orchard can measure it against other runtimes on the same pinned mlx-lm.

## What Changes

- Add strict-prefix checkpoint reuse to the stock MLX Worker, selected only by `ORCHARD_WORKER_STRICT_PREFIX_CHECKPOINTS=enabled`. Unset or `disabled` keeps current behavior.
- Capture one checkpoint per request at an intermediate prefill boundary: the last multiple of the prefill step at or before the last reply marker. Never capture at the final prompt-progress callback or at the end of a response.
- Restore only a retained checkpoint whose tokens are an exact, strictly shorter prefix of the request. Never trim or truncate cache state.
- Deep-copy every cache layer on store and on restore. Charge each checkpoint a fixed slot reservation before the copy, and keep the reservation of a failed or uncertain copy until unload.
- Refuse Worker startup or model load when the setting is on and the configuration cannot support it.
- Document the setting and its refusals in `docs/local-dev.md`.

## Impact

No SPEC.md behavior impact. The setting is off by default. With it off, the trim-based caches, batch mode and every model behave as before. The experiment does not publish prefix-cache status or fingerprints, and it does not change admission, scheduling, Node status, public APIs or the MLX-LM runtime foundation in SPEC.md. It is not a support claim or a qualified serving profile. Promoting it to a supported mode needs a separate decision and a later change that updates SPEC.md.
