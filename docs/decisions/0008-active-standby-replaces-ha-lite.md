# Active/Standby replaces HA-lite; control-plane status named by surface

Accepted.

"HA-lite" named Orchard's two-controller failover mode by what it is not (full HA), which reads as an apology in operator surfaces and tells an operator nothing about the topology. The mode is renamed **Active/Standby** across product language: SPEC.md, the glossary, Console, CLI, docs, and machine vocabulary (`deployment_mode: "active_standby"`). Industry usage grounds the term (HAProxy Enterprise active/standby clustering, Crunchy PGO's active-standby deployment model; PostgreSQL uses primary/standby at the database layer), and the Orchard glossary already defined Active Leader and Standby Controller.

The status contract formerly named `HALiteStatus` is renamed by what it describes rather than by one of its own enum values: `Orchard.ClusterManagement.ControlPlaneStatus`, object `cluster_management.control_plane_status`, contract version `orchard.cluster_management.control_plane_status.v1`. It reports control-plane leadership state in every deployment mode, including single-controller, and sibling contracts (`node_status`, `action_preview`, `scheduler_explanation`) already follow surface naming. The rename happens in place at v1 while Orchard is pre-release and all consumers are in-repo; after external adoption this would have required a v2.

The `ha_lite` support-bundle scope merges into `control_plane`: its defined evidence set is exactly the ControlPlaneStatus payload, and two overlapping control-plane scopes invited drift. Support bundle v2 is unimplemented, so the merge is vocabulary-only.

The design constraint keeps its force under the new name: at most two Controller instances, exactly one Active Leader, Postgres advisory-lock election, no active/active consensus. "HA-lite" remains only in historical records (archived change packages, investigation notes, milestone notes, and ADR 0005 as amended).

SPEC.md impact: update required in the deployment-mode, controller-leadership, leader-only write, audit, and upgrade sections, plus the Milestone 7 title — same semantics, renamed mode.

Partially superseded 2026-09-02: support bundles were retired before beta.
The `ha_lite` to `control_plane` vocabulary decision remains historical context, while no support-bundle scope vocabulary remains in the live product contract.
