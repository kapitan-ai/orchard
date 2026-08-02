# Thin active-node liveness monitor (#122 ordered slices A then B)

## Why

Active-Node liveness is observed today only as a side effect of scheduling a request.
Between requests nothing observes an `:active` Node, so a Node that dies while the
cluster is idle stays `:active`/`:healthy` until the next request pays to discover it.
The M5 closed internal pilot (#118) needs liveness tracked on a bounded interval and
idle Node loss detected without depending on the inline scheduler probe.

ADR 0015 decomposes #122 into ordered slices A then B in one OpenSpec package.
Slice A (#148) is the only pilot-blocking build item. Slice B (#149) decouples the
scheduler from the inline probe and is out of scope for A’s implementation.

## What changes

### Slice A (issue #148) — implement now

- Generalize the supervised, leader-gated `ActivationProbe` to observe `:active` Nodes
  as well as `:admitted` Nodes (no second poller).
- Consume probe outcomes through the authenticated observation path
  (`observe_authenticated_status/5`), advancing heartbeat, health, and aggregate
  capacity evidence in one write.
- Route genuine transport failures through graded demotion via
  `record_transport_failure/3`, including `:authenticated_transport_failed` and
  `:beam_peer_grant_authorization_unavailable`.
- Do not treat seam rejections (`:authenticated_observation_rejected`,
  `:beam_peer_observation_rejected`) as transport demotions.
- Relax authenticated health gates so already-`:active` Nodes record
  `:degraded`/`:unhealthy`; keep `:admitted` → `:active` promotion healthy-gated.
- Add a periodic heartbeat-age sweep over `:active` Nodes so detection is bounded at
  approximately `unreachable_threshold + probe_interval`, leaving `:admitted` Nodes and
  sticky `:unhealthy` health to the observation seam.
- Enforce probe interval strictly below freshness (30s) and unreachable (15s) thresholds,
  clamping with a warning at boot rather than failing Controller startup.
- Name the SPEC §4.6 push-versus-pull divergence and explicitly defer reconciliation,
  coupled to deferred §8 `node_heartbeats` work.
- Update SPEC §4.5/§4.6.1 language so active-Node liveness is maintained by a
  leader-owned background observer independent of request traffic.

### Slice B (issue #149) — tasks only, no A assertions

- Decouple the scheduler from the inline sequential probe.
- Serve candidates from a monitor-refreshed source; remove or bound the inline probe.
- Settle whether durable `node_heartbeats`, a leader-local mirror, or both back that source.
- Carry §8 `node_heartbeats`, §8.5 retention, and §9.1 heartbeat-lag metric as coupled work
  with the §4.6 push-vs-pull reconciliation.

## Out of scope for this package’s Slice A code

- Scheduler MultiNode decoupling (slice B).
- `node_heartbeats` migration, retention job, heartbeat-lag metric.
- Candidate/ranking fact-set redesign.
- Issue #128 scheduler failure reclassification.

## SPEC.md impact

- §4.5 health thresholds: state leader-owned background observation for active Nodes.
- §4.6: explicit deferral of push-vs-pull reconciliation (ADR 0015).
- §4.6.1: background status-probe ingestion for active-Node liveness.
- No §8 schema work in slice A.

## Delivery state

Slice A is the active implementation track for this package. Slice B remains ordered
after A and must not be asserted by slice A tests or deltas.
