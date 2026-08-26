## 1. Portable Compile Boundary

- [x] 1.1 Remove the `elixir_make` compiler hook and Darwin helper source ownership from portable `orchard_cli`.
- [x] 1.2 Add a first-party umbrella compilation regression that rejects Orchard Darwin helper compilation and artifacts.

## 2. Explicit macOS Host Artifacts

- [x] 2.1 Add the explicit macOS native-helper builder and source/test Make targets.
- [x] 2.2 Preserve lifecycle and secret-terminal behavior through focused macOS regressions.
- [x] 2.3 Build and stage both production helpers during payload assembly while excluding test-only artifacts and sources.

## 3. Validation

- [x] 3.1 Run strict focused and repository-wide OpenSpec validation and review all change prose for placeholders.
- [x] 3.2 Run the full Elixir contribution workflow with explicit macOS test helpers.
- [x] 3.3 Run payload, Orchard.app, signing-contract, DMG, lifecycle, and PTY validation.
- [ ] 3.4 Run exact-head RepoPrompt review and the repository required review gate.
