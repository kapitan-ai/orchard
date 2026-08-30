## ADDED Requirements

### Requirement: Active local-model support claims require exact approved qualification

An active Orchard local-model support claim SHALL identify an approved qualification record for the exact model, runtime, artifact, and environment tuple and SHALL expose only the approved capability envelope.
Catalog presence, Tenant publication, runtime availability, or a plausible response SHALL NOT independently constitute qualification or support.
Every applicable Platform Profile, Distribution Profile, Runtime Provider Profile, and Acceptance Profile gate SHALL already be supported before the claim becomes active.

#### Scenario: Exact approved tuple supports a narrower claim

- **WHEN** an approved qualification record covers an exact tuple and a tested capability envelope
- **THEN** a merged support claim may activate for that tuple
- **AND** the claim includes only the approved subset of capabilities, topology, concurrency, serving mode, and operating bounds

#### Scenario: Applicable profile is unsupported

- **WHEN** qualification evidence targets an unsupported or experimental applicable profile
- **THEN** the evidence may remain draft or `hold_for_review`
- **AND** no active support claim is created for that profile

#### Scenario: Capability was not tested

- **WHEN** a capability has no accepted conformance evidence
- **THEN** the capability remains unknown
- **AND** plausible generated output does not imply support

### Requirement: Qualification evidence preserves serving conditions and failure attribution

Each qualification record SHALL distinguish artifact or import validation, runtime load, meaningful generation, capability-specific semantic or API conformance, and production qualification.
Every measured result SHALL be `pass`, `fail`, `blocked`, or `not_tested` and SHALL identify either `cold_load_permitted` or `placement_preloaded` as its serving mode.
The record SHALL include cold-load time, effective request deadline, routing or residency values, and any residency requirement.

#### Scenario: Preloaded generation passes

- **WHEN** meaningful generation passes only after placement preload
- **THEN** the evidence is recorded as `placement_preloaded`
- **AND** it does not support a cold-load claim

#### Scenario: Orchard cold-start defect blocks qualification

- **WHEN** the exact tuple generates successfully while preloaded but a durable Orchard defect prevents cold load within the tested deadline
- **THEN** the record outcome is `hold_for_review`
- **AND** the hold classifies the blocker as an Orchard defect
- **AND** it names the owning issue and the exact resume condition
- **AND** closing the issue triggers requalification rather than approval of the historical record

### Requirement: Qualification and claim lifecycles remain reviewable and atomic

Qualification outcomes SHALL be `approved`, `hold_for_review`, `not_qualified`, `withdrawn`, or `superseded`.
A maintainer with merge authority SHALL approve, withdraw, or supersede a record through a merged repository change.
When a record stops being approved, every linked active claim SHALL transition in the same merged change.

#### Scenario: Approved record is invalidated

- **WHEN** a material defect or requalification trigger invalidates an approved record
- **THEN** the record is withdrawn, superseded, or placed under review through a merged change
- **AND** every linked active claim becomes withdrawn, superseded, or otherwise inactive in that same change

#### Scenario: Evidence author is the only available maintainer

- **WHEN** no other qualified maintainer is available to review the evidence author's record
- **THEN** the same maintainer may approve it under a disclosed sole-maintainer exception
- **AND** the record identifies the exception explicitly

### Requirement: Material changes trigger requalification and evidence retention

Qualification SHALL be repeated when a material change can invalidate the accepted tuple, capability envelope, serving conditions, or cost and deadline assumptions.
The repository policy SHALL define retention for active claims, held evidence, approved evidence without a claim, and inactive outcomes.

#### Scenario: Material tuple or contract input changes

- **WHEN** the artifact, tokenizer or renderer, runtime dependency, Orchard revision, protocol, configuration, hardware or operating system, request admission budget, residency policy, cold-start cost, or relevant defect changes materially
- **THEN** the affected record and claims require review and requalification before support is represented as current

#### Scenario: Record contains protected evidence

- **WHEN** raw prompts, responses, credentials, logs, machine paths, identifiers, or transient traces are needed for review
- **THEN** they remain outside Git in a protected site-local evidence package
- **AND** the repository record references only a stable package identifier and digest

### Requirement: Qualification governance does not create product state

Model qualification and support claims SHALL remain repository-owned manual governance unless a separate product Feature is approved.
This policy SHALL NOT add or overload product persistence, APIs, manifests, scheduler gates, Console surfaces, runtime protocols, or automation.

#### Scenario: Runtime enforcement is proposed

- **WHEN** a collaborator proposes runtime enforcement of qualification or support-claim state
- **THEN** that behavior is excluded from this change
- **AND** it requires a separate approved product change with explicit `SPEC.md` impact
