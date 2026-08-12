## Why

Source-dev BEAM currently conflates RFC1918 address classification with network trust, which rejects Tailscale CGNAT IPv4 literals and legitimate operator-routed networks while different configuration paths already enforce inconsistent rules.
Issue #193 requires one explicit Source-dev address policy without relaxing enrolled production or BEAM Peer Grant identity boundaries.

## What Changes

- Define one shared-cookie Source-dev BEAM address policy for local node names, Controller membership identity, and explicit Runtime Endpoint targets.
- Accept RFC1918 private-use IPv4 and Tailscale/shared CGNAT `100.64.0.0/10` by default.
- Allow operators to add trusted IPv4 CIDRs, including deliberately authorized globally routable prefixes, through a Source-dev-only configuration setting; globally routable use emits an exposure warning and requires network access controls.
- Keep loopback limited to same-host development and reject malformed, unspecified, wildcard, multicast, limited-broadcast, hostname, IPv6, and unrestricted `/0` values.
- Keep enrolled production and BEAM Peer Grant identity validation unchanged.
- Make rejection errors name the accepted address classes and reconcile tests plus `docs/local-dev.md` with the final boundary.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `runtime-endpoints`: Expand and unify the Source-dev BEAM address-policy requirements for shared-cookie identities and targets.

## Impact

- Source-dev configuration parsing and Controller membership resolution in `config/` and `apps/orchard_shared/`.
- Controller and Node Agent source-dev launch validation, including `bin/lib/source-dev-beam.sh`.
- Runtime Endpoint target guardrails and their configuration tests.
- Operator guidance in `docs/local-dev.md`.
- No change to `SPEC.md` production requirements: production private-network, trusted-inventory, certificate, and Peer Grant requirements remain unchanged; this change refines the Source-dev operating model described by §1.2 and §7.5.
