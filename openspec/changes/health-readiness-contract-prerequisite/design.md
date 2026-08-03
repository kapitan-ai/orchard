## Context

`SPEC.md` section 3.1 requires Controller readiness to cover Postgres, migrations, loaded model, tenant, and API-key caches, plus write-path leadership when Active/Standby mode is enabled.
The current evaluator checks Postgres, migrations, public HTTPS, and a constant boot flag.
No `Orchard.CacheSupervisor`, `Orchard.Cache.Models`, `Orchard.Cache.Tenants`, or `Orchard.Cache.ApiKeys` implementation exists.
The production model, tenant, and API-key paths read Postgres directly, so issue #115 has no authoritative cache-loaded interfaces to consume.
`Orchard.ControlPlane.authorize_write_path/1` and `read_only_status/0` already provide a write gate and status surface, but their production backing and bounded-read suitability must be assessed before health wiring consumes them.

The public readiness response currently exposes operator-only metadata and is consumed by Console, CLI, packaging documentation, and tests.
The existing `/ops/v1` pipeline already supplies the required cluster-scoped Operator-or-admin authorization boundary.

The owner has approved a two-stage migration. Stage one removes public disclosure now while preserving and explicitly labeling the unchanged M0 predicate. Stage two adopts the complete `SPEC.md` §3.1 aggregate only after the required control-plane authorities exist.

## Goals / Non-Goals

**Goals:**

- Implement the approved public and authenticated health exposure boundary now.
- Preserve `SPEC.md` as the apex contract.
- Label the unchanged staged predicate `orchard.readiness.legacy_m0.v1` without claiming complete §3.1 readiness.
- Identify the missing control-plane authorities that block only the later complete aggregate.
- Forbid readiness shims that would create false compliance in that aggregate.

**Non-Goals:**

- Change the legacy readiness predicate or claim full §3.1 readiness.
- Design or implement model, tenant, or API-key cache architecture.
- Design or implement a new leadership authority unless an explicit assessment of the existing surface demonstrates a separately owned gap.
- Build the issue #115 external probe, terminal-event validator, Collector path, redaction boundary, dashboards, alerts, or Grafana resources.
- Add `/metrics`, product metric families, tracing, structured logging, or a telemetry vendor SDK.
- Change Sentry or exactly-one-terminal-event behavior.
- Add an unauthenticated diagnostic fallback.

## Decisions

### Use a two-stage health migration

Stage one changes exposure without changing the predicate: public health becomes exact and status-only, detailed diagnostics move behind Operator authorization, and the evaluator identifies itself as `orchard.readiness.legacy_m0.v1`. This removes disclosure without pretending the staged predicate is the complete §3.1 aggregate.

Stage two replaces the legacy predicate only after authoritative cache-loaded and conditional leadership sources exist. Public and Operator health then consume the same complete aggregate.

Alternative considered: implement genuine serving-path caches in the exposure change. This was rejected because cache preload, coherence, mutation invalidation, revocation, API Client disablement, role changes, multi-controller consistency, and recovery semantics are correctness-sensitive control-plane architecture.

Alternative considered: keep public diagnostics until the complete aggregate exists. This was rejected because the security boundary does not depend on aggregate completeness and the predicate can be labeled honestly.

### Assign missing authorities to separate control-plane changes

Separate accepted changes must own:

- Model cache architecture, serving-path integration, and authoritative loaded-state status.
- Tenant cache architecture, serving-path integration, and authoritative loaded-state status.
- API-key cache architecture, authentication-path integration, security, coherence, and authoritative loaded-state status.
- An assessment of whether the existing `Orchard.ControlPlane` gate and status provide a bounded, production-backed conditional leadership source.
- A separately owned leadership change only if that assessment demonstrates a gap.

Each cache owner must define startup, failure, recovery, coherence, and test behavior appropriate to its domain.
Issue #115 consumes the accepted stable status interfaces but does not define their internal architecture.

Alternative considered: let issue #115 define generic cache processes.
This was rejected because an observability consumer cannot safely own the correctness and security semantics of production serving paths.

### Prohibit readiness substitutes

The later health implementation must not treat any of these as authoritative:

- A hard-coded or configured healthy value.
- A readiness-only process or ETS table.
- The unrelated tokenizer compatibility cache.
- A successful direct database query presented as proof that a cache loaded.
- Process presence without authoritative hydration state.
- Configured Controller role, membership state, or process presence presented as proof of current write-path leadership.

An absent, invalid, unavailable, or timed-out authority must block implementation review or fail closed after the real interface exists.

### Preserve the approved future health boundary

In stage one:

- `GET /health/live` remains unauthenticated and exact at HTTP `200` with `{"status":"ok"}`.
- `GET /health/ready` remains unauthenticated and returns only `{"status":"ok"}` with HTTP `200` or `{"status":"error"}` with HTTP `503`.
- Readiness runs in a supervised, unlinked task with a fixed 5-second production
  timeout. Raises, exits, throws, malformed returns, and timeouts fail closed, and
  timed-out work is terminated.
- Public readiness and authenticated Operator health consume the same unchanged legacy M0 predicate and Operator detail identifies it as `orchard.readiness.legacy_m0.v1`.
- The Operator route installs `NoStore` before authentication, so `401`, `403`,
  `200`, and `503` responses are all non-cacheable and denied callers trigger no
  readiness or observational probe.
- Console Overview describes its internal `legacy_m0.v1` readiness view and does
  not claim that its check table mirrors the status-only public body.

In stage two, public readiness and authenticated Operator health consume one complete `SPEC.md` section 3.1 aggregate.

In both stages:

- `GET /ops/v1/health` uses the existing Operator-or-admin authorization boundary.
- Operator detail carries stable checks, reasons, bounded remediation, and sanitized observations.
- Runtime, licensing, build, transport, and Console observations remain non-gating unless `SPEC.md` explicitly changes.
- No public or Operator health response adds tenant or user identifiers.

Alternative considered: content negotiation or a query parameter on `/health/ready`.
This was rejected because it combines public and protected representations at one security boundary.

Alternative considered: preserve rich public fields for compatibility.
This was rejected because it preserves the disclosure that the owner decision explicitly removes.

### Intentionally drop public API transport posture as a readiness gate

The current evaluator gates readiness on `public_api_https_enabled`, which is not a `SPEC.md` section 3.1 readiness condition.
`SPEC.md` section 10.7 lists `plain_http_localhost` as a permitted public transport mode, so a Controller correctly configured for local development or break-glass recovery is currently reported as not ready.
Adopting the complete section 3.1 aggregate therefore removes that gate on purpose: a `plain_http_localhost` Controller that satisfies every section 3.1 condition will return HTTP `200` where it returns HTTP `503` today.
`reverse_proxy` already passes the current HTTPS gate and does not undergo that status transition.

Transport posture is retained as an Operator observation, not deleted.
Section 10.7 still classifies `plain_http_localhost` as degraded and unsuitable for production public transport.
A readiness `200` means the Controller satisfies section 3.1 service readiness; it does not endorse the configured transport for production.
The later behavior-changing PR must reconcile this distinction explicitly in `SPEC.md` sections 3.1 and 10.7.

Removing transport from readiness also depends on section 10.7 configuration, wrapper, and boot validation continuing to fail closed for invalid or unresolvable transport modes.
Health must not become the fallback validator for a Controller configuration that should not have started.
That dependency is a contract condition rather than design prose: the fail-closed transport requirement in this change's spec delta blocks the gate removal, and task 2.6 supplies the evidence.
The assessment must cover configuration sources other than `ORCHARD_TRANSPORT_MODE`, because runtime validation raises on a bad environment value while `Orchard.API.Transport.mode/0` normalizes an unrecognized `:transport_mode` application-environment value to `unknown`, and readiness is currently the only surface that reports that state.
This is a deliberate posture change rather than an oversight, and it takes effect only in the later atomic migration.
Current readiness behavior, including the existing transport gate, stays unchanged while this prerequisite is in force.

Alternative considered: keep the transport gate alongside the section 3.1 aggregate.
This was rejected because it is exactly the milestone-specific readiness subset this contract forbids, and it would keep reporting a permitted transport mode as unready.

### Resolve the constant boot flag in the same migration

`controller_boot_completed` is the other current aggregate member that section 3.1 does not require, and the evaluator hard-codes it to `true`.
It changes no readiness result today, but it is the exact shape the no-shim rule rejects, and it is a rendered Console check with CLI remediation text.
Adopting the complete aggregate therefore requires the later migration to decide explicitly whether the key survives as an Operator observation or leaves the check set, rather than carrying a constant into the new contract.
It is listed in the deferred migration inventory for that reason.

### Accept a bounded credential-free `orchardctl status` feature loss

`orchardctl status` currently reads `version` and `build_ref` from the unauthenticated `/health/ready` body to render a remote Controller version banner.
The exact minimal public body removes that source, and the CLI probes without Operator credentials.

The accepted resolution is a bounded feature loss.
Credential-free status may present the local CLI or installed package version, but must not present it as remote Controller identity.
It accepts only HTTP `200` with exactly `{"status":"ok"}` or HTTP `503` with
exactly `{"status":"error"}`, renders a state-free Console URL, and points a
degraded caller to authenticated Operator health. Dormant rich-public rendering is
removed rather than preserved as an unreachable compatibility path.
Remote version and build identity move to authenticated Operator health detail.
No unauthenticated version route is added, and no credential is placed in the public probe path.

Alternative considered: add an unauthenticated version or build route.
This was rejected because it reintroduces the unauthenticated deployment disclosure the owner decision removes.

### Preserve read availability on standby Controllers

The future leadership check describes write-capable readiness.
A standby may remain live and serve authenticated health plus other authorized read-only APIs while public readiness returns HTTP `503`.
Readiness must not become middleware that blocks read-only routes.
Write routes retain their own mutation-time leadership authorization.

Single-controller mode is the only case where the leadership check may be `not_applicable`.
Active/Standby leadership must come from the existing production authority after it is accepted as sufficient or from a separately resolved demonstrated gap.

The no-shim rule and the `not_applicable` path are distinct concerns.
Determining that the conditional leadership condition does not apply is a deployment-mode question; proving that this Controller currently holds write-path leadership is an authority question.
A validated deployment mode may answer the first, but a configured role may never answer the second.

`Orchard.ControlPlane.read_only_status/0` currently derives `deployment_mode` solely from the configured `:role`, so today the applicability decision is itself configuration-derived.
Task 1.4 therefore assesses whether that source can be validated rather than assumed, and must cover a host falsely configured as `single_controller` inside an Active/Standby cluster, an `unknown` normalized role, and a mode inconsistent with cluster membership evidence.
Each of those cases must either fail closed or be assigned to a separately owned leadership change.

### Require ordered exposure and aggregate migrations

Stage one changes the public representation, adds Operator detail, and migrates Console, CLI, packaging, local-development documentation, and tests as one reviewable unit. Stage-two Console behavior is adopted only with the complete aggregate, when it renders every complete check including the conditional leadership `not_applicable` state. Stage two changes the predicate after every authoritative dependency exists. Public probes never receive Operator credentials in either stage, and public diagnostic detail is never restored.

The deferred migration inventory includes `docs/milestones/m0-foundation.md`, which records the M0 readiness subset and the transport-posture reporting that the complete aggregate replaces.
That document is intentionally left unedited by this prerequisite because it accurately describes current behavior; it is reconciled in the same behavior-changing pull request.

## Risks / Trade-offs

- [The prerequisite is mistaken for implementation] -> Keep all production tasks blocked, change no runtime files, and state in the PR that issue #115 remains open.
- [A separate owner introduces a readiness-only cache] -> Require evidence that each loaded-state interface belongs to the corresponding production serving or authentication path.
- [API-key cache work weakens credential safety] -> Keep its architecture under a separate security-sensitive control-plane review and require revocation, expiry, disablement, role-change, coherence, and recovery tests.
- [Leadership status diverges from write authorization] -> Assess the existing `Orchard.ControlPlane` gate and status first, require any consumed interface to use the same production authority, and prohibit configured-role inference.
- [The later public switch breaks clients] -> Audit and migrate every in-repository consumer in the same behavior-changing PR.
- [Operator diagnostics are unavailable during authentication failure] -> Preserve the authentication boundary and do not add an unauthenticated detailed fallback.
- [The prerequisite expands into the full observability issue] -> Keep probe, Collector, metrics, tracing, logging, Grafana, and terminal-event work as explicit non-goals.

## Migration Plan

1. Implement stage one: exact status-only public health, authenticated Operator detail, the explicit legacy contract identifier, and consumer/documentation migration.
2. Assign and accept separate control-plane changes for the three genuine cache authorities.
3. Assess the existing `Orchard.ControlPlane` gate and status for production backing, bounded reads, and exact readiness semantics, then assign separate work only for demonstrated gaps.
4. Verify each dependency through public interfaces and tests rather than implementation-specific assumptions.
5. Implement stage two as a separately reviewed predicate migration to the complete §3.1 aggregate without shims.
6. Keep issue #115 open for its separately owned external acceptance harness.

## Open Questions

- Which issue and OpenSpec identifiers will own each cache authority?
- Does the existing `Orchard.ControlPlane` gate and status already satisfy the bounded production leadership requirement, and if not, which exact gap needs separate ownership?
- May one control-plane change own all three cache authorities, or do their security and coherence differences require separate reviews?

These ownership questions block implementation but do not change the approved health boundary.
