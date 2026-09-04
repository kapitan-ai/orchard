## 1. Contract and Decision Acceptance

- [ ] 1.1 Accept `product-versioning-release-governance` first or accept both changes atomically, then amend `SPEC.md` §§1.4, 2.5, 4.1 through 4.4, 4.9, 4.10, 5, 11.2 through 11.4, and 13.4 with the dedicated-host, one-way-transition, immutable-generation, Controller-fence, and exact-baseline rollback contract.
- [ ] 1.2 Accept ADR 0030 and record that it narrowly supersedes only ADR 0027's no-managed-handover conclusion for this profile and transition direction.
- [ ] 1.3 Reconcile terminology and artifact order with `product-versioning-release-governance`, `deprecate-node-runtime-grpc-compatibility`, and `add-portable-validation-fanout` without duplicating their ownership.
- [ ] 1.4 Obtain collaborator acceptance of the proposal, design, delta specifications, proof matrix, and explicit exclusions before behavior implementation.

## 2. Dedicated Profile and Entry State

- [ ] 2.1 Define `managed_apple_silicon_macos_node` as a dedicated Node-only distribution profile and reject Controller-bearing or all-in-one hosts.
- [ ] 2.2 Keep production entry into the already managed baseline blocked until a separate clean-host provisioning contract is accepted, without adding legacy or unmanaged installation adoption here.
- [ ] 2.3 Reject native PKG receipts, foreground source-development processes, arbitrary installed trees, and external supervisors as baseline evidence.
- [ ] 2.4 Preserve foreground `make dev` and every existing non-managed profile behavior.

## 3. Closed Generations and Provenance

- [ ] 3.1 Define versioned schemas for signed component manifests, the composition lock, source-construction evidence, purpose-bound verifier decisions, and immutable generation identity.
- [ ] 3.2 Implement deterministic closure with traversal, link, collision, special-file, permission, extended-attribute, ACL, Mach-O dependency, entitlement, and extraction-limit checks.
- [ ] 3.3 Implement verifier-controlled isolated `exact_ref_source_build` construction with canonical repository, authorized full commit, clean inputs, pinned toolchains, dependency locks, controlled environment, and exact target checks.
- [ ] 3.4 Remove any pretrusted-local-builder admission path from v1.
- [ ] 3.5 Implement the macOS arm64 Node Agent, launchd generation contract, exact-pinned MLX Worker Provider, dedicated interpreter, and closed runtime dependencies.
- [ ] 3.6 Reject every executable, provider, interpreter, launch-label, active-pointer, or identity-path override.
- [ ] 3.7 Publish every baseline and candidate as a new immutable content-addressed generation and prohibit in-place mutation.
- [ ] 3.8 Add malformed, incomplete, ambiguous, dirty-source, unauthorized, wrong-purpose, wrong-stage, and byte-divergent regression tests.

## 4. Stable Bootstrap and Retained Identity

- [ ] 4.1 Define and implement the stable signed lifecycle, launch-gate, recovery, active-pointer, and privileged-helper bootstrap outside replaceable generations.
- [ ] 4.2 Block activation when the exact bootstrap identity or helper protocol required by either generation is absent or incompatible.
- [ ] 4.3 Prohibit bootstrap, helper, launchd plist, launch-label, launch-gate, pointer-path, and trust-policy replacement during the v1 transition.
- [ ] 4.4 Define the Node Identity Set as the complete current Node Identity Store generation, scoped BEAM Peer Grant Store, and stable bootstrap release-trust store, with exact versioned fields and paths.
- [ ] 4.5 Bind exact store generations and digests at Controller transition creation, freeze stable key and trust-anchor identity, and permit renewable certificate or peer-grant rotation only through generation-checked scheduler-excluded recovery with rebinding and reauthorization.
- [ ] 4.6 Add bootstrap incompatibility, unknown journal, identity mutation, identity relocation, and reboot regression tests.

## 5. Artifact Identity and Signing

- [ ] 5.1 Sign nested generation code before sealing component manifests and the composition lock.
- [ ] 5.2 Admit the closed Node subtree for app assembly through purpose `assemble_node_subtree` only.
- [ ] 5.3 Preserve the current nested-helper, main-executable, outer-app signing order and verify the complete final app tree.
- [ ] 5.4 Run mandatory DMG assembly, notarization, stapling, mounting, and nested verification for every supported candidate.
- [ ] 5.5 Seal the Candidate Manifest only after the final app and DMG are verified and keep its identity graph acyclic.
- [ ] 5.6 Implement activation authorization after Controller transition creation and bind it to purpose, stage, Node, operation, transition generation, target profile, transition direction, final mounted candidate app, imported Node subtree, composition, installed bootstrap, Candidate Manifest, and exact DMG evidence.
- [ ] 5.7 Prove assembly admission cannot authorize activation and that later signing or packaging cannot change an activation-authorized identity.
- [ ] 5.8 Prove no component archive, generation, composition lock, verifier decision, app, or unpublished DMG gains a standalone support claim.

## 6. Durable Controller Transition Generation

- [ ] 6.1 Persist one monotonically increasing managed transition generation per Node with a unique nonterminal-generation constraint.
- [ ] 6.2 Atomically bind exact artifact identities, operation, actor, direction, compatibility, `draining` state, scheduler exclusion, and audit evidence at creation.
- [ ] 6.2a Make transition creation the allocation fence, require allocation claims and final Worker Runtime execution acceptance to serialize against it, and prove zero acknowledgement covers every pre-fence accepted execution with no post-fence acceptance.
- [ ] 6.3 Add generation-checked compare-and-swap transitions for drain acknowledgement, host-fence evidence, active pointer, provisional child, Controller arm authorization, host-arm evidence, pending Controller commit, exact-child enabled acknowledgement, fresh live-child proof, terminal success, rollback, failure, and uncertainty.
- [ ] 6.4 Block generic resume, generic uncordon, heartbeat-driven activation, managed-target static, single-node, and compatibility fallbacks, scheduler selection, stale leader mutation, and duplicate or replayed evidence while the generation is not terminally accepted, while preserving a target positively proved to be unmanaged.
- [ ] 6.5 Make a new Controller leader load and enforce transition exclusions before lifecycle or scheduler reconciliation.
- [ ] 6.6 Implement `host_armed_pending_controller_commit` as an exact-child-only, replacement-denying, unschedulable, recoverable phase with idempotent evidence submission.
- [ ] 6.7 Commit `controller_committed_pending_child_observation` while excluded, let the exact child consume and acknowledge that result, then clear exclusion and move `maintenance -> active` only in a second generation-checked transaction that freshly re-verifies the same enabled child.
- [ ] 6.8 Add public-interface authorization, race, replay, stale-generation, Controller restart, leadership change, and scheduler exclusion tests.

## 7. Descendant Process Fence

- [ ] 7.1 Implement one privileged helper protocol for host locking, durable general launch suppression, one-shot authorization, kernel-backed containment, capture, stop, exit proof, and replacement detection.
- [ ] 7.2 Route Swift, Elixir, scripts, and tests through that protocol instead of copying process-fence logic.
- [ ] 7.3 Establish authoritative Managed Process Containment before each baseline or candidate first start, require membership to survive reparenting and prevent generation-code escape, and treat scans only as violation detectors.
- [ ] 7.4 Select and prove a supported public macOS kernel-backed containment primitive that prevents managed descendants from escaping membership and atomically closes new-child creation before recording the no-new-child point.
- [ ] 7.5 Prove exact termination of the complete closed containment membership and no replacement root before pointer activation.
- [ ] 7.6 Reject containment escape, PID reuse, executable mismatch, membership ambiguity, failed close, surviving members, external generation processes, and incomplete observation as uncertainty.
- [ ] 7.7 Prove unrelated processes survive.

## 8. Atomic Pointer, Provisional Start, and Terminal Acceptance

- [ ] 8.1 Implement one validated relative active-generation pointer and atomic same-filesystem pointer replacement with required durability barriers.
- [ ] 8.2 Record and verify old and new pointer identities before and after replacement.
- [ ] 8.3 Implement operation-bound, transition-generation-bound, generation-bound, executable-bound, nonce-bound one-shot authorization under durable general suppression.
- [ ] 8.4 Atomically claim the one-shot for exactly one provisional child and reject every second, stale, replacement, or mismatched claim.
- [ ] 8.5 Prevent the provisional child from normal registration, capacity publication, Worker Provider execution, Runtime Endpoint work, request serving, and scheduler eligibility.
- [ ] 8.6 Collect exact provisional evidence and obtain the Controller's generation-bound arm token while the Node remains unschedulable.
- [ ] 8.7 Consume that token into `host_armed_pending_controller_commit`, keep the exact child provisional, deny replacement, and submit arm evidence idempotently.
- [ ] 8.8 Commit the pending Controller result while excluded, let the exact child consume it and acknowledge exact-child enabled state, then commit terminal success only after a fresh challenge of that same enabled child.
- [ ] 8.9 Add owner-death, host-reboot, launchd-retry, second-claim, wrong-child, wrong-generation, and missing-terminal-evidence tests.

## 9. Exact-Baseline Rollback and Recovery

- [ ] 9.1 Permit rollback only to the exact immutable source baseline bound at Controller transition creation.
- [ ] 9.2 Fence and stop any candidate closure before atomically restoring the baseline pointer.
- [ ] 9.3 Start the restored baseline only through a new one-shot provisional operation under durable suppression.
- [ ] 9.4 Require the same Controller host-arm token, idempotent arm evidence, pending-result consumption, exact-child acknowledgement, fresh live-child proof, and second terminal generation protocol before returning the baseline to eligibility.
- [ ] 9.5 Prohibit backup reconstruction, another source ref, another generation, prior-loaded-service restoration, and generic resume.
- [ ] 9.6 Keep every unknown journal, contradictory pointer, missing generation, incompatible bootstrap, identity mismatch, unreachable Controller, process ambiguity, or rollback failure stopped, suppressed, and unschedulable.
- [ ] 9.7 Persist a lifetime managed-profile admission marker and make every generic schema-v1 install, update, uninstall, start, stop, rollback, and recovery path reject or delegate to the stable managed bootstrap.
- [ ] 9.8 Add fault injection at every local journal and Controller database boundary.

## 10. Qualification and Handoff

- [ ] 10.1 Prove the complete forward transition and exact-baseline rollback through supported public interfaces on real Apple Silicon macOS.
- [ ] 10.2 Run adversarial descendant, reparenting, PID reuse, launch replacement, owner-death, host-reboot, Controller-restart, leader-race, stale-heartbeat, generic-resume, artifact-mismatch, and rollback-uncertainty cases.
- [ ] 10.3 Prove the target host runs no Controller role and that existing Controller-bearing, all-in-one, app, DMG, Worker Runtime, and foreground source-development behavior remains conformant.
- [ ] 10.4 Run strict OpenSpec validation and the full applicable Elixir, Swift/macOS app, native Worker Provider, packaging, and coverage workflows.
- [ ] 10.5 Record exact commands and evidence in the approved issue or pull request without committing raw logs, secrets, local paths, or tool session identifiers.
- [ ] 10.6 Obtain independent architecture, security, packaging, and real-hardware migration review before claiming support.
- [ ] 10.7 Keep all excluded platforms, roles, provenance directions, updates, identity migrations, credentials, publication, native PKG, and zero-downtime behavior outside implementation and handoff.
