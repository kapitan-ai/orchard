## Context

The deterministic KAP-82 gate connects, disconnects, and reconnects the same
canonical BEAM name without rotating credentials or its active Peer Grant. Both
`BeamClient` values contain the same Node atom, target, authenticated peer, and
server module. OTP exposes no stable value in this path that distinguishes the
predecessor connection's response at the Controller's commit boundary.

## Decision

Generate 128 random bits for each authenticated private-network BEAM connection and
encode them as unpadded base64url. Return that value as
`agent_connection_incarnation` in authenticated status only. It is never loaded from
or written to disk.

The Controller captures the value from the response alongside exact certificate
and Peer Grant generations. The authenticated observation transaction compares
it with the latest incarnation accepted for the same live connection before
mutating Node health, heartbeat, diagnostic inventory, or capacity evidence.
Connection replacement clears the live value before reconnect. The first fresh
observation after exact authentication establishes the value for that
connection; a delayed observation carrying the predecessor value fails closed.

Disconnect invalidation and observation commit serialize through one
process-local exact-pair connection registry. Controller restart begins with no
live incarnation and requires fresh exact authentication plus a new observation.
Node Agent restart necessarily creates a new connection and value. Neither case
reconstructs it from heartbeat rows or prior Node inventory.

## Boundaries

- The value is ephemeral liveness evidence, not stable Node identity.
- It does not identify a request, operation, output stream, delivery attempt,
  Worker Unit, Resource Allocation, or Worker Runtime.
- It cannot authorize a connection without current certificate, grant, names,
  lifecycle, and admission authority.
- It is not a KAP-27 session ID and creates no replay or resume behavior.
- KAP-84 retains real mixed-version qualification ownership.

## Alternatives rejected

- Native Node atom: unchanged across the proven reconnect case.
- PID or monitor reference: remote status response does not provide a durable
  commit-time connection fence and process identity is not authority.
- Credential or grant rotation on every transient reconnect: violates the
  accepted unchanged-authority reconnect contract and creates unnecessary
  durable authority churn.
- Universal session protocol: exceeds KAP-82 and reopens canceled KAP-27 scope.
