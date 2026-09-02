## MODIFIED Requirements

### Requirement: Lifecycle Is Role-Aware, Transactional, And Retains Operator State

Installation SHALL require an explicit persistent role of `controller` or `node-agent` and SHALL install only the role-relevant services.
Role changes SHALL use a dedicated root-authorized transaction with quiesce, snapshot, apply, verify, commit, and rollback stages.
App-owned install and update SHALL preserve operator-owned `config`, `data`, `models`, `bundles`, `logs`, and non-app-owned contents under the retained `support/` namespace.
Default uninstall SHALL remove app-owned payloads, links, launchd plists, install markers, and app-owned support entries while retaining operator-owned contents.
Role-change failures SHALL restore the prior role and service state atomically or report a stopped but recoverable rollback-failed state with the recovery snapshot retained.

#### Scenario: Default uninstall preserves operator-owned state

- **WHEN** an administrator performs the default app-primary uninstall
- **THEN** Orchard removes executable service artifacts and app-owned support entries
- **AND** Orchard retains operator configuration, data, models, bundles, logs, and non-app-owned contents under the retained `support/` namespace
- **AND** Orchard reports the retained paths

#### Scenario: Role change fails verification

- **WHEN** the target role fails post-apply health verification
- **THEN** the helper restores the prior persistent role and enabled service state
- **AND** the prior installed payload remains runnable
