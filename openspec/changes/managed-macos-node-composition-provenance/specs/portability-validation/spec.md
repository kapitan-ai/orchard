## ADDED Requirements

### Requirement: Both Provenance Directions Require Public-Interface Proof

Orchard SHALL test `exact_ref_source_build` to `orchard_signed_prebuilt` and `orchard_signed_prebuilt` to `exact_ref_source_build` through the same public verifier, Controller-maintenance, host-activation, start, health, rollback, and uncordon interfaces used by operators.
Tests SHALL NOT establish acceptance solely through private functions or direct state mutation.

#### Scenario: Source-built composition transitions to signed prebuilt

- **WHEN** the A-to-B public-interface test completes successfully
- **THEN** evidence SHALL show one retained Node Identity Root, a stopped interval with no managed-process overlap, the expected incoming composition, and explicit Controller uncordon

#### Scenario: Signed prebuilt transitions to source-built

- **WHEN** the B-to-C public-interface test completes successfully
- **THEN** evidence SHALL show one retained Node Identity Root, a stopped interval with no managed-process overlap, the expected incoming composition, and explicit Controller uncordon
- **AND** the result SHALL NOT imply that arbitrary product-version downgrade is supported

### Requirement: Failure Boundaries Require Fail-Closed Proof

Validation SHALL inject interruption or failure at every durable journal boundary and at verifier, Controller acknowledgement, launch suppression, outgoing stop, replacement detection, staging, activation, post-activation verification, start, health, rollback, and uncordon boundaries.
Every uncertain case SHALL prove that the Node remains stopped, launch-suppressed, and unschedulable.

#### Scenario: Failure occurs at a journal boundary

- **WHEN** the lifecycle is interrupted before or after any recorded external mutation
- **THEN** recovery SHALL re-observe state rather than infer completion
- **AND** any ambiguous result SHALL remain stopped and in maintenance

#### Scenario: Unexpected managed process appears

- **WHEN** fault injection creates a replacement process before incoming start
- **THEN** validation SHALL prove that activation or start is rejected and suppression remains active

### Requirement: Real Apple Silicon Migration Qualification Is Mandatory

The managed profile SHALL NOT be described as supported until both provenance directions, compatible rollback, failed rollback, Controller disconnect, host reboot, process replacement, and retained-schema incompatibility have passed on real supported Apple Silicon macOS hardware.
Qualification SHALL record exact composition identities, process observations, journal states, Controller maintenance observations, retained Node identity, and final health without committing secrets or transient machine-specific evidence.

#### Scenario: Only simulated validation passes

- **WHEN** unit, integration, and simulated lifecycle tests pass but real Apple Silicon migration qualification is absent
- **THEN** Orchard SHALL treat the profile as unqualified

#### Scenario: Real hardware qualification passes

- **WHEN** the complete required matrix passes on a supported Apple Silicon macOS host
- **THEN** the profile MAY proceed to independent review and the remaining support gates

### Requirement: Existing Profiles and Foreground Development Remain Regression Gates

Validation SHALL prove that controller-only, all-in-one, existing macOS app and DMG lifecycle, Worker Runtime compatibility, and foreground source-development behavior remain conformant.
The new profile SHALL NOT make native PKG, another platform, relaxed skew, or zero-downtime activation part of the validation claim.

#### Scenario: Managed composition tests pass but foreground behavior regresses

- **WHEN** `make dev` no longer retains foreground custody or its documented stop behavior changes unintentionally
- **THEN** the managed composition change SHALL be blocked
