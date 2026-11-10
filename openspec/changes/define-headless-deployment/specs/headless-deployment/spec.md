## ADDED Requirements

### Requirement: Headless Deployment Is A Console-Disabled Controller

A headless deployment SHALL be a Controller started as the standard production `orchard_controller` release with the Console disabled by boot-time runtime configuration.
That release SHALL disable the Console unless `ORCHARD_CONSOLE_ENABLED` holds a true value, so disabled remains its default; an invalid value SHALL stop boot.
A headless deployment SHALL keep serving the Public Inference API, the Operator API, the Admin API, the Developer Portal, the bootstrap API, the health endpoints, and `/metrics` under their existing contracts.
Orchard MUST NOT require a build, release, or package other than the standard Controller release to run headless.
Source development under `bin/dev` and `bin/dev-controller` always enables the Console and SHALL NOT be described as a headless deployment.
A Controller in the `SPEC.md` §10.11.4 `rollback_console_disabled` recovery state SHALL NOT be treated as a headless deployment; its §10.11.4 writer isolation, including for Developer Portal writers, SHALL prevail.
This requirement adds the headless deployment definition to `SPEC.md` §§2.3 and 7.1.
It is distinct from the headless Linux Controller platform profile of `SPEC.md` §11.8 and ADR 0023, which describes a host without desktop components.

#### Scenario: Production release starts without Console configuration

- **WHEN** the `orchard_controller` production release starts without `ORCHARD_CONSOLE_ENABLED` set to a true value
- **THEN** the Console is disabled
- **AND** `GET /health/ready`, `GET /ops/v1/cluster`, and `POST /v1/chat/completions` behave as they do with the Console enabled

#### Scenario: Developer Portal stays available headless

- **WHEN** an invited Portal User signs in to `/portal/:organization_slug` over TLS on a Controller with the Console disabled
- **THEN** the Developer Portal serves its key list, mint, and revoke flows under `SPEC.md` §7.4a

### Requirement: Disabling The Console Adds No Authority Path

Disabling the Console MUST NOT relax, bypass, or replace the authorization, audit, leadership, or Action Preview semantics of any other surface.
Orchard MUST NOT add a management path that exists only because the Console is disabled.
The convergence of Console, API, and CLI authority on shared Controller-owned domain operations remains governed by the `operator-command-authority` capability and `SPEC.md` §§2.5, 10.11, and 11.9; a headless deployment does not satisfy that target by itself.

#### Scenario: Standby refuses a Node read with or without Console

- **WHEN** a cluster operator calls `GET /ops/v1/nodes` on a Standby Controller
- **THEN** Orchard returns `503 controller_standby` whether the Console is enabled or disabled

### Requirement: Headless Management Credentials

Remote headless management SHALL authenticate a service-account-owned API Token whose owning API Client is enabled and holds the cluster-scoped `operator` or `admin` RoleBinding that `SPEC.md` §§7.3 and 7.4 require for the route.
Console Basic Auth credentials, Console sessions, Portal sessions, and Public Inference credentials MUST NOT authorize Operator API or Admin API requests.
Initial administrator provisioning SHALL remain the local Controller-host bootstrap operation of ADR 0011.
On the Controller host, `orchardctl` command families that have not migrated SHALL keep the local Controller-runtime authority that `SPEC.md` §11.9 and ADR 0024 retain as the migration baseline, until each family migrates.

#### Scenario: Console credentials are refused on the Operator API

- **WHEN** a caller sends `Accept: application/json` and the configured Console Basic Auth credentials to `GET /ops/v1/nodes`
- **THEN** Orchard returns `401 invalid_api_key`
- **AND** it returns no Node data

#### Scenario: Portal session is refused on the Admin API

- **WHEN** a caller sends `Accept: application/json` and only a valid Developer Portal session cookie to `GET /admin/v1/node-admission/candidates`
- **THEN** Orchard returns `401 invalid_api_key`
- **AND** it returns no Admission Candidate data

### Requirement: Console-Disabled Controller Exposes No Console Authority

When the Console is disabled, every `/console` route requested with an HTML or wildcard `Accept` SHALL return `404`, and no `/console` request SHALL render Console content.
No Console LiveView SHALL mount or reconnect, including over an existing LiveView socket or with a session issued while the Console was enabled.
Browser infrastructure that the Console shares with the Developer Portal, namely the LiveView socket, the endpoint session cookie, and static assets, MAY remain mounted only to serve the Developer Portal.
That shared infrastructure MUST NOT grant Console access or Console session authority.

#### Scenario: Console route is requested while disabled

- **WHEN** a browser requests `/console/nodes` with an HTML `Accept` on a Controller with the Console disabled
- **THEN** Orchard returns `404`
- **AND** it renders no Console content

#### Scenario: Stale Console session reconnects after Console is disabled

- **WHEN** a browser that held a Console session reconnects a Console LiveView after the Controller restarts with the Console disabled
- **THEN** the LiveView does not mount
- **AND** the browser receives no Console data

### Requirement: Headless Capability Inventory

Orchard SHALL maintain an operator-facing headless capability inventory that lists each Console capability and classifies it as one of:

- `available`: served by the Public Inference, Operator, or Admin API.
- `local_cli`: available only through Controller-host `orchardctl` under `SPEC.md` §11.9 local authority.
- `planned`: an API equivalent is owned by a named change or a `SPEC.md` contract section.
- `undecided`: blocked on a named product decision.
- `console_only`: deliberately left to the Console.

Orchard documentation and release notes SHALL describe a capability as remotely available in a headless deployment only when the inventory classifies it `available`, and SHALL qualify a `local_cli` capability as requiring Controller-host access.
A change that adds an Operator or Admin API equivalent for a Console capability, or migrates a `local_cli` family, SHALL update the inventory in the same change.

#### Scenario: Capability without an API is not claimed

- **WHEN** release notes describe headless operation while Model Hub acquisition has no Operator or Admin API
- **THEN** the release notes do not describe Model Hub acquisition as remotely available headless

#### Scenario: Controller-host CLI capability is qualified

- **WHEN** documentation describes Node drain in a headless deployment before an Operator API route exists for it
- **THEN** it states that drain requires `orchardctl` on the Controller host

#### Scenario: New API slice updates the inventory

- **WHEN** a change adds `GET /ops/v1/requests/:request_id`
- **THEN** the same change marks request details `available` in the inventory
