## ADDED Requirements

### Requirement: Shared-cookie Source-dev BEAM Address Policy
Shared-cookie Source-dev BEAM SHALL apply one IPv4 address policy to Controller and Node Agent `ORCHARD_BEAM_NODE_NAME` hosts, the Source-dev Controller membership host, and `ORCHARD_RUNTIME_ENDPOINT_TARGETS` hosts.
The policy SHALL accept RFC1918 private-use addresses and shared CGNAT `100.64.0.0/10` by default.
The policy SHALL accept loopback only for same-host Source-dev use.
Operators SHALL be able to add trusted IPv4 CIDRs, including explicitly authorized globally routable prefixes, through `ORCHARD_SOURCE_DEV_BEAM_ALLOWED_CIDRS`.
An added `/0` CIDR MUST be rejected as unrestricted.
Added policy CIDRs SHALL authorize configured identities and targets but SHALL NOT replace the exact-host Runtime Endpoint connection guardrails derived from configured targets.
Malformed CIDR segments MUST abort startup and name the offending setting and segment.
Malformed host IPv4 values, hostnames including Tailscale MagicDNS, IPv6, unspecified or wildcard addresses, multicast, and the limited-broadcast address MUST be rejected.
Enrolled production and BEAM Peer Grant identity validation MUST NOT inherit the Source-dev policy or its operator additions.
Rejection errors SHALL name the address classes and configuration setting accepted by the path that rejected startup.
This refines Source-dev BEAM Runtime Endpoint behavior in `SPEC.md` §1.2 and §7.5 without changing their production identity and private-network requirements.

#### Scenario: Tailscale CGNAT IPv4 Controller and target are accepted by default
- **WHEN** shared-cookie Source-dev BEAM uses Controller membership and node-name IPv4 literals plus a Runtime Endpoint target within `100.64.0.0/10`
- **THEN** Orchard accepts those configured hosts without an additional CIDR setting
- **THEN** Orchard derives Runtime Endpoint connection guardrails from the exact configured target hosts

#### Scenario: Tailscale MagicDNS remains unsupported
- **WHEN** a shared-cookie Source-dev identity or target uses a Tailscale MagicDNS hostname
- **THEN** Orchard rejects startup and directs the operator to use an accepted IPv4 literal

#### Scenario: Operator-authorized internal network is accepted
- **WHEN** `ORCHARD_SOURCE_DEV_BEAM_ALLOWED_CIDRS` contains a valid IPv4 CIDR and a shared-cookie Source-dev identity or target is inside that CIDR
- **THEN** Orchard accepts that configured host under the Source-dev address policy
- **THEN** Orchard does not admit other hosts from that CIDR unless they are configured as Runtime Endpoint targets

#### Scenario: Globally routable operator network warns about exposure
- **WHEN** `ORCHARD_SOURCE_DEV_BEAM_ALLOWED_CIDRS` authorizes a globally routable prefix used by a shared-cookie Source-dev identity or target
- **THEN** Orchard emits a startup warning that names the EPMD and BEAM Distribution exposure
- **THEN** operator guidance requires host firewall or network ACL rules that restrict those ports to configured peers

#### Scenario: Unrestricted or malformed policy CIDR is rejected
- **WHEN** `ORCHARD_SOURCE_DEV_BEAM_ALLOWED_CIDRS` contains `/0` or a malformed segment
- **THEN** Orchard rejects startup and names the offending setting and segment

#### Scenario: Globally routable address requires explicit authorization
- **WHEN** a shared-cookie Source-dev identity or target uses a globally routable IPv4 address outside the built-in and operator-configured CIDRs
- **THEN** Orchard rejects startup before Runtime Endpoint work begins
- **THEN** the error names RFC1918, Tailscale CGNAT `100.64.0.0/10`, same-host loopback where applicable, and `ORCHARD_SOURCE_DEV_BEAM_ALLOWED_CIDRS`

#### Scenario: Invalid host class remains rejected
- **WHEN** a shared-cookie Source-dev identity or target uses an unspecified, wildcard, multicast, limited-broadcast, malformed, hostname, or IPv6 value
- **THEN** Orchard rejects startup even when an operator-configured CIDR could otherwise contain the address

#### Scenario: Controller membership and node name disagree
- **WHEN** the Source-dev Controller membership host differs from the Controller `ORCHARD_BEAM_NODE_NAME` host
- **THEN** Orchard rejects startup even when both hosts are individually accepted by the Source-dev address policy

#### Scenario: Peer Grant identity remains strict
- **WHEN** BEAM Peer Grant mode uses a CGNAT, loopback, globally routable, or Source-dev operator-authorized address as its Controller or Node identity
- **THEN** Orchard rejects that identity under the existing RFC1918 non-loopback Peer Grant policy
