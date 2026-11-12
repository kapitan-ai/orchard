# Headless Deployment

A **Headless Deployment** is the standard production `orchard_controller` release started with the Console disabled by boot-time runtime configuration. It is not a separate build, release, or package. `SPEC.md` §§2.3 and 7.1 define the contract; the accepted [`define-headless-deployment` change](../openspec/changes/define-headless-deployment/proposal.md) records its scope and follow-up decisions.

## Production release only today

The production Controller defaults to Console disabled. `ORCHARD_CONSOLE_ENABLED` must hold a true value to enable it, with Console credentials configured; an invalid boolean value stops boot.

Source development through `bin/dev` and `bin/dev-controller` honors the same flag through the same strict parser, but defaults to enabled. True retains the no-auth dev Console; false requires no Console credentials and leaves API authentication unchanged. An invalid value stops boot. This exercises Console-disabled routing and API-only operation, not production credential posture; source development SHALL NOT be described as a Headless Deployment. See [the source-dev switch](local-dev.md#console-switch) for usage. The Developer Portal still returns `404` on default `plain_http_localhost` dev transport; Portal flows need `reverse_proxy`.

Source development remains the active installation path under `SPEC.md` §11.0. The production Controller release has no supported distribution today, and native `Orchard.app` and DMG distribution remains paused. This document is not an installation or support claim and does not lift any distribution gate.

Headless Deployment means **no Console**, on any otherwise qualified platform. The §11.8 headless Linux Controller platform profile means **no desktop components** on the host; these are separate properties.

The §10.11.4 `rollback_console_disabled` recovery state is not a Headless Deployment. Its writer-isolation requirements, including isolation of Developer Portal writers, take precedence over the ordinary behavior described here.

## Surfaces and credentials

Disabling the Console leaves the Public Inference, Operator and Admin APIs, Developer Portal, bootstrap API, health endpoints, and `/metrics` under their existing contracts. It changes no authorization, audit, leadership, or Action Preview requirements and creates no additional management authority. It does not establish the future shared-operation convergence in `SPEC.md` §§2.5, 10.11, and 11.9.

- Remote management uses a service-account-owned Bearer API Token whose API Client is enabled. Operator routes require a cluster-scoped `operator` or `admin` RoleBinding; Admin routes require cluster-scoped `admin` authority. A token's ability to call Public Inference alone is not management authority.
- Console Basic Auth credentials, Console sessions, Portal sessions, tenant-direct API Keys, and tenant-scoped access never authorize remote management.
- First-admin provisioning remains local to the Controller host through `orchardctl cluster init`, under ADR 0011 and `SPEC.md` §11.9. Bootstrap Tokens remain Node-join credentials, not administrator credentials.
- Unmigrated `orchardctl` families retain §11.9 local Controller-runtime authority and require Controller-host access. They are not portable HTTPS clients until separately migrated under ADR 0024.
- Existing invited Portal Users can redeem an invite, sign in, list, mint, and revoke their own Workspace-scoped keys over TLS under §7.4a. Portal access does not grant Console or management API authority. Creating, inviting, and disabling Portal Users still requires the Console; there is no Admin API equivalent today.

With the Console disabled, HTML or wildcard requests to `/console` routes return `404`. Unsupported media types may return `406` before the Console guard; no request renders Console content. Console LiveView mounts and reconnects are refused even with a session issued while the Console was enabled. The shared `/live` socket, endpoint session cookie, and static assets remain for the Portal, not as a Console access path.

## Headless capability inventory

This inventory describes current implementation, not every endpoint specified as a target in `SPEC.md`. Its implementation baseline is main at `6b256768886260b79dac1a01f088638663ecba2a`; classifications include Najib's decisions of 2026-11-11.

The accepted parity bar is a named subset of must-have operator journeys: bootstrap, admit Nodes, issue keys, import and activate a model, monitor, and contain an incident. This is a target, not a claim that every journey works headless today. `local_cli` counts only as host-assisted operation, never toward a remote API or MCP claim; unmigrated Controller-state command families are expected to migrate under `SPEC.md` §11.9 and Milestone 8. First-admin bootstrap remains host-local under ADR 0011.

| Classification | Meaning |
| --- | --- |
| `available` | Served remotely by the Public Inference, Operator, or Admin API under that route's existing contract. |
| `local_cli` | Available through Controller-host `orchardctl` under §11.9; requires host access, not just an API credential. |
| `planned` | An API equivalent has a named OpenSpec or `SPEC.md` owner but is not implemented. |
| `decided` | Headless direction accepted, but no named implementing OpenSpec change or `SPEC.md` contract yet; not an availability claim. |
| `undecided` | A named product decision is still required. |
| `console_only` | Deliberately left to the Console by an accepted decision. |

The Q references below refer to [the product owner's accepted answers](../openspec/changes/define-headless-deployment/design.md#product-owner-answers-q1q7). Acceptance of a direction does not implement it or replace a required SPEC amendment. `decided` keeps that distinction without weakening the named-owner requirement for `planned`.

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

`available` does not bypass readiness, authorization, model access, leadership, redaction, or confirmation gates. In particular, Standby Node reads still return `503 controller_standby`; cluster status remains readable, and `/health/ready` keeps its existing readiness checks.

Only `available` rows may be described in documentation or release notes as remotely available headless. Always qualify `local_cli` rows as requiring Controller-host access. An Operator or Admin API equivalent for a Console capability, or a CLI family migration, must update this inventory in the same change; see the [Review Gates](process.md#review-gates).

Model deprecate and retire (and thus the complete delete journey), API Client disable for incident containment, and credential list have no headless path today. They remain explicit gaps in the accepted journey target, even when an API contract is already `planned`.

## Accepted follow-up direction, not current behavior

Najib accepted Q1–Q7 on 2026-11-11. Q7's source-dev switch is implemented as described above; [tasks section 3](../openspec/changes/define-headless-deployment/tasks.md#3-open-items-outside-this-change) tracks the remaining follow-ups.

- **MCP (Q2–Q3):** client-side stdio first, preferably a portable `orchardctl` mode using its protected token file and pinned TLS over `reverse_proxy` or `direct_https`. A server-enforced read-only cluster role must precede any MCP work, with a §10.4 amendment; read tools omit request content by default. Later writes require an explicit allowlist, an Operator API route with Action Preview, and human approval bound to action, target, and expiry. The write-capable adapter holds `operator`, not `admin`; admin actions and invite URLs stay out without a separate reviewed change. Only `available` rows are eligible, and API availability alone does not make a tool eligible.
- **Topology (Q4):** profile-neutral requirements, with slice priority following Milestone 8: Linux Controller, external Postgres, admitted macOS Nodes. A single-host Ubuntu appliance is not a target for now. macOS source development keeps being tested; this is not a platform support claim.
- **Acquisition (Q5):** Controller-host Orchard Artifact Bundle import, a future offline preparation command for Hugging Face snapshots, and later implementation of the specified import API. No required network egress is added (§11.7).
- **Portal administration (Q6):** Admin API primitives follow implementation of the shared authorization fences, retained-writer ledger, and audit surface, not merely acceptance of their docs. §7.4a must be amended before these routes ship. Until then, issue tenant keys through `orchardctl api-keys create`.
