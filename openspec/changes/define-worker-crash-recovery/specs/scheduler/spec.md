## ADDED Requirements

### Requirement: Worker Crash-Loop Suppression Is An Independent Eligibility Gate

Production candidate construction, queue-capacity refresh, cold or warm load authorization, automatic load reconciliation, and final pre-execution authorization SHALL consume the durable current worker crash-loop projection for the exact Node and runtime model version.
An open projection SHALL mark that placement failed and reject it with stable reason `worker_crash_loop_open` before tiering, ranking, scoring, load, or execution.
Missing, malformed, stale, identity-unresolved, or authority-unavailable evidence after enforcement cutover SHALL fail closed without falsely reporting an open transition.
The only missing-projection exception SHALL be provisional cold-candidate treatment for a capability-proven exact placement with no Controller projection after every other ordinary gate passes.
The candidate SHALL retain normal tiering, ranking, selection, request-step, attempt, deadline, allocation, and release ordering; the Node Agent SHALL initialize only when no prior local record exists, and the Controller SHALL persist returned authoritative recovery evidence before final authorization or execution.
An ordinary load, a stale loaded observation, heartbeat recovery, or an independently clear §5.10 breaker MUST NOT bypass crash-loop suppression.
This requirement clarifies `SPEC.md` §§5.5, 5.9, 6.8, and 12.2.

#### Scenario: Crash-loop breaker is open on a loaded snapshot

- **WHEN** a stale ordinary placement snapshot says loaded but the durable exact recovery projection is open
- **THEN** the scheduler rejects the placement with `worker_crash_loop_open`
- **AND** it does not dispatch or call `EnsureModelLoaded`

#### Scenario: Breaker opens after model load

- **WHEN** the crash-loop projection opens or becomes unresolvable after model load but before `ExecuteInference`
- **THEN** final authorization rejects execution and releases Controller capacity effectively once
- **AND** the Request follows its existing attempt outcome and retry gates

#### Scenario: First load bootstraps recovery evidence

- **WHEN** a capability-proven exact placement has no Controller projection
- **THEN** Orchard may waive only that missing fact, evaluate and select a provisional cold candidate normally, start the attempt, acquire capacity, and issue one evidence-producing bootstrap load
- **AND** it cannot pass final authorization or execute on the placement until the returned closed recovery projection commits

#### Scenario: Another bootstrap gate fails

- **WHEN** a placement without a projection fails identity, lifecycle, trust, policy, model, resource, queue, or capacity eligibility
- **THEN** bootstrap is not authorized for that placement
- **AND** missing recovery evidence cannot cause an untracked or pre-allocation load

#### Scenario: Another model version remains healthy

- **WHEN** one exact model version has an open crash-loop projection
- **THEN** another version on the same Node remains independently eligible when every other gate passes
- **AND** no model-identifier-only suppression is inferred

#### Scenario: Controller cannot read recovery authority

- **WHEN** the Controller cannot establish current crash-loop state for a placement after enforcement cutover
- **THEN** it fails the eligibility decision closed through the existing authority-unavailable contract
- **AND** it does not report `worker_crash_loop_open` without durable evidence of that state

### Requirement: Crash-Loop And Model-Load Suppression Have Different Effects

The §5.10 model-load placement breaker SHALL continue to suppress cold or warm loading for its timed duration while allowing a separately valid already-loaded placement to remain dispatchable.
The §12.2 crash-loop breaker SHALL represent a failed exact runtime placement and SHALL suppress both loading and dispatch until explicit recovery succeeds.
Evaluation and diagnostics SHALL preserve both facts when both policies are active.
This requirement clarifies `SPEC.md` §§5.10, 6.8, and 12.2.

#### Scenario: Both placement policies are active

- **WHEN** the same resolved placement has both an open §5.10 model-load breaker and an open §12.2 crash-loop breaker
- **THEN** diagnostics preserve both independent states
- **AND** clearing either one leaves the other gate effective
