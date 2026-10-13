## Context

Node enrollment already proves CSR possession and issues an exact cluster/Node
URI-SAN certificate. ADR 0012 already defines certificate-bound pair grants,
canonical BEAM names, one active plus one staged grant, and deliberate
disconnect. The gaps are lifecycle orchestration and exact timing, custody,
reconnect, restart, and stale-result rules.

This change stays inside the Controller-routable private network. The retained
certificate-authenticated control path handles enrollment, renewal, grant
delivery, and recovery; production Runtime Endpoint traffic remains stock OTP
TLS Distribution. No operation can silently switch transports.

## Goals / Non-Goals

**Goals:**

- Complete Node certificate issuance, renewal, overlap, revocation, and recovery.
- Make local current/staged generations crash-safe and owner-only.
- Complete pair-specific Peer Grant staging, cutover, disconnect, and recovery.
- Bound reconnect without inventing a durable session protocol.
- Reject stale observations across credential rotation, disconnect, and restart.

**Non-Goals:**

- Outbound WSS/HTTP2 sessions, NAT traversal, public remote-session ingress, or
  another Runtime Endpoint transport.
- Session IDs, delivery generations, replay envelopes, output resumption, or
  transport flow control.
- Worker Runtime incarnation, Worker Units, Resource Allocations, residency,
  provider/model work, or KAP-18 completion.
- Active/Standby redesign or real mixed-platform qualification.

## Decisions

### Authority is a conjunction rechecked at use

Stable Node ID and current certificate are transport-neutral identity. A
production BEAM connection additionally requires exact Controller identity,
canonical names and targets, one current pair grant, private-network policy,
and current lifecycle state. Every protected production BEAM operation and BEAM
observation commit rechecks this conjunction. Enrollment uses enrollment
authority and key-possession proof; certificate lifecycle and recovery use
their explicitly authorized control or operator-recovery path. Prior
reachability is never authority.

KAP-28 owns whether admission is granted. This change consumes current
admission where the existing production BEAM contract requires it but does not
change admission policy.

### Timing favors early renewal and bounded overlap

The existing 90-day certificate lifetime and 30-day renewal threshold leave
time for offline operators without keeping two accepted credentials current for
the entire renewal lead. The successor may be issued during that lead but may
remain accepted as staged alongside its predecessor for at most seven days from
atomic staged publication and never beyond predecessor expiry. Signed validity
overlap before staged publication is not accepted authority. Seven days matches
the existing normal Peer Grant rotation lead and keeps one coordinated cutover
window. If cutover remains incomplete at the overlap deadline, predecessor and
staged-successor authority cease for protected use; only separately
authenticated recovery remains available.

Five minutes is the maximum clock uncertainty. Issuance may backdate `notBefore`
by at most that bound. With Controller time represented as a bounded interval,
activation waits until the interval's earliest possible time reaches
`notBefore`, while expiry and other terminal deadlines apply when its latest
possible time reaches the deadline. Uncertainty may shorten authority but never
extend it. An established connection is disconnected at the earliest credential
or grant terminal boundary because TLS does not expire a live connection by
itself.

### Local generation publication is crash-safe

Each certificate generation contains the private key, certificate chain,
identity metadata, immutable generation, and integrity metadata. It is created
under an owner-only staging directory, pair-validated, fsynced, and atomically
renamed. A separate atomically published marker selects current and staged
generations. Symlinks and ambiguous/multiple staged generations fail closed.

Peer Grant plaintext remains separately stored per exact Controller pair under
the same identity-root custody rules. Postgres retains only grant scope,
lifecycle evidence, and a secret hash.

### Reconnect is liveness restoration, not replay

Equal-jitter exponential backoff starts with a 250 ms ceiling, doubles to a
30-second ceiling, and selects each delay from half to all of the current
ceiling. It resets only after exact successor authentication and acceptance of
a fresh observation after cutover, or after exact current-credential
authentication and a fresh observation when no cutover occurred. Loss of
authority stops attempts; network unavailability keeps the endpoint unavailable
while attempts continue at the bounded ceiling.

No reconnect state identifies or resumes an inference operation. Ambiguous
operations retain their existing failure and reconciliation contracts.

### Use native connection identity before adding a field

The first implementation tests delayed observations across disconnect,
certificate/grant cutover, Node restart, and Controller restart. Acceptance
requires the Runtime Endpoint adapter to capture native BEAM connection
identity and current credential/grant generations before the operation and
compare them again before committing its observation.
The matrix includes connection replacement after response receipt but before
durable commit, reconnect with unchanged credentials, Node restart, and
Controller restart.

If stock OTP cannot expose a stable-enough connection identity to make those
tests pass, implementation stops. A follow-up OpenSpec amendment may propose a
random ephemeral Agent-boot incarnation carried only by authenticated
observations. No field is added by this proposal, and any later field is barred
from becoming durable Node identity, a replay key, a session ID, or a Worker
allocation incarnation.

### Version skew is capability refusal

`N`/`N-1` compatibility is allowed only when both sides preserve exact
certificate, grant, connection, cutover, and no-replay semantics. A peer that
cannot represent or check a required generation remains disconnected or
observation-ineligible. KAP-84 owns real macOS/Linux qualification.

## Failure and recovery

- Invalid enrollment token, CSR signature, URI SAN, key possession, cluster, or
  Node binding fails before certificate issuance.
- Crash before staged publication preserves current. Crash after complete
  publication recovers exactly current plus at most one staged generation.
- Revocation and decommission remove current authority before best-effort
  disconnect and remain visibly incomplete until the peer is gone.
- Certificate or authorization-root compromise revokes every bound grant and
  requires explicit reissuance; it never rotates silently from untrusted state.
- Node or Controller restart reloads only complete current authority and never
  accepts a delayed result from the predecessor connection.
- More than five minutes of clock uncertainty or loss of authoritative state
  makes the endpoint unavailable and blocks reconnect.

## Migration Plan

Land and accept this contract first. Then implement transport-neutral
certificate persistence and authority checks, followed by Peer Grant staging
and cutover, reconnect supervision, stale-observation tests, and diagnostics.
Keep each behavior default-off until its complete failure matrix passes.

The accepted `add-linux-node-platform-contract` change is an archive/sync
predecessor because this change modifies its `linux-node-platform` capability.

Do not add an ephemeral boot-incarnation field unless the required native BEAM
tests first demonstrate a concrete stale-observation escape and a reviewed
OpenSpec amendment is accepted.

## Open Questions

Repository Owner acceptance is required for the proposed seven-day certificate
overlap, five-minute clock uncertainty, retained 30-day renewal lead, forced
disconnect at certificate expiry, and reconnect backoff constants before source
implementation.
