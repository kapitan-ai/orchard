## 1. Contract and Decision Acceptance

- [ ] 1.1 Accept `product-versioning-release-governance` first or accept both changes atomically, then amend `SPEC.md` §§1.4, 2.5, 4.1 through 4.4, 4.6.2, 4.9, 4.10, 5, 7.5, 11.2 through 11.4, and 13.4 with the dedicated-host, one-way-transition, single-process Worker Provider, immutable-generation, Controller-fence, and exact-baseline rollback contract; scope the §4.6.2 exception to durable grant IDs and fence epochs for this profile without admitting a general crash-recoverable reservation ledger before M7.
- [ ] 1.2 Accept ADR 0030 and record that it narrowly supersedes only ADR 0027's no-managed-handover conclusion for this profile and transition direction.
- [ ] 1.3 Reconcile terminology and artifact order with `product-versioning-release-governance`, `deprecate-node-runtime-grpc-compatibility`, and `add-portable-validation-fanout` without duplicating their ownership.
- [ ] 1.3a Reconcile `worker-runtime-providers` so the Node Agent retains logical Worker lifecycle ownership while the managed profile delegates OS parentage, durable registration, termination, and exact exit custody to the stable helper.
- [ ] 1.4 Obtain collaborator acceptance of the proposal, design, delta specifications, proof matrix, and explicit exclusions before behavior implementation.

## 2. Dedicated Profile and Entry State

- [ ] 2.1 Reserve `managed_apple_silicon_macos_node` as an experimental dedicated Node-only profile identifier and reject Controller-bearing or all-in-one hosts.
- [ ] 2.2 Keep production entry and support blocked until a separate clean-host provisioning contract with a concrete operator journey, operator-visible managed status and repair surfaces, safe managed decommission, and a next-update strategy are accepted, without adding legacy or unmanaged installation adoption here.
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
- [ ] 3.9 Define the operator-visible supported model and feature matrix bound to exact provider, interpreter, dependency closure, runtime configuration, model families, tokenizer paths, and execution modes, and require requalification whenever that binding changes.

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
- [ ] 6.2a Implement the `managed_apple_silicon_macos_node`-only §4.6.2 successor: make transition creation the allocation-issuance fence; persist unique grant IDs, fence epochs, and terminal dispositions in Postgres; make the stable helper hold one acceptance gate from authenticated pre-fence grant decision through Worker acceptance or durable rejection; make durable local epoch closure the final-acceptance fence; persist the local current epoch and consumed-or-rejected IDs in the helper journal; fail closed across Node Agent or helper restart until exact epoch reconciliation; and require local closure plus every pre-fence grant proving never-accepted, durable rejection, or confirmed execution termination and allocation release before zero acknowledgement, without creating a general pre-M7 reservation ledger.
- [ ] 6.3 Add generation-checked compare-and-swap transitions for drain acknowledgement, host-fence evidence, active pointer, provisional child, Controller arm authorization, host-arm evidence, pending Controller commit, exact-child enabled acknowledgement, Worker readiness, fresh Node Agent and Worker proof, terminal success, rollback, failure, and uncertainty.
- [ ] 6.4 Block generic resume, generic uncordon, heartbeat-driven activation, managed-target static, single-node, and compatibility fallbacks, scheduler selection, stale leader mutation, and duplicate or replayed evidence while the generation is not terminally accepted, while preserving a target positively proved to be unmanaged.
- [ ] 6.5 Make a new Controller leader load and enforce transition exclusions before lifecycle or scheduler reconciliation.
- [ ] 6.6 Implement `host_armed_pending_controller_commit` as an exact-child-only, replacement-denying, unschedulable, recoverable phase with idempotent evidence submission.
- [ ] 6.7 Commit `controller_committed_pending_child_observation` while excluded, let the exact child consume the result, open the incoming Worker gate only for that exact child, register the Worker and prove authenticated-channel and supported-model readiness, then clear exclusion, move `maintenance -> active`, establish the accepted generation's new serving epoch, and reopen its Controller grant set only in a second generation-checked transaction that freshly re-verifies the same Node Agent and Worker; keep grant issuance blocked until helper epoch reconciliation and matching Node Agent epoch-readiness across forward activation, rollback, restart, and leadership change.
- [ ] 6.8 Add public-interface authorization, race, replay, stale-generation, Controller restart, leadership change, and scheduler exclusion tests.
- [ ] 6.9 Persist a managed-profile fault exclusion bound to the exact active generation for ordinary-serving process, descriptor, filesystem, channel, or execution-identity violations; make it override health, capacity, portable restart, ordinary reconciliation, generic resume, and generic uncordon; retain independent §4.6.2 quarantine when execution termination or allocation release is unresolved; and clear each layer only through its own authenticated audited reconciliation proof.
- [ ] 6.10 Add stable scheduler reason codes `managed_transition_excluded`, `managed_profile_fault_excluded`, and `managed_profile_matrix_unqualified`; make their primary precedence transition, fault, matrix, existing quarantine or health, then capacity; and retain all secondary reasons in diagnostics.

## 7. BEAM Execution Custody and Registered Process Fence

- [ ] 7.1 Implement one privileged helper protocol for host locking, durable general launch suppression, Worker Provider spawn authorization and registration, one-shot Node Agent authorization, exact direct-process capture, stop, exit proof, and replacement detection; authenticate installed caller code identity and role; bind every command to exact operation state, command kind, canonical arguments, command ID, and fresh nonce; durably consume command ID and nonce before the first side effect; and make duplicate recovery idempotent across helper restart.
- [ ] 7.2 Route Swift, Elixir, scripts, and tests through that protocol instead of copying process-fence logic.
- [ ] 7.3 Make the managed v1 MLX Worker Provider one non-forking, non-daemonizing process that may use threads but cannot create descendants or launch another executable.
- [ ] 7.3a Define and qualify the exact pinned ERTS support-process set, including OTP 29 `erl_child_setup`; treat exact-pinned `epmd` as stable host infrastructure outside generations; register exact support-process and inherited-descriptor identities before cluster authority; and prohibit every other Erlang Port target, resolver helper, shell, library child, or direct spawn path.
- [ ] 7.4 Route every Worker Provider start through a reserve-before-spawn helper protocol without an intervening shell or persistent launcher: durably reserve with a unique inherited lifetime reservation lock and initialization-and-liveness gate, fail-exit on gate EOF before initialization and terminate on EOF afterward, use public POSIX `fork` plus identity drop plus `execve`, close every inherited descriptor except the operation-bound reservation-lock, gate, and channel-capability allowlist, bind and fsync exact PID, process-start identity from `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID)`, executable identity from `proc_pidpath`, generation, execution epoch, and owning Node Agent, then release; recover a missing-PID reservation by closing the gate and acquiring the lock exclusively.
- [ ] 7.5 Bind the transition-creation allocation-issuance fence, helper-serialized durable local final-acceptance fence, zero-active-allocation acknowledgement, durable general launch suppression, and atomic local Worker Provider spawn-gate close into the no-new-execution point.
- [ ] 7.6 Close all outgoing Worker Runtime channels, prove exact termination of every registered Worker Provider, then terminate the Node Agent root only through label-bound launchd job-domain disablement and bootout authority for the profile-fixed label so registered ERTS support processes exit through parent-pipe closure; prove root and support-process exit with live `kevent` `EVFILT_PROC` registrations plus post-exit identity recheck, treat unavailable exact launchd authority, a registered ERTS survivor, or missing live registration as uncertainty without issuing a bare-PID signal, remove every outgoing generation-scoped socket, and prove that no old channel remains connectable before pointer activation.
- [ ] 7.7 Reject an observed unregistered provider, descendant process, daemonization, PID reuse, executable mismatch, failed spawn-gate close, surviving registered process, stale usable channel, external generation process, or incomplete observation as uncertainty.
- [ ] 7.8 Treat process-tree scans and POSIX process groups only as violation detection and cleanup defense-in-depth, never as custody or closure proof.
- [ ] 7.9 Keep the Worker Provider free of Node Certificates, BEAM Peer Grants, BEAM membership, Controller reachability, and an independently schedulable Runtime Endpoint.
- [ ] 7.10 Require a separately accepted containment contract or distribution profile before admitting a multi-process Worker Provider.
- [ ] 7.11 Prove unrelated processes survive.
- [ ] 7.12 Run the Worker under a profile-fixed unprivileged account name created and verified by clean-host provisioning, never bind a machine-specific numeric UID, and enforce denial of identity, trust, pointer, journal, helper-control, other-generation, and shared mutable serving state while permitting read and execute access only to the exact admitted current-generation Worker code and qualified closed system resources, read-only admitted models, write access only to generation-scoped scratch, and the authenticated local channel.
- [ ] 7.13 Mint a fresh per-start channel capability, deliver the Worker copy only through an inherited descriptor and the Node Agent copy only through the authenticated helper protocol, never expose it through argv, environment, logs, or shared files, bind both peers and every request to exact operation and process identities, and reject replay and alternate peers over one long-lived gRPC connection to a helper-reserved filesystem Unix-domain socket that is unlinked after exact peer authentication.
- [ ] 7.13a Use `waitpid` only while the original helper remains the Worker parent; after helper death in `bound`, `released`, serving, or terminal-pending state, require liveness-gate EOF, exclusive lifetime-lock acquisition, durable-registry reconciliation, and any still-live `EVFILT_PROC` evidence before restart or pointer action. Use recorded `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID)` start identity plus `proc_pidpath` executable identity, a live `kevent` `EVFILT_PROC` registration, and post-exit recheck for registered non-children; never use process-table text as exact custody proof or issue a bare-PID signal after identity uncertainty.
- [ ] 7.14 Preserve Node Agent logical Worker lifecycle ownership and portable failure semantics while making the helper the managed profile's OS parent and fail-closed process-custody authority.

## 8. Atomic Pointer, Provisional Start, and Terminal Acceptance

- [ ] 8.1 Implement one validated relative active-generation pointer and atomic same-filesystem pointer replacement with required durability barriers.
- [ ] 8.2 Record and verify old and new pointer identities before and after replacement.
- [ ] 8.3 Implement operation-bound, transition-generation-bound, generation-bound, executable-bound, nonce-bound one-shot authorization under durable general suppression.
- [ ] 8.3a Make one profile-fixed system-domain launchd label always start the stable bootstrap as the job root; have the bootstrap `execve` the authorized Node Agent in place; define and implement the exact persist-one-shot, enable-label, bootstrap-label, atomic-claim, root-registration, disable-label ordering; make every interruption reconcile to disabled fail-closed state; use label-bound disablement and bootout for stop; and leave the label enabled only after durable exact active-policy installation.
- [ ] 8.4 Atomically claim the one-shot for exactly one provisional child and reject every second, stale, replacement, or mismatched claim.
- [ ] 8.5 Prevent the provisional child from normal registration, capacity publication, Worker Provider execution, Runtime Endpoint work, request serving, and scheduler eligibility.
- [ ] 8.6 Collect exact provisional evidence and obtain the Controller's generation-bound arm token while the Node remains unschedulable.
- [ ] 8.7 Consume that token into `host_armed_pending_controller_commit`, keep the exact child provisional, deny replacement, and submit arm evidence idempotently.
- [ ] 8.8 Commit the pending Controller result while excluded, let the exact child consume it, open the incoming Worker gate only for the exact child, generation, transition, and execution epoch, register the Worker, establish its authenticated channel, and acknowledge protocol and representative supported-model readiness before the fresh terminal challenge.
- [ ] 8.8a After accepted terminal `succeeded` or fully accepted `rolled_back`, durably and idempotently replace transitional suppression only with an exact active-generation launch policy bound to the terminal result, Node, generation, executable, and bootstrap; preserve suppression until installation succeeds, make Controller-terminal-active with host suppression explicit, retry only the exact installation through stable-bootstrap recovery, and reject stale or alternate-generation replacement starts.
- [ ] 8.9 Add owner-death, host-reboot, launchd-retry, second-claim, wrong-child, wrong-generation, and missing-terminal-evidence tests.

## 9. Exact-Baseline Rollback and Recovery

- [ ] 9.1 Permit rollback only to the exact immutable source baseline bound at Controller transition creation.
- [ ] 9.2 Fence and stop the candidate registered-process set before atomically restoring the baseline pointer.
- [ ] 9.3 Start the restored baseline only through a new one-shot provisional operation under durable suppression.
- [ ] 9.4 Require the same Controller host-arm token, idempotent arm evidence, pending-result consumption, exact-child enablement, incoming Worker gate, reserve-before-spawn registration, authenticated channel, supported-model readiness, fresh Node Agent and Worker proof, and second terminal generation protocol before returning the baseline to eligibility.
- [ ] 9.5 Prohibit backup reconstruction, another source ref, another generation, prior-loaded-service restoration, and generic resume.
- [ ] 9.6 Keep every unknown journal, contradictory pointer, missing generation, incompatible bootstrap, identity mismatch, unreachable Controller, process ambiguity, or rollback failure stopped, suppressed, and unschedulable.
- [ ] 9.7 Persist a lifetime managed-profile admission marker and make every generic schema-v1 install, update, uninstall, start, stop, rollback, and recovery path reject or delegate to the stable managed bootstrap.
- [ ] 9.8 Add fault injection at every local journal and Controller database boundary.

## 10. Qualification and Handoff

- [ ] 10.1 Prove the complete forward transition and exact-baseline rollback through supported public interfaces on real Apple Silicon macOS.
- [ ] 10.2 Run adversarial fork, subprocess, daemonization, unregistered-execution, reserve-before-spawn crash, spawn-gate race, helper caller and nonce replay, PID reuse, stale-channel impersonation and request replay, remnant protected-resource access, Worker readiness loss, launch-replacement, owner-death, host-reboot, Controller-restart, leader-race, stale-heartbeat, execution-grant replay, generic-resume, artifact-mismatch, and rollback-uncertainty cases.
- [ ] 10.2a Audit executable-launch paths and observe runtime process creation across the exact supported model and feature matrix; treat the result as qualification of that bound matrix rather than universal proof of non-forking behavior.
- [ ] 10.3 Prove the target host runs no Controller role and that existing Controller-bearing, all-in-one, app, DMG, Worker Runtime, and foreground source-development behavior remains conformant.
- [ ] 10.4 Run strict OpenSpec validation and the full applicable Elixir, Swift/macOS app, native Worker Provider, packaging, and coverage workflows.
- [ ] 10.5 Record exact commands and evidence in the approved issue or pull request without committing raw logs, secrets, local paths, or tool session identifiers.
- [ ] 10.6 Obtain independent architecture, security, packaging, and real-hardware migration review before claiming support.
- [ ] 10.7 Keep all excluded platforms, roles, provenance directions, updates, identity migrations, credentials, publication, native PKG, and zero-downtime behavior outside implementation and handoff.
