## Context

Orchard already has three relevant but separate foundations.
The macOS native distribution profile builds and verifies a signed `Orchard.app` in a DMG.
The app lifecycle serializes host mutations and can recover a failed transaction, but its current recovery model may restore previously loaded services automatically.
The source-development Node Agent stop path captures exact process identity and rejects a replacement process, but it is not a durable managed-distribution process fence.

The proposed slice joins those foundations without merging their scopes.
It creates one managed Node profile whose replaceable composition can be realized either from a controlled exact source ref or from Orchard-signed prebuilt bytes.
It does not turn ordinary source development into an installation path, revive native PKG, or give a component archive an independent support claim.

The normative hierarchy remains `SPEC.md`, accepted decisions, accepted OpenSpec specifications, tests, and implementation.
This package must be accepted with the corresponding `SPEC.md` amendment before behavior implementation can be considered conformant.

## Goals

- Define one closed composition identity for a managed Apple Silicon macOS Node.
- Admit exactly two provenance realizations while preserving their distinct trust roots.
- Make verification, Controller maintenance, process custody, activation, rollback, and retained identity one fail-closed protocol.
- Prove both provenance directions through public interfaces and real Apple Silicon migration evidence.
- Preserve the existing app and DMG as the supported distribution boundary.
- Preserve foreground source development unchanged.

## Non-Goals

- Amore upload, promotion, publication, or credential handling.
- GitHub Release publication or other release authority.
- Linux, WSL, Windows, Intel macOS, or another Node Distribution Profile.
- Relaxed Controller, Node Agent, Runtime Endpoint, or Worker Provider version skew.
- Zero-downtime or overlapping-process activation.
- Support for a standalone Node Agent Core archive, launchd host-adapter archive, Worker Provider archive, composition lock, or build attestation.
- Native PKG or any handover from removed native-PKG machinery.
- Fencing manually started or externally supervised processes outside the supported managed launch domain.
- Changing the default foreground behavior of `make dev`.

## Contract Reconciliation

### Existing Contract Preserved

The existing macOS native distribution profile remains the outer distribution contract.
`Orchard.app` remains the installed product boundary and the signed DMG remains the supported transport artifact.
The Node Agent Core remains provider-neutral.
The MLX Worker Provider remains an independently versioned provider behind the existing Worker Runtime Interface.
Controller maintenance remains the state that prevents new scheduling.
Native PKG remains unsupported and removed.

### Existing Contract Narrowly Superseded

`SPEC.md` §11.4 and ADR 0027 currently state that Orchard has no supported source-development to packaged-service handover or zero-overlap ownership transfer.
The accepted change would supersede only that absence for the named Managed Apple Silicon macOS Node Distribution Profile and only for `exact_ref_source_build` and `orchard_signed_prebuilt` compositions.
Ordinary source development, controller-only installs, all-in-one profiles, and every other platform or provenance route remain outside the exception.

### Active Change Coordination

`product-versioning-release-governance` owns Orchard product version, Candidate and Internal Build Manifests, state attestations, release state, and publication gates.
This change owns component manifests, composition locks, and detached composition build attestations.
The release manifest may reference a composition-lock digest, but the composition lock must not reference a later release manifest.

`deprecate-node-runtime-grpc-compatibility` owns staged Runtime Endpoint compatibility epochs and removal gates.
This change records the required epoch and assets for each composition and verifies them during transition.
It does not remove, default-off, or accelerate any compatibility transport.

`add-portable-validation-fanout` owns the general validation-lane fanout.
This change supplies the profile-specific public-seam and real-hardware cases that those lanes must execute when the corresponding implementation lands.

`operator-first-run-journey` owns operator-facing setup journeys and future upgrade guidance.
This change defines lifecycle authority and machine-readable states only.
It does not add a Console journey or UI implementation.

## Composition Model

### Managed Profile

The profile identifier is `managed_apple_silicon_macos_node`.
It is a Node-role specialization of the existing macOS native distribution profile and is compatible with the separate macOS MLX Node runtime profile.
Admission requires Apple Silicon macOS, the supported app and DMG lifecycle, the managed launch-domain adapter, and Controller reachability for maintenance coordination.

### Closed Components

The composition contains exactly these first-party component roles:

| Component role | Required content | Independent identity |
|---|---|---|
| `node_agent` | macOS arm64 Node Agent component built from the provider-neutral Node Agent core | tree digest, build identity, protocol compatibility |
| `launchd_host_adapter` | launchd definitions plus the privileged lifecycle and process-fence helper | tree digest, helper protocol version, managed launch-domain identity |
| `mlx_worker_provider` | exact-pinned MLX Worker Provider and its closed runtime dependencies | tree digest, provider version, Worker Runtime protocol identity |

No undeclared executable, dynamic library, Python package, model, launchd definition, helper, or mutable configuration default may be imported into the replaceable composition at activation time.
Models and operator data remain outside the composition and are governed by their existing storage contracts.

### Closed Manifest Rules

Each component manifest records normalized relative path, entry kind, digest, byte length, mode, ownership policy, extended-attribute policy, code-signing identity where applicable, Mach-O dependency closure, entitlements, and component-specific compatibility identity.
Directory traversal, absolute paths, hard links, device files, sockets, FIFOs, undeclared extended attributes, access-control-list mutations, and symlinks outside the component root are rejected.
Internal symlinks are relative, resolve within the same component root, and cannot form cycles.
Path comparison rejects case-fold and Unicode-normalization collisions before extraction.
Extraction uses bounded entry counts, bounded path length, bounded expanded bytes, an isolated staging root, and an atomic same-filesystem rename after complete verification.

Mutable host state, the Node Identity Root, activation journals, verification evidence, release manifests, and the composition's own generated digest files are not part of a component tree digest.
Their exclusions are explicit rather than inferred.

## Identity Graph

The identity graph is acyclic and ordered:

1. Component trees produce component tree digests.
2. Component manifests bind those tree digests and component compatibility identities.
3. The composition lock binds the ordered component-manifest digests, target profile, target platform, compatibility declarations, identity-schema ranges, and realization-neutral composition identity.
4. A detached build attestation binds the composition-lock digest, provenance realization, builder policy, controlled inputs, and build outputs.
5. Verified composition inputs are assembled into the `Orchard.app` tree.
6. The Candidate or Internal Build Manifest records the app tree identity and composition-lock digest.
7. The signed DMG wraps the verified app tree and is recorded by release governance.

The composition lock does not contain its own digest, build-attestation digest, app-tree digest, release-manifest identity, DMG digest, publication state, or signature generated after the lock.
The detached build attestation does not contain its own digest or any later artifact identity.

## Provenance Realizations

### `exact_ref_source_build`

This realization is admitted only from the configured canonical Orchard repository at an exact full commit identifier reachable from an authorized ref policy.
The complete source tree is clean, including submodules or other declared source inputs.
The build uses pinned toolchain versions, dependency locks, controlled environment inputs, the exact macOS arm64 target, and either a pretrusted local builder identity or a verifier-controlled build environment.
The attestation records all declared source, toolchain, dependency-lock, builder-policy, and output identities.

A clean arbitrary fork, detached commit, modified lockfile, untrusted builder, or build using `--allow-dirty` may produce a custom local composition but cannot receive Orchard-trusted `exact_ref_source_build` status.

### `orchard_signed_prebuilt`

This realization is admitted only when every component manifest, composition lock, detached build attestation, and enclosing app or release evidence satisfies the configured Orchard signing and authorization policy.
The verifier checks exact bytes, signature chain, designated requirements, entitlements, notarization and stapling where required by the artifact stage, revocation policy, release identity, target platform, and composition compatibility.

A valid Apple signature alone does not establish Orchard provenance.
Ad hoc, locally resigned, partially signed, or byte-divergent inputs are rejected.

### Common Decision Contract

Both realization validators feed one verifier and return one versioned decision shape.
The decision includes the composition-lock digest, realization, profile, target, component identities, compatibility result, identity-schema result, trust-policy result, closure result, app or release binding when present, evidence digest, and a terminal verdict.
The only terminal verdicts are `admitted` and `rejected`.
Missing, unsupported, stale, ambiguous, or internally inconsistent evidence is rejected.

The verifier never converts an `exact_ref_source_build` result into an `orchard_signed_prebuilt` result or the reverse.
Trust policy is an input to the common decision, not a post-verification label.

## Node Identity Root

The Node Identity Root is a durable host path outside both the replaceable composition and its staging roots.
It owns Node identity material, Controller enrollment state, trust roots, and schema-governed retained state needed to preserve the same Node identity across activation and rollback.
It is never copied into a component archive or replaced by composition activation.

Each composition declares the minimum and maximum readable schema and the maximum schema it may write.
Preflight requires the incoming composition to read the current retained schema and the rollback composition to read every schema the incoming composition may write before uncordon.
The v1 transition set rejects a composition that could perform an irreversible retained-state migration across the selected rollback pair.

Secrets remain in their existing protected custody locations.
Manifests record secret-reference identities or required trust-root versions, never secret values.

## Coordinated Activation Protocol

### Authority Split

The Controller owns schedulability, maintenance, drain completion, allocation absence, health eligibility, and uncordon.
The host lifecycle owns local operation serialization, launch suppression, process custody, byte activation, local verification, and local start.
Neither authority may infer the other's acknowledgement from local state.

### Activation Sequence

1. Verify the incoming composition and selected rollback composition without mutating live state.
2. Ask the Controller to enter maintenance and drain the Node.
3. Require a fresh Controller acknowledgement that the Node is unschedulable and has no active allocations.
4. Acquire the host operation lock.
5. Write the new activation-journal header and establish durable managed-launch suppression.
6. Capture the exact outgoing managed process set through the single process-fence helper.
7. Boot out the managed launch domain and terminate only the captured process identities when required.
8. Prove that every captured identity exited and that no replacement managed process appeared.
9. Stage, verify, atomically activate, and post-activation verify the incoming composition.
10. Commit the journal state `activated_stopped` while launch suppression remains active.
11. Start the activated composition as a separate verified operation.
12. Require the new process to report the expected composition-lock digest, Node Identity Root identity, protocol compatibility, and healthy local state.
13. Clear launch suppression only as part of the verified start state.
14. Ask the Controller to evaluate health and compatibility, then explicitly uncordon the Node.

There is always a stopped interval between outgoing-process proof and incoming-process start.
The protocol makes no zero-downtime claim.

### Process Fence

One privileged helper protocol is the safety authority for launch suppression, exact process capture, stop, exit proof, and replacement detection.
Swift, Elixir, scripts, and tests call that protocol and do not maintain independent copies of the safety algorithm.
The helper identifies a process by PID, process start identity, executable identity, and the managed launch-domain membership available on the supported host.

The v1 no-overlap invariant is precise: after the outgoing fence is proven and until the incoming managed process is explicitly started, no process may run through the profile's supported managed launch domain.
An unexpected process in that domain is a hard failure and leaves suppression active.

### Activation Journal

The managed-composition journal has a new schema version and records immutable operation identity, old and new composition-lock digests, rollback target, Node Identity Root identity, Controller maintenance acknowledgement, verifier evidence digests, helper protocol version, and monotonic state transitions.
The minimum states are `prepared`, `suppressed`, `outgoing_captured`, `outgoing_stopped`, `activating`, `activated_stopped`, `starting`, `started_pending_controller`, `rollback_restored_stopped`, and `uncertain`.

Journal replacement is atomic and durable before the corresponding external mutation is acknowledged.
A state transition that cannot be durably recorded is treated as uncertain.
Existing lifecycle code that does not understand this schema refuses recovery and preserves launch suppression.

### Recovery and Rollback

Recovery begins by re-verifying the journal, Node Identity Root, active composition, rollback composition, process-fence state, and Controller maintenance state.
It never assumes that an interrupted state means a prior mutation completed or did not complete.

Rollback restores bytes only when the rollback composition remains verified and compatible with the current retained identity schema.
The restored composition remains stopped and launch-suppressed in `rollback_restored_stopped` until an explicit verified start succeeds.
Rollback does not uncordon the Node.

Missing journal evidence, contradictory active-tree identity, an unrecognized process, failed suppression, incompatible retained state, or inability to contact the Controller produces `uncertain`.
An uncertain operation may be inspected and repaired by an authorized operator but cannot auto-start or auto-uncordon.

## Orchard.app and DMG Derivation

The managed composition is assembled into a declared Node-role subtree of `Orchard.app` only after the common verifier admits it.
The app may continue to contain Controller, CLI, Console, or all-in-one content governed by the existing profile.
This change does not silently narrow the app to a Node-only product.

The app build records the composition-lock digest and detached build-attestation digest in the app's governed build evidence.
The app signing verifier covers the final embedded composition bytes and rejects a mismatch with the recorded composition identity.
The Candidate or Internal Build Manifest records the final app-tree digest and the embedded composition-lock digest.
The DMG builder packages that exact verified app tree and runs the existing signing, Gatekeeper, notarization, stapling, and artifact verification gates appropriate to its stage.

An extracted component archive, composition lock, or detached build attestation is evidence or an assembly input only.
It does not carry an independent installation or support claim.

## Migration Plan

There is no automatic adoption of an existing service or source-development process into managed custody.
The first managed activation requires a verifier-admitted incoming composition and a verifier-admitted rollback baseline with a known composition-lock digest.
If the currently installed Node lacks a composition lock, an explicit migration command must build and verify a closed baseline from the exact installed bytes before any stop or replacement occurs.
If that baseline cannot be closed and verified, migration stops before host mutation.

The initial supported matrix contains these distinct transition cases:

| Case | Outgoing realization | Incoming realization | Required result |
|---|---|---|---|
| A to B | `exact_ref_source_build` | `orchard_signed_prebuilt` | same Node Identity Root, zero managed-process overlap, explicit Controller uncordon |
| B to C | `orchard_signed_prebuilt` | `exact_ref_source_build` | same Node Identity Root, zero managed-process overlap, explicit Controller uncordon |

The B to C case is a reverse provenance transition, not an implied product-version downgrade.
Each selected pair must independently satisfy product-version, Runtime Endpoint, Worker Runtime, retained-schema, and rollback compatibility.

## Acceptance and Proof Strategy

Contract tests exercise the common verifier with fixtures for both realizations and byte-identical closure failures.
Public-interface lifecycle tests drive Controller maintenance, host activation, start, health, uncordon, and rollback without calling private implementation functions.
Fault-injection tests interrupt every journal boundary and prove that recovery never creates overlap or schedulability from uncertainty.
Process tests use real managed launchd jobs and prove exact outgoing exit, no replacement, unrelated-process survival, and rejected stale process identity.
Identity tests prove the Node Identity Root remains byte-for-byte or semantically stable as specified across both transition directions and rollback.

Real Apple Silicon qualification executes both transition directions plus failed activation, failed start, interrupted rollback, Controller disconnect, and host reboot at selected journal boundaries.
Evidence includes exact commands, composition identities, process samples, journal states, Controller maintenance observations, Node identity observations, and final health state.
Secrets, credentials, machine-specific paths, and raw transient logs do not enter the repository.

## Risks and Tradeoffs

The profile introduces a second lifecycle journal schema and a privileged helper protocol, which increases compatibility surface but creates one auditable safety authority.
Controller coordination makes activation unavailable during a control-plane outage, which is preferable to silently restarting a potentially schedulable Node.
The stopped interval reduces availability, which is the accepted tradeoff for a provable v1 no-overlap transition.
Exact-ref source trust requires a controlled builder policy, which deliberately excludes casual local builds from the supported provenance claim.
Retained-schema rollback compatibility restricts migrations, which avoids irreversible identity loss in the first slice.

## Open Questions

No contract-level design question remains open after owner approval.
Concrete filesystem locations, key identifiers, helper transport, journal encoding, timeout values, and compatibility-version values remain implementation details that must be selected within this contract and reviewed before code lands.
