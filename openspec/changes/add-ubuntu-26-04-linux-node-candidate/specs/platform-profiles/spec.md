## MODIFIED Requirements

### Requirement: Qualified Profiles And Support Gates

Orchard SHALL define platform, distribution, runtime-provider, and acceptance
profiles as qualified, composable concepts.
A platform profile SHALL bind host roles to an operating system, architecture,
and platform acceptance evidence.
A distribution profile SHALL bind a platform profile and install roles to
deployment artifacts, host lifecycle, paths, credential storage, update and
rollback behavior, retained state, and release evidence.
A runtime-provider profile SHALL bind a Node role to a Worker Runtime provider,
compatible acceleration and device resources, provider-neutral conformance, and
real-runtime acceptance.
A runtime-provider profile MUST NOT make the portable Node Agent
provider-specific.
An acceptance profile SHALL define a named topology and the evidence required
to prove its participating profiles operate together.
Host-lifecycle adapters and deployment artifacts MUST NOT be represented as
profiles.
Defining or accepting a profile SHALL NOT be represented as a support claim
before its applicable acceptance evidence and gates pass.
The Apple Silicon macOS platform profile, macOS native distribution profile,
and macOS MLX Node runtime profile SHALL preserve the accepted all-in-one and
split-role behavior applicable to each profile.
Managed Database Mode and Active/Standby operation SHALL remain future
milestone work rather than current topology support claims.
The first accepted Linux target SHALL be a Controller Host using
operator-provided external Postgres and dispatching to admitted macOS MLX Nodes.
The Linux Controller profile MUST NOT be represented as supported until its
Milestone 8 acceptance gates pass.
Orchard SHALL enumerate `ubuntu_24_04_x86_64_node` and
`ubuntu_26_04_x86_64_node` as separate experimental Linux Node candidates.
Qualification and support evidence SHALL apply to one exact candidate and SHALL
NOT create a generic Ubuntu or Linux profile.
This requirement changes `SPEC.md` §§1.1, 1.4, 1.5, 4.1, 11, and 14.

#### Scenario: Mixed Linux Controller and Mac Node cluster

- **WHEN** the Linux Controller target undergoes the mixed-platform acceptance profile with an admitted macOS Node under the macOS MLX Node runtime profile through an authenticated Runtime Endpoint
- **THEN** the Controller may schedule compatible work to that Node under the same durable policy and trust requirements as a macOS Controller
- **AND** the Linux Controller is not required to provide a local accelerator runtime

#### Scenario: Existing Mac all-in-one deployment

- **WHEN** Orchard runs the all-in-one topology under the Apple Silicon macOS platform profile, macOS native distribution profile, and macOS MLX Node runtime profile
- **THEN** the accepted Mac app lifecycle, inference, DMG distribution, signing, and retained-state guarantees remain applicable

#### Scenario: Ubuntu 26.04 candidate is accepted but unqualified

- **WHEN** the profile contract is accepted before real 26.04 lifecycle and mixed-host evidence passes
- **THEN** Orchard describes it as an experimental candidate
- **AND** does not claim Ubuntu 26.04 or general Linux Node support

#### Scenario: One Ubuntu candidate qualifies

- **WHEN** one enumerated candidate satisfies its applicable gates
- **THEN** evidence applies only to that exact candidate
- **AND** the other candidate and all unenumerated Ubuntu releases remain unqualified
