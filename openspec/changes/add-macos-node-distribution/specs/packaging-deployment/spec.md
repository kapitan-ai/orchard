## MODIFIED Requirements

### Requirement: DMG And Orchard.app Are The Approved macOS Native Distribution

After contract acceptance, Orchard SHALL permit a separately authorized exact candidate for Stage B or Stage C qualification to use a signed and notarized DMG containing `Orchard.app` for the existing all-in-one artifact or `Orchard Node.app` for the dedicated Node-only artifact.
Qualification of that candidate SHALL NOT itself approve delivery, publication, support, public visibility, or the distribution profile.
The app-owned lifecycle SHALL remain the current root-authorized path for service installation, update, uninstall, and status, with role selection in the existing artifact and fixed Node-only authority in the dedicated artifact.
This changes `SPEC.md` §11 and §§11.1-11.4 only for the separately identified Node distribution.
The proposal, structural validation, implementation, or local artifact qualification SHALL NOT establish a supported public binary.
Developer ID credentials, signing, notarization, stapling, and candidate activation SHALL require explicit authorization before Stage B or Stage C uses the candidate.
Delivery, publication, support, and public visibility SHALL remain separately authorized later operations.

#### Scenario: Current macOS distribution is assembled

- **WHEN** Orchard produces the existing all-in-one macOS distribution
- **THEN** the distribution contains a verifiable `Orchard.app` in the DMG
- **AND** it does not require a native PKG artifact

#### Scenario: Dedicated Node distribution is assembled

- **WHEN** Orchard produces the dedicated Node-only macOS distribution
- **THEN** its DMG contains a verifiable `Orchard Node.app` with the closed Node-only payload
- **AND** the existing all-in-one composition and release gates remain preserved
- **AND** assembly alone does not authorize publication or support

### Requirement: Distribution Payloads Are Selected Explicitly

A distribution profile SHALL contain only runtime providers and native host artifacts compatible with its declared platform and runtime-provider profiles.
The macOS native distribution profile SHALL retain the accepted Controller, Node Agent, MLX, tokenizer, app-owned host lifecycle, and role-selected payload behavior for the all-in-one topology.
The dedicated Node-only artifact SHALL contain only the closed Node payload specified by `macos-node-distribution`, without changing the all-in-one payload requirement.
This changes `SPEC.md` §§11.1-11.3 to distinguish the two artifact compositions.

#### Scenario: Mac all-in-one artifact is assembled

- **WHEN** the existing macOS all-in-one topology is built during the portability migration
- **THEN** it continues to contain the accepted Mac-compatible role payloads
- **AND** no future Linux or CUDA payload is required for acceptance

#### Scenario: Node-only profile contains Controller modules

- **WHEN** the dedicated Node artifact includes Controller implementation anywhere in its release or boot closure
- **THEN** artifact validation fails even if its selected service role is Node-only
