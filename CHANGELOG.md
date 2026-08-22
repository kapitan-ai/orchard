# Changelog

All notable changes to Orchard are documented here. Entries are grouped by the
date the change landed on `main`.

## 2026-08-21

### Breaking changes

- Tenant-to-Model access is now deny-by-default: `GET /v1/models` only lists models with an enabled grant for the caller's Tenant, and `/v1/chat/completions` and `/v1/responses` return `403 model_not_authorized` without one. **Required action:** after upgrading, grant every model each Tenant must reach with `orchardctl models access grant` (including the seeded `legacy` Tenant used by the Console Playground) — the migration creates no grants, so existing deployments stop serving inference until grants exist. Optional routing policies are managed with `orchardctl models routing-policy create|list`, and a null policy resolves to the canonical `AdmissionPolicy` defaults. ([#224](https://github.com/kapitan-ai/orchard/pull/224))

### Features

- Streaming inference events now carry `TokenDelta`: added `Orchard.InferenceEvent.TokenDelta` with validated constructors and bidirectional `V1.TokenDelta` proto mapping, so token-level deltas (including logprobs) survive the Node Agent → controller event path. ([#232](https://github.com/kapitan-ai/orchard/pull/232))

### Bug fixes

- MLX worker OS children are now reaped by a supervised `RuntimeProcessReaper` that takes the lease when the worker port opens, so BEAM shutdown or cancellation during a long `load_model` no longer leaves an orphaned Python subprocess. ([#228](https://github.com/kapitan-ai/orchard/pull/228))
- Model-load dispatch deadlines now match the cold-start stage cap instead of the absolute request deadline, so an abandoned load no longer keeps loading on the Node Agent; gRPC deadline expiry (integer status codes included) surfaces as `load_timeout` (HTTP 504) rather than `internal_error`. ([#230](https://github.com/kapitan-ai/orchard/pull/230))
- Abandoned model loads now clean up fully: timed-out local BEAM calls terminate their wrapper process and drain racing results, and a late successful load no longer retains a worker placement when every non-preload waiter has expired (explicit preloads still own residency). ([#233](https://github.com/kapitan-ai/orchard/pull/233))
- Source-dev orphaned-worker cleanup is scoped to the current checkout, UID, socket directory, and normalized executable identity, treating ambiguous ownership as a skip — `bin/dev` and `bin/dev-node-agent` no longer signal workers belonging to another checkout. ([#234](https://github.com/kapitan-ai/orchard/pull/234))
- The Console Playground catalog diagnostic uses a targeted model lookup instead of enumerating the full catalog, and fails closed on lookup errors. ([#236](https://github.com/kapitan-ai/orchard/pull/236))

### Improvements

- Metrics tests take module-scoped Bootstrap ownership and deterministically restore Orchard telemetry handlers, removing cross-test handler interference. ([#235](https://github.com/kapitan-ai/orchard/pull/235))
- `README.md` is now a product-facing overview: positioning, who it's for, what ships today, `curl`/OpenAI-SDK examples, status/roadmap table, run-from-source steps, and product plus CI badges. ([#227](https://github.com/kapitan-ai/orchard/pull/227))
