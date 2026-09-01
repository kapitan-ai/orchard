## Why

The accepted Worker Runtime contract still has an implementation-owned protobuf source, Python-only generation, and a manually maintained Elixir binding.
That migration state can hide wire drift and makes a provider implementation the owner of a provider-neutral boundary.
Issue #345 implements the already accepted ownership and validation contract before any later additive Worker Runtime encoding work.

## What Changes

- Move the unchanged Worker Runtime protobuf source to `proto/orchard/worker/v1/worker_runtime.proto` as the sole authority.
- Generate committed Python and Elixir bindings deterministically from that source with pinned repository toolchains.
- Preserve the existing `Orchard.Node.Worker.V1.*` Elixir consumer surface through a mechanical generated namespace mapping.
- Commit a descriptor-set golden and reciprocal Python and Elixir semantic fixtures for the complete current wire contract.
- Add a clean-checkout generated-output check and a deliberate-drift negative regression.
- Route the neutral schema, generator inputs, and generated bindings to every applicable portable, conformance, macOS, MLX, and packaging lane.

This change adds no new product behavior, but it reconciles stale migration wording in `SPEC.md` with the already accepted ownership contract.
It implements `SPEC.md` sections 2.4, 4.10, 7.5.2a, and Milestone 8 plus ADR 0025 and the accepted `worker-runtime-providers` and `portability-validation` specifications.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `worker-runtime-providers`: Makes provider-neutral source ownership, reproducible bindings, descriptor compatibility, and drift rejection executable.
- `portability-validation`: Makes protocol and generated-binding dependency fan-out explicit and tested.

## Impact

- Worker Runtime schema ownership moves out of the MLX provider package.
- Python and Elixir consumers continue using the same package, messages, RPCs, wire numbers, imported types, defaults, and runtime behavior.
- Required validation gains deterministic generation, drift, descriptor, and cross-language compatibility evidence.
- This change does not add capability fields, reasoning encoding, scheduling behavior, runtime providers, or a new transport boundary.
