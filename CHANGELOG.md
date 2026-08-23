# Changelog

All notable changes to Orchard are documented here. Entries are grouped by the
date the change landed on `main`.

## 2026-08-23

### Breaking changes

- Effective request deadlines are now bounded by a deployment-owned ceiling, `ORCHARD_MAX_REQUEST_DEADLINE_MS` (default `360000`). Saving a routing policy whose effective deadline (`request_timeout_ms + max_queue_wait_ms + max_cold_start_ms` on cold-load paths) exceeds the ceiling is rejected, pre-existing policies above it are capped at request time with a logged warning, and a configured `request_timeout_ms` above the ceiling makes the Controller raise at startup. **Required action:** if any routing policy legitimately needs a longer effective deadline, set `ORCHARD_MAX_REQUEST_DEADLINE_MS` above it (and raise reverse-proxy response timeouts accordingly — the packaged nginx/Caddy/Traefik examples now use 390s) before upgrading. ([#261](https://github.com/kapitan-ai/orchard/pull/261))

### Features

- Source-dev Controllers can now opt into an operator-managed HTTPS reverse proxy (`reverse_proxy` transport mode), so `public_api_https_enabled` readiness reflects the configured deployment; parsing of bind IPs, public HTTPS URLs, origin checks, and trusted-proxy CIDRs is shared with release configuration, and every non-loopback backend bind requires an explicit trusted-proxy allowlist. Plain loopback HTTP remains the default; `direct_https` stays release-only. ([#264](https://github.com/kapitan-ai/orchard/pull/264), contract in [#263](https://github.com/kapitan-ai/orchard/pull/263))

### Bug fixes

- Public request deadlines are now policy-authoritative: the hardcoded 30s admission default no longer shadows `Inference.request_timeout_ms()` or the resolved routing policy, so `allow_cold_load` policies get `request_timeout_ms + max_queue_wait_ms + max_cold_start_ms` as their persisted deadline and models with cold loads longer than ~30s become servable. Unresolved timeouts now fail closed instead of persisting a default. ([#258](https://github.com/kapitan-ai/orchard/pull/258))
- Cold model-load timeouts are reported to clients as `HTTP 504 load_timeout` instead of `HTTP 500 internal_error`: the durable failure *code* was being fed into a *category* mapper and fell through to `:internal`; a drift-guard test now asserts every durable model-load code maps to its intended category. ([#260](https://github.com/kapitan-ai/orchard/pull/260))
- The Developer Portal works in a real browser: the endpoint now parses `application/x-www-form-urlencoded` bodies so CSRF-protected invite/sign-in/logout POSTs no longer 403, portal templates are included in Tailwind's `@source` so the portal renders styled, and portal controls gained visible focus states plus dialog ARIA semantics. ([#262](https://github.com/kapitan-ai/orchard/pull/262))

### Improvements

- Elixir dependency patch/minor group with security fixes: Phoenix 1.7.24 (CVE-2026-56811, CVE-2026-56812), Bandit 1.12.5 (GHSA-x3gh-xhj4-3vq8, GHSA-xj8g-532w-jv94), and Protobuf 0.16.1 (GHSA-rv48-qqj5-crxg recursion DoS), plus routine bumps. ([#241](https://github.com/kapitan-ai/orchard/pull/241))
- Ecto 3.14 + Decimal 3.x remediate CVE-2026-32686 (unbounded-exponent Decimal DoS); Decimal now defaults to decimal128 context and rejects inputs above 34 digits or |exponent| > 6144. ([#243](https://github.com/kapitan-ai/orchard/pull/243))
- Python tooling lockfile refresh: tokenizers 0.23.1, sentencepiece 0.2.2, pytest 9.1.1, ruff 0.16.3. ([#242](https://github.com/kapitan-ai/orchard/pull/242))
- Tailwind CSS toolchain 4.1.3 → 4.3.3 for console asset builds. ([#240](https://github.com/kapitan-ai/orchard/pull/240))
- Required CI validation migrated from Blacksmith to the Namespace `nscloud-macos-sequoia-stable-arm64-6x14` runner, preserving the Apple Silicon macOS 15 / 6-vCPU contract. ([#245](https://github.com/kapitan-ai/orchard/pull/245))
- Docs-only PRs skip the expensive macOS validation runner via a path-filter gate; branch protection now requires the new "Required Orchard validation gate" check. ([#246](https://github.com/kapitan-ai/orchard/pull/246))
- De-flaked the `ModelHubDownloadCoordinator` crash-log test by scoping the assertion to the test's own task pid/ref and accepting `:killed` or `:noproc`. ([#248](https://github.com/kapitan-ai/orchard/pull/248))
- Defined the Orchard platform portability contract: platform profiles (Apple Silicon macOS remains the sole supported v1 profile), portable-core dependency rules, Controller Host / Node separation, provider-neutral Worker Runtime vocabulary, and Milestone 8 acceptance gates for a future Linux Controller profile; the accepted requirements were promoted into main OpenSpec specs and archived. ([#268](https://github.com/kapitan-ai/orchard/pull/268), [#269](https://github.com/kapitan-ai/orchard/pull/269))

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
