## ADDED Requirements

### Requirement: Managed Node Composition Is Closed and Role Specific

Orchard SHALL define one `managed_apple_silicon_macos_node` composition for the Node-role specialization of the macOS native distribution profile.
The composition SHALL contain exactly one macOS arm64 Node Agent component built from the provider-neutral Node Agent core, one launchd host-adapter component, and one exact-pinned MLX Worker Provider component.
Every executable, library, package, launch definition, helper, and immutable configuration default needed to run those components SHALL be enumerated by closed component manifests.
Models, operator data, the Node Identity Root, journals, release manifests, and generated identity records SHALL remain outside the replaceable composition.

#### Scenario: Closed composition is admitted

- **WHEN** all three required component roles have closed manifests and every referenced entry passes closure verification
- **THEN** Orchard SHALL permit the component manifests to be bound into one composition lock
- **AND** the composition lock SHALL identify the managed Apple Silicon macOS Node profile and exact target platform

#### Scenario: Undeclared runtime dependency is present

- **WHEN** a component needs or contains an executable, library, package, launch definition, helper, or immutable configuration input that its manifest does not close
- **THEN** Orchard SHALL reject the composition
- **AND** SHALL NOT stage or activate any of its bytes

### Requirement: Component Closure Is Deterministic and Safe to Extract

Orchard SHALL canonicalize each component tree and record path, entry kind, digest, byte length, mode, ownership policy, extended-attribute policy, code-signing identity where applicable, Mach-O dependency closure, entitlements, and compatibility identity.
Orchard SHALL reject traversal, absolute paths, hard links, device files, sockets, FIFOs, external or cyclic symlinks, undeclared extended attributes, disallowed access-control-list changes, case-fold collisions, Unicode-normalization collisions, and unclosed Mach-O dependencies.
Extraction SHALL enforce configured entry, path-length, and expanded-byte limits inside an isolated staging root and SHALL publish only by atomic same-filesystem rename after complete verification.

#### Scenario: Archive contains a path collision or unsafe entry

- **WHEN** an archive contains traversal, a special file, a disallowed link, or two paths that collide under the target filesystem's case or Unicode normalization behavior
- **THEN** Orchard SHALL reject the archive before activation
- **AND** SHALL leave the active composition unchanged

#### Scenario: Closed component is extracted

- **WHEN** every entry is within configured limits and matches the canonical component manifest
- **THEN** Orchard SHALL extract it only into an isolated staging root
- **AND** SHALL make it eligible for atomic activation only after post-extraction verification succeeds

### Requirement: Composition Identity Graph Is Acyclic

Component tree digests SHALL feed component manifests, component-manifest digests SHALL feed the composition lock, and the composition-lock digest SHALL feed a detached build attestation and later app or release evidence.
The composition lock SHALL bind the ordered component identities, target profile, target platform, compatibility declarations, retained-identity schema ranges, and realization-neutral composition identity.
The composition lock SHALL NOT reference its own digest, a build-attestation digest, an app-tree digest, a Candidate or Internal Build Manifest, a DMG digest, publication state, or any later signature.
The detached build attestation SHALL NOT reference its own digest or later app, release, DMG, or publication identity.

#### Scenario: Composition evidence follows the identity order

- **WHEN** Orchard produces component manifests, a composition lock, and a detached build attestation
- **THEN** every reference SHALL point only to an identity that existed earlier in the graph
- **AND** recomputing any earlier identity SHALL deterministically invalidate every dependent identity

#### Scenario: Manifest introduces a circular identity

- **WHEN** a composition lock or build attestation references itself or an identity produced by a later assembly or release stage
- **THEN** Orchard SHALL reject the evidence as structurally invalid

### Requirement: Exactly Two Provenance Realizations Are Admitted

The managed profile SHALL admit only `exact_ref_source_build` and `orchard_signed_prebuilt` realizations.
Both realizations SHALL produce the same component, composition-lock, compatibility, and verifier-decision structure.
The realization name SHALL describe provenance and SHALL NOT by itself grant support, publication, installation, or scheduling authority.

#### Scenario: Admitted realization is supplied

- **WHEN** a composition declares `exact_ref_source_build` or `orchard_signed_prebuilt`
- **THEN** Orchard SHALL evaluate the realization-specific trust policy and the common composition contract

#### Scenario: Unknown or hybrid realization is supplied

- **WHEN** a composition declares another realization or combines trust evidence from both admitted realizations to cover missing evidence
- **THEN** Orchard SHALL reject the composition

### Requirement: Exact Ref Source Builds Use Controlled Trust

An `exact_ref_source_build` SHALL originate from the configured canonical Orchard repository at an exact full commit identity reachable under an authorized-ref policy.
Its complete declared source inputs SHALL be clean.
Its build SHALL use pinned toolchains, dependency locks, controlled environment inputs, the exact macOS arm64 target, and a pretrusted local builder or verifier-controlled build environment.
Its detached build attestation SHALL bind those inputs and the resulting composition-lock digest.

#### Scenario: Controlled exact-ref build is verified

- **WHEN** the canonical repository, authorized exact ref, clean source, pinned inputs, target, builder policy, and output identities all agree
- **THEN** the common verifier MAY admit the composition as `exact_ref_source_build`

#### Scenario: Arbitrary clean commit is presented

- **WHEN** a build comes from an unauthorized ref, noncanonical repository, dirty source, changed lock, uncontrolled environment, or untrusted builder
- **THEN** Orchard SHALL NOT assign Orchard-trusted `exact_ref_source_build` provenance
- **AND** SHALL NOT activate it under this managed profile

### Requirement: Orchard Signed Prebuilt Uses Orchard Authorization

An `orchard_signed_prebuilt` SHALL satisfy the configured Orchard signing and authorization policy for every component manifest, composition lock, detached build attestation, and enclosing app or release evidence required by its stage.
Verification SHALL cover exact bytes, signature chain, designated requirements, entitlements, target platform, composition compatibility, and notarization and stapling where required.
A valid Apple signature without Orchard authorization SHALL be insufficient.

#### Scenario: Authorized prebuilt is verified

- **WHEN** exact bytes, Orchard authorization, required signatures, entitlements, target, compatibility, and stage-specific notarization evidence agree
- **THEN** the common verifier MAY admit the composition as `orchard_signed_prebuilt`

#### Scenario: Locally resigned or byte-divergent prebuilt is presented

- **WHEN** a prebuilt is ad hoc signed, locally resigned, partially signed, authorized by an unrecognized identity, or differs from its recorded bytes
- **THEN** Orchard SHALL reject it

### Requirement: Both Realizations Share One Fail-Closed Verifier Decision

Realization-specific validators SHALL feed one versioned verifier decision contract.
The decision SHALL include composition-lock digest, realization, profile, target, component identities, compatibility result, retained-schema result, trust-policy result, closure result, applicable app or release binding, evidence digest, and a terminal `admitted` or `rejected` verdict.
Missing, stale, unsupported, ambiguous, or inconsistent evidence SHALL produce `rejected`.
The verifier SHALL NOT convert one realization into the other.

#### Scenario: Either realization passes all checks

- **WHEN** the realization-specific trust validator and every common composition check pass
- **THEN** the verifier SHALL return the same versioned decision shape with verdict `admitted`
- **AND** SHALL preserve the original realization identity

#### Scenario: Evidence is incomplete or ambiguous

- **WHEN** any required trust, closure, compatibility, schema, target, or binding evidence is missing, stale, unsupported, ambiguous, or contradictory
- **THEN** the verifier SHALL return verdict `rejected`
- **AND** downstream lifecycle code SHALL NOT reinterpret the result

### Requirement: Node Identity Root Is Retained Outside Composition

The managed profile SHALL keep the Node Identity Root outside active, staged, and rollback composition trees.
The Node Identity Root SHALL retain Node identity, Controller enrollment, trust-root references, and schema-governed state needed to preserve the same Node across activation and rollback.
Manifests and evidence SHALL record secret references or trust-root identities rather than secret values.

#### Scenario: Composition provenance changes

- **WHEN** a Node transitions between the two admitted realizations
- **THEN** the active composition bytes MAY change
- **AND** the Node Identity Root and Controller-visible Node identity SHALL remain the same

#### Scenario: Archive contains retained identity material

- **WHEN** a component archive includes Node identity, enrollment secrets, trust roots, or retained-state bytes owned by the Node Identity Root
- **THEN** Orchard SHALL reject the archive

### Requirement: Retained Schema Must Remain Rollback Compatible

Each composition SHALL declare the minimum and maximum retained schema it can read and the maximum schema it may write.
Before activation, Orchard SHALL prove that the incoming composition can read current retained state and that the selected rollback composition can read every schema the incoming composition may write.
The v1 supported transition set SHALL reject irreversible retained-schema mutation.

#### Scenario: Transition preserves rollback compatibility

- **WHEN** current retained state is readable by the incoming composition and every reachable written schema remains readable by the rollback composition
- **THEN** the transition MAY proceed to Controller maintenance preflight

#### Scenario: Incoming write would strand rollback

- **WHEN** the incoming composition may write retained state that the selected rollback composition cannot read
- **THEN** Orchard SHALL reject the transition before host mutation

### Requirement: Support Claim Is Bound to the Complete Profile

Orchard SHALL describe the managed Node as supported only when the composition, app and DMG derivation, Controller coordination, host lifecycle, compatibility, migration, rollback, and real Apple Silicon qualification requirements all pass.
A component archive, component manifest, composition lock, detached build attestation, locally built app, or unsigned or unpublished DMG SHALL NOT independently establish a support claim.

#### Scenario: Only component evidence exists

- **WHEN** component closure and composition verification pass but app, lifecycle, migration, or real-hardware qualification evidence is absent
- **THEN** Orchard SHALL treat the result as build or test evidence only
- **AND** SHALL NOT represent the profile as supported
