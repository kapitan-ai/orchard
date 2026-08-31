## 1. Contract And Public Seams

- [x] 1.1 Add focused Controller-owned command and RPC tests before or alongside the extraction.
- [x] 1.2 Preserve the existing standalone CLI node-command tests unchanged through a thin adapter.

## 2. Controller Ownership

- [x] 2.1 Move the packaged RPC bridge and closed allowlist under Controller ownership.
- [x] 2.2 Move the required node-command compatibility implementation under Controller ownership while reusing existing domain operations and presenters.
- [x] 2.3 Add a narrow supervised-Repo runner without moving the generic standalone CLI Repo runtime.
- [x] 2.4 Remove the old CLI-owned RPC bridge and every `OrchardCLI.*` dependency from the packaged handler path.

## 3. Release And Packaging

- [x] 3.1 Update the packaged wrapper and remove `orchard_cli` from the Controller release application list.
- [x] 3.2 Add build-time and real-release assertions for Controller release independence.
- [x] 3.3 Prove matching payload operation, both fail-closed skew directions, transactional activation, and full-payload rollback.

## 4. Validation

- [x] 4.1 Run focused Controller and CLI tests plus the full Elixir workflow and coverage.
- [x] 4.2 Run packaged runtime, real Controller release, and payload assembly tests.
- [x] 4.3 Run dependency classifier, aggregate gate, focused strict OpenSpec, and repository-wide strict OpenSpec validation.
- [x] 4.4 Run every dependency-selected portable, provider-neutral, macOS host, MLX, packaging, and other applicable lane.
- [x] 4.5 Run an independent exact-head RepoPrompt Oracle review and address validated blockers.
- [ ] 4.6 Record exact-head hosted CI and review evidence in the pull request without merging it.
