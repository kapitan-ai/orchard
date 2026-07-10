# PKG Packaging and Operator Runbook

The PKG remains a supported, separate ownership path for root-authorized, offline, and manual deployment while the Orchard.app DMG path proves lifecycle parity.
Do not layer app-owned service mutations over a host with the `com.orchard.pkg` receipt.
The app lifecycle refuses that takeover and keeps the PKG's role selection, launchd labels, wrapper sources, and installed-path policy aligned through `packaging/service-lifecycle.json` and contract tests.
See `packaging/dmg/README.md` for the app-owned path.

Current packaged installs use a universal PKG payload with role selection for
`all`, `controller`, and `node-agent` hosts. Controller-bearing installs require
an **external PostgreSQL** server today; managed Postgres is not available in
this build. The `orchard-managed-postgres` helper remains an operator-safe
placeholder for future Managed Database Mode and exits non-zero for operational
invocations with the current external database setup path.
Services are installed by role and must be configured before start.

## Naming strategy

- Internal release names remain underscore-based (`orchard_controller`, `orchard_node_agent`, `orchard_cli`).
- Installed operator-facing commands use the Orchard product names expected by `SPEC.md` and launchd:
  - `orchard-controller`
  - `orchard-node-agent`
  - `orchardctl`
  - `orchard-managed-postgres`
- The PKG is expected to provide these external commands as wrapper scripts under `/Library/Application Support/Orchard/bin/`.

## Prerequisites

The packaged controller requires an **external PostgreSQL** server. Orchard does
not currently ship a managed Postgres runtime. The `orchard-managed-postgres`
wrapper is a placeholder that exits non-zero for operational invocations and
points operators back to the external PostgreSQL setup path.

Before starting the controller for the first time:

1. Ensure PostgreSQL is running and accessible from the host.
2. Create a database for the controller (e.g. `orchard_controller`).
3. Create `controller.env` with the required variables (see below).
4. Run release migrations (see below).

### Local two-Mac rehearsal PostgreSQL setup

For the current packaged two-Mac rehearsal, prefer a Homebrew-managed PostgreSQL 16 server on the controller Mac, bound to loopback.
This still counts as operator-managed external PostgreSQL because Orchard does not install, bootstrap, or supervise it.
It avoids exposing Postgres to the worker Mac, and it matches the current packaged BEAM topology where only the controller Mac needs database access.

Install and start PostgreSQL on the controller Mac:

```bash
brew install postgresql@16
brew services start postgresql@16
/opt/homebrew/opt/postgresql@16/bin/pg_isready -h 127.0.0.1 -p 5432
```

If Homebrew is installed somewhere other than `/opt/homebrew`, replace `/opt/homebrew` with `$(brew --prefix)`.
Create an Orchard database user and database without placing the password in shell history:

```bash
$(brew --prefix)/opt/postgresql@16/bin/createuser --pwprompt orchard
$(brew --prefix)/opt/postgresql@16/bin/createdb -O orchard orchard_controller
$(brew --prefix)/opt/postgresql@16/bin/psql "postgresql://orchard@127.0.0.1:5432/orchard_controller" -c 'select 1'
```

Set the packaged controller DSN to loopback in `/Library/Application Support/Orchard/config/controller.env`.
URL-encode any special characters in the password.
For a local lab loopback database, omit TLS or set `ssl=false`; use TLS for a PostgreSQL host reached over a private LAN, VPN, or Tailscale network.

```bash
DATABASE_URL="ecto://orchard:URL_ENCODED_PASSWORD@127.0.0.1:5432/orchard_controller?ssl=false"
```

The worker Mac does not need direct PostgreSQL reachability in the packaged BEAM first cut.
Do not point node-agent env files at Postgres.
If a separate PostgreSQL host is required, restrict it to the controller Mac's private IP or VPN IP in PostgreSQL `listen_addresses`, `pg_hba.conf`, and host firewall rules rather than opening `0.0.0.0/0`.
Use PostgreSQL 16 or newer, require password authentication, and prefer TLS for any non-loopback database connection.

Operational notes:

- `brew services start postgresql@16` is convenient for local rehearsal and restarts PostgreSQL when the owning user logs in.
- It is not a substitute for Orchard Managed Database Mode, boot-before-login service management, backup automation, or production hardening.
- Back up rehearsal state with `pg_dump` or `pg_dumpall` before deleting the Homebrew data directory.
- Homebrew's default PostgreSQL 16 data directory on Apple Silicon is usually `/opt/homebrew/var/postgresql@16`.

Fallback local container path:

Use the container path only when an organization-approved local container runtime is already part of the operator environment.
Run `postgres:16` or a PostgreSQL 16+ equivalent with a persistent named volume, `POSTGRES_USER=orchard`, `POSTGRES_DB=orchard_controller`, a generated password, and a loopback-only port binding such as `127.0.0.1:5432:5432`.
The container must publish Postgres only on loopback for the two-Mac rehearsal.
The chosen container runtime must be running before its restart policy can bring the database back after a reboot or logout.

## Packaged External-Sites Multi-Mac First Cut

The first external-sites packaged cut supports one controller Mac and one or more node-agent Macs on a trusted private network or VPN.
It uses operator-managed external PostgreSQL and BEAM Runtime Endpoint transport as the packaged multi-Mac happy path.
gRPC remains available only as an explicit compatibility fallback.
Managed Postgres remains out of scope for this cut.
Secure Node Enrollment is available through a local controller-host bundle, `orchardctl node join`, explicit admission, and the certificate-backed gRPC compatibility path.

Network prerequisites:

- The controller Mac and each node-agent Mac can reach one another over EPMD TCP `4369` or the shared `ORCHARD_BEAM_EPMD_PORT`.
- The controller Mac can reach each node-agent Mac on the configured BEAM distribution ports.
- Defaults are controller TCP `52171` and node-agent TCP `52172`.
- Use the same root-owned mode `0600` `ORCHARD_BEAM_COOKIE_FILE` contents on every participating Mac.
- Do not expose BEAM EPMD, BEAM distribution ports, or node-agent gRPC directly to the public internet.
- The controller Mac can reach the external PostgreSQL server.

Provision the BEAM cookie once, then copy the same file contents to each participating Mac through an operator-controlled secure channel:

```bash
sudo install -d -o root -g wheel -m 0750 '/Library/Application Support/Orchard/config'
openssl rand -base64 48 | sudo tee '/Library/Application Support/Orchard/config/beam.cookie' >/dev/null
sudo chown root:wheel '/Library/Application Support/Orchard/config/beam.cookie'
sudo chmod 0600 '/Library/Application Support/Orchard/config/beam.cookie'
```

Controller host sequence:

1. Seed `.install-role.request` with `controller` or `all` before installing the PKG.
2. Install the universal PKG.
3. Run `sudo orchardctl env init --service controller` for a controller-only host, or `sudo orchardctl env init --service all` for an all-in-one host.
4. Edit `/Library/Application Support/Orchard/config/controller.env`.
5. Set `DATABASE_URL` for operator-managed external PostgreSQL, for example `ecto://USER:PASSWORD@postgres.example.internal:5432/orchard_controller?ssl=true`.
6. Keep the generated `SECRET_KEY_BASE` unless intentionally rotating it.
7. Keep `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT="beam"`.
8. Set `ORCHARD_BEAM_NODE_NAME` to `orchard_controller@<controller-ipv4>`.
   The controller rejects remote BEAM targets when its node name still uses a loopback host.
9. Provision `ORCHARD_BEAM_COOKIE_FILE` with the same root-owned mode `0600` cookie file used by every node-agent Mac.
10. Set `ORCHARD_RUNTIME_ENDPOINT_TARGETS` to comma-separated node-agent BEAM node names, for example `orchard_node_agent@10.0.0.21,orchard_node_agent@10.0.0.22`.
11. Set `ORCHARD_BEAM_EPMD_PORT`, `ORCHARD_BEAM_DIST_PORT_MIN`, and `ORCHARD_BEAM_DIST_PORT_MAX` only when the defaults conflict with local services or firewall policy.
12. Configure `ORCHARD_TRANSPORT_MODE`, `ORCHARD_PUBLIC_HOST`, and related transport values for direct HTTPS, reverse proxy, or explicit local generated HTTPS.
13. Run `sudo orchardctl migrate`.
14. Run `sudo orchardctl cluster init --output /secure/path/bootstrap-admin.json`.
15. Store the One-time Secret Output on protected removable media or another operator-controlled secure location.
16. Run `sudo orchardctl start`.
17. Verify with `orchardctl status`.

Node-agent host sequence:

1. Seed `.install-role.request` with `node-agent` before installing the PKG.
2. Install the universal PKG.
3. Run `sudo orchardctl env init --service node-agent`.
4. Edit `/Library/Application Support/Orchard/config/node-agent.env`.
5. Keep `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT="beam"`.
6. Set `ORCHARD_BEAM_NODE_NAME` to `orchard_node_agent@<worker-ipv4>`.
7. Provision `ORCHARD_BEAM_COOKIE_FILE` with the same root-owned mode `0600` cookie file used by the controller Mac.
8. Keep `ORCHARD_NODE_AGENT_LISTEN_HOST="127.0.0.1"` unless intentionally using the gRPC compatibility fallback.
9. Set `ORCHARD_NODE_DISPLAY_NAME` and worker backend settings for the host.
10. Run `sudo orchardctl start`.
11. Verify with `orchardctl status` and the node-agent launchd log at `/Library/Application Support/Orchard/logs/node-agent.log`.

Verification:

- On each host, `orchardctl status` should show the role-selected service state.
- On the controller, readiness should report PostgreSQL reachable and migrations current.
- On the controller, Runtime Endpoint target configuration should match each remote node-agent BEAM node name in `ORCHARD_RUNTIME_ENDPOINT_TARGETS`.
- After admin credentials, tenant/API access, model import, and model activation are configured, use `/v1/models` and a single chat completion request as the external-site API smoke test.

gRPC compatibility fallback:

- Set `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT="grpc"` on the controller and node-agent hosts.
- Configure node-agent `ORCHARD_NODE_AGENT_LISTEN_HOST` and `ORCHARD_NODE_AGENT_LISTEN_PORT` for a trusted private network or VPN.
- Configure controller `ORCHARD_RUNTIME_CLIENT_TARGETS` with comma-separated node-agent `host:port` values.
- Use this path only for compatibility or diagnostic fallback, not as the packaged happy path.

Explicit deferrals:

- BEAM cookie provisioning is operator-managed in this phase and must produce a root-owned mode `0600` file.
- Production BEAM credential hardening remains future work and the shared BEAM cookie must not be treated as Node identity.
- Managed Postgres is unavailable in this build.

## Install Role Selection

Orchard ships a **universal PKG payload**. The install role controls which
system LaunchDaemon plists are installed and later managed; it does not remove
binaries or other payload files.

Role contract:

| Role | LaunchDaemons installed | Intended host |
|------|-------------------------|---------------|
| `all` | controller + node-agent | Single-machine/default install |
| `controller` | controller only | Control-plane host |
| `node-agent` | node-agent only | Worker-node host |

The default role is `all`. The persistent source of truth is:

```text
/Library/Application Support/Orchard/support/.install-role
```

To select or change a role, seed this request file **before** running
`installer`:

```text
/Library/Application Support/Orchard/support/.install-role.request
```

The file must contain exactly one of `all`, `controller`, or `node-agent`
(optionally followed by a newline). The installer validates the request,
installs only the selected LaunchDaemons, removes any stale out-of-role
controller/node-agent plist from a prior role, atomically writes `.install-role`,
and deletes `.install-role.request` after success. On upgrade, if no request file
is present, the installer preserves the existing `.install-role`; if neither file
exists, it defaults to `all`.

The installer also always boots out and removes stale
`com.orchard.postgres.plist` before role validation, because managed Postgres
LaunchDaemon service mode is unsupported in this build.

Local automation should create the same root-owned request file before
installing the universal PKG. Recommended request-file permissions are
`0600 root:wheel`.

### Role install examples

Controller-only host:

```bash
sudo install -d -o root -g wheel -m 0755 \
  '/Library/Application Support/Orchard/support'
printf 'controller\n' | sudo tee \
  '/Library/Application Support/Orchard/support/.install-role.request' >/dev/null
sudo chown root:wheel \
  '/Library/Application Support/Orchard/support/.install-role.request'
sudo chmod 0600 \
  '/Library/Application Support/Orchard/support/.install-role.request'
sudo installer -pkg Orchard-<version>-<date>-<sha>.pkg -target /
sudo cat '/Library/Application Support/Orchard/support/.install-role'
```

Node-agent-only host:

```bash
sudo install -d -o root -g wheel -m 0755 \
  '/Library/Application Support/Orchard/support'
printf 'node-agent\n' | sudo tee \
  '/Library/Application Support/Orchard/support/.install-role.request' >/dev/null
sudo chown root:wheel \
  '/Library/Application Support/Orchard/support/.install-role.request'
sudo chmod 0600 \
  '/Library/Application Support/Orchard/support/.install-role.request'
sudo installer -pkg Orchard-<version>-<date>-<sha>.pkg -target /
sudo cat '/Library/Application Support/Orchard/support/.install-role'
```

All-in-one/default host:

```bash
sudo install -d -o root -g wheel -m 0755 \
  '/Library/Application Support/Orchard/support'
printf 'all\n' | sudo tee \
  '/Library/Application Support/Orchard/support/.install-role.request' >/dev/null
sudo chown root:wheel \
  '/Library/Application Support/Orchard/support/.install-role.request'
sudo chmod 0600 \
  '/Library/Application Support/Orchard/support/.install-role.request'
sudo installer -pkg Orchard-<version>-<date>-<sha>.pkg -target /
sudo cat '/Library/Application Support/Orchard/support/.install-role'
```

You can also omit `.install-role.request` for a fresh all-in-one install, because
`all` is the default. To change roles later, write a new `.install-role.request`
with the desired role and reinstall the universal PKG.

## Env File Overrides

Wrapper scripts (`bin/orchard-node-agent`, `bin/orchard-controller`) source
optional env files before starting the BEAM release. `bin/orchardctl` also
sources `controller.env` so DB-backed CLI commands, including upgrade preflight,
use the same database configuration as the controller:

| Service | Env File |
|---------|----------|
| node-agent | `/Library/Application Support/Orchard/config/node-agent.env` |
| controller | `/Library/Application Support/Orchard/config/controller.env` |

Format: plain `KEY=value` lines. Comments (`#`) and blank lines are fine.

DB-backed CLI commands (for example `orchardctl nodes`, `models`, `requests`,
`cluster status`, `cluster init`, `tenants`, `api-keys`, and `api-clients`)
start the controller Repo on demand, so they must run as root (`sudo`) to read
`controller.env` and its `DATABASE_URL`. When the database is unreachable or
`DATABASE_URL` is unset, these commands fail with a `database_unavailable`
error and remediation guidance rather than returning empty or "not found"
output.

Primary use case: operational rollback of the worker backend without editing
launchd plists or global environment.

```bash
# Example: rollback to stub backend
echo 'ORCHARD_WORKER_BACKEND=stub' | sudo tee \
  '/Library/Application Support/Orchard/config/node-agent.env'
sudo launchctl kickstart -k system/com.orchard.node-agent
```

No `ORCHARD_WORKER_GENERATION_MODE` override is required for this rollback path;
when the backend is `stub` and the mode env var is unset, packaged runtime
configuration resolves generation mode to `stream`. If set explicitly, valid
values are `stream` and `batch`; leave it unset for stub rollback.
For MLX batch mode, `ORCHARD_WORKER_MAX_CONCURRENT_REQUESTS_PER_MODEL` controls the worker-reported request capacity for each loaded placement.
The default `auto` value resolves through `ORCHARD_WORKER_AUTO_MAX_CONCURRENT_REQUESTS_PER_MODEL`, currently `3`.
The node-agent reports aggregate capacity in `StatusResponse.active_request_count` and `StatusResponse.max_concurrency`, and placement capacity in `StatusResponse.runtime_model_placements`.
Aggregate capacity is the conservative limit the node agent enforces across loaded workers.

**Security note:** These files are sourced by shell scripts running as root
(via launchd). The wrapper scripts validate ownership and permissions before
sourcing — files that are not root-owned (`uid 0`) or have group/world
permissions are **ignored with a warning** to stderr (visible in launchd
logs). The service still starts, but without the overrides.

Recommended setup:

```bash
# Create env file with correct ownership and permissions
echo 'ORCHARD_WORKER_BACKEND=stub' | sudo tee \
  '/Library/Application Support/Orchard/config/node-agent.env'
sudo chmod 600 '/Library/Application Support/Orchard/config/node-agent.env'
```

The `config/` directory is set to mode `0750` root:admin by the installer,
allowing members of the admin group (GID 80) to traverse and read configuration.
Private keys and secrets in env files remain protected via owner-only (0600)
permissions.

### Shell quoting requirement

Env files are **sourced as POSIX shell** (not parsed as generic `.env` files).
Values containing spaces, dollar signs, backticks, or hash characters **must**
be quoted. The Orchard support root (`/Library/Application Support/Orchard`)
contains a space, so all paths under it require quoting:

```bash
# CORRECT — quoted path with space
ORCHARD_TOKENIZER_EXECUTABLE="/Library/Application Support/Orchard/native/orchard_tokenizer/.venv/bin/orchard-tokenizer"

# BROKEN — unquoted path with space
ORCHARD_TOKENIZER_EXECUTABLE=/Library/Application Support/Orchard/native/orchard_tokenizer/.venv/bin/orchard-tokenizer
```

Use `orchardctl env init` (below) to generate correctly-quoted templates.
You can target a specific role template with `--service controller`,
`--service node-agent`, or keep `--service all` for both files. Generated
templates include role-aware guidance comments for controller BEAM Runtime
Endpoint targets, public host, tokenizer path, node-agent BEAM node identity,
cookie path, EPMD/distribution ports, gRPC compatibility settings, worker path,
and clearly marked M3 join placeholders.

### Controller env file lifecycle

**Fresh install (recommended):** Use `orchardctl env init` to generate
correctly-quoted templates with auto-detected packaged paths:

```bash
sudo orchardctl env init
```

This creates `controller.env` and `node-agent.env` under
`/Library/Application Support/Orchard/config/` with:
- Shell-safe quoted values (handles the space in `Application Support`)
- Auto-detected absolute paths to packaged tokenizer and worker executables
  (uses `.venv/bin/` entrypoints directly — no `uv` or PATH dependency)
- A generated `SECRET_KEY_BASE`
- A commented external PostgreSQL `DATABASE_URL` placeholder
- BEAM Runtime Endpoint transport, node-name, cookie-file, EPMD, and distribution-port templates
- BEAM controller target comments for remote node-agent Macs
- A node-agent gRPC listener template that starts on loopback and is documented as compatibility/fallback only

Then fill in the required external database and runtime target values:

```bash
sudo vi '/Library/Application Support/Orchard/config/controller.env'
# Uncomment and set DATABASE_URL.
# Set ORCHARD_RUNTIME_ENDPOINT_TARGETS when using remote node-agent Macs.
# Provision ORCHARD_BEAM_COOKIE_FILE with the same root-owned mode 0600 cookie on every Mac.
```

Leave the generated `SECRET_KEY_BASE` in place unless intentionally rotating it.

Then run migrations through the packaged CLI:

```bash
sudo orchardctl migrate
```

**Manual alternative:** If you prefer to create the file manually:

```bash
sudo tee '/Library/Application Support/Orchard/config/controller.env' >/dev/null <<'EOF'
DATABASE_URL="ecto://USER:PASSWORD@postgres.example.internal:5432/orchard_controller?ssl=true"
SECRET_KEY_BASE="<generate-with-mix-phx-gen-secret>"
ORCHARD_TOKENIZER_EXECUTABLE="/Library/Application Support/Orchard/native/orchard_tokenizer/.venv/bin/orchard-tokenizer"
ORCHARD_RUNTIME_ENDPOINT_TRANSPORT="beam"
ORCHARD_RUNTIME_ENDPOINT_TARGETS="orchard_node_agent@10.0.0.21"
ORCHARD_BEAM_NODE_NAME="orchard_controller@10.0.0.10"
ORCHARD_BEAM_COOKIE_FILE="/Library/Application Support/Orchard/config/beam.cookie"
EOF
sudo chown root:wheel '/Library/Application Support/Orchard/config/controller.env'
sudo chmod 600 '/Library/Application Support/Orchard/config/controller.env'
```

**Required variables:**

| Variable | Description |
|----------|-------------|
| `DATABASE_URL` | Postgres connection URL (required) |
| `SECRET_KEY_BASE` | Phoenix secret key base (required) |

**Optional variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `ORCHARD_CONSOLE_ENABLED` | `false` | Enable the operator console UI |
| `ORCHARD_CONSOLE_USERNAME` | — | Console Basic Auth username (required when console enabled) |
| `ORCHARD_CONSOLE_PASSWORD` | — | Console Basic Auth password (required when console enabled) |
| `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT` | `beam` | Runtime Endpoint transport. Use `grpc` only for compatibility fallback. |
| `ORCHARD_RUNTIME_ENDPOINT_TARGETS` | required for BEAM multi-Mac | Comma-separated node-agent BEAM node names such as `orchard_node_agent@10.0.0.21`. |
| `ORCHARD_BEAM_NODE_NAME` | `orchard_controller@127.0.0.1` | Controller BEAM node name. Use `orchard_controller@<controller-ipv4>` for multi-Mac; remote BEAM targets are rejected while this remains loopback. |
| `ORCHARD_BEAM_COOKIE_FILE` | `/Library/Application Support/Orchard/config/beam.cookie` | Root-owned mode `0600` BEAM cookie file shared across controller and node-agent Macs. |
| `ORCHARD_BEAM_EPMD_PORT` | `4369` | EPMD port. Set the same override on every Mac when needed. |
| `ORCHARD_BEAM_DIST_PORT_MIN` / `ORCHARD_BEAM_DIST_PORT_MAX` | `52171` | Controller BEAM distribution port range. |
| `ORCHARD_RUNTIME_CLIENT_TARGETS` | unset | gRPC compatibility fallback only. Comma-separated node-agent `host:port` values. |
| `POOL_SIZE` | `10` | Ecto connection pool size |
| `ECTO_IPV6` | — | Set to `true` for IPv6 socket options |

See the Controller Transport section below for TLS-related variables.

**Upgrade:** The installer preserves existing `controller.env` files. They are
not overwritten during package upgrades.

**Troubleshooting:**

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Controller crash-loops with `DATABASE_URL is missing` | `controller.env` absent or ignored | Create the file with correct ownership/permissions |
| Readiness reports `postgres_reachable: false` | Wrong DB URL, DB not running, or DB does not exist | Verify with `psql "$DATABASE_URL" -c 'select 1'` |
| Readiness reports `migrations_current: false` (with DB reachable) | Migrations not run | Run `sudo orchardctl migrate` |
| DB-backed CLI command fails with `database_unavailable` | Command run without `sudo`, `DATABASE_URL` unset, DB unreachable, or migrations pending | Re-run with `sudo`; verify `DATABASE_URL` in `controller.env` and `psql "$DATABASE_URL" -c 'select 1'`; run `sudo orchardctl migrate` if pending |
| `WARNING: ignoring env file` in controller.log | File not root-owned or has group/world permission bits | `sudo chown root:wheel <file> && sudo chmod 600 <file>` |

## Upgrade Preflight

Use `orchardctl upgrade plan` before installing a replacement PKG. The command
runs the controller-side SPEC §13.7 preflight checks without changing Orchard
state:

```bash
sudo orchardctl upgrade plan
```

The preflight validates the backup manifest, database reachability and migration
lock availability, migration status, request activity, draining and
decommissioning nodes, and node-agent version compatibility. Business logic runs
inside the controller application (`Orchard.Upgrade.plan/1`); the CLI only
renders the result and returns the mapped exit code.

### Exit codes

| Exit code | Status | Meaning |
|-----------|--------|---------|
| `0` | `safe` | All blocking checks passed. Warnings may still be present. |
| `1` | `unsafe` | One or more checks are blocked, such as active requests, pending migrations, draining/decommissioning nodes, or incompatible node-agent versions. |
| `2` | `config_error` | The preflight configuration is invalid, such as a malformed backup manifest or invalid queue tolerance. CLI usage errors also return `2`. |
| `3` | `unreachable` | A required runtime dependency, typically Postgres or node inventory, could not be reached. |

### JSON output

Use `--json` for automation:

```bash
sudo orchardctl upgrade plan --json
```

JSON mode emits the raw `Orchard.Upgrade.plan/1` result map. Successful plans
(exit `0`) are printed to stdout. Non-zero plan results follow the global
`orchardctl` command-result contract and are printed to stderr before exiting
with the mapped code.

### Backup manifest

Default path:

```text
/Library/Application Support/Orchard/support/upgrade-backup.json
```

The default is derived from `ORCHARD_SUPPORT_ROOT` when that variable is set:
`$ORCHARD_SUPPORT_ROOT/support/upgrade-backup.json`.

Minimum schema for the current preflight contract:

```json
{
  "schema_version": 1,
  "created_at": "2026-04-18T12:00:00Z",
  "database": {
    "location": "postgresql://localhost/orchard_controller"
  },
  "support_root": {
    "location": "/Library/Application Support/Orchard"
  }
}
```

Only `schema_version` and `created_at` are currently required by preflight;
additional fields document the operator backup source for future auditability.
Create or refresh the manifest after completing your backup step:

```bash
sudo mkdir -p '/Library/Application Support/Orchard/support'
sudo tee '/Library/Application Support/Orchard/support/upgrade-backup.json' >/dev/null <<'JSON'
{
  "schema_version": 1,
  "created_at": "2026-04-18T12:00:00Z",
  "database": {
    "location": "postgresql://localhost/orchard_controller"
  },
  "support_root": {
    "location": "/Library/Application Support/Orchard"
  }
}
JSON
sudo chown root:wheel '/Library/Application Support/Orchard/support/upgrade-backup.json'
sudo chmod 600 '/Library/Application Support/Orchard/support/upgrade-backup.json'
```

### Upgrade preflight environment

Set these in `controller.env` so both the controller and packaged `orchardctl`
see the same policy:

| Variable | Default | Description |
|----------|---------|-------------|
| `ORCHARD_UPGRADE_BACKUP_MANIFEST_PATH` | `$ORCHARD_SUPPORT_ROOT/support/upgrade-backup.json` | Override the backup manifest path checked by `orchardctl upgrade plan`. |
| `ORCHARD_UPGRADE_QUEUE_TOLERANCE` | `0` | Maximum queued requests allowed during preflight. Must be an integer `>= 0`; active non-queued requests still block. |

Example:

```bash
sudo tee -a '/Library/Application Support/Orchard/config/controller.env' >/dev/null <<'EOF'
ORCHARD_UPGRADE_BACKUP_MANIFEST_PATH="/Library/Application Support/Orchard/support/upgrade-backup.json"
ORCHARD_UPGRADE_QUEUE_TOLERANCE=0
EOF
sudo chown root:wheel '/Library/Application Support/Orchard/config/controller.env'
sudo chmod 600 '/Library/Application Support/Orchard/config/controller.env'
```

### Operator upgrade workflow

1. **Plan with current state:**
   ```bash
   sudo orchardctl upgrade plan
   ```
   Resolve any `unsafe`, `config_error`, or `unreachable` result before
   installing a replacement PKG.

2. **Back up Orchard state:** back up Postgres and any required support-root
   files, then write the backup manifest shown above.

3. **Re-run preflight:**
   ```bash
   sudo orchardctl upgrade plan --json
   ```
   Confirm exit code `0` for a safe upgrade window.

4. **Install the replacement PKG:**
   ```bash
   sudo installer -pkg Orchard-<version>-<date>-<sha>.pkg -target /
   ```
   Existing `controller.env`, support data, and TLS material are preserved.
   Services are stopped during upgrade and are not auto-restarted.

5. **Run migrations if the new release requires them:**
   ```bash
   sudo orchardctl migrate
   ```

6. **Start services:**
   ```bash
   sudo orchardctl start
   ```

7. **Verify readiness and version:**
   ```bash
   sudo orchardctl status
   curl --cacert '/Library/Application Support/Orchard/config/tls/ca.crt' \
     https://localhost:8443/health/ready
   ```

## Licensing v0

Orchard licensing v0 stores one Orchard-owned local bundle at:

- `/Library/Application Support/Orchard/config/licensing/current.json`

The bundle persists only the extracted certificate pair:

- `license_certificate`
- `machine_certificate`

Orchard does **not** persist Keygen JSON envelopes as runtime state, and Orchard
hosts do **not** require or support a shipped Keygen admin token.

### Activation workflow

Activate a license with the packaged CLI using a non-argv key source:

```bash
sudo orchardctl license activate --key-file /path/to/orchard-license-key
```

The key file must be a regular file with `0600` permissions. For an interactive
handoff, warm sudo first so it cannot consume stdin, then read the key without
echoing it:

```bash
sudo -v
read -rs ORCHARD_TRIAL_LICENSE_KEY
sudo orchardctl license activate --key-stdin <<<"$ORCHARD_TRIAL_LICENSE_KEY"
unset ORCHARD_TRIAL_LICENSE_KEY
```

Activation uses the stable Orchard node ID as the machine fingerprint, performs
Keygen validation + checkout, extracts the plaintext certificate pair, verifies
that pair offline, and installs it atomically into `current.json`.

If activation fails after a bundle already exists, Orchard keeps the previous
local bundle untouched.

Orchard ships the Keygen account ID, public verification key, and default API
base URL as product config. Operators do **not** need to set
`ORCHARD_KEYGEN_ACCOUNT_ID` or `ORCHARD_KEYGEN_PUBLIC_KEY` for normal installs.
Those variables, plus `ORCHARD_KEYGEN_API_BASE_URL`, are optional overrides for
Orchard-directed alternate environments and debugging only. If you override the
account ID or public key, keep them as a matching pair or activation/offline
verification will fail.

### Status and observation workflow

- `orchardctl license status` inspects only local Orchard licensing state.
- `orchardctl status` renders the controller's additive health payload when the
  `"license"` block is present.
- Controller `/health/ready` exposes license state for observation, but remains
  **non-gating** — it does not change readiness semantics or HTTP status.

**Exposure posture:** `/health/ready` is intentionally unauthenticated for
operational readiness checks, so health endpoints should be network-restricted
to trusted operator/support paths (for example, VPN/private-network access,
firewall rules, or reverse-proxy allowlists). Do not expose these endpoints
directly to the public internet.

If a license includes optional tracking metadata, `orchardctl license status`,
`orchardctl status`, and `/health/ready` may display the tracking program and
reference. This metadata and other license identifiers are intended for
operator/support diagnostics and do not affect license enforcement.

### Licensing environment variables

| Variable | Default | Intended use |
|----------|---------|--------------|
| `ORCHARD_BUILD_CHANNEL` | `trial` for scripted PKG builds; `dev` for source builds | Compile-time build identity surfaced in `/health/ready`. Distributed package builds must use a non-`dev` channel. |
| `ORCHARD_LICENSE_ENFORCEMENT` | `hard` for distributed channels; `off` for `dev` | Shared controller/node-agent/CLI enforcement mode: `off`, `warn`, or `hard`. Explicit values override the build-channel default for recovery. |
| `ORCHARD_LICENSE_BUNDLE_PATH` | `/Library/Application Support/Orchard/config/licensing/current.json` | Rare Orchard-directed override for alternate support-root layouts or debugging |
| `ORCHARD_NODE_IDENTITY_PATH` | `/Library/Application Support/Orchard/data/node-id` | Rare override when Orchard support-root layout is intentionally changed |
| `ORCHARD_KEYGEN_API_BASE_URL` | `https://api.keygen.sh` | Optional Orchard-directed override for alternate provider environments |
| `ORCHARD_KEYGEN_ACCOUNT_ID` | built-in Orchard Keygen account ID | Optional override; keep paired with matching public key |
| `ORCHARD_KEYGEN_PUBLIC_KEY` | built-in Orchard Ed25519 verification key | Optional override; keep paired with matching account ID |

No Orchard host runtime requires or supports a shipped
`ORCHARD_KEYGEN_ADMIN_TOKEN` dependency.

### Node-agent enforcement

Licensing enforcement for the packaged node-agent covers both startup checks and runtime useful-work admission. The node-agent reads the same shared licensing enforcement mode as controller and CLI release code.

Mode behavior:
- `off` — skip startup checks and allow runtime useful-work admission
- `warn` — log the licensing problem during startup checks and continue; runtime useful-work admission remains non-blocking without per-admission warn logs
- `hard` — abort node-agent startup or deny new useful work when the local bundle is not valid

### Rollout posture

Distributed PKG builds default to `ORCHARD_BUILD_CHANNEL=trial`, which defaults license enforcement to `hard` unless `ORCHARD_LICENSE_ENFORCEMENT` is explicitly set. Source development and tests keep enforcement `off`.

### Rollback / reset

To remove runtime licensing impact quickly, set:

```bash
ORCHARD_LICENSE_ENFORCEMENT=off
```

Then restart the node-agent service.

If you need to intentionally reset Orchard back to `missing_bundle`, remove the
local bundle file:

```bash
sudo rm '/Library/Application Support/Orchard/config/licensing/current.json'
```

Do this only when you explicitly want Orchard to forget the current local
license state.

### Confidence caveat

Packaged-host lifecycle smoke completed on 2026-04-18 against an actual PKG + launchd install, covering `orchardctl status`, `start`, and `stop`, including non-root status behavior and idempotent start/stop checks. Treat packaged licensing rollout as historically exercised for that release cycle rather than pending a separate active smoke gate.

## Controller Transport Behavior

The packaged controller is certificate-provider-neutral. The PKG does not generate, procure, or trust TLS certificate material by default. Transport mode is resolved at install time (`postinstall`) for diagnostics and at each service start (wrapper boot gate and `config/runtime.exs`) for runtime behavior.

### Mode resolution

| Runtime mode | Condition | Listener |
|------|-----------|----------|
| `plain_http_localhost` | Default when `ORCHARD_TRANSPORT_MODE` is unset and no legacy TLS env selects HTTPS; also explicit `ORCHARD_TRANSPORT_MODE=plain_http_localhost` | HTTP on `127.0.0.1`:`PORT` (degraded local/emergency mode) |
| `direct_https` | `ORCHARD_TRANSPORT_MODE=direct_https`; uses operator-provided `ORCHARD_TLS_CERTFILE`/`ORCHARD_TLS_KEYFILE` or explicit local-CA helper output | HTTPS on `ORCHARD_API_BIND_IP`:`ORCHARD_API_HTTPS_PORT` |
| `reverse_proxy` | `ORCHARD_TRANSPORT_MODE=reverse_proxy`; public HTTPS is terminated by an operator-managed proxy | local/private HTTP backend on `ORCHARD_API_BIND_IP`:`PORT`, default `127.0.0.1:4000` |

Legacy `ORCHARD_TLS_DISABLED`, `ORCHARD_TLS_CERTFILE`, `ORCHARD_TLS_KEYFILE`, and `ORCHARD_TLS_CACERTFILE` are one-release compatibility shims. `ORCHARD_TRANSPORT_MODE` is authoritative when set; inconsistent legacy values emit warnings and are ignored unless structurally invalid.

### Operator deployment modes

Orchard is certificate-provider-neutral. Operators choose how public HTTPS is
terminated; Orchard maps those choices to three runtime modes:

| Operator deployment mode | Runtime mode | Certificate source |
|--------------------------|--------------|--------------------|
| Reverse proxy TLS termination | `reverse_proxy` | Proxy-owned; Orchard reports `unknown` |
| Direct HTTPS with operator cert/key | `direct_https` | `operator_provided` |
| Proprietary or paid CA | `direct_https` | `operator_provided` |
| Internal PKI / air-gapped HTTPS | `direct_https` | `operator_provided` |
| Explicit local CA helper output from `orchardctl tls init` | `direct_https` | `generated_local_ca` |

The PKG installer does **not** procure, generate, or trust production TLS
certificates by default. `orchardctl tls init` remains available as an explicit
local CA / dev-lab bootstrap helper only; it is not a production certificate
provider.

**Invalid configurations that prevent startup:**

- `ORCHARD_TRANSPORT_MODE` set to an unrecognized value
- `ORCHARD_TLS_DISABLED` set to an unrecognized value (not truthy or falsy)
- Only one of `ORCHARD_TLS_CERTFILE` / `ORCHARD_TLS_KEYFILE` set
- Either cert or key override set to an empty string

These exit with code `78` (`EX_CONFIG`) from the wrapper boot gate.

### Validation responsibilities

| Stage | What it checks |
|-------|----------------|
| Wrapper boot gate | File presence and config shape; exits `78` before BEAM starts |
| Runtime (`config/runtime.exs`) | PEM content, cert validity window, key type; warns to stderr if cert expires within 30 days |

### Controller transport environment

All variables are set via `controller.env` or the process environment:

| Variable | Default | Description |
|----------|---------|-------------|
| `ORCHARD_TRANSPORT_MODE` | `plain_http_localhost` | Primary transport mode: `plain_http_localhost`, `direct_https`, or `reverse_proxy` |
| `PORT` | `4000` | HTTP listen port for `plain_http_localhost`; HTTP backend port for `reverse_proxy` |
| `ORCHARD_API_HTTPS_PORT` | `8443` | HTTPS listen port for `direct_https` |
| `ORCHARD_API_BIND_IP` | `0.0.0.0` for `direct_https`; `127.0.0.1` for `reverse_proxy`; ignored for `plain_http_localhost` | Bind IP for the active listener. Non-loopback `reverse_proxy` binds require `ORCHARD_TRUSTED_PROXIES`. |
| `ORCHARD_PUBLIC_HOST` | `localhost` | Browser-visible hostname or IP. **Required when accessing the console from a non-`localhost` host** (e.g. Tailscale IP, domain name). Must match the browser origin exactly. |
| `ORCHARD_PUBLIC_PORT` | `443` | Browser-visible HTTPS port for `reverse_proxy` display URLs and origin checks |
| `ORCHARD_TRUSTED_PROXIES` | loopback only (`127.0.0.1/32`, `::1/128`) | Comma-separated CIDRs allowed to supply `x-forwarded-*` headers in `reverse_proxy` mode |
| `ORCHARD_TLS_CERTFILE` | _(unset)_ | Legacy shim / `direct_https` operator certificate path |
| `ORCHARD_TLS_KEYFILE` | _(unset)_ | Legacy shim / `direct_https` operator private key path |
| `ORCHARD_TLS_CACERTFILE` | _(unset)_ | Optional CA certificate path for generated local CA or operator validation |
| `ORCHARD_TLS_DISABLED` | _(unset)_ | Legacy shim: truthy maps to `plain_http_localhost`; explicit false maps to `direct_https` during compatibility window |
| `ORCHARD_CORS_ORIGINS` | _(empty)_ | Comma-separated CORS origin allowlist (see below) |

Truthy values for `ORCHARD_TLS_DISABLED`: `1`, `true`, `TRUE`, `yes`, `YES`, `on`, `ON`
Falsy values: `0`, `false`, `FALSE`, `no`, `NO`, `off`, `OFF`

Default TLS file paths are relative to `ORCHARD_SUPPORT_ROOT` (default
`/Library/Application Support/Orchard`).

> **⚠️ `ORCHARD_PUBLIC_HOST` must match the browser URL when accessing the
> console from a non-`localhost` host.** Set it to the exact hostname or IP
> that operators type in the browser (e.g. `100.86.198.38` for Tailscale,
> `orchard.local` for mDNS). If left as the default `localhost` and accessed
> from a different host, the console HTML will load but LiveView will stay
> disconnected — data shows "Loading" / "Unknown" with no visible error.
> See [Console troubleshooting](#console-troubleshooting) below.
>
> **Variable roles:**
> - `ORCHARD_PUBLIC_HOST` — the browser-visible hostname (used for URL
>   generation and LiveView websocket origin checks)
> - `ORCHARD_API_BIND_IP` — the network interface the active listener binds
>   (`direct_https` default `0.0.0.0`; `reverse_proxy` default `127.0.0.1`)
> - `ORCHARD_API_HTTPS_PORT` — the direct-HTTPS port (default `8443`)
> - `ORCHARD_PUBLIC_PORT` — the reverse-proxy public HTTPS port (default `443`)
> - `PORT` — HTTP port for `plain_http_localhost` or the `reverse_proxy` backend
> - `ORCHARD_TRUSTED_PROXIES` — trusted proxy CIDRs for non-loopback
>   reverse-proxy deployments

## Reverse Proxy TLS Termination

Use `reverse_proxy` when nginx, Caddy, Traefik, a load balancer, or an operator-managed edge proxy owns public HTTPS. Orchard listens on HTTP behind that proxy and trusts forwarded headers only from configured proxy CIDRs.

Minimal `controller.env` for a loopback proxy on the same Mac:

```bash
ORCHARD_TRANSPORT_MODE=reverse_proxy
ORCHARD_API_BIND_IP=127.0.0.1
PORT=4000
ORCHARD_PUBLIC_HOST=orchard.example.com
ORCHARD_PUBLIC_PORT=443
```

If the proxy reaches Orchard over a non-loopback network interface, set both the backend bind and trusted proxy CIDRs:

```bash
ORCHARD_TRANSPORT_MODE=reverse_proxy
ORCHARD_API_BIND_IP=10.0.0.10
PORT=4000
ORCHARD_PUBLIC_HOST=orchard.example.com
ORCHARD_TRUSTED_PROXIES=10.0.0.20/32
```

Without `ORCHARD_TRUSTED_PROXIES`, non-loopback reverse-proxy backend binds fail closed. Spoofed `x-forwarded-*` headers from untrusted clients are stripped and do not affect scheme, host, port, or client IP handling.

### nginx example

```nginx
server {
    listen 443 ssl http2;
    server_name orchard.example.com;

    ssl_certificate     /etc/ssl/orchard/fullchain.pem;
    ssl_certificate_key /etc/ssl/orchard/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Port 443;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

### Caddy example

```caddyfile
orchard.example.com {
    reverse_proxy 127.0.0.1:4000 {
        header_up Host {host}
        header_up X-Forwarded-Host {host}
        header_up X-Forwarded-Proto https
        header_up X-Forwarded-Port 443
    }
}
```

Caddy can manage public ACME certificates or use operator-provided certificates with `tls /path/to/fullchain.pem /path/to/privkey.pem`.

### Traefik example

```yaml
http:
  routers:
    orchard:
      rule: Host(`orchard.example.com`)
      entryPoints: [websecure]
      tls: {}
      service: orchard
  services:
    orchard:
      loadBalancer:
        servers:
          - url: http://127.0.0.1:4000
```

Configure Traefik certificate resolvers, file certificates, or internal PKI outside Orchard. Orchard does not inspect or publish proxy-owned certificate material.

## CORS Allowlist Configuration

CORS is **disabled by default**. When `ORCHARD_CORS_ORIGINS` is empty or
unset, the controller does not add any CORS response headers.

To allow browser-based clients from specific origins, set a comma-separated
allowlist in `controller.env`:

```bash
sudo tee '/Library/Application Support/Orchard/config/controller.env' <<'EOF'
ORCHARD_PUBLIC_HOST=orchard.local
ORCHARD_CORS_ORIGINS=https://app.example.com,https://admin.example.com:3000
EOF
sudo chmod 600 '/Library/Application Support/Orchard/config/controller.env'
```

### Origin validation rules

Each origin is validated at controller boot. Invalid origins abort startup.

**Required:**
- Scheme must be `http` or `https`
- Must include a host

**Rejected:**
- `*` (wildcard)
- `null`
- Trailing slash (e.g., `https://app.example.com/`)
- Path component (e.g., `https://app.example.com/api`)
- Query string, fragment, or userinfo

### CORS response behavior

- **Empty allowlist:** no CORS headers on any request (no-op)
- **Allowed origin:** `Access-Control-Allow-Origin` set to the request origin;
  `x-request-id` exposed
- **Allowed preflight** (`OPTIONS` with `Origin` and
  `Access-Control-Request-Method`): responds `204 No Content` with allowed
  methods (`GET`, `POST`, `OPTIONS`) and halts
- **Disallowed origin:** no CORS headers added; request continues normally

## LAN Client Trust and `/ca.crt`

When using the explicit local CA / dev-lab bootstrap helper
(`orchardctl tls init`), the controller can expose that generated CA
certificate for LAN client trust bootstrap:

```
GET /ca.crt
```

This endpoint serves the CA PEM file **only when all of the following are
true:**

- The endpoint is configured with `ca_certfile` and `ca_cert_metadata_path`
- The TLS metadata file exists and contains valid JSON
- The metadata `"source"` field is exactly `"generated_local_ca"`
- The runtime certificate source is `generated_local_ca`
- The CA certificate file is readable

All other cases return `404`. This includes operator-provided certificate
paths, operator-provided CA certificates, internal PKI roots, proprietary or
public CA bundles, missing metadata, and broken local-CA helper state. Orchard
publishes only the CA generated by `orchardctl tls init` metadata and does not
publish operator-provided CA or certificate material from `/ca.crt`.

### Operator workflow

1. **Install Orchard** — the PKG installer does not generate TLS material
2. **Create local CA helper TLS** when desired for dev-lab or local evaluation:
   ```bash
   sudo orchardctl tls init --no-trust
   ```
3. **Trust CA on the Orchard host** (optional):
   ```bash
   sudo orchardctl tls trust-ca
   ```
4. **Distribute CA to LAN clients** — either download from the running
   controller:
   ```bash
   curl -k -o orchard-ca.crt https://<controller-host>:8443/ca.crt
   ```
   or copy `config/tls/ca.crt` out-of-band
5. **Install the CA on each client** according to the client OS/browser trust
   store procedures
6. **Verify access:**
   ```bash
   curl --cacert orchard-ca.crt https://<controller-host>:8443/health/ready
   ```

> **External certificate deployments** should distribute trust through their
> own CA/PKI workflow. The `/ca.crt` endpoint is not served for externally
> managed certificates.

### Certificate regeneration

To regenerate local generated certificates (e.g., after hostname change or expiry):

```bash
sudo orchardctl tls init --force
sudo launchctl kickstart -k system/com.orchard.controller
```

Add `--no-trust` to skip the interactive Keychain trust prompt. LAN clients
will need the new CA after regeneration.

## Console Troubleshooting

### Console loads but data stays "Loading" / "Unknown"

**Symptom:** The console shell and sidebar render, but all data tiles show
"Loading", readiness checks show "Unknown", and the connection banner may
appear: *"Live connection lost — reconnecting. Displayed data may be stale."*

**Cause:** `ORCHARD_PUBLIC_HOST` does not match the hostname/IP in the browser
URL. Phoenix rejects the LiveView websocket connection because the `Origin`
header doesn't match the configured public host.

**Diagnosis:** Open the browser console (F12) and run:

```js
window.liveSocket.isConnected()   // expected: true; if false, origin mismatch
window.liveSocket.getSocket().connectionState()  // "connecting" = stuck
```

**Fix:**

1. Set `ORCHARD_PUBLIC_HOST` in `controller.env` to the exact host used in the
   browser (e.g. `100.86.198.38` for Tailscale, `orchard.local` for mDNS).
2. Restart the controller: `sudo launchctl kickstart -k system/com.orchard.controller`
3. If using local generated TLS and the hostname changed, regenerate certificates:
   `orchardctl tls init --force` then restart again.

### Basic Auth credentials persist in browser URL

**Symptom:** After entering Basic Auth credentials, the browser URL shows
`https://user:pass@host:8443/console`.

**Fix:** The controller now redirects after successful Basic Auth to strip
credentials from the URL automatically. If you see this on an older version,
navigate to the clean URL manually after authenticating — the session cookie
persists.

## Permission Expectations

### Directories

| Path | Mode | Owner | Group | Set by | Purpose |
|------|------|-------|-------|--------|---------|
| `config/` | `0750` | `root` | `admin` | preinstall, postinstall | Admin group read/traverse; secrets protected via file perms |
| `config/tls/` | `0750` | `root` | `admin` | preinstall, postinstall | Admin group read/traverse for TLS verification |
| `logs/` | `0755` | `root` | `wheel` | preinstall, postinstall | World-readable logs for troubleshooting |

**Note**: The `admin` group (GID 80) is the standard macOS administrator group.
Most developer accounts are members. This allows `orchardctl` CLI to function for
admin users while keeping secrets protected.

### TLS files

| File | Mode | Set by |
|------|------|--------|
| `ca.key` | `0600` | `orchardctl tls init` |
| `ca.crt` | `0644` | `orchardctl tls init` |
| `controller.key` | `0600` | `orchardctl tls init` |
| `controller.crt` | `0644` | `orchardctl tls init` |
| `.orchard-tls-meta.json` | `0644` | `orchardctl tls init` |

### Env files

Env override files (`controller.env`, `node-agent.env`) must be:

- Owned by root (uid `0`)
- Free of group and world permission bits (recommended: `0600`)

Files that fail these checks are **ignored with a warning** to stderr. The
service starts without the overrides. This is a security measure — env files
are sourced by root-owned shell scripts, so untrusted files are not executed.

## TLS Certificate Management

The installer does not run `orchardctl tls init` automatically. Use
`orchardctl tls init` explicitly only as a local CA / dev-lab bootstrap helper
for direct HTTPS. It is not the default production TLS path.

### Installer behavior

### Fresh install (no prior Orchard):
1. `preinstall` creates `config/tls/` directory (mode `0750` root:admin - admin group accessible)
2. `postinstall` detects empty TLS state, prints operator guidance, and
   continues without running `orchardctl tls init`
3. To create local CA helper TLS, run `sudo orchardctl tls init --no-trust`
   after install
4. Removes any stale unsupported managed PostgreSQL LaunchDaemon early and does not bootstrap managed PostgreSQL; role-selected controller/node-agent services must be started manually via `sudo orchardctl start`

**Upgrade (existing install):**
- Preserves existing managed TLS files (no overwrite, no regeneration)
- If no TLS files exist (upgrading from pre-TLS version), prints operator
  guidance and continues without generating them
- Partial TLS state (some files missing) **aborts the install** with a
  clear error listing which files are present/missing
- **Services are stopped during upgrade and NOT auto-restarted** — run
  `sudo orchardctl start` after upgrade to restore services

### Transport modes

The installer and controller wrapper resolve transport from `ORCHARD_TRANSPORT_MODE`, with legacy TLS variables accepted only as one-release compatibility shims:

| Mode | Condition | Installer behavior |
|------|-----------|--------------------|
| `plain_http_localhost` | Default with no transport/TLS env, or explicit `ORCHARD_TRANSPORT_MODE=plain_http_localhost` | Skip managed TLS inspection; controller runs degraded HTTP on loopback |
| `direct_https` | `ORCHARD_TRANSPORT_MODE=direct_https` | Use operator cert/key env vars or explicit local generated TLS; validate configured files |
| `reverse_proxy` | `ORCHARD_TRANSPORT_MODE=reverse_proxy` | Skip managed TLS inspection; public HTTPS terminates at the operator-managed proxy |

Legacy shims:
- `ORCHARD_TLS_DISABLED=true` maps to `plain_http_localhost` when `ORCHARD_TRANSPORT_MODE` is unset.
- `ORCHARD_TLS_DISABLED=false` maps to `direct_https` managed-default behavior when `ORCHARD_TRANSPORT_MODE` is unset.
- `ORCHARD_TLS_CERTFILE` / `ORCHARD_TLS_KEYFILE` map to `direct_https` operator-provided certs when `ORCHARD_TRANSPORT_MODE` is unset.

**Invalid configurations that abort install/startup:**
- `ORCHARD_TRANSPORT_MODE` set to an unrecognized value
- Only one of `ORCHARD_TLS_CERTFILE` / `ORCHARD_TLS_KEYFILE` set
- `ORCHARD_TLS_DISABLED` set to unrecognized value

### Controller wrapper TLS boot gate

The `orchard-controller` wrapper validates TLS file presence **before**
exec'ing the BEAM release. This catches file drift (e.g., deleted certs)
during launchd restarts without waiting for the BEAM boot to fail.

- `direct_https` with local-CA helper output: requires `controller.crt`,
  `controller.key`; warns if `ca.crt` is missing
- `direct_https` with operator cert/key paths: requires configured cert/key
  files; requires CA cert if `ORCHARD_TLS_CACERTFILE` is set
- `reverse_proxy` and `plain_http_localhost`: skip TLS file checks
- Exit code `78` (`EX_CONFIG`) on configuration errors

### TLS env vars

See the consolidated [Controller transport environment](#controller-transport-environment)
table above for all TLS, transport, and CORS variables with defaults and
truthy/falsy value lists.

### Direct HTTPS with operator certificates

Use this for direct controller HTTPS with public, paid/proprietary, or internal
PKI certificates. Orchard validates the configured files but does not procure,
renew, publish, or distribute operator CA/cert material.

```bash
sudo tee '/Library/Application Support/Orchard/config/controller.env' <<'EOF'
ORCHARD_TRANSPORT_MODE=direct_https
ORCHARD_PUBLIC_HOST=orchard.example.com
ORCHARD_TLS_CERTFILE=/path/to/server.crt
ORCHARD_TLS_KEYFILE=/path/to/server.key
ORCHARD_TLS_CACERTFILE=/path/to/ca.crt
EOF
sudo chmod 600 '/Library/Application Support/Orchard/config/controller.env'
```

For internal PKI or air-gapped environments, distribute the issuing CA through
operator-owned device management, browser, OS trust-store, or application trust
configuration. `/ca.crt` remains disabled for these deployments.

### Recovery from partial TLS state

If the installer fails due to partial managed TLS state:

```bash
# Option 1: Remove all TLS files and reinstall
sudo rm -f '/Library/Application Support/Orchard/config/tls/'*
# Then rerun the PKG installer

# Option 2: Manually regenerate
sudo orchardctl tls init --no-trust
sudo orchardctl tls trust-ca  # optional: trust CA in Keychain
```

### Install context markers

The installer writes role and diagnostic markers under `support/`:

| File | Purpose | Lifecycle |
|------|---------|-----------|
| `.install-role.request` | Transient: requested install role (`all`, `controller`, `node-agent`) | Created by the operator before install, removed on postinstall success |
| `.install-role` | Persistent: selected install role and lifecycle source of truth | Atomically written on postinstall success, preserved on upgrades unless a new request is seeded |
| `.pkg-install-context` | Transient: install mode (fresh/upgrade) | Written by preinstall, removed on postinstall success |
| `.pkg-install-complete` | Persistent: last successful install timestamp | Written on postinstall success, never auto-removed |

## Service Bootstrap

Postinstall installs the `orchard-managed-postgres` guard into the support root,
but does **not** expose it on PATH, install its LaunchDaemon, or bootstrap
managed PostgreSQL. It removes any stale `com.orchard.postgres.plist` before
later validation so unsupported managed PostgreSQL state is cleaned up even if
the install aborts. Controller and node-agent services are **not auto-started**
during install to allow proper configuration first. `sudo orchardctl start`
starts the services selected by the installed role.

Optionally seed `.install-role.request` before installing the PKG (omit for
default `all`). After install, use this first-run sequence for
controller-bearing installs (`all` or `controller`):

1. Provide or verify the Orchard license through the supported licensing path;
   do not place license keys in shell history, logs, package payloads, or
   command arguments.
2. Run `sudo orchardctl env init --service controller` for controller-only hosts, or `sudo orchardctl env init --service all` for all-in-one hosts.
3. Edit `controller.env` with external `DATABASE_URL`, the generated or deliberately rotated `SECRET_KEY_BASE`, BEAM Runtime Endpoint targets, BEAM cookie path, and transport settings.
4. Run `sudo orchardctl migrate`.
5. Run `sudo orchardctl cluster init --output /secure/path/bootstrap-admin.json`.
   This mints the first cluster-admin API Client credential as One-time Secret Output.
6. Run `sudo orchardctl transport enable-local-https --host HOST` for the local
   generated-CA direct HTTPS path, or configure an operator-managed direct HTTPS
   certificate/reverse-proxy transport before starting services.
7. Optional, when browser Console access is desired: run
   `sudo orchardctl console enable` and enter credentials only through the
   interactive prompt.
8. Run `sudo orchardctl start`.
9. Verify with `orchardctl status`.

Before making public `/v1` API calls, create an Organization and API Token.
Tenant-direct API Tokens remain supported for manual/bootstrap use and the token is printed once:

```bash
sudo orchardctl tenants create --slug default --name "Default"
sudo orchardctl api-keys create --tenant-id <tenant-id> --name "Primary"
```

For internal developers, applications, coding agents, or automation clients, use bulk API Client provisioning instead:

```bash
sudo orchardctl api-clients bulk-provision --dry-run --file /path/to/api-clients.csv
sudo orchardctl api-clients bulk-provision --apply --file /path/to/api-clients.csv --output /secure/path/api-client-tokens.csv
```

The input CSV requires `organization`, `api_client`, `owner_contact`, and `key_name`.
The output CSV is One-time Secret Output containing the new API Tokens.

For `node-agent` role installs, run `sudo orchardctl env init --service node-agent`, fill in `node-agent.env` with `ORCHARD_BEAM_NODE_NAME`, `ORCHARD_BEAM_COOKIE_FILE`, EPMD/distribution ports, node display name, and worker settings, then run `sudo orchardctl start` and verify with `orchardctl status`.
The generated gRPC listener starts on loopback and is only for compatibility/fallback mode.
Change it to a private interface address or `0.0.0.0` only when explicitly using `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT="grpc"` and the node-agent Mac is protected by a trusted private network or VPN and firewall rules.

`orchardctl cluster init` mints the first cluster-admin API Client credential as
a local, one-shot, audited controller-host operation after migrations are
applied. It requires a `--output` One-time Secret Output path (the token is
written only to that file, never stdout), refuses a second init with
`cluster_already_initialized`, and supports `--force-new-admin --yes` recovery
minting, `--client-name`, and `--json`. It is credential-only: TLS material and
role/service setup remain separate, and `postinstall` never seeds admin
credentials.

`orchardctl nodes enrollment create --output PATH` creates an owner-only,
single-Node Enrollment bundle on the active controller host.
Transfer that bundle through an operator-controlled secure channel, then run
`orchardctl node join --enrollment-bundle PATH` on the node-agent host.
The joined Node remains non-schedulable until an operator reviews and explicitly
admits it with the existing pending-admission commands.

`orchardctl requests inspect <request-id>` reads the local controller Repo and
renders the persisted scheduler explanation for a request, with stable human and
`--json` output from the shared Operator API presenter; broader request
execution diagnostics beyond persisted scheduler explanations remain future
work. `orchardctl support bundle create` creates a local
diagnostic `.tar.gz` with bounded redacted logs, redacted config, service
status, node snapshots, and request summaries. It records
`support_bundle.generated` when the controller Repo is available. Archives are
written to `/Library/Application Support/Orchard/support/` by default; use
`--output`, `--support-root`, `--max-log-bytes`, and `--json` when support
needs a different destination, alternate state tree, tighter log bound, or
machine-readable output. Use `orchardctl status`, readiness output, service
logs, support bundles, and the troubleshooting tables in this runbook for
current packaged diagnostics.

### Advanced migration fallback

Use `sudo orchardctl migrate` for normal installs and upgrades. If directed by
Orchard support to bypass the CLI migration wrapper while troubleshooting, the
underlying release command is:

```bash
sudo "/Library/Application Support/Orchard/bin/orchard-controller" eval 'Orchard.Release.migrate()'
```

## Responsibilities

- Package Orchard releases into install paths under `/Library/Application Support/Orchard/`
- Install wrapper commands into `/Library/Application Support/Orchard/bin/`,
  including the operator-safe managed Postgres guard
- Expose `orchardctl` via `/usr/local/bin/orchardctl`
- Install role-selected launchd plists under `/Library/LaunchDaemons/` and tray LaunchAgent under `/Library/LaunchAgents/`
- Exclude the managed Postgres LaunchDaemon and remove stale unsupported copies during postinstall
- Leave TLS generation to explicit post-install `sudo orchardctl tls init --no-trust`
- Validate TLS state before bootstrapping `direct_https` services
- Detect fresh install vs upgrade and write diagnostic markers

## Building the PKG

Orchard includes a build script at `scripts/build-pkg.sh` that automates the complete PKG creation process.

### Quick Build

```bash
mise exec -- ./scripts/build-pkg.sh
```

This produces a PKG file following the [naming convention below](#filename-format) in:
```
./artifacts/pkg-builds/YYYY-MM-DD/Orchard-<version>-<date>-<sha>.pkg
```

### Build Options

The script exports `ORCHARD_BUILD_CHANNEL=trial` when the variable is unset. If `ORCHARD_BUILD_CHANNEL=dev`, the PKG build fails before release assembly because distributed packages must not ship with source-dev enforcement defaults.

| Flag | Purpose |
|------|---------|
| `--clean` | Deep clean: removes `_build/` and `deps/` before building (slow, but maximally reproducible) |
| `--allow-dirty` | Supported dev-build escape hatch when your tree is not clean (adds `-dirty` to the git SHA segment) |
| `--stage-only` | Stage the payload, verify Python venv closure, optionally payload-sign Mach-O files, print `STAGING_BASE=<path>`, and skip `pkgbuild` |
| `output_dir` | Custom output directory (default: `./artifacts/pkg-builds/YYYY-MM-DD/`) |

### Source Exposure Posture

Current PKG builds use a bytecode/deterrence posture.
Elixir components ship as releases and native helpers are staged through non-editable packaging virtualenv entrypoints.
The build script verifies that duplicate native helper source trees are not staged under `native/orchard_tokenizer/src`, `native/orchard_tokenizer/tests`, `native/orchard_worker_mlx/src`, `native/orchard_worker_mlx/tests`, or `native/orchard_worker_mlx/proto`.
This reduces obvious payload source exposure, but it does not provide compiled source protection.
Compiled protection and stronger obfuscation remain later release-hardening targets.

### Dev PKG path (no signing/notarization/stapling)

Use the same scripted packaging path, with `--allow-dirty` when needed:

```bash
mise exec -- ./scripts/build-pkg.sh --allow-dirty
```

This is the supported development PKG lane: same staging, payload checks,
scripted `pkgbuild`, and layout validation as the standard build. It does not
add a separate `--dev` mode.

After build/install, use the role request-file workflow from
[Install Role Selection](#install-role-selection) (`.install-role.request`)
rather than environment-variable installer overrides.

### Build Requirements

Before building:
1. **Repo setup**: Run `make setup` from the repo root, or run the equivalent
   manual setup commands from `docs/local-dev.md`. This installs the pinned
   mise toolchain, bootstraps the mise-owned Hex/Rebar installs, fetches Elixir
   deps, syncs native Python packages, and installs root npm tool/asset pins.
2. **Build shell**: Run builds through `mise exec -- ./scripts/build-pkg.sh`.
3. **Git**: Clean working tree recommended (use `--allow-dirty` if needed)
4. **macOS**: PKG build only works on macOS (uses `pkgbuild`)
5. **No dev server running**: Ports 4000/50071 should be free (warns if in use)

### Manual packaging fallback (`pkgbuild`)

If scripted behavior drifts or you need operator-level debugging, use a direct
`pkgbuild` fallback with the same root/scripts structure as `build-pkg.sh`:

```bash
pkgbuild \
  --root /tmp/orchard-pkg-build-<pid> \
  --scripts "$PWD/packaging/pkg/scripts" \
  --identifier com.orchard.pkg \
  --version <app_version> \
  --install-location / \
  /tmp/Orchard-<version>-<date>-<sha>.pkg
```

Keep staged ownership/modes equivalent to the script (root-owned payload paths,
launchd plists `0644`, wrappers `0755`) and use the same role request-file
contract in [Install Role Selection](#install-role-selection) before installing
the fallback PKG.

**Note:** Prefer `mise exec -- ./scripts/build-pkg.sh` for normal operation; it
also validates staging/payload layout and writes checksums.

## Signing and notarization

`scripts/build-pkg.sh` produces a PKG whose installer envelope is unsigned.
Distribution envelope signing and notarization are an explicit second step
performed with `scripts/sign-pkg.sh`; neither script selects a local signing
identity by default.

### Payload signing

Notarizable distribution builds require two different Apple Developer ID
certificate types:

- **Developer ID Application** signs nested Mach-O payload files with
  `ORCHARD_PAYLOAD_SIGNING_IDENTITY` during `scripts/build-pkg.sh`.
- **Developer ID Installer** signs the outer PKG envelope with
  `ORCHARD_PKG_SIGNING_IDENTITY` during `scripts/sign-pkg.sh`.

Set `ORCHARD_PAYLOAD_SIGNING_IDENTITY` before building to run
`scripts/sign-payload.sh` over the staged payload. The signer walks the staging
tree without following symlinks, signs libraries before executables, enables the
hardened runtime, requests a secure timestamp, and writes an optional signing
manifest next to the unsigned PKG when `pkgbuild` succeeds. If the payload
identity is unset, the build continues for development/internal testing but logs
that the resulting PKG cannot be notarized.

Payload entitlements live in `packaging/pkg/entitlements/`:

| File | Applies to | Exceptions |
|------|------------|------------|
| `beam.entitlements` | `beam.smp` in bundled ERTS releases | `com.apple.security.cs.allow-jit` |
| `python.entitlements` | Python venv interpreters and executable venv tools | `com.apple.security.cs.allow-unsigned-executable-memory` |
| `default.entitlements` | Other Mach-O libraries and executables | Empty entitlement dictionary; hardened runtime still comes from `codesign --options runtime` |

`scripts/sign-pkg.sh` expands the input PKG and runs
`scripts/verify-payload-signing.sh` before `productsign`. It refuses to
envelope-sign a PKG whose nested Mach-O files are unsigned, missing hardened
runtime, missing secure timestamps, or signed by a different Developer ID
Application identity.

Prerequisites:

1. Apple Xcode Command Line Tools or Xcode are installed so `codesign`,
   `productsign`, `xcrun notarytool`, and `xcrun stapler` are available.
2. Developer ID certificates for the Orchard developer account are installed in
   the signing keychain:
   - 2a. **Developer ID Installer** for the outer PKG envelope.
   - 2b. **Developer ID Application** for nested Mach-O payload files.
3. A notarytool keychain profile has been created, for example:
   ```bash
   xcrun notarytool store-credentials orchard-notary
   ```

End-to-end distribution flow:

```bash
export ORCHARD_PAYLOAD_SIGNING_IDENTITY='Developer ID Application: Example, Inc. (TEAMID)'
export ORCHARD_PKG_SIGNING_IDENTITY='Developer ID Installer: Example, Inc. (TEAMID)'
export ORCHARD_NOTARYTOOL_PROFILE=orchard-notary

mise exec -- ./scripts/build-pkg.sh

UNSIGNED_PKG="$(ls -t artifacts/pkg-builds/*/Orchard-*.pkg | grep -v -- '-signed\.pkg$' | head -1)"
SIGNED_PKG="${UNSIGNED_PKG%.pkg}-signed.pkg"

scripts/sign-pkg.sh \
  --input "$UNSIGNED_PKG" \
  --output "$SIGNED_PKG"
```

`sign-pkg.sh` signs the installer envelope, submits the signed PKG to Apple
notarization, waits for an `Accepted` result, staples the ticket, and writes the
final SHA-256 plus notary evidence.

The same signing and notarization values can be supplied as flags instead of
environment variables:

```bash
export ORCHARD_PAYLOAD_SIGNING_IDENTITY='Developer ID Application: Example, Inc. (TEAMID)'

mise exec -- ./scripts/build-pkg.sh

scripts/sign-pkg.sh \
  --identity 'Developer ID Installer: Example, Inc. (TEAMID)' \
  --notary-profile orchard-notary \
  --input artifacts/pkg-builds/YYYY-MM-DD/Orchard-<version>-<date>-<sha>.pkg \
  --output artifacts/pkg-builds/YYYY-MM-DD/Orchard-<version>-<date>-<sha>-signed.pkg
```

For release rehearsals or CI wiring checks without contacting Apple services:

```bash
ORCHARD_PAYLOAD_SIGNING_IDENTITY='Developer ID Application: Example, Inc. (TEAMID)' \
scripts/sign-pkg.sh --dry-run \
  --identity 'Developer ID Installer: Example, Inc. (TEAMID)' \
  --notary-profile orchard-notary \
  --input /tmp/Orchard.pkg \
  --output /tmp/Orchard-signed.pkg
```

The script writes:

- `Orchard-<version>-<date>-<sha>-signed.pkg`
- `Orchard-<version>-<date>-<sha>-signed.pkg.sha256`
- `Orchard-<version>-<date>-<sha>-signed.pkg.notary.json`

Copy the SHA-256 and notary submission ID/status into the release manifest.

Verify the signed package before distribution:

```bash
TMP="$(mktemp -d)"
pkgutil --expand-full Orchard-<version>-<date>-<sha>-signed.pkg "$TMP/expanded"
scripts/verify-payload-signing.sh \
  --identity "$ORCHARD_PAYLOAD_SIGNING_IDENTITY" \
  "$TMP/expanded"
rm -rf "$TMP"

pkgutil --check-signature Orchard-<version>-<date>-<sha>-signed.pkg
spctl -a -t install -vv Orchard-<version>-<date>-<sha>-signed.pkg
xcrun stapler validate Orchard-<version>-<date>-<sha>-signed.pkg
shasum -a 256 Orchard-<version>-<date>-<sha>-signed.pkg
```

Keep signing credentials, App Store Connect credentials, notary profile
secrets, activation keys, and customer identifiers out of package payloads,
casks, deployment scripts, logs, and documentation examples.

## Potential Homebrew Cask

Homebrew cask distribution is not a v1 packaging requirement.
If Orchard later adds a private tap or convenience cask, it should install the same signed and notarized PKG used for direct downloads.
The cask should pin the exact SHA-256 of the signed PKG and must not embed license keys, customer names, organization identifiers, or other customer-specific material.

Example future cask shape:

```ruby
cask "orchard" do
  version "0.5.0"
  sha256 "<signed-pkg-sha256>"

  url "https://downloads.example.com/orchard/Orchard-#{version}-20260427-abcdef0-signed.pkg"
  name "Orchard"
  desc "On-prem LLM orchestration platform for Apple Silicon macOS"
  homepage "https://example.com/orchard"

  pkg "Orchard-#{version}-20260427-abcdef0-signed.pkg"

  uninstall launchctl: [
              "com.orchard.controller",
              "com.orchard.node-agent",
            ],
            pkgutil: "com.orchard.pkg",
            delete: [
              "/Library/Application Support/Orchard/bin/orchardctl",
              "/Library/Application Support/Orchard/bin/orchard-controller",
              "/Library/Application Support/Orchard/bin/orchard-node-agent",
              "/Library/Application Support/Orchard/bin/orchard-managed-postgres",
              "/Library/LaunchDaemons/com.orchard.controller.plist",
              "/Library/LaunchDaemons/com.orchard.node-agent.plist",
            ]

  zap trash: [
    "/Library/Application Support/Orchard/logs",
  ]
end
```

If this channel is added later, install from the tap according to the tap's access policy, then activate out of band:

```bash
brew install --cask <private-tap>/orchard/orchard
sudo orchardctl license activate --key-file /path/to/orchard-license-key
```

Activation remains a separate operator step because evaluator/customer identity
lives in the license service and local activation bundle, not in the package or
Homebrew cask.

## Managed Device Deployment

Jamf and MDM deployment are not v1 packaging requirements.
If they become real customer requirements later, add a dedicated change with acceptance criteria for managed-device policy ordering, secret handling, activation, and logging.

The distribution artifact remains generic across current and future channels.
Evaluator/customer attribution and limits are enforced by license activation and Keygen policy/license records.

## PKG Filename Policy

Orchard PKG releases follow a structured naming convention to minimize user
confusion while preserving build traceability.

### Filename Format

```
Orchard-<app_version>-<YYYYMMDD>-<git_sha7>.pkg
```

There is no separate "dev" filename marker. Development builds use the same
format; when `--allow-dirty` is used, `-dirty` is appended to the git-SHA
segment only.

| Component | Example | Purpose |
|-----------|---------|---------|
| `app_version` | `0.5.0-dev` | Matches `orchardctl status` output |
| `YYYYMMDD` | `20260417` | Build date (chronological sorting) |
| `git_sha7` | `e152300` | Traceability for debug/support |

### Example

```
Orchard-0.5.0-dev-20260417-e152300.pkg
```

### Key Principles

1. **App version first**: Users see `0.5.0-dev` in both filename and `orchardctl status`
2. **Date for sorting**: Chronological ordering when multiple builds exist
3. **Git hash last**: Developer/support traceability without user confusion
4. **Hyphen separators**: Tooling-friendly for URLs, shell scripts, and release automation

### Version Mismatch Clarification

The **PKG filename version** (e.g., `0.5.0-dev`) refers to the Orchard application
version inside the package. This is the version reported by:
- `orchardctl status`
- `/health/ready` API endpoint
- `Orchard.version/0` function

This is distinct from packaging iteration numbers (previously used `v0.2.1`
etc.) which caused confusion when the PKG claimed one version but the app
reported another.

### Local Automation

For local package automation:

- Use the full traceable filename for internal tracking
- Consider a symlink or alias `Orchard-latest-dev.pkg` for automation
- Checksum verification is recommended for security

### Historical Note

Earlier PKG iterations used divergent versioning (PKG `v0.2.1` containing
app `v0.5.0-dev`). This was corrected in the 0.5.0 release cycle to align
with the policy above.
