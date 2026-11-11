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

Source development is excluded from the definition rather than changed here. Q7 accepts a follow-up that makes both `bin/dev` and `bin/dev-controller` honor `ORCHARD_CONSOLE_ENABLED`, defaulting to on. That follow-up must amend the always-on wording in `SPEC.md` §2.3 and this change's spec delta while retaining the exclusion from the Headless Deployment definition.

### D2. Keep shared browser infrastructure because the Portal needs it

An earlier draft assumed that a Console-disabled Controller would also stop mounting `/live`, the session cookie, and Console static assets. Keeping the Developer Portal (decided 2026-11-09) rules that out, because the Portal depends on all three.

The requirement is therefore about authority, not mounting. No Console route renders content and no Console LiveView mounts while the Console is disabled. The shared infrastructure stays only to serve the Portal.

The `/console` 404 is stated for HTML or wildcard `Accept`, because the browser pipeline's `:accepts` plug runs before `OrchardConsole.Auth` and answers other media types with `406`. Either way no Console content is rendered.

If the Portal later gets its own session cookie or socket, a separate change can stop mounting Console-only pieces.

### D3. Remote management uses API Client tokens; Controller-host CLI keeps its baseline

Remote headless management restates `SPEC.md` §§7.1, 7.3, and 7.4: an enabled API Client token with cluster-scoped `operator` or `admin` authority. Console Basic Auth exists only to admit the Console, and the bearer parser in `Orchard.API.ScopedRequestContext` already refuses it. Named Console identities under `SPEC.md` §10.11 do not change this, because Console Sessions never authorize the Operator or Admin API.

A headless deployment does not remove Controller-host `orchardctl` authority. ADR 0011 keeps first-admin bootstrap local, and `SPEC.md` §11.9 keeps each unmigrated command family on its local Controller-runtime authority until it migrates. The spec says so explicitly, so the headless definition does not read as an early migration claim.

The convergence of Console, API, and CLI on shared Controller-owned domain operations is a target owned by the accepted main spec [`operator-command-authority`](../../specs/operator-command-authority/spec.md) and `SPEC.md` §§2.5 and 10.11, not an open change of that name. Today the Console uses shared Basic Auth with anonymous audit, so this change only requires that disabling the Console relaxes nothing. It does not claim convergence.

### D4. Track coverage in an inventory and don't gate on full parity

Najib accepted the Q1 parity bar on 2026-11-11: a named subset of must-have operator journeys, not full Console parity:

- Bootstrap.
- Admit Nodes.
- Issue keys.
- Import and activate a model.
- Monitor.
- Contain an incident.

This is a target, not a claim that every journey works headless today. `local_cli` counts only as host-assisted operation, never toward a remote API or MCP claim; unmigrated Controller-state command families are expected to migrate under `SPEC.md` §11.9 and Milestone 8. First-admin bootstrap remains host-local under ADR 0011.

| Classification | Meaning |
| --- | --- |
| `available` | Served remotely by the Public Inference, Operator, or Admin API under that route's existing contract. |
| `local_cli` | Available through Controller-host `orchardctl` under §11.9; requires host access, not just an API credential. |
| `planned` | An API equivalent has a named OpenSpec or `SPEC.md` owner but is not implemented. |
| `decided` | Headless direction accepted, but no named implementing OpenSpec change or `SPEC.md` contract yet; not an availability claim. |
| `undecided` | A named product decision is still required. |
| `console_only` | Deliberately left to the Console by an accepted decision. |

`decided` distinguishes an accepted direction from a named implementing contract without weakening `planned`. The spec delta enumerates the classes and includes this addition; `SPEC.md` §2.3 requires distinguishing availability from unimplemented or undecided capabilities without enumerating class names. No SPEC behavior changes here. Request list remains `undecided` until a SPEC amendment names its contract, as Q1 requires.

The inventory is mirrored in [the operator document](../../../docs/headless-mode.md#headless-capability-inventory), because it changes with every API slice. Its implementation baseline is main at `6b256768886260b79dac1a01f088638663ecba2a`; classifications include Najib's decisions of 2026-11-11.

| Capability | Classification | Path today and limits | API owner or pending decision |
| --- | --- | --- | --- |
| Inference (Console Playground) | `available` | `POST /v1/chat/completions`, `POST /v1/responses`; authorized model discovery at `GET /v1/models` | — |
| Cluster and health overview | `available` | `GET /ops/v1/health`, `GET /ops/v1/cluster` | — |
| Node list and inspect | `available` | `GET /ops/v1/nodes`, `GET /ops/v1/nodes/:node_id`; Active Controller required | — |
| Node admission review, admit, reject | `available` | `/admin/v1/node-admission/candidates`, candidate detail/reject/clear-rejection, `POST /admin/v1/nodes/:node_id/admit` | — |
| Scheduler explanation, request retry, worker recovery, circuit breakers | `available` | `/ops/v1/scheduler/explanations/:request_id`, `/ops/v1/requests/:id/retry`, `/ops/v1/worker-recovery/nodes/:node_id/models/:model_id`, `/ops/v1/circuit-breakers/*` | — |
| Node cordon, uncordon, drain, cancel-drain, maintenance, resume, decommission | `local_cli` | `orchardctl nodes <action>` on the Controller host; preview, confirmation, and lifecycle blockers still apply; maintenance is preview-only on both surfaces until drain completion can be verified | `SPEC.md` §§7.3.1, 7.4.1; cancel-drain has no specified API route |
| Node enrollment bundle issue | `local_cli` | `orchardctl nodes enrollment create` on the Controller host | `SPEC.md` §7.4.1 bootstrap tokens |
| Request details and captured output | `planned` | Console only; `orchardctl requests inspect` shows only the persisted scheduler explanation, already available through the API | `SPEC.md` §7.3.1 `GET /ops/v1/requests/:request_id`, pending a capture-mode redaction decision |
| Request list and browsing | `undecided` | Console only | Q1: a SPEC amendment must name the request-list contract before this can be `planned`; §7.3.1 specifies details only |
| Workspace create | `local_cli` | `orchardctl tenants create` on the Controller host | `SPEC.md` §7.4.1 `POST /admin/v1/tenants` |
| Guided Workspace colleague handoff | `console_only` | Console guided UI; its primitives are tracked separately below | Q1 and Q6: Portal User primitives get future Admin API routes |
| API Key create | `local_cli` | `orchardctl api-keys create` on the Controller host; Portal self-service is separate and limited to the signed-in user's keys | `SPEC.md` §7.4.1 `POST /admin/v1/api-keys` |
| Credential revoke | `local_cli` | `orchardctl api-keys revoke` on the Controller host for persisted API credentials; no named Console Session implementation yet | `cross-surface-authorization-contract`, `SPEC.md` §10.11 |
| Credential list, inspect | `planned` | Console credential summaries only; the accepted cross-surface credential family is not implemented | `cross-surface-authorization-contract`, `SPEC.md` §10.11 |
| API Client disable | `planned` | Console only | `SPEC.md` §7.4.1 service accounts |
| Active model list, bundle import and activation at import | `local_cli` | `orchardctl models list` shows active models only; `orchardctl models import --activate` imports an Orchard Artifact Bundle from a Controller-host path, not raw weights | `SPEC.md` §§7.4.1, 7.4.5: future `POST /admin/v1/models/import` with `source_type: local_path` |
| Delete of previously retired models | `local_cli` | `orchardctl models delete` requires a model already retired through the Console and no non-terminal requests; the complete retire-then-delete journey has no headless path today | `SPEC.md` §7.4.1 owns retirement; no delete API route specified |
| Full model catalog (inactive, deprecated, retired) | `planned` | Console only; `/v1/models` is an authorized active-model view, not the full management catalog | `SPEC.md` §7.4.1 `GET /admin/v1/models` |
| Model activate after import, deprecate, retire | `planned` | Console only; no CLI or API path for deprecate or retire | `SPEC.md` §7.4.1 |
| Tenant model grants, routing policy | `local_cli` | `orchardctl models access` and `models routing-policy` on the Controller host | `SPEC.md` §7.4.1 routing policies |
| Model Hub search and download | `console_only` | Console only; a Hugging Face download API is deferred, not the specified bundle-import API | Q5 |
| Offline bundle preparation | `decided` | No supported offline CLI command; bundle building currently depends on Console Model Hub or dev scripts | Q5: implementing contract not yet named |
| Portal User list, inspect, create, invite or reissue, disable | `decided` | Console only; no Admin API routes specified. Disable ends sessions, not minted API Keys | Q6: implementing contract and §7.4a amendments still needed, after `cross-surface-authorization-contract` implements shared fences, retained-writer ledger, and audit surface |
| Playground inference defaults | `console_only` | Console settings only | Q1 |

Model deprecate and retire (and thus the complete delete journey), API Client disable for incident containment, and credential list have no headless path today. They remain explicit gaps in the accepted journey target, even when an API contract is already `planned`.

### D5. Defer MCP implementation; accept a client-side adapter after read-only authority

MCP remains out of scope for this implementation. Najib accepted Q2 and Q3 on 2026-11-11:

- First add a server-enforced read-only cluster role, with a `SPEC.md` §10.4 amendment, before any MCP work. The current `operator` role can mutate; a read-only tool list on an `operator` token is not read-only authority.
- The first adapter is client-side stdio, preferably a mode of portable `orchardctl` that reuses its protected token file and pinned TLS. It requires `reverse_proxy` or `direct_https`; `plain_http_localhost` would require Controller-host access. It does not run inside the Controller. A separately hosted MCP gateway behind the operator's IdP remains a later option.
- Reads leave out request content by default because it would reach the agent's model provider. Read-only coverage depends on both eligible APIs and the new server-enforced authority, not just tool annotations.
- Later writes require an explicit allowlist, the matching Operator API route and Action Preview, and human approval bound to action, target, and expiry. MCP elicitation is client-side; a confirmation code the agent can echo is not human approval. Reversibility alone is not the test: drain can cancel requests and cordoning all Nodes stops scheduling.
- The later write-capable adapter holds `operator`, not `admin`. Decommission, revoke, credential and token creation, Portal invites, Node admit, and enrollment bundles stay out without a separate reviewed change. Invite URLs stay out of MCP.
- It gives the Controller no tool-execution authority (`SPEC.md` §1.4 Agentic Execution Profile, [0034-responses-tool-boundary.md](../../../docs/decisions/0034-responses-tool-boundary.md), explicitly not the other ADR numbered 0034).
- It covers only eligible `available` inventory rows. API availability alone does not admit a tool; `local_cli` rows and host-path model acquisition are not MCP coverage.

The MCP specification makes authorization optional and permits an external authorization server. Lack of an Orchard authorization server is not the reason for this placement. The reasons are no new Controller network surface, the client-owned tool boundary, and the prohibition on passing MCP client tokens through to upstream APIs.

## Product Owner Answers Q1–Q7

**Decided 2026-11-11, Najib (product owner): all seven answers accepted.** These record follow-up direction, not implementation or an amendment of current SPEC behavior. Required contract changes are open items in [tasks section 3](tasks.md#3-open-items-outside-this-change).

- **Q1. Parity bar — defined subset.** The must-have journeys are bootstrap, admit Nodes, issue keys, import and activate a model, monitor, and contain an incident (D4). `local_cli` counts only as host-assisted operation, never remote API or MCP coverage, and unmigrated Controller-state families are expected to migrate. Playground defaults and the guided Workspace colleague handoff are `console_only`; Q6 accepts API routes for the handoff's primitives. Request list remains `undecided` until a SPEC amendment names it; §7.3.1 currently specifies only request details. Model deprecate and retire (and therefore the full delete journey), API Client disable, and credential list have no headless path today.
- **Q2. MCP placement — client-side stdio first.** Prefer a mode of portable `orchardctl` reusing token-file custody and pinned TLS over `reverse_proxy` or `direct_https`. A separately hosted gateway behind the operator's IdP remains a later option. D5 records the corrected rationale: no new Controller network surface, client-owned tools, and no token passthrough, not a requirement for Orchard to build an authorization server.
- **Q3. MCP write authority — server-enforced read-only role first.** Amend §10.4 before any MCP work; current roles do not supply this boundary. Reads omit request content by default. Later writes require an explicit allowlist, their Operator API route and Action Preview, and human approval bound to action, target, and expiry through client-side MCP elicitation. The later write-capable adapter holds `operator`, not `admin`; D5 lists the excluded admin actions. Neither an echoable confirmation code nor a tool allowlist establishes a human or server authorization boundary. Those exclusions require a separate reviewed change to revisit.
- **Q4. Target topology — profile-neutral, Milestone 8 priority.** Prioritize a Linux Controller with external Postgres managing admitted macOS Nodes. A single-host Ubuntu appliance is not a target for now. macOS source development keeps being tested and, after Q7, is where Console-disabled routing can first be tried on the active installation path. §11.8's headless platform profile means no desktop, not no Console. No support claim is made.
- **Q5. Model Hub — bundle import, not raw weights.** Headless acquisition means importing an Orchard Artifact Bundle from a Controller-host path. Add an offline bundle-preparation command so a Hugging Face snapshot can become a bundle without the Console. Implement the specified `POST /admin/v1/models/import` with `source_type: local_path` later (§§7.4.1, 7.4.5). Defer only a Hugging Face download API (§11.7: no required network egress); Model Hub search and download stay Console-only. Host-path acquisition does not become MCP coverage.
- **Q6. Portal User administration — yes, after shared authorization implementation.** Add Admin API list, inspect, create, invite or reissue, and disable routes after `cross-surface-authorization-contract` implements its shared fences, retained-writer ledger, and audit surface, not merely after its docs land. A follow-up must amend §7.4a, which normatively names the Console, and specify the Admin routes. Existing `Orchard.Governance.PortalGovernance` domain operations are the basis. Disable ends sessions but leaves minted API Keys working; route docs must say so. Invite URLs stay out of MCP. Until then, tenant keys come from `orchardctl api-keys create`.
- **Q7. Source development — yes, default on.** A follow-up will read `ORCHARD_CONSOLE_ENABLED` in shared dev config for both `bin/dev` and `bin/dev-controller`, using the strict parser and defaulting to on. It must amend §2.3's "always enables" sentence and this change's spec delta while keeping "SHALL NOT be described as a Headless Deployment". This tests routing and API-only operation, not production credential posture. The Portal still returns 404 on the default dev transport; Portal onboarding tests need `reverse_proxy`.

## Risks And Trade-offs

- **No reachable headless install today.** Only the production `orchard_controller` release can disable the Console, and it has no supported distribution while source development is the active path. Until the Q7 follow-up is implemented or distribution resumes, the regression tests in `tasks.md` are the main evidence.
- **Shared browser surface.** A Console-disabled Controller still mounts the LiveView socket and session cookie for the Portal. The Console mount check is the only barrier, and the regression tests cover it, including stale sessions after a restart.
- **The Portal can't onboard users headless.** `SPEC.md` §7.4a makes Copy invite a Console action, and §7.4.1 lists no Admin API route for creating, inviting, or disabling Portal Users. Existing Portal Users keep working in a headless deployment, but new ones need the Console. This is the largest gap behind the decision to keep the Portal.
- **Unused Console background work.** The Model Hub download coordinator is supervised even when the Console is disabled. It keeps only in-memory state, starts idle, and is called only from Console LiveViews, so a Console-disabled boot never has a download in flight. Not starting it is a footprint question only.
- **Inventory drift.** The inventory goes stale if an API slice forgets to update it. The requirement puts the update in the same change, and `tasks.md` adds the rule to the review gates and the pull request checklist.
- **Local CLI authority remains.** `orchardctl` keeps direct-Repo authority on the Controller host until each family migrates under `SPEC.md` §11.9. A headless deployment does not remove that path. Families that migrate do.
- **Overlap with `cross-surface-authorization-contract`.** Both changes edit `SPEC.md` §§2.3 and 7.1. Whichever lands second rebases its `SPEC.md` text onto the first. A Controller in that change's `rollback_console_disabled` state is not a headless deployment, and its writer isolation prevails.

## Migration

None. Existing Console-disabled production releases already meet these requirements. Console-enabled Controllers and source development are unaffected.
