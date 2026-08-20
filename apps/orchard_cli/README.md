# orchard_cli

`orchard_cli` builds the `orchardctl` operator/admin command surface used by
source-dev workflows and packaged installs.

This README is orientation only. Normative CLI requirements live in
[`../../SPEC.md`](../../SPEC.md); repo/runtime boundaries are mapped in
[`../../docs/architecture.md`](../../docs/architecture.md).

## Owns

- Operator commands for environment, transport, migrations, status, start/stop,
  upgrades, tenants, API keys, API Client bulk provisioning, nodes, and models.
- Read-only cluster status through `cluster status`, with a `--json` mode that
  emits the shared `ControlPlaneStatus` payload plus an Active/Standby-focused summary of
  deployment mode, controller role, and advisory-lock status.
- First cluster-admin provisioning through `cluster init`, minting the bootstrap
  admin API Client credential with required One-time Secret Output (`--output`),
  `--json`, `--client-name`, and `--force-new-admin`/`--yes` recovery minting.
- SPEC-required future command paths that return explicit deferred status until
  their milestones land: `node join`.
- Node-admission-review commands (`nodes inspect`, `nodes pending`,
  `nodes admit`, `nodes reject`) with stable JSON and human output, `--dry-run`
  previews, and `--yes` execution gating. `nodes reject` requires a nonblank
  `--reason`. `nodes admit` requires a nonblank `--capacity-policy-reason` and
  accepts an optional non-negative `--controller-dispatch-ceiling` that defaults
  to `1` when omitted, persisting the Controller Dispatch Ceiling atomically
  with admission; that write holds the Node's acceptance gate, so it fails fast
  with `dispatch_capacity_acceptance_gate_busy` when a dispatch to the same Node
  is mid-handoff, or with `dispatch_capacity_authority_unavailable` when the
  Controller's allocation authority is not running, and the command should be
  retried in both cases. `nodes inspect` renders a
  counterfactual dispatch-capacity block that reports what F11 enforcement would
  decide without changing dispatch behavior, including the capacity management
  class, authority decision, Placement Capacity, and decision-specific available
  slots; its `consumers_ready` field stays `false` because the block is
  observability, not the Controller capability declaration published on the
  membership heartbeat.
- Node lifecycle commands (`nodes cordon`, `nodes uncordon`, `nodes drain`,
  `nodes cancel-drain`, `nodes maintenance`, `nodes resume`,
  `nodes decommission`) on the shared Action Preview contract, with
  `--dry-run`/`--json` previews and `--yes`, `--acknowledge`, and
  `--typed-node-id` execution gating. `nodes cancel-drain` stops an in-progress
  drain and leaves the node `cordoned`; it is allowed only from `draining` and
  otherwise reports a `drain_not_running` blocker. `nodes maintenance` previews
  only; its `draining -> maintenance` execution stays blocked until drain
  completion can be verified.
- Request diagnostics through `requests inspect <request-id>`, including stable
  human and JSON scheduler-explanation output from the shared Operator API
  presenter and scheduler explanation contract.
- Local diagnostic support bundle creation via `support bundle create`.
- Bulk API Client provisioning through `api-clients bulk-provision`, including
  Dry Run, all-or-nothing Apply, output preflight, Key Rotation, and One-time
  Secret Output CSV delivery.
- CLI helpers that wrap release scripts and packaged service management.
- Human-readable operator output and command validation.

## Current command status

The deferred path above is advertised by `orchardctl`, exits non-zero when
run, and prints command-specific usage, `SPEC.md` traceability, and the current
supported source-dev or packaged workflow. `--help` for the same path is
side-effect free.

`orchardctl cluster init` mints the first cluster-admin API Client credential as
a local, one-shot, audited controller-host operation behind the leader-only
write gate. It requires a `--output` path for One-time Secret Output, and only
the token hash and prefix persist. Confirmed success leaves the chosen
destination as the only intentional plaintext path and never writes the token to
stdout. If publication cannot be confirmed after credential authority commits,
the command returns nonzero, reports the token prefix and containment state
without plaintext, and may report protected residue that requires recovery
beginning with prefix revocation.
It refuses with a stable `cluster_already_initialized`
error once an enabled cluster-scoped admin exists, `--force-new-admin --yes`
mints an additional recovery admin without mutating existing credentials, and
`--client-name` overrides the default bootstrap client name. Successful output
directs operators to provision named admin API Clients and then revoke the
bootstrap credential; `--json` emits the same contract for automation.

`orchardctl requests inspect <request-id>` reads the local controller Repo and renders the persisted scheduler explanation for the request.
Use `--json` for the same stable explanation map exposed by the Operator API presenter.

`orchardctl cluster status` renders read-only cluster and Active/Standby control-plane
status from the local controller runtime.
Use `--json` for a stable automation payload with the shared `ControlPlaneStatus`
contract and an Active/Standby summary block; it exposes no leadership-transfer or
failover actions.

`orchardctl support bundle create` writes a local `.tar.gz` with bounded
redacted logs, redacted config, service status, node snapshots, and request
summaries. It records `support_bundle.generated` when the controller Repo is
available and reports skipped audit status otherwise. By default the archive is
written under `<support-root>/support/`; operators can override the destination
with `--output`, read an alternate local state tree with `--support-root`, cap
per-file log tail bytes with `--max-log-bytes`, and use `--json` for
machine-readable output.

## Tenant Model access

Public Model discovery and inference are deny-by-default, and the
`tenant-model-grants` migration creates no grants. For the packaged upgrade
rollout order and its verification steps, see
[Tenant/Model access grant rollout](../../packaging/pkg/README.md#tenantmodel-access-grant-rollout).

```text
orchardctl models access grant <model_id@version> --tenant <uuid-or-slug> [--routing-policy-id <uuid>]
orchardctl models access disable <model_id@version> --tenant <uuid-or-slug>
orchardctl models access revoke <model_id@version> --tenant <uuid-or-slug>
orchardctl models access list --tenant <uuid-or-slug>
orchardctl models access inspect <model_id@version> --tenant <uuid-or-slug>

orchardctl models routing-policy create (--tenant <uuid-or-slug> | --global) \
  --name <name> \
  --residency-preference <required_loaded|prefer_loaded|allow_cold_load> \
  [--max-cold-start-ms <n>] [--max-queue-wait-ms <n>]
orchardctl models routing-policy list (--tenant <uuid-or-slug> | --global)
orchardctl models routing-policy inspect --id <uuid>
```

Omitting `--routing-policy-id` explicitly selects canonical routing defaults;
Orchard does not implicitly select a global policy. `disable` preserves an
attached policy, while `revoke` deletes only the Tenant/Model access row.
Initial routing policies do not accept pool-routing flags because scheduler pool
enforcement is not yet implemented.

## Does not own

- Controller business logic or persistence rules; see `../orchard_controller/`.
- Node-agent runtime behavior; see `../orchard_node_agent/`.
- Installer scripts and launchd plist installation; see
  `../../packaging/pkg/README.md`.

## Local work

Run CLI tests and source-dev commands from the umbrella root through `mise exec --`.
For setup and validation commands, see [`../../docs/tooling.md`](../../docs/tooling.md)
and [`../../docs/local-dev.md`](../../docs/local-dev.md).
