## Why

The product owner's 2026-11-11 Q3 decision in [headless D5](../define-headless-deployment/design.md#d5-defer-mcp-implementation-accept-a-client-side-adapter-after-read-only-authority) requires server-enforced read-only cluster authority before any MCP work and rejects relying on client-side tool restrictions. An `operator` API Client can already retry requests, recover workers, and clear circuit breakers. `SPEC.md` §10.11.1 states the analogous no-tool-allowlist restriction for browser sessions; headless D5 supplies the API-token/MCP decision here.

Read-only also needs a disclosure boundary: GET responses can contain request content, arbitrary diagnostic maps, administrator reasons, and tenant identifiers. Merely admitting every GET is insufficient.

## What Changes

**Proposal only, pending Najib's acceptance.** This package and proposed ADR 0042 do not amend current `SPEC.md`, implement the role, or authorize MCP work.

- Propose `cluster_reader`, an API Client RoleBinding with cluster scope, admitting only the eight current Operator GET routes listed in [the design](design.md#current-route-admission). Each uses a closed content-free projection; every Admin route and `/metrics` remain excluded.
- Keep grants additive. A dedicated reader-only API Client is read-only; adding `operator`, `admin`, or inference authority makes it broader, never an attenuated token. Provisioning and Console display must make that distinction explicit.
- Apply the reader path whenever a reader-bearing principal lacks independently sufficient existing cluster operator/admin authority for the requested management action, whatever other grants it holds. This includes reader-plus-inference clients: enforce reader projections, side-effect and leadership rules, refuse every mutation and Action Preview using existing API refusal envelopes, and deny unclassified routes by default.
- Add explicit opt-in reader-only bulk provisioning, a role-value/scope migration, accurate Console role display, non-observing reads, and route/security regression gates in the later implementation.
- Classify every specified but unimplemented management GET without claiming it exists. Preserve cross-surface authorization and command-family migration ownership.

## Capabilities

### New Capabilities

- `read-only-cluster-role`: API Client reader authority, exact route/data admission, additive grants, provisioning, and side-effect boundaries.

### Modified Capabilities

- `operator-command-authority`: Admit `cluster_reader` for bounded breaker inspection, but not clear, through Controller-owned authority. No CLI family becomes COMPLETE.
- `api-client-provisioning`: Make the dedicated reader mode an explicit exception to default inference assignment; retain inference authorization and one-time secret custody.
- `pilot-health-exposure`: Keep full diagnostics Operator/admin-only while admitting non-observing, bounded, versioned reader health.
- `runtime-endpoints`: Separate reader status-only recovery evidence from existing hydration and write-authorized recovery commands.
- `scheduler`: Preserve full internal explanation diagnostics while specifying a versioned reader serialization without them.
- `dispatch-capacity`: Add a reader-specific serialization exception retaining bounded counterfactual, phase and freshness evidence; preserve the complete evaluator and full operator/admin diagnostics.

## Impact

### SPEC.md impact

The following amendments are **required after acceptance**, not made by this proposal:

| Section | Required reconciliation |
| --- | --- |
| §3.1 | Retain full health diagnostics under Operator/admin authority; explicitly admit the bounded non-observing reader health representation without changing public health or the staged readiness predicate. Reconcile ADR 0016 and the main pilot-health requirement. |
| §4.6.1 | Keep mandatory nullable `runtime.diagnostics` for full operator health; explicitly omit it from the separately versioned reader shape. Reconcile the accepted open redacted-observation health requirement. |
| §4.6.2 | Add the narrow reader serialization exception to complete capacity diagnostics: retain validated counterfactual/phase/policy/decision labels, observation time and freshness/reason codes with numeric values and separate temporary legacy evidence; omit placement maps. Preserve the evaluator and full operator/admin diagnostics, including pre-cutover zero enforcing values. |
| §§7.1, 7.3, 7.3.1 | Add restricted `cluster_reader` admission to the Operator surface and the Console-disabled remote-management sentence; name method/action and closed-projection boundaries, current read table, future reads, and unchanged role-required 401/403 envelopes. Add the existing circuit-breaker routes missing from §7.3.1's inventory. Retain the Admin boundary and say inference-only credentials do not authorize management. |
| §7.3.5 | Define the reader's reduced scheduler projection separately from the existing operator/admin explanation; no arbitrary diagnostics, components, target references, or error details. |
| §§7.4, 7.4.1 | Explicitly retain admin-only admission for all current and specified Admin reads; no reader exception, including credential and Console Identity inspection under §10.11. |
| §7.4.4 | Add the explicit `--access-level` option, reader-only batch validation and non-secret scope summaries without changing CSV or protected output. |
| §8.3 | Add the fifth role value and restrict its subject/scope to `service_account` with null `tenant_scope_id`; preserve the accepted pending `console_identity` subject extension. |
| §10.4 | Add `cluster_reader`, exact permitted reads, additive-grant semantics, no automatic inference grant, and the opt-in exception to bulk provisioning's inference default. |
| §§10.9–10.11 | Preserve closed audit schemas, capture restrictions, action-time policy and agent-delegation deferral; classify reader-bearing clients as cluster-privileged targets. Require projection/path re-selection at delivery after authority downgrade. Explicitly exempt only fenced serving-Controller health/cluster reads from §10.11.2's active-only family requirement, including caller self-authority; authoritative Postgres remains required. No read-success audit writes or token-use expiry/revision extension. |
| §§2.5, 11.9 | Clarify the same narrow health/cluster observation exception alongside active ownership of durable operations, preserving active-only target reads and all writes. |
| §11.9 | Document the explicit reader provisioning option under the existing Controller-host CLI baseline, not a new portable provisioning family. |
| §12.2.3 | Preserve targeted hydration for existing recovery consumers; reader status uses already-hydrated evidence or refuses unavailable evidence without hydration. Keep operator/admin recovery behavior and checkpoint safety unchanged. |

`SPEC.md` §9.1's `/metrics` operator/admin boundary and tenant-label rules remain unchanged. No public inference, Portal, Node trust, distribution, platform-support, or MCP contract changes.

The accepted cross-surface SPEC text has already landed. After acceptance, land this reader contract reconciliation first, then rebase the cross-surface implementation onto it. Reader activation is blocked on completion and proof of `cross-surface-authorization-contract` tasks 3.1–3.2 (shared fences and retained-writer closure), not full named-Console cutover. [Design integration order](design.md#integration-order) records the stricter fenced-reader versus current plug-time operator baseline, mixed-client delivery checks, and the narrow health/cluster Standby exception.

Implementation will affect Controller governance/authentication/presenters, the RoleBinding migration, bulk provisioning, existing Console access summaries, CLI parsing and their tests. Update [headless coverage](../../../docs/headless-mode.md) and reconcile `add-operator-api-reads` admission/shared-builder rules with reader-specific versions, without waiving its new-version requirement for removed fields. [The route audit](design.md#route-by-route-contract-reconciliation) covers all eight admitted reads and their accepted contracts. Initial coverage needs external Model UUID/version inventory and incident request IDs; placement inventory and aggregate telemetry are named future changes, not routes admitted here. Content exclusion does not hide cross-tenant operational metadata or provide traffic-analysis protection. This proposal changes Markdown only.
