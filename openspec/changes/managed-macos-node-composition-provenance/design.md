## Context

Orchard already has three relevant but separate foundations.
The macOS native distribution profile builds and verifies a signed `Orchard.app` in a DMG.
The app lifecycle serializes root-authorized host mutations and can recover a failed transaction, but it replaces managed paths in place and may restore previously loaded services automatically.
The source-development Node Agent stop path captures an exact root process and rejects replacement, but it does not durably suppress launch or retain Worker Provider custody after the BEAM exits.

The first managed-composition design tried to solve source and prebuilt transitions in both directions, legacy adoption, builder enrollment, retained-schema ranges, and broad app-role compatibility at once.
Review converged on a smaller safe boundary.
V1 is one transition on a dedicated Node-only host from an already managed verifier-built source baseline to one Orchard-signed prebuilt generation, with rollback only to that exact baseline.

The normative hierarchy remains `SPEC.md`, accepted decisions, accepted OpenSpec specifications, tests, and implementation.
This package must be accepted with a corresponding `SPEC.md` amendment before behavior implementation can be conformant.

## Goals

- Define one closed managed Node composition for a dedicated Apple Silicon macOS Node host.
- Prove one source-baseline-to-signed-prebuilt transition with no outgoing serving-authority overlap and no registered outgoing process overlap.
- Preserve exactly one rollback target and one frozen retained identity schema.
- Keep recovery authority stable outside replaceable generations.
- Make Controller schedulability depend on exact durable transition evidence rather than generic resume or heartbeat health.
- Bind verification to its purpose, artifact stage, target profile, and final governed identities.
- Require adversarial real-hardware proof before a support claim.

## Non-Goals

- Legacy or unmanaged installation adoption.
- A normal `orchard_signed_prebuilt` to `exact_ref_source_build` transition.
- A second managed update after the first signed-prebuilt activation.
- Prebuilt-to-prebuilt upgrade, arbitrary downgrade, or relaxed version skew.
- A pretrusted local builder or user-supplied source-build attestation.
- Controller-bearing or all-in-one host activation.
- Lifecycle-bootstrap replacement during the managed transition.
- Node Identity Set schema migration, relocation, deletion, or extension.
- Executable, provider, interpreter, launch-label, or identity-path overrides.
- Amore upload, promotion, publication, or credential handling.
- GitHub Release publication or other release authority.
- Linux, WSL, Windows, Intel macOS, or another Node distribution profile.
- Zero-downtime or overlapping-process activation.
- Native PKG or removed-PKG handover.
- Standalone support for a component archive, composition lock, build attestation, app, or unpublished DMG.
- Changing the foreground behavior of `make dev`.

## Contract Reconciliation

### Existing Contract Preserved

The existing macOS native distribution profile remains the outer distribution contract.
`Orchard.app` remains the installed product boundary and the signed DMG remains the supported transport artifact.
The Node Agent Core remains provider-neutral.
The MLX Worker Provider remains independently versioned behind the provider-neutral Worker Runtime Interface.
Controller maintenance remains unschedulable.
Native PKG remains unsupported and removed.
Foreground source development remains unmanaged and under terminal custody.

### Existing Contract Narrowly Superseded

`SPEC.md` §11.4 and ADR 0027 currently state that Orchard has no managed Node replacement or zero-overlap protocol.
The accepted change would supersede only that absence for `managed_apple_silicon_macos_node` and only for an already managed `exact_ref_source_build` baseline transitioning to one `orchard_signed_prebuilt` generation.
Controller-bearing hosts, all-in-one hosts, legacy installs, ordinary source development, and every other transition remain outside the exception.

### Historical Input Without Authority

Superseded ADR 0018 contains useful safety vocabulary for durable suppression, one-shot launch, and provisional acceptance.
This proposal does not restore its native PKG assumptions or treat it as approval.
The new contract restates every retained invariant against immutable generations, a stable app bootstrap, and durable Controller transition state.

### Active Change Coordination

`product-versioning-release-governance` owns Product Version, Candidate and Internal Build Manifests, final artifact identities, state attestations, release state, and publication gates.
This change owns component manifests, the composition lock, source-construction evidence, purpose-bound composition verification, and activation evidence.
This change cannot be accepted before `product-versioning-release-governance` unless both changes are accepted atomically with matching terminology and identity fields.
The Candidate Manifest references the composition-lock, final app, and mandatory DMG identities after final artifact verification.
The composition lock never references the later Candidate Manifest.

`deprecate-node-runtime-grpc-compatibility` owns staged Runtime Endpoint compatibility epochs and removal gates.
This change records and verifies the required epoch and compatibility assets for the baseline and candidate.
It removes or defaults off no compatibility transport.

`add-portable-validation-fanout` owns the general validation-lane fanout.
This change supplies the profile-specific public-seam and real-hardware cases for the macOS lane.

## V1 Entry State

The target host is a dedicated Apple Silicon macOS Node candidate with no Controller release, Controller launchd job, or all-in-one role selected.
The stable signed lifecycle bootstrap and its compatible privileged helper are already installed through an approved app lifecycle.
The active-generation pointer selects one immutable verifier-built `exact_ref_source_build` baseline.
The durable managed-profile admission marker, baseline, pointer, bootstrap, launch policy, retained Node Identity Stores, and Controller Node identity have already passed the managed-profile admission checks.

V1 defines no conversion from an existing generic app installation, a foreground source checkout, a native PKG receipt, an arbitrary active tree, or another launch supervisor into this entry state.
Production entry into this state requires a separate accepted clean-host provisioning contract.
Until that prerequisite exists, this change can define and review the transition but cannot qualify or claim production support.
Production admission additionally requires accepted operator-visible managed status and repair surfaces, a safe managed decommission path, and an accepted next-update strategy.
Until all prerequisites exist, `managed_apple_silicon_macos_node` is a reserved experimental identifier rather than an operator-acquirable supported profile.

## Closed Composition

The composition contains exactly these component roles:

| Component role | Required content | Bound identity |
|---|---|---|
| `node_agent` | macOS arm64 Node Agent component built from the provider-neutral Node Agent core | signed tree digest, build identity, Runtime Endpoint compatibility |
| `launchd_host_adapter` | generation-side launch contract consumed by the stable lifecycle bootstrap | signed tree digest, bootstrap protocol version, fixed launch identity |
| `mlx_worker_provider` | exact-pinned MLX Worker Provider, dedicated interpreter, tokenizer, and closed runtime dependencies | signed tree digest, provider version, Worker Runtime protocol identity |

The stable lifecycle executable, launch gate, recovery logic, and privileged helper are profile prerequisites outside the replaceable composition.
The composition records their required exact identity and protocol version but cannot replace them.
The Node Agent component also binds the pinned OTP runtime's closed ERTS support-process set.
For OTP 29 this includes the exact `erl_child_setup` executable created by ERTS.
Any profile `epmd` service is exact-pinned stable host infrastructure outside replaceable generations rather than a generation child.
ERTS support processes and `epmd` hold no Node Certificates, BEAM Peer Grants, Worker channel capabilities, Controller request authority, or Runtime Endpoint.

Every executable and interpreter path is internal to either the stable bootstrap or immutable generation and is named by the signed contract.
The launchd label and active-pointer location are fixed by the profile.
Environment variables, command arguments, mutable configuration, symlinks, retained identity, and operator data cannot select another Node Agent, bootstrap, interpreter, or Worker Provider.

Models and operator data remain outside the composition under their existing storage contracts.
They cannot contain an executable override used by the managed process tree.
The profile publishes a supported model and feature matrix bound to the exact Worker Provider, interpreter, dependency closure, relevant runtime configuration, model families, tokenizer paths, and execution modes qualified for the single-process contract.
Anything outside that matrix is rejected with a stable operator-visible reason, and any change to the bound closure invalidates qualification until the affected matrix is requalified.

## Component Closure

Each component manifest records normalized relative path, entry kind, digest, byte length, mode, ownership policy, extended-attribute policy, code-signing identity where applicable, Mach-O dependency closure, entitlements, and component compatibility identity.
Directory traversal, absolute paths, hard links, device files, sockets, FIFOs, undeclared extended attributes, access-control-list mutations, and symlinks outside the component root are rejected.
Internal symlinks are relative, resolve within the same immutable generation, and cannot form cycles.
Path comparison rejects case-fold and Unicode-normalization collisions before extraction.
Extraction uses bounded entry counts, bounded path length, bounded expanded bytes, an isolated staging root, and an atomic same-filesystem publication into a new generation directory after complete verification.

The Node Identity Set, activation journals, operation evidence, active pointer, release manifests, and generated digest files are not part of a component tree digest.
Every exclusion is explicit.

## Artifact Identity and Signing Order

The identity graph is acyclic and follows the actual packaging order:

1. Verifier-controlled source construction records canonical repository, authorized full commit, clean declared inputs, pinned toolchains, dependency locks, controlled environment, and target identity.
2. Nested Node Agent, dedicated Worker Provider interpreter and native code, and generation-side helper code receive their required signatures and entitlements.
3. Canonical component manifests identify the final signed component bytes.
4. The composition lock binds ordered component-manifest digests, target profile, target platform, exact stable-bootstrap requirement, frozen identity schema, compatibility identities, and realization.
5. An assembly-admission decision binds the composition lock to purpose `assemble_node_subtree` and the app-build stage.
6. The admitted Node subtree is embedded into `Orchard.app` without changing those signed generation bytes.
7. Stable app helpers, the main app executable, and the outer app bundle are signed in the existing inner-to-outer order and the complete final app tree is verified.
8. DMG assembly, notarization, stapling, mounting, and post-assembly nested verification produce the final DMG and mounted-app identities.
9. The Candidate Manifest is sealed after the final app and DMG have verified identities and records Product Version, exact commit, app tree, composition lock, Node subtree, bootstrap identity, and DMG identity.
10. The installed stable bootstrap imports only the admitted Node subtree from the verified mounted candidate app into a new immutable generation while every stable-bootstrap identity remains unchanged.
11. Activation authorization is issued only after Controller transition creation and binds those sealed identities to one Node, operation, transition generation, target profile, and transition direction.

The composition lock contains no self-digest, app-tree digest, Candidate Manifest digest, DMG digest, publication state, or later signature.
The Candidate Manifest excludes itself and receives its digest only after canonical serialization, as required by release governance.
No build, signing, packaging, or metadata-injection step may mutate bytes after the identity that activation authorizes is sealed.

## Purpose-Bound Verification

One verifier engine applies explicit policy sets and returns a versioned decision with `purpose`, `stage`, `profile`, `realization`, exact subject identities, required evidence identities, policy version, and terminal `admitted` or `rejected` verdict.
Evidence accepted for one purpose or stage cannot be replayed as authority for another.

### Source Construction

Purpose `construct_source_baseline` runs only inside a verifier-controlled isolated builder.
It requires the canonical repository, authorized exact full commit, clean complete source inputs, pinned toolchains, dependency locks, controlled environment, exact macOS arm64 target, and deterministic declared outputs.
There is no pretrusted local builder path.

### Assembly Admission

Purpose `assemble_node_subtree` verifies closed signed component bytes and the composition lock before app assembly.
It does not authorize installation, activation, rollback, start, scheduling, delivery, or publication.

### Activation Authorization

Static candidate checks before Controller transition creation are non-authorizing preflight only.
Purpose `activate_signed_prebuilt` is issued after transition creation and requires realization `orchard_signed_prebuilt`, exact Node ID, operation ID, Controller transition generation, final mounted candidate-app identity, embedded Node subtree, imported generation identity, composition lock, installed and candidate bootstrap identity equality, accepted Candidate Manifest, target profile, source-baseline identity, transition direction, exact DMG identity, and mounted-app verification evidence.
It rejects an app extracted from another candidate, a locally resigned app, a composition copied between apps, a different bootstrap, or a valid signature that lacks Orchard authorization.

### Rollback Authorization

Purpose `rollback_to_source_baseline` names only the exact source baseline recorded in the active Controller transition generation.
It cannot select another source ref, another generation, or the previous contents of an arbitrary filesystem path.

### Terminal Evidence Verification

Purpose `accept_provisional_generation` verifies the exact provisional process, generation pointer, app, composition, bootstrap, Node identity, Runtime Endpoint, Worker Runtime, launch-suppression, and local-health evidence for the current Controller transition generation.
Purpose `accept_host_arm` verifies the generation-bound Controller token and exact durable host-arm evidence before terminal Controller commit.
Purpose `accept_enabled_child` verifies pending-result consumption, exact-child enabled acknowledgement, exact registered Worker identity, authenticated channel, execution epoch, protocol compatibility, a representative supported-model readiness or inference probe, and a fresh challenge of the same live Node Agent and Worker before active eligibility.

Missing, stale, unsupported, ambiguous, mismatched, or internally inconsistent evidence is rejected.
Downstream code cannot reinterpret a rejected or wrong-purpose decision.

## Immutable Generations and Atomic Selection

Every baseline or candidate is published into a new content-addressed immutable generation directory on the same filesystem as the active pointer.
No supported operation edits, overlays, repairs, or deletes a generation while it is the baseline, candidate, active, rollback, or evidence-retained generation.

One active-generation pointer is the only selector read by the stable bootstrap.
The pointer target is a validated relative generation identifier and cannot name an arbitrary path.
Activation writes a sibling temporary pointer, verifies its target, durably syncs the pointer and parent directory as required by the filesystem contract, atomically replaces the active pointer, and durably syncs the parent directory before recording success.

The transition journal records the old and new pointer identities before replacement and records the observed active pointer after replacement.
A torn, missing, duplicated, out-of-root, or contradictory pointer is uncertainty.

## Stable Lifecycle and Recovery Bootstrap

The root-owned stable bootstrap contains the lifecycle coordinator, launch gate, recovery reader, active-pointer resolver, and privileged-helper client.
It is signed, versioned, and verified independently of every generation.
The baseline and candidate composition locks name the exact compatible bootstrap identity and helper protocol.

The bootstrap never imports lifecycle or recovery code from the active generation before deciding whether that generation may start.
The v1 activation operation cannot change the bootstrap binary, helper, launchd plist, launch label, launch gate, active-pointer path, or bootstrap trust policy.
Any required bootstrap upgrade is a separate app lifecycle change completed and verified before a managed transition generation may be created.

An older or incompatible bootstrap rejects the operation before Controller drain or host mutation.
An unrecognized transition journal or eligibility schema leaves general launch suppression active.

## Retained Node Identity Stores

The v1 Node Identity Set is the union of three versioned stores at profile-fixed roots:

- the complete current Node Identity Store generation, including its current-generation pointer, metadata fields, private key, CSR, Node Certificate, Controller Certificate, runtime CA certificate, enrollment and cluster identifiers, URI SAN bindings, certificate identifiers and fingerprints, runtime trust SPKI digest, public-key and CSR fingerprints, state, and generation identity;
- the scoped BEAM Peer Grant Store and its current controller-bound grant records; and
- the stable bootstrap release-trust store used to verify Orchard candidate authority.

The stores live outside every immutable software generation and staging root.
Their paths and schemas are frozen for the whole v1 transition and rollback.
The exact current store-generation identities and content digests are bound when the Controller transition generation is created.
The schema, profile paths, Node ID, Node private-key identity, Controller trust anchors, runtime trust anchors, and bootstrap release-trust anchors remain frozen while that transition generation is nonterminal.
Renewable Node certificate bytes and scoped BEAM Peer Grant records may change only through their existing separately authorized protocols in an explicit generation-checked, scheduler-excluded recovery phase.
After such renewal or grant rotation, the Controller must atomically rebind the new store generation and digests and reauthorize both the exact baseline and candidate before recovery continues.
Release-root, Controller-trust-anchor, runtime-trust-anchor, Node-key, schema, or path rotation must complete before transition creation or after terminal completion.

Neither baseline nor candidate may migrate, relocate, delete, replace, extend, or symlink-substitute a store as part of activation.
Secret values never appear in component manifests, composition locks, Controller transition rows, journals, or review evidence.

## Durable Controller Transition Generation

The Controller stores one monotonically increasing managed transition generation per Node in Postgres.
At most one generation is nonterminal for a Node.
The row binds:

- Node ID and transition-generation number;
- operation ID and authorized actor;
- exact source baseline, candidate composition, final app, bootstrap, and Candidate Manifest identities;
- required Runtime Endpoint and Worker Runtime compatibility;
- expected direction `exact_ref_source_build_to_orchard_signed_prebuilt`;
- current phase and phase evidence digests;
- provisional process and one-shot identities when created;
- Controller acceptance-token identity;
- host-arm evidence identity; and
- terminal result.

Creation is allowed only from the existing `active` or `cordoned` lifecycle states.
It atomically creates the authoritative scheduler exclusion, records the managed transition generation, moves the Node to `draining`, and appends audit evidence.
The transition generation, Node lifecycle mutation, and audit evidence commit in one database transaction.
Transition creation is the allocation-issuance fence and closes the authoritative execution-grant set to new grants.
For `managed_apple_silicon_macos_node` only, this is the proposed profile-scoped successor to `SPEC.md` §4.6.2's Controller-local F11 rule, limited to durable grant IDs and fence epochs and not a general crash-recoverable reservation ledger or other pre-M7 leadership fencing.
Every allocation claim and new execution-grant issuance receives a unique execution-grant ID and observed fence epoch and atomically verifies the absence of this transition generation and scheduler exclusion in the same Controller serialization boundary as its durable Postgres authority grant.
Final Worker Runtime acceptance of a pre-fence grant instead verifies the exact durable grant, Node, request, open fence epoch, and consumed-or-rejected state through the stable helper.
The helper serializes local epoch closure against each final acceptance by holding one acceptance gate from its authenticated grant decision through Worker Runtime acceptance or durable pre-acceptance failure.
Durable local epoch closure is the final-acceptance fence; after it commits, every not-yet-accepted grant in that epoch and every closed, mismatched, duplicate, replayed, interrupted, or unresolved grant remains incapable of acceptance across restart until exact reconciliation records its disposition.
A terminal disposition requires never-accepted status, durable pre-acceptance Worker rejection, or affirmatively confirmed execution termination and allocation release; cancellation timeout, transport ambiguity, unconfirmed release, unresolved occupancy, or quarantine cannot satisfy it.
Verified inert candidate import may occur before transition creation, but no active pointer, launch suppression, running process, launch policy, or other managed launch state may change until local epoch closure is durable, every pre-fence grant has a qualifying terminal disposition, the Node has acknowledged rejection across queued, retry, streaming, recovery, and delayed-delivery paths, a fresh generation-bound zero-active-allocation acknowledgement commits, and the Node advances through the existing `draining -> maintenance` edge.

Every later Controller mutation uses compare-and-swap on the exact current transition generation and allowed prior phase.
A stale leader, duplicate request, replayed host result, prior-generation heartbeat, or concurrent operator action cannot advance or terminate the operation.
On leadership change, the new leader loads nonterminal transition generations before scheduler or lifecycle reconciliation and preserves their exclusions.

Generic `resume`, generic `uncordon`, normal heartbeat health, admission reconciliation, and scheduler health projection cannot make the Node active or route work to it while a nonterminal generation or a blocking recoverable phase exists.
Static, single-node, and compatibility fallbacks must reject any target that matches or may alias a managed Node with such a generation.
The accepted explicitly unmanaged compatibility path remains permitted only when the Controller positively proves that the target is associated with no managed Node or transition.
Only the managed transition terminal protocol may clear the exclusion.

## BEAM Execution Custody and No-New-Execution Point

The stable privileged helper is the sole authority for operation locking, durable general launch suppression, Worker Provider spawn authorization and registration, one-shot Node Agent authorization, exact direct-process identity capture, stop, exit proof, and replacement detection.
Swift, Elixir, scripts, and tests call that protocol and do not copy the safety algorithm.
The helper authenticates the installed caller code identity and role and authorizes each command against the exact Node ID, operation ID, transition generation, monotonic phase, executable identity, generation identity, and fresh nonce.
Before the first side effect, it durably consumes an operation-bound command ID and nonce bound to command kind and canonical arguments and records the result identity.
A matching duplicate returns the recorded idempotent result; a mismatched duplicate or replay across helper restart fails without repeating mutation.
It rejects stale phase, cross-role use, and any generic privileged spawn, signal, filesystem, pointer, or suppression mutation outside the closed versioned command set.

The managed v1 MLX Worker Provider is one non-forking, non-daemonizing process.
It may use threads, but it cannot create descendants or launch another executable.
The managed Node Agent may create only the exact pinned ERTS support-process set admitted by the Node Agent component and the helper-mediated Worker; BEAM processes and threads are not external OS processes.
The stable launch gate records the exact Node Agent root, and the helper durably registers every ERTS support-process PID, process-start identity, executable identity, generation identity, inherited-descriptor allowlist, and owning Node Agent before provisional or ordinary cluster authority is enabled.
The ERTS support process may communicate only over its parent-private ERTS control pipe, receives no credential or Worker-channel descriptor, and must exit on parent-pipe closure.
A registered survivor or missing live exit registration after that closure is uncertainty; recovery preserves suppression, blocks pointer activation, and does not issue a bare-PID signal.
Any Erlang Port target, resolver helper, shell, library child, or direct spawn outside that exact admitted set is prohibited.
The Node Agent starts every Worker Provider through the stable helper without an intervening shell or persistent launcher.
The helper first durably records an operation-bound pending spawn reservation and creates a unique inherited reservation lock plus initialization-and-liveness gate.
The child holds the reservation lock for its lifetime, fails-exit on gate EOF before creating Worker Runtime state, and terminates on gate EOF after initialization so helper death removes the Worker.
The helper uses public POSIX `fork`, identity drop, and `execve`, binds and durably records the exact PID, process-start identity from `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID)`, executable identity from `proc_pidpath`, generation identity, execution epoch, and owning Node Agent, fsyncs that identity, and only then releases initialization.
Before the Worker image begins execution, it closes every inherited descriptor except the operation-bound and generation-bound reservation-lock, initialization-and-liveness-gate, and channel-capability descriptors; every helper control or listener, credential, directory, scratch, socket, and unrelated descriptor is `FD_CLOEXEC` or explicitly closed.
Recovery closes the gate and acquires the reservation lock exclusively to prove that a pre-registration child exited even when no PID was committed.
After helper death in `bound`, `released`, serving, or terminal-pending state, gate EOF makes the Worker exit and release its lifetime lock; the restarted helper preserves suppression and reconciles the durable registry through exclusive lock acquisition and any still-live exit registration before restart or pointer action.
For a recorded Worker child, the helper uses `waitpid`; for a registered Node Agent or ERTS support-process non-child, it uses the recorded `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID)` start identity and `proc_pidpath` executable identity plus a live `kevent` `EVFILT_PROC` registration, exit observation, and post-exit identity recheck.
Only the original live helper parent reaps a Worker with `waitpid`; a restarted helper proves exit through liveness-gate EOF, exclusive reservation-lock acquisition, and any still-live exit registration, and remains suppressed if proof is incomplete.
The Node Agent remains the only Runtime Endpoint and the only process holding Node Certificates, BEAM Peer Grants, BEAM membership, or Controller reachability.
The Worker Provider is a replaceable local compute leaf without a TCP listener.
It runs under a profile-fixed unprivileged Worker account name created and verified by the clean-host provisioning contract; the composition never binds a machine-specific numeric UID.
That account's host-enforced filesystem policy denies the Node Identity Set, release-trust store, active pointer, managed journals, helper control endpoint, other generations, and shared mutable serving state.
For code and system resources, it permits read and execute access only to the exact admitted current-generation Worker executable, interpreter, dependency closure, and closed system-library, framework, device, and IPC resources bound by the qualified matrix.
For non-code data and mutable resources, it permits read-only admitted model inputs, write access only to generation-scoped scratch, and the authenticated generation-scoped local channel to its supervising Node Agent.
For each start, the helper mints a fresh channel capability, delivers the Worker copy only through an inherited descriptor and the Node Agent copy only through the authenticated helper protocol, and never exposes it through argv, environment, logs, or shared files.
Both peers and every Worker Runtime request authenticate and bind the Node, operation, transition generation, execution epoch, registered process identity, and request identity, rejecting replay and alternate peers.
The v1 transport is one long-lived authenticated gRPC connection over a helper-reserved filesystem Unix-domain socket path in generation-scoped scratch, not an inherited connected socket.
The Worker binds that reserved path under the dedicated account, the Node Agent connects and authenticates, and the helper then unlinks the path so no new connection can attach.
Connection loss makes the Worker unavailable and requires helper-mediated restart rather than reopening the old path.

The Controller transition generation owns a two-stage cluster execution-authority fence.
Creation is the allocation-issuance fence, while helper-serialized durable local epoch closure is the final-acceptance fence for pre-fence grants.
After the Controller records zero active allocations and the helper makes general launch suppression durable, the helper atomically closes the outgoing Node Agent's Worker Provider spawn gate.
The bound Controller fence and closed local spawn gate are the no-new-execution linearization point.

The Node Agent then closes all outgoing Worker Runtime channels.
The helper terminates and proves exact exit for every registered Worker Provider, then terminates the Node Agent root only through label-bound launchd job-domain disablement and bootout authority for the profile-fixed label and proves exact exit through its live `EVFILT_PROC` registration and post-exit identity recheck.
It never issues a bare-PID signal to the Node Agent root; inability to exercise the exact launchd job authority is uncertainty that preserves suppression and blocks pointer activation.
The helper proves that every registered ERTS support process exited through closure of its parent-private ERTS control pipe by using a live `kevent` `EVFILT_PROC` registration plus post-exit identity recheck.
It does not issue a bare-PID signal to a registered ERTS survivor after root exit because that could target a reused identity; a survivor or missing live registration is uncertainty, preserves suppression, and blocks pointer activation.
After provider exit, the helper removes every outgoing generation-scoped socket and proves that none remains connectable.
The candidate receives new process and channel identities and cannot inherit an outgoing Worker Runtime channel.
Process-table and executable scans may detect violations but cannot replace helper-owned registration or exact direct-PID exit proof.

An observed unregistered Worker Provider, ERTS support process outside the exact admitted set, descendant process, daemonization attempt, PID reuse, executable mismatch, failed spawn-gate close, surviving registered process, stale usable Worker Runtime channel, unexpected external generation process, or incomplete observation is uncertainty.
Unrelated processes outside the managed launch domain remain untouched.
Any future Worker Provider that requires multiple processes needs a separately accepted containment contract or distribution profile.
Any managed BEAM configuration that requires another external helper process also needs a separately accepted lifecycle classification and custody contract.
The safety proof does not claim that macOS can discover every possible descendant.
If admitted Worker code violates the process-shape contract without being observed, an unobserved descendant under the dedicated Worker identity is a provider defect and possible resource leak, but the dedicated Worker identity and authenticated channel prevent it from retaining cluster, host-mutation, identity, or serving authority after the Controller fence, zero-active acknowledgement, Node Agent channel closure, and Node Agent root exit.
Exact signed Node Agent and pinned OTP process-shape conformance is a trust assumption outside that remnant argument; any violation invalidates qualification and support for the profile.

An ordinary-serving managed process-shape, descriptor, filesystem, channel, or execution-identity violation closes local execution immediately, establishes general host suppression, and creates a durable Controller managed-profile fault exclusion bound to the exact active generation.
Health, capacity, portable Worker restart, ordinary reconciliation, generic resume, and generic uncordon cannot clear it.
If execution termination or allocation release is unresolved, the current Active Controller also retains the existing `SPEC.md` §4.6.2 quarantine.
Only authenticated audited generation-checked managed repair may clear local suppression and the managed-profile exclusion after re-proving the exact process set, descriptor and filesystem closure, channel identities, Worker readiness, and active-generation policy; it does not clear §4.6.2 quarantine unless independent execution-termination and allocation-release reconciliation also completes.
Controller unavailability keeps local execution closed.

## Durable Suppression and One-Shot Provisional Start

General launch suppression combines persistent launchd job-domain disablement with a stable launch-gate decision below `RunAtLoad` and `KeepAlive`.
It is established before process capture and survives initiating-process death and host reboot.

The profile-fixed system-domain launchd label always names the stable bootstrap outside replaceable generations.
That bootstrap is the launchd job root and `execve`s the exact authorized generation's Node Agent in place without a shell or forked launcher, so label-bound bootout retains authority over provisional, exact-child-enabled, and active roots.
Fully suppressed state keeps both the label disabled and the stable gate denying starts.
For a one-shot start, the helper persists the exact unclaimed authorization while disabled, enables and bootstraps only that label through the public launchd service-management interface, lets the stable bootstrap atomically claim before `execve`, durably registers the exact job-root identity, and disables the label again while the provisional child continues under stable-gate suppression.
A bootstrap invocation without the matching unclaimed authorization exits without Node identity or generation execution.
If owner death, helper death, or reboot interrupts any enable, bootstrap, claim, registration, or disable boundary, recovery reads the durable gate and journal before launch action, rejects a second claim, restores label disablement for every nonterminal state, and continues only in the same transition generation.
Only durable installation of the exact terminal active-generation launch policy leaves the label enabled and allows the stable gate to select the exact active generation for ordinary launchd restart.

The only permitted generation start under suppression uses an atomic one-shot authorization bound to Node ID, transition generation, operation ID, generation ID, exact executable, bootstrap identity, launch label, nonce, and expiry policy.
The stable launch gate atomically claims it once and records the exact child process identity.
A second claim, replacement process, mismatched generation, stale operation, or missing Controller transition fails closed.

The provisional child may perform only the minimum authenticated diagnostics needed to report transition evidence.
It cannot announce normal Node registration, publish schedulable capacity, accept requests, start Worker Provider execution, or use the retained Node identity for ordinary cluster serving.
The stable bootstrap enforces this provisional mode independently of generation-owned configuration.

General suppression remains active through provisional health and Controller terminalization.
After validating provisional evidence, the Controller may issue one generation-bound host-arm token.
The host may use that token only to persist idempotent `host_armed_pending_controller_commit` evidence for the exact provisional child.
Host arm does not authorize normal serving, does not clear general suppression, and does not permit a replacement child.
After host arm, the Controller may commit `controller_committed_pending_child_observation` while retaining maintenance and scheduler exclusion.
The exact child consumes the authenticated result and changes from provisional to exact-child enabled while ordinary dispatch remains fenced.
Only then may the helper open the incoming spawn gate for that exact child, generation, transition, and execution epoch.
The Node Agent starts and registers the single Worker through the reserve-before-spawn protocol, establishes its authenticated local channel, and acknowledges enabled state with exact Worker identity, protocol compatibility, and a representative supported-model readiness or inference probe.
The Controller then freshly challenges that same live Node Agent and registered Worker.
Only a second generation-checked transaction may advance the Node to active, clear exclusion, atomically establish the accepted generation's new serving epoch, and reopen its Controller grant set.
Grant issuance remains blocked until the helper durably reconciles that exact epoch and the Node Agent publishes matching epoch-readiness; rollback, Controller or helper restart, and leadership change use the same reconciliation gate.
If the first response is lost, the child remains provisional and resubmits the same arm evidence.
If the Node Agent or Worker exits, Worker readiness is lost, or the host reboots before the second transaction, the incoming gate closes, the arm and pending Controller commit are invalidated, suppression remains active, and recovery must restart or roll back within the same transition generation.
After an accepted terminal result (`succeeded` or fully accepted `rolled_back`), the helper must durably and idempotently replace transitional general suppression with an exact active-generation launch policy bound to that result, Node, generation, executable, and bootstrap.
Until the helper observes that exact accepted terminal result and installs the policy, general suppression remains fail closed; Controller-terminal-active with host suppression still installed is an explicit recoverable state, and stable-bootstrap recovery retries only the exact bound installation.
The narrower active policy permits launchd restart only for the admitted active generation and never for a stale or replacement generation.

## Forward Activation Protocol

1. Verify and mount the mandatory DMG, verify the final candidate app and Candidate Manifest, import only its admitted Node subtree into a new immutable candidate generation through the installed stable bootstrap, and verify the already managed source baseline, frozen Node Identity Set, and exact rollback target without host activation mutation.
2. Perform only non-authorizing static compatibility checks before Controller transition creation.
3. Create the durable Controller transition generation and atomically create scheduler exclusion, enter `draining`, and record audit evidence.
4. Close new grant issuance at transition creation, serialize durable local epoch closure against every in-progress final acceptance, then require every pre-fence grant to prove never-accepted status, durable pre-acceptance rejection, or confirmed execution termination and allocation release across queued, retry, streaming, recovery, and delayed-delivery paths before a fresh generation-bound zero-active-allocation acknowledgement advances through the existing `draining -> maintenance` edge.
5. After maintenance is committed, issue activation authorization bound to Node ID, operation ID, transition generation, final mounted app, Candidate Manifest, mandatory DMG, imported generation, stable bootstrap, target profile, and transition direction.
6. Acquire the stable host operation lock and verify the same Controller generation and authorization.
7. Durably record the activation journal and establish general launch suppression.
8. Close the outgoing Worker Provider spawn gate and bind that evidence to the Controller execution-authority fence to establish the no-new-execution point.
9. Close every outgoing Worker Runtime channel, stop every registered Worker Provider, then stop the exact Node Agent root only through label-bound launchd job-domain disablement and bootout authority for the profile-fixed label so its registered ERTS support processes exit through parent-pipe closure; remove the outgoing generation-scoped sockets and prove exact exit, no registered survivor, no stale usable channel, and no replacement launchd root. Treat unavailable exact launchd authority, a registered ERTS survivor, or missing live `EVFILT_PROC` registration as uncertainty, preserve suppression, and block pointer activation without a bare-PID signal.
10. Atomically replace the active-generation pointer with the already imported candidate and verify the observed pointer and generation bytes.
11. Record `candidate_active_stopped` while general suppression remains active.
12. Mint one generation-bound one-shot and start the candidate provisionally through the stable bootstrap with a new execution epoch and new local channel identities.
13. Collect exact provisional evidence without starting Worker Provider execution or normal serving.
14. Ask the Controller to verify evidence for the current transition generation and issue one host-arm token while the Node remains unschedulable.
15. Consume the token to record idempotent `host_armed_pending_controller_commit` evidence for the exact provisional child, without clearing suppression or provisional restrictions.
16. Commit `controller_committed_pending_child_observation` with exact host-arm evidence while retaining maintenance and scheduler exclusion.
17. Let the exact child consume the authenticated pending result and become exact-child enabled while ordinary dispatch remains fenced.
18. Open the incoming Worker spawn gate only for the exact child, generation, transition, and execution epoch; reserve, spawn blocked, bind, and release the exact Worker; establish its authenticated local channel; and acknowledge exact Worker identity, protocol compatibility, and a representative supported-model readiness or inference probe.
19. Re-challenge the same live Node Agent and registered Worker and only then commit terminal success, advance `maintenance -> active`, clear scheduler exclusion, establish the accepted generation's new serving epoch, and reopen its Controller grant set in a second generation-checked transaction; keep grant issuance blocked until helper reconciliation and matching Node Agent epoch-readiness.
20. Require the helper to observe exact terminal `succeeded` and durably and idempotently replace transitional general suppression with the exact active-generation launch policy; until installation succeeds keep suppression fail closed, and let stable-bootstrap recovery retry the exact bound installation.

There is a proved stopped interval between outgoing registered-process exit and candidate provisional start.
No zero-downtime claim is made.

## Exact-Baseline Rollback Protocol

Rollback remains within the same Controller transition generation and names only its recorded source baseline.
It can begin from a stopped candidate, failed provisional candidate, or a candidate whose terminal acceptance did not complete.

1. Keep or reestablish general launch suppression and Controller scheduler exclusion.
2. Fence and stop the candidate registered-process set through the same registered-process protocol.
3. Verify the exact immutable source baseline, stable bootstrap, frozen identity set, and rollback authorization.
4. Atomically replace the active pointer with the exact baseline and verify it.
5. Record `baseline_restored_stopped`.
6. Start the baseline through a new operation-bound one-shot under general suppression.
7. Run the same provisional evidence, Controller host-arm token, idempotent arm evidence, pending-commit delivery, exact-child enablement, incoming Worker gate, reserve-before-spawn registration, authenticated Worker channel, representative supported-model readiness, fresh Node Agent and Worker challenge, and second terminal generation-checked sequence.
8. Record terminal `rolled_back` only when exact baseline arm evidence and fresh enabled Node Agent and Worker evidence commit, the Node advances to active, and the same transaction establishes the baseline's new serving epoch and reopens its Controller grant set; keep grant issuance blocked until helper reconciliation and matching Node Agent epoch-readiness, then require the helper to durably and idempotently replace transitional suppression with the exact baseline active-generation launch policy bound to that accepted terminal result. Stable-bootstrap recovery retries only that exact installation while host suppression remains active.

Rollback never reconstructs bytes from a backup copy, selects a different source ref, restores prior loaded-service state, or falls through to generic resume.
If any rollback evidence is uncertain, the baseline remains stopped and the Node remains excluded.

## Journal and Recovery

The stable bootstrap owns a versioned managed-transition journal separate from the current app transaction schema.
It records immutable operation identity, Controller transition generation, baseline and candidate generation identities, old and new pointer observations, suppression generation, Worker Provider spawn-gate state, spawn reservations and their `reserved`, `spawned_blocked`, `bound`, `released`, or `reconciled` states, registered process identities, execution and fence epochs, consumed-or-rejected execution-grant IDs, channel-capability identities, Worker Runtime channel closure, generation-scoped socket removal, durably consumed privileged-command IDs and nonces with command kind, canonical-argument digest, and result identity, one-shot claims, provisional process identity, Controller token identity, host-arm evidence, pending-result consumption, exact-child enabled acknowledgement, Worker readiness evidence, active-generation launch policy, and monotonic phase.

Every external mutation is preceded or followed by the durable record required to make recovery unambiguous under the documented state transition.
Journal replacement is atomic and durable before an operation reports progress.

Recovery re-reads Postgres transition state through the authenticated Controller interface and re-verifies local pointer, generations, bootstrap, identity set, suppression, spawn-gate state, registered-process exit, Worker Runtime channel and socket state, and journal.
It does not infer completion from intended state.
Unknown schema, missing evidence, contradictory pointer state, unexpected process, unreachable Controller, or mismatched generation yields uncertainty and preserves suppression.

The experimental profile has a durable managed-profile admission marker outside every generation and transition journal.
For the entire admitted profile lifetime, the current schema-v1 app lifecycle transaction and generic app install, update, uninstall, start, stop, rollback, and recovery paths must reject or delegate the operation to the managed bootstrap, even when no transition generation is active.
They cannot recover or auto-restart a managed transition.
A stable-bootstrap upgrade or profile decommission is a separate accepted lifecycle operation.
Production admission remains prohibited until operator-visible managed status and repair surfaces, safe decommission, and a next-update strategy are accepted with the clean-host provisioning and release-governance prerequisites.

## Failure Semantics

Before Controller transition creation, failure changes no schedulability or host state.
After transition creation, every state other than `succeeded` or fully accepted `rolled_back` remains scheduler-excluded and nonterminal.
After suppression, every uncertain local state remains launch-suppressed.
After pointer activation, missing terminal acceptance does not permit normal serving.
After rollback pointer restoration, missing exact-baseline acceptance does not permit normal serving.

No timeout, process owner death, Controller restart, leadership change, host reboot, heartbeat, generic lifecycle command, or launchd retry can convert uncertainty into eligibility.
Failure and uncertainty are blocking recoverable phases within the same transition generation, not terminal escape hatches.
In particular, recovery from `host_armed_pending_controller_commit` or `controller_committed_pending_child_observation` must revalidate the same live child and evidence or reestablish suppression after child exit or reboot.
An authorized repair procedure may inspect and reconcile evidence but cannot bypass the same exact-generation terminal protocol.

## Orchard.app and DMG Derivation

The admitted Node subtree is embedded in a declared immutable-generation seed area inside the final app delivered by the mandatory DMG.
The installed stable signed lifecycle bootstrap is a separate app-owned helper outside that subtree.
The app may still contain Controller, CLI, Console, or all-in-one content for other distribution roles, but the managed transition profile rejects a host where a Controller role is selected or running.

The final app verifier checks every embedded generation byte, composition identity, stable-bootstrap identity, code signature, entitlement, and app tree.
The candidate's embedded bootstrap identity must exactly equal the already installed stable bootstrap identity because this operation cannot update it.
The Candidate Manifest binds those identities after final verification.
The installed bootstrap imports only the admitted Node subtree from the verified mounted app into a new immutable generation.
It does not replace the installed app or invoke a generic app update path.
The mounted app and final DMG evidence must match the same Candidate Manifest before activation authorization can be issued.

A component archive, generation directory, composition lock, assembly decision, or build attestation is evidence or an assembly input only.
It is not independently installable or supported.

## Acceptance and Proof Strategy

Contract tests cover every purpose-bound verifier decision and reject cross-purpose replay.
Public-interface lifecycle tests drive Controller transition creation, closed execution-grant accounting, drain acknowledgement, host activation, provisional start, Controller host arm, Worker registration and channel authentication, fresh Node Agent and Worker terminal verification, terminal success, and exact-baseline rollback without direct private-state mutation.
Fault injection interrupts every database and journal boundary and proves that neither leader change nor host recovery reactivates the Node.

Process tests create real launchd-rooted Node Agents, their exact registered ERTS support-process set, and registered single-process Worker Providers.
They exercise attempted fork, subprocess launch, daemonization, unregistered execution, reserve-before-spawn crash boundaries, rapid spawn requests, PID reuse pressure, delayed exit, channel impersonation and replay, denied protected-resource access from remnants, Worker readiness loss, and replacement launch.
The tests qualify the exact supported model and feature matrix, Controller execution-authority fence, atomic Worker Provider spawn-gate close, no-new-execution point, exact registered-process exit, stale-authority denial, unrelated-process survival, and durable suppression across reboot.
Qualification combines closed executable-launch auditing with runtime process-creation observation and is invalidated whenever the bound provider, interpreter, dependency closure, model family, tokenizer path, execution mode, or relevant runtime configuration changes.

Real Apple Silicon qualification includes:

- the one forward transition;
- candidate verification rejection at every artifact stage;
- Worker Provider fork, subprocess, daemonization, and unregistered-execution attempts;
- helper authorization and nonce replay rejection;
- helper or host interruption at every reserve-before-spawn phase;
- spawn-gate races, PID reuse pressure, delayed exit, stale Worker Runtime channel impersonation, and request replay;
- protected-resource access denial from a surviving remnant;
- execution-grant queue, retry, stream, recovery, and delayed-delivery races;
- incoming Worker gate, authenticated-channel, supported-model readiness, and active-generation launch-policy transitions;
- lifecycle-owner death before and after pointer switch and host arm;
- host reboot at every recoverable journal class;
- Controller process restart and leadership change at every Controller phase;
- stale heartbeat, generic resume, and generic uncordon attempts;
- candidate provisional failure;
- exact-baseline rollback success and rollback uncertainty;
- lost pending response, provisional-child exit, and host reboot in `host_armed_pending_controller_commit` or `controller_committed_pending_child_observation`;
- wrong bootstrap, identity schema, executable, provider, app, Candidate Manifest, and mandatory DMG evidence; and
- proof that no Controller role runs on the target host.

Support remains unclaimed until this matrix, the applicable repo quality workflows, independent architecture, security, packaging, and migration review, clean-host provisioning, operator-visible status and repair, safe decommission, and an accepted next-update strategy all pass.

## Risks and Tradeoffs

The dedicated-host restriction limits immediate applicability but removes Controller self-replacement and local authority cycles.
The one-way transition is not a complete update system and therefore remains experimental until the entry, decommission, status, repair, and next-update prerequisites are accepted.
The stable bootstrap introduces a separately versioned prerequisite, but recovery authority cannot safely depend on the generation it replaces.
The single-process Worker Provider constraint narrows future provider freedom, but it gives the stable helper an exact direct-process set and avoids relying on an unavailable macOS cgroup equivalent.
Controller and BEAM authority fencing supplies the correctness boundary, while exact process exit protects host resources and the stopped interval.
The host-arm, pending commit, exact-child enablement, Worker readiness, and fresh Node Agent and Worker terminal protocol adds latency and state, but avoids scheduling before the admitted inference path is capable of serving and avoids an enabled-child crash window.
The frozen identity schema defers migrations, but preserves exact rollback semantics.

## Deferred Implementation Choices

The exact filesystem paths, serialized schemas, helper transport, process-spawn API, timeout values, Controller table names, API paths, and cryptographic key identifiers remain implementation choices.
Each choice must preserve the explicit boundaries and linearization points in this design.
If the admitted Worker Provider or any closed dependency cannot satisfy and pass qualification for the single-process contract, the implementation is blocked and the profile remains unsupported rather than falling back to process-tree scans or POSIX process groups as proof.
