## ADDED Requirements

### Requirement: Controller Owns Worker Crash Recovery Operations

Worker crash-loop inspection, clear, forced reload, and unload/reload SHALL execute through the active Controller and the shared cluster-scoped Operator-or-admin domain authority.
The accepted HTTP surface SHALL be:

- `GET /ops/v1/worker-crash-recovery/placements/:node_id` with exact `model_id` and `version` query parameters;
- `POST /ops/v1/worker-crash-recovery/placements/:node_id/clear`;
- `POST /ops/v1/worker-crash-recovery/placements/:node_id/force-reload`; and
- `POST /ops/v1/worker-crash-recovery/placements/:node_id/unload-reload`.

Each mutation body SHALL carry the exact runtime `model_id` and `version`, and the implementation SHALL reject missing, duplicate, or ambiguous model reference input.
Inspection SHALL return `Cache-Control: no-store` and bounded current projection and reconciliation evidence.
Mutation SHALL require an opaque operation ID, expected recovery generation, non-empty bounded reason, and Controller-authenticated `issued_at` and `expires_at` values no more than 24 hours apart.
A first delivery after expiry or one whose Node-local durable clock evidence cannot prove current validity SHALL fail before mutation.
Expiry of recorded progress SHALL forbid new discretionary stop or load effects while still permitting read-only retrieval and mandatory reconciliation of effects begun while valid; operation-pending suppression SHALL remain until that reconciliation terminalizes.
The Controller SHALL persist command intent before delivery, retain suppression while the command is non-terminal or unknown, and persist the reconciled result and cluster-scoped audit evidence after a matching Node result without claiming a transaction across Postgres and Node-local storage.
A Node result SHALL identify its operation, resulting recovery generation, and state sequence; delayed or regressed results MUST NOT roll back a newer projection or remove newer suppression.
Tenant-direct and public inference credentials MUST fail closed without revealing recovery state.
This requirement clarifies `SPEC.md` §§7.3, 10, and 12.2 under the portable command authority contract.

#### Scenario: Operator inspects an open crash-loop placement

- **WHEN** a cluster-scoped Operator or admin inspects an exact Node, model identifier, and version
- **THEN** the active Controller returns bounded current recovery state with `Cache-Control: no-store`
- **AND** it does not conflate the result with §5.10 breaker state

#### Scenario: Tenant credential attempts recovery

- **WHEN** a tenant-direct or public inference credential requests inspection or mutation
- **THEN** Orchard denies the request without revealing whether the crash-loop breaker exists or is open

#### Scenario: Node acknowledgement is unavailable

- **WHEN** the Controller has durable command intent but cannot reconcile a matching Node result
- **THEN** the operation reports an unknown outcome and suppression remains effective
- **AND** an Operator may retry only with the same operation ID or inspect current reconciliation state

#### Scenario: Recovery result is reconciled

- **WHEN** the Controller obtains the exact Node result for its operation ID, target, action, and expected generation
- **THEN** it persists the resulting projection and cluster-scoped audit evidence
- **AND** no unrelated §5.10, health, lifecycle, quarantine, or capacity state changes

#### Scenario: Delayed result follows a newer projection

- **WHEN** a recovery result carries an older recovery generation or state sequence than the Controller's current projection
- **THEN** the Controller retains the newer projection and suppression state
- **AND** it records the bounded reconciliation outcome without applying the stale state

#### Scenario: Unload/reload targets a busy placement

- **WHEN** unload/reload closes new execution acceptance and the Node reports one or more active Requests on the exact placement
- **THEN** the command fails without recovery-generation advance, expected-stop intent, worker termination, or Request cancellation
- **AND** this recovery surface offers no force-cancellation flag
