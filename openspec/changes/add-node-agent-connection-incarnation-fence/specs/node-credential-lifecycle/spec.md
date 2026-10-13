## ADDED Requirements

### Requirement: Authenticated Observations Fence Connection Incarnation

Each authenticated private-network Node Agent status observation SHALL carry a
random 128-bit ephemeral connection incarnation. The incarnation SHALL be
generated for each authenticated BEAM connection, SHALL NOT be persisted, and
SHALL change after reconnect or Node Agent restart. The Controller SHALL accept an
observation commit only when its captured incarnation still belongs to the
currently authenticated BEAM connection and exact current certificate and Peer
Grant generations.

The incarnation SHALL NOT become stable Node identity, a session ID, a replay
key, an operation or output identity, Worker Runtime incarnation, Worker Unit,
Resource Allocation, scheduling authority, or provider/model qualification.
It SHALL NOT resume output or authorize retransmission.

#### Scenario: Unchanged-authority reconnect replaces the connection

- **WHEN** the same Node and Controller reconnect with unchanged current certificate and Peer Grant generations
- **THEN** the successor has a different incarnation and the predecessor connection's incarnation is no longer current
- **AND** a delayed predecessor observation is rejected before any durable Node, heartbeat, diagnostic, or capacity mutation

#### Scenario: Node Agent restarts

- **WHEN** the Node Agent restarts under the same persisted Node identity and current credentials
- **THEN** its new authenticated connection has a new ephemeral incarnation
- **AND** every observation from the predecessor boot fails closed

#### Scenario: Controller restarts

- **WHEN** the Controller restarts with no live connection-incarnation state
- **THEN** prior heartbeat or inventory rows cannot reconstruct that state
- **AND** a fresh exact authentication and observation are required before reconnect completes

#### Scenario: Version-skew peer omits the fence

- **WHEN** a peer omits or cannot validate the connection incarnation
- **THEN** it is observation-ineligible and reconnect does not complete
- **AND** Orchard does not downgrade transport or infer the value from other evidence
