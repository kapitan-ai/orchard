## ADDED Requirements

### Requirement: Managed Apple Silicon macOS Node Is a Narrow Profile Specialization

Orchard SHALL define `managed_apple_silicon_macos_node` as a Node-role specialization of the existing macOS native distribution profile and the macOS MLX Node runtime profile.
The profile SHALL require Apple Silicon macOS, the signed app and DMG lifecycle, Controller maintenance coordination, the managed launch-domain adapter, and a verifier-admitted managed Node composition.
The profile SHALL NOT alter the support status of controller-only, all-in-one, Linux, WSL, Windows, Intel macOS, or ordinary source-development profiles.

#### Scenario: Managed Node profile is admitted

- **WHEN** the host, role, runtime, distribution, Controller-coordination, launch-domain, and composition requirements all match the named profile
- **THEN** Orchard MAY identify the installation as a Managed Apple Silicon macOS Node

#### Scenario: Another profile presents managed composition evidence

- **WHEN** a host or role outside the named profile presents a valid composition lock or build attestation
- **THEN** Orchard SHALL NOT infer that the managed profile or its support claim applies

### Requirement: Source Development Remains Foreground and Unmanaged

The managed profile SHALL NOT change `make dev`, `mise exec -- bin/dev`, or the source-development Node Agent host into background installation or managed-composition commands.
Source-development processes SHALL NOT be silently adopted into the managed launch domain.

#### Scenario: Operator runs source development

- **WHEN** an operator runs the documented foreground source-development command
- **THEN** the command SHALL retain foreground terminal custody and existing shutdown behavior
- **AND** SHALL NOT create or activate a managed composition implicitly
