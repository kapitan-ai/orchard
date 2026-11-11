# Headless Deployment

A **Headless Deployment** is the standard production `orchard_controller` release started with the Console disabled by boot-time runtime configuration. It is not a separate build, release, or package. `SPEC.md` §§2.3 and 7.1 define the contract; the accepted [`define-headless-deployment` change](../openspec/changes/define-headless-deployment/proposal.md) records its scope and unresolved decisions.

## Production release only today

The production Controller defaults to Console disabled. `ORCHARD_CONSOLE_ENABLED` must hold a true value to enable it, with Console credentials configured; an invalid boolean value stops boot. Source development through `bin/dev` and `bin/dev-controller` always enables the Console without authentication and does not honor this flag as a headless switch.

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

This inventory describes current implementation, not every endpoint specified as a target in `SPEC.md`. It was checked against the router, Console handlers, and CLI command implementations on main at `30a69eedb398b422d602de94894e3f9b88cef33f`.

| Classification | Meaning |
| --- | --- |
| `available` | Served remotely by the Public Inference, Operator, or Admin API under that route's existing contract. |
| `local_cli` | Available through Controller-host `orchardctl` under §11.9; requires host access, not just an API credential. |
| `planned` | An API equivalent has a named OpenSpec or `SPEC.md` owner but is not implemented. |
| `undecided` | A named product decision is still required. |
| `console_only` | Deliberately left to the Console by an accepted decision. No final classification of this kind has been decided yet. |

The Q references below refer to [the accepted design's open questions](../openspec/changes/define-headless-deployment/design.md#open-questions-for-the-product-owner). They are not decisions or implementation commitments.

| Capability | Classification | Path today and limits | API owner or pending decision |
| --- | --- | --- | --- |
| Inference (Console Playground) | `available` | `POST /v1/chat/completions`, `POST /v1/responses`; authorized model discovery at `GET /v1/models` | — |
| Cluster and health overview | `available` | `GET /ops/v1/health`, `GET /ops/v1/cluster` | — |
| Node list and inspect | `available` | `GET /ops/v1/nodes`, `GET /ops/v1/nodes/:node_id`; Active Controller required | — |
| Node admission review, admit, reject | `available` | `/admin/v1/node-admission/candidates`, candidate detail/reject/clear-rejection, `POST /admin/v1/nodes/:node_id/admit` | — |
| Scheduler explanation, request retry, worker recovery, circuit breakers | `available` | `/ops/v1/scheduler/explanations/:request_id`, `/ops/v1/requests/:id/retry`, `/ops/v1/worker-recovery/nodes/:node_id/models/:model_id`, `/ops/v1/circuit-breakers/*` | — |
| Node cordon, uncordon, drain, cancel-drain, maintenance, resume, decommission | `local_cli` | `orchardctl nodes <action>` on the Controller host; preview, confirmation, and lifecycle blockers still apply; maintenance is preview-only on both surfaces until drain completion can be verified | `SPEC.md` §§7.3.1, 7.4.1 |
| Node enrollment bundle issue | `local_cli` | `orchardctl nodes enrollment create` on the Controller host | `SPEC.md` §7.4.1 bootstrap tokens |
| Request details and captured output | `planned` | Console only; `orchardctl requests inspect` shows only the persisted scheduler explanation, already available through the API | `SPEC.md` §7.3.1 `GET /ops/v1/requests/:request_id`, pending a capture-mode redaction decision |
| Request list and browsing | `undecided` | Console only | Q1: parity bar |
| Workspace create | `local_cli` | `orchardctl tenants create` on the Controller host | `SPEC.md` §7.4.1 `POST /admin/v1/tenants` |
| Workspace colleague handoff | `undecided` | Console only | Q1: parity bar; Q6: Portal User administration |
| API Key create | `local_cli` | `orchardctl api-keys create` on the Controller host; Portal self-service is separate and limited to the signed-in user's keys | `SPEC.md` §7.4.1 `POST /admin/v1/api-keys` |
| Credential revoke | `local_cli` | `orchardctl api-keys revoke` on the Controller host for persisted API credentials; no named Console Session implementation yet | `cross-surface-authorization-contract`, `SPEC.md` §10.11 |
| Credential list, inspect | `planned` | Console credential summaries only; the accepted cross-surface credential family is not implemented | `cross-surface-authorization-contract`, `SPEC.md` §10.11 |
| API Client disable | `planned` | Console only | `SPEC.md` §7.4.1 service accounts |
| Active model list, import; delete of previously retired models | `local_cli` | `orchardctl models list`, `models import`, `models delete` on the Controller host; list shows active models only. Delete works only for a model already retired through the Console, with no non-terminal requests; retirement has no CLI or API path | `SPEC.md` §7.4.1 |
| Full model catalog (inactive, deprecated, retired) | `planned` | Console only; `/v1/models` is an authorized active-model view, not the full management catalog | `SPEC.md` §7.4.1 `GET /admin/v1/models` |
| Model activate, deprecate, retire | `planned` | Console; `orchardctl models import --activate` can activate at import only | `SPEC.md` §7.4.1 |
| Tenant model grants, routing policy | `local_cli` | `orchardctl models access` and `models routing-policy` on the Controller host | `SPEC.md` §7.4.1 routing policies |
| Model Hub search and download | `undecided` | Console only | Q5: API, Console-only, or local import |
| Portal User create, invite, disable | `undecided` | Console only; no API route specified | Q6: Portal User administration |
| Playground inference defaults | `undecided` | Console settings only; proposed `console_only`, pending a product-owner decision | Q1: parity bar |

`available` does not bypass readiness, authorization, model access, leadership, redaction, or confirmation gates. In particular, Standby Node reads still return `503 controller_standby`; cluster status remains readable, and `/health/ready` keeps its existing readiness checks.

Only `available` rows may be described in documentation or release notes as remotely available headless. Always qualify `local_cli` rows as requiring Controller-host access. An Operator or Admin API equivalent for a Console capability, or a CLI family migration, must update this inventory in the same change; see the [Review Gates](process.md#review-gates).

Full Console parity and whether local CLI capabilities count toward it remain open under Q1. MCP placement and write authority (Q2–Q3), target topology (Q4), Model Hub (Q5), Portal User administration (Q6), and a source-development headless switch (Q7) remain outside this implementation.
