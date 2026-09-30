## 1. Contract reconciliation

- [x] 1.1 Audit current `SPEC.md`, profile, packaging, transport, lifecycle, provider-neutral, support-bundle, and release-line boundaries against the earlier package-first candidate contract, and verify every package-first assumption is either reconciled to source development or deferred
- [x] 1.2 Record proposed ADR 0035 with an unused number, and verify both existing ADR 0034 records are unchanged
- [x] 1.3 Reconcile `SPEC.md` §1.4, §4.1, §4.9, §7.5.0, §10.6, the §11 preamble, §13.4, and Milestone 9, and verify no text claims Linux Node, distribution, or runtime-provider support
- [x] 1.4 Add the `linux-node-platform` capability and ADDED requirements for `platform-profiles`, `host-lifecycle-adapters`, and `packaging-deployment`, and verify strict change validation passes
- [x] 1.5 Add `docs/platforms/linux-node.md` and update orientation references, and verify relative links resolve
- [ ] 1.6 Obtain independent review and accountable owner acceptance of the exact revision before any task below starts

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

- [ ] 4.1 Reconcile the separate credential lifecycle contract into `SPEC.md` through its own reviewed change before implementing credential behavior
- [ ] 4.2 Prove certificate renewal and revocation, Peer Grant rotation, private-network reconnect, local secret permissions, and stale-connection fail-closed behavior, and verify shared-cookie runs are excluded from evidence
- [ ] 4.3 Verify source revisions fail production BEAM admission before distribution membership

## 5. Custody and compatibility

- [ ] 5.1 Implement model-free process-group custody only after accepted contracts define request-slot release, native cessation, and worker-unit and resource-allocation targeting
- [ ] 5.2 Prove reader-first `N` and `N-1` decoding and fail-closed rejection of incomplete targeted operations

## 6. Mixed-platform acceptance

- [ ] 6.1 Identify an exact governed predecessor Node Agent revision before claiming the `N`/`N-1` pairing, and verify its absence leaves the gate unmet
- [ ] 6.2 Run `macos_controller_linux_node_model_free` for both pairings with independently captured evidence from every participating host

## 7. Provider gate

- [ ] 7.1 Confirm every provider-neutral gate passes before any separately authorized runtime-provider pilot
- [ ] 7.2 If separately authorized, qualify one exact immutable hardware, provider, model, and profile tuple at concurrency one without broader support claims

## 8. Validation

- [x] 8.1 Run `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate reconcile-linux-node-source-dev-contract --type change --strict --no-interactive` and the all-specs strict validation, and verify both pass
- [x] 8.2 Run `git diff --check`, relative-link checks, and static consistency checks for this docs-only change, and verify the Distribution Pause Control is unchanged
- [ ] 8.3 Run the full `AGENTS.md` Elixir workflow for every later implementation slice
- [ ] 8.4 After acceptance and archive or sync, review generated main specs for placeholder prose such as `Purpose TBD`
