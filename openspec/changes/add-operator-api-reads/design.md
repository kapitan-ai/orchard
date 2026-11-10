# Design: first Operator API read slice

## Context

The three reads already have Controller-side producers:

- `Orchard.ControlPlane.read_only_status/0` builds `Orchard.ClusterManagement.ControlPlaneStatus`; `OrchardCLI.Commands.Cluster` wraps it in the `cluster_management.cluster_status` object, whose `object` and `contract_version` strings exist today only as private attributes in `orchard_cli`.
- `Orchard.ClusterManagement.Reads.nodes/0` builds the `cluster_management.node_status_list` object from the strict `Reads.node_inventory/0` result and `Orchard.ClusterManagement.StatusBuilder.node_status_maps/1`. The text CLI consumes the same inventory result, keeping raw Node records for its table and deriving summary counts from those records.
- `Orchard.PackagedNodeCommand` builds the inspected Node from `Orchard.API.Admin.NodeAdmissionPresenter.node/1` plus `Orchard.ClusterManagement.MemoryBudgetPresenter.for_node/2`.

`MemoryBudgetPresenter.for_node/2` calls `OrchardConsole.Runtime.cluster_snapshot/1`, which probes every Runtime Endpoint target and, on each successful probe, calls `Orchard.Nodes.observe_status/3`.
That observation can update Node inventory, persist Admission Candidates, and refresh queue-capacity sources, so today's `orchardctl nodes inspect` writes durable state as a side effect.

## Decisions

### One builder per read, not identical bodies

Extract each payload builder into Controller-owned code and call it from the HTTP controller and from the existing CLI path.
ADR 0005 requires the shared structures and lets each surface keep its own presentation; this change chooses the stricter rule that HTTP and CLI JSON share `object`, `contract_version`, and field set.
It does not promise identical values: the CLI evaluates `ControlPlane.read_only_status/0` and the memory-budget probe in its own BEAM, while the HTTP route evaluates them in the serving Controller.
A wrapper that serializes CLI output over HTTP is rejected because ADR 0024 forbids a mechanical HTTP wrapper around command modules.

### Node reads are leader-gated; cluster status is not

Node inventory is Controller-owned durable state, which `SPEC.md` §§2.5 and 11.9 and the `operator-command-authority` requirement place inside the active Controller; §3.3 says a Standby "MAY serve GET /health/live" and returns `503` on write paths.
Node reads therefore call `ControlPlane.authorize_write_path/1` like breaker inspection and worker-recovery reads, returning `503 controller_standby` or `503 controller_leadership_unproven`.
`GET /ops/v1/cluster` reports the serving Controller's own evidence, the same category as `GET /ops/v1/health`, so any Controller serves it.
Current production configuration sets no `:control_plane` role, so it reports `single_controller` without a Controller identity; durable Controller identity belongs to `GET /ops/v1/controllers` in `controller-dispatch-capacity-authority`.

### Admission only, until the nodes family migrates

`SPEC.md` §7.3 applies the §10.11 action-time contract to migrated operation families.
These reads are not in a migrated family, so the existing `Orchard.API.OperatorRequestContext` admission is sufficient.
When the `nodes` CLI family migrates to HTTP, its reads gain §10.11 action-time authorization under that migration's own change.

### Operators see a decision projection

`SPEC.md` §7.3 grants `GET /ops/v1/nodes/:node_id` to cluster `operator`, but the full admission decision carries the deciding admin's free-text reason, service-account actor ID, audit log ID, observed identity, and request-body metadata.
The product owner decided on 2026-11-09 that operators see only the decision name and `decided_at`.
The shared builder takes an explicit projection option; the Operator API uses the operator projection, and the local CLI, which runs under ADR 0006's local admin authority, keeps the full projection.

### Non-observing memory-budget snapshot

Add an option to the runtime snapshot path that skips `observe_status/3` and its queue-capacity refresh, and use it from the shared Node read builder.
Pass `observe?: false` through authenticated BEAM and mTLS compatibility clients as well: they retain the existing locked enrollment, certificate, Node identity, target, health, freshness, and BEAM grant checks, but do not persist observations or clear capacity sources on rejection.
The read-only trust check does not require lifecycle write authorization; the Node routes still enforce their own leader gate.
`orchardctl nodes inspect` also stops refreshing inventory as a side effect; heartbeats and the existing observation paths remain the owners of that state.

### Not found matches existing Node routes

`Orchard.Nodes.fetch_node/1` maps a malformed UUID to `:node_not_found`, and the Admin API admission routes already return `404 node_not_found`.
These routes follow that precedent rather than the `422` used by circuit-breaker target validation.

### Database failure after admission

Node inventory query failures return `503 database_unavailable` in the shared `AdminErrorHelpers` envelope.
Both text and JSON modes of `orchardctl nodes list` report `database_unavailable` with exit status 1 (KAP-208), using the existing human-readable message in text mode and the error code in JSON mode. Healthy inventory output is unchanged.
Later diagnostics and memory-budget reads retain their existing degraded-data behavior on failure.
A database outage during token admission keeps the shared pipeline's current behavior, which affects every `/ops/v1` and `/admin/v1` route and is left to a separate change.

## Risks

- `GET /ops/v1/nodes/:node_id` probes every Runtime Endpoint target, with a bounded per-target timeout of about two seconds, so its latency can reach that bound when a target is unreachable. The probe still uses `OrchardConsole.Runtime` and the `:console` `runtime_impl` key, which run whether or not Console is enabled.
- The Node status map is still being extended by `controller-dispatch-capacity-authority`; the additive-change rule keeps that compatible with this public contract.
- An unbounded Node list is acceptable for the 1–4 Node target; pagination is deferred.

## Follow-ups

- Shared Operator/Admin admission behavior when the database is unavailable.
- Moving Console `NodesLive` reads onto the same builders.
- Moving the runtime snapshot and memory-budget code out of the `OrchardConsole` namespace.
