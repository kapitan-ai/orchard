## 1. Contract Ownership And Generation

- [x] 1.1 Move the unchanged Worker Runtime schema to the neutral `proto/orchard/worker/v1` boundary and remove the MLX-owned source.
- [x] 1.2 Generate committed Python messages and gRPC stubs from the neutral source.
- [x] 1.3 Generate committed Elixir messages, service, and stub while preserving `Orchard.Node.Worker.V1.*` consumers.
- [x] 1.4 Generate and commit the complete descriptor-set golden.
- [x] 1.5 Move the pinned Python generation toolchain and lock outside every runtime-provider package.

## 2. Compatibility And Drift Evidence

- [x] 2.1 Add literal descriptor assertions for every current message, field, import, and RPC.
- [x] 2.2 Add reciprocal Python-to-Elixir and Elixir-to-Python semantic fixtures.
- [x] 2.3 Add clean-checkout byte-for-byte generated-output drift validation.
- [x] 2.4 Add a deliberate-drift negative regression that does not mutate the checkout.

## 3. Validation Routing And Documentation

- [x] 3.1 Route the neutral schema, generator/check inputs, and generated bindings to all consuming validation lanes.
- [x] 3.2 Run the binding and compatibility checks in required provider-neutral CI.
- [x] 3.3 Update contributor, Node Agent, MLX provider, architecture, and tooling documentation.

## 4. Validation And Review

- [x] 4.1 Run focused and repository-wide strict OpenSpec validation and inspect the prose for placeholders.
- [x] 4.2 Run generation twice, clean drift, negative drift, descriptor, reciprocal fixture, provider-neutral, UDS, and lifecycle regressions.
- [x] 4.3 Run the complete Elixir and native package quality workflows with coverage.
- [ ] 4.4 Run every dependency-selected portable, macOS, MLX, packaging, and OpenSpec lane.
- [ ] 4.5 Run exact-head RepoPrompt pair or design review, Oracle review, hosted CI, and review-thread inspection.
