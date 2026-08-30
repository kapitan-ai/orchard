# Changelog

All notable changes to Orchard are documented here. Entries are grouped by the
date the change landed on `main`.

## 2026-08-30

### Breaking changes

- Product licensing is removed entirely: license activation, validation, entitlement enforcement, feature gating, Console license status surfaces, Node Agent license checks, licensing telemetry, and the `orchardctl license` command are all gone. Legacy `ORCHARD_LICENSE_*` and `ORCHARD_KEYGEN_*` values become inert (still redacted defensively), and stored license records are left untouched by install, update, and uninstall. **Required action:** remove any automation that invokes `orchardctl license` or reads license status fields — the removed CLI command now follows the unknown-command path and exits nonzero. ([#280](https://github.com/kapitan-ai/orchard/pull/280); contract in [#271](https://github.com/kapitan-ai/orchard/pull/271), originally staged via [#272](https://github.com/kapitan-ai/orchard/pull/272)/[#273](https://github.com/kapitan-ai/orchard/pull/273))
- The native PKG installer and the Managed Node Agent handover program are removed: PKG build/signing/notarization assets, launchd package assets, and managed-handover lifecycle state are deleted, with Orchard.app/DMG payload assembly extracted to `scripts/build-payload.sh`. ADRs 0018–0027 are superseded; the legacy `com.orchard.pkg` receipt blocker is kept so the app cannot silently take over a PKG install. Service lifecycle semantics change with the handover removal: `orchardctl stop` no longer applies persistent launchd job-domain disablement, so a stopped service starts again after a reboot or launchd domain reload, and `orchardctl start` unconditionally enables the job domain — overriding an operator's own `launchctl disable`. **Required action:** distribute via the signed `Orchard.app` DMG — native PKG is no longer a supported channel, and future packaging work needs a fresh OpenSpec proposal. To keep a service down across reboots, leave it stopped or remove the role from the install; `launchctl disable` is not a supported mechanism. ([#281](https://github.com/kapitan-ai/orchard/pull/281))

### Features

- Automatic attempt retry is now implemented end to end: a retryable attempt-1 Node failure runs one attempt 2 on a different Node under the original Request, preserving admission, queue grant, quota reservation, idempotency scope, capture snapshot, and the absolute deadline; attempt 2 records `retry_exhausted` on failure and there is never a third execution. ([#305](https://github.com/kapitan-ai/orchard/pull/305))
- Every unsuccessful started attempt now carries a durable `retry_decision` from a closed, fail-closed `AttemptRetryClassifier`, and caller disconnect maps to HTTP 499 with public code `request_cancelled` on both Chat Completions and Responses. ([#299](https://github.com/kapitan-ai/orchard/pull/299))
- Durable Node and `(node, model)` placement circuit breakers (SPEC §5.10): rolling-window failure evidence, fail-closed scheduler eligibility at snapshot/acquisition/dispatch, and authenticated Operator inspect/clear endpoints under `GET|POST /ops/v1/circuit-breakers/...` with required clear reasons and audit events. Adds `circuit_breakers` and `circuit_breaker_failures` tables (migration included). ([#302](https://github.com/kapitan-ai/orchard/pull/302))
- Schedulers accept a canonical prior-Node exclusion set: attempt 2 hard-excludes attempt 1's durable Node before eligibility and scoring, with a `previous_attempt_node_excluded` explanation and a pre-dispatch identity recheck that fails closed on identity mismatch. ([#301](https://github.com/kapitan-ai/orchard/pull/301))
- New bounded Prometheus series for physical attempts and logical retries: `orchard_inference_attempts_total`, `orchard_inference_attempt_duration_seconds`, and `orchard_inference_retries_total`, projected from durable attempt evidence after terminalization and fail-closed on incomplete or duplicate evidence. ([#307](https://github.com/kapitan-ai/orchard/pull/307))
- Added a project-local `verify-orchard` agent skill with a `control-orchard` helper (bootstrap node trust, launch, doctor, stop, curl) for scripted source-dev Console and health verification with kept proof artifacts. ([#297](https://github.com/kapitan-ai/orchard/pull/297))
- Added `scripts/prepare-mlx-smoke-bundle.sh`, which pins an ungated ~335 MB Qwen3-0.6B-4bit MLX snapshot and builds a manifest-complete local bundle for `scripts/smoke-mlx.sh`, replacing the manual Llama 3.2 copy-paste recipe. ([#298](https://github.com/kapitan-ai/orchard/pull/298))

### Bug fixes

- Streaming requests sending only `Accept: text/event-stream` are no longer rejected with HTTP 406: `POST /v1/chat/completions` and `POST /v1/responses` now accept SSE for `stream: true` requests while unsupported media types still fail closed with an OpenAI-shaped 406. ([#274](https://github.com/kapitan-ai/orchard/pull/274))
- Disabled Portal Users can no longer reactivate by redeeming an invite issued before disablement: disabling atomically deletes outstanding invites, redemption is bound to the route Organization and an eligible `invited` user, and all invalid-token cases return the same generic failure without mutation. ([#284](https://github.com/kapitan-ai/orchard/pull/284))
- Developer Portal feedback stays current: mint and revoke failures own separate dialog state, the 10-key cap message derives from current key state and reconciles concurrent mint races, validation renders inside the active dialog with accessible semantics, and unusable invites get a generic 422 with no password form. ([#303](https://github.com/kapitan-ai/orchard/pull/303))
- Breaker-eligible attempt failures are attributed exactly once to the correct Node or placement breaker, using the post-delivery selected outcome and an idempotent failure identity, with the durable breaker write completing before retry or terminal orchestration. ([#304](https://github.com/kapitan-ai/orchard/pull/304))
- The bounded retry contract is proven end to end through both public APIs in JSON and streaming modes; the tests exposed and fixed accounting gaps, including `reserved_output_tokens` initialization from the admitted sampling limit and central clearing on every terminal Request update. ([#308](https://github.com/kapitan-ai/orchard/pull/308))
- Retry-contract reconciliation: model-load retry decisions use the normalized failure category as sole authority, identity and occupancy failures keep their decline precedence, and caller cancellation can no longer carry stale model-load evidence into an invalid terminal outcome. ([#310](https://github.com/kapitan-ai/orchard/pull/310))
- Node Agent worker shutdown signals are gated on launch-time OS identity (uid + start time): TERM/KILL is refused on missing or mismatched identity so a recycled PID can never kill an unrelated process, while owned socket and lease cleanup still proceeds. ([#290](https://github.com/kapitan-ai/orchard/pull/290))
- The Console Playground no longer renders model reasoning as the answer when a Qwen3-style completion starts inside a think block and closes it with a bare `</think>`: display-only containment drops the reasoning preamble and never yields an empty assistant bubble. ([#313](https://github.com/kapitan-ai/orchard/pull/313))
- Long model identities on the Console request-detail page wrap at the natural `/` and `@` separators instead of arbitrary mid-token positions, keeping the full value selectable and never painting over the neighboring column. ([#314](https://github.com/kapitan-ai/orchard/pull/314))
- The Console Registered Nodes empty state no longer implies a runtime status read registers a Node, and `pending_observed` candidate detail pages gained a read-only Enrollment Guidance card with the real trust → enrollment-bundle → node-join command sequence. ([#289](https://github.com/kapitan-ai/orchard/pull/289))
- Top-level Model Manifest `sha256` is deprecated to optional, non-authoritative compatibility metadata: manifests with or without it are accepted (present null/empty/non-string values still rejected), and the Catalog's `models.artifact_sha256` tree digest remains the sole authority over stored bundles. ([#315](https://github.com/kapitan-ai/orchard/pull/315))
- The test-only node-agent port moved below the Linux ephemeral range (default `50071` → `15071`, CI `50171` → `15171`), so the kernel can no longer hand it to an unrelated client socket mid-run and abort the suite with `:eaddrinuse`; a configured `ORCHARD_TEST_NODE_AGENT_PORT` inside the host's ephemeral range now fails fast with remediation guidance. ([#316](https://github.com/kapitan-ai/orchard/pull/316))
- The opt-in MLX smoke derives its ExUnit timeout from the sum of its own phase budgets instead of racing the unrelated 60-second default during large bundle hashing and model load. ([#309](https://github.com/kapitan-ai/orchard/pull/309))
- The `verify-orchard` workflow is hardened: launches survive the invoking shell with recorded PIDs, Console proofs wait for connected LiveView state, an opt-in Apple Silicon MLX smoke is exposed, and run metadata became versioned data-only `meta.json` that is never executed (legacy `meta.env` fails closed). ([#306](https://github.com/kapitan-ai/orchard/pull/306))

### Improvements

- Elixir gRPC stack upgraded 0.11.5 → 1.0.4 (client/server package split into `grpc` + `grpc_server`, explicit `gun` dependency, `protobuf` 0.17), clearing four advisories including EEF-CVE-2026-48853; client supervision moved into the library and dropped upstream typespecs are re-owned by `Orchard.GRPCTypes`. ([#283](https://github.com/kapitan-ai/orchard/pull/283))
- Grouped patch/minor dependency updates: cowboy 2.18.0 / cowlib 2.19.0 / gun 2.4.1 / ranch 2.2.1 (clearing three cowboy advisories), openspec CLI 1.9.0, and Python lockfile refreshes (huggingface-hub 1.27, grpcio 1.83, and friends). ([#282](https://github.com/kapitan-ai/orchard/pull/282))
- Darwin native helper builds are isolated from the portable compile: `orchard_cli` no longer compiles C helpers on `mix compile`; `scripts/build-macos-native-helpers.sh` is the single explicit builder, with tripwire tests proving portable compilation invokes no Darwin tooling. ([#292](https://github.com/kapitan-ai/orchard/pull/292))
- Required CI fans out into explicit Linux portable-core, provider-neutral conformance, macOS host, MLX provider, packaging, and OpenSpec lanes behind a repository-owned fail-closed changed-path classifier, making Linux validation of the portable control-plane core a required signal. ([#293](https://github.com/kapitan-ai/orchard/pull/293))
- Durable documentation now defines the portable Orchard control-plane core and four qualified profile kinds (Platform, Distribution, Runtime-Provider, Acceptance), and corrects topology support status ahead of the Milestone 8 Linux Controller work. ([#285](https://github.com/kapitan-ai/orchard/pull/285))
- Portal documentation and the accepted OpenSpec capability now describe the shipped Create-then-Copy invitation lifecycle: token issuance on first Copy, one-row hash-only storage, deletion-based invalidation, and the canonical POST redemption route. ([#300](https://github.com/kapitan-ai/orchard/pull/300))
- OpenSpec hygiene: six completed change packages archived with accepted capability specs synced ([#291](https://github.com/kapitan-ai/orchard/pull/291)), and the completed observability packages (metrics floor, circuit-breaker foundation, phase-0 probe) archived and promoted ([#312](https://github.com/kapitan-ai/orchard/pull/312)).

## 2026-08-23

### Breaking changes

- Effective request deadlines are now bounded by a deployment-owned ceiling, `ORCHARD_MAX_REQUEST_DEADLINE_MS` (default `360000`). Saving a routing policy whose effective deadline (`request_timeout_ms + max_queue_wait_ms + max_cold_start_ms` on cold-load paths) exceeds the ceiling is rejected, pre-existing policies above it are capped at request time with a logged warning, and a configured `request_timeout_ms` above the ceiling raises as incoherent configuration whenever the ceiling is resolved (at routing-policy save and request admission — not at Controller startup). **Required action:** if any routing policy legitimately needs a longer effective deadline, set `ORCHARD_MAX_REQUEST_DEADLINE_MS` above it (and raise reverse-proxy response timeouts accordingly — the packaged nginx/Caddy/Traefik examples now use 390s) before upgrading. ([#261](https://github.com/kapitan-ai/orchard/pull/261))

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
