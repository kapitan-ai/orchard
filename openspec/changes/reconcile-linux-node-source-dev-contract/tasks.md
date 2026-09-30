## 1. Contract reconciliation

- [x] 1.1 Audit current `SPEC.md`, profile, packaging, transport, lifecycle, provider-neutral, support-bundle, and release-line boundaries against the earlier package-first candidate contract, and verify every package-first assumption is either reconciled to source development or deferred
- [x] 1.2 Record proposed ADR 0035 with an unused number, and verify both existing ADR 0034 records are unchanged
- [x] 1.3 Reconcile `SPEC.md` §1.4, §4.1, §4.9, §7.5.0, §10.6, the §11 preamble, §13.4, and Milestone 9, and verify no text claims Linux Node, distribution, or runtime-provider support
- [x] 1.4 Add the `linux-node-platform` capability and ADDED requirements for `platform-profiles`, `host-lifecycle-adapters`, and `packaging-deployment`, and verify strict change validation passes
- [x] 1.5 Add `docs/platforms/linux-node.md`, update orientation references including the `AGENTS.md` Milestone 9 row and the architecture acceptance-profile row, and verify relative links resolve
- [x] 1.6 Resolve independent review findings in one bounded revision, restoring the Mac-only production BEAM sentence verbatim and leaving ADR 0012 unchanged
- [ ] 1.7 Obtain independent re-review and accountable owner acceptance of the exact revision before any task below starts
- [ ] 1.8 Only after owner acceptance, flip the proposed or pending labels in `SPEC.md` §1.4 and Milestone 9, ADR 0035 status, `docs/decisions/README.md`, `docs/architecture.md`, `docs/README.md`, `docs/local-dev.md`, `docs/platforms/linux-node.md`, and the `AGENTS.md` milestone row, and verify no text claims support

## 2. Source-development Node path and Linux adapter

- [ ] 2.1 Make the Node-only source-development path operable on a matrix host with the pinned toolchain, and verify it runs no Controller, Console, or database role
- [ ] 2.2 Implement closed-matrix preflight, and verify unqualified hosts, including Ubuntu 26.04 LTS, fail before identity, service-manager, or enrollment mutation
- [ ] 2.3 Implement the Node Identity Root exclusive lock and local-filesystem checks, and verify duplicate Agents fail before enrollment, Runtime Endpoint activation, or Worker Runtime startup
- [ ] 2.4 Implement the Linux host lifecycle adapter with relocated-root tests, and verify no real systemd manager or host installation changes
- [ ] 2.5 Implement exact source evidence capture, and verify dirty, unidentified, or drifted checkouts produce implementation evidence only

## 3. Inventory and diagnostics

- [ ] 3.1 Implement bounded provider-neutral CPU, memory, disk, OS, kernel, and network observations, and verify malformed and missing input yields absent evidence
- [ ] 3.2 Implement separate NVIDIA and AMD accelerator observations with stable identities, and verify no capacity, allocation, device binding, or runtime startup follows
- [ ] 3.3 Expose redacted health, logs, metrics, inventory, and lifecycle diagnostics through retained generic surfaces, and verify no support-bundle or archive format is introduced

## 4. Trust

- [ ] 4.1 Propose a future credential lifecycle OpenSpec change reviewed under `docs/process.md` and reconcile it into `SPEC.md` before implementing credential behavior
- [ ] 4.2 Prove certificate renewal and revocation, Peer Grant rotation, private-network reconnect, local secret permissions, and stale-connection fail-closed behavior through certificate-authenticated control and the controlled source-development Peer Grant TLS Distribution test mesh, and verify shared-cookie and gRPC compatibility runs are not used as the qualification transport
- [ ] 4.3 Verify source revisions fail production BEAM admission before distribution membership

## 5. Custody and compatibility

- [ ] 5.1 Implement model-free process-group custody only after accepted contracts define request-slot release, native cessation, and worker-unit and resource-allocation targeting
- [ ] 5.2 Prove reader-first `N` and `N-1` decoding and fail-closed rejection of incomplete targeted operations

## 6. Mixed-platform acceptance

- [ ] 6.1 Identify the exact commit and tree whose earlier, distinct Product Version is designated as the logical `N-1` by accepted governed previous-line evidence, and verify that absence of such a designation leaves the gate unmet
- [ ] 6.2 Run `macos_controller_linux_node_model_free` for both pairings, including exact worker-unit and resource-allocation targeting under accepted contracts, with independently captured evidence from every participating host

## 7. Provider gate

- [ ] 7.1 Confirm every provider-neutral gate passes before any separately authorized runtime-provider pilot
- [ ] 7.2 If separately authorized, qualify one immutable H100, vLLM, model, and serving-configuration tuple at concurrency one without broader support claims

## 8. Validation

- [x] 8.1 Run `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate reconcile-linux-node-source-dev-contract --type change --strict --no-interactive` and the all-specs strict validation, and verify both pass
- [x] 8.2 Run `git diff --check`, relative-link checks, and static consistency checks for this docs-only change, and verify the Distribution Pause Control is unchanged
- [ ] 8.3 Run the full `AGENTS.md` Elixir workflow for every later implementation slice
- [ ] 8.4 After acceptance and archive or sync, review generated main specs for placeholder prose such as `Purpose TBD`
