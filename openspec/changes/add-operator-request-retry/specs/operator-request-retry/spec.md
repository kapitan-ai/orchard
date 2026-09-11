## ADDED Requirements

### Requirement: Operator Retry Requires an Eligible Retained Source

Orchard SHALL expose operator retry only through `POST /ops/v1/requests/:id/retry` to a server-authenticated cluster-scoped operator or admin API Client. Before a descendant is created, Orchard SHALL require a source Request in `failed`, `cancelled`, `timed_out`, or `interrupted`, with `payload_capture_mode` of `full` and a complete retained canonical source. Orchard SHALL reject a retained canonical source that is missing, malformed, identity-inconsistent, or contains negotiated reasoning evidence that this revision cannot reconstruct, with `retry_source_unavailable`; it MUST NOT create or dispatch a descendant on that path. A noneligible state SHALL return `retry_source_not_eligible` with no descendant.

This requirement implements `SPEC.md` §§7.3.4 and 10.10.

#### Scenario: Tenant-scoped token cannot retry another tenant's Request

- **WHEN** a caller presents a tenant-scoped service-account token to the retry endpoint
- **THEN** Orchard rejects the request as operator authorization failure
- **AND** it does not reveal or mutate the source Request

#### Scenario: Retained negotiated source is unavailable before #327 support

- **WHEN** a terminal full-capture source contains retained negotiated reasoning evidence
- **THEN** Orchard returns `retry_source_unavailable`
- **AND** it creates no descendant and performs no scheduler dispatch

### Requirement: Operator Retry Preserves Atomic Original Lineage

Orchard SHALL atomically cap operator-created descendants at three per original Request. A retry of either an original Request or one of its descendants SHALL set the new descendant's `retry_of_request_id` to the original Request. The descendant SHALL have a fresh Request identity and no idempotency key. Concurrent reservations for one original SHALL not create a fourth descendant.

#### Scenario: Four concurrent retry requests target one original

- **WHEN** four eligible operator retry requests are concurrent for the same original lineage
- **THEN** exactly three descendants are created
- **AND** the remaining request returns `operator_retry_limit_reached`

#### Scenario: A descendant is retried

- **WHEN** an eligible descendant is retried
- **THEN** the new descendant points to the first original Request
- **AND** it does not form a chain through the immediate source

### Requirement: Operator Retry Re-Resolves Current Model Authorization

Before a descendant is created, Orchard SHALL require that the source Request's
Model is currently `active` and that the source Tenant currently holds an
enabled Model access grant. Orchard SHALL fail closed with
`retry_source_not_authorized` and create no descendant when the Model is not
`active`, when the grant is revoked, or when the grant is disabled. Orchard
SHALL resolve the descendant's routing policy, allowed pools, residency
preference, and active-request limit from that current grant, and SHALL NOT
widen a retained queue-wait or cold-start budget beyond the current grant's
budget. This requirement applies `SPEC.md` §5.2 steps 3 and 7 to the operator
retry path.

#### Scenario: Tenant Model access was revoked after the source Request failed

- **WHEN** an operator retries a terminal full-capture source whose Tenant Model
  access has been revoked or disabled
- **THEN** Orchard returns `retry_source_not_authorized`
- **AND** it creates no descendant and performs no scheduler dispatch

#### Scenario: The source Model is no longer active

- **WHEN** an operator retries a terminal full-capture source whose Model is
  `registered`, `deprecated`, or `retired`
- **THEN** Orchard returns `retry_source_not_authorized`
- **AND** it creates no descendant and performs no scheduler dispatch

#### Scenario: The current grant carries a narrower routing policy

- **WHEN** an eligible source is retried after its Tenant Model access is bound
  to a routing policy with a stricter residency preference and smaller
  queue-wait and cold-start budgets than the retained snapshot
- **THEN** the descendant records the current routing policy, its residency
  preference, and the narrower budgets
- **AND** it does not record a budget wider than either the retained snapshot or
  the current grant

### Requirement: Operator Retry Reports an Unrecorded Dispatch Outcome

When a descendant has been created but Orchard cannot record its terminal
outcome, Orchard SHALL retain the descendant row for audit and recovery, log
only bounded non-sensitive identifiers and an outcome label, and return a stable
server error rather than a success response. A dispatch that reaches a durable
terminal outcome SHALL remain a created-descendant success response carrying that
state.

#### Scenario: The terminal row cannot be written after dispatch

- **WHEN** dispatch of a created descendant cannot persist its terminal outcome
- **THEN** Orchard returns a stable `retry_dispatch_incomplete` server error
- **AND** the descendant row is retained for audit and recovery

### Requirement: Operator Retry Cannot Widen Capture

Orchard SHALL resolve the retry capture mode to the narrower of the retained source capture mode and the current source-tenant capture policy, then apply the existing `store` resolution. A retry SHALL preserve legacy canonical serialization and body-hash behavior only while its resolved capture permits full retention; metadata and none modes SHALL retain no canonical request content.

#### Scenario: Tenant policy narrows after a full source was retained

- **WHEN** a full-capture source is retried after its tenant policy becomes metadata or none
- **THEN** the descendant uses metadata or none respectively
- **AND** its canonical request content is absent
