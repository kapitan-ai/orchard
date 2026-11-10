# Add the first Operator API read slice

## Why

Orchard can run with the Console disabled, but a remote operator or automation client cannot yet read cluster or Node state.
Those reads exist only in Console LiveViews and in `orchardctl cluster status` and `orchardctl nodes list|inspect`, which open the Controller Repo on the controller host.

`SPEC.md` §7.3.1 already lists `GET /ops/v1/cluster`, `GET /ops/v1/nodes`, and `GET /ops/v1/nodes/:node_id`.
ADR 0005 already requires the future Operator API to consume the shared cluster-management structures that the CLI JSON output uses.
ADR 0024 and `SPEC.md` §11.9 make Controller-owned operations the authority that portable clients call.

The accepted product direction for headless operation is runtime-disabled Console with the Developer Portal retained, and Operator API reads started in parallel with the credential family in the `cross-surface-authorization-contract` change.

## What Changes

- Add `GET /ops/v1/cluster`, returning the `cluster_management.cluster_status` object (`orchard.cluster_management.cluster_status.v1`) that `orchardctl cluster status --json` returns, evaluated by the serving Controller. Any Controller serves it.
- Add `GET /ops/v1/nodes` and `GET /ops/v1/nodes/:node_id`, returning the `cluster_management.node_status_list` and `node` objects that `orchardctl nodes list|inspect --json` return. Only the active Controller serves them (`503 controller_standby` / `controller_leadership_unproven`), and `404 node_not_found` covers unknown or malformed IDs.
- Admit these routes through the existing Operator API boundary: an enabled API Client with a cluster-scoped `operator` or `admin` RoleBinding, `no-store` caching, `401 invalid_api_key`, and `403 operator_required`.
- Move the payload builders into Controller-owned code that both the HTTP routes and the existing CLI commands call, so the shapes cannot drift; values may differ by evaluating process and time.
- Show operators only the admission decision name and `decided_at`; the local CLI keeps the full admission provenance.
- Read the Node memory budget through a Runtime Endpoint snapshot that does not observe Node status, so these reads, and `orchardctl nodes inspect`, no longer update inventory, Admission Candidates, or queue capacity.
- Return `503 database_unavailable` for Node inventory query failures after admission.
- Make `orchardctl nodes list` report `database_unavailable` with exit status 1 in both text and JSON modes when the inventory query fails, instead of reporting an empty inventory (KAP-208). Text mode uses the existing human-readable database-unavailable message; healthy inventory output is unchanged.

## Out Of Scope

- `GET /ops/v1/controllers`, which the open `controller-dispatch-capacity-authority` change owns.
- `GET /ops/v1/requests/:request_id`, whose response shape and capture-mode redaction need a separate decision.
- Node lifecycle actions, dispatch-capacity policy, diagnostics, and every Admin API route.
- Migrating any `orchardctl` command family to HTTP; the local CLI remains the migration baseline under `SPEC.md` §11.9.
- Pagination, filtering, or Console behavior changes.
- Database-outage handling inside the shared Operator/Admin token admission.

## SPEC.md Impact

This change implements endpoints `SPEC.md` §7.3.1 already lists, under the §7.3 admission boundary, the §§2.5, 3.3, and 11.9 active-Controller rule, and ADR 0005's shared-structure rule.
It defines their response objects by reference to the existing shared cluster-management contracts and does not modify `SPEC.md`.
The operator projection of admission provenance is a product-owner decision recorded on 2026-11-09 within the §7.3 grant of Node reads to cluster `operator`.

## Impact

- `Orchard.API.Router` and new `Orchard.API.Ops` read controllers.
- A Controller-owned read module used by `Orchard.PackagedNodeCommand` and `OrchardCLI.Commands.Cluster`.
- Focused authorization, shape-parity, not-found, and no-side-effect tests.
