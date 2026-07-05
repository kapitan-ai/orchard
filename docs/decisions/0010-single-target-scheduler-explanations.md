# ADR: Scheduler explanations from a single runtime target

## Status

Proposed. Resolves GitHub issue #49 once accepted.

## Context

`auto_scheduler/0` in `apps/orchard_controller/lib/orchard/inference.ex` selects `Orchard.Scheduler.MultiNode` when explicit `:runtime_endpoint_targets` exist or when `length(runtime_client_targets()) > 1`, and `Orchard.Scheduler.SingleNode` otherwise. `SingleNode` (`apps/orchard_controller/lib/orchard/scheduler/single_node.ex`) builds a schedule map with no `scheduler_explanation` key, so `Requests.record_schedule/2` (`apps/orchard_controller/lib/orchard/requests.ex`) persists no scored/skipped/rejected candidates and the explanation surfaces — Operator API, `orchardctl requests inspect`, the Console request panel — render the empty legacy shape.

One refinement to the issue as filed: the gap is narrower than "any single-worker topology". Explicit Runtime Endpoint targets "force endpoint-aware scheduling even when only one target is configured" (`Inference.runtime_endpoint_targets/0` doc), so the default BEAM split-role path already runs MultiNode with one worker. Only the legacy gRPC-compat path (a single `runtime_client_target(s)` entry) falls to SingleNode. The `> 1` threshold is therefore a transport inconsistency, not a designed rule.

Code reading shows MultiNode with one candidate is neither expensive nor divergent in placement outcome. `runtime_endpoint_targets/0` falls back to normalized legacy gRPC targets; MultiNode probes each target (SingleNode also probes status per request, so probe cost is equal), persists the observation, joins persisted schedulable nodes, ranks the single candidate, and emits the explanation. When no schedulable node or probe outcome exists, `fallback_schedule/3` in `apps/orchard_controller/lib/orchard/scheduler/multi_node.ex` delegates to `SingleNode.default_schedule/3` with the same target — identical behavior. The incremental cost is one observation upsert plus a node lookup per request. The one visible difference: proven saturation returns `:cluster_busy` instead of `:model_busy` (both busy-class errors in `apps/orchard_controller/lib/orchard/inference/chat_error.ex`).

SPEC.md §7.3.5 defines no single-node exemption and states: "Scheduler explanation generation, validation, and persistence are observational. An invalid or unbuildable explanation SHALL NOT fail, block, or alter the user's inference request."

## Decision

Make explanation coverage uniform: select MultiNode whenever any runtime target exists (predicate becomes non-empty `runtime_client_targets()`), keeping SingleNode as the no-target fallback and MultiNode's degradation path. Empty explanation panels in the smallest real deployment read as a defect; since the single-candidate placement outcome is equivalent and the cost negligible, uniform observability wins over documenting the threshold, which would enshrine a transport inconsistency the BEAM path already contradicts.

## Consequences

Single-target gRPC deployments gain persisted explanations and runtime observations at a small per-request DB cost. Saturation on that path reports `cluster_busy` rather than `model_busy`; a target whose node is not yet admitted still yields no explanation via fallback, which is correct — there are no lifecycle-managed candidates to explain. Scheduler-selection tests need updating for the new predicate.

## SPEC.md impact

No change required — §7.3.5 specifies explanation shape and observational semantics without any target-count threshold; this change removes an implementation threshold SPEC.md never defined. An optional clarifying sentence in §7.3.5 ("explanations are produced whenever at least one runtime target is configured") may be added when the edge lands.
