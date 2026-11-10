# Design: headless Controller deployment

## Context

The Console is a set of LiveView routes under `/console` on the Controller's Phoenix endpoint. `OrchardConsole.Auth` and the `:ensure_console_access` mount hook refuse every Console request and LiveView mount when the `:console` config has `enabled: false`.

Only the production `orchard_controller` release reads `ORCHARD_CONSOLE_ENABLED` (`config/runtime.exs`). It defaults to false, requires Basic Auth credentials when true, and stops boot on an invalid value. Source development (`bin/dev`, `bin/dev-controller`) runs with `MIX_ENV=dev`, where `config/config.exs` and `config/dev.exs` enable the Console with no authentication. Source development is the active installation path under `SPEC.md` §11.0, and the production release has no supported distribution yet, so a headless deployment is a contract target that only a production release can reach today.

The Developer Portal is also a LiveView surface on the same endpoint. It uses the same `/live` socket, the same endpoint session cookie (`_orchard_console_key`, which also carries the Portal token), and the static asset paths returned by `OrchardConsole.static_paths/0`.

Some code under the `OrchardConsole` namespace is not Console UI. `OrchardConsole.ModelHubDownloadCoordinator` is always supervised. `OrchardConsole.Runtime` backs `/ops/v1/health` and the shared Node memory-budget read, and the Operator reads take their runtime implementation from the `:console` config. The Portal uses `OrchardConsole.WorkspacePresentation`.

The management API surface is still partial. On `main`, the Operator API serves health, cluster and Node reads, request retry, worker recovery, scheduler explanations, and circuit breakers. The Admin API serves only Node admission. Most other management runs in Console LiveViews or in `orchardctl` commands that use the Controller Repo on the Controller host, which `SPEC.md` §11.9 and ADR 0024 keep as the migration baseline.

"Headless" already names the Linux Controller platform profile (`SPEC.md` §11.8, ADR 0023, `docs/glossary/CONTEXT.md`): a host with no desktop or tray components. A headless deployment is a different axis, a Controller with no Console, and can apply to any platform profile.

## Goals

- Give later slices one agreed definition of a headless deployment and its credential rules.
- Make the current Console-disabled behavior of the production release normative and covered by regression tests.
- Stop documentation from claiming headless coverage that the API does not provide, while still describing what works through Controller-host `orchardctl`.

## Non-Goals

- Shipping any new management endpoint.
- Removing Console code from the build.
- Changing source-development configuration.
- Designing an MCP server.

## Decisions

### D1. Disable the Console by runtime configuration and don't remove it from the build

A headless deployment is the standard production Controller release with the Console disabled at boot.

Alternatives considered:

- A separate OTP application or release without Console code. It reduces footprint and attack surface, but it needs non-UI code moved out of the `OrchardConsole` namespace, a second release to build and qualify, and a packaging decision while distribution is paused (`SPEC.md` §11.0).
- A compile-time flag. It has the same refactoring cost and also creates two differently compiled Controllers to test.

The runtime switch already exists and is the production default, so it costs nothing to adopt. The product owner chose it on 2026-11-09. Build exclusion stays possible later if footprint or attack surface requires it.

Source development is excluded from the definition rather than changed here. Making `bin/dev` honor `ORCHARD_CONSOLE_ENABLED=false` would be a small config change, but it is a product choice about the source-dev contract (Q7).

### D2. Keep shared browser infrastructure because the Portal needs it

An earlier draft assumed that a Console-disabled Controller would also stop mounting `/live`, the session cookie, and Console static assets. Keeping the Developer Portal (decided 2026-11-09) rules that out, because the Portal depends on all three.

The requirement is therefore about authority, not mounting. No Console route renders content and no Console LiveView mounts while the Console is disabled. The shared infrastructure stays only to serve the Portal.

The `/console` 404 is stated for HTML or wildcard `Accept`, because the browser pipeline's `:accepts` plug runs before `OrchardConsole.Auth` and answers other media types with `406`. Either way no Console content is rendered.

If the Portal later gets its own session cookie or socket, a separate change can stop mounting Console-only pieces.

### D3. Remote management uses API Client tokens; Controller-host CLI keeps its baseline

Remote headless management restates `SPEC.md` §§7.1, 7.3, and 7.4: an enabled API Client token with cluster-scoped `operator` or `admin` authority. Console Basic Auth exists only to admit the Console, and the bearer parser in `Orchard.API.ScopedRequestContext` already refuses it. Named Console identities under `SPEC.md` §10.11 do not change this, because Console Sessions never authorize the Operator or Admin API.

A headless deployment does not remove Controller-host `orchardctl` authority. ADR 0011 keeps first-admin bootstrap local, and `SPEC.md` §11.9 keeps each unmigrated command family on its local Controller-runtime authority until it migrates. The spec says so explicitly, so the headless definition does not read as an early migration claim.

The convergence of Console, API, and CLI on shared Controller-owned domain operations is a target owned by `operator-command-authority` and `SPEC.md` §§2.5 and 10.11. Today the Console uses shared Basic Auth with anonymous audit, so this change only requires that disabling the Console relaxes nothing. It does not claim convergence.

### D4. Track coverage in an inventory and don't gate on full parity

Whether a headless deployment requires full Console parity is still open (Q1). An inventory works under either answer:

- If full parity is required, the inventory is the checklist.
- If a subset is acceptable, the inventory records which capabilities are `console_only` by decision.

Classifications:

- `available`: served by the Public Inference, Operator, or Admin API, so remote headless clients can use it.
- `local_cli`: available only through Controller-host `orchardctl` under `SPEC.md` §11.9. It works in a headless deployment but needs Controller-host access.
- `planned`: an API equivalent is owned by a named change or `SPEC.md` contract section, and nothing headless serves it yet.
- `undecided`: blocked on a named product decision.
- `console_only`: deliberately left to the Console.

The inventory lives in an operator document rather than in `SPEC.md`, because it changes with every API slice. Initial content, as of `main` at `9e2689fc`:

| Capability | Classification | Path today | API owner |
| --- | --- | --- | --- |
| Inference (Console Playground) | `available` | `/v1` | — |
| Cluster and health overview | `available` | `/ops/v1/health`, `/ops/v1/cluster` | — |
| Node list and inspect | `available` | `/ops/v1/nodes`, `/ops/v1/nodes/:node_id` | — |
| Node admission review, admit, reject | `available` | `/admin/v1/node-admission/*`, `/admin/v1/nodes/:node_id/admit` | — |
| Scheduler explanation, request retry, worker recovery, circuit breakers | `available` | `/ops/v1` | — |
| Node cordon, uncordon, drain, cancel-drain, maintenance, resume, decommission | `local_cli` | `orchardctl nodes <action>` on the Controller host; preview, confirmation, and lifecycle blockers still apply; maintenance is preview-only on both surfaces until drain completion can be verified | `SPEC.md` §7.3.1, §7.4.1 |
| Node enrollment bundle issue | `local_cli` | `orchardctl nodes enrollment create` | `SPEC.md` §7.4.1 bootstrap tokens |
| Request details and captured output | `planned` | Console only (`orchardctl requests inspect` shows only the scheduler explanation, already `available`) | `SPEC.md` §7.3.1 `GET /ops/v1/requests/:request_id`, pending a capture-mode redaction decision |
| Request list and browsing | `undecided` (Q1) | Console only | — |
| Workspace create | `local_cli` | `orchardctl tenants create` | `SPEC.md` §7.4.1 `POST /admin/v1/tenants` |
| Workspace colleague handoff | `undecided` (Q1, Q6) | Console only | — |
| API Key create | `local_cli` | `orchardctl api-keys create` | `SPEC.md` §7.4.1 `POST /admin/v1/api-keys` |
| Credential revoke | `local_cli` | `orchardctl api-keys revoke` | `cross-surface-authorization-contract` |
| Credential list, inspect | `planned` | Console only | `cross-surface-authorization-contract` |
| API Client disable | `planned` | Console only | `SPEC.md` §7.4.1 service accounts |
| Active model list, import; delete of previously retired models | `local_cli` | `orchardctl models list`, `models import`, `models delete` on the Controller host; list shows active models only. Delete works only for a model already retired through the Console, with no non-terminal requests; retirement has no CLI or API path | `SPEC.md` §7.4.1 |
| Full model catalog (inactive, deprecated, retired) | `planned` | Console only | `SPEC.md` §7.4.1 `GET /admin/v1/models` |
| Model activate, deprecate, retire | `planned` | Console, or `orchardctl models import --activate` at import | `SPEC.md` §7.4.1 |
| Tenant model grants, routing policy | `local_cli` | `orchardctl models access|routing-policy` | `SPEC.md` §7.4.1 routing policies |
| Model Hub search and download | `undecided` (Q5) | Console only | — |
| Portal User create, invite, disable | `undecided` (Q6) | Console only | no API route specified |
| Playground inference defaults | `undecided` (Q1) | Console settings only; proposed `console_only`, pending a product-owner decision | — |

### D5. Defer MCP and propose a client-side adapter

MCP is out of scope for this change. The proposed direction, recorded so later changes start from it:

- The first Orchard MCP server is a client-side stdio adapter that calls the public Operator and Admin APIs with a protected, least-privilege API Client token. It does not run inside the Controller.
- It is read-only first. Mutating tools come only after the matching Action Preview exists, and they use `dry_run` plus explicit confirmation codes.
- It gives the Controller no tool-execution authority (`SPEC.md` §1.4 Agentic Execution Profile, `docs/decisions/0034-responses-tool-boundary.md`).
- It covers only `available` inventory rows. `local_cli` rows need Controller-host access, which an MCP client should not get.

A remote MCP endpoint on the Controller would need it to act as an OAuth 2.1 resource server under the current MCP authorization specification. Orchard has no such authorization server, which is why the client-side adapter is preferred.

## Open Questions For The Product Owner

These do not block accepting this change. They block the slices that depend on them.

- **Q1. Parity bar.** Must a headless deployment reach full Console parity before Orchard calls it a supported mode, or is a defined subset enough? Do `local_cli` rows count toward that bar? This decides the `console_only` and `undecided` entries in the inventory.
- **Q2. MCP placement.** Client-side stdio adapter (D5) or a remote MCP endpoint on the Controller?
- **Q3. MCP write authority.** May an agent ever drain, decommission, or revoke? If so, under `operator`/`admin`, or under a narrower dedicated role?
- **Q4. Target topology.** Is headless aimed at the Linux Controller profile and a single-host Ubuntu appliance, at macOS, or at both? The requirements here are profile-neutral. The answer affects which slices come first.
- **Q5. Model Hub.** Should Hugging Face acquisition get an API, stay Console-only, or be replaced headless by `models import` from local paths?
- **Q6. Portal User administration.** Should Portal User create, invite, and disable get Admin API routes, so that a headless deployment can onboard Portal Users? Or is onboarding Portal Users a reason to enable the Console?
- **Q7. Source development.** Should source development honor `ORCHARD_CONSOLE_ENABLED=false`, so headless can be exercised on the active installation path before a production release is distributed?

## Risks And Trade-offs

- **No reachable headless install today.** Only the production `orchard_controller` release can disable the Console, and it has no supported distribution while source development is the active path. Until Q7 is answered or distribution resumes, the regression tests in `tasks.md` are the main evidence.
- **Shared browser surface.** A Console-disabled Controller still mounts the LiveView socket and session cookie for the Portal. The Console mount check is the only barrier, and the regression tests cover it, including stale sessions after a restart.
- **The Portal can't onboard users headless.** `SPEC.md` §7.4a makes Copy invite a Console action, and §7.4.1 lists no Admin API route for creating, inviting, or disabling Portal Users. Existing Portal Users keep working in a headless deployment, but new ones need the Console. This is the largest gap behind the decision to keep the Portal.
- **Unused Console background work.** The Model Hub download coordinator is supervised even when the Console is disabled. It keeps only in-memory state, starts idle, and is called only from Console LiveViews, so a Console-disabled boot never has a download in flight. Not starting it is a footprint question only.
- **Inventory drift.** The inventory goes stale if an API slice forgets to update it. The requirement puts the update in the same change, and `tasks.md` adds the rule to the review gates and the pull request checklist.
- **Local CLI authority remains.** `orchardctl` keeps direct-Repo authority on the Controller host until each family migrates under `SPEC.md` §11.9. A headless deployment does not remove that path. Families that migrate do.
- **Overlap with `cross-surface-authorization-contract`.** Both changes edit `SPEC.md` §§2.3 and 7.1. Whichever lands second rebases its `SPEC.md` text onto the first. A Controller in that change's `rollback_console_disabled` state is not a headless deployment, and its writer isolation prevails.

## Migration

None. Existing Console-disabled production releases already meet these requirements. Console-enabled Controllers and source development are unaffected.
