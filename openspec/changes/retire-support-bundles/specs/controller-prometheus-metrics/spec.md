## MODIFIED Requirements

### Requirement: Bounded Label Contract

Categorical inputs SHALL normalize only to the bounded values in the design.
HTTP status SHALL normalize to `informational`, `success`, `redirect`, `client_error`, or `server_error`, rather than materializing individual status codes.
Current terminal Request status SHALL normalize only to `completed`, `failed`, `cancelled`, `timed_out`, or `interrupted`.
Scheduler result, tier, rejection reason, quota reason, audit action domain, and audit outcome SHALL use only the design's listed values and pair constraints.
Audit action domain SHALL normalize only to `tenant`, `api_key`, `service_account`, `role_binding`, `routing_policy`, `tenant_model_access`, `node_admission`, `node_lifecycle`, `circuit_breaker`, `cluster`, or `portal_user`.
Audit outcome SHALL normalize only to `succeeded`, `failed`, or `denied`.
Unknown categorical inputs SHALL be dropped and reporting marked degraded.

The pilot SHALL admit at most 4 distinct Tenant identifiers, 4 distinct model identifiers, 4 distinct Node identifiers, and 8 HTTP endpoint categories across all exposed families in one reporter generation.
A shared atomic Cardinality Ledger SHALL charge an identifier when its first exposed tuple is admitted.
Counter/histogram references SHALL remain charged for the generation; gauge replacement SHALL release a reference only when no counter, histogram, or other gauge family still references that identifier.
The `tenant` label SHALL be the canonical stable raw Tenant identifier, `model` the canonical model identifier, and `node` the stable physical Node identifier.
The protected site-local endpoint SHALL NOT hash, alias, truncate, or substitute Tenant identifiers.
No HMAC pilot alias SHALL exist.
Any later external metrics egress SHALL remove tenant and user dimensions before transmission under issue #115; external egress is not implemented by this change.

#### Scenario: Protected Tenant dimension

- **WHEN** an authorized site-local scrape contains a family with `tenant`
- **THEN** the value is the canonical stable raw Tenant identifier
- **AND** no user dimension or HMAC alias is present

#### Scenario: Raw HTTP codes do not multiply series

- **WHEN** HTTP responses use different concrete codes in the same status class
- **THEN** they share the corresponding bounded status label
- **AND** no `100` through `599` status-value Cartesian product is materialized

#### Scenario: Invalid categorical value

- **WHEN** a source supplies a value outside its bounded normalization
- **THEN** Orchard does not materialize that label tuple
- **AND** reporting becomes degraded without changing the source operation

#### Scenario: Portal lifecycle actions share one bounded domain

- **WHEN** a committed audit action begins with `portal_user.`
- **THEN** its audit metric action label SHALL normalize to `portal_user`
- **AND** the concrete suffix, Portal User ID, Tenant ID, email, and target ID SHALL NOT become metric labels

#### Scenario: Retired support-bundle action is not normalized

- **WHEN** a historical or unknown action begins with `support_bundle.`
- **THEN** metrics normalization rejects the action as outside the live bounded domain
- **AND** the stored audit row remains available to generic audit readers

### Requirement: Active Series Ceiling

The Controller SHALL materialize at most 5,000 active Prometheus series.
A counter or gauge SHALL cost one series for each active label tuple.
A histogram with `B` finite boundaries and `L` active domain-label tuples SHALL cost `(B + 3) * L`.

The pilot worksheet SHALL be exactly:

- HTTP requests 280; HTTP duration 560;
- inference requests 160; inference duration 1,040;
- input tokens 16; output tokens 16; decode throughput 176;
- scheduler decisions 6; scheduler duration 14; queue depth 4; scheduler rejections 7;
- heartbeat lag 4; available memory 4; swap used 4; active requests 16;
- model-load duration 208; model resident 16; worker crashes 16;
- quota rejections 16; API-key authentication failures 1; audit events 33.

The accepted Controller metrics floor SHALL be 2,597, leaving 2,403 series before separately accepted attempt and retry families.
The implemented attempt and retry families SHALL add 229 series, so the runtime worksheet SHALL total 2,826 and retain 2,174 series of headroom below 5,000.

Orchard SHALL own a bounded in-memory Series Admission registry in front of counter and histogram emission and a shared atomic Cardinality Ledger across event and gauge paths.
Series Admission SHALL normalize a new label tuple, calculate the tuple's complete family cost, and atomically admit it only within the identifier, family worksheet, and global ceilings before emitting to the core reporter.
Series Admission and the core reporter SHALL share one generation: they SHALL restart together with empty state, or metrics SHALL remain fail-closed until both cleanly start in the same new generation.
Previously admitted counter/histogram tuples and their identifier references SHALL remain charged for that generation.
The Gauge Snapshot Store SHALL validate the complete candidate replacement against its family and global ceilings before replacement.
No unsupported core pre-materialization API is required.

A rejected tuple or snapshot SHALL NOT be aliased or coalesced.
It SHALL mark reporting degraded, emit only a bounded rate-limited structured log, and make authorized scrapes return `503`.
A valid later gauge snapshot MAY clear gauge degradation; missed counter/histogram history SHALL NOT be reconstructed.
Admission unavailability, meaning a bounded deadline expiry, an unavailable admission or ledger process, or a contained exception, SHALL be tracked as a distinct recoverable degradation class that a later successful admission MAY clear, while a rejected counter/histogram tuple SHALL keep its generation degraded.

#### Scenario: Prospective counter tuple exceeds a ceiling

- **WHEN** Orchard's Series Admission registry determines that a normalized tuple would exceed its family or global ceiling
- **THEN** it does not emit the first event for that tuple to the core reporter
- **AND** authoritative Controller work continues
- **AND** authorized scrapes return sanitized `503`

#### Scenario: Histogram budget is calculated

- **WHEN** a histogram has `B` finite boundaries and `L` active domain-label tuples
- **THEN** its worksheet subtotal is exactly `(B + 3) * L`

#### Scenario: Post-retirement audit domains remain within the runtime ceiling

- **WHEN** the eleven bounded audit domains combine with the three bounded outcomes
- **THEN** the audit-events family ceiling SHALL be exactly 33 series
- **AND** the accepted Controller metrics floor SHALL be 2,597 series
- **AND** the runtime worksheet SHALL be 2,826 after the 229-series attempt and retry delta
- **AND** the 5,000-series ceiling SHALL retain 2,174 series of headroom
