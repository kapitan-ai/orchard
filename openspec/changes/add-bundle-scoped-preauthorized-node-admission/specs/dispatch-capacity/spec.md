## MODIFIED Requirements

### Requirement: Atomic Admission Policy Persistence
Every new Node Admission SHALL lock and read the durable authority phase and atomically persist the admission transition, admission decision, cluster audit evidence, and phase-derived dispatch-capacity policy.
The shared Admin API and local CLI manual-admission preview SHALL require a non-empty capacity policy reason, accept an optional non-negative ceiling, and resolve omission to explicit ceiling `1`.
A bundle-scoped preauthorization issuance preview SHALL resolve and bind the same explicit value and reason together with the authority phase and expected revision. Redemption SHALL persist exactly those confirmed values only when the phase, revision, and every other admission predicate remain current; it SHALL NOT silently re-resolve drift.
While the phase is `pre_cutover`, admission SHALL persist `approved_explicit` and SHALL warn that the ceiling is not yet enforcing.
No telemetry value SHALL supply the default or override the explicit manual or preauthorized value.
This requirement traces to `SPEC.md` §4.4, §4.4.1, §4.6.2, §7.3.1, §7.4.1, §10.9, and §11.9.

#### Scenario: Admission omission persists explicit one
- **WHEN** an administrator confirms manual admission with a non-empty capacity policy reason and omits the ceiling
- **THEN** the preview and transaction resolve Controller Dispatch Ceiling `1`
- **AND** the transaction persists `approved_explicit` under `pre_cutover`
- **AND** diagnostics report that the ceiling is not yet enforcing

#### Scenario: Admission accepts explicit zero
- **WHEN** an administrator confirms admission with explicit ceiling `0` and a non-empty reason
- **THEN** Orchard persists explicit ceiling `0`
- **AND** Orchard does not replace it with the default or a telemetry value

#### Scenario: Preauthorized capacity phase drifts
- **WHEN** the durable capacity phase or expected revision differs at Enrollment redemption from the confirmed preauthorization
- **THEN** Orchard does not substitute a new phase-derived state or capacity value
- **AND** independently valid registration may end pending review without a dispatch policy

#### Scenario: Policy failure rolls back admission
- **WHEN** policy or policy-audit persistence fails inside Node Admission
- **THEN** the Node lifecycle, admission candidate, admission decision, grants, policy, preauthorization consumption, and audit writes all roll back

#### Scenario: Admission and phase use a stable lock order
- **WHEN** concurrent admission transactions operate while the authority row is available
- **THEN** each transaction locks the authority row and admission-mode singleton before the Controller-membership lock, eligible Controller rows, Enrollment, preauthorization, Node, and related grant rows
- **AND** each persisted policy state matches the phase locked by that transaction
