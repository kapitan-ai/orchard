# host-lifecycle-adapters Specification

## Purpose

Defines the portability boundary that isolates platform-native host lifecycle implementations from the portable Orchard control-plane core without claiming an unimplemented managed Node Agent replacement protocol.

## Requirements

### Requirement: Platform Lifecycle Authority Is Isolated

Platform-specific service installation, update, start, stop, uninstall, and status behavior SHALL be implemented behind a host lifecycle adapter rather than inside the managed Node Agent or portable Orchard control-plane core.
The current contract SHALL NOT infer a zero-overlap replacement guarantee, shared lifecycle exclusion protocol, durable start-eligibility state, or provisional launch protocol from that adapter boundary.

#### Scenario: Portable code requests a host lifecycle operation

- **WHEN** portable Orchard code invokes a supported host lifecycle operation
- **THEN** platform-native service-manager and filesystem mechanics remain inside the selected adapter
- **AND** the adapter boundary alone does not claim managed replacement safety that `SPEC.md` does not define

### Requirement: Future Managed Replacement Requires Separate Approval

A managed Node Agent replacement or handover protocol SHALL require a fresh accepted OpenSpec proposal and a separate implementing pull request before it becomes part of the host lifecycle interface.
The proposal SHALL define the supported platforms, process-observation semantics, failure recovery, identity-root safety, and conformance evidence without relying on superseded ADR 0018.

#### Scenario: Cross-process handover is proposed

- **WHEN** Orchard proposes automated replacement of a running Node Agent
- **THEN** the work cannot treat the existing adapter boundary or legacy PKG material as an accepted handover contract
- **AND** review starts from a new explicit lifecycle proposal

### Requirement: Platform Native Artifacts Are Isolated

Host adapters that require native platform code SHALL be built and validated only in compatible platform lanes and MUST NOT be unconditional compile dependencies of the portable umbrella.

#### Scenario: Linux portable compile excludes Darwin helper

- **WHEN** the portable umbrella compiles on Linux
- **THEN** Darwin lifecycle and terminal-custody sources are not compiled
- **AND** their absence does not remove platform-neutral Controller, Node Agent, Shared, or CLI modules
