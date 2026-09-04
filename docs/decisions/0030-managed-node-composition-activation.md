# ADR: Activate one signed Node generation from one managed source baseline

## Status

Proposed under the `managed-macos-node-composition-provenance` OpenSpec change.

## Context

The supported macOS native distribution profile currently uses a signed `Orchard.app` inside a DMG and deliberately has no managed source-to-package handover contract.
ADR 0027 removed native PKG and its incomplete handover machinery because it could not prove one verified custody chain or zero process overlap.
The current app lifecycle replaces app-owned paths in place, records a schema-v1 transaction, and may restore previously loaded services automatically during rollback and recovery.
The source-development Node Agent stop path proves exact root-process custody for one foreground development lifecycle but does not close every descendant or durably fence launch.

The earlier form of this proposal attempted bidirectional realization changes, legacy adoption, a pretrusted local builder option, schema-range migration, and broad compatibility with Controller-bearing app roles.
Those features create independent safety problems and are not required to prove the first useful managed transition.

## Decision

Introduce one `managed_apple_silicon_macos_node` distribution profile for a dedicated Apple Silicon macOS host that runs the Node Agent role and no Controller role.
All-in-one and Controller-bearing hosts are excluded.

The only v1 transition starts from an already managed `exact_ref_source_build` baseline and activates one `orchard_signed_prebuilt` candidate.
The baseline must have been constructed from the canonical Orchard repository at an authorized exact full commit inside a verifier-controlled isolated build environment with pinned toolchains, dependency locks, controlled inputs, and the exact target.
V1 does not trust a local builder, adopt a legacy installation, transition from prebuilt back to source provenance as a normal operation, or perform a subsequent prebuilt-to-prebuilt upgrade.

Both baseline and candidate use the same closed component contract: one macOS arm64 Node Agent component built from the provider-neutral Node Agent core, one launchd host adapter, and one exact-pinned MLX Worker Provider.
No environment variable, configuration file, command-line option, symlink, or retained-state entry may override the admitted Node Agent executable, lifecycle bootstrap, Worker Provider executable, or provider package set.

Each verified composition is installed into a new immutable generation directory.
One active-generation pointer is the sole selector consumed by the stable bootstrap.
Activation atomically replaces that pointer after the outgoing process fence and before any new process can start.
Existing generations are never mutated in place.

One stable signed lifecycle, launch-gate, and recovery bootstrap lives outside the replaceable generation set.
The v1 transition cannot replace or update that bootstrap.
An incompatible or missing bootstrap blocks activation before host mutation.

One privileged helper protocol owns durable launch suppression and process custody for the dedicated Node launch domain.
Before either generation starts, the stable bootstrap places its Node Agent and all descendants into a supported public macOS kernel-backed Managed Process Containment whose membership survives reparenting and cannot be escaped by generation code.
The helper establishes the no-new-child point by atomically closing that containment against new membership, then terminates and proves exit for its complete authoritative membership before pointer activation.
Process-table scans may detect violations but cannot supply the closure proof.
Containment escape, ambiguous membership, identity reuse, a surviving member, a replacement launch, or a generation process outside its containment is uncertainty.
If supported public macOS APIs cannot prove this contract, the profile remains unsupported.

General launch suppression remains durable across lifecycle-owner exit and host reboot.
Starting the candidate creates one operation-bound, generation-bound, nonce-bound one-shot authorization.
The stable launch gate may atomically claim that authorization for exactly one expected executable and exact generation.
The child runs provisionally and cannot register normal cluster identity, publish capacity, execute workers, accept Runtime Endpoint work, or become scheduler eligible.

The retained Node Identity Set is the union of three explicit versioned stores outside every generation: the complete current Node Identity Store generation, the scoped BEAM Peer Grant Store, and the stable bootstrap release-trust store.
The Node Identity Store includes its current-generation pointer, metadata, private key, CSR, Node Certificate, Controller Certificate, runtime CA certificate, enrollment and cluster identifiers, URI SAN bindings, certificate identifiers and fingerprints, runtime trust SPKI digest, public-key and CSR fingerprints, state, and generation identity.
The Controller transition binds the exact current store generations and digests.
V1 freezes their schemas, paths, Node ID, Node private-key identity, and trust anchors while the transition is nonterminal.
Renewable Node certificate bytes and scoped BEAM Peer Grants may rotate only through their existing separately authorized protocols in a generation-checked, scheduler-excluded recovery phase.
The Controller must then rebind the new store generation and reauthorize both exact baseline and candidate before recovery continues.

The Controller owns a durable Postgres transition generation that binds Node ID, operation ID, outgoing baseline composition, incoming composition, expected app and governed-build identities, and monotonic phase.
Creation is allowed only from `active` or `cordoned` and atomically creates the transition generation, scheduler exclusion, `draining` lifecycle state, and audit evidence.
Verified inert candidate import may occur before transition creation, but no active pointer, launch suppression, running process, launch policy, or other managed launch state may change until a fresh generation-bound zero-active-allocation acknowledgement advances the Node through the existing `draining -> maintenance` edge.
Transition creation is the allocation fence.
Every allocation claim and final Worker Runtime execution acceptance must atomically verify the observed absence of the transition generation and exclusion in the same serialization boundary as its authority grant.
The zero acknowledgement covers every pre-fence accepted execution, and no post-fence acceptance may commit.
Generic resume, generic uncordon, ordinary heartbeat health, stale leaders, new leaders, static compatibility fallback, and single-node fallback cannot clear that exclusion or make the Node active.
An explicitly unmanaged compatibility target remains permitted only when the Controller positively proves it is associated with no managed Node or transition.

Terminal acceptance uses a crash-closed host-arm protocol.
The provisional child reports exact composition, app, Candidate Manifest, DMG, Node identity, process, bootstrap, Runtime Endpoint, Worker Runtime, and health evidence for its Node ID, operation ID, and active Controller transition generation.
The Controller returns one generation-bound host-arm token while the Node remains unschedulable.
The host consumes it to persist idempotent `host_armed_pending_controller_commit` evidence for that exact child without clearing suppression or provisional restrictions.
The Controller then commits `controller_committed_pending_child_observation` while retaining maintenance and scheduler exclusion.
The exact child consumes that authenticated result, enters exact-child enabled state, and acknowledges it while ordinary dispatch remains fenced.
The Controller freshly challenges the same live enabled child and only then may a second generation-checked transaction record terminal success, advance `maintenance -> active`, and clear the exclusion.
If the pending response is lost the child remains provisional and resubmits the same evidence, while child exit or host reboot invalidates the arm and preserves suppression.

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
This ADR does not authorize clean-host provisioning or support claims until that prerequisite exists and passes qualification.

Foreground source development remains governed by `make dev` and existing source-development lifecycle commands.
It cannot be adopted as the managed baseline.

## Consequences

The first managed composition feature proves one useful production direction without claiming a general package manager, legacy migration, or repeated update system.
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
Root-process-only custody was rejected because the Node Agent supervises Worker Provider descendants that can outlive or race the root.
Clearing general suppression before health was rejected because `KeepAlive`, reboot, and owner death could create an unbound replacement process.
Generic maintenance and resume were rejected as the terminal protocol because stale leaders and ordinary health paths could make the Node schedulable without exact operation evidence.
Retained-schema ranges were rejected for v1 because any identity migration broadens rollback safety.
Native PKG handover remains rejected because native PKG is not a supported current distribution channel.
Zero-downtime activation remains outside scope because v1 requires a proved stopped interval.

## SPEC.md Impact

Acceptance requires a focused amendment to §§1.4, 2.5, 4.1 through 4.4, 4.9, 4.10, 5, 11.2 through 11.4, and 13.4.
That amendment narrowly supersedes ADR 0027's no-managed-handover conclusion only for the dedicated profile and the single source-baseline-to-signed-prebuilt transition.
All native PKG removal, Controller-bearing and all-in-one profile behavior, foreground source development, release and credential gates, and other provenance directions remain unchanged.
This ADR does not itself change `SPEC.md` or product behavior.
