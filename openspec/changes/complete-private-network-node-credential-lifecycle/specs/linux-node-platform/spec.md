## MODIFIED Requirements

### Requirement: Linux Connectivity Uses Existing Private-Network Contracts

The experimental Linux Node candidate SHALL use the transport-neutral Node
credential lifecycle plus production OTP TLS Distribution with exact
certificate-bound pair-specific Peer Grants. Certificate-authenticated gRPC
SHALL remain only for enrollment, credential lifecycle, grant delivery and
recovery, diagnostics, and explicit compatibility roles retained by the
existing contract.

Reconnect SHALL mean authenticated BEAM reachability and a fresh observation
for the same persisted Linux Node and Controller IDs at a Controller-routable
private-network target. It SHALL revalidate current certificate, local-identity,
admission, canonical target, Peer Grant, and connection generations and SHALL
use bounded backoff. Reconnect without a cutover MAY reuse still-current
credentials; after a committed cutover it SHALL accept only the successor
generations. It SHALL NOT add outbound-only sessions, Internet-exposed
Node listeners, NAT/proxy/firewall traversal, another Runtime Endpoint
transport, automatic fallback, operation replay, output resumption, or a
durable session identity.

This refines `SPEC.md` §§7.5.0 and 10.6 without changing the candidate's support
or KAP-84 mixed-platform qualification gates.

#### Scenario: Private-network Node reconnects with current authority

- **WHEN** the trusted Linux Node target is directly routable and the exact currently authorized credential and Peer Grant generations are current
- **THEN** bounded reconnect may restore authenticated BEAM reachability for the same persisted Node and Controller IDs
- **AND** scheduler availability remains absent until a fresh current-connection observation is accepted

#### Scenario: Private-network boundary is not met

- **WHEN** reaching the Linux Node requires public ingress, NAT traversal, a proxy tunnel, or an outbound persistent session
- **THEN** this candidate remains unavailable
- **AND** Orchard does not reopen KAP-27 or claim general remote Linux support
