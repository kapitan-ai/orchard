# Controller dispatch is bounded by a mandatory per-Node ceiling

## Status

Accepted.

## Context

Orchard currently lets Node-reported aggregate concurrency telemetry act as the Controller's dispatch authority.
That conflates the Node Agent's local enforcement responsibility with the Controller's responsibility to govern how much work it allocates to an admitted production Node.
The distinction becomes critical when runtime limits change, telemetry is absent, a Node becomes unhealthy or stale, or an operator needs to reduce new work without cancelling running requests.

The decision is hard to reverse because it fixes the authority boundary across Node Admission, scheduling, queue capacity, dispatch, diagnostics, and later Active/Standby hardening.
It is surprising because both the Node and the Controller own different limits that apply simultaneously.
It resolves a real trade-off between runtime-managed capacity, Controller-only policy, and an explicit composition of both authorities.

## Decision

Every admitted production Node has one mandatory durable Controller Dispatch Ceiling in steady-state operation.
The operational cohort begins at committed Node Admission and ends only at durable lifecycle `removed` with trust revoked and removal audited.
A removed tombstone retains its historical policy but does not block approval, quiescence, or cutover, and later re-enrollment requires a new admission policy.
The only temporary exception is the bounded pre-F11 `shadow_legacy` cohort, whose durable policy record deliberately has no ceiling, authorizes none of the new semantics, and remains distinct from a missing policy record.
New Node Admission persists an explicit ceiling atomically with admission and uses the explicit default `1` when the administrator omits the value.
An explicit ceiling of `0` is valid policy for stopping new Controller allocations under `f11_enforcing` without changing Node Lifecycle State.
Before cutover, every approved ceiling is recorded policy but is not yet allocation authority, and previews must warn that even `0` does not change temporary legacy allocation.

The Node owns its dynamic Runtime Concurrency Enforcement Limit and enforces that limit locally.
For a trusted, Active, healthy production Node with scheduler-fresh heartbeat and capacity observations, valid runtime and ceiling values, durable cluster phase `enforcing`, and policy state `enforcing`, the Effective Dispatch Limit is the smaller of the Runtime Concurrency Enforcement Limit and the Controller Dispatch Ceiling.
Before cutover, new admissions enter non-enforcing `approved_explicit`; after cutover, new admissions enter `enforcing` directly.
Under `f11_enforcing`, the Effective Dispatch Limit is `0` for an untrusted, non-Active, degraded, unhealthy, stale, policy-missing, or runtime-limit-missing production Node.
Dispatch Headroom is the non-negative difference between the Effective Dispatch Limit and Controller-accounted Allocation.

Controller-accounted Allocation counts unique, non-released, Node-scoped logical allocations owned by the current Active Controller.
It does not derive from Node-reported active request telemetry or Placement Capacity.
The current Active Controller serializes allocation of the final unit of headroom, retains one allocation through model loading and execution, and releases it exactly once before retry or after failure, cancellation, or completion.
Pre-acceptance revalidation excludes only the request's recognized allocation from the allocation operand so the claim is not counted twice.

Placement Capacity remains Node-owned and may further restrict a requested Model Placement.
Placement and queue-lane capacity never increase aggregate authority beyond the shared authority decision's available slots, and under `f11_enforcing` no new allocation across all placements on a Node may cause the total to exceed its Effective Dispatch Limit.
A lower ceiling may temporarily leave accepted, running, or streaming allocations above the new limit while they drain naturally.

Under `f11_enforcing`, lowering a Controller Dispatch Ceiling blocks new allocation above the new limit, revalidates pre-acceptance held allocations, and lets accepted, running, or streaming work drain naturally without forced cancellation solely because of the reduction.
Under `f11_enforcing`, raising a ceiling creates no allocation by itself and remains bounded by current runtime enforcement and every other eligibility gate.

Existing Nodes migrate through `shadow_legacy`, `approved_explicit`, and `enforcing`.
The legacy cohort is explicit and temporary, receives no silent default of `1`, and receives no telemetry-derived durable ceiling.
Operator approval persists the ceiling and provenance before enforcement.
After cutover, a missing policy fails closed with Effective Dispatch Limit `0`.

One durable cluster-wide enforcement phase distinguishes `pre_cutover` from `enforcing` and records the required contract version plus cutover provenance.
Admission locks and reads that marker in its transaction instead of inferring cutover from policy rows, Controller version, or cluster occupancy.
In `pre_cutover`, every named consumer uses one shared legacy decision while F11 Effective Dispatch Limit and Dispatch Headroom remain counterfactual zero for `shadow_legacy` and `approved_explicit`.
That decision centrally freezes the pre-F11 calculation as positive fresh runtime maximum or fallback `1`, minus non-negative fresh reported aggregate active count or fallback `0` and live temporary legacy claims, with the complete result floored at zero exactly once, equivalent to `max(limit - reported - claimed, 0)`, under the pre-F11 trusted, Active, healthy-or-degraded, fresh, placement, and routing gates.
Every legacy dispatch also acquires one serialized Controller-local temporary claim across all placements and lanes, and that live claim count is one of the operands subtracted before the single final floor.
The claim remains through Node acceptance and terminal completion so concurrent lanes cannot spend the same temporary slot.
Cutover requires fresh evidence from every non-retired Controller whose published contract version exactly equals the locked required version and whose all-consumers-ready declaration is true, atomically advances approved policies and the marker, and makes a Controller that cannot enforce the recorded contract version fail closed after cutover.
Cutover quiesces new legacy claims, waits for all temporary claims to release and for new fresh aggregate observations to report zero active requests on every non-removed admitted production Node, then holds every applicable per-Node acceptance gate while it revalidates and commits.
It never adopts live legacy work across the phase boundary and never derives durable policy from the zero-occupancy observation.
The supervised Controller membership owner refreshes the complete capability tuple every `10000` ms, and the leader-only admin retirement surface supplies the audited recovery path for a stale non-Active, non-last Controller.

One shared transport-independent evaluation supplies the capacity semantics to MultiNode, admitted SingleNode, Node queue-source refresh, QueueManager, and dispatch-time revalidation.
A consumer that cannot assemble the Controller-owned facts for that evaluation from current authenticated evidence fails closed with the stable scheduler rejection reason code `dispatch_capacity_facts_unavailable` instead of falling back to telemetry or a permissive default.
Transport selection does not create an exemption for an admitted production Node.
Every normalized target carries Controller-owned `capacity_management_class`, admitted inventory always forces `production_managed`, and absent, invalid, or inferred classification fails closed.
Only a valid explicitly classified unmanaged source-development or compatibility target may retain legacy capacity behavior.

The normative management surfaces are Operator API policy reads for cluster `operator` or `admin`, leader-only and admin-only Operator API policy mutations and enforcement cutover, and matching Admin API and local `orchardctl nodes admit` inputs for the initial ceiling and reason.
API mutations require cluster `admin`, while local CLI admission uses the established Controller-runtime authority boundary; both require Action Preview, explicit confirmation when consequences require it, mutation-time revalidation, and atomic cluster-scoped audit persistence.
Per-Node policy mutation and final dispatch revalidation share one Controller-local acceptance gate that remains held through Node acceptance or pre-acceptance failure.
This makes either acceptance or the policy change happen first without an authority gap, while leaving distributed leadership fencing to M7.
Both gate consumers are bounded rather than blocking: policy mutation and dispatch each fail with `dispatch_capacity_acceptance_gate_busy` when they cannot acquire the gate within their own bound, so neither waits behind an in-flight dispatch to the same Node.
A dispatch that cannot establish whether its runtime execution ended quarantines that Node Controller-locally, so every later evaluation treats it as unreachable instead of counting an unresolved execution as free capacity; the quarantine does not expire and exposes no operator-release seam, which keeps release out of unauthenticated operator reach; today it survives an allocation authority restart and clears only with the Controller, and durable survival plus audited release after verified reconciliation land with durable permits and crash recovery in M7.
`SPEC.md` §4.6.2 states this quarantine contract normatively, and §3.2 places the quarantine store at the Controller root ahead of the inference subtree.

## Rejected alternatives

Runtime telemetry alone is rejected because it gives the Controller no durable dispatch policy.
Controller policy alone is rejected because the Node must retain local authority to reduce its dynamic runtime limit and reject excess work.
A permanent null ceiling meaning runtime-managed is rejected because it makes missing policy indistinguishable from deliberate policy and migration state.
Silently assigning existing Nodes a ceiling of `1` is rejected because it can unexpectedly reduce working capacity.
Inferring a durable ceiling from telemetry is rejected because observations are not operator-approved policy.
Independent per-placement ceilings without an aggregate bound are rejected because multiple lanes could exceed Node-level authority.
Persisting only the Effective Dispatch Limit is rejected because it erases the two independent authority inputs.
The term `Admitted Capacity` is rejected because it conflates Node Admission, Request Admission, policy, runtime enforcement, and remaining headroom.

## Consequences

Node Admission and operator policy changes become auditable capacity-authority writes.
Diagnostics must show the separate runtime limit, Controller ceiling, effective limit, Controller allocation, headroom, Placement Capacity, policy state, management class, authority decision, decision-specific available slots, eligibility, and reason codes.
Production capacity becomes fail-closed when policy, trust, health, freshness, or runtime evidence is missing.
Source-development and compatibility exceptions require explicit unmanaged classification and cannot be inferred from transport.
A target that an operator explicitly enabled as a static Controller-owned runtime endpoint, and that resolves to no admitted inventory, counts as that explicit compatibility configuration; nothing about its transport, address shape, or probe outcome contributes to the class.

F11 provides durable Controller policy and a serialized Controller-local bound on new allocations by one live Active Controller.
It does not provide a durable distributed dispatch permit, leader epoch, Node-verifiable token, crash-recoverable reservation ledger, or proof of actual Node occupancy.
Durable dispatch permits, leadership fencing, reservation recovery, and compromised-node occupancy integrity remain M7-aligned follow-ups.

## SPEC.md impact

Update required in `SPEC.md` §4.1, §4.4, §4.6.1, new §4.6.2, §5.4, §5.5, §5.9, §7.3.5, §7.5.3, §8, §10.9, and §13.2.
