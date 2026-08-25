## RENAMED Requirements

- FROM: `### Requirement: Lifecycle Authority Is External To The Managed Process`
- TO: `### Requirement: Platform Lifecycle Authority Is Isolated`

## ADDED Requirements

### Requirement: Future Managed Replacement Requires Separate Approval

A managed Node Agent replacement or handover protocol SHALL require a fresh accepted OpenSpec proposal and a separate implementing pull request before it becomes part of the host lifecycle interface.
The proposal SHALL define the supported platforms, process-observation semantics, failure recovery, identity-root safety, and conformance evidence without relying on superseded ADR 0018.

#### Scenario: Cross-process handover is proposed

- **WHEN** Orchard proposes automated replacement of a running Node Agent
- **THEN** the work cannot treat the existing adapter boundary or legacy PKG material as an accepted handover contract
- **AND** review starts from a new explicit lifecycle proposal

## MODIFIED Requirements

### Requirement: Platform Lifecycle Authority Is Isolated

Platform-specific service installation, update, start, stop, uninstall, and status behavior SHALL be implemented behind a host lifecycle adapter rather than inside the managed Node Agent or portable core.
The current contract SHALL NOT infer a zero-overlap replacement guarantee, shared lifecycle exclusion protocol, durable start-eligibility state, or provisional launch protocol from that adapter boundary.

#### Scenario: Portable code requests a host lifecycle operation

- **WHEN** portable Orchard code invokes a supported host lifecycle operation
- **THEN** platform-native service-manager and filesystem mechanics remain inside the selected adapter
- **AND** the adapter boundary alone does not claim managed replacement safety that `SPEC.md` does not define

## REMOVED Requirements

### Requirement: Platform-Neutral Managed Host Lifecycle

### Requirement: Platform Evidence Preserves Portable Outcomes
