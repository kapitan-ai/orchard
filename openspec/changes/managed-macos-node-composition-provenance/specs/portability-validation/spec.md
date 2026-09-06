## ADDED Requirements

### Requirement: Forward Transition Requires Public-Interface Proof

Orchard SHALL test the already managed `exact_ref_source_build` baseline to `orchard_signed_prebuilt` candidate transition through the same public verifier, Controller, host lifecycle, provisional-start, terminal-acceptance, and scheduler interfaces used by operators.
Tests SHALL NOT establish acceptance solely through private functions or direct database or filesystem mutation.

#### Scenario: Forward transition succeeds

- **WHEN** the public-interface transition completes on a dedicated Node
- **THEN** evidence SHALL show the exact source baseline, mandatory verified DMG and Candidate Manifest, imported signed-prebuilt generation, frozen Node Identity Set, closed execution-grant set, closed Worker Provider spawn gate, exact registered-process exit, atomic pointer switch, exact provisional child, host-arm evidence, pending-result consumption, enabled-child acknowledgement, exact registered Worker readiness, authenticated local channel, fresh Node Agent and Worker proof, and scheduler eligibility only after the second Controller commit

### Requirement: Exact-Baseline Rollback Requires Public-Interface Proof

Orchard SHALL test rollback only to the exact source baseline bound by the active Controller transition generation.
Rollback proof SHALL use the same closed execution-grant set, Worker Provider spawn gate, reserve-before-spawn process fence, authenticated local channel, atomic pointer, one-shot provisional child, Controller token, host-arm evidence, pending-result consumption, enabled-child acknowledgement, exact Worker readiness, fresh Node Agent and Worker proof, and second terminal generation transaction.

#### Scenario: Exact-baseline rollback succeeds

- **WHEN** candidate activation or acceptance fails and authorized rollback completes
- **THEN** evidence SHALL show only the exact baseline returned to eligibility and no generic resume or reconstructed backup was used

#### Scenario: Exact baseline cannot be verified

- **WHEN** baseline bytes, bootstrap, identity, process custody, pointer, Controller generation, or terminal evidence is uncertain
- **THEN** validation SHALL prove the Node remains stopped, launch-suppressed, and scheduler-excluded

### Requirement: Failure Boundaries Require Fail-Closed Proof

Validation SHALL inject interruption or failure at every durable Controller phase and local journal boundary and at mandatory DMG verification, candidate import, transition allocation fencing, execution-grant closure and accounting, drain acknowledgement, launch suppression, each reserve-before-spawn state, Worker Provider spawn-gate close and open, channel-capability delivery and authentication, Worker Runtime channel close, stop, exit proof, pointer switch, provisional claim, Controller arm authorization, host arm, pending Controller commit, child consumption, enabled-child acknowledgement, Worker readiness, fresh Node Agent and Worker challenge, terminal commit, active-generation launch-policy installation, and rollback.
Every ambiguous result SHALL remain launch-suppressed and scheduler-excluded.

#### Scenario: Terminal Controller result precedes active-policy installation

- **WHEN** failure occurs after the Controller accepts terminal `succeeded` or fully accepted `rolled_back` but before the exact active-generation launch policy is durably installed
- **THEN** validation SHALL prove the host remains suppressed and stable-bootstrap recovery idempotently installs only the policy bound to that exact terminal result, Node, generation, executable, and bootstrap
- **AND** ordinary grant issuance SHALL remain blocked until the helper durably reconciles the terminal result's serving epoch and the Node Agent publishes matching epoch-readiness
- **AND** if the Node Agent exits in that window, validation SHALL prove the execution-epoch channel closes, new Worker initialization remains denied, the helper terminates and reaps its registered Worker child, and restart waits for exact policy installation
- **AND** no stale, alternate-generation, or ordinary restart SHALL be admitted before installation succeeds

#### Scenario: Failure occurs around a linearization point

- **WHEN** the lifecycle or Controller is interrupted immediately before or after a pointer, one-shot, host-arm token, host-arm evidence, pending Controller commit, child acknowledgement, live-child challenge, or terminal database mutation
- **THEN** recovery SHALL re-observe exact state rather than infer completion
- **AND** SHALL preserve the fences until matching evidence is proved

### Requirement: Leadership, Heartbeat, and Generic Commands Cannot Bypass Transition

Validation SHALL prove that Controller restart, leadership change, stale leader mutation, stale scheduler snapshot, healthy heartbeat, generic resume, generic uncordon, and launchd retry cannot make the Node eligible before exact terminal evidence.
It SHALL race transition creation against allocation claims to prove no later grant can issue, race helper-serialized durable local epoch closure against final Worker Runtime acceptance to prove no later acceptance can commit, and prove every pre-fence execution-grant ID was never accepted, was durably rejected before acceptance, or has confirmed execution termination and allocation release across queue, retry, stream, recovery, and delayed-delivery paths before drain acknowledgement.

#### Scenario: Leader changes during provisional start

- **WHEN** leadership changes while the candidate is provisional or in `host_armed_pending_controller_commit`
- **THEN** the new leader SHALL preserve the transition generation and exclusion
- **AND** no request SHALL dispatch to the Node

### Requirement: Worker Process-Shape Adversaries Are Qualified on Real Hardware

Real Apple Silicon tests SHALL exercise exact OTP 29 `erl_child_setup` registration and exit, rejection of every unadmitted Erlang Port target and resolver or shell child, Worker Provider fork, subprocess launch, daemonization, unregistered execution, rapid spawn requests, PID reuse pressure, delayed exit, stale Worker Runtime channels, incomplete registration, helper crash at every reserve-before-spawn boundary, wrong-identity spawn, channel impersonation and replay, denied Node Identity Set, BEAM Peer Grant Store, journal, helper-control, and other protected-path access from a remnant, Worker readiness loss, and replacement root launch.
They SHALL also exercise helper death in `bound`, `released`, serving, and terminal-pending Worker states; privileged-command replay across helper death before and after the first side effect; every launchd enable, bootstrap, one-shot claim, root-registration, disable, bootout, owner-death, and reboot boundary; inherited-descriptor leakage attempts; and durable ordinary-serving managed-fault exclusion against health, restart, resume, uncordon, and Controller-unavailable races.
Qualification SHALL bind the exact executable, interpreter, dependency closure, relevant runtime configuration, model families, tokenizer paths, and execution modes in the supported model and feature matrix.
It SHALL combine closed executable-launch auditing with runtime process-creation observation across that matrix and SHALL invalidate qualification when the bound closure or matrix changes.
Qualification SHALL establish the observed single-process behavior of that exact matrix, atomic Worker Provider spawn-gate close bound to the Controller execution-authority fence as the no-new-execution point, exact registered-process exit, denial of stale authority, unrelated-process survival, and durable suppression across lifecycle-owner death and host reboot.

#### Scenario: Worker violates the admitted process shape

- **WHEN** a Worker Provider creates a descendant, daemonizes, starts outside the helper, changes identity, survives termination, retains a usable stale channel, or becomes unclassifiable
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

Production support and admission SHALL remain blocked until the separate clean-host managed-baseline provisioning contract, `product-versioning-release-governance` Candidate Manifest contract, operator-visible managed status and repair surfaces, safe managed decommission path, and next-update strategy are accepted and qualified.
Until then `managed_apple_silicon_macos_node` SHALL remain an experimental reserved identifier and SHALL NOT be exposed as an operator-acquirable supported profile.

#### Scenario: A prerequisite remains unaccepted

- **WHEN** any prerequisite contract or lifecycle surface is absent, unaccepted, or fails its qualification gates
- **THEN** Orchard SHALL NOT claim production support or begin implementation-dependent qualification

### Requirement: Existing Profiles and Foreground Development Remain Regression Gates

Validation SHALL prove that existing Controller-bearing and all-in-one profiles, generic app and DMG lifecycle, Worker Runtime behavior, and foreground source development remain conformant outside the managed profile.
The new profile SHALL NOT make native PKG, another platform, another provenance direction, another update, identity migration, relaxed skew, or zero-downtime activation part of the validation claim.

#### Scenario: Managed tests pass but existing profile regresses

- **WHEN** an existing supported profile or `make dev` changes outside the explicit contract
- **THEN** the managed composition change SHALL be blocked
