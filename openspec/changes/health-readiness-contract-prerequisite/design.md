## Context

`SPEC.md` section 3.1 requires Controller readiness to cover Postgres, migrations, loaded model, tenant, and API-key caches, plus write-path leadership when Active/Standby mode is enabled.
The current evaluator checks Postgres, migrations, public HTTPS, and a constant boot flag.
No `Orchard.CacheSupervisor`, `Orchard.Cache.Models`, `Orchard.Cache.Tenants`, or `Orchard.Cache.ApiKeys` implementation exists.
The production model, tenant, and API-key paths read Postgres directly, so issue #115 has no authoritative cache-loaded interfaces to consume.
`Orchard.ControlPlane.authorize_write_path/1` and `read_only_status/0` already provide a write gate and status surface, but their production backing and bounded-read suitability must be assessed before health wiring consumes them.

The public readiness response currently exposes operator-only metadata and is consumed by Console, CLI, packaging documentation, and tests.
The existing `/ops/v1` pipeline already supplies the required cluster-scoped Operator-or-admin authorization boundary.

The owner has approved minimal unauthenticated health responses and authenticated detailed health, but also requires detailed health to reconcile every `SPEC.md` section 3.1 condition.
Those decisions cannot be implemented honestly in one narrow observability branch while the required control-plane authorities are absent.

## Goals / Non-Goals

**Goals:**

- Record the approved future public and authenticated health boundary.
- Preserve `SPEC.md` as the apex contract.
- Identify the missing control-plane authorities that block issue #115 health wiring.
- Forbid readiness shims that would create false compliance.
- Define the evidence required before implementation may resume.
- Keep this prerequisite review small enough to assess independently.

**Non-Goals:**

- Change production code, tests, runtime behavior, `SPEC.md`, or existing health responses.
- Design or implement model, tenant, or API-key cache architecture.
- Design or implement a new leadership authority unless an explicit assessment of the existing surface demonstrates a separately owned gap.
- Build the issue #115 external probe, terminal-event validator, Collector path, redaction boundary, dashboards, alerts, or Grafana resources.
- Add `/metrics`, product metric families, tracing, structured logging, or a telemetry vendor SDK.
- Change Sentry or exactly-one-terminal-event behavior.
- Add an unauthenticated diagnostic fallback.

## Decisions

### Submit an OpenSpec-only prerequisite

This change package is the only committed artifact in the prerequisite PR.
It documents the contract conflict and the gate for later implementation.
It does not claim to implement health behavior or complete any phase of issue #115.

Alternative considered: implement genuine serving-path caches inside issue #115.
This was rejected because cache preload, coherence, mutation invalidation, revocation, API Client disablement, role changes, multi-controller consistency, and recovery semantics are correctness-sensitive control-plane architecture.

Alternative considered: implement the public health split before the missing readiness authorities.
This was rejected because the public endpoint would either report a permanently failed Controller or use an incomplete aggregate that contradicts `SPEC.md`.

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

After the blocking authorities are accepted:

- `GET /health/live` remains unauthenticated and exact at HTTP `200` with `{"status":"ok"}`.
- `GET /health/ready` remains unauthenticated and returns only `{"status":"ok"}` with HTTP `200` or `{"status":"error"}` with HTTP `503`.
- Public readiness and authenticated Operator health consume one complete `SPEC.md` section 3.1 aggregate.
- `GET /ops/v1/health` uses the existing Operator-or-admin authorization boundary.
- Operator detail carries stable checks, reasons, bounded remediation, and sanitized observations.
- Runtime, licensing, build, transport, and Console observations remain non-gating unless `SPEC.md` explicitly changes.
- No public or Operator health response adds tenant or user identifiers.

### Intentionally drop public API transport posture as a readiness gate

The current evaluator gates readiness on `public_api_https_enabled`, which is not a `SPEC.md` section 3.1 readiness condition.
`SPEC.md` section 10.7 lists `plain_http_localhost` as a permitted public transport mode, so a Controller correctly configured for local development or break-glass recovery is currently reported as not ready.
Adopting the complete section 3.1 aggregate therefore removes that gate on purpose: a `plain_http_localhost` or `reverse_proxy` Controller that satisfies every section 3.1 condition will return HTTP `200` where it returns HTTP `503` today.

Transport posture is retained as an Operator observation, not deleted.
This is a deliberate posture change rather than an oversight, and it takes effect only in the later atomic migration.
Current readiness behavior, including the existing transport gate, stays unchanged while this prerequisite is in force.

Alternative considered: keep the transport gate alongside the section 3.1 aggregate.
This was rejected because it is exactly the milestone-specific readiness subset this contract forbids, and it would keep reporting a permitted transport mode as unready.

### Accept a bounded credential-free `orchardctl status` feature loss

`orchardctl status` currently reads `version` and `build_ref` from the unauthenticated `/health/ready` body to render a remote Controller version banner.
The exact minimal public body removes that source, and the CLI probes without Operator credentials.

The accepted resolution is a bounded feature loss.
Credential-free status may present the local CLI or installed package version, but must not present it as remote Controller identity.
Remote version and build identity move to authenticated Operator health detail.
No unauthenticated version route is added, and no credential is placed in the public probe path.

Alternative considered: add an unauthenticated version or build route.
This was rejected because it reintroduces the unauthenticated deployment disclosure the owner decision removes.

Alternative considered: content negotiation or a query parameter on `/health/ready`.
This was rejected because it combines public and protected representations at one security boundary.

Alternative considered: preserve rich public fields for compatibility.
This was rejected because it preserves the disclosure that the owner decision explicitly removes.

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

### Require an atomic health exposure migration

After all prerequisite authorities exist, the health implementation changes the public representation, adds Operator detail, and migrates Console, CLI, packaging, local-development documentation, and tests as one reviewable unit.
The public representation does not change in advance of the complete aggregate.
Public probes never receive Operator credentials.

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

1. Review and merge this OpenSpec-only prerequisite without changing current behavior or claiming issue #115 completion.
2. Assign and accept separate control-plane changes for the three genuine cache authorities.
3. Assess the existing `Orchard.ControlPlane` gate and status for production backing, bounded reads, and exact readiness semantics, then assign separate work only for demonstrated gaps.
4. Verify each dependency through public interfaces and tests rather than implementation-specific assumptions.
5. Resume issue #115 health wiring only after every dependency is available.
6. Update `SPEC.md` and implement the approved health boundary in the later behavior-changing PR.
7. Keep issue #115 open for the external acceptance harness after the health prerequisite lands.

## Open Questions

- Which issue and OpenSpec identifiers will own each cache authority?
- Does the existing `Orchard.ControlPlane` gate and status already satisfy the bounded production leadership requirement, and if not, which exact gap needs separate ownership?
- May one control-plane change own all three cache authorities, or do their security and coherence differences require separate reviews?

These ownership questions block implementation but do not change the approved health boundary.
