# PKG skeleton

Milestone 0 packaging placeholder for Orchard enterprise/unattended installs.

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
not currently ship a managed Postgres runtime — the `orchard-managed-postgres`
wrapper is a placeholder that exits with an error.

Before starting the controller for the first time:

1. Ensure PostgreSQL is running and accessible from the host.
2. Create a database for the controller (e.g. `orchard_controller`).
3. Create `controller.env` with the required variables (see below).
4. Run release migrations (see below).

## Env File Overrides

Wrapper scripts (`bin/orchard-node-agent`, `bin/orchard-controller`) source
optional env files before starting the BEAM release:

| Service | Env File |
|---------|----------|
| node-agent | `/Library/Application Support/Orchard/config/node-agent.env` |
| controller | `/Library/Application Support/Orchard/config/controller.env` |

Format: plain `KEY=value` lines. Comments (`#`) and blank lines are fine.

Primary use case: operational rollback of the worker backend without editing
launchd plists or global environment.

```bash
# Example: rollback to stub backend
echo 'ORCHARD_WORKER_BACKEND=stub' | sudo tee \
  '/Library/Application Support/Orchard/config/node-agent.env'
sudo launchctl kickstart -k system/com.orchard.node-agent
```

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

The `config/` directory is set to mode `0700` by the installer, so only root
can create or modify files within it.

### Controller env file lifecycle

**Fresh install:** The installer does not create `controller.env`. The operator
must create it before the controller can start successfully in prod mode:

```bash
sudo tee '/Library/Application Support/Orchard/config/controller.env' >/dev/null <<'EOF'
DATABASE_URL=postgres://USER:PASSWORD@HOST:5432/DB_NAME
SECRET_KEY_BASE=<generate-with-mix-phx-gen-secret>
EOF
sudo chown root:wheel '/Library/Application Support/Orchard/config/controller.env'
sudo chmod 600 '/Library/Application Support/Orchard/config/controller.env'
```

Then run migrations:

```bash
sudo /Library/Application\ Support/Orchard/bin/orchard-controller eval 'Orchard.Release.migrate()'
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
| Readiness reports `migrations_current: false` (with DB reachable) | Migrations not run | Run `sudo "/Library/Application Support/Orchard/bin/orchard-controller" eval 'Orchard.Release.migrate()'` |
| `WARNING: ignoring env file` in controller.log | File not root-owned or has group/world permission bits | `sudo chown root:wheel <file> && sudo chmod 600 <file>` |

## Controller Transport Behavior

The packaged controller defaults to **HTTPS**. Transport mode is resolved
at both install time (`postinstall`) and each service start (wrapper boot gate
and `config/runtime.exs`).

### Mode resolution

| Mode | Condition | Listener |
|------|-----------|----------|
| `managed_default` | No cert/key overrides, or overrides match managed defaults | HTTPS on `ORCHARD_API_BIND_IP`:`ORCHARD_API_HTTPS_PORT` |
| `external_override` | Both `ORCHARD_TLS_CERTFILE` and `ORCHARD_TLS_KEYFILE` set to non-default paths | HTTPS on `ORCHARD_API_BIND_IP`:`ORCHARD_API_HTTPS_PORT` |
| `disabled` | `ORCHARD_TLS_DISABLED` set to a truthy value | HTTP on `127.0.0.1`:`PORT` (loopback only) |

**Invalid configurations that prevent startup:**

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
| `ORCHARD_API_HTTPS_PORT` | `8443` | HTTPS listen port |
| `ORCHARD_API_BIND_IP` | `0.0.0.0` | HTTPS bind IP address |
| `ORCHARD_PUBLIC_HOST` | `localhost` | Browser-visible hostname or IP. **Required when accessing the console from a non-`localhost` host** (e.g. Tailscale IP, domain name). Must match the browser origin exactly. |
| `PORT` | `4000` | HTTP port (only used when TLS is disabled) |
| `ORCHARD_TLS_CERTFILE` | `config/tls/controller.crt` | Server certificate path |
| `ORCHARD_TLS_KEYFILE` | `config/tls/controller.key` | Server private key path |
| `ORCHARD_TLS_CACERTFILE` | `config/tls/ca.crt` | CA certificate path (for `/ca.crt` endpoint and validation) |
| `ORCHARD_TLS_DISABLED` | `false` | Set to a truthy value for emergency loopback HTTP mode |
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
> - `ORCHARD_API_BIND_IP` — the network interface the server listens on
>   (default `0.0.0.0` = all interfaces)
> - `ORCHARD_API_HTTPS_PORT` — the HTTPS port (default `8443`)
> - `PORT` — HTTP port, only used in emergency TLS-disabled mode

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

When using managed TLS (the default), the controller exposes its CA
certificate for LAN client trust bootstrap:

```
GET /ca.crt
```

This endpoint serves the CA PEM file **only when all of the following are
true:**

- The endpoint is configured with `ca_certfile` and `ca_cert_metadata_path`
- The TLS metadata file exists and contains valid JSON
- The metadata `"source"` field is exactly `"generated_local_ca"`
- The CA certificate file is readable

All other cases return `404`. This includes external certificate deployments,
missing metadata, and broken managed TLS state.

### Operator workflow

1. **Install Orchard** — the PKG installer generates managed TLS material
   (CA + controller certs) under `config/tls/`
2. **Trust CA on the Orchard host** (optional):
   ```bash
   sudo orchardctl tls trust-ca
   ```
3. **Distribute CA to LAN clients** — either download from the running
   controller:
   ```bash
   curl -k -o orchard-ca.crt https://<controller-host>:8443/ca.crt
   ```
   or copy `config/tls/ca.crt` out-of-band
4. **Install the CA on each client** according to the client OS/browser trust
   store procedures
5. **Verify access:**
   ```bash
   curl --cacert orchard-ca.crt https://<controller-host>:8443/health/ready
   ```

> **External certificate deployments** should distribute trust through their
> own CA/PKI workflow. The `/ca.crt` endpoint is not served for externally
> managed certificates.

### Certificate regeneration

To regenerate managed certificates (e.g., after hostname change or expiry):

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
3. If using managed TLS and the hostname changed, regenerate certificates:
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

| Path | Mode | Owner | Set by |
|------|------|-------|--------|
| `config/` | `0700` | `root:wheel` | preinstall, postinstall |
| `config/tls/` | `0700` | `root:wheel` | preinstall, postinstall |

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

The installer integrates with `orchardctl tls init` (Task 4) to manage TLS
certificates for the controller HTTPS listener.

### Installer behavior

**Fresh install (no prior Orchard):**
1. `preinstall` creates `config/tls/` directory (mode `0700`)
2. `postinstall` detects empty TLS state and runs:
   `orchardctl tls init --no-trust`
3. Generates `ca.key`, `ca.crt`, `controller.key`, `controller.crt` under
   `config/tls/`
4. Does **not** auto-trust the CA in Keychain (operator must run
   `sudo orchardctl tls trust-ca` manually)
5. Bootstraps services after TLS generation succeeds

**Upgrade (existing install):**
- Preserves existing managed TLS files (no overwrite, no regeneration)
- If no TLS files exist (upgrading from pre-TLS version), generates them
- Partial TLS state (some files missing) **aborts the install** with a
  clear error listing which files are present/missing

### TLS modes

The installer and controller wrapper resolve TLS mode from `controller.env`:

| Mode | Condition | Installer behavior |
|------|-----------|--------------------|
| `managed_default` | No cert/key overrides set | Auto-generate if empty; preserve if complete; fail if partial |
| `external_override` | Both `ORCHARD_TLS_CERTFILE` and `ORCHARD_TLS_KEYFILE` set | Skip generation; validate files exist |
| `disabled` | `ORCHARD_TLS_DISABLED=true` | Skip generation; controller runs HTTP-only (loopback) |

**Invalid configurations that abort install:**
- Only one of `ORCHARD_TLS_CERTFILE` / `ORCHARD_TLS_KEYFILE` set
- `ORCHARD_TLS_DISABLED` set to unrecognized value

### Controller wrapper TLS boot gate

The `orchard-controller` wrapper validates TLS file presence **before**
exec'ing the BEAM release. This catches file drift (e.g., deleted certs)
during launchd restarts without waiting for the BEAM boot to fail.

- Managed mode: requires `controller.crt`, `controller.key`; warns if
  `ca.crt` is missing
- External mode: requires configured cert/key files; requires CA cert if
  `ORCHARD_TLS_CACERTFILE` is set
- Disabled mode: skips all checks
- Exit code `78` (`EX_CONFIG`) on configuration errors

### TLS env vars

See the consolidated [Controller transport environment](#controller-transport-environment)
table above for all TLS, transport, and CORS variables with defaults and
truthy/falsy value lists.

### External certificate setup

```bash
# Configure external certificates in controller.env
sudo tee '/Library/Application Support/Orchard/config/controller.env' <<'EOF'
ORCHARD_TLS_CERTFILE=/path/to/server.crt
ORCHARD_TLS_KEYFILE=/path/to/server.key
ORCHARD_TLS_CACERTFILE=/path/to/ca.crt
EOF
sudo chmod 600 '/Library/Application Support/Orchard/config/controller.env'
```

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

The installer writes diagnostic markers under `support/`:

| File | Purpose | Lifecycle |
|------|---------|-----------|
| `.pkg-install-context` | Transient: install mode (fresh/upgrade) | Written by preinstall, removed on postinstall success |
| `.pkg-install-complete` | Persistent: last successful install timestamp | Written on postinstall success, never auto-removed |

## Service bootstrap order

Postinstall bootstraps services in dependency order:
1. `com.orchard.postgres` (if managed postgres is present)
2. `com.orchard.node-agent`
3. `com.orchard.controller`

Bootstrap failures trigger reverse-order rollback of previously started
services and abort the install.

## Responsibilities

- Package Orchard releases into install paths under `/Library/Application Support/Orchard/`
- Install wrapper commands into `/Library/Application Support/Orchard/bin/`
- Expose `orchardctl` via `/usr/local/bin/orchardctl`
- Install launchd plists under `/Library/LaunchDaemons/` and `/Library/LaunchAgents/`
- Generate managed TLS certificates on fresh install
- Validate TLS state before bootstrapping services
- Detect fresh install vs upgrade and write diagnostic markers
