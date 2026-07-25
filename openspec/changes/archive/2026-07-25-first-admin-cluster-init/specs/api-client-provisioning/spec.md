## ADDED Requirements

### Requirement: First Cluster-Admin Credential Provisioning
Orchard SHALL provision the first cluster-admin credential through `orchardctl cluster init` as a local, one-shot, audited controller-host operation.
`orchardctl cluster init` SHALL create a service-account-owned API Client holding a cluster-scoped `admin` RoleBinding and an API Token persisted as hash and prefix only.
The token secret SHALL be emitted exactly once through a required operator-chosen output path with preflight, following the One-time Secret Output requirements.
Initialization SHALL refuse with a stable `cluster_already_initialized` error when an enabled cluster-scoped `admin` RoleBinding already exists, and the one-shot guard SHALL be race-safe under concurrent initialization attempts.
An explicit recovery flag SHALL mint an additional admin credential without resetting, deleting, or mutating existing credentials, SHALL require confirmation, and SHALL record a cluster-scoped audit event.
Initialization SHALL execute under the local controller-runtime authority boundary with the leader-only write-path gate.
First-admin provisioning SHALL NOT be exposed as an Admin API endpoint, SHALL NOT be seeded by installer packaging, and SHALL NOT repurpose node-join Bootstrap Tokens.
This refines `SPEC.md` §10.1, §10.2, §11.4, and §11.9 per ADR 0011.

#### Scenario: Fresh cluster mints the first admin credential
- **WHEN** an operator runs `orchardctl cluster init` with a writable output path on a cluster with no enabled cluster-scoped `admin` RoleBinding
- **THEN** Orchard creates the service-account-owned API Client, cluster-scoped `admin` RoleBinding, and API Token in one transaction
- **AND** Orchard emits the token secret exactly once to the operator-chosen output path
- **AND** Orchard persists only the token hash and prefix
- **AND** Orchard records a cluster-scoped audit event

#### Scenario: Second initialization refuses
- **WHEN** an operator runs `orchardctl cluster init` on a cluster that already has an enabled cluster-scoped `admin` RoleBinding
- **THEN** Orchard refuses with the stable `cluster_already_initialized` error
- **AND** Orchard mutates no credential state

#### Scenario: Recovery mint is additive
- **WHEN** an operator runs `orchardctl cluster init` with the recovery flag and confirms
- **THEN** Orchard mints an additional admin credential
- **AND** Orchard does not reset, delete, or mutate existing credentials
- **AND** Orchard records a cluster-scoped audit event for the recovery mint

#### Scenario: Non-leader controller refuses
- **WHEN** an operator runs `orchardctl cluster init` on a standby controller or a configured leader without proven advisory-lock leadership
- **THEN** Orchard refuses through the shared leader-only write-path gate semantics
- **AND** Orchard mutates no credential state
