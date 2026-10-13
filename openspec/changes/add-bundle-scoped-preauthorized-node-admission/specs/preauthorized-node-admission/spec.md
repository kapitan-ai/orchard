## ADDED Requirements

### Requirement: Manual Admission Remains Deny By Default

Orchard SHALL default Node Enrollment to manual admission. The cluster SHALL
persist exactly one admission mode, `manual` or `enrollment_preauthorized`, and
Controllers SHALL NOT infer different mode authority from process-local
configuration. Bundle-scoped preauthorization is permitted only in
`enrollment_preauthorized` mode, and mode enablement alone SHALL authorize no
Node. An administrator SHALL issue one exact preauthorization through a
side-effect-free Action Preview, explicit confirmation, current authorization,
Active leadership, mutation-time revalidation, and atomic cluster audit.
Redemption of that durable authorization SHALL require no second human preview.
Changing admission mode SHALL require administrator authorization, Action
Preview, explicit confirmation, Active leadership, and cluster-scoped audit.
Disabling the mode SHALL prevent new issuance and later automatic admission but
SHALL NOT reverse an already committed admission.
This requirement refines `SPEC.md` §§4.4, 7.3.1, 7.4.1, and 11.9.

#### Scenario: Manual mode registers without admitting

- **WHEN** a valid Node Enrollment is redeemed while admission mode is `manual`
- **THEN** Orchard registers the exact Node and leaves it non-schedulable pending manual admission
- **AND** no admission decision, dispatch policy, or Peer Grant metadata is created by registration

#### Scenario: Enabled mode has no per-Enrollment authorization

- **WHEN** admission mode is `enrollment_preauthorized` but the exact Enrollment has no current preauthorization
- **THEN** successful registration still ends in manual pending admission
- **AND** Orchard does not infer authority from the mode, bundle, certificate, connection, or locality

### Requirement: Preauthorization Is Exact Durable And Not A Separate Bearer

Each preauthorization SHALL bind its version and UUID; cluster, Enrollment,
allocated Node, issuing Controller, and issuing administrator; issue and expiry
times; exact pool and routing-policy identities and revisions; explicit
Controller Dispatch Ceiling and reason; required trust, inventory,
compatibility, platform, and admission predicates; dispatch-capacity phase and
revision; preview digest and confirmation evidence; audit reference; and closed
state. Expiry SHALL NOT exceed Enrollment expiry. The states SHALL be
`authorized`, `consumed_admitted`, `consumed_pending_review`, `revoked`, and
`expired`, and only `authorized` MAY admit.

The bundle MAY contain a bounded identifier and policy digest, but those fields
SHALL NOT be separate bearer authority and the durable Controller record SHALL
be authoritative. The complete Enrollment Bundle remains sensitive one-time
credential material: theft before first redemption can let the holder establish
the allocated Node's key and reach the preauthorized admission outcome. The
issuance preview and confirmation SHALL expose that consequence. Possession
without successful exact Enrollment and current preauthorization validation
SHALL confer no admission, certificate, Peer Grant, Runtime Endpoint, or
scheduling authority. This requirement refines `SPEC.md` §§4.1, 4.4.1, 10.2,
10.5, and 10.8.

#### Scenario: Bundle policy is changed in transit

- **WHEN** a redemption presents pool, routing, capacity, or admission values that differ from the durable preauthorization
- **THEN** Orchard ignores the client-supplied authority and fails the mismatch closed
- **AND** no changed value is admitted or persisted as policy

#### Scenario: Preauthorization expires before Enrollment

- **WHEN** Controller-authoritative time has expired the preauthorization but the ordinary Enrollment remains valid
- **THEN** the exact Node may register under the Enrollment contract
- **AND** the preauthorization remains terminal `expired` while registration records pending review without admission, dispatch policy, or grant metadata

#### Scenario: Administrator confirms theft consequence

- **WHEN** an administrator previews issuance with `--admit-on-join`
- **THEN** the preview warns that theft before first redemption can let the holder establish the allocated Node key and reach preauthorized admission
- **AND** execution requires explicit confirmation of that consequence

### Requirement: Redemption Commits One Complete Outcome

Redemption SHALL first validate ordinary Enrollment identity, Bootstrap Token,
Node key possession, exact CSR and certificate state. It SHALL then revalidate
current leadership, mode, preauthorization, inventory, compatibility, canonical
identity, pool, routing, capacity phase, policy revisions, admission constraints,
and audit availability.

When all predicates pass, one transaction SHALL commit Enrollment and
preauthorization consumption, certificate issuance state,
`provisioned -> registered -> admitted`, the admission decision, phase-derived
dispatch policy, cluster audit, and one initial `pending_delivery` Peer Grant
record per eligible Controller. The issuing administrator SHALL remain the
decision principal and the executing Controller SHALL be separate provenance.
When the record remains `authorized` and only admission predicates drift, one
transaction MAY commit registration, `consumed_pending_review`, bounded reason,
and audit but SHALL create no admission, policy, or grant metadata. A record
already `revoked` or `expired` SHALL retain that terminal state when separately
valid registration records pending review. Identity, trust, cluster, Node,
leadership, or durable-write failure SHALL reject rather than fall back. Any
persistence failure SHALL roll back the complete attempted outcome. This
requirement refines `SPEC.md` §§4.4.1, 4.6.2, 7.5.0, and 10.9.

#### Scenario: Exact preauthorization succeeds

- **WHEN** a valid exact Enrollment and current preauthorization are redeemed and every admission predicate passes
- **THEN** registration, admission, decision, policy, audit, consumption, and initial pending-grant metadata commit atomically
- **AND** the Node remains `admitted`, not `active`, pending fresh authenticated health evidence

#### Scenario: Admission policy drift preserves safe registration

- **WHEN** Enrollment identity is valid but a bound pool, routing policy, compatibility predicate, or dispatch phase has drifted
- **THEN** Orchard registers the Node and consumes the preauthorization as pending review with a bounded reason
- **AND** no partial admission, dispatch policy, Peer Grant metadata, activation, or scheduling authority exists

#### Scenario: Atomic persistence fails

- **WHEN** decision, policy, audit, consumption, certificate-state, or pending-grant persistence fails
- **THEN** the attempted outcome rolls back as one transaction
- **AND** no partial admission or orphaned policy or grant metadata remains

### Requirement: Races Replay And Restart Fail Closed

Redemption SHALL preserve the authority-first lock order: current leader write
gate, dispatch-capacity phase singleton, admission-mode singleton, cluster
Controller-membership transaction lock, eligible Controller rows in stable ID
order, then exact Enrollment, preauthorization, Node, and related parent rows.
Controller enrollment, retirement, and post-admission grant creation SHALL use
the same membership lock. Parent locks and exact uniqueness constraints SHALL
serialize new decision, policy, grant, and audit-linked outcome rows.
Controller-authoritative time and state observed under those locks SHALL decide
redemption, expiry, revocation, and mode-disable races.
Concurrent exact redemption SHALL have one committed winner. A retry with the
same Enrollment, Node key, CSR fingerprint, and preauthorization SHALL return
the same durable outcome without duplicate effects; any divergent replay SHALL
fail closed.

Restart or reconnect SHALL reconstruct no authority from a PID, socket, process
memory, bundle copy, BEAM name, connection incarnation, or previous connection.
This requirement refines `SPEC.md` §§3.7, 4.4.1, 7.5.0, and 12.7.

#### Scenario: Concurrent exact redemptions race

- **WHEN** two matching requests concurrently redeem one preauthorization
- **THEN** at most one transaction creates the durable outcome
- **AND** the other request returns that same outcome without another certificate, decision, policy, grant generation, or successful audit event

#### Scenario: Revocation races redemption

- **WHEN** revocation obtains the locked current record before redemption commits
- **THEN** the record remains terminal `revoked`, automatic admission is denied, and independently valid registration may end pending review
- **WHEN** full admission commits first
- **THEN** later revocation does not retroactively de-admit the Node

#### Scenario: Mode disablement races redemption

- **WHEN** mode disablement locks and commits before redemption observes the admission-mode row
- **THEN** automatic admission is denied and an `authorized` record may be consumed pending review only with independently valid registration
- **WHEN** full admission commits before mode disablement obtains the lock
- **THEN** disablement prevents later automatic admissions but does not alter that admitted Node

#### Scenario: Expiry threshold races redemption

- **WHEN** Controller database time reaches preauthorization expiry before locked redemption eligibility is evaluated
- **THEN** the record is terminal `expired` and independently valid registration may record pending review without changing that state
- **WHEN** locked eligibility is evaluated before expiry and the full transaction commits
- **THEN** the admission outcome remains committed after the later expiry threshold

#### Scenario: Controller membership changes during redemption

- **WHEN** Controller enrollment or retirement races a preauthorized admission
- **THEN** the shared membership lock establishes one eligible Controller snapshot for initial pending-grant metadata
- **AND** later Controller enrollment uses the separate initial-grant operation while later retirement uses ordinary grant revocation

#### Scenario: Response is lost after commit

- **WHEN** the Controller commits an outcome but its response is lost
- **THEN** an exact identity-bound retry returns the durable outcome
- **AND** a retry with a different key, CSR, Node, cluster, or preauthorization fails closed

#### Scenario: Controller restarts

- **WHEN** the Controller restarts before or after redemption
- **THEN** only durable records plus fresh current authority determine whether redemption may proceed or which outcome already committed
- **AND** no process-local or connection evidence reconstructs authorization

#### Scenario: Pending-review persistence fails

- **WHEN** certificate state, Enrollment consumption, preauthorization outcome or terminal-state link, bounded reason, or audit persistence fails during pending-review registration
- **THEN** the complete pending-review transaction rolls back
- **AND** Orchard does not report registration or consume an `authorized` preauthorization partially

### Requirement: Preauthorization Preserves Runtime And Platform Boundaries

Preauthorization SHALL NOT itself enroll or authenticate a Node, issue a
certificate, authorize a BEAM connection or Peer Grant, activate a Runtime
Endpoint, prove health or capacity, schedule or place work, authorize a Worker,
provider, or model, or establish qualification or support. Fresh current
certificates, admission, an active exact Peer Grant, authenticated observation,
health, lifecycle, capacity, and every scheduler gate SHALL remain required.

For `ubuntu_24_04_x86_64_single_host`, exact installation UUID, profile, and
source-manifest evidence MAY be bound compatibility predicates, but fixed roots,
lifecycle lock, local process ownership, or colocation SHALL confer no
authority. Remote expansion SHALL use a distinct Node, key, certificate,
canonical name, and applicable installation identity. This requirement refines
`SPEC.md` §§4.1, 7.5, 10.5, and 11.10.

#### Scenario: Colocated Node redeems a preauthorization

- **WHEN** a Node Agent shares the Controller host and exact installation
- **THEN** it passes the same Enrollment, admission, certificate, Peer Grant, Runtime Endpoint, and activation checks as a remote private-network Node
- **AND** localhost, a local socket, service identity, systemd ownership, and installation UUID supply no shortcut

#### Scenario: Remote Node is added later

- **WHEN** the composition expands to another host
- **THEN** the remote Node receives distinct identity and exact authority
- **AND** the local Node's Enrollment, key, certificate, name, installation identity, or preauthorization is not cloned

### Requirement: Audit And Diagnostics Are Bounded And Secret Free

Issuance, revocation, expiry observation, consumption, admitted outcome,
pending-review fallback, and conflicting replay SHALL have cluster-scoped audit
or linked durable evidence. Output SHALL distinguish manual registration,
preauthorized admission, pending-review fallback, terminal state, and replay
conflict. Audit and diagnostics MAY include bounded identifiers, revisions,
decision principal, execution provenance, reason codes, and policy values but
MUST NOT include Bootstrap Tokens, private keys, certificate secrets, Peer Grant
values or hashes, administrator credentials, DSNs, or reusable admission
authority. This requirement refines `SPEC.md` §§7.3.5, 10.2, 10.9, and 11.9.

#### Scenario: Admission-only drift is diagnosed

- **WHEN** a valid Enrollment ends in `consumed_pending_review`
- **THEN** human and JSON output name the stable bounded reason and exact non-secret identifiers
- **AND** output exposes no credential or reusable authority
