# PR #153 review — pilot health exposure split

**PR:** [kapitan-ai/orchard#153](https://github.com/kapitan-ai/orchard/pull/153)  
**Branch:** `najibninaba/health-exposure-split` at `5a36a74`  
**Comparison:** `origin/main...najibninaba/health-exposure-split`  
**Reviewed:** 2026-08-03  
**Disposition:** **Request changes. Do not merge.**

## Summary

The change establishes the intended route split on normal paths: public liveness and
readiness return status-only JSON, detailed health is routed through `operator_api`,
the staged predicate remains `orchard.readiness.legacy_m0.v1`, and the Console no
longer claims to mirror the public response. The current implementation is not yet
safe to merge because readiness faults can bypass the exact public contract. The CLI
also remains a permissive consumer of the removed rich public representation, and
the Operator no-store/test and OpenSpec completion claims are incomplete.

No implementation fixes were made as part of this review.

## Findings

### Blocker — readiness faults and hangs bypass the exact public response contract

**References:**

- `apps/orchard_controller/lib/orchard/api/health_controller.ex:14-19`
- `apps/orchard_controller/lib/orchard/api/health_evaluation.ex:13-22`
- `apps/orchard_controller/lib/orchard/api/error_json.ex:5-7`
- `apps/orchard_controller/test/orchard/api/health_controller_test.exs:7-48`
- `openspec/changes/pilot-health-exposure-split/specs/pilot-health-exposure/spec.md:10-28`

`HealthEvaluation.evaluate/0` handles only the two expected tuples from
`Readiness.status/0`. An exception, exit, throw, malformed return, or unbounded
readiness dependency escapes before `public_response/1` can reduce it. Phoenix then
uses the ordinary endpoint error representation (for example,
`{"errors":{"detail":"Internal Server Error"}}`) or leaves the request waiting on
the dependency. Either outcome violates `SPEC.md` §3.1, which requires public
readiness to produce only HTTP 200 with exactly `{"status":"ok"}` or HTTP 503 with
exactly `{"status":"error"}`.

The current tests exercise only liveness success and ordinary readiness success and
failure. They call `Router.call/2`, not the full Endpoint, and there is no injected
fault/timeout seam. Consequently they cannot catch the production error-rendering
path. The pilot OpenSpec scenarios likewise describe only ordinary predicate
pass/fail, which is the acceptance-criteria gap a red-green cycle should have exposed.

**Recommended fix:** put the unchanged legacy predicate behind a bounded, fail-closed
evaluation boundary. Normalize errors, exits, throws, invalid values, and timeout to
one unavailable evaluation; terminate timed-out work; map that evaluation publicly
to exact HTTP 503 `{"status":"error"}`. Reuse the same sanitized evaluation for
Operator health without changing the legacy check set. Add full-Endpoint regression
tests for ordinary failure, exception, exit/throw, malformed result, and timeout, and
add the corresponding stage-one OpenSpec scenario.

### Major — `orchardctl status` still accepts and renders the removed public diagnostics contract

**References:**

- `apps/orchard_cli/lib/orchard_cli/commands/status.ex:229-242`
- `apps/orchard_cli/lib/orchard_cli/commands/status.ex:336-360`
- `apps/orchard_cli/lib/orchard_cli/commands/status.ex:366-384`
- `apps/orchard_cli/lib/orchard_cli/commands/status.ex:398-467`
- `apps/orchard_cli/lib/orchard_cli/commands/status.ex:548-633`
- `apps/orchard_cli/test/orchard_cli/commands/status_test.exs:70-134`
- `apps/orchard_cli/test/orchard_cli/commands/status_test.exs:366-463`
- `docs/decisions/0016-pilot-health-exposure-before-complete-readiness.md:58-65`

The probe accepts every HTTP status in `200..599`, discards that status, and derives
readiness only from a JSON `status` field. `validate_health_contract/1` accepts maps
with arbitrary extra keys. The banner then still consumes `runtime`, `reason`,
`remediation`, `transport`, `console`, and `license` from that public body. This
allows contradictory pairs such as HTTP 503 plus `{"status":"ok"}` to render ready,
and it amplifies diagnostic data if a Controller regresses and sends the old rich
body.

The new remote-version test proves only that `version` and `build_ref` are no longer
used as identity. It deliberately accepts an invalid extra-key response, while the
shared fixtures and many existing assertions continue to normalize rich public
runtime/check/reason/remediation bodies. That contradicts ADR 0016's requirement
that public consumers use the HTTP status and exact status-only body.

**Recommended fix:** accept only these two complete pairs:

- HTTP 200 and exactly `%{"status" => "ok"}`
- HTTP 503 and exactly `%{"status" => "error"}`

Reject extra keys, mismatched HTTP/body status, and every other status as an invalid
health response. Remove rich-public-body fixtures and rendering expectations from
credential-free status tests. Keep any displayed version explicitly local; obtain
remote build/runtime diagnostics only through an authenticated Operator flow.

### Major — authorized Operator failure handling does not guarantee `no-store`, and the route-specific auth matrix is incomplete

**References:**

- `apps/orchard_controller/lib/orchard/api/ops/health_controller.ex:9-15`
- `apps/orchard_controller/lib/orchard/api/operator_health.ex:9-28`
- `apps/orchard_controller/test/orchard/api/ops/health_controller_test.exs:65-118`
- `apps/orchard_controller/test/orchard/api/ops/health_controller_test.exs:136-149`

`OperatorHealth.evaluate/0` runs before the controller attaches
`Cache-Control: no-store`. If readiness or unguarded metadata evaluation raises, the
authorized request falls into Phoenix error handling before the header is set. The
ordinary 200 and 503 tuples receive the header, but the exceptional path does not
satisfy the protected endpoint's no-store contract.

The route tests correctly cover missing credential → 401, tenant credential → 403,
and a successful admin credential. They do not cover a syntactically valid but
invalid bearer token, an actual cluster-scoped `operator` binding, authorized
readiness failure → 503 with `no-store`, or an authorized exceptional path. The
helper named `operator_token!/1` calls `ensure_cluster_admin_access/1`, so the test
description overstates its Operator-role coverage.

**Recommended fix:** establish no-store at a protected route/pipeline boundary that
runs before health evaluation, or guarantee that all authorized evaluation failures
are normalized before response rendering. Add route-specific tests for invalid token
401, actual Operator success, admin success, unauthorized 403, ordinary 503 with
`no-store`, and exceptional failure with `no-store`. Continue asserting that authn
and authz complete before any health probe.

### Major — OpenSpec completion state is syntactically valid but semantically inaccurate

**References:**

- `openspec/changes/health-readiness-contract-prerequisite/specs/controller-health-prerequisites/spec.md:206-229`
- `openspec/changes/health-readiness-contract-prerequisite/tasks.md:12-18`
- `openspec/changes/pilot-health-exposure-split/tasks.md:12-31`

The prerequisite package combines the permitted stage-one legacy evaluator with a
Console scenario that already requires every check from the future complete
tri-state evaluation, without marking that scenario as stage two. Task 2.5 is checked
complete even though the CLI still expects and renders removed rich public fields.
In the pilot package, tasks 2.4, 3.1, 4.1, 4.2, and 4.3 overstate exact public
failure handling, consumer migration, and route-specific regression coverage in the
ways described above.

Both strict validation commands pass because OpenSpec validation checks package
shape and requirement syntax; it does not prove implementation or checkbox truth.

**Recommended fix:** split the consumer requirements into explicit stage-one legacy
and stage-two complete/tri-state scenarios. Add current-stage invalid/exceptional
readiness behavior. Reopen or narrow the affected tasks until the implementation and
regression matrix satisfy them, then rerun strict validation.

## Verified non-findings

- `apps/orchard_controller/lib/orchard/api/router.ex:20-24,62-67` places
  `/ops/v1/health` only under `operator_api`; public health remains under `api`.
- `apps/orchard_controller/lib/orchard/api/readiness.ex:14-20,29-62` preserves the
  four-check legacy predicate and causal order and labels it
  `orchard.readiness.legacy_m0.v1`; no readiness cache or authority shim was added.
- `apps/orchard_controller/lib/orchard/console/overview_live.ex:418-425` accurately
  describes the Console as an internal view of the staged predicate rather than a
  mirror of the public body.
- The normal public-path tests assert exact serialized bodies, and the normal
  authorized Operator response includes `Cache-Control: no-store`.

## Validation performed

- `mise exec -- mix test apps/orchard_controller/test/orchard/api/health_controller_test.exs apps/orchard_controller/test/orchard/api/operator_health_test.exs apps/orchard_controller/test/orchard/api/ops/health_controller_test.exs apps/orchard_cli/test/orchard_cli/commands/status_test.exs`
  - Passed: Controller 27 tests; CLI 81 tests.
- `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate pilot-health-exposure-split --type change --strict --no-interactive`
  - Passed.
- `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate health-readiness-contract-prerequisite --type change --strict --no-interactive`
  - Passed.
- Required Orchard validation was reported successful on the PR; this review did not
  independently rerun the entire Elixir format/compile/Credo/Dialyzer/test/coverage
  workflow because no implementation change was made.

## Residual risks for pilot #118

- The labeled M0 predicate is intentionally incomplete: it does not prove
  model/tenant/API-key cache hydration or conditional write-path leadership. A 200
  readiness result is therefore not complete `SPEC.md` §3.1 serving readiness.
- Operator diagnostics depend on successful API Client authentication and its data
  sources. During the database/auth failures for which diagnostics are most useful,
  detailed remote health may be unavailable; ADR 0016 accepts that trade-off rather
  than restoring public detail.
- Runtime and licensing data in Operator health are observational and may be stale or
  unavailable; they intentionally do not gate the legacy aggregate.
- Public liveness/readiness still reveal process availability and one readiness bit.
  This is the intended black-box pilot surface, but deployment rate limiting and
  network exposure remain operational controls outside this PR.
- Until a bounded readiness evaluation is implemented, external load balancer or
  orchestrator deadlines can expire before Orchard emits its required 503 body.
