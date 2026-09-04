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

Drain acknowledgement, host-fence evidence, pointer activation, provisional child evidence, Controller host-arm authorization, host-arm evidence, pending Controller commit, exact-child enabled acknowledgement, fresh live-child evidence, terminal success, rollback, failure, and uncertainty SHALL advance only from the expected prior phase of the exact current transition generation.
Stale leaders, duplicate requests, prior-generation heartbeats, replayed evidence, and concurrent operator actions SHALL fail closed.

#### Scenario: Matching phase evidence arrives

- **WHEN** authenticated evidence matches the current generation, expected prior phase, bound artifacts, and Node identity
- **THEN** the Controller MAY atomically advance to the next allowed phase and append audit evidence

#### Scenario: Stale or replayed evidence arrives

- **WHEN** evidence names another generation, prior phase, operation, artifact, process, or Node identity
- **THEN** the Controller SHALL reject it without changing lifecycle or scheduler state

### Requirement: Drain Completes Before Host Mutation

The transition SHALL remain in `draining` until existing request and allocation authority records a fresh generation-bound acknowledgement of zero active allocations.
Transition creation SHALL be the allocation fence.
Every allocation claim and final Worker Runtime execution acceptance SHALL atomically verify the observed absence of that transition generation and scheduler exclusion in the same serialization boundary as its authority grant.
No post-fence acceptance may commit, and the zero-active-allocation acknowledgement SHALL cover every pre-fence accepted allocation and execution.
Only that acknowledgement MAY advance the Node through the existing `draining -> maintenance` edge.
Verified inert candidate import MAY occur before transition creation.
No active pointer, launch suppression, running process, launch policy, or other managed launch state mutation and no activation authorization SHALL occur before maintenance is committed.

#### Scenario: Allocations remain active

- **WHEN** the current transition generation lacks a fresh zero-active-allocation acknowledgement
- **THEN** the Controller SHALL retain `draining` and scheduler exclusion
- **AND** SHALL reject managed launch-state mutation authority

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

### Requirement: Terminal Acceptance Requires Host Arm and Fresh Live-Child Evidence

The Controller SHALL first verify exact provisional evidence bound to Node ID, operation ID, transition generation, candidate artifacts, and exact child while the Node remains unschedulable.
It SHALL issue a generation-bound host-arm token for the exact child.
The host SHALL persist idempotent `host_armed_pending_controller_commit` evidence without clearing suppression or provisional restrictions.
The Controller MAY then commit `controller_committed_pending_child_observation` while retaining maintenance and scheduler exclusion.
The exact child SHALL consume that authenticated result, enter exact-child enabled state, and acknowledge it while ordinary dispatch remains fenced.
Only after the Controller freshly challenges the same live enabled child MAY a second database transaction record terminal success, advance `maintenance -> active`, and clear scheduler exclusion.

#### Scenario: Provisional evidence is accepted

- **WHEN** composition, app, build manifest, Node identity, process, bootstrap, Runtime Endpoint, Worker Runtime, suppression, and health evidence all match the current generation
- **THEN** the Controller SHALL issue one host-arm token and keep the Node unschedulable

#### Scenario: Exact child observes pending Controller commit

- **WHEN** authenticated host evidence proves the matching token armed only the exact provisional child
- **THEN** the Controller MAY record `controller_committed_pending_child_observation` while retaining maintenance and scheduler exclusion
- **AND** the child MAY enter exact-child enabled state only after consuming that authenticated result

#### Scenario: Exact enabled child is freshly confirmed

- **WHEN** the exact child acknowledges enabled state and a fresh challenge proves that same child remains live
- **THEN** the Controller MAY atomically record terminal success and make the Node eligible

#### Scenario: Host arm, child, or response is missing or uncertain

- **WHEN** the Controller cannot verify exact host arm, pending-result consumption, enabled-child acknowledgement, or fresh live-child evidence
- **THEN** the generation SHALL remain blocking and the Node SHALL remain unschedulable

### Requirement: Exact-Baseline Rollback Uses the Managed Terminal Protocol

Rollback SHALL remain inside the current transition generation and SHALL name only the exact source baseline bound at creation.
A restored baseline SHALL remain unschedulable until its own provisional evidence, Controller token, host-arm evidence, pending-result consumption, enabled-child acknowledgement, fresh live-child evidence, and terminal `rolled_back` transaction complete.
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
