## ADDED Requirements

### Requirement: Deprecated manifest digest compatibility
Per `SPEC.md` §6.4, supported Model Manifest consumers SHALL accept otherwise valid manifests with or without top-level `sha256`.
The field SHALL remain a known key during the compatibility phase, SHALL be deprecated and non-authoritative when present, and SHALL NOT supply, override, or be compared with the Catalog Artifact Bundle digest.
When present, the field SHALL contain a non-empty string; omission is distinct from an explicit JSON `null`.
Consumers MUST continue to reject unknown manifest keys.

#### Scenario: Consumer accepts omitted legacy digest
- **WHEN** a supported consumer receives an otherwise valid Model Manifest without top-level `sha256`
- **THEN** the consumer accepts the manifest and represents the legacy value as absent

#### Scenario: Consumer accepts present legacy digest without authority
- **WHEN** a supported consumer receives an otherwise valid Model Manifest with top-level `sha256`
- **THEN** the consumer accepts the manifest without using that value as Artifact Bundle integrity evidence

#### Scenario: Consumer rejects a present non-string legacy digest
- **WHEN** a Model Manifest includes top-level `sha256` with JSON `null` or another non-string value
- **THEN** the consumer rejects the manifest rather than treating the field as omitted

#### Scenario: Consumer rejects an unknown key
- **WHEN** a Model Manifest includes a top-level key outside the closed known-key set
- **THEN** the consumer rejects the manifest even though `sha256` itself is optional

### Requirement: Authoritative final Artifact Bundle digest
Per `SPEC.md` §§6.4-6.6, `models.artifact_sha256` SHALL contain the lowercase SHA-256 digest computed over the final stored Artifact Bundle after secure staging and all importer-owned mutations.
The digest domain SHALL include every regular file under the Artifact Bundle root, including the relative path and exact final bytes of `manifest.json`, using the existing `Orchard.ArtifactBundle.tree_sha256/1` algorithm.
The importer SHALL persist the computed value independently of any legacy manifest `sha256` value.

#### Scenario: Final manifest bytes affect the authoritative digest
- **WHEN** only the exact bytes of `manifest.json` change in an Artifact Bundle
- **THEN** the recomputed Artifact Bundle digest changes

#### Scenario: Importer stores the final post-rewrite digest
- **WHEN** import succeeds after an importer-owned manifest rewrite
- **THEN** `models.artifact_sha256` equals a fresh digest of the final stored Artifact Bundle tree

#### Scenario: Legacy value cannot override Catalog authority
- **WHEN** two otherwise identical import inputs carry different present legacy `sha256` strings
- **THEN** each Catalog digest is derived from its final stored tree and neither legacy string is copied into the Catalog digest field

### Requirement: Distinct offline verification checkpoints
Per `SPEC.md` §§6.5, 6.7, and 11.7, pre-import detached media verification and post-import Catalog verification SHALL be distinct checkpoints.
Pre-import verification SHALL compare transferred Model Bundle media with detached verification evidence obtained through an independently trusted channel.
Post-import verification SHALL recompute the final stored Artifact Bundle digest and compare it with the authoritative Catalog value or a trusted external export.
This requirement SHALL NOT define Runtime Endpoint distribution, Node acquisition enforcement, signatures, or archive-container digest semantics.

#### Scenario: Verify transferred media before import
- **WHEN** an operator transfers a Model Bundle into an offline environment
- **THEN** the operator verifies the transferred media against independently trusted detached evidence before import

#### Scenario: Verify final storage after import
- **WHEN** Orchard import has completed and may have rewritten `manifest.json`
- **THEN** post-import verification uses the final stored tree and the authoritative Catalog digest rather than the legacy manifest field

### Requirement: Gated producer deprecation
BundleBuilder SHALL retain top-level `sha256` emission during this compatibility phase.
Producer omission MUST be implemented only in a separate accepted change that cites repo-owned minimum-consumer-version evidence proving every supported consumer accepts omission.

#### Scenario: Current builder preserves compatibility output
- **WHEN** BundleBuilder creates a Model Manifest before the compatibility gate is accepted
- **THEN** it continues emitting the legacy top-level `sha256` key

#### Scenario: Producer omission remains a gated follow-up
- **WHEN** no repo-owned accepted compatibility gate proves omission safe
- **THEN** this change does not remove the field or invent capability negotiation
