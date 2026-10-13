## MODIFIED Requirements

### Requirement: Runtime Endpoint Observations

The Controller SHALL record Runtime Endpoint Observations as durable snapshots
of endpoint status, capability, availability, Placement Capacity, and placement
signals. Runtime Endpoint Observations SHALL be transport-independent.

For an authenticated first-party BEAM endpoint, observation acceptance SHALL
capture the native connection identity and current certificate, local-identity,
Peer Grant, and connection generations before the operation and revalidate them
before durable commit. A result from a disconnected, superseded, restarted, or
reauthenticated connection SHALL be stale even when the persisted Node ID and
BEAM name are unchanged. No custom boot-incarnation field SHALL be added unless
deterministic native-BEAM tests first prove that these fences cannot reject a
delayed observation and a separate OpenSpec amendment is accepted.

This replaces the current first-party dependence on `StatusResponse` as the
active observation seam in `SPEC.md` §§4.6.1 and 7.5 and refines §7.5.0.

#### Scenario: First-party status is observed

- **WHEN** a Node Agent reports runtime status through the Runtime Endpoint Interface under current authenticated connection authority
- **THEN** the Controller records a Runtime Endpoint Observation in Postgres using transport-independent fields

#### Scenario: Transport-specific field is absent

- **WHEN** a first-party BEAM Runtime Endpoint reports status without protobuf fields
- **THEN** the Controller still records equivalent Runtime Endpoint Observation data

#### Scenario: Address-only BEAM observation lacks persisted identity proof

- **WHEN** a BEAM Runtime Endpoint Observation is recorded from a target that cannot resolve back to the same persisted node identity
- **THEN** the Controller does not publish queue capacity from that observation
- **AND** stale queue capacity sources for the unresolved target remain unavailable for promotion

#### Scenario: Observation completes after connection replacement

- **WHEN** a status operation began on a connection that was disconnected or superseded before observation commit
- **THEN** the Controller rejects the result as stale
- **AND** reconnect requires a new authenticated observation without replaying the old operation

### Requirement: First-party BEAM Transport Guardrails

Orchard SHALL validate first-party BEAM Distribution guardrails before
production BEAM Runtime Endpoint transport can be enabled. First-party Orchard
Runtime Endpoints MAY use BEAM Distribution as a default-off live communication
and monitoring layer between admitted Elixir services. Production BEAM
Distribution MUST be explicitly configured, identity-bound,
network-restricted, and limited to admitted first-party Orchard services.
External Runtime Endpoints MUST NOT join the first-party BEAM mesh.

Reconnect SHALL restore authenticated BEAM reachability plus a fresh accepted
observation for the same persisted Node and Controller IDs. It SHALL use the
currently authorized certificate and active exact pair-grant generations with
bounded backoff; after a committed cutover, only its successor generations are
current. It
SHALL NOT add outbound WSS/HTTP2, NAT/proxy traversal, public remote-session
ingress, operation replay, output resumption, a durable session identity, or
automatic gRPC inference fallback.

This changes the base `SPEC.md` §1.2 language and refines §§7.5 and 10.6.

#### Scenario: First-party BEAM endpoint is enabled

- **WHEN** an admitted first-party Node Agent participates in production runtime communication through the BEAM adapter
- **THEN** it communicates with the Controller only through explicitly configured first-party BEAM transport
- **AND** the Controller still records durable Runtime Endpoint Observations in Postgres

#### Scenario: BEAM target identity is validated

- **WHEN** a configured BEAM Runtime Endpoint target has a node-name address and node identity
- **THEN** the address is validated as a BEAM node name
- **AND** the node identity is validated as a UUID
- **AND** scheduler and dispatch trust the identity only when observed endpoint metadata matches the configured identity

#### Scenario: First-party BEAM endpoint reconnects without a cutover

- **WHEN** current unchanged credentials remain authorized and the trusted private-network target becomes reachable
- **THEN** the same persisted Node and Controller identities may restore authenticated BEAM reachability with bounded backoff
- **AND** availability returns only after a fresh current-connection observation is accepted

#### Scenario: External endpoint remains outside BEAM mesh

- **WHEN** a future provider-backed Runtime Endpoint is configured
- **THEN** it integrates through a Runtime Endpoint adapter
- **AND** it does not join first-party BEAM Distribution
