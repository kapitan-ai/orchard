## ADDED Requirements

### Requirement: Leader-owned background active-Node liveness observation
The Active Controller SHALL maintain active-Node liveness on a bounded interval through a
single supervised, leader-gated status observer that probes both `:admitted` and `:active`
trusted Runtime Endpoint Nodes.
The observer interval MUST be strictly below `node_unreachable_threshold_ms` and
`node_freshness_threshold_ms`.
Successful authenticated observations MUST advance `last_heartbeat_at`, re-derive health,
and refresh aggregate capacity evidence in one authenticated write path.
A standby Controller MUST write nothing on this path.
This requirement traces to `SPEC.md` §4.5, §4.6.1, and ADR 0015. Scheduler inline probing
and candidate-source decoupling remain slice B (issue #149) and MUST NOT be required here.

#### Scenario: Idle active Node stays schedulable without request traffic
- **WHEN** an `:active` Node is observed only by the leader-owned background status observer
- **AND** the observation is authenticated and within the freshness threshold
- **THEN** `last_heartbeat_at` and aggregate capacity evidence advance together
- **AND** the Node remains eligible in `schedulable_nodes/0` without a request-path probe

#### Scenario: Probe interval stays below thresholds
- **WHEN** the background observer starts or its interval is validated
- **THEN** the configured interval is strictly less than the unreachable threshold
- **AND** the configured interval is strictly less than the freshness threshold

#### Scenario: Standby Controller observes nothing
- **WHEN** a standby Controller would run the background status observer cycle
- **THEN** `authorize_write_path(:node_lifecycle)` refuses the write path
- **AND** no Node health, heartbeat, or capacity evidence is updated

### Requirement: Authenticated observation health for active Nodes
Authenticated Runtime Endpoint status observation SHALL record `:healthy`, `:degraded`, and
`:unhealthy` health for already-`:active` Nodes.
Promotion from `:admitted` to `:active` SHALL remain healthy-gated.
Missing or non-map runtime health, or a health map without a boolean `ready` flag, SHALL
be rejected without demoting the Node as a transport failure.
This requirement traces to `SPEC.md` §4.5, §4.6.1, and ADR 0015.

#### Scenario: Degraded active observation is recorded
- **WHEN** an already-`:active` Node reports ready with a non-empty health code
- **AND** the observation is authenticated and accepted
- **THEN** the Node is persisted with health `:degraded`
- **AND** heartbeat and capacity evidence advance

#### Scenario: Non-healthy admitted Node does not activate
- **WHEN** an `:admitted` Node reports a non-healthy runtime health observation
- **THEN** authenticated observation is rejected
- **AND** the Node remains `:admitted`
- **AND** the rejection is not treated as a transport demotion

### Requirement: Graded demotion for idle Node loss
Genuine transport failures observed by the background status observer SHALL route through
the graded demotion path used by `record_transport_failure/3`, including
`:authenticated_transport_failed` and `:beam_peer_grant_authorization_unavailable`.
Seam rejections `:authenticated_observation_rejected` and `:beam_peer_observation_rejected`
MUST NOT demote health as transport failures.
A leader-gated heartbeat-age sweep SHALL demote Nodes whose last heartbeat is older than
`node_unreachable_threshold_ms`, bounding detection at approximately the unreachable
threshold plus one observer interval.
This requirement traces to `SPEC.md` §4.5 and ADR 0015.

#### Scenario: Fresh transport failure degrades then ages to unreachable
- **WHEN** an `:active` Node fails a status probe while its last heartbeat is still within
  the unreachable threshold
- **THEN** health becomes `:degraded`
- **AND WHEN** the last heartbeat later exceeds the unreachable threshold
- **THEN** a subsequent failure or the heartbeat-age sweep sets health `:unreachable`

#### Scenario: Seam rejection does not demote
- **WHEN** a status probe returns `:authenticated_observation_rejected` or
  `:beam_peer_observation_rejected`
- **THEN** `record_transport_failure/3` is a no-op for demotion
- **AND** Node health is unchanged by that classification

### Requirement: SPEC §4.6 push-versus-pull observation deferral
The OpenSpec change and `SPEC.md` SHALL explicitly name the divergence between the
historical §4.6 Node-push heartbeat wording and the pull-based status-probe ingestion
implemented under §4.6.1 and in product code.
Slice A MUST NOT leave that divergence silent.
Full reconciliation of §4.6 to pull-based observation, or an explicit dual-path contract,
is deferred and coupled to deferred §8 `node_heartbeats` work (slice B / metrics floor).
This requirement traces to `SPEC.md` §4.6, §4.6.1, §8, and ADR 0015.

#### Scenario: Divergence is named with an explicit deferral
- **WHEN** collaborators read `SPEC.md` §4.6 after slice A lands
- **THEN** the push-versus-pull divergence is named
- **AND** reconciliation is explicitly deferred with coupling to §8 `node_heartbeats`
