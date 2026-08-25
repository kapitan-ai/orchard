# platform-profiles Specification

## Purpose

Defines the portable Orchard control-plane core dependency boundary, qualified profile composition and support gates, the distinction between Controller Hosts and schedulable Nodes, and provider-neutral vocabulary for heterogeneous runtimes and resources.

## Requirements

### Requirement: Portable Orchard Control-Plane Core Dependency Contract
`orchard_shared`, `orchard_controller`, `orchard_node_agent`, and the portable `orchard_cli` SHALL compile and run their platform-neutral tests on Linux validation hosts without Xcode, `xcrun`, launchd, MLX, CUDA, or platform-native helper compilation.
Portable Orchard control-plane core modules MUST NOT depend on host adapters, runtime-provider implementations, platform packaging, or vendor SDKs.
Platform and provider implementations SHALL depend inward on portable contracts.
This requirement changes the product-wide macOS assumption in `SPEC.md` §§1.4, 2, and 14.

#### Scenario: Controller-only Linux development
- **WHEN** a contributor compiles and tests the portable Orchard control-plane core in the Linux portability validation lane
- **THEN** the workflow does not require Apple or accelerator toolchains
- **AND** no platform-native host artifact is compiled as an unconditional umbrella child

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

### Requirement: Controller Hosts And Schedulable Nodes Are Distinct
Orchard SHALL model a Controller Host independently from a schedulable Node.
A Node SHALL represent an admitted host running a Node Agent and advertising versioned runtime and device capabilities; it MUST NOT be defined solely as an Apple Silicon Mac.
A Controller Host SHALL NOT become schedulable unless it also satisfies the Node admission and capability contract.
This requirement changes `SPEC.md` §§1.1 and 4.1.

#### Scenario: Linux Controller has no Node Agent
- **WHEN** a Linux Controller Host runs without an admitted local Node Agent
- **THEN** it participates in Controller leadership and durable orchestration
- **AND** the scheduler does not create a local inference candidate for that host

### Requirement: Heterogeneous Runtime Vocabulary
Orchard SHALL represent artifact format, runtime provider, acceleration implementation, and device resource as distinct concepts.
Portable policy and scheduling MUST NOT infer one concept from another or branch on an operating-system name.
This requirement changes `SPEC.md` §§1.5, 4.1, 5.5, 6.4, and 8.2.

#### Scenario: One artifact supports multiple providers
- **WHEN** a model artifact is compatible with more than one runtime provider or acceleration implementation
- **THEN** Orchard records and evaluates each compatibility independently
- **AND** the artifact format is not rewritten as a provider name
