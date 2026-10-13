## MODIFIED Requirements

### Requirement: Ubuntu Source Lifecycle Uses Singleton Ordered Recoverable Phases

The Ubuntu single-host adapter SHALL prepare inert systemd units from the one
canonical source checkout and SHALL start PostgreSQL readiness, exclusive
compatible migration, Controller readiness, and Node Agent in that order.
It SHALL serialize lifecycle mutation through a root-owned lock and durable
monotonic receipts and SHALL expose partial, failed, and recovery-required state
without claiming a whole-appliance transaction.
It SHALL fail before mutation or start when another checkout, installation/state
identity, Controller, lock owner, listener/port, EPMD/BEAM name, PostgreSQL
cluster, or supervisor is live, foreign, or ambiguous and SHALL neither kill nor
adopt that owner.
Worker processes SHALL remain descendants in generation-scoped delegated
sub-cgroups of the Node Agent unit and MUST NOT start merely because the
appliance target is reached.
A narrow root launcher SHALL authenticate the local Node Agent, allow only an
immutable provider and generation from the active compatibility manifest, drop
to the dedicated Worker identity, and expose no general command, environment,
signal, device, cgroup, package, service-manager, or root API.
Agent stop or crash SHALL close the launch gate and kill the complete unit
cgroup before replacement Agent activation.
Service-manager, PID, cgroup, socket, and receipt observations SHALL NOT create
product identity, admission, readiness, execution, or capacity-release
authority.

#### Scenario: A dependent service fails during startup

- **WHEN** PostgreSQL, migration, Controller, or Node readiness fails
- **THEN** later dependants remain stopped or unschedulable
- **AND** systemd active state for an earlier unit does not make the appliance ready

#### Scenario: A foreign process owns a required listener

- **WHEN** preflight finds a live, foreign, replaced, or ambiguous listener on a required port
- **THEN** startup fails without killing or adopting the process
- **AND** the lifecycle receipt records a bounded non-secret conflict

#### Scenario: A second checkout claims the host

- **WHEN** a non-canonical checkout or different installation UUID claims any source, state, service, port, database, EPMD, or BEAM identity
- **THEN** preparation and startup fail before mutation
- **AND** only exact stale evidence owned by the canonical installation may enter bounded recovery

#### Scenario: Agent exits while a Worker survives

- **WHEN** the Agent root exits or its unit is stopped while a registered Worker descendant remains
- **THEN** the launch gate closes and systemd cleanup covers the complete Agent/Worker cgroup
- **AND** no replacement Agent starts until exact cgroup emptiness is proved
- **AND** cleanup does not independently prove request-slot or Resource Allocation release
