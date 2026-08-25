## RENAMED Requirements

- FROM: `### Requirement: Portable Core Dependency Contract`
- TO: `### Requirement: Portable Orchard Control-Plane Core Dependency Contract`
- FROM: `### Requirement: Platform Profiles And Support Gates`
- TO: `### Requirement: Qualified Profiles And Support Gates`

## MODIFIED Requirements

### Requirement: Qualified Profiles And Support Gates

Orchard SHALL define platform, distribution, runtime-provider, and acceptance profiles as qualified, composable concepts.
A platform profile SHALL bind host roles to an operating system, architecture, and platform acceptance evidence.
A distribution profile SHALL bind a platform profile and install roles to deployment artifacts, host lifecycle, paths, credential storage, update and rollback behavior, retained state, and release evidence.
A runtime-provider profile SHALL bind a Node role to a Worker Runtime provider, compatible acceleration and device resources, provider-neutral conformance, and real-runtime acceptance.
An acceptance profile SHALL define a named topology and the evidence required to prove its participating profiles operate together.
Host-lifecycle adapters and deployment artifacts MUST NOT be represented as profiles.
The Apple Silicon macOS platform profile, macOS native distribution profile, and macOS MLX Node runtime profile SHALL preserve the accepted all-in-one and split-role behavior applicable to each profile.
The first accepted Linux target SHALL be a Controller Host using operator-provided external Postgres and dispatching to admitted macOS MLX Nodes.
The Linux Controller profile MUST NOT be represented as supported until its Milestone 8 acceptance gates pass.
This requirement changes `SPEC.md` §§1.1, 1.4, 1.5, 4.1, 11, and 14.

#### Scenario: Mixed Linux Controller and Mac Node cluster

- **WHEN** the Linux Controller target undergoes the mixed-platform acceptance profile with an admitted macOS Node under the macOS MLX Node runtime profile through an authenticated Runtime Endpoint
- **THEN** the Controller may schedule compatible work to that Node under the same durable policy and trust requirements as a macOS Controller
- **AND** the Linux Controller is not required to provide a local accelerator runtime

#### Scenario: Existing Mac all-in-one deployment

- **WHEN** Orchard runs the all-in-one topology under the Apple Silicon macOS platform profile, macOS native distribution profile, and macOS MLX Node runtime profile
- **THEN** the accepted Mac app lifecycle, inference, DMG distribution, signing, and retained-state guarantees remain applicable
