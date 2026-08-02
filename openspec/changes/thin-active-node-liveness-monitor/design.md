# Design: thin active-node liveness monitor

## Decision source

ADR 0015 is accepted. This design records implementation seams for slice A and the
slice B boundary only.

## Slice A architecture

Reuse `Orchard.RuntimeEndpoint.ActivationProbe` (already supervised and
`ControlPlane.authorize_write_path(:node_lifecycle)` gated).

1. **Targets** — `Nodes.activation_probe_runtime_endpoint_targets/0` returns
   trusted certificate-backed targets for states `[:admitted, :active]`, preserving
   per-state authorization metadata (`:activation_probe` vs `:inference_dispatch`).
2. **Success path** — authenticated clients already call
   `Nodes.observe_authenticated_status/5` inside `status/2`. No second write path.
3. **Health gates** — outer seam requires a well-formed health map with boolean
   `ready`; inner gate after row lock accepts non-healthy for `:active` only.
4. **Failure path** — probe passes **raw** failure reasons to
   `Nodes.record_transport_failure/3`. Seam rejections fall through the classifier.
5. **Sweep** — once per `run_once/1` cycle after probes:
   `Nodes.sweep_stale_node_heartbeats/1` demotes aged `:active` heartbeats via the same
   graded path as transport failure. `:admitted` Nodes and sticky `:unhealthy` health are
   left to the observation seam.
6. **Interval contract** — interval must be `<` unreachable and freshness thresholds;
   `assert_interval_contract!/1` is the strict assertion, while GenServer `init` logs and
   clamps so a threshold misconfiguration degrades detection instead of blocking boot.

## SPEC §4.6 push-vs-pull

Implementation and §4.6.1 already pull status probes. Slice A names the divergence
and defers full reconciliation to the §8 `node_heartbeats` work with slice B.
Silent divergence is forbidden; the SPEC note is the explicit deferral.

## Slice B boundary

Do not assert cached candidates, inline-probe removal, `node_heartbeats` schema,
or ranking payloads in slice A tests or OpenSpec scenarios.
