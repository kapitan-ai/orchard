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
  emits the shared `HALiteStatus` payload plus a HA-lite-focused summary of
  deployment mode, controller role, and advisory-lock status.
- SPEC-required future command paths that return explicit deferred status until
  their milestones land: `cluster init` and `node join`.
- Node-admission-review commands (`nodes inspect`, `nodes pending`,
  `nodes admit`, `nodes reject`) with stable JSON and human output, `--dry-run`
  previews, and `--yes`/`--reason` execution gating.
- Node lifecycle commands (`nodes cordon`, `nodes uncordon`, `nodes drain`,
  `nodes maintenance`, `nodes resume`, `nodes decommission`) on the shared
  Action Preview contract, with `--dry-run`/`--json` previews and `--yes`,
  `--acknowledge`, and `--typed-node-id` execution gating. `nodes maintenance`
  previews only; its `draining -> maintenance` execution stays blocked until
  drain completion can be verified.
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

The deferred paths above are advertised by `orchardctl`, exit non-zero when
run, and print command-specific usage, `SPEC.md` traceability, and the current
supported source-dev or packaged workflow. `--help` for the same paths is
side-effect free.

`orchardctl requests inspect <request-id>` reads the local controller Repo and renders the persisted scheduler explanation for the request.
Use `--json` for the same stable explanation map exposed by the Operator API presenter.

`orchardctl cluster status` renders read-only cluster and HA-lite control-plane
status from the local controller runtime.
Use `--json` for a stable automation payload with the shared `HALiteStatus`
contract and a HA-lite summary block; it exposes no leadership-transfer or
failover actions.

`orchardctl support bundle create` writes a local `.tar.gz` with bounded
redacted logs, redacted config, service status, node snapshots, and request
summaries. It records `support_bundle.generated` when the controller Repo is
available and reports skipped audit status otherwise. By default the archive is
written under `<support-root>/support/`; operators can override the destination
with `--output`, read an alternate local state tree with `--support-root`, cap
per-file log tail bytes with `--max-log-bytes`, and use `--json` for
machine-readable output.

## Does not own

- Controller business logic or persistence rules; see `../orchard_controller/`.
- Node-agent runtime behavior; see `../orchard_node_agent/`.
- Installer scripts and launchd plist installation; see
  `../../packaging/pkg/README.md`.

## Local work

Run CLI tests and source-dev commands from the umbrella root through `mise exec --`.
For setup and validation commands, see [`../../docs/tooling.md`](../../docs/tooling.md)
and [`../../docs/local-dev.md`](../../docs/local-dev.md).
