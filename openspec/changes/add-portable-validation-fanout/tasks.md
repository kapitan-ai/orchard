## 1. Dependency Fan-Out

- [x] 1.1 Add a repository-owned classifier for portable, conformance, macOS, MLX, and packaging lanes.
- [x] 1.2 Add trigger-matrix tests for portable-only, provider, macOS-native, packaging, normative, shared-protocol, root-toolchain, workflow, source renames, and ordinary documentation changes.

## 2. Required Validation Lanes

- [x] 2.1 Add Linux portable compilation, static analysis, tests, coverage, tokenizer, and non-accelerator Worker Runtime setup.
- [x] 2.2 Add focused provider-neutral conformance on Linux.
- [x] 2.3 Retain explicit macOS host-native, Apple Silicon MLX, Orchard.app, DMG, signing-contract, and packaged CLI evidence.
- [x] 2.4 Tag retained Darwin-only test modules and run them explicitly in the macOS host lane.

## 3. Aggregate Gate

- [x] 3.1 Preserve the `Required Orchard validation gate` check name.
- [x] 3.2 Add a repository-owned aggregate evaluator that requires exact success or skipped results.
- [x] 3.3 Add deliberate success and failure proofs for aggregate behavior.

## 4. Validation

- [x] 4.1 Run strict focused and repository-wide OpenSpec validation and inspect the prose for placeholders.
- [x] 4.2 Run local trigger, aggregate, portable compile, provider-neutral, Elixir, and applicable macOS validation.
- [ ] 4.3 Run the exact Linux, provider-neutral, macOS, MLX, packaging, and aggregate lanes in hosted CI.
- [ ] 4.4 Run exact-head RepoPrompt review and the repository required review gate.
