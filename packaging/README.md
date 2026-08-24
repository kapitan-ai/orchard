# Orchard Packaging and Operator Runbook

Orchard ships as `Orchard.app` inside a DMG.
The app owns the root-authorized service lifecycle and installs the shared payload under `/Library/Application Support/Orchard`.
See [`dmg/README.md`](dmg/README.md) for app assembly, signing, DMG verification, and lifecycle details.

The accepted Linux Controller profile remains a future milestone with separate headless lifecycle and packaging acceptance requirements.
Nothing in this runbook makes launchd, Keychain, macOS paths, or Apple signing part of the portable Controller contract.

## Shared payload

Build the distribution-neutral payload with:

```bash
mise exec -- ./scripts/build-payload.sh
```

The script builds the Elixir releases and native helper environments, stages the command wrappers and selected launchd plists, remediates Mach-O dependencies, removes macOS metadata, and verifies payload closure.
It prints `PAYLOAD_ROOT=<path>` after the staged payload passes validation.
Pass that path to `scripts/build-app.sh`.

Shared wrapper sources live in `packaging/payload/bin/`.
Payload signing entitlements live in `packaging/payload/entitlements/`.
The staged operator-facing commands are:

- `orchard-controller`
- `orchard-node-agent`
- `orchardctl`
- `orchard-managed-postgres`

Internal release names remain underscore-based: `orchard_controller`, `orchard_node_agent`, and `orchard_cli`.

`--clean` removes `_build/` and `deps/` before assembly.
`--allow-dirty` permits a development payload from a worktree with uncommitted inputs.
The default output parent is `artifacts/payload-builds/YYYY-MM-DD/`.
A custom output parent may be supplied as the final argument.

## Legacy PKG receipt compatibility

The app continues to detect the legacy `com.orchard.pkg` receipt.
Install, update, and uninstall mutations fail closed when that receipt is present so the app cannot silently take ownership of a legacy installation.
Receipt detection is compatibility behavior only and does not retain a native PKG distribution path.

## Roles and lifecycle

The app lifecycle supports `all`, `controller`, and `node-agent` roles.
The selected role controls which system LaunchDaemon plists are installed and managed, not which payload files are available.

| Role | LaunchDaemons installed | Intended host |
|------|-------------------------|---------------|
| `all` | controller and node-agent | Single-machine/default install |
| `controller` | controller only | Control-plane host |
| `node-agent` | node-agent only | Worker host |

The persistent role is stored at `/Library/Application Support/Orchard/support/.install-role`.
An explicit lifecycle `--role` takes precedence over a valid `.install-role.request`, followed by the persistent role and the `all` default.

Install starts no services.
Update restores only services that were loaded before the transaction and remain selected by the new role.
Uninstall removes app-owned payload and service files while preserving operator data, configuration, models, logs, and non-owned support contents.

## External PostgreSQL requirement

Controller-bearing installations require operator-managed PostgreSQL 16 or newer.
Orchard does not currently install or supervise PostgreSQL.
The `orchard-managed-postgres` wrapper is an operator-safe guard that exits nonzero for operational invocations and points operators to external database setup.
The managed Postgres LaunchDaemon is not included in the staged payload.

Before first controller start:

1. Create a PostgreSQL user and database.
2. Create `/Library/Application Support/Orchard/config/controller.env`.
3. Set `DATABASE_URL` and the required controller secrets and transport values.
4. Run `sudo orchardctl migrate`.
5. Run `sudo orchardctl cluster init --output /secure/path/bootstrap-admin.json`.
6. Configure transport and optional Console access.
7. Run `sudo orchardctl start`.
8. Verify with `orchardctl status` and authenticated operator health.

For a local two-Mac rehearsal, PostgreSQL may run on loopback on the controller Mac.
The node-agent Mac does not require direct PostgreSQL access.
Use TLS and network allowlisting when PostgreSQL is reached over a private LAN or VPN.

## Environment files

The service wrappers read optional environment files before starting their releases.
`orchardctl` also reads `controller.env` for database-backed commands.

| Service | Environment file |
|---------|------------------|
| controller | `/Library/Application Support/Orchard/config/controller.env` |
| node-agent | `/Library/Application Support/Orchard/config/node-agent.env` |

Environment files use plain `KEY=value` lines.
They must be owned by root and have no group or world permission bits.
Mode `0600` is recommended.
Files that fail these checks are ignored with a warning because the wrappers source them with root authority.

Values containing spaces or shell metacharacters must use shell-safe quoting.
Do not place credentials in command history or world-readable files.

## Multi-Mac runtime

The current distributed macOS path supports one controller Mac and one or more node-agent Macs on a trusted private network or VPN.
BEAM Runtime Endpoint transport is the first-party default.
gRPC remains an explicit compatibility path.

For the shared-cookie first cut:

- Assign each host a routable `ORCHARD_BEAM_NODE_NAME`.
- Use a shared root-owned mode `0600` `ORCHARD_BEAM_COOKIE_FILE`.
- Configure the same EPMD port across participating hosts.
- Restrict EPMD and BEAM distribution ports to the trusted network.
- Configure controller Runtime Endpoint targets for the admitted worker nodes.
- Do not expose EPMD, BEAM distribution, or node-agent gRPC to the public internet.

See [`../docs/local-dev.md`](../docs/local-dev.md) for the current validated source-development topology.

## Transport and TLS

The controller supports `plain_http_localhost`, `direct_https`, and `reverse_proxy` transport modes.
The default loopback HTTP mode is degraded and must not be exposed beyond the host.
For production access, use operator-provided certificates, an internal PKI, or a trusted reverse proxy.
The local CA helper is intended for development and lab bootstrap.

The controller wrapper validates required TLS files before starting the release.
It fails closed for unknown transport modes, incomplete certificate/key pairs, missing configured files, and malformed legacy TLS compatibility values.
CORS remains disabled unless an explicit origin allowlist is configured.

## Permissions

Recommended installed permissions are:

| Path | Mode | Owner | Group |
|------|------|-------|-------|
| `config/` | `0750` | root | admin |
| `config/tls/` | `0750` | root | admin |
| `logs/` | `0755` | root | wheel |
| `controller.env` | `0600` | root | wheel |
| `node-agent.env` | `0600` | root | wheel |
| BEAM cookie file | `0600` | root | wheel |

Private keys must remain mode `0600`.
Certificates and non-secret metadata may be mode `0644` where documented by the command that creates them.

## Operator bootstrap

For an all-in-one or controller host:

```bash
sudo orchardctl env init --service controller
sudo orchardctl migrate
sudo orchardctl cluster init --output /secure/path/bootstrap-admin.json
sudo orchardctl start
orchardctl status
```

For an all-in-one host, use `--service all` when initializing environment files.
For a node-agent host, use `--service node-agent`, configure its BEAM identity and worker settings, then start and verify the selected service.

Before public inference, create an Organization, issue a credential, import and activate a model, and grant that Organization access to the model.
Model access is deny-by-default.

```bash
sudo orchardctl tenants create --slug default --name "Default"
sudo orchardctl api-keys create --tenant-id <tenant-id> --name "Primary"
sudo orchardctl models access grant <model_id>@<version> --tenant default
```

`orchardctl cluster init` and API credential creation publish secrets only through their explicit one-time output paths.
Protect those files and revoke credentials by prefix if publication cannot be confirmed.

## Diagnostics

Use these operator surfaces before changing host state:

- `orchardctl status`
- authenticated `/ops/v1/health`
- authenticated `/metrics`
- controller and node-agent logs
- `orchardctl requests inspect <request-id>`
- `orchardctl support bundle create`

The `/metrics` route uses the same controller listener as the API and Console and requires an Operator or admin API Client token.
Do not publish it outside the trusted private network or VPN.

## Validation

Run the focused packaging checks from the repository root:

```bash
scripts/test-build-payload.sh
scripts/test-build-app.sh
scripts/test-app-signing.sh
scripts/test-build-dmg.sh
swift test --package-path packaging/app
```

Developer ID signing, notarization, stapling, draft publication, and system-root lifecycle mutations remain explicit credential or authorization gates.
