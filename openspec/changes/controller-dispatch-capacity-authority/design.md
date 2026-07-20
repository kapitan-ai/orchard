# Design: Controller dispatch capacity authority

## Context

The Node Agent already owns local worker admission and reports aggregate runtime concurrency through Runtime Endpoint Observations.
MultiNode, SingleNode, Node observation refresh, QueueManager, and dispatch currently interpret those values independently.
This design introduces durable Controller policy and a shared semantic evaluation without moving local enforcement out of the Node.

## Authority model

The Node owns the Runtime Concurrency Enforcement Limit and local enforcement.
The Controller owns the durable Controller Dispatch Ceiling and its own allocation accounting.
Placement Capacity remains Node-owned model-specific evidence.

For an admitted production Node:

```text
effective_dispatch_limit =
  min(runtime_concurrency_enforcement_limit, controller_dispatch_ceiling)
```

The formula produces a non-zero value only when the durable cluster phase is `enforcing`, trusted identity, lifecycle state `active`, health `healthy`, scheduler-fresh heartbeat, scheduler-fresh capacity observation, an `enforcing` explicit policy with a valid non-negative ceiling, and a valid runtime limit are all present.
Otherwise the Effective Dispatch Limit is `0`.

```text
dispatch_headroom =
  max(effective_dispatch_limit - controller_accounted_allocation, 0)
```

## Durable policy model

Use a one-to-one `node_dispatch_capacity_policies` record for each admitted production Node.
The record owns policy state, the Controller Dispatch Ceiling, approval actor, approval time, and approval reason.
This keeps missing policy distinct from an explicit ceiling of `0` and from temporary migration state.

The allowed policy states are:

```text
shadow_legacy -> approved_explicit -> enforcing
enforcing -> enforcing
```

Initial policy state is `approved_explicit` for admission before enforcement cutover and `enforcing` for admission after cutover.

`shadow_legacy` is created only for non-removed production Nodes whose Node Admission committed before the expand migration, identified from durable admission evidence.
Durably removed Nodes whose trust is revoked and removal is audited retain historical policy evidence but are outside the operational capacity cohort and do not block approval, quiescence, or cutover.
Later re-enrollment passes a new Node Admission under the then-current phase.
It carries no ceiling and is a temporary counterfactual observation state.
Legacy behavior may continue during the bounded shadow window, but the counterfactual Effective Dispatch Limit is `0` until an explicit ceiling exists.

`approved_explicit` contains an operator-approved ceiling and provenance but remains non-enforcing until every semantic consumer is wired.
`enforcing` means every named consumer applies the shared evaluation.
An audited ceiling update keeps an enforcing policy in the enforcing state.

Before enforcement cutover, new Node Admission atomically writes `approved_explicit` policy before the lifecycle transition commits.
After enforcement cutover, new Node Admission writes `enforcing` directly because every semantic consumer already applies the shared evaluation.
The administrator may provide any non-negative integer, including `0`.
When omitted, the Controller persists the explicit default `1`.
Policy write or audit failure rolls back admission.

Missing policy is never interpreted as legacy state.
Runtime telemetry is never copied into the durable ceiling.
Cutover preflight requires every otherwise eligible legacy Node to have an explicit approved ceiling and requires every named consumer to use the shared evaluation.
Cutover advances those policies to `enforcing` atomically, and post-cutover admission fails closed unless its `enforcing` policy and audit record commit with the lifecycle transition.

## Durable enforcement phase

Persist one cluster-wide dispatch-capacity authority row with phase `pre_cutover` or `enforcing`, a positive required contract version, and cutover provenance.
The row exists even for an empty cluster.
Admission locks and reads it inside the admission transaction, so the initial policy state is never inferred from existing Node policies, Controller version, transport, or cluster occupancy.

The shared evaluator takes the durable phase as an explicit input.
In `pre_cutover`, `shadow_legacy` and `approved_explicit` return counterfactual F11 values of zero plus one explicit legacy decision consumed by all named consumers.
That decision centrally calculates temporary available slots as positive fresh runtime `max_concurrency` or fallback `1`, minus non-negative fresh aggregate `active_request_count` or fallback `0`, floored at `0`.
It then subtracts unique non-released Controller-local temporary legacy claims, acquired serially across all placements and lanes and retained through terminal completion.
Legacy revalidation excludes only the current recognized temporary claim, and every queue grant must acquire that claim even when queue-source capacity advertised the same slots to multiple lanes.
It preserves the pre-F11 trusted, Active, healthy-or-degraded, fresh, placement, pool, format, memory, and breaker gates.
Queue contribution, scheduler eligibility, QueueManager, admitted SingleNode, and dispatch revalidation consume those temporary slots directly instead of requiring positive Dispatch Headroom or re-deriving legacy concurrency.
The missing or malformed active-count fallback is a named temporary legacy finding and never enters F11 enforcement or durable policy.
In `enforcing`, only an `enforcing` policy can authorize positive F11 capacity.
Either phase-policy mismatch fails closed.

Cutover runs under the migration advisory lock and one Postgres transaction.
It locks the phase row, proves every non-removed admitted production Node has approved policy, proves every non-retired Controller has fresh capability evidence whose contract version exactly equals the locked required version and whose indivisible all-consumers-ready declaration is true, advances approved policies, records provenance, and changes the phase to `enforcing` atomically.
Before the transaction, a visible Controller-local transition barrier blocks new temporary legacy claims while existing claims and accepted work drain.
Cutover requires zero live temporary claims plus a new fresh aggregate observation reporting zero active requests for every non-removed admitted production Node.
Only durable lifecycle `removed` with revoked trust and an existing successful removal audit qualifies for exclusion; other lifecycle states and unreachable Nodes remain blockers.
It then acquires every per-Node acceptance gate in stable order, revalidates quiescence, and holds the gates through commit and local phase publication.
Timeout or stale or nonzero evidence aborts quiescence without changing phase or policies and reopens legacy dispatch.
No live legacy work is adopted across cutover, and the zero-occupancy evidence never becomes durable policy.
The cutover request carries only `expected_required_contract_version` for optimistic comparison and cannot change the durable required version.
Any failure rolls back the entire transition.
A Controller that cannot support the recorded contract version fails readiness and refuses admission and dispatch after cutover.
The supervised Controller membership owner refreshes `last_seen_at` and the complete capability tuple atomically every `10000` ms.
The Operator API provides leader-only admin-authorized audited retirement for a non-Active, non-last Controller so stale evidence has an explicit recovery path before cutover.

## Management surface

Node Admission accepts an optional non-negative initial ceiling, defaults it explicitly to `1` only when omitted, and requires a capacity-policy reason.
The Operator API exposes policy reads to cluster `operator` or `admin`; policy approval or ceiling updates and enforcement cutover require cluster `admin` and Active leadership.
Every mutation supports a side-effect-free Action Preview, mutation-time authorization and phase revalidation, optimistic concurrency where policy is updated, explicit consequence confirmation, and atomic cluster-scoped audit persistence.
Under `f11_enforcing`, lowering below current Controller-accounted Allocation previews natural drain and pre-acceptance revalidation consequences.
Before cutover, admission and mutation previews warn `controller_dispatch_ceiling_not_yet_enforcing`, including for ceiling `0`, and do not claim the approved ceiling changes temporary legacy allocation.
The local `orchardctl nodes admit` surface accepts the same optional ceiling and required reason, previews the same resolved values, and uses the same atomic Controller-runtime transaction and audit contract.

## Controller-accounted Allocation

Controller-accounted Allocation is the number of unique, non-released, Node-scoped logical allocations owned by the current Active Controller.
An allocation begins when Node selection and the capacity claim are atomically committed.
It is retained through connection, model loading, scheduled, dispatching, accepted, running, and streaming work.
It is released exactly once on terminal completion, cancellation, pre-acceptance failure, or before a retry claims another Node.

Queued requests, unassigned queue grants, configured lane capacity, Runtime Endpoint active-request telemetry, and Placement Capacity do not count as Controller-accounted Allocation.
The final unit of headroom must be serialized so concurrent requests cannot both acquire it.
Dispatch Headroom authorizes acquisition of a new allocation only.
For revalidation before Node acceptance, the same shared evaluation serializes with allocation changes, excludes only the request's recognized allocation from the allocation operand, and requires the resulting value to be positive without counting that claim twice.
If the held allocation no longer fits, dispatch releases it exactly once and requeues or fails under the existing contract.
A request already accepted by the Node, running, or streaming is not forcibly cancelled solely because a ceiling is lowered.

One Controller-local acceptance gate exists per admitted production Node.
Final dispatch revalidation holds it continuously through Node acceptance or pre-acceptance failure, and ceiling mutation holds the same gate through commit and local publication.
Whichever operation acquires the gate first defines whether the work is accepted under the old policy and drains, or must revalidate under the new policy.
A cluster transition barrier coordinates those gates for cutover.
This is Controller-local F11 serialization, not cross-Controller leadership fencing or a durable permit.

This is a live Controller-local accounting contract.
It does not promise persistence across a Controller crash or leadership change.
M7 remains responsible for durable permits, leader fencing, reservation recovery, and compromised-node occupancy integrity.

## Shared evaluation

One pure transport-independent evaluation returns:

- Runtime Concurrency Enforcement Limit.
- Controller Dispatch Ceiling.
- Effective Dispatch Limit.
- Controller-accounted Allocation.
- Dispatch Headroom.
- Placement Capacity.
- Durable enforcement phase.
- Policy state.
- Normalized target `capacity_management_class`.
- Authority decision, `legacy_pre_cutover`, `f11_enforcing`, or fail-closed.
- Decision-specific available slots, including temporary `legacy_pre_cutover_available_slots` when applicable.
- Eligibility.
- Stable reason codes.

The following consumers must use that same result:

1. MultiNode candidate eligibility and queue-lane contribution.
2. SingleNode whenever the target resolves to an admitted or otherwise production-managed Node.
3. Node observation queue-source refresh and source clearing.
4. QueueManager aggregate Node claims across all lanes.
5. Dispatch-time revalidation after model loading and immediately before `ExecuteInference`.

No consumer may re-derive the formulas, default missing production policy to `1`, or treat configured queue capacity as dispatch authority.

## Placement aggregate bound

Placement Capacity can only reduce capacity for the requested Model Placement.
The effective capacity of one placement is bounded by its Node-owned Placement Capacity and the shared authority decision's available slots.
Every queue lane and placement on a Node shares the same aggregate allocation authority.
Under `f11_enforcing`, no new allocation across all placements and lanes may cause the total to exceed the Node's Effective Dispatch Limit.
Under `legacy_pre_cutover`, the centrally calculated temporary available slots and serialized temporary claims provide the aggregate bound while Effective Dispatch Limit remains counterfactual `0`.
A ceiling reduction may temporarily leave accepted, running, or streaming allocations above the new limit while they drain naturally.

Cold model loading retains its Node allocation while the model loads.
Dispatch revalidates the recognized pre-acceptance allocation without double-counting it and revalidates Placement Capacity before execution.

## Raising and lowering

Under `f11_enforcing`, lowering a ceiling applies to new allocations and pre-acceptance held-allocation revalidation immediately.
Accepted, running, and streaming work is not forcibly cancelled solely because the ceiling changed, and the Node does not enter lifecycle state `draining` merely because the ceiling changed.
Dispatch Headroom remains `0` while allocation is greater than or equal to the lowered Effective Dispatch Limit and becomes positive only as work finishes.

Under `f11_enforcing`, raising a ceiling does not create an allocation.
It remains bounded by the fresh Runtime Concurrency Enforcement Limit and every trust, lifecycle, health, freshness, placement, and breaker gate.
Queue wake-up follows shared re-evaluation.

## Source-development and compatibility boundary

Transport is not an authority classification.
An admitted production Node remains governed over BEAM, gRPC compatibility, or a static target reference.
Production inventory resolution happens before any source-development or compatibility exception is considered.

Admitted Production Evidence Safety is a separate always-on invariant.
An admitted target is `production_managed`, and missing, stale, invalid, or untrusted capacity evidence never downgrades it or authorizes unmanaged or compatibility semantics for it.

Each normalized target has Controller-owned `capacity_management_class` of `production_managed`, `unmanaged_source_development`, or `unmanaged_compatibility`.
An admitted inventory match always forces `production_managed`.
Unmanaged source development is valid only in source-development mode, and unmanaged compatibility is valid only for explicitly enabled compatibility configuration that does not match admitted inventory.

Classification is always-on target safety, not a staged behavior.
Missing, malformed, conflicting, telemetry-derived, transport-derived, or probe-derived classification fails closed for production dispatch with no legacy normalization, and only a valid explicitly classified unmanaged source-development or static compatibility target may retain documented legacy capacity behavior through shared capacity evaluation.
`dispatch_capacity_consumers_ready` proves only that the five named capacity consumers are ready for enforcement-cutover preflight; it never selects runtime behavior and never enables, disables, defers, or weakens this classification contract.
That documented legacy behavior includes bounded ephemeral normalization of a missing or zero runtime maximum to `1`, which populates only the ephemeral Runtime Concurrency Enforcement Limit and never creates or backfills a Controller Dispatch Ceiling.
An admitted production target can never fall back to unmanaged or compatibility behavior at any stage.
Broader production probe-failure direct scheduling fallback cleanup remains out of scope for this change.

## Diagnostics

Operator status exposes durable enforcement phase, policy state, normalized target management class, authority decision, all five aggregate capacity values, Placement Capacity, observation time, and stable reason codes.
Pre-cutover status also exposes temporary `legacy_pre_cutover_available_slots`, live temporary legacy claim count, and cutover quiescing state while the canonical F11 Effective Dispatch Limit and Dispatch Headroom remain `0`.
At minimum, the fixed vocabulary includes:

- `node_health_degraded`.
- `controller_dispatch_ceiling_missing`.
- `controller_dispatch_ceiling_invalid`.
- `controller_dispatch_ceiling_zero`.
- `controller_dispatch_ceiling_exhausted`.
- `runtime_concurrency_limit_unknown`.
- `runtime_concurrency_limit_exhausted`.
- `dispatch_headroom_exhausted`.
- `placement_capacity_exhausted`.
- `dispatch_capacity_revalidation_failed`.
- `dispatch_capacity_pre_cutover_legacy`.
- `dispatch_capacity_phase_policy_mismatch`.
- `dispatch_capacity_cutover_quiescing`.
- `dispatch_capacity_cutover_occupancy_not_zero`.
- `runtime_endpoint_management_class_missing`.
- `runtime_endpoint_management_class_invalid`.
- `dispatch_ceiling_shadow_mismatch`.
- `dispatch_ceiling_not_approved`.

Public request outcomes remain the existing sanitized `cluster_busy`, `queue_timeout`, and dispatch error contracts.
The term `Admitted Capacity` is prohibited because it conflates unrelated admission and capacity concepts.

## First implementation tracer

The first tracer is intentionally non-enforcing.
It adds the policy table and constraints, creates `shadow_legacy` rows for the existing cohort, adds the pure evaluator and truth-table tests, atomically persists admission default `1`, and exposes policy diagnostics.
It does not advance any policy to `enforcing` and does not claim production enforcement.

The next implementation slice is the first enforcing vertical tracer.
It must wire all five consumers, serialize temporary legacy and F11 allocation claims, add the transition barrier and per-Node acceptance gates, preserve each claim through model loading and Node acceptance, revalidate before execution, release once on every terminal path, and quiesce legacy occupancy before cutover.
Partial enforcing wiring is rejected because an unwired consumer could bypass the ceiling.

## Rejected alternatives

Runtime telemetry alone is rejected because it is not durable Controller policy.
Controller ceiling alone is rejected because the Node must retain local dynamic enforcement.
Permanent null meaning runtime-managed is rejected because it makes missing policy ambiguous.
Silent existing-row default `1` is rejected because it can collapse working capacity.
Telemetry backfill is rejected because observation is not operator approval.
Independent placement limits without an aggregate bound are rejected because multiple lanes can exceed Node authority.
Persisting only Effective Dispatch Limit is rejected because it erases the two authority inputs.
`Admitted Capacity` is rejected as ambiguous language.

## Follow-up boundaries

F11 defines durable policy and a serialized bound for one live Active Controller.
It does not add a durable dispatch permit, leader epoch, Node-verifiable capacity token, crash-recoverable reservation ledger, or proof of actual Node occupancy.
Those are M7-aligned follow-ups.

Malformed aggregate active-count handling, production probe-failure direct scheduling fallback, queue-source expiry and reservation provenance, and configured-base versus live-capacity provenance remain separate implementation findings.
