## ADDED Requirements

### Requirement: Generic observation requires Controller write authority

Generic Runtime Endpoint status observation and candidate-only observation SHALL
authorize the `:node_lifecycle` write path before durable persistence. This implements
`SPEC.md` §3.3, §4.5, and §5.4.

#### Scenario: Standby generic status observes an unresolved target

- **WHEN** a standby Controller receives a valid generic status observation for an
  unresolved target
- **THEN** it returns the existing no-op result
- **AND** it creates or updates no admission candidate, Node, heartbeat, or capacity evidence

#### Scenario: Denied generic status safely invalidates an original target's hints

- **WHEN** generic status is refused for Controller write authority
- **AND** its original target safely resolves to a Node
- **AND** the Controller observation time is newer than that Node's heartbeat or no heartbeat exists
- **AND** any status payload Node identity does not determine source ownership
- **THEN** Orchard clears only that Node's aggregate, placement, and cold queue sources
- **AND** the clear does not invoke immediate queue promotion

#### Scenario: Denied generic status cannot order target evidence

- **WHEN** generic status is refused for Controller write authority
- **AND** the observation time is older, equal, invalid, or unordered, or target ownership is unresolved
- **THEN** Orchard clears no queue source and publishes no positive capacity

#### Scenario: Candidate-only denial remains queue-inert

- **WHEN** candidate-only observation is refused for Controller write authority
- **THEN** it creates or updates no candidate or Node
- **AND** it refreshes or clears no queue source
