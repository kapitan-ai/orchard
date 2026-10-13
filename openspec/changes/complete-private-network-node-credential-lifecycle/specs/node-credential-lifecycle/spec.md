## ADDED Requirements

### Requirement: Enrollment Proves Stable Node Identity And Key Possession

The transport-neutral Node credential authority SHALL bind one stable persisted
Node ID to one cluster and SHALL require a signed CSR proving possession of the
corresponding Node Identity Root private key. The CSR and issued certificate
SHALL carry the exact cluster and Node URI identity. Invalid, mismatched,
replayed under another identity, or leadership-unproven enrollment SHALL fail
before certificate issuance and SHALL NOT create another Node identity.

#### Scenario: Enrollment CSR has the wrong Node identity

- **WHEN** a CSR signature is valid but its exact cluster or Node identity differs from the enrollment authority
- **THEN** certificate issuance fails without consuming authority for another identity
- **AND** no Node Certificate, Peer Grant, or Runtime Endpoint authority is created

#### Scenario: Enrollment response is lost

- **WHEN** certificate issuance committed but the response was lost
- **THEN** retry succeeds only for the same enrollment, persisted private key, CSR fingerprint, cluster, and Node ID
- **AND** different key material fails closed instead of minting another identity

### Requirement: Node Certificate Rotation Is Bounded And Crash Safe

Node certificates SHALL have a 90-day default lifetime and become eligible for
renewal 30 days before expiry. Accepted-authority overlap SHALL begin when the
complete successor is atomically published as staged and end no later than the
earlier of seven days after publication and predecessor expiry. Signed validity
alone SHALL NOT establish accepted authority. Exactly one complete local
certificate generation SHALL be current and at most one SHALL be staged.
Owner-only staging, key/certificate pair validation, fsync, atomic publication,
generation markers, and symlink refusal SHALL make publication crash safe.
Ambiguous or incomplete generations SHALL fail closed.

#### Scenario: Renewal crashes before publication

- **WHEN** renewal stops after writing only part of a staged generation
- **THEN** restart retains the complete current generation and rejects the incomplete successor
- **AND** no Peer Grant or BEAM connection uses the partial material

#### Scenario: Renewal overlaps a current certificate

- **WHEN** a valid successor is issued during the 30-day renewal lead
- **THEN** its accepted-authority overlap begins only on complete atomic staged publication
- **AND** for each production BEAM relationship, cutover also requires the exact replacement Peer Grant bound to the staged certificate
- **AND** incomplete cutover at the overlap deadline ends predecessor and successor authority for protected use except separately authenticated recovery

### Requirement: Certificate Time Policy Never Extends Terminal Authority

Controller database time SHALL govern issuance, renewal eligibility, revocation,
decommission, and cutover. Certificate issuance MAY backdate `notBefore` by no
more than five minutes. An endpoint with more than five minutes of clock
uncertainty SHALL fail closed. Clock tolerance SHALL NOT extend certificate or
grant expiry, revocation, decommission, or cutover authority.
With Controller time represented as a bounded interval, activation SHALL wait
until the earliest possible time reaches `notBefore`; terminal authority SHALL
end when the latest possible time reaches its deadline.

#### Scenario: Node clock is outside the accepted boundary

- **WHEN** the Node cannot establish that its clock is within five minutes of authenticated Controller time
- **THEN** it does not activate or renew production transport authority
- **AND** diagnostics report bounded clock-authority loss without exposing credentials

#### Scenario: Established connection reaches certificate expiry

- **WHEN** either peer certificate reaches `notAfter` while BEAM remains connected
- **THEN** Orchard replaces the exact-name cookie authorization, disconnects the peer, and prevents further authenticated observations
- **AND** no clock grace extends the established connection

### Requirement: Current Credential Authority Is Audited And Fail Closed

Certificate issuance, staging, activation, supersession, revocation,
decommission, failed cutover, and recovery SHALL append sanitized cluster audit
events. Every protected operation SHALL recheck its applicable authorization
prerequisites at action time. Enrollment SHALL use enrollment authority and
key-possession proof. Certificate lifecycle and recovery SHALL use their
explicitly authorized control or operator-recovery path. Production BEAM SHALL
additionally require current certificates, stable Node and Controller identity,
applicable admission, canonical names and targets, an exact active Peer Grant,
and current generations. Certificate or key compromise SHALL revoke every bound
grant and require explicit recovery with new key possession. Missing or
uncertain authority SHALL NOT be reconstructed from discovery, PID, BEAM name,
or prior connection state.

#### Scenario: Current certificate is revoked while connected

- **WHEN** certificate revocation commits while its peer remains connected
- **THEN** new authority stops immediately and every bound Peer Grant becomes unusable
- **AND** revocation remains visibly incomplete until disconnect or process restart succeeds

#### Scenario: Node is decommissioned

- **WHEN** decommission commits
- **THEN** every Node certificate and Peer Grant is revoked and reachable peers are disconnected
- **AND** the stable Node ID, certificates, names, and grants cannot be reused

### Requirement: Private-Network Peer Grants Rotate By Exact Pair

Production BEAM SHALL require a certificate-bound Peer Grant for the exact
cluster, Controller, Node, canonical names, certificate identifiers and
fingerprints, authorization root, grant ID, generation, and validity interval.
An exact pair SHALL have at most one active and one staged successor. Normal
generation SHALL remain rate limited and only Controller-approved bounded
metadata may create OTP cookie atoms. Both endpoints SHALL durably stage the
successor before cutover.
A grant-only rotation SHALL bind its successor to unchanged current
certificates. Certificate renewal SHALL create replacement grants bound to the
staged certificate for each production BEAM relationship.

#### Scenario: Exact successor cuts over

- **WHEN** both endpoints have staged the same successor and its cutover time arrives under current authority
- **THEN** Orchard activates it, supersedes the predecessor, replaces the exact-name cookie mapping, and deliberately disconnects the old connection
- **AND** reconnect after cutover accepts only the committed successor certificate and grant generations

#### Scenario: Successor staging is incomplete

- **WHEN** either endpoint cannot prove the exact staged successor at cutover
- **THEN** cutover fails closed and the Runtime Endpoint remains unavailable for new work
- **AND** Orchard does not extend predecessor authority or create another generation outside the rate limit

### Requirement: Reconnect Restores Reachability Without Resuming Operations

Reconnect SHALL mean authenticated BEAM reachability and one fresh accepted
Runtime Endpoint Observation for the same persisted Node and Controller IDs
inside the Controller-routable private network. Attempts SHALL use equal-jitter
exponential backoff with ceilings beginning at 250 ms, doubling to at most 30
seconds, and each delay in the upper half of its ceiling. Backoff SHALL reset
only after exact authentication under currently authorized certificate and
active grant generations plus a fresh observation. After a committed cutover,
only the committed successor generations satisfy that rule. Authority loss
SHALL stop reconnect until explicit recovery.

Reconnect SHALL NOT resume output, retransmit an ambiguous Runtime Endpoint
operation, create a universal durable session identity, import KAP-27 session or
delivery semantics, or absorb KAP-26 Worker Runtime incarnation.

#### Scenario: Private-network interruption clears without a cutover

- **WHEN** Controller-routable private-network reachability returns and the unchanged current certificate and active grant remain valid
- **THEN** bounded reconnect restores authenticated BEAM reachability and publishes a fresh observation
- **AND** no prior ambiguous operation or output is retransmitted or resumed

#### Scenario: Reconnect authority is stale

- **WHEN** the available certificate, local identity, grant, name, target, or generation is not current
- **THEN** reconnect fails closed without gRPC inference fallback
- **AND** no fresh observation or scheduler availability is published

### Requirement: Delayed Observations Cannot Cross A Connection Incarnation

An observation SHALL be accepted only when its operation began and completed on
the currently authenticated native BEAM connection and the captured
certificate, local-identity, Peer Grant, and connection generations still equal
current authority at commit. Results from a disconnected, superseded,
restarted, or reauthenticated connection SHALL be rejected even if they claim
the same persisted Node ID and BEAM name.

Deterministic native BEAM tests proved that connection identity plus generations
cannot reject a delayed observation across unchanged-authority reconnect. The
separately accepted amendment therefore requires a random 128-bit
process-ephemeral incarnation for each authenticated BEAM connection. It SHALL
change on reconnect and Agent restart, SHALL never be persisted, and SHALL be
cleared on disconnect, authority loss, and Controller restart. It SHALL NOT
become durable identity, authority by itself, a session ID, a replay key, an
operation or output identity, or Worker allocation incarnation.
The deterministic matrix SHALL include connection replacement after response
receipt but before durable commit, reconnect with unchanged credentials, Node
restart, and Controller restart.

#### Scenario: Old observation arrives after Node restart

- **WHEN** a result from the predecessor BEAM connection arrives after the same Node ID reconnects from a restarted Agent
- **THEN** the Controller rejects it before durable observation or availability publication
- **AND** only a result captured and completed under the current connection authority may become fresh evidence

#### Scenario: Older version lacks a required generation fence

- **WHEN** Controller `N` or Node Agent `N-1` cannot preserve the complete credential, grant, connection, and no-replay contract
- **THEN** the pair remains disconnected or observation-ineligible
- **AND** deterministic compatibility does not claim KAP-84 mixed-platform qualification

### Requirement: Credential Lifecycle Preserves Adjacent Ownership Boundaries

KAP-28 SHALL own admission-on-join policy; KAP-18 SHALL own drain, native
termination, bounded delivery, and capacity release; KAP-26 SHALL own Worker
Units, allocations, and Runtime incarnation; KAP-84 SHALL own real mixed
macOS/Linux qualification; and KAP-17 SHALL remain the local Worker transport.
This lifecycle SHALL NOT add outbound sessions, public remote ingress, NAT or
proxy traversal, another Runtime Endpoint transport, federation, external
compute, inference replay, Active/Standby redesign, provider work, or model work.

#### Scenario: Reconnect is requested across a NAT-only boundary

- **WHEN** the Controller cannot route to the trusted private-network Node target without NAT, proxy, or outbound-session traversal
- **THEN** this profile remains unavailable
- **AND** Orchard does not activate KAP-27 behavior or infer general remote Linux support
