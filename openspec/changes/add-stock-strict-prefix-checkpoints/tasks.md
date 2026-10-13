# Tasks: default-off strict-prefix checkpoint reuse in the stock MLX Worker

## 1. Contract

- [x] 1.1 State that the change has no SPEC.md behavior impact while the setting is off by default.
- [x] 1.2 Run strict OpenSpec validation for this change package.

## 2. Implementation

- [x] 2.1 Add the checkpoint store, boundary choice and capture hook in `native/orchard_worker_mlx`.
- [x] 2.2 Wire restore and capture into stream generation, and keep the existing prefix-cache path when the setting is off.
- [x] 2.3 Read the setting in the Worker CLI, and refuse unsupported configurations at startup and before weights load.
- [x] 2.4 Document the setting and its refusals in `docs/local-dev.md`.

## 3. Tests

- [x] 3.1 Model-free tests: hit, miss, changed earlier turn, equal-length miss, no capture at the final callback, isolation from later changes, reservation before copy, uncertain copies, restore failure, startup refusals and unchanged behavior with the setting off.
- [x] 3.2 Real-MLX tests with the `mlx` extra: byte measurement, deep-copy isolation, the pinned commit, and convolution-state storage that does not keep the prefill chunk buffer alive.
- [x] 3.3 Mutation checks for the final-callback exclusion, the strictly-shorter rule and reserve before copy.
- [x] 3.4 Run the Python/native workflow for `native/orchard_worker_mlx` and `native/orchard_tensorfold_http`.

## 4. Native evidence

- [x] 4.1 Compare cached and uncached stock output with greedy decoding on Apple Silicon.
- [x] 4.2 Compare long-context follow-ups and agentic sessions against the TensorFold experiment, with memory telemetry.

## 5. Before promotion (separate change)

- [ ] 5.1 Decide whether strict-prefix reuse becomes a supported mode for a qualified tuple, and update SPEC.md in that change.
- [x] 5.2 Make stock prefill cancellable at chunk boundaries (change `stop-stream-prefill-on-cancel`).
- [x] 5.3 Add a config mode, Node Agent error mapping, headroom accounting and per-model enablement (change `harden-stock-strict-prefix-checkpoints`). Cache-affinity fingerprints for checkpoints are a separate change.
- [ ] 5.4 After archive or sync, review generated specs and remove placeholder prose such as "Purpose TBD".
