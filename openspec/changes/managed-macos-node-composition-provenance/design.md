## Context

Orchard already has three relevant but separate foundations.
The macOS native distribution profile builds and verifies a signed `Orchard.app` in a DMG.
The app lifecycle serializes root-authorized host mutations and can recover a failed transaction, but it replaces managed paths in place and may restore previously loaded services automatically.
The source-development Node Agent stop path captures an exact root process and rejects replacement, but it does not durably suppress launch or prove that every Worker Provider descendant is gone.

The first managed-composition design tried to solve source and prebuilt transitions in both directions, legacy adoption, builder enrollment, retained-schema ranges, and broad app-role compatibility at once.
Review converged on a smaller safe boundary.
V1 is one transition on a dedicated Node-only host from an already managed verifier-built source baseline to one Orchard-signed prebuilt generation, with rollback only to that exact baseline.

The normative hierarchy remains `SPEC.md`, accepted decisions, accepted OpenSpec specifications, tests, and implementation.
This package must be accepted with a corresponding `SPEC.md` amendment before behavior implementation can be conformant.

## Goals

- Define one closed managed Node composition for a dedicated Apple Silicon macOS Node host.
- Prove one source-baseline-to-signed-prebuilt transition with no outgoing process or descendant overlap.
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
The composition lock never references the later governed build manifest.

`deprecate-node-runtime-grpc-compatibility` owns staged Runtime Endpoint compatibility epochs and removal gates.
This change records and verifies the required epoch and compatibility assets for the baseline and candidate.
It removes or defaults off no compatibility transport.

`add-portable-validation-fanout` owns the general validation-lane fanout.
This change supplies the profile-specific public-seam and real-hardware cases for the macOS lane.

## V1 Entry State

The host is a dedicated supported Apple Silicon macOS Node with no Controller release, Controller launchd job, or all-in-one role selected.
The stable signed lifecycle bootstrap and its compatible privileged helper are already installed through an approved app lifecycle.
The active-generation pointer selects one immutable verifier-built `exact_ref_source_build` baseline.
The durable managed-profile admission marker, baseline, pointer, bootstrap, launch policy, retained Node Identity Stores, and Controller Node identity have already passed the managed-profile admission checks.

V1 defines no conversion from an existing generic app installation, a foreground source checkout, a native PKG receipt, an arbitrary active tree, or another launch supervisor into this entry state.
Production entry into this state requires a separate accepted clean-host provisioning contract.
Until that prerequisite exists, this change can define and review the transition but cannot qualify or claim production support.

## Closed Composition

The composition contains exactly these component roles:

| Component role | Required content | Bound identity |
|---|---|---|
| `node_agent` | macOS arm64 Node Agent component built from the provider-neutral Node Agent core | signed tree digest, build identity, Runtime Endpoint compatibility |
| `launchd_host_adapter` | generation-side launch contract consumed by the stable lifecycle bootstrap | signed tree digest, bootstrap protocol version, fixed launch identity |
| `mlx_worker_provider` | exact-pinned MLX Worker Provider, dedicated interpreter, tokenizer, and closed runtime dependencies | signed tree digest, provider version, Worker Runtime protocol identity |

The stable lifecycle executable, launch gate, recovery logic, and privileged helper are profile prerequisites outside the replaceable composition.
The composition records their required exact identity and protocol version but cannot replace them.

Every executable and interpreter path is internal to either the stable bootstrap or immutable generation and is named by the signed contract.
The launchd label and active-pointer location are fixed by the profile.
Environment variables, command arguments, mutable configuration, symlinks, retained identity, and operator data cannot select another Node Agent, bootstrap, interpreter, or Worker Provider.

Models and operator data remain outside the composition under their existing storage contracts.
They cannot contain an executable override used by the managed process tree.

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

The composition lock contains no self-digest, app-tree digest, governed-build-manifest digest, DMG digest, publication state, or later signature.
The governed build manifest excludes itself and receives its digest only after canonical serialization, as required by release governance.
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
Purpose `accept_enabled_child` verifies pending-result consumption, exact-child enabled acknowledgement, and a fresh challenge of the same live child before active eligibility.

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
- exact source baseline, candidate composition, final app, bootstrap, and governed-build identities;
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
Transition creation is also the allocation fence.
Every allocation claim and final Worker Runtime execution acceptance must atomically verify the observed absence of this transition generation and scheduler exclusion in the same serialization boundary as its authority grant.
No post-fence allocation or execution acceptance may commit.
Verified inert candidate import may occur before transition creation, but no active pointer, launch suppression, running process, launch policy, or other managed launch state may change until existing request and allocation authority proves every pre-fence accepted allocation and execution is complete, records a fresh generation-bound zero-active-allocation acknowledgement, and advances the Node through the existing `draining -> maintenance` edge.

Every later Controller mutation uses compare-and-swap on the exact current transition generation and allowed prior phase.
A stale leader, duplicate request, replayed host result, prior-generation heartbeat, or concurrent operator action cannot advance or terminate the operation.
On leadership change, the new leader loads nonterminal transition generations before scheduler or lifecycle reconciliation and preserves their exclusions.

Generic `resume`, generic `uncordon`, normal heartbeat health, admission reconciliation, and scheduler health projection cannot make the Node active or route work to it while a nonterminal generation or a blocking recoverable phase exists.
Static, single-node, and compatibility fallbacks must reject any target that matches or may alias a managed Node with such a generation.
The accepted explicitly unmanaged compatibility path remains permitted only when the Controller positively proves that the target is associated with no managed Node or transition.
Only the managed transition terminal protocol may clear the exclusion.

## Process Fence and No-New-Child Point

The stable privileged helper is the sole authority for operation locking, durable general launch suppression, one-shot authorization, process discovery, suspension, exact identity capture, stop, exit proof, and replacement detection.
Swift, Elixir, scripts, and tests call that protocol and do not copy the safety algorithm.

Before the source baseline first starts, the stable bootstrap places its Node Agent and every descendant into one kernel-backed Managed Process Containment whose membership survives reparenting and cannot be escaped by generation code.
The same stable bootstrap creates the candidate containment before provisional start.
The selected public supported macOS primitive must enumerate exact membership, atomically close membership against new descendants, and terminate or freeze the complete membership.
Process-table scans may detect violations and supply evidence but cannot create the no-new-child proof.

After durable launch suppression, the helper validates the exact launchd root and asks the kernel-backed containment to close membership against new descendants.
The successful containment close is the no-new-child linearization point.
The helper then captures every exact member identity, terminates the complete closed membership, proves every member exited, and proves no replacement launchd root exists before pointer activation.

Any process observed running an outgoing-generation executable outside its required containment is an immediate uncertainty and support-boundary violation.
Containment escape, PID reuse, executable mismatch, membership ambiguity, failed close, surviving membership, unexpected external generation process, or incomplete authoritative observation is uncertainty.
Unrelated processes outside the closed generation and launch domain remain untouched.
If supported public macOS APIs cannot implement and prove this containment contract, managed activation remains blocked and the profile remains unsupported.

## Durable Suppression and One-Shot Provisional Start

General launch suppression combines persistent launchd job-domain disablement with a stable launch-gate decision below `RunAtLoad` and `KeepAlive`.
It is established before process capture and survives initiating-process death and host reboot.

The only permitted start under suppression uses an atomic one-shot authorization bound to Node ID, transition generation, operation ID, generation ID, exact executable, bootstrap identity, launch label, nonce, and expiry policy.
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
The exact child consumes the authenticated result, changes from provisional to exact-child enabled, and acknowledges that state while ordinary dispatch remains fenced.
The Controller then freshly challenges that same live enabled child.
Only a second generation-checked transaction may advance the Node to active and clear exclusion.
If the first response is lost, the child remains provisional and resubmits the same arm evidence.
If the child exits or the host reboots before the second transaction, the arm and pending Controller commit are invalidated, suppression remains active, and recovery must restart or roll back within the same transition generation.

## Forward Activation Protocol

1. Verify and mount the mandatory DMG, verify the final candidate app and Candidate Manifest, import only its admitted Node subtree into a new immutable candidate generation through the installed stable bootstrap, and verify the already managed source baseline, frozen Node Identity Set, and exact rollback target without host activation mutation.
2. Perform only non-authorizing static compatibility checks before Controller transition creation.
3. Create the durable Controller transition generation and atomically create scheduler exclusion, enter `draining`, and record audit evidence.
4. Drain active allocations and require a fresh generation-bound Controller acknowledgement of zero active allocations to advance through the existing `draining -> maintenance` edge.
5. After maintenance is committed, issue activation authorization bound to Node ID, operation ID, transition generation, final mounted app, Candidate Manifest, mandatory DMG, imported generation, stable bootstrap, target profile, and transition direction.
6. Acquire the stable host operation lock and verify the same Controller generation and authorization.
7. Durably record the activation journal and establish general launch suppression.
8. Close the kernel-backed outgoing containment to establish the no-new-child point.
9. Stop every member of the closed containment and prove exact exit, no survivor, and no replacement launchd root.
10. Atomically replace the active-generation pointer with the already imported candidate and verify the observed pointer and generation bytes.
11. Record `candidate_active_stopped` while general suppression remains active.
12. Mint one generation-bound one-shot and start the candidate provisionally through the stable bootstrap in a new containment.
13. Collect exact provisional evidence without starting Worker Provider execution or normal serving.
14. Ask the Controller to verify evidence for the current transition generation and issue one host-arm token while the Node remains unschedulable.
15. Consume the token to record idempotent `host_armed_pending_controller_commit` evidence for the exact provisional child, without clearing suppression or provisional restrictions.
16. Commit `controller_committed_pending_child_observation` with exact host-arm evidence while retaining maintenance and scheduler exclusion.
17. Let the exact child consume the authenticated pending result, become exact-child enabled, and acknowledge that state while ordinary dispatch remains fenced.
18. Re-challenge the same live enabled child and only then commit terminal success, advance `maintenance -> active`, and clear scheduler exclusion in a second generation-checked transaction.

There is a proved stopped interval between outgoing closure exit and candidate provisional start.
No zero-downtime claim is made.

## Exact-Baseline Rollback Protocol

Rollback remains within the same Controller transition generation and names only its recorded source baseline.
It can begin from a stopped candidate, failed provisional candidate, or a candidate whose terminal acceptance did not complete.

1. Keep or reestablish general launch suppression and Controller scheduler exclusion.
2. Fence and stop any candidate provisional closure through the same descendant protocol.
3. Verify the exact immutable source baseline, stable bootstrap, frozen identity set, and rollback authorization.
4. Atomically replace the active pointer with the exact baseline and verify it.
5. Record `baseline_restored_stopped`.
6. Start the baseline through a new operation-bound one-shot under general suppression.
7. Run the same provisional evidence, Controller host-arm token, idempotent arm evidence, pending-commit delivery, exact-child-enabled acknowledgement, fresh live-child challenge, and second terminal generation-checked sequence.
8. Record terminal `rolled_back` only when exact baseline arm evidence and fresh enabled-child evidence commit and the Node advances to active.

Rollback never reconstructs bytes from a backup copy, selects a different source ref, restores prior loaded-service state, or falls through to generic resume.
If any rollback evidence is uncertain, the baseline remains stopped and the Node remains excluded.

## Journal and Recovery

The stable bootstrap owns a versioned managed-transition journal separate from the current app transaction schema.
It records immutable operation identity, Controller transition generation, baseline and candidate generation identities, old and new pointer observations, suppression generation, containment-close evidence, one-shot claims, provisional process identity, Controller token identity, host-arm evidence, pending-result consumption, exact-child enabled acknowledgement, and monotonic phase.

Every external mutation is preceded or followed by the durable record required to make recovery unambiguous under the documented state transition.
Journal replacement is atomic and durable before an operation reports progress.

Recovery re-reads Postgres transition state through the authenticated Controller interface and re-verifies local pointer, generations, bootstrap, identity set, suppression, process closure, and journal.
It does not infer completion from intended state.
Unknown schema, missing evidence, contradictory pointer state, unexpected process, unreachable Controller, or mismatched generation yields uncertainty and preserves suppression.

The dedicated profile has a durable managed-profile admission marker outside every generation and transition journal.
For the entire admitted profile lifetime, the current schema-v1 app lifecycle transaction and generic app install, update, uninstall, start, stop, rollback, and recovery paths must reject or delegate the operation to the managed bootstrap, even when no transition generation is active.
They cannot recover or auto-restart a managed transition.
A stable-bootstrap upgrade or profile decommission is a separate accepted lifecycle operation.

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
Public-interface lifecycle tests drive Controller transition creation, drain acknowledgement, host activation, provisional start, Controller host arm, fresh-child terminal verification, terminal success, and exact-baseline rollback without direct private-state mutation.
Fault injection interrupts every database and journal boundary and proves that neither leader change nor host recovery reactivates the Node.

Process tests create real launchd-rooted Node Agent and Worker Provider trees inside the selected kernel-backed containment, including nested children, rapid child creation, reparenting attempts, PID reuse pressure, delayed exit, containment escape attempts, and replacement launch.
The tests prove the authoritative containment close, no-new-child point, exact membership exit, unrelated-process survival, and durable suppression across reboot.

Real Apple Silicon qualification includes:

- the one forward transition;
- candidate verification rejection at every artifact stage;
- descendant races and reparenting attempts;
- lifecycle-owner death before and after pointer switch and host arm;
- host reboot at every recoverable journal class;
- Controller process restart and leadership change at every Controller phase;
- stale heartbeat, generic resume, and generic uncordon attempts;
- candidate provisional failure;
- exact-baseline rollback success and rollback uncertainty;
- lost pending response, provisional-child exit, and host reboot in `host_armed_pending_controller_commit` or `controller_committed_pending_child_observation`;
- wrong bootstrap, identity schema, executable, provider, app, Candidate Manifest, and mandatory DMG evidence; and
- proof that no Controller role runs on the target host.

Support remains unclaimed until this matrix, the applicable repo quality workflows, and independent architecture, security, packaging, and migration review all pass.

## Risks and Tradeoffs

The dedicated-host restriction limits immediate applicability but removes Controller self-replacement and local authority cycles.
The one-way transition is not a complete update system but provides a tractable first safety proof.
The stable bootstrap introduces a separately versioned prerequisite, but recovery authority cannot safely depend on the generation it replaces.
Kernel-backed containment and authoritative membership closure are more demanding than root-process checks, but the Worker Provider makes scan-only proof insufficient.
The host-arm, pending commit, exact-child acknowledgement, and fresh-live-child terminal protocol adds latency and state, but avoids scheduling before a child is capable of serving and avoids an enabled-child crash window.
The frozen identity schema defers migrations, but preserves exact rollback semantics.

## Deferred Implementation Choices

The exact filesystem paths, serialized schemas, helper transport, supported public kernel-backed containment primitive, timeout values, Controller table names, API paths, and cryptographic key identifiers remain implementation choices.
Each choice must preserve the explicit boundaries and linearization points in this design.
If macOS cannot provide authoritative full descendant closure and no-new-child proof for the declared process model, the implementation is blocked and the profile remains unsupported rather than weakening the requirement.
