## MODIFIED Requirements

### Requirement: Counterfactual Capacity Diagnostics
Shared operator Node status SHALL expose the complete evaluator result together with its observation time.
Under `pre_cutover`, diagnostics SHALL label the result counterfactual, keep canonical enforcing values at `0`, and expose temporary legacy available slots separately.
Counterfactual diagnostics MUST NOT mutate scheduler, queue, placement, reservation, or dispatch authorization behavior.
This requirement traces to `SPEC.md` §4.6.2 and §7.3.5.

The complete-result requirement SHALL continue to govern the shared evaluator and full operator/admin diagnostics. Only the separately versioned cluster-reader serialization of Node list/detail SHALL instead expose the closed `dispatch_capacity` subset in [the reader projection](../../design.md#closed-reader-projections). It SHALL omit placement-capacity maps and arbitrary evidence/prose, while retaining the numeric fields with validated `mode`, `counterfactual`, `consumers_ready`, `authority_phase`, `policy_state`, `management_class`, `authority_decision`, `eligible`, `observation_time` and declared capacity `reason_codes`. Counterfactual labels SHALL retain their source meaning even in the enforcing phase. Observation time and stale/missing-evidence reasons SHALL remain distinguishable from response time and Node heartbeat freshness; missing time or a missing snapshot SHALL remain null. Invalid interpretation metadata SHALL fail closed rather than expose unlabeled numbers. Temporary `legacy_pre_cutover_*` evidence SHALL remain separate from canonical enforcing values. Reader serialization SHALL NOT alter evaluation, dispatch authority, shared facts or existing full operator/admin output.

#### Scenario: Approved ceiling is visible but not enforced
- **WHEN** a pre-cutover Node has an `approved_explicit` ceiling and fresh runtime evidence
- **THEN** diagnostics show the ceiling, `pre_cutover`, and the counterfactual evaluator result
- **AND** diagnostics report `controller_dispatch_ceiling_not_yet_enforcing`
- **AND** the approved ceiling does not authorize dispatch while the durable phase remains `pre_cutover`

#### Scenario: Missing policy is distinguishable
- **WHEN** an admitted production Node has no dispatch-capacity policy
- **THEN** diagnostics show Effective Dispatch Limit and Dispatch Headroom as `0`
- **AND** diagnostics include `controller_dispatch_ceiling_missing`
- **AND** diagnostics do not display a synthesized ceiling of `1`

#### Scenario: Reader sees labeled pre-cutover capacity
- **WHEN** a reader inspects Node list or detail with an approved pre-cutover ceiling and nonzero temporary legacy availability
- **THEN** the reader-versioned subset retains counterfactual and pre-cutover labels, observation time and stable reasons, zero canonical enforcing values and separately named legacy evidence
- **AND** neither numeric availability nor eligibility grants dispatch authority, and full operator/admin output retains the complete evaluator result

#### Scenario: Reader distinguishes stale capacity from fresh heartbeat
- **WHEN** a reader inspects a Node whose heartbeat is fresh but capacity observation is stale
- **THEN** the capacity subset retains the original observation time and `runtime_capacity_observation_stale`, independently of Node heartbeat freshness
- **AND** missing observation time stays null, invalid label values fail closed, and no response-time stamp or unlabeled number substitutes for the missing interpretation evidence

#### Scenario: Enforcing phase does not relabel counterfactual diagnostics
- **WHEN** a reader inspects a counterfactual snapshot evaluated under the enforcing phase
- **THEN** the subset retains both `authority_phase: enforcing` and `mode: counterfactual` with `counterfactual: true`, plus the source decision, policy and freshness evidence
- **AND** the shared evaluator and full diagnostics remain unchanged and the reader result is not represented as a dispatch reservation
