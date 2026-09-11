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

### Requirement: Operator Retry Cannot Widen Capture

Orchard SHALL resolve the retry capture mode to the narrower of the retained source capture mode and the current source-tenant capture policy, then apply the existing `store` resolution. A retry SHALL preserve legacy canonical serialization and body-hash behavior only while its resolved capture permits full retention; metadata and none modes SHALL retain no canonical request content.

#### Scenario: Tenant policy narrows after a full source was retained

- **WHEN** a full-capture source is retried after its tenant policy becomes metadata or none
- **THEN** the descendant uses metadata or none respectively
- **AND** its canonical request content is absent
