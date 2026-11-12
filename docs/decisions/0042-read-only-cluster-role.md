# ADR 0042: A dedicated API Client can hold cluster-reader authority

## Status

Accepted target contract.
Najib, product owner, accepted all four design decisions on 2026-11-12. `SPEC.md` records the reconciled target; the role remains inactive, with implementation and activation pending completion and proof of `cross-surface-authorization-contract` tasks 3.1–3.2 and the reader's own verification gates. Acceptance does not archive the open package, implement route admission, or authorize MCP work.

## Context

The accepted headless-deployment Q3 direction requires server-enforced read-only cluster authority before MCP work. Before this amendment, `SPEC.md` §10.4 had no such role. ADRs [0004](0004-admin-api-cluster-admin-auth.md) and [0007](0007-operator-api-operator-or-admin-auth.md) bind management bearer authority to enabled API Clients with cluster RoleBindings. [ADR 0033](0033-cross-surface-authorization.md) defines shared authority and defers fine-grained agent delegation; the [accepted credential-management requirement](../../openspec/changes/cross-surface-authorization-contract/specs/credential-management/spec.md#requirement-credential-authority-is-scoped-to-full-target-privilege) explicitly makes caller grants additive. Tool allowlists do not restrict a principal's authority.

This decision settles the new grant's subject/scope, its relationship to stronger grants, its disclosure boundary and activation sequence. The earlier headless direction alone did not settle those choices.

## Decision

Use `cluster_reader` as a cluster-scoped API Client RoleBinding, not a new credential kind or Console role. Keep grants additive: a client also holding operator/admin authority retains it. A reader grant is not a deny ceiling; all tokens inherit current owner authority.

Provision dedicated reader-only clients through an explicit mode of the existing Controller-host bulk-provision command, without its default inference grant. Reject mixed-authority clients in that mode rather than deleting grants, and display mixed authority as Not read-only. General grant management can intentionally broaden a client later; issuance history is not proof of current read-only authority.

For each management action, a reader-bearing principal takes the reader path when it lacks independently sufficient existing cluster operator/admin authority for that action, whatever other grants it holds. On that path, including for reader-plus-inference clients, permit only the enumerated Operator GET actions with closed, typed, non-content projections, non-observing execution and reader leadership gates. Deny every mutation, Admin read, site-local `/metrics`, request content and Action Preview. Read-only means neither permission to mutate nor permission to disclose arbitrary tenant data. [The change design](../../openspec/changes/add-read-only-cluster-role/design.md) owns the route matrix and projection details.

Keep ADR 0004's admin-only boundary. Extend ADR 0007's Operator admission and [ADR 0016's health boundary](0016-pilot-health-exposure-before-complete-readiness.md) only through this explicit, activation-gated reader policy. Give reduced root/nested representations their own versions and derive them as subsets of shared operator builder facts. Preserve ADR 0033's current-authority and writer-fencing requirements, cluster-privileged target classification and agent-delegation deferral. Land the contract first; activation waits for cross-surface tasks 3.1–3.2. Fenced serving-Controller health/cluster observation on Standby is a narrow accepted exception to active-only family operations, not an exception to authoritative Postgres or caller fences. This is not MCP implementation or a COMPLETE command-family claim.

## Consequences

Dedicated monitoring clients can receive bounded cluster evidence without write authority. Closed projections exclude tenant content and arbitrary metadata/prose, but still disclose cross-tenant operational IDs, existence, scores, codes and changing counts; no traffic-analysis protection is promised. Initial coverage needs externally supplied model/version inventory and incident request IDs. Bounded placement inventory and tenant-dimension-free aggregate telemetry remain separately reviewed follow-ups. `/metrics` stays operator/admin-only, so today's site-local scraper still needs a write-capable token.

Under additive grants, read-only is a property of the current grant set, not of the token. Cluster `authority.roles/read_only` self-inspection mitigates mistakes; the projection marker alone proves neither exclusive nor lasting read-only authority. Provisioning and display must reflect current grants. Reader-bearing clients, even when a stronger grant initially selects full output, reselect path/projection under transmission fences after authority changes; stale full payloads are rebuilt or refused, never released merely because read permission survives. Existing operator-only reads remain plug-time until their family migrates. The product owner accepted this stricter new-role boundary and the Standby exception. Shared fences and compatible readers/writers are activation prerequisites, not optional hardening.

## SPEC.md impact

The accepted target is reconciled in §§2.5, 3.1, 4.6.1, 4.6.2, 7.1, 7.3, 7.3.1, 7.3.5, 7.4/7.4.1/7.4.4, 8.3, 10.4, 10.9–10.11, 11.9 and 12.2.3 as scoped in the [proposal impact table](../../openspec/changes/add-read-only-cluster-role/proposal.md#specmd-impact). §9.1 explicitly retains the metrics denial. No operator/admin behavior or runtime availability changes in this acceptance record; remaining cross-owner reconciliation and sync are tracked in the open change's tasks.
