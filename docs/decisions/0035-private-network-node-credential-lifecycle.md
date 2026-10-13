# ADR: Complete the private-network Node credential and Peer Grant lifecycle

## Status

Accepted by the Repository Owner under KAP-82 on 2026-09-19 at contract commit
`ee8969087b1ce3ad119c8acf2b8856ca9edae394`. The owner-authorized review-history
replacement `48c8cc5a4fd09d4016831465e985b1e1bcc19574` preserves the exact accepted tree
`f31941a820571998a763a75726cef05e0219c2be`.

The separately accepted authenticated-connection incarnation amendment is
recorded at `c27e537c6175201ffa182a849338738244adbaa2`; rewritten commit
`c75ebd2c26b452fb7f3a681921709b8791f8a7e3` preserves its exact tree
`9cc1c29e8b677c45bf90dc14a19a2f0ec37846a9`. Local implementation and bounded
single-host evidence exist at `deded3ee6aad729babbd71700f9a7e46e1156f51`;
rewritten commit `3da861d91ea806d2e1a97eec115e9a81035c05a5` preserves its exact tree
`8f832a9cf795a9980e89b8faf49417b020636c49`.

KAP-84 real mixed macOS/Linux `N` and `N-1` qualification remains unmet. This
decision therefore establishes the accepted contract but does not qualify a
Linux Node, close KAP-82, or establish a support claim.

This decision refines ADR 0012 without replacing its scoped Peer Grant,
high-trust BEAM, Active/Standby, or no-fallback decisions. It does not reopen
the canceled outbound-session work recorded by KAP-27.

## Context

ADR 0012 and `SPEC.md` §7.5.0 define production OTP TLS Distribution plus a
certificate-bound, pair-specific BEAM Peer Grant. The first tracer proves
enrollment, exact identity, deterministic grant derivation, authenticated grant
delivery, active-peer expiry, and a narrow restart path. It does not complete
certificate renewal, overlapping credential custody, normal staged grant
rotation, connected-peer revocation, bounded reconnect, or stale-observation
fencing.

The experimental Linux Node profile must use this existing private-network
model. It must not substitute an outbound WSS/HTTP2 session, a new Runtime
Endpoint transport, or KAP-27 delivery and replay semantics. Reconnect is a
transport reachability event, not a durable operation session and not proof
that ambiguous work can be resumed.

The contract also needs exact timing policy. Node certificates currently have
a 90-day lifetime and `SPEC.md` starts renewal 30 days before expiry. Peer
Grants have a 30-day lifetime and start normal rotation 7 days before expiry.
Neither contract currently fixes the maximum certificate overlap, the allowed
clock uncertainty, or whether an established connection survives certificate
expiry.

## Decision

### Two layers remain distinct

The transport-neutral Node credential layer owns stable Node identity,
enrollment proof and private-key possession, certificate issuance and
lifecycle, exact cluster and Node binding, local credential custody, audit,
current-authority checks, and compromise recovery.

The private-network BEAM profile owns exact Controller-to-Node names and
targets, certificate-bound pair grants, staged grant cutover, explicit
connection replacement, reconnect, and BEAM-specific stale-connection
rejection. A Peer Grant is transport authorization, never durable Node identity
or operation identity.

### Certificate timing and current authority

Node certificates retain a 90-day default lifetime. Renewal eligibility begins
30 days before the current certificate expires. Issuance MAY backdate
`notBefore` by no more than five minutes to tolerate bounded clock uncertainty.
Endpoints SHALL treat more than five minutes of clock uncertainty as authority
loss and fail closed. Clock tolerance SHALL NOT extend `notAfter`, revocation,
decommission, grant expiry, or a scheduled cutover.

The accepted-authority overlap starts when the complete successor generation is
atomically published as `staged`; its deadline is the earlier of seven days
after that publication and the predecessor's `notAfter`. Signed certificate
validity alone does not establish accepted authority. During this interval,
exactly one local certificate generation is `current` and at most one is
`staged`. For a production BEAM relationship, the successor does not authorize
ordinary BEAM connections until its exact replacement Peer Grants are staged
and the scheduled cutover commits. Successful cutover supersedes the
predecessor. At an incomplete cutover's overlap deadline, predecessor authority
and successor staging authority both cease for protected use; only the
separately authenticated recovery path remains available.

Every established production BEAM connection SHALL be forcibly disconnected at
the earliest of certificate expiry, Peer Grant expiry, revocation,
decommission, superseding cutover, or loss of current authority. There is no
expiry grace for an established connection because TLS does not revalidate an
already established distribution connection.

Controller database time is authoritative for issuance, renewal eligibility,
revocation, decommission, and grant cutover. Each endpoint validates local
certificate time and rejects operation when its bounded relationship to
Controller time cannot be established. Given a bounded Controller-time
interval, activation requires its earliest possible time to meet `notBefore`,
while expiry and every other terminal deadline apply once its latest possible
time reaches the deadline. Uncertainty can therefore shorten authority but
never extend it.

### Crash-safe local custody

Node private keys are generated in the Node Identity Root and never leave it.
Enrollment and renewal require a CSR whose signature proves possession of the
corresponding private key and whose exact URI SAN binds the cluster and stable
Node IDs. Certificate and private-key generations are written to owner-only
staging directories, validated as a pair, fsynced, and published by atomic
rename without following symlinks. A generation marker selects `current`; at
most one validated successor is `staged`. A crash before publication leaves the
current generation unchanged. Startup accepts only complete, internally
consistent generations and fails closed on ambiguity.

Certificate issuance, staging, activation, supersession, revocation,
decommission, failed cutover, and recovery append sanitized cluster audit
events. Protected operations recheck the authority applicable to that operation
at action time. Enrollment uses enrollment authority and key-possession proof;
certificate lifecycle and recovery use their explicitly authorized control or
operator-recovery path; production BEAM additionally requires current
certificates, Node lifecycle, admission where required by KAP-28, trusted
Controller identity, canonical names and targets, an exact active Peer Grant,
and current generations. Discovery, a PID, a live BEAM name, or a previously
valid connection cannot restore authority.

Private-key compromise revokes the certificate and every grant bound to it,
disconnects reachable peers, and requires explicit certificate-authenticated or
operator-authorized recovery with a new key. Loss of an unrevoked current key
may use the separately authenticated recovery path; loss, revocation, or
uncertain identity state never silently creates a replacement Node identity.
Decommission remains terminal for the Node ID under ADR 0012.

### Pair-specific Peer Grant mechanics

ADR 0012's 30-day grant validity, 7-day normal rotation lead, one-active plus
one-staged uniqueness, per-pair one-hour generation rate limit, deterministic
derivation, hash-only Postgres storage, and bounded atom creation remain in
force.

A grant-only rotation binds its successor to unchanged current certificates. A
certificate renewal creates replacement grants bound to the staged certificate.
Each staged grant successor binds the exact current or staged Node and
Controller certificate identifiers and fingerprints, stable IDs, canonical
BEAM names, authorization root, grant ID, generation, and time window. Both
endpoints must durably stage it before cutover. Cutover makes the successor
current, replaces the exact-name cookie mapping, deliberately disconnects the
old connection, and permits reconnect only with the committed successor scope.
Failure to prove disconnection is visible and keeps the Runtime Endpoint
unavailable.

Reconnect means restoring authenticated BEAM reachability and publishing a
fresh Runtime Endpoint Observation for the same persisted Node and Controller
IDs inside the Controller-routable private network. Attempts use equal-jitter
exponential backoff with a 250 ms initial ceiling, doubling ceilings, and a
30-second maximum ceiling; each delay is selected from the upper half of its
current ceiling. Backoff resets only after exact successor authentication and a
fresh accepted observation after a committed cutover. Without a cutover,
reconnect uses the still-current certificate and active grant generations and
resets after their exact authentication plus a fresh accepted observation.
Authority loss stops reconnect until recovery re-establishes current authority.

Reconnect does not resume output, retransmit an ambiguous Runtime Endpoint
operation, create a universal durable session identity, or import Worker Runtime
incarnation from KAP-26. KAP-18 remains authoritative for bounded delivery,
native termination, and capacity release.

### Stale observations and version skew

The Controller accepts a Node Agent observation only when the operation began
and completed on the currently authenticated native BEAM connection and its
captured certificate, local-identity, Peer Grant, and connection generations
still equal current authority at commit time. A result from a disconnected,
superseded, restarted, or reauthenticated connection is stale even when it
claims the same persisted Node ID and BEAM name.

Implementation first tested this fence using native BEAM connection identity
plus credential and grant generations. The required unchanged-authority
reconnect case proved that a delayed observation could cross that fence, and
review proved that one value per Agent boot would not distinguish two
connections in the same boot. The accepted amendment therefore adds one random
128-bit process-ephemeral incarnation per authenticated BEAM connection to
authenticated observations. It must change on reconnect, is never persisted,
and cannot become durable Node identity, operation replay identity, allocation
identity, authority by itself, or a KAP-27 session ID.

The deterministic matrix includes connection replacement after response receipt
but before durable commit, reconnect with unchanged credentials, Node restart,
and Controller restart.

Controller `N` and Node Agent `N-1` may reconnect only when both preserve the
complete certificate, grant, connection-generation, and no-replay contract.
Missing generation semantics fail closed. KAP-84 owns real mixed macOS/Linux
`N`/`N-1` qualification; deterministic compatibility here does not satisfy that
acceptance profile.

## Consequences

Normal renewal causes a bounded deliberate disconnect. Expiry and revocation
can interrupt liveness, but cannot leave an authenticated connection alive past
known authority. Nodes with excessive clock uncertainty or an incomplete local
generation remain unavailable until explicit recovery.

The design reuses the existing certificate-authenticated control and recovery
path and stock OTP TLS Distribution. It adds no public ingress, NAT traversal,
remote-session transport, replay envelope, flow-control protocol, provider
activation, Worker allocation, or Active/Standby redesign.

KAP-28 remains authoritative for admission-on-join policy. KAP-17 remains the
Node-local Worker transport. KAP-18, KAP-26, and KAP-84 retain their existing
ownership boundaries.

## SPEC.md impact

Update §§7.5.0, 10.5, 10.6, and Milestone 9 to define the two layers, exact
certificate timing and custody, forced expiry disconnect, bounded reconnect,
stale-observation fencing, version-skew refusal, and explicit exclusions.
