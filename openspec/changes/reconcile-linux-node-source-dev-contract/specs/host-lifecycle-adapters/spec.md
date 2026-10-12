## ADDED Requirements

### Requirement: Linux Node Candidate Lifecycle Stays Behind A Linux Adapter

Linux Node candidate service-manager, filesystem, and process-supervision mechanics SHALL be implemented behind a Linux host lifecycle adapter rather than inside the portable Node Agent or portable Orchard control-plane core.
The adapter SHALL support complete relocated-root validation that relocates every path it manages and simulates systemd effects without invoking or mutating the host systemd manager.
The adapter SHALL NOT define a zero-overlap replacement, shared lifecycle exclusion, or managed handover protocol.
Process, cgroup, and unit state returned by the adapter SHALL NOT grant scheduling, custody, or release authority.
This requirement changes `SPEC.md` §§4.9 and 13.4.

#### Scenario: Portable code requests Linux lifecycle status

- **WHEN** portable Orchard code requests status for a candidate Node
- **THEN** systemd and Linux filesystem mechanics remain inside the Linux adapter
- **AND** the returned process facts grant no scheduling or release authority

#### Scenario: Relocated lifecycle test runs

- **WHEN** the Linux adapter is configured with a non-system test root
- **THEN** every managed path is relocated and systemd effects are simulated
- **AND** no real systemd unit or Orchard installation on the host changes
