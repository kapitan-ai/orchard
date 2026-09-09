## ADDED Requirements

### Requirement: Controller Owns a Durable Managed Transition Generation

The Controller SHALL persist one monotonically increasing managed transition generation per Node in Postgres and SHALL allow at most one nonterminal generation for that Node.
The generation SHALL bind Node ID, operation ID, actor, exact source baseline, imported signed-prebuilt generation, mounted final app, installed stable bootstrap, Candidate Manifest, mandatory DMG, exact retained identity-store generations and digests, target profile, transition direction, compatibility requirements, current phase, evidence digests, and terminal result.

#### Scenario: Managed transition is created

- **WHEN** an authorized operator presents valid transition preflight for a dedicated Node in `active` or `cordoned`
- **THEN** the Controller SHALL atomically create the next generation, move the Node to `draining`, create scheduler exclusion, and append audit evidence

#### Scenario: Another transition is active

- **WHEN** a Node already has a nonterminal managed transition generation
- **THEN** the Controller SHALL reject creation of another generation

### Requirement: Every Controller Phase Uses Exact Generation Compare and Swap

Drain acknowledgement, host-fence evidence, pointer activation, provisional child evidence, Controller host-arm authorization, host-arm evidence, pending Controller commit, exact-child enabled acknowledgement, Worker readiness evidence, fresh Node Agent and Worker evidence, terminal success, rollback, failure, and uncertainty SHALL advance only from the expected prior phase of the exact current transition generation.
Stale leaders, duplicate requests, prior-generation heartbeats, replayed evidence, and concurrent operator actions SHALL fail closed.

#### Scenario: Matching phase evidence arrives

- **WHEN** authenticated evidence matches the current generation, expected prior phase, bound artifacts, and Node identity
- **THEN** the Controller MAY atomically advance to the next allowed phase and append audit evidence

#### Scenario: Stale or replayed evidence arrives

- **WHEN** evidence names another generation, prior phase, operation, artifact, process, or Node identity
- **THEN** the Controller SHALL reject it without changing lifecycle or scheduler state

### Requirement: Drain Completes Before Host Mutation

The transition SHALL remain in `draining` until existing request and allocation authority records a fresh generation-bound acknowledgement of zero active allocations.
Transition creation SHALL be the allocation-issuance fence and SHALL close the authoritative execution-grant set to new grants.
For `managed_apple_silicon_macos_node` only, this protocol SHALL supersede the Controller-local F11 restriction in `SPEC.md` §4.6.2 only for the profile-scoped durable grant-ID and fence-epoch ledger and SHALL NOT authorize a general crash-recoverable reservation system before M7.
Every allocation claim and new execution-grant issuance SHALL receive a unique execution-grant ID and observed fence epoch and SHALL atomically verify the absence of that transition generation and scheduler exclusion in the same Controller serialization boundary as its durable Postgres authority grant.
The Controller SHALL persist each grant and terminal disposition in Postgres, while the stable helper SHALL durably persist the current local fence epoch and consumed or rejected grant IDs for Node-side replay rejection across Node Agent or helper restart.
Final Worker Runtime acceptance of a grant issued before transition creation SHALL verify the exact durable grant, Node, request, still-open fence epoch, and consumed-or-rejected state through the stable helper.
The helper SHALL serialize local epoch closure against every final acceptance by holding one acceptance gate continuously from its authenticated grant decision through Worker Runtime acceptance or durable pre-acceptance failure.
Once the helper durably closes the local epoch, every not-yet-accepted grant in that epoch and every closed, mismatched, duplicate, replayed, interrupted, or unresolved grant SHALL remain incapable of acceptance across restart until exact Controller and helper reconciliation records its disposition.
Node Agent or helper restart SHALL begin execution-fail-closed until the exact current Controller epoch and durable local fence state reconcile.
The zero-active-allocation acknowledgement SHALL commit only after durable local epoch closure and after every pre-fence grant is either never accepted, durably rejected before Worker acceptance, or affirmatively confirmed terminated with allocation release across queued, retry, streaming, recovery, and delayed-delivery paths.
Cancellation timeout, transport ambiguity, unconfirmed release, unresolved occupancy, or quarantine SHALL block zero acknowledgement and host mutation.
No grant issued after transition creation and no final Worker Runtime acceptance begun after local epoch closure may commit.
Only that acknowledgement MAY advance the Node through the existing `draining -> maintenance` edge.
Verified inert candidate import MAY occur before transition creation.
No active pointer, launch suppression, running process, launch policy, or other managed launch state mutation and no activation authorization SHALL occur before maintenance is committed.

#### Scenario: Allocations remain active

- **WHEN** the current transition generation lacks a fresh zero-active-allocation acknowledgement
- **THEN** the Controller SHALL retain `draining` and scheduler exclusion
- **AND** SHALL reject managed launch-state mutation authority

#### Scenario: Pre-fence grant is queued, replayed, or recovered

- **WHEN** any pre-fence execution-grant ID lacks a durable terminal disposition or may still reach Worker Runtime through queue, retry, stream, recovery, or delayed delivery
- **THEN** zero-active acknowledgement SHALL fail and the Node SHALL remain draining and excluded

#### Scenario: Cancel or release is unresolved

- **WHEN** a pre-fence grant has cancellation timeout, ambiguous transport closure, unconfirmed allocation release, unresolved execution occupancy, or quarantine
- **THEN** the Controller SHALL refuse zero-active acknowledgement and every host mutation authority

### Requirement: Managed Transition Blocks Generic Reactivation

Generic `resume`, generic `uncordon`, ordinary heartbeat health, admission reconciliation, static compatibility fallback, single-node fallback, and scheduler health projection SHALL NOT make a Node active while a managed transition generation is nonterminal or in a blocking recoverable phase.
Only a matching managed terminal transaction may clear the exclusion.

#### Scenario: Generic resume is requested during transition

- **WHEN** an operator invokes generic resume or uncordon for a Node with a blocking managed transition generation
- **THEN** the Controller SHALL return a managed-transition blocker and keep the Node unschedulable

#### Scenario: Healthy heartbeat arrives during transition

- **WHEN** a baseline or candidate process reports ordinary health while the generation lacks exact terminal evidence
- **THEN** the Controller SHALL retain maintenance and scheduler exclusion

### Requirement: Leadership Change Preserves the Fence

A Controller leader SHALL load and enforce every nonterminal or blocking managed transition generation before it performs lifecycle reconciliation or offers the Node to scheduling.
Leadership change SHALL NOT synthesize terminal evidence or clear exclusion.

#### Scenario: New leader takes over mid-transition

- **WHEN** a standby Controller becomes leader while a managed transition generation is active
- **THEN** it SHALL preserve the recorded phase and scheduler exclusion
- **AND** SHALL accept only exact next-phase evidence for that generation

### Requirement: Managed Profile Fault Exclusion Requires Exact Repair

When an ordinary-serving managed Node reports a process-shape, descriptor-closure, filesystem-closure, channel-identity, or execution-identity violation, the Controller SHALL durably persist a managed-profile fault exclusion bound to the exact active generation.
If execution termination or allocation release is unresolved, the current Active Controller SHALL also place the Node in the existing `SPEC.md` §4.6.2 quarantine.
That exclusion SHALL take precedence over heartbeat health, capacity, portable Worker restart, ordinary reconciliation, generic resume, and generic uncordon.
Only an authenticated and audited generation-checked managed repair SHALL clear the managed-profile exclusion after the host and Controller re-prove the exact process set, descriptor and filesystem closure, channel identities, Worker readiness, and active-generation policy.
Managed repair SHALL NOT clear §4.6.2 quarantine unless its independent execution-termination and allocation-release reconciliation also completes.
If the Controller cannot durably persist or re-read the exclusion, the host SHALL remain launch-suppressed and locally reject execution.

#### Scenario: Healthy evidence follows a managed-profile fault

- **WHEN** health, capacity, Worker restart, or ordinary reconciliation evidence arrives after a managed-profile fault exclusion is recorded
- **THEN** the Controller SHALL retain the exclusion and reject scheduler eligibility until exact managed repair commits

#### Scenario: Fault report cannot be persisted

- **WHEN** the host reports a managed-profile fault but the Controller cannot durably persist or verify the bound exclusion
- **THEN** the host SHALL preserve general suppression and local execution rejection
- **AND** no generic recovery path SHALL make the Node schedulable

#### Scenario: Managed fault has clean execution closure

- **WHEN** a managed-profile fault proves exact Worker execution termination and allocation release without unresolved occupancy
- **THEN** the Controller SHALL persist the managed-profile exclusion without adding §4.6.2 quarantine

#### Scenario: Managed fault has unresolved execution

- **WHEN** a managed-profile fault has ambiguous termination, unconfirmed release, or unresolved occupancy
- **THEN** the Controller SHALL persist both the managed-profile exclusion and §4.6.2 quarantine
- **AND** managed repair SHALL clear only the managed-profile exclusion unless quarantine reconciliation independently proves execution termination and allocation release

### Requirement: Terminal Acceptance Requires Host Arm and Fresh Live-Child Evidence

The Controller SHALL first verify exact provisional evidence bound to Node ID, operation ID, transition generation, candidate artifacts, and exact child while the Node remains unschedulable.
It SHALL issue a generation-bound host-arm token for the exact child.
The host SHALL persist idempotent `host_armed_pending_controller_commit` evidence without clearing suppression or provisional restrictions.
The Controller MAY then commit `controller_committed_pending_child_observation` while retaining maintenance and scheduler exclusion.
The exact child SHALL consume that authenticated result and enter exact-child enabled state while ordinary dispatch remains fenced.
Only in that state MAY the incoming Worker spawn gate open for the exact child, generation, transition, and execution epoch.
The Node Agent SHALL register the exact Worker through reserve-before-spawn, establish its authenticated channel, and acknowledge exact Worker identity, protocol compatibility, and a representative supported-model readiness or inference probe.
Only after the Controller freshly challenges the same live Node Agent and registered Worker MAY a second database transaction record terminal success, advance `maintenance -> active`, clear scheduler exclusion, atomically establish the accepted generation's new serving epoch, and reopen its Controller grant set.
Grant issuance SHALL remain blocked until the helper durably reconciles that exact serving epoch and the Node Agent publishes matching epoch-readiness; rollback, Controller or helper restart, and leadership change SHALL use the same reconciliation gate.

#### Scenario: Provisional evidence is accepted

- **WHEN** composition, app, Candidate Manifest, Node identity, process, bootstrap, Runtime Endpoint, Worker Runtime, suppression, and health evidence all match the current generation
- **THEN** the Controller SHALL issue one host-arm token and keep the Node unschedulable

#### Scenario: Exact child observes pending Controller commit

- **WHEN** authenticated host evidence proves the matching token armed only the exact provisional child
- **THEN** the Controller MAY record `controller_committed_pending_child_observation` while retaining maintenance and scheduler exclusion
- **AND** the child MAY enter exact-child enabled state only after consuming that authenticated result
- **AND** the incoming Worker gate MAY open only for the exact child, generation, transition, and execution epoch while exclusion remains active

#### Scenario: Exact enabled Node Agent and Worker are freshly confirmed

- **WHEN** the exact child acknowledges the exact registered Worker, execution epoch, authenticated channel, protocol compatibility, and supported-model readiness and a fresh challenge proves that same Node Agent and Worker remain live
- **THEN** the Controller MAY atomically record terminal success, establish the accepted generation's new serving epoch, and reopen its Controller grant set
- **AND** the scheduler SHALL keep grant issuance blocked until helper reconciliation and matching Node Agent epoch-readiness are current

#### Scenario: Host arm, child, or response is missing or uncertain

- **WHEN** the Controller cannot verify exact host arm, pending-result consumption, enabled-child acknowledgement, Worker readiness, or fresh Node Agent and Worker evidence
- **THEN** the generation SHALL remain blocking and the Node SHALL remain unschedulable

### Requirement: Exact-Baseline Rollback Uses the Managed Terminal Protocol

Rollback SHALL remain inside the current transition generation and SHALL name only the exact source baseline bound at creation.
A restored baseline SHALL remain unschedulable until its own provisional evidence, Controller token, host-arm evidence, pending-result consumption, exact-child enablement, incoming Worker gate, registered Worker readiness, fresh Node Agent and Worker evidence, and terminal `rolled_back` transaction complete.
Generic resume SHALL NOT finish rollback.

#### Scenario: Baseline is restored but terminal evidence is absent

- **WHEN** the host points to and starts the exact baseline provisionally but host-arm, pending-result, enabled-child, or fresh-child evidence is incomplete
- **THEN** the Controller SHALL keep the Node in managed transition maintenance

### Requirement: Failure and Uncertainty Remain Recoverable and Blocking

Only `succeeded` and fully accepted `rolled_back` SHALL be terminal outcomes.
Every failure or uncertainty phase SHALL remain bound to the same transition generation, scheduler exclusion, and repair protocol.

#### Scenario: Host arm is durable but terminal commit is absent

- **WHEN** the Controller observes `host_armed_pending_controller_commit` without matching terminal success
- **THEN** it SHALL keep the Node excluded and revalidate the same live child or require suppression and restart within the same generation

#### Scenario: Pending Controller result lacks child observation

- **WHEN** `controller_committed_pending_child_observation` lacks exact-child enabled acknowledgement
- **THEN** the Controller SHALL retain maintenance and scheduler exclusion
