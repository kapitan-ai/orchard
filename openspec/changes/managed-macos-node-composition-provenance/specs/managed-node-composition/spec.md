## ADDED Requirements

### Requirement: V1 Has One Dedicated-Host Transition

Orchard SHALL reserve `managed_apple_silicon_macos_node` as an experimental distribution-profile identifier for a dedicated Apple Silicon macOS host that runs the Node Agent role and no Controller role.
Each admitted software composition under that profile SHALL be an independently typed, content-addressed Managed Node Composition instance.
V1 SHALL admit only an already managed `exact_ref_source_build` baseline transitioning to one `orchard_signed_prebuilt` candidate.
V1 SHALL permit rollback only to that exact recorded baseline.
It SHALL NOT admit legacy adoption, a normal reverse provenance transition, a subsequent managed update, or a Controller-bearing or all-in-one host.

#### Scenario: Supported v1 transition is requested

- **WHEN** a dedicated admitted Node presents its exact managed source baseline and one authorized signed-prebuilt candidate
- **THEN** Orchard SHALL evaluate the one supported forward transition

#### Scenario: Another transition or host role is requested

- **WHEN** the request starts from an unmanaged or prebuilt baseline, selects another rollback target, requests another update direction, or targets a Controller-bearing host
- **THEN** Orchard SHALL reject it before Controller transition creation or host mutation

### Requirement: Source Baseline Construction Is Verifier Controlled

An `exact_ref_source_build` baseline SHALL be constructed only inside a verifier-controlled isolated build environment.
Construction SHALL require the canonical Orchard repository, an authorized exact full commit, clean complete source inputs, pinned toolchains, dependency locks, controlled environment inputs, the exact macOS arm64 target, and deterministic declared outputs.
V1 SHALL NOT admit a pretrusted local builder or a user-supplied build attestation.

#### Scenario: Controlled source baseline is constructed

- **WHEN** the isolated verifier controls every declared source, toolchain, dependency, environment, target, and output input
- **THEN** it MAY issue a purpose-bound source-construction decision for the resulting exact baseline

#### Scenario: Local or uncontrolled source build is presented

- **WHEN** a build originated from a local trusted-builder claim, arbitrary checkout, dirty source, changed dependency lock, uncontrolled environment, or user-supplied attestation
- **THEN** Orchard SHALL reject it as a managed v1 baseline

### Requirement: Managed Composition Is Closed

The composition SHALL contain exactly one macOS arm64 Node Agent component built from the provider-neutral Node Agent core, one generation-side launchd host-adapter contract, and one exact-pinned single-process MLX Worker Provider with its dedicated interpreter and closed runtime dependencies.
Every executable, interpreter, library, package, launch contract, and immutable configuration default required by those components SHALL be enumerated by signed closed manifests.
The stable lifecycle bootstrap SHALL remain outside the replaceable composition and SHALL be referenced by exact required identity and protocol.
The Worker Provider and every closed runtime dependency SHALL satisfy the managed v1 non-forking and non-daemonizing process-shape contract.
The Node Agent component SHALL bind the pinned OTP runtime's exact closed ERTS support-process set, including OTP 29 `erl_child_setup`, and SHALL prohibit any unadmitted external Port target, resolver helper, shell, library child, or direct spawn path.
Any profile `epmd` service SHALL be exact-pinned stable host infrastructure outside replaceable generations and SHALL hold no Node Certificate, BEAM Peer Grant, Worker channel capability, Controller request authority, or Runtime Endpoint.
The composition SHALL bind a profile-fixed unprivileged Worker account name created and verified by the clean-host provisioning contract and SHALL NOT bind a machine-specific numeric UID.
That account's host-enforced filesystem policy SHALL deny the Worker Provider access to the Node Identity Set, release-trust store, active pointer, managed journals, helper control endpoint, other generations, and shared mutable serving state.
For code and system resources, it SHALL permit read and execute access only to the exact admitted current-generation Worker executable, interpreter, dependency closure, and closed system-library, framework, device, and IPC resources bound by the qualified matrix.
For non-code data and mutable resources, it SHALL permit read-only admitted model inputs, write access only to generation-scoped scratch, and the authenticated generation-scoped local channel.

#### Scenario: Closed composition is assembled

- **WHEN** all required component roles, signed bytes, runtime dependencies, compatibility identities, and bootstrap requirements are closed
- **THEN** Orchard MAY bind them into one composition lock

#### Scenario: Runtime dependency or component is undeclared

- **WHEN** a generation needs or contains an undeclared executable, interpreter, library, package, launch contract, helper, or immutable input
- **THEN** Orchard SHALL reject the composition

#### Scenario: Worker Provider requires multiple processes

- **WHEN** the Worker Provider or a closed dependency requires fork, subprocess creation, daemonization, or another executable at runtime
- **THEN** Orchard SHALL reject it from the managed v1 profile
- **AND** SHALL require a separately accepted containment contract or distribution profile before support

### Requirement: Executable and Provider Selection Cannot Be Overridden

The managed profile SHALL fix the Node Agent executable, stable bootstrap, Worker Provider executable, dedicated interpreter, launchd label, active-pointer location, and Node Identity Set location through signed profile evidence.
Environment variables, command arguments, mutable configuration, symlinks, retained state, model content, and operator data SHALL NOT override those selections.

#### Scenario: Override is attempted

- **WHEN** any mutable input attempts to select another executable, interpreter, provider, launch label, active pointer, or identity location
- **THEN** the stable bootstrap or verifier SHALL reject the managed start

### Requirement: Component Closure Is Deterministic and Safe

Orchard SHALL canonicalize each signed component tree and record path, entry kind, digest, byte length, mode, ownership policy, extended-attribute policy, code-signing identity where applicable, Mach-O dependency closure, entitlements, and compatibility identity.
Orchard SHALL reject traversal, absolute paths, hard links, device files, sockets, FIFOs, external or cyclic symlinks, undeclared extended attributes, disallowed access-control-list changes, case-fold collisions, Unicode-normalization collisions, and unclosed Mach-O dependencies.
Extraction SHALL enforce entry, path-length, and expanded-byte limits in an isolated staging root and SHALL publish only into a new immutable generation after complete verification.

#### Scenario: Archive contains an unsafe or ambiguous entry

- **WHEN** an archive contains traversal, a special file, a disallowed link, or a target-filesystem path collision
- **THEN** Orchard SHALL reject the archive before generation publication

#### Scenario: Generation is published

- **WHEN** every extracted byte matches the canonical signed manifests and all limits pass
- **THEN** Orchard SHALL atomically publish a new immutable generation
- **AND** SHALL NOT mutate an existing baseline, candidate, active, rollback, or retained-evidence generation

### Requirement: Artifact Identity Graph Follows Signing Order

Nested generation code SHALL receive required signatures and entitlements before component manifests and the composition lock identify its final bytes.
The admitted Node subtree SHALL then be embedded without mutation, followed by existing inner-to-outer app signing and complete app verification.
DMG assembly, notarization, stapling, mounting, and post-assembly verification SHALL be mandatory for every production candidate.
The Candidate Manifest SHALL be sealed only after the final app and mandatory DMG have final verified identities.

The composition lock SHALL NOT reference its own digest, final app identity, Candidate Manifest digest, DMG identity, publication state, or later signature.
The Candidate Manifest SHALL exclude itself according to the release-governance contract.

#### Scenario: Identity and signing order is valid

- **WHEN** each identity is sealed only after its subject bytes reach their final state for that stage
- **THEN** every reference SHALL point to an identity that existed earlier in the graph

#### Scenario: Later step mutates authorized bytes

- **WHEN** signing, packaging, copying, or metadata injection changes a sealed Node subtree, app, or DMG identity
- **THEN** Orchard SHALL invalidate the dependent admission or activation decision

### Requirement: Verification Is Bound to Purpose and Stage

One verifier engine SHALL return a versioned decision containing purpose, stage, profile, realization, exact subject identities, required evidence identities, policy version, and terminal `admitted` or `rejected` verdict.
The supported purposes SHALL distinguish source construction, Node-subtree assembly, signed-prebuilt activation, exact-baseline rollback, provisional-generation acceptance, host arm, and terminal live-child acceptance.
Evidence or a decision accepted for one purpose or stage SHALL NOT authorize another.
Missing, stale, unsupported, ambiguous, mismatched, or internally inconsistent evidence SHALL produce `rejected`.

#### Scenario: Node subtree is admitted for assembly

- **WHEN** closed signed component and composition evidence passes purpose `assemble_node_subtree`
- **THEN** Orchard MAY embed that exact subtree into an app
- **AND** SHALL NOT treat the decision as activation authority

#### Scenario: Signed prebuilt is authorized for activation

- **WHEN** purpose `activate_signed_prebuilt` binds the Node ID, operation ID, Controller transition generation, exact mounted final app, imported Node subtree generation, composition lock, installed bootstrap, Candidate Manifest, target profile, transition direction, baseline, and mandatory DMG evidence
- **THEN** Orchard MAY use that decision only for the matching Controller transition generation

#### Scenario: Wrong-purpose decision is replayed

- **WHEN** an assembly, source-construction, rollback, prior-stage, or prior-generation decision is presented as activation authority
- **THEN** Orchard SHALL reject it

### Requirement: Node Identity Set Is Explicit and Frozen

The retained Node Identity Set SHALL be the union of the complete current Node Identity Store generation, the scoped BEAM Peer Grant Store, and the stable bootstrap release-trust store.
The Node Identity Store SHALL include its current-generation pointer, metadata, private key, CSR, Node Certificate, Controller Certificate, runtime CA certificate, enrollment and cluster identifiers, URI SAN bindings, certificate identifiers and fingerprints, runtime trust SPKI digest, public-key and CSR fingerprints, state, and generation identity.
Each store SHALL live outside every generation and staging root at a fixed profile path.
The Controller generation SHALL bind the exact current store-generation identities and content digests.
Their schemas, paths, Node ID, Node private-key identity, Controller trust anchors, runtime trust anchors, and bootstrap release-trust anchors SHALL remain frozen for the v1 transition and rollback.
Renewable Node certificate bytes and scoped BEAM Peer Grant records MAY change only through their existing separately authorized protocols in an explicit generation-checked, scheduler-excluded recovery phase.
After such renewal or grant rotation, the Controller SHALL atomically rebind the new store generation and digests and reauthorize both the exact baseline and candidate before recovery continues.
V1 SHALL NOT migrate, relocate, delete, replace, extend, or symlink-substitute a store as part of activation.
Secret values SHALL NOT appear in manifests, composition locks, journals, Controller transition rows, or review evidence.

#### Scenario: Candidate uses the retained identity

- **WHEN** the signed-prebuilt generation starts provisionally
- **THEN** it SHALL observe the same Node Identity Set and frozen schema as the source baseline

#### Scenario: Identity mutation or alternate root is requested

- **WHEN** a generation or mutable input requests a schema change, new identity member, alternate path, replacement key or trust anchor, unauthorized credential or grant rotation, relocation, deletion, or symlinked root during a nonterminal transition
- **THEN** Orchard SHALL reject activation or rollback

#### Scenario: Renewable credential expires during recovery

- **WHEN** an existing authorized renewal or peer-grant rotation completes in the scheduler-excluded recovery phase
- **THEN** the Controller SHALL rebind the exact new store generation and reauthorize both baseline and candidate before another recovery mutation

### Requirement: Only Complete Profile Evidence Supports a Claim

Orchard SHALL describe the managed profile as supported only after its composition, purpose-bound verification, immutable-generation lifecycle, Controller execution-authority fence, Worker Provider spawn gate, exact registered-process fence, exact-baseline rollback, final app and DMG evidence, and adversarial real Apple Silicon qualification all pass.
Qualification SHALL bind an explicit operator-visible supported model and feature matrix to the exact Worker Provider executable, interpreter, dependency closure, relevant runtime configuration, model families, tokenizer paths, and execution modes.
Any change to that bound matrix or closure SHALL invalidate qualification until the affected matrix is requalified.
No component archive, generation, composition lock, verifier decision, local app, or unpublished artifact SHALL independently establish support.

#### Scenario: Contract or simulated tests pass without real-hardware qualification

- **WHEN** design, unit, integration, or simulated evidence exists but the adversarial real Apple Silicon matrix is incomplete
- **THEN** Orchard SHALL keep the profile unsupported

#### Scenario: Model or feature is outside the qualified matrix

- **WHEN** admission or execution selects a model, tokenizer path, execution mode, provider byte, dependency, or runtime configuration outside the qualified matrix
- **THEN** Orchard SHALL reject it with a stable operator-visible unsupported-profile reason
