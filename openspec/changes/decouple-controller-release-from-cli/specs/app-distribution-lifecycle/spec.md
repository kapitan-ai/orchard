## ADDED Requirements

### Requirement: Packaged Wrapper And Controller Release Are One Compatibility Unit

The app-owned payload SHALL assemble, activate, and roll back the packaged `orchardctl` wrapper and Controller release as one compatibility unit.
Update SHALL stop selected services before replacing the release and wrapper trees and SHALL restore services only after the matching payload is present.
Rollback SHALL restore the prior release, wrapper, app-owned paths, and loaded-service state from the same transaction.
Either private-entrypoint skew direction SHALL fail closed without falling back to standalone Controller-state mutation.

#### Scenario: Matching payload is updated

- **WHEN** app-owned update activates a payload containing the new wrapper and Controller release
- **THEN** selected services are stopped before the release tree is replaced
- **AND** the matching wrapper is installed before those services are restored
- **AND** packaged allowlisted commands execute through the Controller-owned entrypoint after restoration

#### Scenario: Update fails after payload replacement

- **WHEN** app-owned update fails after replacing one or more app-owned payload paths
- **THEN** rollback restores the prior wrapper and Controller release together
- **AND** it restores the prior loaded-service state

#### Scenario: Wrapper and release versions are skewed

- **WHEN** an old wrapper targets the new Controller release or a new wrapper targets the old Controller release
- **THEN** the private command route fails closed
- **AND** it does not fall back to standalone Controller-state mutation
