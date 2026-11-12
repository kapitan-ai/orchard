# Define the headless Controller deployment

## Why

Operators want to run Orchard without the Console and manage it through the API, the CLI, and later an MCP adapter.
Parts of this already exist or are already contracted:

- The production `orchard_controller` release starts with the Console disabled unless `ORCHARD_CONSOLE_ENABLED` is true and Console credentials are set.
- `SPEC.md` §§2.5 and 11.9 and ADR 0024 make Controller-owned domain operations the target authority that portable clients call, with today's local Controller-runtime `orchardctl` as the migration baseline.
- The first Operator API reads (`GET /ops/v1/cluster`, `/ops/v1/nodes`, `/ops/v1/nodes/:node_id`) shipped in the `add-operator-api-reads` change.

Two limits apply today:

- Source development, the active installation path under `SPEC.md` §11.0, defaults to the Console without authentication. Q7 adds an opt-out for routing and API-only testing, not production credential posture. Only a production `orchard_controller` release qualifies as a Headless Deployment, and that release has no supported distribution yet.
- Many management operations work without the Console only through `orchardctl` on the Controller host, because their Operator or Admin API routes are specified but not built.

`SPEC.md` does not yet say what a headless deployment is, what it keeps, what credentials manage it, or how Orchard may describe which capabilities it covers.
Without that, every later slice re-argues the same baseline, and documentation could claim headless coverage for capabilities that exist only in the Console (Model Hub, model lifecycle, Portal invites, request browsing, API Client disable) or only on the Controller host.

"Headless" already names the Linux Controller platform profile in `SPEC.md` §11.8 and ADR 0023, meaning a host with no desktop components. This change defines a separate concept, the headless deployment, meaning a Controller with no Console.

The product owner decided on 2026-11-09:

- Headless first means the Console disabled by runtime configuration, not removed from the build.
- The Developer Portal stays available in a headless deployment.
- Operator API reads start in parallel with the credential family in `cross-surface-authorization-contract`.

## What Changes

- Implement accepted Q7 in shared dev runtime configuration: both source-dev launchers honor `ORCHARD_CONSOLE_ENABLED`, default on, using the production strict parser. Enabled retains no-auth access; disabled requires no Console credentials and changes no API authorization or transport requirements.
- Define a **headless deployment** as the standard production Controller release with the Console disabled by boot-time runtime configuration, managed through the Public Inference, Operator, and Admin APIs and `orchardctl`. No separate build or package is introduced. Source development and the `SPEC.md` §10.11.4 `rollback_console_disabled` recovery state are explicitly not headless deployments.
- Require that disabling the Console does not change the authorization, audit, leadership, or Action Preview semantics of any other surface, and does not add a new authority path.
- Require that remote headless management uses only enabled API Client tokens with cluster-scoped `operator` or `admin` RoleBindings. Console Basic Auth, Console sessions, and Portal sessions never authorize it. First-admin bootstrap stays local, and unmigrated `orchardctl` families keep their `SPEC.md` §11.9 Controller-host authority.
- Require that a Console-disabled Controller renders no Console route and admits no Console LiveView mount. Shared browser infrastructure (the LiveView socket, session cookie, and static assets) may stay only because the Developer Portal needs it.
- Require a documented headless capability inventory that classifies each Console capability as `available`, `local_cli`, `planned`, `decided`, `undecided`, or `console_only`. `decided` records accepted headless direction without a named implementing contract; it does not imply availability. Documentation may describe a capability as remotely available headless only when the inventory marks it `available`.

## Out Of Scope

- Removing Console code from the build, a separate OTP application, or a headless-only release or package.
- New Operator or Admin API endpoints. Each one lands in its own change under the accepted main `operator-command-authority` spec, one command family at a time.
- Migrating `orchardctl` command families to HTTPS; ADR 0024 and the `cross-surface-authorization-contract` change own that order.
- Any MCP server or adapter. `design.md` records the accepted direction and its read-only authority prerequisite; implementation remains separate.
- Stopping Console-only background work, such as the Model Hub download coordinator, when the Console is disabled.
- Changes to the named Console authorization target in `SPEC.md` §10.11, including the `rollback_console_disabled` state.
- Distribution of a Controller package, which stays paused or deferred under `SPEC.md` §§1.4 and 11.0.

## SPEC.md Impact

This change adds a short headless-deployment definition to `SPEC.md` §2.3, distinct from the §11.8 headless platform profile.
The Q7 amendment replaces §2.3's always-on source-dev wording with a default-on strict switch and retains the exclusion from Headless Deployment. It amends this unarchived change's existing ADDED requirement, rather than trying to MODIFY a requirement not yet present in main specs.
It adds a §7.1 note that, when the Console is disabled, the Operator and Admin APIs are the remote management surface, and Controller-host `orchardctl` keeps its §11.9 local authority for unmigrated families.
It does not change the §7.3 or §7.4 admission boundaries, the §10.11 Console target, the §11.9 migration rule, or ADR 0011's local bootstrap.
The `cross-surface-authorization-contract` change also edits §§2.3 and 7.1; whichever change lands second rebases its `SPEC.md` text onto the first.
The Console-disabled route, mount, and credential-refusal behavior it requires already holds in the production release; this change makes it normative and adds regression coverage.

## Impact

- `SPEC.md` §§2.3 and 7.1, and a Headless Deployment entry in `docs/glossary/CONTEXT.md`.
- A new `headless-deployment` capability spec.
- A new operator document holding the headless capability inventory.
- Shared dev runtime configuration and regression tests for parsing and Console-disabled behavior across Console, Developer Portal, and API routes. Production release behavior is unchanged.
