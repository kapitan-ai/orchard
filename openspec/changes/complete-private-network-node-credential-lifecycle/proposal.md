## Why

The accepted production BEAM contract defines exact certificates and scoped
Peer Grants, but its implemented tracer does not complete renewal, overlapping
local generations, normal rotation, connected-peer revocation, bounded
reconnect, or stale-observation rejection. KAP-82 previously pointed at the
canceled KAP-27 outbound-session design, which conflicts with the accepted
private-network Linux Node profile.

## What Changes

- Reframe KAP-82 as one contract-first credential and Peer Grant lifecycle with
  a transport-neutral Node credential layer and an existing private-network
  BEAM mechanics layer.
- Retain stable Node identity, CSR key-possession proof, exact certificate
  identity, current-authority checks, owner-only atomic local generations,
  audit, revocation, decommission, compromise recovery, and fail-closed clock
  behavior.
- Retain ADR 0012's pair-specific Peer Grant scope while specifying staged
  cutover, deliberate disconnect, current-generation reconnect that becomes
  successor-only after cutover, restart recovery, bounded backoff, and stale
  certificate/grant/connection rejection.
- Fix the proposed timing policy at a 90-day certificate lifetime, 30-day
  renewal lead, at most seven days of accepted-authority overlap from staged
  publication, five minutes of allowed clock uncertainty without expiry
  extension, and forced disconnect at certificate expiry.
- Define reconnect as authenticated BEAM reachability plus a fresh observation
  for the same persisted Node and Controller IDs on a Controller-routable
  private network, with no operation replay or output resumption.
- Require deterministic proof that native BEAM connection identity plus current
  credential and grant generations fence delayed observations before any
  ephemeral boot-incarnation field may be proposed.

## Capabilities

### New Capabilities

- `node-credential-lifecycle`: Defines transport-neutral Node certificate
  authority and the private-network BEAM Peer Grant lifecycle.

### Modified Capabilities

- `runtime-endpoints`: Defines current-generation reconnect, successor-only
  reconnect after cutover, and stale-observation fencing without adding a
  transport or replay contract.
- `linux-node-platform`: Composes the lifecycle into the experimental Linux
  Node candidate without changing its support or mixed-platform gates.

## Impact

- `SPEC.md` §§7.5.0, 10.5, 10.6, and Milestone 9 gain exact lifecycle and
  reconnect semantics.
- Proposed ADR 0035 refines ADR 0012 while preserving historical decisions.
- Implementation will affect Node enrollment PKI, certificate and Peer Grant
  persistence, Controller authority checks, Node Identity Root custody, BEAM
  connection supervision, Runtime Endpoint observation acceptance, diagnostics,
  and deterministic tests only after Repository Owner acceptance.
- KAP-28, KAP-18, KAP-26, KAP-84, and KAP-17 retain their owned policy,
  termination, allocation/incarnation, real mixed-platform, and local Worker
  transport claims.
- KAP-27 remains canceled and is not reopened or implemented.
- No provider, model, deployment, release, production activation, generic Linux,
  NAT, proxy, firewall-traversal, federation, or external-compute claim follows.
- The accepted `add-linux-node-platform-contract` change is a predecessor: its
  `linux-node-platform` capability SHALL be synced to the main specs before this
  change is archived, so this change modifies rather than recreates that
  capability.
