# Shared cluster-management contract

Accepted.

Cluster-management status categories, scheduler reason codes, action-preview codes, scheduler-explanation shapes, and HA-lite read-only status belong in `orchard_shared`.
Controller code translates persisted inventory, admission candidates, runtime observations, scheduler evaluations, and control-plane state into those shared structures.
Admin API, future Operator API, CLI JSON, Console assigns, support bundles, and tests consume the shared structures rather than inventing local reason vocabularies.
This decision does not require the full Operator API route set, Console pending-admission workflow, or support bundle v2 archive format to land in the same slice.
It does allow scheduler code to attach additive `scheduler_explanation` metadata to persisted scheduler decisions so support and future Operator API surfaces have a real producer.

This keeps machine-readable cluster-management semantics stable across human and programmatic surfaces while allowing each surface to keep its own presentation.
Human-readable messages may change, but fixed reason codes and documented status categories are the client contract.

The trade-off is an extra controller builder layer between persistence/runtime state and rendered JSON.
That layer is deliberate because `orchard_shared` must not depend on Ecto schemas, Phoenix presenters, Console LiveViews, CLI commands, or support-bundle writers.

SPEC.md impact: no change required.

Amended 2026-07-05: the HA-lite read-only status contract described above is renamed to `ControlPlaneStatus` (`cluster_management.control_plane_status`), and the Active/Standby term replaces HA-lite; see ADR 0008.
