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

### Requirement: Scheduler Snapshots Cannot Outlive Transition Generation

Any scheduler eligibility projection or placement decision SHALL bind the observed managed transition generation or absence of one and SHALL be invalidated when a newer generation is created.
A stale leader or cached snapshot SHALL NOT dispatch work after managed transition creation enters `draining`.

#### Scenario: Transition begins after scheduler snapshot

- **WHEN** a scheduler snapshot observed the Node as eligible before creation of a newer managed transition generation
- **THEN** dispatch SHALL recheck the durable generation fence and reject the stale selection

### Requirement: Provisional Child Cannot Publish Schedulable Capacity

Capacity, health, or Runtime Endpoint observations from a provisional child SHALL be transition evidence only and SHALL NOT update ordinary schedulable capacity or make the Node eligible.

#### Scenario: Provisional child reports capacity

- **WHEN** the current transition generation identifies the reporting process as provisional
- **THEN** the scheduler SHALL ignore that report for eligibility and dispatch
- **AND** the Controller MAY evaluate it only under the managed terminal-acceptance policy
