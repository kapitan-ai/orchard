## 1. Contract and Decision Acceptance

- [ ] 1.1 Amend `SPEC.md` §§1.4, 2.5, 4.1, 4.9, 4.10, 11.3, 11.4, and 13.4 with the accepted profile, provenance, custody, retained-identity, rollback, and support boundaries.
- [ ] 1.2 Accept ADR 0030 and record that it narrowly supersedes only ADR 0027's no-managed-handover conclusion for the named profile and realizations.
- [ ] 1.3 Reconcile terminology and cross-references with `product-versioning-release-governance`, `deprecate-node-runtime-grpc-compatibility`, `add-portable-validation-fanout`, and `operator-first-run-journey` without duplicating their ownership.
- [ ] 1.4 Obtain collaborator review of the proposal, design, delta specifications, migration matrix, and explicit exclusions before behavior implementation.

## 2. Closed Composition and Provenance

- [ ] 2.1 Define versioned schemas for component manifests, the composition lock, detached build attestation, and the common verifier decision.
- [ ] 2.2 Implement deterministic tree closure with traversal, link, collision, special-file, permission, extended-attribute, ACL, Mach-O dependency, entitlement, and extraction-limit checks.
- [ ] 2.3 Implement the macOS arm64 Node Agent component build from the provider-neutral Node Agent core.
- [ ] 2.4 Implement the launchd host-adapter component with one versioned privileged-helper protocol.
- [ ] 2.5 Implement the exact-pinned MLX Worker Provider component and record its independent version and Worker Runtime compatibility identity.
- [ ] 2.6 Implement `exact_ref_source_build` validation for canonical repository, authorized exact ref, clean source, pinned toolchains, dependency locks, controlled inputs, target identity, and trusted builder policy.
- [ ] 2.7 Implement `orchard_signed_prebuilt` validation for exact bytes, Orchard authorization, code-signing chain, designated requirements, entitlements, notarization and stapling where applicable, target identity, and composition compatibility.
- [ ] 2.8 Implement one fail-closed verifier decision contract consumed by both realization validators.
- [ ] 2.9 Add malformed, incomplete, ambiguous, byte-divergent, unauthorized, dirty-source, untrusted-builder, and cross-realization-confusion tests.

## 3. Retained Node Identity Root

- [ ] 3.1 Define the durable Node Identity Root boundary and inventory retained identity, enrollment, trust-root, and schema-governed state without recording secret values.
- [ ] 3.2 Add composition declarations for readable and writable retained-schema ranges.
- [ ] 3.3 Reject activation when the incoming or rollback composition cannot read every retained schema reachable during the transition.
- [ ] 3.4 Prohibit irreversible retained-schema mutations in the v1 supported transition set.
- [ ] 3.5 Add identity continuity and incompatible-schema regression tests across activation, rollback, interruption, and host reboot.

## 4. Controller Coordination and Operator Authority

- [ ] 4.1 Add an authenticated operation that requests Node maintenance and drain for a named composition transition.
- [ ] 4.2 Require a fresh Controller acknowledgement of unschedulability and zero active allocations before host mutation.
- [ ] 4.3 Keep maintenance sticky through activation, start, rollback, recovery, timeout, Controller disconnect, and uncertainty.
- [ ] 4.4 Require the started process to report the expected composition and identity before Controller health evaluation.
- [ ] 4.5 Require a separate authorized uncordon after health and compatibility pass.
- [ ] 4.6 Add public-interface authorization, stale-acknowledgement, concurrent-operation, disconnect, and denied-uncordon tests.

## 5. Host Process Fence and Activation Journal

- [ ] 5.1 Define and implement one privileged helper protocol for operation locking, durable managed-launch suppression, exact process capture, stop, exit proof, and replacement detection.
- [ ] 5.2 Route Swift, Elixir, scripts, and lifecycle tests through the helper protocol instead of copying process-fence logic.
- [ ] 5.3 Add the managed-composition activation-journal schema and reject it from lifecycle code that does not understand the schema.
- [ ] 5.4 Implement monotonic durable states from preflight through `activated_stopped`, verified start, and `started_pending_controller`.
- [ ] 5.5 Separate byte activation and rollback restoration from all service-start behavior.
- [ ] 5.6 Keep launch suppression active for every uncertain journal, verification, custody, compatibility, or rollback outcome.
- [ ] 5.7 Prove the managed launch domain has no outgoing or replacement process before activating or starting the incoming composition.
- [ ] 5.8 Prove unrelated processes survive and stale or recycled process identities are rejected.
- [ ] 5.9 Add fault injection at every journal boundary plus process replacement, helper failure, disk failure, and host reboot coverage.

## 6. Orchard.app and DMG Integration

- [ ] 6.1 Add a declared Node-role subtree to app assembly that accepts only a verifier-admitted composition.
- [ ] 6.2 Bind the embedded composition-lock and detached build-attestation digests into governed app build evidence.
- [ ] 6.3 Verify the final signed app contains the exact admitted composition bytes and identities.
- [ ] 6.4 Extend Candidate or Internal Build Manifest integration to reference the composition-lock digest without creating an identity cycle.
- [ ] 6.5 Package the exact verified app tree into the DMG and rerun existing app, signing, Gatekeeper, notarization, stapling, and DMG checks appropriate to the build stage.
- [ ] 6.6 Prove that component archives, composition locks, and build attestations cannot be installed or represented as independently supported artifacts.
- [ ] 6.7 Preserve Controller, CLI, Console, and all-in-one app contents and roles not changed by this Node-specific slice.

## 7. Migration and Rollback Proof

- [ ] 7.1 Implement explicit legacy-baseline closure that completes before host mutation and rejects an installed Node whose exact current bytes cannot be closed and verified.
- [ ] 7.2 Prove `exact_ref_source_build` to `orchard_signed_prebuilt` on real Apple Silicon macOS with the same Node Identity Root and no managed-process overlap.
- [ ] 7.3 Prove `orchard_signed_prebuilt` to `exact_ref_source_build` on real Apple Silicon macOS with the same Node Identity Root and no managed-process overlap.
- [ ] 7.4 Prove rollback from each direction restores only verified compatible bytes and remains stopped until a separate verified start.
- [ ] 7.5 Prove failed activation, failed start, interrupted rollback, incompatible retained state, Controller disconnect, helper uncertainty, and host reboot remain stopped, launch-suppressed, and unschedulable.
- [ ] 7.6 Prove foreground `make dev` and its existing source-development stop path remain unchanged and cannot be silently adopted into managed custody.

## 8. Quality, Evidence, and Handoff

- [ ] 8.1 Run strict OpenSpec validation and review generated main specifications for complete prose.
- [ ] 8.2 Run the full applicable Elixir, Swift/macOS app, native Worker Provider, packaging, and coverage workflows from the umbrella root.
- [ ] 8.3 Run adjacent suites and public interfaces that exercise the same lifecycle, scheduling, identity, packaging, and rollback paths.
- [ ] 8.4 Record exact commands and pass or fail evidence in the approved issue or pull request without committing raw logs, credentials, local paths, or tool session identifiers.
- [ ] 8.5 Obtain independent code, security, packaging, and real-hardware migration review before claiming the profile supported.
- [ ] 8.6 Keep Amore publication, credentials, tags, releases, native PKG, other platforms, relaxed skew, and zero-downtime behavior outside the implementation and handoff.
