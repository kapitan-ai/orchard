# ADR 0038: Stock MLX-LM with strict-prefix reuse is the runtime for the Qwen3.8 coding-agent tuple

## Status

Accepted runtime direction on 2026-10-13 by the accountable product owner.
The acceptance binds to the reviewed revision of this record that merges through its pull request.

This record chooses the candidate runtime for one exact tuple.
It is not a qualification record, a support claim or a production activation under `SPEC.md` §1.4 and §7.2.9.
The following remain separately approved work:

- native qualification of the tuple, including the 131,072-token input floor that [LMQ-2026-0001](../model-qualification-records/LMQ-2026-0001.md) records as unexercised;
- the native cancellation measurements in task 3.4 of the OpenSpec changes `stop-stream-prefill-on-cancel` and `add-stream-keepalive-disconnect`;
- the `SPEC.md` promotion of the strict-prefix mode (task 5.1 of `add-stock-strict-prefix-checkpoints`).

## Context

The first tuple Orchard intends to qualify for a coding agent is `mlx-community/Qwen3.8-27B-8bit` at the immutable checkpoint recorded in [LMQ-2026-0001](../model-qualification-records/LMQ-2026-0001.md), on an Apple Silicon M3 Ultra host, driven by OpenCode through the Public Inference API.
The model has a hybrid prompt cache: `KVCache` layers and `ArraysCache` layers that hold convolution history and recurrent state.

Before pull request #512, the stock MLX-LM Worker reused prefixes only through the `kv` and `trie` prefix caches, which restore a stored cache and trim it back to the shared prefix.
Recurrent state has no per-token history, so a hybrid cache cannot be trimmed, and the Worker ran this model with no prefix reuse.
Every agent turn prefilled its whole prompt again, which took about 600 to 780 s at about 131k tokens on the target host.

Two candidates could reuse checkpoints across turns for this model:

1. **The TensorFold 0.6.6 Worker**, a default-off source experiment that embeds TensorFold in a Node-owned Worker process (`native/orchard_tensorfold_http`), allowed by the last paragraph of `SPEC.md` §7.2.9.
2. **Strict-prefix checkpoint reuse in the stock MLX-LM Worker**, added as a default-off spike in pull request #512.
   It restores a checkpoint only when the checkpoint's tokens are an exact, strictly shorter prefix of the new prompt, and never trims cache state.

`SPEC.md` §1.5 makes MLX-LM the default macOS runtime provider, and requires any additional runtime provider to have its own runtime-provider profile and acceptance.
`SPEC.md` §7.2.9 forbids selecting TensorFold or any other project as an Orchard runtime foundation from an Agentic Execution Profile result.

### Evidence

The native comparison is published in the [native results comment on pull request #512](https://github.com/kapitan-ai/orchard/pull/512#issuecomment-6111251421).
It ran both candidates on the same M3 Ultra host and tuple, with prefill step 2048, stream mode with one slot, and strict-prefix reuse at 2 slots of 9 GiB.
It is decision evidence, not qualification.

- **Output.** With greedy decoding, all 8 responses from stock with reuse matched stock without reuse on the content and reasoning SHA-256, the delta count and the finish reason.
  The requests covered 16k and 131k prompts, follow-ups, a second follow-up and an edited earlier turn, which missed as designed.
- **Long-context follow-up** (131k prompt plus a 2k follow-up): first delta at 18.8 s and 17.6 s with stock reuse, and 15.6 s and 17.8 s with TensorFold.
  The same follow-up took 776.7 s on stock without reuse.
  Peak footprint was 75 GiB with stock reuse and 76 GiB with TensorFold.
- **OpenCode sessions** (3 per backend, temperature 1): 91% checkpoint hits with stock reuse and 89% with TensorFold.
  Each finished the task in 2 of 3 sessions.
  Peak footprint was 40 to 43 GiB with stock reuse and 50 to 52 GiB with TensorFold.
  The sessions diverge, so wall-time figures are indicative only.
- No checkpoint copy or restore failed. All valid runs had normal memory pressure and no swap.

Since that run, pull request #521 made a stock stream-mode prefill stop at the next chunk boundary on cancel, and pull requests #522 and #523 hardened the mode.

## Decision

### Runtime

The stock MLX-LM Worker with the `strict_prefix` prefix-cache mode is the candidate runtime for the tuple.
MLX-LM stays the runtime provider under `SPEC.md` §1.5.
Strict-prefix reuse is an Orchard-owned prefix-cache mode inside that provider, not a new runtime provider or runtime foundation.

The tuple runs in stream mode with one generation slot.
While a strict-prefix model is loaded, the Node already serves one request at a time, because it takes the lowest Worker limit.
The tuple also runs alone on its Node.
That is a qualification rule, not enforced behavior: each model checks memory only against itself.

### Strict-prefix mode under qualification

Qualification tests the mode as implemented by pull requests #512, #521, #522 and #523, and documented in `docs/local-dev.md`:

- capture only at an intermediate prefill boundary, at the last prefill-step multiple at or before the last reply marker;
- restore only an exact, strictly shorter prefix, deep-copying every cache layer, and never trim;
- reserve a fixed slot charge before each capture copy, and keep a failed capture charged as uncertain until unload;
  a failed restore drops that checkpoint and the request prefills cold;
- enable the mode for an exact `model_id@version` in the per-model Worker settings, which the Node refuses before spawn when the generation mode is not `stream` or the memory-budget mode is not `observe`;
- refuse the model load with a stable code for another mlx-lm build, an unsupported cache layout, a reply marker that tokenizes to nothing, or a budget larger than known headroom;
- subtract the configured checkpoint budget once from published headroom;
- report `strict_prefix` prefix-cache status, with no cache-affinity fingerprints and no prefix-cache capability;
- on cancel, stop a prefill at the next intermediate chunk boundary.
  A cancel during the final chunk or after prefill uses the decode stride, so a short reply can still complete.

The tuple's qualification identity under `SPEC.md` §7.2.9 includes the mlx-lm version and commit, the resolved per-model launch policy (generation mode, memory-budget mode, slots, slot bytes, budget bytes and reply marker) and the Worker's prefill step size.
A change to any of them needs a new qualification identity under §6.4 governance.

### TensorFold

The TensorFold bridge stays in the repository as a frozen, default-off source experiment, as `native/orchard_tensorfold_http/README.md` states.
Orchard does not promote it, mirror its pinned engine, add it to required CI or `make setup`, or start new TensorFold work.
Frozen status does not waive the README's rule: a change that breaks the `SPEC.md` §7.2.9 experiment contract still blocks a merge.
Its measured results stay as reference evidence for this decision.

## Alternatives considered

- **Promote TensorFold 0.6.6.**
  Rejected.
  It gave similar follow-up latency at equal or higher memory.
  Orchard would have to own a frozen engine, its mirror, its CI lane and its custody code.
  It would also need an accepted runtime-provider profile and qualification under `SPEC.md` §1.4 and §1.5, and a change to §7.2.9.
- **A newer TensorFold engine.**
  Not selected.
  The experiment pins TensorFold 0.6.6, and a newer engine would need a new experiment and its own evidence.
- **Upstream `LRUPromptCache` from mlx-lm.**
  Rejected.
  It reuses exact shorter prefixes, but it is built for the mlx-lm server, reserves no memory before a copy, and does not align checkpoints to Orchard's prefill step, which the exact-output result depends on.
- **Relax the trimmability gate in the `kv` and `trie` caches.**
  Rejected.
  Trimming a hybrid cache truncates recurrent state and gives wrong output.
- **No prefix reuse for the tuple.**
  Rejected.
  A full prefill on every agent turn makes long sessions impractical on this host.

## Consequences

- MLX-LM stays the tuple's runtime provider, and the existing `SPEC.md` §1.5 and `AGENTS.md` runtime language stays true.
- Orchard owns the strict-prefix capture seam.
  It depends on the pinned `generate_step` callback order, and the Worker refuses any other mlx-lm build when the mode is on.
  An mlx-lm upgrade needs the seam checked again and the tuple qualified again.
- The checkpoint memory bound depends on array `nbytes` and on the pinned hybrid layers storing convolution history with `mx.contiguous`.
  Slot charges do not cap process memory, and the load-fit check is skipped when headroom is unknown.
  Qualification must show that working cache, transient allocations and retained checkpoints fit the declared memory envelope.
- Hits depend on the rendered prompt.
  A chat-template, renderer or client change that renders an earlier turn differently, or moves the reply marker, misses from that point on.
  A different prefill step gives no reuse rather than a refusal.
  Qualification must use representative multi-turn sessions from the named client.
- Concurrency stays at one request per Node for this tuple.
- A strict-prefix Worker publishes no cache-affinity fingerprints, so a follow-up turn routed to another Node misses its checkpoint.
  This does not matter while the tuple runs on one Node.
  Checkpoint-identity routing is separate work.
- Rollback to an older Worker needs the `strict_prefix` entries removed from the per-model settings first, because older Workers reject the mode.
- Later readiness work for the tuple targets the stock Worker.
- The open OpenSpec change `add-tensorfold-http-worker` should be archived or marked frozen, so that it does not read as planned work.

### What would reopen this decision

- The tuple needs more than one concurrent request per Node, and strict-prefix reuse cannot provide it.
- Native measurement shows that stock prefill cancellation does not settle within about one prefill chunk.
- An mlx-lm pin upgrade breaks the capture seam and cannot be repaired without changes inside mlx-lm.
- Native qualification shows output that differs from stock without reuse, checkpoint-accounting violations, or physical memory above the declared envelope.
- The checkpoint hit rate in real client sessions is too low to justify the mode.

## SPEC.md impact

No change in this record.
`SPEC.md` §7.5.3 already defines `strict_prefix` prefix-cache status, the absence of fingerprints and of the prefix-cache capability, and the `disabled` score answer, and §12.4 already defines the chunk-boundary cancel.
Both landed with pull requests #521 to #523.

The promotion is a separate OpenSpec change for task 5.1 of `add-stock-strict-prefix-checkpoints`, after the native evidence exists, with strict validation clean.
It updates §7.2.9:

- state that `strict_prefix` is a Worker prefix-cache mode of the MLX-LM provider that a qualified tuple may use, and that the mode alone is not a support claim;
- state that the resolved per-model launch policy and the prefill step size are part of the cache settings in the qualification identity;
- in the TensorFold paragraph, state that the experiment is frozen reference evidence and not a candidate runtime.

No change to §1.5, §6.4 or `AGENTS.md`: MLX-LM stays the runtime provider.
