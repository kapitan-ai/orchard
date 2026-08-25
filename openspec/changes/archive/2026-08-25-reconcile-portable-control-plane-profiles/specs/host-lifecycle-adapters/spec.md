## MODIFIED Requirements

### Requirement: Platform Lifecycle Authority Is Isolated

Platform-specific service installation, update, start, stop, uninstall, and status behavior SHALL be implemented behind a host lifecycle adapter rather than inside the managed Node Agent or portable Orchard control-plane core.
The current contract SHALL NOT infer a zero-overlap replacement guarantee, shared lifecycle exclusion protocol, durable start-eligibility state, or provisional launch protocol from that adapter boundary.

#### Scenario: Portable code requests a host lifecycle operation

- **WHEN** portable Orchard code invokes a supported host lifecycle operation
- **THEN** platform-native service-manager and filesystem mechanics remain inside the selected adapter
- **AND** the adapter boundary alone does not claim managed replacement safety that `SPEC.md` does not define
