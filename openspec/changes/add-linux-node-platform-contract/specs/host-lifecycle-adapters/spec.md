## MODIFIED Requirements

### Requirement: Platform Lifecycle Authority Is Isolated

Platform-specific service installation, update, start, stop, uninstall, and
status behavior SHALL be implemented behind a host lifecycle adapter rather than
inside the managed Node Agent or portable Orchard control-plane core.
The current contract SHALL NOT infer a zero-overlap replacement guarantee,
shared lifecycle exclusion protocol, durable start-eligibility state, or
provisional launch protocol from that adapter boundary.

The experimental Linux Node candidate SHALL use a systemd system-service adapter
and fixed Linux filesystem policy. The adapter SHALL support complete
relocated-root validation without invoking or mutating the host systemd manager.
systemd and process observations SHALL NOT imply an Orchard request-slot or
Resource Allocation release guarantee.

#### Scenario: Portable code requests a host lifecycle operation

- **WHEN** portable Orchard code invokes a supported host lifecycle operation
- **THEN** platform-native service-manager and filesystem mechanics remain inside the selected adapter
- **AND** the adapter boundary alone does not claim managed replacement safety that `SPEC.md` does not define

#### Scenario: Portable code requests Linux lifecycle status

- **WHEN** portable Orchard code invokes status for the Linux Node candidate
- **THEN** systemd and Linux filesystem mechanics remain inside the Linux adapter
- **AND** returned process facts do not grant scheduling or release authority

#### Scenario: Relocated lifecycle test runs

- **WHEN** the Linux adapter is configured with a non-system test root
- **THEN** every owned path is relocated and systemd effects are simulated
- **AND** no real-system unit or Orchard installation changes
