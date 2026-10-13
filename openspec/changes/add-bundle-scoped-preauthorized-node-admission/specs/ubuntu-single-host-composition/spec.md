## MODIFIED Requirements

### Requirement: Single-Host Composition Preserves Role Authority

The accepted `ubuntu_24_04_x86_64_single_host` profile SHALL compose one
Controller, one locally managed PostgreSQL 16 cluster, one separately enrolled
and admitted Node Agent, and only separately qualified Worker Runtimes on the
exact Ubuntu Server 24.04 LTS x86_64 host tuple.
Controller, PostgreSQL, Node Agent, and Worker Runtime SHALL retain distinct
non-login identities, writable roots, credentials, units, logs, cgroups, and
operational ownership.
The local Node MAY use a bundle-scoped preauthorization only when the durable
record binds its exact cluster, Enrollment, Node, installation UUID, platform
profile, source manifest, admission policy, and current trust predicates.
Colocation MUST NOT create enrollment, admission, leadership, dispatch,
execution, capacity, database-superuser, or release authority.

#### Scenario: Controller and Node are healthy on one host

- **WHEN** every local process and database readiness check succeeds
- **THEN** the Node remains unschedulable until its independent enrollment, admission, credential, Runtime Endpoint observation, lifecycle, health, and capacity gates pass
- **AND** PostgreSQL readiness does not become Controller or Node readiness

#### Scenario: Exact local preauthorization drifts

- **WHEN** the local Node's installation, source-manifest, policy, or trust predicate differs from the preauthorization at redemption
- **THEN** colocation does not preserve or recreate admission authority
- **AND** independently valid registration may end pending review without policy, grant, activation, or scheduling authority

#### Scenario: One role attempts another role's state

- **WHEN** a service identity attempts to read or mutate another role's private state, secret, or writable root
- **THEN** host permissions reject access
- **AND** locality supplies no alternate shared credential or directory
