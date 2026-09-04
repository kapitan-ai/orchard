## ADDED Requirements

### Requirement: Managed Activation Requires Coordinated Controller and Host Authority

The Controller SHALL own Node maintenance, drain completion, allocation absence, health eligibility, and uncordon.
The host lifecycle SHALL own local operation serialization, launch suppression, process custody, byte activation, local verification, and local start.
Neither authority SHALL infer the other's acknowledgement from local state.

#### Scenario: Operator requests a managed transition

- **WHEN** an authorized operator requests a managed composition transition
- **THEN** Orchard SHALL coordinate distinct Controller and host lifecycle decisions under one operation identity
- **AND** SHALL preserve evidence for both authorities

### Requirement: Controller Maintenance Precedes Host Mutation

The Controller SHALL place the Node in maintenance, prevent new allocations, drain existing allocations, and issue a fresh authenticated acknowledgement before host mutation begins.
The acknowledgement SHALL bind the Node, operation, intended incoming composition, maintenance state, and allocation observation.

#### Scenario: Node is drained and unschedulable

- **WHEN** the Controller has entered maintenance and observes no active allocations for the transition operation
- **THEN** it MAY issue the acknowledgement required by host preflight

#### Scenario: Acknowledgement is stale or allocations remain

- **WHEN** the acknowledgement is stale, belongs to another operation or composition, or active allocations remain
- **THEN** the host lifecycle SHALL refuse mutation

### Requirement: Uncordon Is Explicit and Post-Health

Local start SHALL NOT make a Node schedulable.
The Controller SHALL uncordon only after it observes the expected composition identity, retained Node identity, compatible Runtime Endpoint and Worker Runtime state, and required health checks.
Uncordon SHALL require separate authority from host activation.

#### Scenario: New composition is healthy and expected

- **WHEN** the Controller observes the expected composition and Node identity and all compatibility and health gates pass
- **THEN** an authorized uncordon MAY make the Node schedulable

#### Scenario: Local process is healthy but identity differs

- **WHEN** a process responds successfully but reports an unexpected composition or Node identity
- **THEN** the Controller SHALL keep the Node in maintenance

### Requirement: Failure Keeps Maintenance Sticky

Activation failure, start failure, rollback, recovery, host disconnect, Controller disconnect, timeout, or uncertainty SHALL NOT clear maintenance automatically.
An authorized recovery or repair action SHALL precede any later uncordon.

#### Scenario: Controller loses contact during host activation

- **WHEN** Controller contact is lost after maintenance acknowledgement
- **THEN** the host SHALL continue only through locally safe stopped states or fail closed
- **AND** the Controller SHALL retain maintenance when contact returns
