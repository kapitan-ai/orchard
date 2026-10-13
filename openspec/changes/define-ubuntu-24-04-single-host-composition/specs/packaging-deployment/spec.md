## MODIFIED Requirements

### Requirement: Ubuntu Single-Host Is Source-Development-Only

The accepted Ubuntu single-host contract SHALL use exactly one canonical
source-development checkout, installation UUID, fixed state/runtime roots, and
source manifest per host. Source preparation MUST NOT enable or start units,
initialize PostgreSQL, create product identities, enroll or admit a Node,
activate a provider or model, or publish capacity.
Retirement SHALL preserve database files, identities, configuration, models,
logs, backups, installation identity, and lifecycle receipts for validated
re-preparation. Debian package installation and qualification are outside the
current profile.
A future packaged distribution SHALL require a fresh accepted change and fenced
one-way handoff that prevents concurrent source and packaged Controllers.

#### Scenario: Source identity does not match one manifest

- **WHEN** preflight observes a checkout commit/tree, dependency/toolchain lock, generated output, component, schema, or protocol outside the source manifest
- **THEN** the composed start or upgrade fails before service or database mutation
- **AND** the mismatched source is not represented as the installation

#### Scenario: Future packaging is proposed

- **WHEN** a packaged Ubuntu distribution is proposed
- **THEN** it does not inherit source-development qualification or run beside the source Controller
- **AND** a separately accepted migration contract owns identity, retained-state, and authority cutover
