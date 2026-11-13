## 1. Toolchain

- [x] 1.1 Select Python 3.14.10 in mise and uv; align documentation, active Ruff targets and fixtures.
- [x] 1.2 Check native and proto-tooling locks without unrelated dependency upgrades; verify CI consumers use the selected interpreter.

## 2. Validation

- [x] 2.1 Run native formatting, lint, tests and coverage for every retained native package.
- [x] 2.2 Compare tokenizer bytes, token IDs/counts and marker provenance against pinned smoke assets.
- [x] 2.3 Run available Apple Silicon load, generation, cancellation, reaping and cache checks; report missing evidence.
- [x] 2.4 Run strict OpenSpec, affected script/workflow contracts and supply-chain validation.

## 3. Owner gates

- [x] 3.1 Implement and validate the owner-approved prerequisite retirement (merged in #590).
- [x] 3.2 Record the product owner's migration deadline: complete by December 31, 2026, and before the SPEC §11.0 distribution pause lifts.
- [ ] 3.3 Obtain independent final-head review and exact-head CI before readiness; keep the PR draft.
