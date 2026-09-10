# controller-prometheus-metrics Specification

## Purpose
Define the protected, bounded Controller Prometheus metrics floor and its failure-isolated ownership contract.
## Requirements
### Requirement: Protected Controller Metrics Endpoint
The Controller SHALL serve `GET /metrics` on its existing HTTP listener and SHALL NOT create a separate metrics listener.
The route SHALL authenticate an enabled service-account-owned API Token and authorize a cluster-scoped `operator` or `admin` RoleBinding with `tenant_scope_id = nil`.
Missing or invalid credentials SHALL return `401 invalid_api_key`, and an authenticated principal without the required cluster role SHALL return `403 operator_required`.
Authentication and authorization SHALL complete before metrics access, and every route response SHALL be non-cacheable.
An authorized scrape SHALL return complete valid Prometheus exposition or a sanitized `503`; it SHALL NOT return partial exposition or internal diagnostics.
This requirement traces to `SPEC.md` §9.1 and ADR 0007.

#### Scenario: Authorized site-local scrape
- **WHEN** an enabled service-account token has a cluster-scoped operator or admin binding
- **THEN** `GET /metrics` uses the Controller's existing HTTP listener
- **AND** the response is non-cacheable
- **AND** no metrics-only listener exists

#### Scenario: Authentication precedes metrics work
- **WHEN** credentials are missing, invalid, tenant-direct, or insufficiently privileged
- **THEN** Orchard returns the ADR 0007 `401` or `403` contract
- **AND** scrape rendering and scrape-time metrics reads are not invoked
- **AND** normal post-decision HTTP and authentication-failure Telemetry events MAY still record the `401` or `403` outcome

#### Scenario: Authorized rendering is unavailable
- **WHEN** an authorized scrape cannot produce complete valid exposition
- **THEN** Orchard returns `503` with no partial exposition
- **AND** the response discloses no exception, label value, backend state, or process identity

### Requirement: Exact Metrics Floor And Ownership
The Controller SHALL declare every family and domain label listed in `SPEC.md` §9.1 without adding a Request ID, user ID, target address, hostname, claim token, raw error, or arbitrary runtime-code label.
Prometheus histogram exposition MAY additionally contain generated `le` labels, `+Inf` buckets, `_sum`, and `_count` series.
Each family SHALL have exactly one authoritative source and emission boundary as defined by the design ownership table.
Counters and histograms SHALL use `telemetry_metrics` declarations with `telemetry_metrics_prometheus_core` 1.2.1 (Apache-2.0), and snapshots SHALL use `telemetry_poller`.
The five §9.1 histograms SHALL use exactly these finite boundaries:

- HTTP request duration seconds: `[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]`;
- inference Request duration seconds: `[0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120]`;
- decode tokens/second: `[1, 2, 5, 10, 20, 40, 80, 120]`;
- scheduler duration seconds: `[0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.15, 0.25, 0.5, 1]`;
- model-load duration seconds: `[0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120]`.

The boundaries SHALL be compile-time descriptor constants and SHALL NOT vary by deployment.

#### Scenario: Descriptor inventory is exact
- **WHEN** metric descriptors are inspected
- **THEN** every §9.1 family has exactly its listed Orchard domain labels
- **AND** histogram-generated Prometheus labels and companion series are distinguished from Orchard domain labels
- **AND** every histogram has exactly its required immutable boundaries

#### Scenario: One owner emits an observation
- **WHEN** an authoritative domain transition or full snapshot produces a metric observation
- **THEN** exactly the owner named in the design emits or polls it
- **AND** metrics are not inferred from logs or persistence replay

### Requirement: Worker Crash Observation And Deduplication
The Node Agent `ModelManager` SHALL maintain a process-lifetime monotonic crash count per model and SHALL increment it only for an unexpected death of a monitored worker process.
Load-task failures, subscriber exits, and worker deaths caused by intentional unload SHALL NOT increment the count.
The existing authenticated Runtime Endpoint status observation and heartbeat payload SHALL carry at most four per-model entries containing the canonical `model_id`, monotonic count, and an internal counter version.
No new endpoint or transport SHALL be added.

Only a heartbeat observation accepted by the authenticated active Controller SHALL advance worker-crash deduplication state.
For each Node, model, and internal counter version, a first valid count SHALL establish a baseline without emission; a greater count SHALL emit exactly its positive delta once; an equal count SHALL emit nothing; and a lower count or version change SHALL establish a new baseline without emission.
Malformed entries SHALL be ignored, and duplicate entries for one model SHALL be rejected as a group without emission or baseline advancement for that model.
Rejected, unauthenticated, standby-observed, or otherwise unaccepted observations SHALL neither emit a delta nor advance deduplication state.
`orchard_worker_crashes_total` SHALL export only `node` and `model`, where `model` is `model_id`; the internal counter version SHALL NOT be exported.

#### Scenario: Baseline, duplicate, delta, and reset
- **WHEN** the active Controller accepts successive authenticated heartbeat observations for one Node and model
- **THEN** the first valid count emits nothing
- **AND** an equal duplicate emits nothing
- **AND** a greater count emits exactly the positive delta once
- **AND** a lower count or changed internal version re-baselines without emission

#### Scenario: Invalid or unaccepted observation
- **WHEN** crash entries are malformed or duplicate, or the heartbeat observation is not accepted by the authenticated active Controller
- **THEN** no worker-crash metric is emitted from those entries
- **AND** the affected deduplication baseline does not advance

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
- **AND** reporting becomes degraded without changing the authoritative audit write result
- **AND** the stored audit row remains available to generic audit readers

### Requirement: Logical Request Accounting Across Attempts
Existing §9.1 logical-Request, admission, scheduler/queue, quota, authentication, audit, token, and client-visible metrics SHALL count at their named logical boundary and SHALL NOT count once per execution attempt.
Logical inference Request duration SHALL span all attempts.
Input tokens SHALL count once, output tokens SHALL use final logical chargeable usage, and client-visible terminal status SHALL count once.
Attempt and retry families SHALL remain distinct from the accepted logical-Request floor and SHALL contribute their separately accepted 229-series runtime delta.

#### Scenario: One logical Request uses multiple attempts
- **WHEN** a logical Request performs more than one execution attempt before terminalizing
- **THEN** §9.1 logical Request and client-visible terminal metrics count the Request once
- **AND** input and final output token accounting are not duplicated
- **AND** attempt and retry families count only their separately defined attempt boundaries

### Requirement: Gauge Snapshot Reconciliation And Staleness
Orchard SHALL own a bounded in-memory Gauge Snapshot Store that receives complete normalized snapshots from `telemetry_poller` and atomically replaces each gauge family's current map.
The renderer SHALL combine core reporter output with current gauge exposition from that store; it SHALL NOT require per-series deletion from `telemetry_metrics_prometheus_core`.
Queue depth SHALL include zero for each enabled Tenant, active requests SHALL include zero for each governed Node/model tuple, and model residency SHALL be exactly `0` or `1` for each governed placement.
Memory and swap series SHALL disappear when their observation fails the existing freshness rule.
Heartbeat lag SHALL continue increasing after missed heartbeats and disappear only when the Node leaves the managed liveness domain.
A failed or over-budget poll MAY retain its last valid complete snapshot for at most two poll intervals and SHALL then expire it rather than write zero.
An entity absent from an authoritative successful snapshot SHALL disappear immediately on replacement, and out-of-order observations SHALL be ignored.
Counters and histograms SHALL reset on reporter restart and SHALL NOT be reconstructed from persistence.

#### Scenario: Poll source remains unavailable
- **WHEN** a gauge source fails for more than two poll intervals
- **THEN** the Orchard-owned snapshot store expires its prior family map
- **AND** no unsupported core-reporter series deletion is required

#### Scenario: Governed tuple becomes idle
- **WHEN** a successful authoritative snapshot still governs an idle Tenant, Node/model tuple, or placement
- **THEN** queue depth or active requests is `0`
- **AND** model residency is its authoritative `0` or `1` value

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

### Requirement: Metrics Failure Isolation
Metrics initialization, event handling, polling, aggregation, admission, snapshot storage, and rendering SHALL be non-authoritative and SHALL NOT prevent Controller boot or alter inference, admission, quota, scheduling, dispatch, recovery, or persistence outcomes.
Telemetry handlers SHALL perform only bounded in-memory normalization and Series Admission and SHALL be exception-contained with no database, network, filesystem, or domain mutation.
Poll callbacks SHALL be read-only and bounded; raises, exits, throws, malformed snapshots, and timeouts SHALL become reporting failures only.
An unavailable gauge authority SHALL fail only the families that authority owns, and a host role that does not supervise the polled authorities SHALL NOT supervise the metrics subtree.
Expiring a retained failed gauge family SHALL retry its ledger release rather than crash the snapshot store and discard the counter/histogram generation.
Reporter, Series Admission, Cardinality Ledger, or Gauge Snapshot Store startup or repeated crash SHALL leave metrics disabled or degraded without exhausting a parent supervisor's restart intensity.
Series Admission SHALL NOT reset independently while the core reporter retains an older generation.
Rendering SHALL be bounded and SHALL return complete core-plus-gauge exposition or sanitized `503`.

#### Scenario: Metrics subsystem cannot start
- **WHEN** the reporter, Series Admission registry, Cardinality Ledger, or Gauge Snapshot Store fails during Controller startup
- **THEN** the Controller still boots and can perform inference, scheduling, and recovery
- **AND** an authorized scrape returns `503`

#### Scenario: Metrics callback fails during authoritative work
- **WHEN** an event handler or poll callback raises, exits, throws, times out, or returns malformed data
- **THEN** the originating domain operation retains its result
- **AND** metrics reporting alone becomes disabled or degraded

### Requirement: Excluded Observability Surfaces
This capability SHALL NOT add another attempt or retry family, a collector, metrics backend, tracing, dashboards, alerts, external egress, a Node Agent metrics endpoint, a separate Controller listener, or an HMAC Tenant alias.

#### Scenario: Worker-crash seam scope is reviewed
- **WHEN** the issue #123 worker-crash implementation is inspected
- **THEN** it adds no endpoint, request-inference instrumentation, worker restart or backoff behavior, tracing, or unrelated Node telemetry
- **AND** it uses only the existing authenticated Runtime Endpoint status and heartbeat path
