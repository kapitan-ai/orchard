## MODIFIED Requirements

### Requirement: Operator State Is Preserved

App-owned install and update SHALL preserve operator-owned `config`, `data`, `models`, `bundles`, `logs`, and non-app-owned contents under the retained `support/` namespace.
Default uninstall SHALL retain those paths and contents while removing app-owned payloads, links, launchd plists, install markers, and app-owned support entries.

#### Scenario: Default uninstall retains recoverable state

- **WHEN** an operator runs app-owned uninstall without a separately approved destructive purge operation
- **THEN** Orchard removes executable service artifacts and app-owned support entries
- **AND** Orchard retains operator configuration, data, models, bundles, logs, and non-app-owned contents under the retained `support/` namespace
