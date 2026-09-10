## ADDED Requirements

### Requirement: Node Activation Authority Is Separate From Distribution Approval

Product release governance SHALL define a Release Activation Attestation before the dedicated Node distribution can implement install, enrollment, update, or serving startup.
The attestation SHALL bind contract version and activation purpose, Product Version, release channel, Candidate Manifest digest, exact Node artifact identity, eligible verified candidate and distribution state, bundle identifier, platform tuple, monotonically increasing artifact-lineage sequence, release-registry generation and signing key identity, issue time, not-before time, expiry time, withdrawal, supersession, or replacement relationship, maximum clock uncertainty, and offline verification policy.
Distribution approval, publication approval, GitHub state, Amore state, a checksum, or a Candidate Manifest alone SHALL NOT authorize activation.
Known withdrawal SHALL take precedence over an older unexpired attestation.
Replay below the locally recorded highest accepted lineage sequence SHALL fail closed.
Release trust SHALL bootstrap from owner-approved root key identifiers and fingerprints plus the expected Apple Team identity and SHALL NOT accept a root introduced only by the candidate it verifies.
Registry rotation SHALL require authorization by a previously trusted unrevoked root, a monotonic generation, explicit key identities and effective times, and rollback protection.
Release governance SHALL own renewal issuance and authenticated trusted-time/state recovery evidence; the Node verifier SHALL consume that evidence through an authorized recovery path that does not require production BEAM or a currently valid activation attestation.
Recovery SHALL preserve existing release trust, withdrawal precedence, and lineage replay protection, and SHALL NOT reset trust or treat an uncertain local clock as authority.
Exact attestation lifetime, maximum clock uncertainty, root identities, key custody, rotation ceremony, and recovery SHALL be accepted and implemented before candidate qualification.

#### Scenario: Published candidate has no activation attestation

- **WHEN** a candidate is verified and published but lacks a valid Release Activation Attestation
- **THEN** the dedicated Node rejects install, enrollment, update, and serving startup

#### Scenario: Candidate tries to authorize its verifier

- **WHEN** the only key that validates release state is introduced by the same untrusted candidate or sidecar
- **THEN** verification fails without changing the trusted registry

#### Scenario: Offline activation evidence is current

- **WHEN** offline media carries an already trusted registry, exact Candidate Manifest projection, valid activation attestation, acceptable clock evidence, and a non-replayed lineage sequence
- **THEN** the host can verify the same activation authority without network egress

### Requirement: Apple Build Allocation Covers Every Governed App Identity

Product release governance SHALL assign `CFBundleVersion` through one explicitly approved monotonic authority for every governed macOS app bundle identifier.
The proposed authority SHALL use the existing global `1..9999` allocation ledger across `com.orchard.app` and `com.orchard.node`.
It SHALL consume one distinct allocation for each governed app artifact.
The allocation SHALL occur before app construction using `{build_kind, candidate_or_internal_build_identity, full_source_commit, product_version, channel, bundle_identifier, staged_payload_identity}` as its idempotency key.
For a tagged Candidate the construction identity SHALL be its signed tag, while an Internal Build SHALL use a unique governance-issued construction identity.
The Candidate Manifest SHALL record each artifact's bundle identifier, numeric-base `CFBundleShortVersionString`, allocated `CFBundleVersion`, and exact artifact identity.
An unchanged pre-seal retry with the same idempotency key SHALL reuse its allocation, while a changed key SHALL consume a new number and an abandoned allocation SHALL NOT be recycled.
The final Candidate or Internal Build Manifest SHALL bind the allocation record to the final sealed artifact digest after construction and signing.
A changed Product Version, channel, staged payload identity, signed tag, Internal Build construction identity, or other pre-seal key field SHALL receive a new allocation.
The first Node allocation SHALL verify and seed against every historical governed app value.

#### Scenario: Candidate contains two app artifacts

- **WHEN** one candidate set contains `Orchard.app` and `Orchard Node.app`
- **THEN** each artifact records its own bundle metadata
- **AND** the candidate consumes two distinct allocations from the approved monotonic authority without collision or unauthorized reuse
