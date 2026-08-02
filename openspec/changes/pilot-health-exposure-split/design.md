## Context

The current `HealthController` combines readiness evaluation with public rendering
and observational build, transport, Console, runtime, licensing, reason, and
remediation detail. The evaluator is an M0 predicate, not the complete `SPEC.md`
§3.1 aggregate. Pilot #118 needs the disclosure removed without inventing missing
cache or leadership authorities.

## Goals / Non-Goals

**Goals:**

- Separate predicate evaluation from public and Operator representations.
- Make the public representation exact and permanently minimal.
- Preserve the current predicate unchanged and label it honestly.
- Reuse the existing Operator-or-admin authentication boundary.
- Keep all observational probes non-gating.

**Non-Goals:**

- Implement model, tenant, or API-key cache authorities.
- Change the current readiness predicate or remove its transport/boot checks.
- Claim complete §3.1 readiness.
- Implement issue #115 probes, telemetry, metrics, dashboards, or alerts.

## Decisions

### Separate evaluation, detail, and transport rendering

`Orchard.API.HealthEvaluation` translates `Readiness.status/0` into one internal
result. The public controller converts only its boolean outcome to the exact public
body. `Orchard.API.OperatorHealth` owns the diagnostic representation and all
observational probes. The Operator controller adds authorization through the
existing router pipeline and marks responses `no-store`.

This avoids two readiness policies: public and Operator paths consume the same
result shape while exposing different representations.

### Version the staged predicate

`Readiness.contract_version/0` returns
`orchard.readiness.legacy_m0.v1`; `check_order/0` returns the existing causal order.
`Readiness.status/0` is unchanged. Operator detail returns both values under
`readiness_contract`, making the limitation machine-readable without exposing it
publicly.

The later complete aggregate receives a new contract version only when real
serving/authentication cache-loaded sources and conditional leadership authority
exist. No shim may satisfy those missing conditions.

### Make the disclosure removal irreversible

Public bodies contain one `status` key. There is no query parameter, content
negotiation, alternate route, cache, or compatibility representation for old rich
health. Operator detail is the only HTTP diagnostic surface, and public details are
never restored.

### Accept bounded CLI loss

Credential-free `orchardctl status` continues to probe public readiness for
reachability and ready/degraded state. It uses only its local version and never
presents public response version/build fields as remote Controller identity. No
credential is added to the public probe.

## Risks / Trade-offs

- Operators without an Operator token lose inline diagnostics; this is intentional
  and documented.
- The legacy predicate remains incomplete; explicit versioning and SPEC text prevent
  a false full-readiness claim.
- Auth failure can hide diagnostics during incidents; no unauthenticated fallback is
  allowed because it would restore the disclosure.

## Migration Plan

1. Record the ADR and §3.1 exposure contract.
2. Add evaluation and Operator-detail modules, route, and auth/status tests.
3. Reduce public controllers and exact-body tests.
4. Migrate CLI, Console copy, and operator documentation.
5. Validate this OpenSpec package and the focused Elixir surface.
6. Implement the complete aggregate later under its prerequisite owners.
