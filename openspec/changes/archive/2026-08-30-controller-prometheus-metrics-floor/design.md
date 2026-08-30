## Context

`SPEC.md` §9.1 names the Controller metric families but leaves their exposure,
ownership, label bounds, cardinality, and failure behavior open. The pilot must
remain useful to a site-local operator without turning metrics into a new
availability dependency or external telemetry path.

## Goals / Non-Goals

**Goals:**

- Expose the exact §9.1 Controller metric floor through one protected route.
- Assign every family to one authoritative domain source.
- Fix bounded label values, five immutable histogram bucket sets, and a concrete
  pilot series budget.
- Count logical-Request, admission, quota, and client-visible outcomes once
  across any execution attempts.
- Isolate reporter, polling, and rendering failures from authoritative work.

**Non-Goals:**

- Add attempt or retry metrics; those remain owned by issue #121.
- Add a collector, metrics backend, tracing, dashboards, or alerts.
- Add or externally enable a Node Agent metrics endpoint.
- Add a metrics-only listener, unauthenticated compatibility route, external
  egress, or HMAC Tenant alias.

## Decisions

### Reuse the existing telemetry path

The implementation will pin `telemetry_metrics_prometheus_core` to 1.2.1 and
record its Apache-2.0 license. Counters and histograms use `telemetry_metrics`
declarations and the core reporter. Snapshot collection uses the existing
`telemetry_poller`. There is no direct reporter mutation alongside Telemetry
events and no second polling framework.

The core library does not need to provide per-series deletion or prospective
reservation. Orchard owns the two required controls:

- `Orchard.Metrics.SeriesAdmission` is a bounded in-memory registry in front of
  counter/histogram emission. It normalizes a label tuple, calculates its full
  family cost, atomically admits the tuple only when the resulting total is at
  most 5,000, and only then emits the Telemetry event to the core reporter.
  SeriesAdmission and the core reporter share one generation: either they restart
  together with empty state, or metrics remain fail-closed with `503` until both
  are cleanly restarted in the same new generation.
- `Orchard.Metrics.GaugeSnapshotStore` accepts complete, normalized poll
  snapshots and atomically replaces each gauge family's map. The `/metrics`
  renderer combines core reporter output with gauge exposition generated from
  the current store. This provides full-set replacement and expiry without
  asking the core reporter to delete label children.
- `Orchard.Metrics.CardinalityLedger` is shared atomically by SeriesAdmission and
  GaugeSnapshotStore. It charges each distinct Tenant, model, and Node identifier
  when first referenced by an exposed tuple. A counter/histogram reference lasts
  for the reporter generation. Gauge replacement releases a reference, but an
  identifier is released only when no counter, histogram, or other gauge family
  in that generation still references it.

Both mechanisms are observational, bounded, supervised outside authoritative
serving/control paths, and unavailable state produces reporting degradation
rather than domain failure.

### Protect the existing Controller endpoint

`GET /metrics` uses the existing Controller HTTP listener and existing
cluster-scoped operator-or-admin service-account bearer boundary. There is no
separate listener. Missing or invalid credentials use `401 invalid_api_key`;
an authenticated principal without cluster-scoped operator or admin authority
uses `403 operator_required`. Authentication and authorization complete before
reporter access. Every response is non-cacheable. An authorized reporter,
admission-registry, snapshot-store, or renderer failure returns a sanitized
`503` without partial exposition.

### Metric-source ownership

| Metric family | Authoritative source and emission boundary |
|---|---|
| `orchard_http_requests_total` | Controller HTTP instrumentation, once after final response status is known. |
| `orchard_http_request_duration_seconds` | Same HTTP owner, from request entry through a final response whose status is known; termination without a final status emits no duration sample. |
| `orchard_inference_requests_total` | Request orchestrator, once at the logical Request's single terminal transition. |
| `orchard_inference_request_duration_seconds` | Request orchestrator, from logical Request start through its single terminal transition, spanning any attempts. |
| `orchard_input_tokens_total` | Accounting/quota owner, once at logical input accounting; attempts never recount input. |
| `orchard_output_tokens_total` | Accounting/quota owner, once at final logical usage reconciliation. |
| `orchard_decode_tokens_per_second` | Runtime event adapter, once per completed valid decode measurement for its producing model and Node. |
| `orchard_scheduler_decisions_total` | Scheduler, once after each completed selection decision. |
| `orchard_scheduler_duration_seconds` | Scheduler around selection computation only, excluding queue wait and dispatch. |
| `orchard_scheduler_queue_depth` | Queue authority full snapshot through `telemetry_poller`. |
| `orchard_scheduler_rejections_total` | Scheduler/queue authority at one definitive rejection, never inferred from HTTP status. |
| `orchard_node_heartbeat_lag_seconds` | Active-node liveness owner from the last accepted heartbeat. |
| `orchard_node_available_memory_bytes` | Node observation owner from a freshness-valid observation. |
| `orchard_node_swap_used_bytes` | Node observation owner from a freshness-valid observation. |
| `orchard_active_requests` | Dispatch-capacity authority full snapshot. |
| `orchard_model_load_duration_seconds` | Ensure-model-loaded owner, once per actual Node/model load outcome. |
| `orchard_model_resident` | Placement/residency authority full snapshot, exactly `0` or `1`. |
| `orchard_worker_crashes_total` | Active Controller heartbeat-observation owner, by accepted positive delta from bounded monotonic Node Agent per-model counters. |
| `orchard_quota_rejections_total` | Quota authority at one definitive rejection. |
| `orchard_api_key_auth_failures_total` | Shared authentication boundary on credential authentication failure, not authorization denial. |
| `orchard_audit_events_total` | Audit writer after the audit outcome is known. |

Counters are not reconstructed from persistence after reporter restart. A lost
sample remains observational loss and never causes an authoritative transition
to replay.

### Worker-crash observation seam

The Node Agent `ModelManager` owns a process-lifetime monotonic crash count per
model identifier. It increments a count only when a monitored worker process
dies unexpectedly. Load-task failures, subscriber exits, and worker deaths
caused by an intentional unload do not increment it. Status exposes at most the
four admitted model entries, each carrying `model_id`, the monotonic count, and
an internal counter version used only for deduplication.

The existing authenticated Runtime Endpoint status observation and heartbeat
path carries this bounded snapshot; no metrics endpoint or new transport is
added. Only a heartbeat observation accepted by the authenticated active
Controller may advance Controller deduplication state. For each Node, model,
and internal version, the first valid observation establishes a baseline and
emits nothing. A later greater count emits exactly the positive delta, an equal
count emits nothing, and a lower count re-establishes the baseline without
emission. A version change also establishes a new baseline without emission.
Malformed entries are ignored. Duplicate entries for the same model are rejected
as a group, so they cannot overcount or advance that model's baseline.

The Prometheus family exports only the stable physical `node` and canonical
`model` (`model_id`) labels. The internal counter version is never exported.
Rejected, unauthenticated, standby-observed, or otherwise unaccepted status and
heartbeat observations do not emit crash deltas and do not advance deduplication
state.

### Bounded labels grounded in current contracts

Identifier ceilings are pilot admission limits, not aliases: at most 4 active
Tenants, 4 active models, 4 managed Nodes, and 8 HTTP endpoint categories may
materialize. `tenant` is the canonical stable raw Tenant identifier, `model`
the canonical model identifier, and `node` the stable physical Node identifier.

| Label | Bounded values or normalization |
|---|---|
| HTTP `endpoint` | `public_api`, `operator_api`, `admin_api`, `console`, `health`, `metrics`, `static`, `unmatched` |
| HTTP `method` | `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `OPTIONS`, `OTHER`; all seven values are budgeted for every endpoint category |
| HTTP `status` | `informational` (100–199), `success` (200–299), `redirect` (300–399), `client_error` (400–499), `server_error` (500–599) |
| Inference `endpoint` | `chat_completions`, `responses` |
| Inference `status` | current terminal Request states `completed`, `failed`, `cancelled`, `timed_out`, `interrupted` |
| Scheduler `result` | `selected`, `no_active_nodes`, `cluster_busy`, `model_busy` |
| Scheduler `tier` | `loaded`, `cached`, `cold`, `none`; `selected` pairs with a serving tier and every non-selected result pairs only with `none` |
| Scheduler rejection `reason` | current stable scheduler/queue outcomes `no_active_nodes`, `cluster_busy`, `model_busy`, `queue_full`, `queue_timeout`, `request_caller_disconnect`, `internal` |
| Quota rejection `reason` | §4/§9 governance dimensions `requests_per_minute`, `input_tokens_per_day`, `output_tokens_per_day`, `tenant_concurrency` |
| Audit `action` | normalized current action domains `tenant`, `api_key`, `service_account`, `role_binding`, `support_bundle`, `node_admission`, `node_lifecycle`, `cluster` |
| Audit `outcome` | `succeeded`, `failed`, `denied` |

Unknown categorical inputs are not turned into arbitrary labels: they are
dropped and reporting is marked degraded. The audit writer maps concrete audit
actions onto the eight bounded action domains before admission; an action
outside those domains emits no audit event instead of materializing an
out-of-vocabulary label. Target addresses, hostnames, Request
IDs, user IDs, claim tokens, raw errors, and runtime-provided arbitrary codes
are never labels. There are no HMAC pilot aliases. Issue #115 must strip tenant
and user dimensions before later external egress.

### Logical-Request semantics

The existing §9.1 inference request, duration, input/output token, admission,
scheduler/queue, quota, authentication, audit, and client-visible status metrics
count at their named logical boundary and never once per execution attempt.
Logical Request duration spans all attempts; input tokens count once; output
tokens use final logical chargeable usage; terminal status counts once. Future
attempt/retry families and their label taxonomy remain owned by issue #121 and
are outside this package.

### Immutable histogram boundaries

The five §9.1 histograms use these finite, strictly increasing boundaries:

| Histogram | Boundaries | Evidence |
|---|---|---|
| HTTP request duration (seconds) | `[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]` | Covers interactive HTTP latency through bounded slow responses without inheriting the 120-second inference deadline. |
| Inference Request duration (seconds) | `[0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120]` | Includes `ORCHARD_REQUEST_TIMEOUT_MS=120000` and useful lower ranges. |
| Decode throughput (tokens/second) | `[1, 2, 5, 10, 20, 40, 80, 120]` | Bounded pilot throughput bands for Apple Silicon MLX measurements. |
| Scheduler duration (seconds) | `[0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.15, 0.25, 0.5, 1]` | Includes the current optional prefix-cache scoring timeout of 150 ms; excludes queue wait. |
| Model-load duration (seconds) | `[0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120]` | Includes `ORCHARD_MODEL_LOAD_TIMEOUT_MS=120000` and worker load timeout 120000 ms. |

Prometheus adds `+Inf`, `_sum`, and `_count`. Bucket lists are compile-time
descriptor constants; deployment configuration cannot change them.

### Gauge reconciliation and staleness

Each successful poll is a complete candidate snapshot. The snapshot store
atomically validates its label values and series cost, then replaces that
family's current map. Queue depth includes zero for each enabled Tenant; active
requests includes zero for each governed Node/model tuple; model residency is
`0` or `1` for each governed placement. Node memory and swap disappear when
their observation fails the existing freshness rule. Heartbeat lag continues
increasing after missed heartbeats and disappears only when the Node leaves the
managed liveness domain.

A failed or over-budget poll retains the prior valid snapshot for exactly two
poll intervals measured from the first failure, then the Orchard-owned store
expires the family and releases its ledger charge. Repeated failures do not
extend that deadline; a valid newer replacement cancels the pending expiry. An entity
absent from a successful authoritative snapshot disappears immediately on
replacement. Out-of-order observations are ignored. Counters and histograms
remain process-lifetime monotonic and reset on reporter restart.

### Concrete 5,000-series pilot worksheet

A counter or gauge costs one active label tuple. A histogram with `B` finite
boundaries and `L` active domain-label tuples costs `(B + 3) * L`.

| Family | Tuple ceiling / calculation | Series |
|---|---:|---:|
| HTTP requests | 8 endpoints × 7 methods × 5 status classes | 280 |
| HTTP duration | 8 endpoints × 5 status classes × (11 + 3) | 560 |
| Inference requests | 2 endpoints × 4 Tenants × 4 models × 5 statuses | 160 |
| Inference duration | 4 Tenants × 4 models × 5 statuses × (10 + 3) | 1,040 |
| Input tokens | 4 Tenants × 4 models | 16 |
| Output tokens | 4 Tenants × 4 models | 16 |
| Decode throughput | 4 models × 4 Nodes × (8 + 3) | 176 |
| Scheduler decisions | 3 selected tiers + 3 non-selected/none pairs | 6 |
| Scheduler duration | unlabelled × (11 + 3) | 14 |
| Queue depth | 4 Tenants | 4 |
| Scheduler rejections | 7 reasons | 7 |
| Heartbeat lag | 4 Nodes | 4 |
| Available memory | 4 Nodes | 4 |
| Swap used | 4 Nodes | 4 |
| Active requests | 4 Nodes × 4 models | 16 |
| Model-load duration | 4 Nodes × 4 models × (10 + 3) | 208 |
| Model resident | 4 Nodes × 4 models | 16 |
| Worker crashes | 4 Nodes × 4 models | 16 |
| Quota rejections | 4 Tenants × 4 reasons | 16 |
| API-key auth failures | unlabelled | 1 |
| Audit events | 8 action domains × 3 outcomes | 24 |
| **Pilot total** |  | **2,588** |
| **Ceiling headroom** | 5,000 − 2,588 | **2,412** |

The implementation SHALL preserve these tuple ceilings. CardinalityLedger also
enforces the shared limits of 4 distinct Tenants, 4 models, and 4 Nodes across
all exposed families. SeriesAdmission counts the full histogram cost before
emitting a first event for a tuple; a previously admitted counter/histogram tuple
and its identifier references remain charged until the coupled reporter and
SeriesAdmission generation restarts. GaugeSnapshotStore counts the candidate
replacement snapshot and updates shared identifier reference counts atomically. A new event tuple
or complete gauge snapshot that would exceed its family ceiling or the 5,000
global ceiling is rejected without aliasing; reporting becomes degraded and
authorized scrapes return `503`. A later valid complete gauge snapshot can
clear gauge degradation. Counter/histogram *rejection* degradation clears only
with a clean reporter/registry restart because missed counter history cannot be
reconstructed safely.

Admission *unavailability* is a separate, recoverable degradation class: a 25
millisecond deadline expiry, registry or ledger process unavailability, and a
contained exception leave ledger and reporter state untouched, so the next
successful admission clears that class while a rejected tuple keeps its
generation degraded.

### Failure isolation

Telemetry handlers execute in the emitter context, so normalization and
SeriesAdmission are bounded, in-memory, exception-contained operations with no
database, network, filesystem, or domain mutation. An emitter waits at most 25
milliseconds for SeriesAdmission; timeout or process exit degrades metrics and
returns control without the default five-second `GenServer.call/3` wait. Poll callbacks are read-only
and bounded; raises, exits, throws, malformed snapshots, and timeouts become
reporting failures only. A gauge authority that this host's role does not
supervise fails only the families it owns, and the metrics subtree is not
supervised at all in peer-grant control mode, where the polled inference
authorities are absent by design. Expiring a retained failed gauge family
retries its ledger release rather than crashing the store, because a store
restart would discard the whole counter/histogram generation. Reporter,
admission-registry, cardinality-ledger, or snapshot-store startup
failure leaves metrics disabled without failing Controller boot. SeriesAdmission
cannot restart into an existing reporter generation: both reset together or
scrapes remain `503`. Repeated reporter failure must not exhaust a parent
supervisor and restart the Controller.

Rendering is bounded and produces either complete valid core-plus-gauge
exposition or sanitized `503`; partial output is forbidden. Metrics failure
never changes HTTP behavior outside `/metrics`, Request state, quota,
scheduling, capacity, dispatch, recovery, or persistence.

## Risks / Trade-offs

- Raw Tenant IDs are sensitive but intentionally useful on the protected
  site-local surface; external egress must strip them.
- The pilot cardinality envelope supports four active Tenants, models, and Nodes;
  widening it requires a reviewed worksheet update.
- A strict ceiling makes scrapes unavailable rather than silently incomplete.
- Process-local counters reset after Controller restart.
