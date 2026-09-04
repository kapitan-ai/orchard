## ADDED Requirements

### Requirement: Managed Transition Generation Is an Authoritative Eligibility Exclusion

The scheduler SHALL exclude any Node whose current durable managed transition generation is nonterminal or in any blocking recoverable failure or uncertainty phase.
Lifecycle state, heartbeat health, cached capacity, and runtime-provider evidence SHALL NOT override that exclusion.
Every placement, dispatch, static compatibility, single-node, and fallback path SHALL check all known managed Node and transition bindings against the same durable exclusion.
A target that matches or may alias a managed Node SHALL bind to that exact checked Node generation or fail closed.
The accepted explicitly unmanaged compatibility path MAY continue only when the Controller positively proves that the target is associated with no managed Node or transition.

#### Scenario: Candidate reports healthy before terminal acceptance

- **WHEN** a provisional or ordinary heartbeat reports healthy capacity for a Node with a blocking transition generation
- **THEN** the scheduler SHALL not select or dispatch to that Node

#### Scenario: Terminal success commits

- **WHEN** the exact generation-checked Controller transaction records terminal success and clears the exclusion
- **THEN** the scheduler MAY evaluate the Node under all ordinary eligibility and capacity gates

#### Scenario: Fallback may alias a managed Node

- **WHEN** a static, single-node, or compatibility fallback matches or may alias a managed Node but cannot bind its target to the exact checked Node and transition generation
- **THEN** dispatch SHALL fail closed

#### Scenario: Compatibility target is positively unmanaged

- **WHEN** trusted inventory is confirmed empty and the Controller proves the configured compatibility target is associated with no managed Node or transition
- **THEN** the accepted explicitly unmanaged compatibility path MAY proceed under its existing gates

### Requirement: Managed Profile Fault Exclusion Overrides Health

A durable managed-profile fault exclusion bound to an active generation SHALL make the Node ineligible regardless of heartbeat, capacity, Runtime Endpoint health, portable Worker restart, ordinary reconciliation, generic resume, or generic uncordon.
If the fault also has unresolved execution termination or allocation release, the current Active Controller SHALL retain the existing `SPEC.md` §4.6.2 quarantine independently.
Only an authenticated and audited generation-checked managed repair that re-proves the exact process, descriptor, filesystem, channel, Worker-readiness, and active-policy contract MAY clear the managed-profile exclusion.
That repair SHALL NOT clear §4.6.2 quarantine without its independent execution-termination and allocation-release reconciliation.

#### Scenario: Worker republishes health after a managed fault

- **WHEN** a Node or restarted Worker publishes healthy status or capacity while its active generation has a managed-profile fault exclusion
- **THEN** the scheduler SHALL keep the Node ineligible and expose the managed fault reason

#### Scenario: Managed repair completes while quarantine remains

- **WHEN** exact managed repair clears the managed-profile exclusion but §4.6.2 quarantine still lacks confirmed execution termination or allocation release
- **THEN** the scheduler SHALL keep the Node ineligible under quarantine

### Requirement: Scheduler Snapshots Cannot Outlive Transition Generation

Any scheduler eligibility projection or placement decision SHALL bind the observed managed transition generation or absence of one and SHALL be invalidated when a newer generation is created.
A stale leader or cached snapshot SHALL NOT dispatch work after managed transition creation enters `draining`.

#### Scenario: Transition begins after scheduler snapshot

- **WHEN** a scheduler snapshot observed the Node as eligible before creation of a newer managed transition generation
- **THEN** dispatch SHALL recheck the durable generation fence and reject the stale selection

### Requirement: Execution Grants Are Closed and Accounted Across the Fence

For `managed_apple_silicon_macos_node` only, this requirement SHALL be the profile-scoped successor to the Controller-local F11 rule in `SPEC.md` §4.6.2 and SHALL NOT create a general crash-recoverable reservation ledger or admit other pre-M7 leadership fencing.
Every allocation claim and new execution-grant issuance SHALL carry a unique execution-grant ID and the fence epoch observed in the same Controller serialization boundary as its durable authority grant.
The Controller SHALL persist the grant, epoch, Node, request, and terminal disposition in Postgres.
Managed transition creation SHALL close the Node's authoritative execution-grant set to new grants and SHALL be the allocation-issuance fence.
Final Worker Runtime acceptance of a pre-fence grant SHALL verify the exact durable grant, Node, request, still-open fence epoch, and consumed-or-rejected state through an authenticated stable-helper operation.
The helper SHALL serialize local epoch closure against every final acceptance by holding one acceptance gate continuously from its authenticated grant decision through Worker Runtime acceptance or durable pre-acceptance failure.
Durable local epoch closure SHALL be the final-acceptance fence; after it commits, every not-yet-accepted grant in that epoch and every closed, mismatched, duplicate, replayed, interrupted, or unresolved grant SHALL remain incapable of acceptance across Node Agent or helper restart until exact reconciliation records its disposition.
A Node Agent or helper restart SHALL begin execution-fail-closed until the exact current Controller epoch and durable local fence state reconcile.
A zero-active acknowledgement SHALL require durable local epoch closure and a terminal disposition for every pre-fence grant across queued, retry, streaming, recovery, and delayed-delivery paths.
A terminal disposition SHALL mean the grant was never accepted, was durably rejected before Worker acceptance, or has affirmatively confirmed Worker execution termination and allocation release.
Cancellation timeout, transport ambiguity, unconfirmed release, or unresolved occupancy or quarantine SHALL block zero-active acknowledgement and host mutation.
The accepted terminal `succeeded` or fully accepted `rolled_back` transaction SHALL atomically establish the accepted generation's new serving epoch and reopen its Controller grant set.
No post-terminal grant SHALL issue until the helper durably reconciles that exact serving epoch and the Node Agent publishes the matching epoch-readiness observation; rollback, Controller or helper restart, and leadership change SHALL use the same reconciliation gate.

#### Scenario: Grant arrives after transition creation

- **WHEN** a new grant is issued after transition creation, or a replayed, retried, recovered, or delayed pre-fence grant reaches final acceptance after durable local epoch closure
- **THEN** the path SHALL reject it against the current transition generation, durable grant state, and fence epoch
- **AND** SHALL NOT create or revive execution authority

#### Scenario: Node Agent or helper restarts with a delayed grant

- **WHEN** the Node Agent or helper restarts and receives a grant before the current Controller epoch and durable local fence state reconcile
- **THEN** local execution SHALL remain closed and the grant SHALL NOT reach Worker Runtime acceptance

#### Scenario: Grant ID is replayed after local acceptance

- **WHEN** the same execution-grant ID reaches the Node Agent or helper again in the same or a later process lifetime
- **THEN** the stable helper SHALL reject it from the durable consumed-or-rejected set without executing work

#### Scenario: Grant disposition does not prove execution closure

- **WHEN** cancellation times out, transport closure is ambiguous, allocation release is unconfirmed, or execution occupancy remains unresolved or quarantined
- **THEN** the grant SHALL NOT count as terminal for zero-active acknowledgement and host mutation SHALL remain blocked

#### Scenario: Terminal transaction opens the next serving epoch

- **WHEN** terminal `succeeded` or fully accepted `rolled_back` commits for the exact enabled Node Agent and Worker
- **THEN** the same transaction SHALL establish the accepted generation's new serving epoch and reopen its Controller grant set
- **AND** grant issuance SHALL remain blocked until the helper durably reconciles that epoch and matching Node Agent epoch-readiness is current

### Requirement: Managed Profile Rejections Have Stable Precedence

The scheduler explanation contract SHALL use `managed_transition_excluded` for a nonterminal managed transition, `managed_profile_fault_excluded` for a durable managed-profile fault, and `managed_profile_matrix_unqualified` when the exact composition, model, macOS, hardware, OTP, or Worker tuple lacks current qualification.
When more than one condition applies, the primary reason precedence SHALL be managed transition, managed-profile fault, unqualified matrix, existing §4.6.2 quarantine or health, and then ordinary capacity reasons.
Diagnostics SHALL retain all applicable secondary reasons, including quarantine when `managed_profile_fault_excluded` is primary.

#### Scenario: Managed fault and quarantine both apply

- **WHEN** a Node has both a managed-profile fault exclusion and unresolved §4.6.2 quarantine without a nonterminal transition
- **THEN** the primary rejection reason SHALL be `managed_profile_fault_excluded` and diagnostics SHALL also expose quarantine

#### Scenario: Exact matrix tuple is unqualified

- **WHEN** no current qualification covers the Node's exact managed composition, supported model, macOS, hardware, OTP, and Worker tuple
- **THEN** the scheduler SHALL reject it with `managed_profile_matrix_unqualified` before evaluating ordinary capacity

### Requirement: Provisional Child Cannot Publish Schedulable Capacity

Capacity, health, or Runtime Endpoint observations from a provisional child SHALL be transition evidence only and SHALL NOT update ordinary schedulable capacity or make the Node eligible.

#### Scenario: Provisional child reports capacity

- **WHEN** the current transition generation identifies the reporting process as provisional
- **THEN** the scheduler SHALL ignore that report for eligibility and dispatch
- **AND** the Controller MAY evaluate it only under the managed terminal-acceptance policy
