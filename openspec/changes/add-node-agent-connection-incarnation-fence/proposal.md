# Change: Add an ephemeral authenticated-connection observation fence

## Why

KAP-82's required deterministic unchanged-authority reconnect test proves that
stock OTP reconnects the same canonical BEAM Node atom while `BeamClient`
captures no per-connection identity. Certificate and Peer Grant generations
also remain unchanged during an ordinary reconnect. A status response received
before disconnect is therefore indistinguishable at durable commit from one
received after reconnect.

The accepted credential-lifecycle contract requires implementation to stop at
this concrete escape and obtain separate review before adding a field. Review
also established that a value generated only once per Agent boot is
insufficient for reconnects during that same boot.

## What Changes

- Generate one random, process-ephemeral incarnation for each authenticated
  private-network BEAM connection; Agent boot begins with no accepted value.
- Include it only in authenticated Runtime Endpoint status observations.
- Capture it with certificate and Peer Grant generations before an observation
  request and require the same incarnation at durable commit.
- Reject a missing, malformed, changed, or predecessor incarnation as stale.
- Treat version-skew peers that cannot preserve the fence as
  observation-ineligible.

The incarnation is not persisted as Node identity, used for operation replay,
accepted as authority by itself, or shared with Worker Runtime allocation
incarnation.

## Impact

- Affected specs: `node-credential-lifecycle`
- Affected code: Node Agent status envelope, Controller BEAM client, authenticated
  observation transaction, deterministic restart/reconnect tests
- No KAP-27 session/delivery semantics, operation retransmission, output resume,
  allocation ownership, provider activation, or new transport
