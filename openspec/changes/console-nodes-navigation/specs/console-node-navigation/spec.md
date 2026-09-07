## ADDED Requirements

### Requirement: Preserve Node diagnosis context on refresh failure

The Console SHALL offer a read-only Node detail refresh and distinguish lifecycle, health, and evidence freshness.
After a failed refresh, the Console SHALL retain the last successful evidence for the same target with a stale warning and its refresh time.
Action preview and execution SHALL remain unavailable until refresh succeeds.
Changing targets SHALL clear the retained evidence.

#### Scenario: Refresh fails after successful diagnosis
- **WHEN** the operator refreshes a previously loaded Node and the read fails
- **THEN** the existing evidence remains visible as stale and the operator can retry without executing a Node action

#### Scenario: Refresh recovers
- **WHEN** a subsequent refresh succeeds
- **THEN** the evidence and timestamp update and normal action eligibility is restored

#### Scenario: Inspect an action preview
- **WHEN** the operator opens a Node action preview
- **THEN** it appears in the Actions section and receives focus, with a close control that returns focus to the originating action

### Requirement: Task-focused Node sections

The Nodes page SHALL separate Inventory, Admission, Runtime, and Diagnostics through page-local navigation.
Node detail SHALL separate Overview, Evidence, and Actions while retaining shared target identity and refresh state.
Sections SHALL use whitelisted URL parameters and replace visible content instead of acting as scroll anchors.
Inactive sections SHALL not remain reachable through keyboard navigation or the accessibility tree.

#### Scenario: Inspect evidence and return
- **WHEN** an operator switches from Node Overview to Evidence and reloads the URL
- **THEN** Evidence remains selected for the same target and Overview and Actions content remains hidden

#### Scenario: Unknown section
- **WHEN** a Node URL supplies an unsupported section
- **THEN** the page selects its default section without changing the target or authorizing an action

#### Scenario: Refreshed action facts change
- **WHEN** an open action preview changes after a data refresh
- **THEN** prior confirmation is cleared and execution requires review and confirmation of the updated preview
- **AND** a refresh with unchanged preview facts preserves the operator's confirmation

#### Scenario: Historical candidate evidence
- **WHEN** Evidence shows an admission candidate observed by a prior runtime status read
- **THEN** transport evidence identifies that observation and its timestamp rather than implying a current health check

#### Scenario: Follow a linked admitted Node
- **WHEN** the operator follows a candidate's linked Node from Admission Review
- **THEN** Back to Nodes preserves the Admission Review origin

### Requirement: Enrollment handoff preserves action context

The enrollment flow SHALL open the registered Node in Actions with Admission as its return destination.
An explicit successful Prepare action SHALL focus the next step heading without moving focus during automatic observation.

#### Scenario: Registered Node is ready for review
- **WHEN** an operator follows Review and Admit Node
- **THEN** the correct Node opens in Actions and Back returns to Admission

#### Scenario: Preparation advances the flow
- **WHEN** the operator successfully completes Prepare
- **THEN** the next step is visible and its heading receives focus
- **AND** later automatic observations do not move focus
