# Active-node liveness lands as a thin background monitor before scheduler decoupling

## Status

Accepted.

Owner decision recorded 2026-08-02. Implementation proceeds through a single
OpenSpec change package with ordered slices; this record fixes the decomposition
and the pilot-blocking boundary ahead of that authoring.

## Context

Active-node liveness is observed today only as a side effect of scheduling a
request. `Orchard.Scheduler.MultiNode` probes every configured target
sequentially on the request path, and the observation that probe persists is what
refreshes `last_heartbeat_at` so the freshness gate in `Nodes.schedulable_nodes/0`
passes. Between requests nothing observes an `:active` Node, so a Node that dies
while the cluster is idle stays `:active`/`:healthy` in inventory until the next
request pays to discover it. The only recurring prober, `ActivationProbe`, targets
`:admitted` Nodes and discards its return values; it persists anything only as a
client-internal side effect on authenticated transports, and only for healthy
responses.

The M5 closed internal pilot (issue #118) needs this gap closed: its readiness gate
requires that liveness be tracked on a bounded interval and that the loss of either
Node be detected without depending on an inline probe on the request path. Issue
#122 proposed both a background monitor and taking the scheduler off the inline
probe. The question this record settles is how to decompose #122 so the pilot is
unblocked as fast as is defensible, without over-building.

An implementation proposal asserted a hard constraint: the background-observation
slice must first create the SPEC §8 `node_heartbeats` table and persist the full
candidate-construction fact set (availability, loaded-model status, active-request
counts, maximum concurrency, placement capacity, prefix-cache status, memory
budget, and an acquirability fact), because otherwise the scheduler-decoupling
slice would require a second migration. That constraint was tested against the code,
`SPEC.md`, ADR 0001, and ADR 0013 through independent review, and it does not hold.

This decision is hard to reverse because it fixes where the liveness authority for
scheduling eligibility lives and what the pilot may claim. It is surprising because
the intuitive "persist everything the scheduler uses" instinct is both unnecessary
and slower here. It resolves a real trade-off between front-loading a durable
contract now and deferring it until its only consumer exists.

## Decision

Decompose #122 into two ordered slices, A then B, in one OpenSpec package. Slice A
is tracked by issue #148 and slice B by issue #149.

Slice A is the only pilot-blocking build item and is deliberately thin. It
generalizes the existing supervised, leader-authorized `ActivationProbe` to observe
`:active` Nodes in addition to `:admitted` Nodes, on a bounded interval strictly
below the unreachable threshold.

Slice A consumes probe outcomes through the authenticated observation path
(`observe_authenticated_status/5`), not the plain `observe_status/4` upsert. This
distinction is load bearing. Plain `observe_status/4` writes only the Node row;
aggregate capacity evidence is persisted only by the authenticated path. The
dispatch authority check requires durable capacity evidence to be at least as
current as `last_heartbeat_at`, so a monitor that advanced the heartbeat without
co-writing evidence would make evidence non-current and force dispatch closed with
unavailable facts. A successful monitor observation therefore advances
`last_heartbeat_at`, re-derives health, and refreshes aggregate capacity evidence in
one authenticated write, keeping heartbeat freshness and evidence currency in
lockstep.

Slice A carries one real code change beyond generalizing the prober. The
authenticated seam today double-gates on health and rejects any non-healthy
observation, so a `:degraded` or `:unhealthy` already-`:active` Node is dropped and
ages out of `schedulable_nodes/0` even under traffic. Slice A must relax those gates
to accept and record a non-healthy observation from an already-`:active` Node, while
keeping the `:admitted` to `:active` promotion healthy-gated so a non-healthy
`:admitted` Node still cannot activate.

Failure handling must separate two cases that look alike. A genuine transport
failure, where the Node did not respond, routes through the graded demotion path:
`:degraded`, then `:unreachable` once the last heartbeat exceeds the 15-second
threshold. The demotion classifier must also recognize the authenticated and BEAM
transport failures it does not classify today (`:authenticated_transport_failed`,
`:beam_peer_grant_authorization_unavailable`). An observation the seam rejected
because the Node was non-healthy (`:authenticated_observation_rejected`,
`:beam_peer_observation_rejected`) is not a transport failure, the Node responded,
and it must be handled by the gate relaxation above rather than swept into demotion.
A periodic heartbeat-age sweep bounds detection at approximately the unreachable
threshold plus one sweep interval, roughly 20 seconds at the 15-second threshold
and the existing 5-second probe interval.

Slice A leaves the scheduler's control flow, candidate selection, ranking, and the
inline probe path in place. It does not, however, leave the inline probe's observed
behavior identical: the health gate slice A relaxes lives in the shared
`observe_authenticated_status/5` seam, which the inline probe also drives through
its transport client's status call, so the relaxation applies to the background
monitor and the inline probe alike. That is intended and safe. Its only effect is
that a non-healthy observation from an already-`:active` Node is recorded rather
than dropped, and it does not change the `:admitted` to `:active` promotion, which
stays healthy-gated.

Slice A adds no migration. The persistence seam and the schema columns it needs
already exist. It does not create `node_heartbeats`, does not implement the §8.5
retention job, and does not implement the §9.1 heartbeat-lag metric; those are real
SPEC obligations but serve operator forensics and the metrics floor, not the two
gate properties, and #118 already spun the metrics floor out of the pilot gate.
They land with slice B or the metrics-floor work.

Slice A must name the `SPEC.md` §4.6 push-versus-pull divergence in its OpenSpec
delta. §4.6 says the Node Agent sends heartbeats every 2 seconds, while §4.6.1
already blesses status-probe ingestion as the durable seam, so SPEC is internally
split and the evidence favors reconciling to pull. The implementation, inline and
background alike, pulls status probes. Slice A extends that existing divergence
rather than creating it, and the delta must either reconcile SPEC to pull-based
observation or explicitly defer the reconciliation. The §8 `node_heartbeats` columns
mirror the §4.6 push payload, so the deferred §8 work and this reconciliation are
coupled and should be resolved together. Silent divergence is not acceptable.

Slice B decouples the scheduler from the inline probe: it serves candidates from a
monitor-refreshed source and removes or bounds the inline sequential probe. Whether
the durable `node_heartbeats` history, a leader-local in-memory mirror of the
persisted observation, or both back that source is slice B's design question, to be
settled when B's snapshot-freshness and dispatch-time revalidation contracts are
designed. Enriching what an observation payload carries is a payload-contract change
absorbed by the spec-fixed `payload jsonb` column, not a schema migration. The full
candidate fact set is slice B's deliverable, defined against a real consumer.

The pilot (#118) is blocked by slice A only, not by whole-#122. Retargeting the
blocker to slice A matches the readiness-gate text, which requires detection without
the inline probe rather than scheduling-path purity. The pilot's official claim is
2-node liveness and observability stability plus failure-classification
correctness. Scheduler latency is exploratory only and is not an official baseline,
because the inline probe remains on the request path through the frozen window;
multi-node placement-optimization behavior is deferred to slice B. The pilot
findings must disclose the inline-probe latency overhead and the window in which a
`:degraded` Node remains schedulable, the unreachable threshold plus one sweep
interval and so roughly 20 seconds at the default 5-second interval, as known,
bounded limitations of the frozen artifact.

Issue #128 (scheduler failure reclassification) is decoupled from slice A and from
the pilot build. Acquirability is a time-sensitive property derived Controller-side
from catalog, artifact, policy, and live capacity state; it is not an observation
fact, does not belong in a heartbeat row, and must not be persisted as a boolean or
computed by a second eligibility formula. #128 ships on its own track, ideally
before the pilot midpoint because a misclassified `model_busy` is the defect the
client team is most likely to hit.

Pre-loading the pinned catalog on both Nodes before the window opens reduces, but
does not eliminate, #128 contamination of the failure denominator. It removes the
specific cold-path misclassification, catalog-active but not loaded returning
`model_busy`, so the `model_busy` that remains is genuine capacity exhaustion, which
is classified correctly before #128 lands. Pre-loading is a reduction, not a
guarantee: residency can be lost mid-window to a worker crash, a Node restart, or a
memory-pressure unload, so the window must assert model residency periodically and
disclose any eviction as a known limitation. Two residual gaps must be disclosed in
the findings. Pre-loading means the pilot never exercises the cold-load path, so
cold-start behavior is out of the pilot evidence base. And #128 is broader than this
one path, since it also covers queue admission that ignores canonical policy and the
absence of a recorded scheduler explanation, so some failures in the window will
still lack explanations. Window-open is not gated on #128 code landing; the
contamination it addresses is bounded operationally instead.

## Rejected alternatives

Persisting the full candidate-construction fact set in slice A is rejected. It is
not required by ADR 0001, which constrains where authority lives (durable in
Postgres, not in BEAM signals) rather than mandating that every ranking input be
schema-modeled before anything consumes it; the current inline path already
persists durable authority and uses the live observation for ranking annotations,
and a thin monitor through the same seam cannot be less compliant than that
accepted pattern. It is not required by ADR 0013, which demotes the richest parts of
the proposed payload (placement capacity, active counts) from authority to evidence
and keeps capacity authority Controller-owned. Its second-migration cost argument is
wrong: thin A requires zero migrations, so the comparison is one migration total
either way, taken in A or in B. And it finalizes a payload contract whose only
consumer, slice B's cached candidate construction, is not yet designed, which
guarantees rather than avoids a later review pass.

Landing all of #122 before the pilot is rejected: it holds a stability finding
hostage to a latency optimization that is irrelevant at two Nodes.

Adding a second background poller instead of generalizing `ActivationProbe` is
rejected: the existing prober is already supervised and leader-gated via
`ControlPlane.authorize_write_path(:node_lifecycle)`, and reuse inherits
single-writer semantics for free.

Coupling #128 to slice A or to window-open is rejected: acquirability is not a
heartbeat fact, #128 is not in the #118 gate, and #128's real scope is a
multi-module admission-policy and reason-code change that would put a scheduler and
orchestrator redesign on the pilot's critical path for no gate benefit.

Framing the accompanying ADR as a reconciliation of ADR 0001 and ADR 0013 is
rejected: the two do not conflict. Both point the same direction — durable
observations in Postgres as scheduler and operator input, capacity authority
Controller-owned and fail-closed on missing facts — and there is nothing to
reconcile.

## Consequences

The pilot build shrinks to one GenServer generalization, result consumption
through the authenticated seam, the health-gate relaxation for `:active` Nodes, an
interval-versus-threshold invariant, and a small OpenSpec delta plus this record.
Every gate property the stability finding must prove maps to a test: an idle cluster
stays schedulable with zero traffic, a Node killed while idle is demoted within the
asserted bound, a recovered Node returns to `:healthy`, a standby Controller writes
nothing, the interval stays below the freshness and unreachable thresholds, a
`:degraded` `:active` Node is recorded rather than dropped while a non-healthy
`:admitted` Node still cannot activate, and a seam rejection is not treated as a
transport demotion.

Double probing exists during slice A: the inline probe and the background monitor
both write observations. Existing staleness and concurrent-insert guards make this
safe, and the extra RPC load at two Nodes is negligible.

The SPEC §4.6 push-versus-pull divergence becomes an explicit, named obligation
rather than an undocumented drift, carried by slice B or a dedicated reconciliation.

The `node_heartbeats` table, its §8.5 retention, and the §9.1 heartbeat-lag metric
remain unimplemented after slice A and are tracked with slice B and the metrics
floor. Heartbeat lag stays computable from `nodes.last_heartbeat_at` once the metric
lands.

## SPEC.md impact

Confirm or update the Node liveness and heartbeat observation language in `SPEC.md`
§4.2 (Node lifecycle states), §4.5 (Node health model), and §4.6 (Heartbeat
payload) to state that active-node liveness is maintained by a leader-owned
background observer independent of request traffic.
Name and resolve the §4.6 push-versus-pull heartbeat divergence, either by
reconciling SPEC to pull-based observation or by recording an explicit deferral.
The §8 `node_heartbeats` schema, §8.5 retention, and §9.1 heartbeat-lag metric are
unchanged and remain future obligations tracked with slice B and the metrics floor.
