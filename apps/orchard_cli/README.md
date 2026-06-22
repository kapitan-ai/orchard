# orchard_cli

`orchard_cli` builds the `orchardctl` operator/admin command surface used by
source-dev workflows and packaged installs.

This README is orientation only. Normative CLI requirements live in
[`../../SPEC.md`](../../SPEC.md); repo/runtime boundaries are mapped in
[`../../docs/architecture.md`](../../docs/architecture.md).

## Owns

- Operator commands for environment, transport, migrations, status, start/stop,
  upgrades, tenants, API keys, nodes, and models.
- SPEC-required future command paths that return explicit deferred status until
  their milestones land: `cluster init`, `node join`, `nodes admit`,
  and `requests inspect`.
- Local diagnostic support bundle creation via `support bundle create`.
- CLI helpers that wrap release scripts and packaged service management.
- Human-readable operator output and command validation.

## Current command status

The deferred paths above are advertised by `orchardctl`, exit non-zero when
run, and print command-specific usage, `SPEC.md` traceability, and the current
supported source-dev or packaged workflow. `--help` for the same paths is
side-effect free.

`orchardctl support bundle create` writes a local `.tar.gz` with bounded
redacted logs, redacted config, service status, node snapshots, and request
summaries. It records `support_bundle.generated` when the controller Repo is
available and reports skipped audit status otherwise.

## Does not own

- Controller business logic or persistence rules; see `../orchard_controller/`.
- Node-agent runtime behavior; see `../orchard_node_agent/`.
- Installer scripts and launchd plist installation; see
  `../../packaging/pkg/README.md`.

## Local work

Run CLI tests and source-dev commands from the umbrella root through `mise exec --`.
For setup and validation commands, see [`../../docs/tooling.md`](../../docs/tooling.md)
and [`../../docs/local-dev.md`](../../docs/local-dev.md).
