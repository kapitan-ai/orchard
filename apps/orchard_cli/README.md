# orchard_cli

`orchard_cli` builds the `orchardctl` operator/admin command surface used by
source-dev workflows and packaged installs.

This README is orientation only. Normative CLI requirements live in
[`../../SPEC.md`](../../SPEC.md); repo/runtime boundaries are mapped in
[`../../docs/architecture.md`](../../docs/architecture.md).

## Owns

- Operator commands for cluster/bootstrap, environment, transport, migrations,
  status, start/stop, support, upgrades, tenants, API keys, nodes, and models.
- CLI helpers that wrap release scripts and packaged service management.
- Human-readable operator output and command validation.

## Does not own

- Controller business logic or persistence rules; see `../orchard_controller/`.
- Node-agent runtime behavior; see `../orchard_node_agent/`.
- Installer scripts and launchd plist installation; see
  `../../packaging/pkg/README.md`.

## Local work

Run CLI tests and source-dev commands from the umbrella root through `mise exec --`.
For setup and validation commands, see [`../../docs/tooling.md`](../../docs/tooling.md)
and [`../../docs/local-dev.md`](../../docs/local-dev.md).
