## ADDED Requirements

### Requirement: Worker reasoning evidence is bound to one loaded artifact

A future Worker Runtime reasoning envelope SHALL be scoped to exactly one `WorkerLoadedBinding` and one `service_incarnation`. Each complete advertised tuple SHALL match that binding's artifact digest and resolve its selected profile exactly once in the enclosing capability envelope. A present incomplete envelope, duplicate or conflicting tuple, unknown required value, or missing loaded binding SHALL prove no reasoning support rather than legacy omission.

The accepted future encoding lifts the deferred `WorkerCapabilities.loaded_binding` allocation at field 8, adds its sibling reasoning envelope at field 9, and shares cross-boundary definitions through `proto/cluster/v1/reasoning.proto`. This acceptance delta does not add those source declarations.

Load replacement, unload, failed destructive unload, or Worker Runtime teardown SHALL invalidate advertised reasoning evidence and any preparation authorization for the affected loaded instance.

#### Scenario: Same worker process reloads an artifact

- **WHEN** the Worker Runtime reloads an artifact without changing `service_incarnation`
- **THEN** prior reasoning evidence and preparation authorization are invalid
- **AND** the Worker must publish fresh evidence for the new loaded binding before negotiated execution

#### Scenario: Terminal failure has known zero output

- **WHEN** a Worker-originated terminal failure proves exact cumulative output usage of zero
- **THEN** the future presence-aware failure usage field is present with zero
- **AND** absence remains distinct missing evidence
