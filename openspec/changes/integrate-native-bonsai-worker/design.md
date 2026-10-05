## Context

The Worker uses the held MLX-LM generator, tokenizer/parser and Node-owned lifecycle. Released mlx-vlm 0.7.2 at `a74c7de90a344a2c2c7334acb4e48b57a40480e2` implements `prism_hadamard_qwen35` schema2 using reviewed native Hadamard modules. The official pack requires those modules; ordinary affine loading is insufficient.

## Goals / Non-Goals

**Goals:** Reuse the exact native model implementation, retain the existing Worker protocol and renderer/tool parser boundaries, and construct one explicit serial text-only evaluation tuple with strict weights and safe cleanup.

**Non-Goals:** Vision admission, native serving processes, new Runtime Endpoint/provider contracts, batching, persistent prefix reuse, remote model code, dependency modernization, production qualification or distribution activation.

## Decisions

1. Retain `mlx_lm` as the generation adapter and add a closed model-construction branch for `prism_hadamard_qwen35`. Native code is an installed pinned dependency, never a model-bundle import. A new adapter name would require unnecessary producer/runtime identity migration while the generator and protocol remain MLX-LM.
2. Install the exact native source through an optional `bonsai` extra alongside `mlx`. Record and check native package Git provenance. The native package's import surface requires its declared audio/image/server dependencies; keep these outside the ordinary Worker environment. The lock must preserve all held existing package versions. Vendoring is a future reviewed alternative if this environment fails; numerical reimplementation is unnecessary.
3. Validate schema2, grouped GDN layout, namespace, quantization and the complete 402 typed unique packed module records before native import. Reject executable model declarations, architecture/drafter overrides, offload mode and escaping/missing shard paths. Pre-read bounded safetensors headers, accepting only F16/BF16/F32/U32, and require complete contiguous ranges; this prevents the released loader's in-place dtype-reinterpretation fallback from mutating an immutable artifact. Reconcile shard index keys and ownership, packed weight/sign widths and all 2,390 tensor names including 333 vision tensors. Use local Path-only native `load_model` with strict weights and reject changes to the tensor inventory. Native modules validate dimensions and sign values. Reject residual generic quantized language layers that are not covered by the Hadamard manifest rather than silently apply affine inference.
4. Wrap native language generation in an MLX module that yields `.logits` and delegates request-local cache construction. Retain the vision tower as a public module so complete weight evaluation and residency remain truthful. Clear native position IDs and rope deltas before each fresh cache and after synchronized request finalization. Use native resolved EOS configuration. Text generation does not invoke processors or admit image inputs.
5. Require explicit stream generation and persistent cache disabled before load. Reject incompatible settings without silently changing them. The existing stream mode enforces concurrency one. Every request creates its own native cache; existing generator finalization/synchronization and Worker/Node lifecycle remain responsible for cancellation and release.
6. Preserve exact tokenizer IDs/EOS, template, reasoning and declared parser preflight as separate gates. No capability or support is inferred from family names or successful construction. Genuine client-owned edit/test/iteration and cancellation/reuse receipts remain acceptance tasks.
7. A request-boundary MLX synchronization failure marks the loaded session and Worker process unavailable for further admission, including same-process reload. Continue cleanup, log reset/cache-clear failures, preserve an already emitted public terminal, and require Node Agent-owned Worker restart before reuse. This closes the existing stream cleanup fault path without changing cancellation acknowledgment or accounting contracts.

## Risks / Trade-offs

- The optional native dependency graph is broader than its numerical module → exact Git and locked transitive identities, separate opt-in environment, import/security validation and no native server launch.
- Native cache classes differ from MLX-LM's classes → stream-only uncached path, direct interface regression tests, then exact-tuple native prefill/decode/cancel-reuse qualification before broader modes.
- Native loading has permissive custom-code/offload features → reject those inputs at the owned boundary before the native loader, retain immutable Node-owned artifacts, strict complete weights and malformed-pack tests.
- A plausible output can conceal wrong transforms/history → independent pinned reference parity, preserved failed trajectories, real tool continuation and held-out repository task checks.

## Migration Plan

Ordinary Worker loading and the separate helper environment remain unchanged. Operators explicitly install both extras and select stream/cache-disabled settings for the candidate. The Node Agent launches the existing direct-exec Worker entrypoint. A failed native load never publishes loaded placement evidence. Stop or quarantine uncertain execution through Node Agent custody before changing environments or reusing capacity. No automatic fallback to ordinary affine loading or another model.

## Open Questions

The official exact native baseline establishes bounded loader/numerical, functional and performance evidence. Its four direct coding attempts and actual seven-request OpenCode attempt remain incomplete, including missing required tool arguments; no Worker gate inherits a pass from those runs. Source and unit validation do not establish hardware parity, native drain, useful coding outcomes or formal profile qualification. The SPEC clarification on this branch is a concrete proposal for review; implementation approval is not main acceptance or publication approval.
