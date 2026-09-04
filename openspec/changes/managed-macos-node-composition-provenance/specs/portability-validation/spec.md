## ADDED Requirements

### Requirement: Forward Transition Requires Public-Interface Proof

Orchard SHALL test the already managed `exact_ref_source_build` baseline to `orchard_signed_prebuilt` candidate transition through the same public verifier, Controller, host lifecycle, provisional-start, terminal-acceptance, and scheduler interfaces used by operators.
Tests SHALL NOT establish acceptance solely through private functions or direct database or filesystem mutation.

#### Scenario: Forward transition succeeds

- **WHEN** the public-interface transition completes on a dedicated Node
- **THEN** evidence SHALL show the exact source baseline, mandatory verified DMG and Candidate Manifest, imported signed-prebuilt generation, frozen Node Identity Set, authoritative containment close and exit, atomic pointer switch, exact provisional child, host-arm evidence, pending-result consumption, enabled-child acknowledgement, fresh live-child proof, and scheduler eligibility only after the second Controller commit

### Requirement: Exact-Baseline Rollback Requires Public-Interface Proof

Orchard SHALL test rollback only to the exact source baseline bound by the active Controller transition generation.
Rollback proof SHALL use the same kernel-backed containment fence, atomic pointer, one-shot provisional child, Controller token, host-arm evidence, pending-result consumption, enabled-child acknowledgement, fresh live-child proof, and second terminal generation transaction.

#### Scenario: Exact-baseline rollback succeeds

- **WHEN** candidate activation or acceptance fails and authorized rollback completes
- **THEN** evidence SHALL show only the exact baseline returned to eligibility and no generic resume or reconstructed backup was used

#### Scenario: Exact baseline cannot be verified

- **WHEN** baseline bytes, bootstrap, identity, process custody, pointer, Controller generation, or terminal evidence is uncertain
- **THEN** validation SHALL prove the Node remains stopped, launch-suppressed, and scheduler-excluded

### Requirement: Failure Boundaries Require Fail-Closed Proof

Validation SHALL inject interruption or failure at every durable Controller phase and local journal boundary and at mandatory DMG verification, candidate import, transition allocation fencing, drain acknowledgement, launch suppression, containment close, stop, exit proof, pointer switch, provisional claim, Controller arm authorization, host arm, pending Controller commit, child consumption, enabled-child acknowledgement, fresh live-child challenge, terminal commit, and rollback.
Every ambiguous result SHALL remain launch-suppressed and scheduler-excluded.

#### Scenario: Failure occurs around a linearization point

- **WHEN** the lifecycle or Controller is interrupted immediately before or after a pointer, one-shot, host-arm token, host-arm evidence, pending Controller commit, child acknowledgement, live-child challenge, or terminal database mutation
- **THEN** recovery SHALL re-observe exact state rather than infer completion
- **AND** SHALL preserve the fences until matching evidence is proved

### Requirement: Leadership, Heartbeat, and Generic Commands Cannot Bypass Transition

Validation SHALL prove that Controller restart, leadership change, stale leader mutation, stale scheduler snapshot, healthy heartbeat, generic resume, generic uncordon, and launchd retry cannot make the Node eligible before exact terminal evidence.
It SHALL race transition creation against allocation claim and final Worker Runtime execution acceptance and prove no post-fence acceptance can commit while every pre-fence accepted execution is included in drain acknowledgement.

#### Scenario: Leader changes during provisional start

- **WHEN** leadership changes while the candidate is provisional or in `host_armed_pending_controller_commit`
- **THEN** the new leader SHALL preserve the transition generation and exclusion
- **AND** no request SHALL dispatch to the Node

### Requirement: Full Descendant Adversaries Are Qualified on Real Hardware

Real Apple Silicon tests SHALL include nested Worker Provider children, rapid child creation, reparenting attempts, PID reuse pressure, delayed exit, containment escape attempts, incomplete authoritative membership, replacement root launch, and replacement descendant launch.
Qualification SHALL prove authoritative containment membership, atomic containment close as the no-new-child point, exact membership exit, unrelated-process survival, and durable suppression across lifecycle-owner death and host reboot.

#### Scenario: Descendant escapes exact proof

- **WHEN** a child escapes containment, reparents without retaining membership, changes identity, survives termination, or becomes unclassifiable
- **THEN** activation SHALL fail and the Node SHALL remain stopped and scheduler-excluded

### Requirement: Purpose and Artifact Stage Boundaries Are Qualified

Validation SHALL reject cross-purpose verifier decisions, wrong-stage evidence, locally resigned apps, copied compositions, mutated signed bytes, wrong Candidate Manifests, wrong bootstrap identities, and wrong or missing mandatory DMG evidence.

#### Scenario: Valid assembly evidence is replayed at activation

- **WHEN** an otherwise valid Node-subtree assembly decision is presented for activation
- **THEN** validation SHALL prove activation is rejected before host mutation

### Requirement: Real Apple Silicon Qualification Is a Support Gate

The profile SHALL remain unsupported until the forward transition, exact-baseline rollback, every failure boundary, process adversary, Controller race, host reboot, artifact mismatch, dedicated-host check, and regression matrix pass on supported Apple Silicon macOS hardware.
Evidence SHALL record exact artifact and generation identities, process observations, journal states, Controller transition phases, Node identity, and final eligibility without committing secrets or machine-specific transient logs.

#### Scenario: Only simulated validation passes

- **WHEN** unit, integration, and simulated lifecycle tests pass but the real-hardware adversarial matrix is incomplete
- **THEN** Orchard SHALL keep the profile unsupported

### Requirement: Provisioning and Release Governance Are Acceptance Prerequisites

Production support SHALL remain blocked until the separate clean-host managed-baseline provisioning contract and `product-versioning-release-governance` Candidate Manifest contract are accepted and qualified.

#### Scenario: A prerequisite remains unaccepted

- **WHEN** either prerequisite contract is absent, unaccepted, or fails its qualification gates
- **THEN** Orchard SHALL NOT claim production support or begin implementation-dependent qualification

### Requirement: Existing Profiles and Foreground Development Remain Regression Gates

Validation SHALL prove that existing Controller-bearing and all-in-one profiles, generic app and DMG lifecycle, Worker Runtime behavior, and foreground source development remain conformant outside the managed profile.
The new profile SHALL NOT make native PKG, another platform, another provenance direction, another update, identity migration, relaxed skew, or zero-downtime activation part of the validation claim.

#### Scenario: Managed tests pass but existing profile regresses

- **WHEN** an existing supported profile or `make dev` changes outside the explicit contract
- **THEN** the managed composition change SHALL be blocked
