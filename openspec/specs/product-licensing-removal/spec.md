# product-licensing-removal Specification

## Purpose
Define Orchard's license-free product behavior while preserving legal, dependency, signing, model-metadata, and inert-compatibility boundaries.

## Requirements
### Requirement: Orchard product behavior is license-free

Orchard SHALL NOT require, activate, validate, inspect, or enforce a product license or entitlement for any product behavior.

#### Scenario: Useful work without a product license

- **WHEN** an authenticated and authorized caller uses an Orchard product path without a product-license bundle
- **THEN** the request is evaluated by the same authentication, authorization, governance, quota, admission, and runtime rules as any other request
- **AND** no license or entitlement check denies or changes the request

#### Scenario: Legacy invalid licensing configuration

- **WHEN** an existing install supplies a legacy `ORCHARD_LICENSE_*` or product-licensing `ORCHARD_KEYGEN_*` environment variable with any value
- **THEN** Orchard ignores it
- **AND** Controller and Node Agent startup do not fail because of it

### Requirement: Product-license interfaces are absent

Orchard SHALL NOT expose product-license activation, status, remediation, feature-gate, health, Console, CLI, telemetry, or support interfaces.

#### Scenario: Operator inspects Orchard

- **WHEN** an operator uses Console, authenticated health, logs, telemetry, Sentry, status, or support collection
- **THEN** no product-license state, identifier, licensee, machine-license identity, tracking metadata, activation guidance, badge, or card is exposed

#### Scenario: Operator invokes the removed CLI namespace

- **WHEN** an operator invokes `orchardctl license`
- **THEN** the CLI follows ordinary unknown-command behavior
- **AND** it does not activate, inspect, or modify a legacy bundle

### Requirement: Existing product-license artifacts remain inert

Orchard SHALL preserve upgrade and rollback safety by leaving existing product-license bundle files untouched and inert.

#### Scenario: Upgrade with an existing bundle

- **WHEN** Orchard starts or operates after upgrade and a legacy license bundle exists
- **THEN** Orchard does not read, validate, rewrite, migrate, or delete the bundle
- **AND** product behavior is identical to an install without that bundle

#### Scenario: Rollback after removal

- **WHEN** an operator rolls back to a release that still implements product licensing
- **THEN** the previously stored bundle remains available unless the operator independently removed it
- **AND** no database restoration is required by this change

### Requirement: Legal and unrelated controls remain intact

Product-license removal SHALL preserve legal attribution and controls that are not derived from product licensing.

#### Scenario: Distribution after removal

- **WHEN** Orchard source or artifacts are distributed
- **THEN** the repository License section in `README.md`, copyright notices, third-party dependency license metadata, and required legal attribution remain intact
- **AND** model-card `license` metadata resolved from model sources remains recorded and surfaced unchanged
- **AND** macOS code-signing entitlements remain governed by the packaging contract

#### Scenario: Protected operation after removal

- **WHEN** a caller attempts an operation protected by authentication, authorization, governance, quota, Node admission, transport identity, or artifact verification
- **THEN** the corresponding control remains enforced
- **AND** product-license removal does not act as a bypass
