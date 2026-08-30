## ADDED Requirements

### Requirement: Durable canonical breaker authority

Orchard SHALL persist Node breakers by canonical `node_id` and placement breakers by canonical `(node_id, model_id)` in Postgres.
Node breaker identity SHALL retain referential integrity to Node inventory.
Placement breaker `model_id` SHALL be a validated catalog UUID without a database foreign key to the deletable model row, so retired-model history survives and a re-imported model with a new UUID does not inherit suppression.
It SHALL persist a globally idempotent failure identity, breaker kind, canonical target identity, generation, closed failure class, source occurrence evidence, database decision time, current state, suppression deadline, and resulting transition without request content or secrets.
Recording and clearing MUST serialize on canonical breaker identity so concurrent Controllers cannot lose a contribution or produce inconsistent transitions.
This requirement implements `SPEC.md` §5.10 under the Postgres and Active/Standby authority in §3.3.

#### Scenario: Duplicate failure delivery crosses Controllers

- **WHEN** two Controller processes deliver the same eligible failure identity for one canonical breaker
- **THEN** exactly one contribution affects the rolling window
- **AND** both callers observe the same durable resulting transition

#### Scenario: Identity cannot be proven

- **WHEN** the producing Node or model cannot be resolved to canonical durable identity
- **THEN** Orchard refuses the contribution without attributing it elsewhere
- **AND** the failure does not change any breaker

#### Scenario: Retired model is re-imported

- **WHEN** a catalog model is deleted after placement breaker evidence exists and equivalent model content is later imported under a new UUID
- **THEN** the historical breaker evidence retains the retired model UUID
- **AND** the new placement does not inherit the retired placement's suppression

### Requirement: Exact rolling-window transitions

Each record or read decision SHALL use database-authoritative `decision_time`.
The applicable rolling window SHALL include current-generation contributions in `(decision_time - window, decision_time]` and SHALL use source `occurred_at` only as evidence and clear-fence input.
The Node breaker SHALL open on the third eligible contribution in 60 seconds and suppress for five minutes.
The placement breaker SHALL open on the third eligible contribution for one placement in 10 minutes and suppress cold or warm loading for 15 minutes.
Suppression SHALL expire when `decision_time >= suppressed_until`, and recording while open MUST NOT extend the original suppression deadline.
Eligibility and durations remain those fixed by `SPEC.md` §5.10.

#### Scenario: Contribution lies exactly on the lower boundary

- **WHEN** an earlier contribution decision time equals `decision_time - window`
- **THEN** that contribution is outside the rolling window
- **AND** a contribution later than that boundary is inside it

#### Scenario: Decision reaches the suppression deadline

- **WHEN** database decision time equals or exceeds `suppressed_until`
- **THEN** the breaker evaluates as expired
- **AND** every other scheduling eligibility gate remains independently required

### Requirement: Closed failure eligibility and target isolation

The Node breaker SHALL count only `pre_acceptance_unavailable` and `worker_or_node_loss`.
The placement breaker SHALL count only `model_load_failure`.
Every other closed failure class, including ordinary `capacity_rejection`, MUST NOT contribute, and one unsuccessful outcome MUST affect at most one breaker.
Node and placement identities SHALL isolate their windows and transitions.
This requirement implements `SPEC.md` §5.10 without adding retry-specific policy.

#### Scenario: Busy Node rejects capacity

- **WHEN** an attempt produces `capacity_rejection`
- **THEN** neither Node nor placement breaker receives a contribution

#### Scenario: One placement reaches its threshold

- **WHEN** one `(node_id, model_id)` receives three eligible load failures in its window
- **THEN** only that placement breaker opens
- **AND** other models on that Node and the same model on other Nodes remain unaffected

### Requirement: Generation-fenced Operator clear

An authenticated clear SHALL atomically increment the breaker generation, record the database clear decision time as a watermark, remove active suppression, and append audit evidence.
A delayed delivery with source `occurred_at` at or before the clear watermark MUST NOT contribute in the new generation.
Repeated clear of an already-cleared generation SHALL be idempotent.
Clear MUST NOT mutate Node lifecycle, Node health, placement lifecycle, or historical evidence.
This requirement implements the Operator clear contract in `SPEC.md` §5.10 and the audit boundary in §10.

#### Scenario: Old failure arrives after clear

- **WHEN** an eligible failure occurred before the clear watermark but is delivered after clear
- **THEN** Orchard retains bounded fenced evidence without counting it in the new generation
- **AND** the breaker remains cleared

#### Scenario: Clear is repeated

- **WHEN** the same effective clear is submitted again
- **THEN** Orchard returns an idempotent no-op result
- **AND** it does not change health, lifecycle, or the current generation again

### Requirement: Actual failures own breaker contributions

Runtime Endpoint transport and status probes SHALL remain health-only and MUST NOT create breaker contributions.
The actual typed dispatch or execution failure outcome SHALL be the sole contribution source and SHALL use its durable failure identity for idempotency.
Health state and breaker state SHALL remain independent scheduler gates.
This requirement preserves the Node health behavior adjacent to `SPEC.md` §5.10 without duplicate counting.

#### Scenario: Transport failure is health-relevant and breaker-eligible

- **WHEN** one actual dispatch failure also causes Node health handling and is delivered repeatedly
- **THEN** health handling may update the Node through its existing authority
- **AND** the actual failure contributes to the Node breaker at most once

#### Scenario: Liveness probe fails

- **WHEN** a transport probe marks or confirms a Node health condition without an actual attempt failure
- **THEN** no breaker contribution is created
