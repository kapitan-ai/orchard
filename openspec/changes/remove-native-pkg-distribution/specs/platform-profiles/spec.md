## MODIFIED Requirements

### Requirement: Platform Profiles And Support Gates

Orchard SHALL define platform profiles that bind portable roles to host lifecycle, paths, credential storage, packaging, runtime payloads, and support acceptance evidence.
The macOS profile SHALL preserve the existing all-in-one Controller, Node Agent, MLX worker, app, DMG, launchd, and retained-state behavior.
The first accepted Linux target SHALL be a Controller Host using operator-provided external Postgres and dispatching to admitted macOS MLX Nodes.
The Linux Controller profile MUST NOT be represented as supported until its Milestone 8 acceptance gates pass.
This requirement changes `SPEC.md` §§1.1, 1.4, 1.5, 4.1, 11, and 14.

#### Scenario: Mixed Linux Controller and Mac Node cluster

- **WHEN** the Linux Controller target undergoes mixed-platform acceptance with an admitted macOS MLX Node through an authenticated Runtime Endpoint
- **THEN** the Controller may schedule compatible work to that Node under the same durable policy and trust requirements as a macOS Controller
- **AND** the Linux Controller is not required to provide a local accelerator runtime

#### Scenario: Existing Mac all-in-one deployment

- **WHEN** Orchard runs under the macOS all-in-one profile
- **THEN** the accepted Mac app lifecycle, inference, DMG distribution, signing, and retained-state guarantees remain applicable
