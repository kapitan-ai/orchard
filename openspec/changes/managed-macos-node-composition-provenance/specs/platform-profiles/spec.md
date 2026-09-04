## ADDED Requirements

### Requirement: Managed Apple Silicon macOS Node Is Dedicated

Orchard SHALL reserve `managed_apple_silicon_macos_node` as an experimental dedicated Node-role transition specialization of the Apple Silicon macOS platform profile, macOS native distribution profile, and macOS MLX Node runtime profile.
It SHALL NOT be operator-acquirable or described as supported until every production-admission prerequisite in this change is accepted and qualified.
The host SHALL run no Controller release, Controller launchd job, or all-in-one role while the managed profile is admitted or a managed transition generation exists.
The profile SHALL require the signed app and DMG lifecycle, exact stable bootstrap, fixed managed launch domain, external Controller coordination, and a verifier-admitted composition.

#### Scenario: Dedicated Node host is admitted

- **WHEN** the host, role, runtime, distribution, bootstrap, launch-domain, Controller, and composition evidence all match the named profile and no Controller role is present
- **THEN** Orchard MAY identify the installation as a Managed Apple Silicon macOS Node

#### Scenario: Controller role is selected or running

- **WHEN** the target host selects or runs a Controller or all-in-one role
- **THEN** Orchard SHALL reject managed profile admission and transition creation

### Requirement: V1 Profile Starts from a Managed Baseline

The v1 profile SHALL start from an immutable `exact_ref_source_build` baseline whose production provisioning is governed by a separate accepted clean-host contract.
This change SHALL NOT define, authorize, or claim support for that provisioning path.
It SHALL NOT adopt a generic app install, foreground source checkout, native PKG install, arbitrary active tree, or externally supervised Node Agent.

#### Scenario: Existing unmanaged installation is presented

- **WHEN** a host lacks the exact managed baseline, stable bootstrap, active pointer, frozen identity set, or Controller admission evidence
- **THEN** Orchard SHALL refuse v1 transition instead of deriving or synthesizing a baseline

#### Scenario: Provisioning contract is not accepted

- **WHEN** no separate accepted production provisioning contract has established the managed baseline and profile marker
- **THEN** Orchard SHALL keep production admission and support claims blocked

### Requirement: Source Development Remains Foreground and Unmanaged

The managed profile SHALL NOT change `make dev`, `mise exec -- bin/dev`, or the source-development Node Agent host into background installation or managed-composition commands.
Source-development processes SHALL NOT be adopted into the managed launch domain.

#### Scenario: Operator runs source development

- **WHEN** an operator runs the documented foreground source-development command
- **THEN** the command SHALL retain foreground terminal custody and existing shutdown behavior
- **AND** SHALL NOT create a managed baseline or transition implicitly
