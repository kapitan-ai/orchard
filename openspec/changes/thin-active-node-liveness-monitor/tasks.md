## 1. Contract and OpenSpec

- [x] 1.1 Record ADR 0015 as the accepted decomposition (merged via #150)
- [x] 1.2 Author this OpenSpec package with ordered slices A (#148) and B (#149)
- [x] 1.3 Name SPEC §4.6 push-vs-pull divergence and record explicit deferral
- [x] 1.4 Update SPEC §4.5 / §4.6.1 for leader-owned background active-Node observation
- [x] 1.5 Validate package: `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate thin-active-node-liveness-monitor --type change --strict --no-interactive`

## 2. Slice A implementation

- [x] 2.1 Expand activation probe targets to `[:admitted, :active]`
- [x] 2.2 Relax authenticated health gates for already-`:active` Nodes; keep admission promotion healthy-gated
- [x] 2.3 Classify `:authenticated_transport_failed` and `:beam_peer_grant_authorization_unavailable`
- [x] 2.4 Add `Nodes.sweep_stale_node_heartbeats/1`
- [x] 2.5 Wire `ActivationProbe` to record raw transport failures and run the sweep each cycle
- [x] 2.6 Enforce probe interval strictly below freshness and unreachable thresholds
      (strict assertion plus boot-safe clamp)
- [x] 2.7 Acceptance and regression tests (see tasks 3.x)

## 3. Slice A tests

- [x] 3.1 New transport-failure reasons demote; seam rejections do not
- [x] 3.2 Sweep demotes stale heartbeats; race with fresher heartbeat is noop; standby writes nothing
- [x] 3.3 Probe interval contract tests
- [x] 3.4 ActivationProbe records failures and invokes sweep (stub client)
- [x] 3.5 Authenticated degraded/unhealthy active observations recorded; non-healthy admitted not promoted (integration where fixtures allow)

## 4. Slice B (deferred — issue #149)

- [ ] 4.1 Design monitor-refreshed candidate source and snapshot-freshness contracts
- [ ] 4.2 Remove or bound MultiNode inline sequential probe
- [ ] 4.3 Decide durable `node_heartbeats` vs leader-local mirror vs both
- [ ] 4.4 Implement §8 `node_heartbeats`, §8.5 retention, §9.1 heartbeat-lag metric with §4.6 reconciliation
- [ ] 4.5 Slice B tests against a real scheduler consumer

## 5. Quality gate

- [ ] 5.1 `mise exec -- mix format`
- [ ] 5.2 `mise exec -- mix compile --warnings-as-errors`
- [ ] 5.3 `mise exec -- mix credo --strict`
- [ ] 5.4 `mise exec -- mix dialyzer` (if available for changed surface)
- [ ] 5.5 Focused then full relevant tests + coverage for changed modules
- [ ] 5.6 no-mistakes gate and qualified PR for #148
