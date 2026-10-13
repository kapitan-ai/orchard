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
Loopback identity, localhost trust, a static or shared cookie, certificate-only
authorization, address-only trust, and automatic gRPC fallback MUST NOT satisfy
any requirement.
KAP-27 outbound-session semantics MUST NOT be introduced.
Implementation and qualification SHALL remain held while the applicable
credential-lifecycle decision, OpenSpec package, and qualification evidence
disagree or remain incomplete.

#### Scenario: Colocated BEAM authentication succeeds

- **WHEN** both services use their trusted private-address canonical names and every current certificate, admission, Peer Grant, generation, and network gate passes
- **THEN** the Controller may accept a fresh Runtime Endpoint Observation from the local Node
- **AND** ordinary scheduler and dispatch eligibility remains independently enforced

#### Scenario: BEAM operation fails on the local host

- **WHEN** a same-host BEAM Runtime Endpoint operation fails before, during, or after ambiguous acceptance
- **THEN** the failure remains visible on the BEAM path
- **AND** Orchard does not retry that operation through the gRPC compatibility adapter
