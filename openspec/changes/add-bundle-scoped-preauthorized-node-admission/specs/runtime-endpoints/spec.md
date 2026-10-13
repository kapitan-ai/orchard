## MODIFIED Requirements

### Requirement: Colocated Production BEAM Retains Exact Pair Authorization

The Ubuntu single-host profile SHALL use the enrolled Production BEAM Operating
Model between its Controller and local Node Agent.
Both canonical names SHALL contain their distinct complete UUID and the host's
validated stable non-loopback RFC1918 IPv4 address.
The relationship SHALL require exact current Controller and Node Certificates,
Node Admission, trusted inventory, one active certificate-bound scoped Peer
Grant, current local and connection generations, restricted listeners, forced
disconnect obligations, and a fresh accepted Runtime Endpoint Observation.
A bundle-scoped admission preauthorization MAY authorize only the exact Node
Admission transaction; it SHALL NOT authorize the BEAM connection, create or
activate a Peer Grant, establish Runtime Endpoint availability, or make the
Node schedulable.
Loopback identity, localhost trust, a static or shared cookie, certificate-only
authorization, address-only trust, bundle possession, preauthorization state,
and automatic gRPC fallback MUST NOT satisfy any runtime requirement.
KAP-27 outbound-session semantics MUST NOT be introduced.
Authenticated topology and separation implementation and qualification SHALL
remain held until real KAP-84 mixed-host evidence and their separately
authorized gates pass.

#### Scenario: Colocated BEAM authentication succeeds

- **WHEN** both services use their trusted private-address canonical names and every current certificate, admission, Peer Grant, generation, and network gate passes
- **THEN** the Controller may accept a fresh Runtime Endpoint Observation from the local Node
- **AND** ordinary scheduler and dispatch eligibility remains independently enforced

#### Scenario: Preauthorization exists without runtime authority

- **WHEN** an Enrollment has a current or consumed admission preauthorization but certificate, active Peer Grant, connection generation, or authenticated observation evidence is absent
- **THEN** the Runtime Endpoint remains unavailable and unschedulable
- **AND** Orchard does not infer the missing authority from colocation or admission intent

#### Scenario: BEAM operation fails on the local host

- **WHEN** a same-host BEAM Runtime Endpoint operation fails before, during, or after ambiguous acceptance
- **THEN** the failure remains visible on the BEAM path
- **AND** Orchard does not retry that operation through the gRPC compatibility adapter
