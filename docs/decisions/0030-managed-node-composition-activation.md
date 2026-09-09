# ADR: Activate one signed Node generation from one managed source baseline

## Status

Proposed under the `managed-macos-node-composition-provenance` OpenSpec change.

## Context

The supported macOS native distribution profile currently uses a signed `Orchard.app` inside a DMG and deliberately has no managed source-to-package handover contract.
ADR 0027 removed native PKG and its incomplete handover machinery because it did not implement the proposed zero-process-overlap contract.
This v1 design deliberately narrows the guarantee to zero serving-authority overlap and zero registered-process overlap.
The current app lifecycle replaces app-owned paths in place, records a schema-v1 transaction, and may restore previously loaded services automatically during rollback and recovery.
The source-development Node Agent stop path proves exact root-process custody for one foreground development lifecycle but does not close every descendant or durably fence launch.

The earlier form of this proposal attempted bidirectional realization changes, legacy adoption, a pretrusted local builder option, schema-range migration, and broad compatibility with Controller-bearing app roles.
Those features create independent safety problems and are not required to prove the first useful managed transition.

## Decision

Reserve `managed_apple_silicon_macos_node` as an experimental distribution-profile identifier for the managed transition specialization on a dedicated Apple Silicon macOS host that runs the Node Agent role and no Controller role.
All-in-one and Controller-bearing hosts are excluded.

The only v1 transition starts from an already managed `exact_ref_source_build` baseline and activates one `orchard_signed_prebuilt` candidate.
The baseline must have been constructed from the canonical Orchard repository at an authorized exact full commit inside a verifier-controlled isolated build environment with pinned toolchains, dependency locks, controlled inputs, and the exact target.
V1 does not trust a local builder, adopt a legacy installation, transition from prebuilt back to source provenance as a normal operation, or perform a subsequent prebuilt-to-prebuilt upgrade.

Both baseline and candidate use the same closed component contract: one macOS arm64 Node Agent component built from the provider-neutral Node Agent core, one launchd host adapter, and one exact-pinned MLX Worker Provider.
No environment variable, configuration file, command-line option, symlink, or retained-state entry may override the admitted Node Agent executable, lifecycle bootstrap, Worker Provider executable, or provider package set.
The pinned OTP runtime's closed ERTS support-process set is part of the Node Agent component contract.
For OTP 29 this includes the exact `erl_child_setup` process created by ERTS; any profile `epmd` service is exact-pinned stable host infrastructure outside replaceable generations.
Neither may hold Node Certificates, BEAM Peer Grants, Worker channel capabilities, Controller request authority, or a Runtime Endpoint.

The v1 MLX Worker Provider is a single non-forking, non-daemonizing OS process that may use threads but may not create descendants or launch another executable.
The Node Agent may start it only through the stable helper using a reserve-before-spawn protocol.
The helper durably records an operation-bound spawn reservation and creates a unique inherited reservation lock plus initialization-and-liveness gate.
The child holds the reservation lock for its lifetime, fails-exit on gate EOF before creating the Worker, and terminates on gate EOF after initialization so helper death removes it.
It then creates the child with public POSIX `fork`, identity drop, and `execve`, binds and durably records its exact PID, process-start identity from `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID)`, executable identity from `proc_pidpath`, generation identity, execution epoch, and owning Node Agent, and fsyncs that identity before releasing initialization.
Before the Worker image begins execution, it closes every inherited descriptor except the operation-bound and generation-bound reservation-lock, initialization-and-liveness-gate, and channel-capability descriptors; every helper control or listener, credential, directory, scratch, socket, and unrelated descriptor is `FD_CLOEXEC` or explicitly closed.
Recovery closes the gate and acquires the reservation lock exclusively to prove that a pre-registration child exited even when no PID was committed.
After helper death in `bound`, `released`, serving, or terminal-pending state, liveness-gate EOF makes the Worker exit and release its lifetime lock; a restarted helper preserves suppression and reconciles the durable registry through exclusive lock acquisition and any still-live exit registration before restart or pointer action.
The Worker Provider remains a Node Agent-local leaf without Node Certificates, BEAM Peer Grants, BEAM membership, Controller reachability, a TCP listener, or an independently schedulable Runtime Endpoint.
It runs under a profile-fixed unprivileged Worker account name created and verified by the clean-host provisioning contract; the composition never binds a machine-specific numeric UID.
That account's host-enforced filesystem policy denies the Node Identity Set, release-trust store, active pointer, managed journals, helper control endpoint, other generations, and shared mutable serving state.
For code and system resources, it permits read and execute access only to the exact admitted current-generation Worker executable, interpreter, dependency closure, and closed system-library, framework, device, and IPC resources bound by the qualified matrix.
For non-code data and mutable resources, it permits read-only admitted model inputs, write access only to generation-scoped scratch, and the authenticated generation-scoped local channel to its supervising Node Agent.
The helper mints a fresh per-start channel capability, delivers the Worker copy only through an inherited descriptor and the Node Agent copy only through the authenticated helper protocol, never through argv, environment, logs, or shared files, and binds both peers and every request to the Node, operation, transition generation, execution epoch, registered process identity, and request identity with replay rejection.
The channel is one long-lived authenticated gRPC connection over a helper-reserved filesystem Unix-domain socket path inside generation-scoped scratch, not an inherited connected socket.
After the exact peers authenticate, the helper unlinks the path so no new connection can attach; connection loss makes the Worker unavailable and requires helper-mediated restart.
Any future provider that requires child processes needs a separately accepted containment contract or distribution profile.

Each verified composition is installed into a new immutable generation directory.
One active-generation pointer is the sole selector consumed by the stable bootstrap.
Activation atomically replaces that pointer after the outgoing process fence and before any new process can start.
Existing generations are never mutated in place.

One stable signed lifecycle, launch-gate, and recovery bootstrap lives outside the replaceable generation set.
The v1 transition cannot replace or update that bootstrap.
An incompatible or missing bootstrap blocks activation before host mutation.

One privileged helper protocol owns durable launch suppression, the Worker Provider spawn gate, and exact direct-process custody for the dedicated Node launch domain.
It authenticates the installed caller code identity and role and authorizes each command against the exact Node ID, operation ID, transition generation, monotonic phase, executable identity, generation identity, and fresh nonce.
Before the first side effect, it durably consumes an operation-bound command ID and nonce bound to command kind and canonical arguments and records the result identity.
A matching duplicate returns the recorded idempotent result; a mismatched duplicate or replay across helper restart fails without repeating mutation.
It rejects stale phases, cross-role use, and generic privileged spawn, signal, filesystem, pointer, or suppression mutation outside the versioned protocol.
The helper captures process-start identity with `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID)`, captures executable identity with `proc_pidpath`, and monitors exact exit with `waitpid` for its Worker child or a live `kevent` `EVFILT_PROC` registration plus post-exit identity recheck for registered non-children; process-table text is detection evidence only.
The Controller transition generation owns a two-stage cluster execution-authority fence: creation is the allocation-issuance fence, while helper-serialized durable local epoch closure is the final-acceptance fence for pre-fence grants.
After the zero-active-allocation acknowledgement, the helper atomically closes the local Worker Provider spawn gate while general launch suppression prevents a replacement Node Agent.
Together those events establish the no-new-execution point.
The helper first terminates and proves exact exit for the registered single-process Worker Providers, then terminates the Node Agent root only through label-bound launchd job-domain disablement and bootout authority for the profile-fixed label and proves exact exit through its live `EVFILT_PROC` registration and post-exit identity recheck.
It never issues a bare-PID signal to the Node Agent root; inability to exercise the exact launchd job authority is uncertainty that preserves suppression and blocks pointer activation.
Registered ERTS support processes must exit through closure of their parent-private ERTS control pipe; the helper proves their exit with a live `kevent` `EVFILT_PROC` registration plus post-exit identity recheck.
A registered ERTS survivor or missing live registration is uncertainty: the helper preserves suppression and blocks pointer activation instead of issuing a bare-PID signal that could hit a reused identity.
The Node Agent closes every Worker Runtime channel before its root exits, the helper removes the outgoing generation-scoped socket after the registered provider exits, and the next generation receives new channel identities.
Process-table and executable scans may detect contract violations but cannot substitute for helper-owned registration and exact direct-PID exit proof.
An observed unregistered Worker Provider, ERTS support process outside the exact admitted set, descendant process, daemonization attempt, identity reuse, surviving registered process, replacement launch, stale Worker Runtime channel, or generation process outside the admitted process contract is uncertainty.
The safety proof does not depend on claiming that macOS can discover every possible Worker descendant.
An unobserved Worker descendant under the dedicated Worker identity would be a provider defect and resource leak, but the dedicated Worker identity and authenticated channel prevent it from retaining cluster, host-mutation, identity, or serving authority after the Controller fence, zero-active acknowledgement, Node Agent channel closure, and Node Agent root exit.
Exact signed Node Agent and pinned OTP process-shape conformance is a trust assumption outside that remnant argument; any violation invalidates qualification and support for the profile.

An ordinary-serving managed process-shape, descriptor, filesystem, channel, or execution-identity violation closes local execution immediately, establishes general host suppression, and creates a durable Controller managed-profile fault exclusion bound to the exact active generation.
Health, capacity, portable Worker restart, ordinary reconciliation, generic resume, and generic uncordon cannot clear it.
If execution termination or allocation release is unresolved, the current Active Controller also retains the existing `SPEC.md` §4.6.2 quarantine.
Only authenticated audited generation-checked managed repair may clear local suppression and the managed-profile exclusion after re-proving the exact process set, descriptor and filesystem closure, channel identities, Worker readiness, and active-generation policy; it does not clear §4.6.2 quarantine unless independent execution-termination and allocation-release reconciliation also completes.
Controller unavailability keeps local execution closed.

General launch suppression remains durable across lifecycle-owner exit and host reboot.
The profile-fixed system-domain launchd label always names the stable bootstrap outside replaceable generations.
That bootstrap remains the launchd job root and `execve`s the exact authorized generation's Node Agent in place without a shell or forked launcher, preserving label-bound bootout authority over every Node Agent phase.
Fully suppressed state keeps both the label disabled and the stable gate denying starts.
For a one-shot start, the helper persists the exact unclaimed authorization while disabled, enables and bootstraps only that label through the public launchd service-management interface, lets the bootstrap atomically claim before `execve`, durably registers the exact job-root identity, and disables the label again while the provisional child continues under stable-gate suppression.
An invocation without the matching authorization exits without Node identity or generation execution; interrupted enable, bootstrap, claim, registration, or disable ordering reconciles to disabled state before recovery proceeds.
Only durable installation of the exact terminal active-generation policy leaves the label enabled for ordinary restart of that generation.
Starting the candidate creates one operation-bound, generation-bound, nonce-bound one-shot authorization.
The stable launch gate may atomically claim that authorization for exactly one expected executable and exact generation.
The child runs provisionally and cannot register normal cluster identity, publish capacity, execute workers, accept Runtime Endpoint work, or become scheduler eligible.

The retained Node Identity Set is the union of three explicit versioned stores outside every generation: the complete current Node Identity Store generation, the scoped BEAM Peer Grant Store, and the stable bootstrap release-trust store.
The Node Identity Store includes its current-generation pointer, metadata, private key, CSR, Node Certificate, Controller Certificate, runtime CA certificate, enrollment and cluster identifiers, URI SAN bindings, certificate identifiers and fingerprints, runtime trust SPKI digest, public-key and CSR fingerprints, state, and generation identity.
The Controller transition binds the exact current store generations and digests.
V1 freezes their schemas, paths, Node ID, Node private-key identity, and trust anchors while the transition is nonterminal.
Renewable Node certificate bytes and scoped BEAM Peer Grants may rotate only through their existing separately authorized protocols in a generation-checked, scheduler-excluded recovery phase.
The Controller must then rebind the new store generation and reauthorize both exact baseline and candidate before recovery continues.

The Controller owns a durable Postgres transition generation that binds Node ID, operation ID, outgoing baseline composition, incoming composition, expected app and Candidate Manifest identities, and monotonic phase.
Creation is allowed only from `active` or `cordoned` and atomically creates the transition generation, scheduler exclusion, `draining` lifecycle state, and audit evidence.
Verified inert candidate import may occur before transition creation, but no active pointer, launch suppression, running process, launch policy, or other managed launch state may change until a fresh generation-bound zero-active-allocation acknowledgement advances the Node through the existing `draining -> maintenance` edge.
Transition creation is the allocation-issuance fence.
For `managed_apple_silicon_macos_node` only, this is the proposed profile-scoped successor to `SPEC.md` §4.6.2's Controller-local F11 rule, limited to durable grant IDs and fence epochs and not a general crash-recoverable reservation ledger or other pre-M7 leadership fencing.
Every allocation claim and new execution-grant issuance receives a unique execution-grant ID and observed fence epoch and atomically verifies the absence of the transition generation and exclusion in the same Controller serialization boundary as its durable Postgres authority grant.
Final Worker Runtime acceptance of a pre-fence grant instead verifies the exact durable grant, Node, request, open fence epoch, and consumed-or-rejected state through the stable helper.
The helper serializes local epoch closure against every final acceptance from its authenticated grant decision through Worker Runtime acceptance or durable pre-acceptance failure.
Transition creation closes the execution-grant set to new grants.
Durable local epoch closure is the final-acceptance fence; afterward every not-yet-accepted, closed, mismatched, duplicate, replayed, interrupted, or unresolved grant remains incapable of acceptance across restart until exact reconciliation records its disposition.
A terminal disposition requires never-accepted status, durable pre-acceptance Worker rejection, or affirmatively confirmed execution termination and allocation release; cancellation timeout, transport ambiguity, unconfirmed release, unresolved occupancy, or quarantine blocks zero acknowledgement and host mutation.
The zero acknowledgement may commit only after local epoch closure is durable, every pre-fence grant has a qualifying terminal disposition, and the Node has acknowledged rejection across queued, retry, streaming, recovery, and delayed-delivery paths; no new grant after transition creation and no final acceptance begun after local closure may commit.
Generic resume, generic uncordon, ordinary heartbeat health, stale leaders, new leaders, static compatibility fallback, and single-node fallback cannot clear that exclusion or make the Node active.
An explicitly unmanaged compatibility target remains permitted only when the Controller positively proves it is associated with no managed Node or transition.

Terminal acceptance uses a crash-closed host-arm protocol.
The provisional child reports exact composition, app, Candidate Manifest, DMG, Node identity, process, bootstrap, Runtime Endpoint, Worker Runtime, and health evidence for its Node ID, operation ID, and active Controller transition generation.
The Controller returns one generation-bound host-arm token while the Node remains unschedulable.
The host consumes it to persist idempotent `host_armed_pending_controller_commit` evidence for that exact child without clearing suppression or provisional restrictions.
The Controller then commits `controller_committed_pending_child_observation` while retaining maintenance and scheduler exclusion.
The exact child consumes that authenticated result and enters exact-child enabled state while ordinary dispatch remains fenced.
Only in that state may the helper open the incoming Worker spawn gate for the exact child, generation, transition, and execution epoch; the Node Agent then starts and registers the single Worker and establishes its authenticated local channel.
The child acknowledges enabled state only with exact Worker identity, protocol compatibility, channel authentication, and a representative supported-model readiness or inference probe.
The Controller freshly challenges that same live Node Agent and registered Worker before a second generation-checked transaction may record terminal success, advance `maintenance -> active`, clear the exclusion, establish the accepted generation's new serving epoch, and reopen its Controller grant set.
Grant issuance remains blocked until the helper durably reconciles that exact epoch and the Node Agent publishes matching epoch-readiness; rollback, Controller or helper restart, and leadership change use the same reconciliation gate.
The helper must then durably and idempotently replace transitional general suppression with an exact active-generation launch policy bound to the terminal result, Node, generation, executable, and bootstrap; until it observes that result and installs the policy, suppression remains fail closed.
Controller-terminal-active with host suppression still installed is an explicit recoverable state, and stable-bootstrap recovery retries only the exact bound policy installation.
Child or Worker exit, Worker readiness loss, or reboot before terminal success closes the incoming gate, invalidates the arm, and preserves suppression and scheduler exclusion.

Rollback may select only the exact verified source baseline recorded when the transition generation was created.
Rollback atomically restores that baseline pointer and uses the same durable suppression and one-shot provisional-start protocol.
Rollback has its own terminal Controller evidence and never falls through to generic resume.
If the exact baseline, stable bootstrap, retained identity, process fence, or Controller generation cannot be verified, the Node remains stopped, launch-suppressed, and unschedulable.

Verification decisions are bound to purpose and stage.
Assembly admission and pre-transition static checks cannot authorize activation.
Production activation requires a mandatory DMG and Candidate Manifest and binds the Node ID, operation ID, transition generation, final mounted app identity, embedded Node subtree, imported immutable generation, composition lock, target profile, transition direction, installed stable-bootstrap identity, and exact DMG identity.

Nested generation code is signed before the closed Node-subtree and composition identities are sealed.
The app helpers, main executable, and outer app are signed and verified next.
DMG assembly, notarization, stapling, and mounted verification follow and are mandatory.
The Candidate Manifest is sealed only after every artifact required for that stage has final verified identity.
No later signing or packaging step may change an identity already authorized for activation.

Before the Controller transition is created, the installed stable bootstrap mounts and verifies the mandatory DMG and final app, requires the candidate's embedded bootstrap identity to equal the installed bootstrap, and imports only the admitted Node subtree into a new immutable generation.
The operation does not install or update the app through the generic schema-v1 lifecycle.
The dedicated profile carries a durable managed-profile admission marker outside every generation and journal.
For the profile's entire admitted lifetime, generic app install, update, uninstall, start, stop, rollback, and recovery must reject or delegate to the managed bootstrap.

Acceptance of `product-versioning-release-governance` is an explicit prerequisite because its Candidate Manifest contract is normative input here.
Production entry into the already managed source baseline is a separate accepted provisioning contract.
Production admission also requires accepted operator-visible managed status and repair surfaces, a safe managed decommission path, and an accepted next-update strategy.
Until all prerequisites exist and pass qualification, this ADR is an experimental transition design and does not create a supported distribution profile or authorize production admission.

Foreground source development remains governed by `make dev` and existing source-development lifecycle commands.
It cannot be adopted as the managed baseline.

## Consequences

The first managed composition design proves one bounded transition direction without claiming a current production feature, general package manager, legacy migration, or repeated update system.
The dedicated-host restriction avoids coordinating Controller self-replacement with the Controller database authority that fences the transition.
Immutable generations and one atomic pointer remove partial active-tree replacement from the safety model.
The stable bootstrap and already managed source baseline become prerequisites that must be provisioned and versioned independently before the first managed transition.
The stopped interval and provisional phase reduce availability but make the no-overlap and no-premature-scheduling claims reviewable.
Controller terminalization requires more durable state than ordinary maintenance, but prevents resume, heartbeat, static-fallback, leadership, and host-arm crash races from bypassing the operation.
Real Apple Silicon adversarial qualification is required before support can be claimed.

## Alternatives Rejected

Bidirectional provenance transition was deferred because the first slice needs only source-baseline to signed-prebuilt activation and exact-baseline rollback.
Legacy adoption was rejected because Orchard cannot derive a trustworthy immutable baseline and complete custody proof from arbitrary installed bytes.
A pretrusted local builder was rejected because it adds builder enrollment and attestation policy that the verifier-controlled isolated build does not need.
Replace-in-place activation was rejected because partial mutations and rollback copies create more states than one immutable pointer switch.
Replacing the lifecycle bootstrap with the candidate was rejected because recovery authority cannot safely replace itself during the operation it must recover.
Root-process-only custody was rejected because the Node Agent supervises a Worker Provider process that can outlive or race the root.
Arbitrary multi-process Worker Providers were rejected for v1 because macOS has no supported public cgroup-like primitive that can authoritatively close an escapable descendant set.
Treating process-tree scans or POSIX process groups as the safety proof was rejected because both are racy or escapable.
Clearing general suppression before health was rejected because `KeepAlive`, reboot, and owner death could create an unbound replacement process.
Generic maintenance and resume were rejected as the terminal protocol because stale leaders and ordinary health paths could make the Node schedulable without exact operation evidence.
Retained-schema ranges were rejected for v1 because any identity migration broadens rollback safety.
Native PKG handover remains rejected because native PKG is not a supported current distribution channel.
Zero-downtime activation remains outside scope because v1 requires a proved stopped interval.

## SPEC.md Impact

Acceptance requires a focused amendment to §§1.4, 2.5, 4.1 through 4.4, 4.6.2, 4.9, 4.10, 5, 7.5, 11.2 through 11.4, and 13.4.
For `managed_apple_silicon_macos_node` only, that amendment supersedes §4.6.2's Controller-local F11 prohibition and M7 deferral only to the extent required by the durable grant-ID and fence-epoch protocol, without authorizing a general crash-recoverable reservation ledger.
It also narrowly supersedes ADR 0027's no-managed-handover conclusion only for the dedicated profile and the single source-baseline-to-signed-prebuilt transition.
All native PKG removal, Controller-bearing and all-in-one profile behavior, foreground source development, release and credential gates, and other provenance directions remain unchanged.
This ADR does not itself change `SPEC.md` or product behavior.
