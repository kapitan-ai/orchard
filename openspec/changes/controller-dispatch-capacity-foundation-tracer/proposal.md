## Why

The approved F11 dispatch-capacity contract has no product implementation, so Orchard cannot yet persist Controller-owned ceilings, evaluate the contract centrally, or show operators what enforcement would decide.
This change establishes the smallest non-enforcing foundation that makes the migration state and counterfactual decisions observable without changing current dispatch behavior.

## What Changes

- Add durable per-Node dispatch-capacity policies and the cluster-wide authority phase in `pre_cutover`, including bounded `shadow_legacy` migration rows derived only from durable admission history.
- Add a pure shared evaluator with canonical values, explicit authority decisions, decision-specific available slots, eligibility, and stable reason codes, plus exhaustive truth-table tests.
- Make new Node Admission lock the durable phase and atomically persist an explicit `approved_explicit` ceiling, defaulting new admissions to `1` only when the administrator omits the value.
- Thread the optional ceiling, required policy reason, preview warning, and resolved policy values through the existing Admin API and local CLI admission paths.
- Persist bounded Runtime Endpoint capacity evidence needed by the evaluator without treating telemetry as policy.
- Add supervised Controller capability evidence with a `10000` ms heartbeat and an explicit all-five-consumers-ready value of `false` for this non-enforcing slice.
- Expose counterfactual policy and capacity diagnostics while leaving every dispatch, queue, placement, and acceptance consumer on its current behavior.
- Do not advance any policy or the singleton phase to `enforcing`.

## Capabilities

### New Capabilities

- None.

### Modified Capabilities

- `dispatch-capacity`: Implement the approved non-enforcing persistence, evaluation, admission, Controller capability, and counterfactual diagnostics subset without enabling F11 dispatch enforcement.
- `runtime-endpoints`: Persist bounded aggregate runtime capacity evidence used by the counterfactual evaluator while retaining Node ownership of the reported runtime limit.

## Impact

This change affects Controller database migrations and schemas, Node Admission transactions and existing admission surfaces, Runtime Endpoint observation normalization and persistence, supervised Controller membership, cluster-management diagnostics, and focused tests.
It adds no public inference behavior change and no enforcing capacity consumer.
It does not implement policy mutation or cutover APIs, temporary legacy claim serialization, per-Node acceptance gates, or any M7 fencing and recovery follow-up.

No SPEC.md behavior impact.
This change implements a bounded subset of the already approved `SPEC.md` §4.6.2, §7.3.5, §7.5.3, §8.3, §10.9, and §13.2 contract without modifying it.
