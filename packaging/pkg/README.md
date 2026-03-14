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

| Variable | Default | Description |
|----------|---------|-------------|
| `ORCHARD_TLS_CERTFILE` | `config/tls/controller.crt` | Server certificate path |
| `ORCHARD_TLS_KEYFILE` | `config/tls/controller.key` | Server private key path |
| `ORCHARD_TLS_CACERTFILE` | `config/tls/ca.crt` | CA certificate path |
| `ORCHARD_TLS_DISABLED` | `false` | Emergency HTTP-only mode (loopback only) |

Truthy values: `1, true, TRUE, yes, YES, on, ON`
Falsy values: `0, false, FALSE, no, NO, off, OFF`

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
