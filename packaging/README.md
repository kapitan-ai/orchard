# Orchard Packaging and Operator Runbook

The approved macOS native distribution profile uses `Orchard.app` inside a DMG.
The initial source-availability transition does not promise a supported public binary.
Public binary support requires an explicit release decision and completed release gates.
The app owns the root-authorized service lifecycle and installs the shared distribution-neutral payload under `/Library/Application Support/Orchard`.
See [`dmg/README.md`](dmg/README.md) for app assembly, signing, DMG verification, and lifecycle details.

The accepted Linux Controller profile remains a future milestone with separate headless lifecycle and packaging acceptance requirements.
Nothing in this runbook makes launchd, Keychain, macOS paths, or Apple signing part of the portable Orchard control-plane core contract.

## Shared distribution-neutral payload

The payload is a deployment artifact rather than a profile, and `Orchard.app` and the DMG are its current macOS native-distribution consumers.

Build the shared distribution-neutral payload with:

```bash
mise exec -- ./scripts/build-payload.sh
```

The script builds the Elixir releases and native helper environments, stages the command wrappers and selected launchd plists, remediates Mach-O dependencies, removes macOS metadata, and verifies payload closure.
It prints `PAYLOAD_ROOT=<path>` after the staged payload passes validation.
Pass that path to `scripts/build-app.sh`.

Payload wrapper sources live in `packaging/payload/bin/`.
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

### Shell quoting requirement

Environment files are sourced as POSIX shell, not parsed as generic `.env` files.
Values containing spaces, dollar signs, backticks, or hash characters must be quoted.
The Orchard support root contains a space, so every path under it requires quoting:

```bash
# CORRECT - quoted path with space
ORCHARD_TOKENIZER_EXECUTABLE="/Library/Application Support/Orchard/native/orchard_tokenizer/.venv/bin/orchard-tokenizer"

# BROKEN - unquoted path with space
ORCHARD_TOKENIZER_EXECUTABLE=/Library/Application Support/Orchard/native/orchard_tokenizer/.venv/bin/orchard-tokenizer
```

Use `orchardctl env init` to generate correctly quoted templates.
Target a specific role with `--service controller`, `--service node-agent`, or `--service all`.
Generated templates carry role-aware guidance for controller Runtime Endpoint targets, public host, tokenizer path, node-agent BEAM identity, cookie path, EPMD and distribution ports, gRPC compatibility settings, and worker path.

### Controller environment file lifecycle

```bash
sudo orchardctl env init --service controller
sudo vi '/Library/Application Support/Orchard/config/controller.env'
sudo orchardctl migrate
```

`orchardctl env init` writes a generated `SECRET_KEY_BASE`, auto-detected absolute paths to the staged tokenizer and worker entrypoints, a commented external PostgreSQL `DATABASE_URL` placeholder, and BEAM Runtime Endpoint templates.
Leave the generated `SECRET_KEY_BASE` in place unless intentionally rotating it.
App-owned update preserves an existing `controller.env`; it is not overwritten.

A manual alternative:

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

Required controller variables:

| Variable | Description |
|----------|-------------|
| `DATABASE_URL` | Postgres connection URL |
| `SECRET_KEY_BASE` | Phoenix secret key base |

Optional controller variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `ORCHARD_CONSOLE_ENABLED` | `false` | Enable the operator Console UI |
| `ORCHARD_CONSOLE_USERNAME` | - | Console Basic Auth username, required when the Console is enabled |
| `ORCHARD_CONSOLE_PASSWORD` | - | Console Basic Auth password, required when the Console is enabled |
| `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT` | `beam` | Runtime Endpoint transport. Use `grpc` only for compatibility fallback. |
| `ORCHARD_RUNTIME_ENDPOINT_TARGETS` | required for BEAM multi-Mac | Comma-separated node-agent BEAM node names such as `orchard_node_agent@10.0.0.21` |
| `ORCHARD_BEAM_NODE_NAME` | `orchard_controller@127.0.0.1` | Controller BEAM node name. Use `orchard_controller@<controller-ipv4>` for multi-Mac; remote BEAM targets are rejected while this remains loopback. |
| `ORCHARD_CONTROLLER_MEMBERSHIP_HOST` | the `ORCHARD_BEAM_NODE_NAME` host, or `127.0.0.1` under `grpc`; required when `ORCHARD_BEAM_PEER_GRANTS_ENABLED=true` | Private IPv4 address naming this controller's durable membership identity, republished on every membership heartbeat. It must match the `ORCHARD_BEAM_NODE_NAME` host under `beam`. With BEAM Peer Grants enabled it has no default and must be private non-loopback, or the controller fails to start. |
| `ORCHARD_BEAM_COOKIE_FILE` | `/Library/Application Support/Orchard/config/beam.cookie` | Root-owned mode `0600` BEAM cookie shared across controller and node-agent Macs |
| `ORCHARD_BEAM_EPMD_PORT` | `4369` | EPMD port. Set the same override on every Mac when needed. |
| `ORCHARD_BEAM_DIST_PORT_MIN` / `ORCHARD_BEAM_DIST_PORT_MAX` | `52171` | Controller BEAM distribution port range |
| `ORCHARD_CONTROLLER_MANAGEMENT_NODE_NAME` | `orchard_controller_management@127.0.0.1` | Local controller management identity used only when the inference Runtime Endpoint transport is `grpc`. The host must be loopback. |
| `ORCHARD_CONTROLLER_MANAGEMENT_COOKIE_FILE` | `/Library/Application Support/Orchard/config/beam.cookie` | Root-owned mode `0600` cookie used by the loopback management endpoint and local `orchardctl` |
| `ORCHARD_CONTROLLER_MANAGEMENT_EPMD_PORT` | `4369` | EPMD port for the loopback management endpoint in gRPC compatibility mode |
| `ORCHARD_CONTROLLER_MANAGEMENT_DIST_PORT` | `52171` | Fixed loopback distribution port for the management endpoint in gRPC compatibility mode |
| `ORCHARD_RUNTIME_CLIENT_TARGETS` | unset | gRPC compatibility fallback only. Comma-separated node-agent `host:port` values. |
| `ORCHARD_ALLOW_STATIC_RUNTIME_TARGET_FALLBACK` | `false` | Compatibility escape hatch. When `true`, the controller schedules `ORCHARD_RUNTIME_CLIENT_TARGETS` while no enrolled Node is admitted; the supported path leaves this `false` and derives targets from trusted Node inventory. |
| `ORCHARD_NODE_TRUST_ROOT` | `/Library/Application Support/Orchard/config/node-trust` | Controller root for internal Node trust material initialized by `orchardctl nodes trust init` |
| `POOL_SIZE` | `10` | Ecto connection pool size |
| `ECTO_IPV6` | - | Set to `true` for IPv6 socket options |

Transport, TLS, and CORS variables are listed in
[Controller transport environment](#controller-transport-environment).

### Node identity environment variables

Set these node-agent overrides only when the Orchard support-root layout is intentionally changed.
Defaults are relative to `ORCHARD_SUPPORT_ROOT`, default `/Library/Application Support/Orchard`.

| Variable | Default | Intended use |
|----------|---------|--------------|
| `ORCHARD_NODE_IDENTITY_PATH` | `/Library/Application Support/Orchard/data/node-id` | Path to the persisted Node identifier used by the node-agent runtime |
| `ORCHARD_NODE_IDENTITY_ROOT` | `/Library/Application Support/Orchard/config/node-identity` | Owner-only node-agent root for the Node key, issued Node Certificate, and runtime trust persisted during `orchardctl node join`; also roots BEAM Peer Grant custody |

### Worker backend rollback

Environment files are the supported way to roll the worker backend back without editing launchd plists:

```bash
echo 'ORCHARD_WORKER_BACKEND=stub' | sudo tee \
  '/Library/Application Support/Orchard/config/node-agent.env'
sudo chmod 600 '/Library/Application Support/Orchard/config/node-agent.env'
sudo orchardctl stop
sudo orchardctl start
```

Remove that file, or set `ORCHARD_WORKER_BACKEND=mlx`, and restart the same way to restore MLX inference.
No `ORCHARD_WORKER_GENERATION_MODE` override is required for this rollback: with the `stub` backend and the mode unset, runtime configuration resolves generation mode to `stream`.
Valid explicit values are `stream` and `batch`.
For MLX batch mode, `ORCHARD_WORKER_MAX_CONCURRENT_REQUESTS_PER_MODEL` controls the worker-reported request capacity for each loaded placement; the default `auto` resolves through `ORCHARD_WORKER_AUTO_MAX_CONCURRENT_REQUESTS_PER_MODEL`, currently `3`.

Restart services through `orchardctl stop` and `orchardctl start` rather than direct `launchctl` control so role selection and the lifecycle lock are honored.

### Environment file troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Controller crash-loops with `DATABASE_URL is missing` | `controller.env` absent or ignored | Create the file with correct ownership and permissions |
| Operator health reports `postgres_reachable: false` | Wrong DB URL, DB not running, or DB does not exist | Request authenticated `/ops/v1/health`; verify with `psql "$DATABASE_URL" -c 'select 1'` |
| Operator health reports `migrations_current: false` with the DB reachable | Migrations not run | Run `sudo orchardctl migrate` |
| A database-backed CLI command fails with `database_unavailable` | Command run without `sudo`, `DATABASE_URL` unset, DB unreachable, or migrations pending | Re-run with `sudo`; verify `DATABASE_URL` and `psql "$DATABASE_URL" -c 'select 1'`; run `sudo orchardctl migrate` if pending |
| `WARNING: ignoring env file` in `controller.log` | File not root-owned or has group/world permission bits | `sudo chown root:wheel <file> && sudo chmod 600 <file>` |
| `sudo orchardctl nodes ...` fails with `controller_runtime_unavailable` | Controller service not running, management identity/cookie mismatch, or the controller RPC hit its 30-second watchdog or output limit | Check `orchardctl status` and `controller.log`, confirm the root-owned cookie and any `ORCHARD_CONTROLLER_MANAGEMENT_*` overrides, then inspect controller and node state before retrying |
| Controller exits `78` with `existing Controller management EPMD listener must bind exclusively to loopback` | Under `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT="grpc"`, a pre-existing EPMD on the management port is bound to a wildcard or routable address | Stop the foreign `epmd`, or set `ORCHARD_CONTROLLER_MANAGEMENT_EPMD_PORT` to a free port so the controller owns a loopback-only listener |

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

### Mode resolution

| Runtime mode | Condition | Listener |
|--------------|-----------|----------|
| `plain_http_localhost` | Default when `ORCHARD_TRANSPORT_MODE` is unset and no legacy TLS variable selects HTTPS; also explicit `ORCHARD_TRANSPORT_MODE=plain_http_localhost` | HTTP on `127.0.0.1`:`PORT`, a degraded local/emergency mode |
| `direct_https` | `ORCHARD_TRANSPORT_MODE=direct_https`; uses operator-provided `ORCHARD_TLS_CERTFILE`/`ORCHARD_TLS_KEYFILE` or explicit local-CA helper output | HTTPS on `ORCHARD_API_BIND_IP`:`ORCHARD_API_HTTPS_PORT` |
| `reverse_proxy` | `ORCHARD_TRANSPORT_MODE=reverse_proxy`; public HTTPS terminates at an operator-managed proxy | Local/private HTTP backend on `ORCHARD_API_BIND_IP`:`PORT`, default `127.0.0.1:4000` |

Legacy `ORCHARD_TLS_DISABLED`, `ORCHARD_TLS_CERTFILE`, `ORCHARD_TLS_KEYFILE`, and `ORCHARD_TLS_CACERTFILE` are one-release compatibility shims.
`ORCHARD_TRANSPORT_MODE` is authoritative when set; inconsistent legacy values emit warnings and are ignored unless structurally invalid.

### Operator deployment modes

Orchard is certificate-provider-neutral.
Operators choose how public HTTPS is terminated; Orchard maps those choices to three runtime modes:

| Operator deployment mode | Runtime mode | Certificate source |
|--------------------------|--------------|--------------------|
| Reverse proxy TLS termination | `reverse_proxy` | Proxy-owned; Orchard reports `unknown` |
| Direct HTTPS with operator cert/key | `direct_https` | `operator_provided` |
| Proprietary or paid CA | `direct_https` | `operator_provided` |
| Internal PKI or air-gapped HTTPS | `direct_https` | `operator_provided` |
| Explicit local CA helper output from `orchardctl tls init` | `direct_https` | `generated_local_ca` |

The app lifecycle does not procure, generate, or trust production TLS certificates by default.
`orchardctl tls init` remains an explicit local CA and dev-lab bootstrap helper only; it is not a production certificate provider.

Configurations that prevent startup:

- `ORCHARD_TRANSPORT_MODE` set to an unrecognized value
- `ORCHARD_TLS_DISABLED` set to an unrecognized value that is neither truthy nor falsy
- Only one of `ORCHARD_TLS_CERTFILE` / `ORCHARD_TLS_KEYFILE` set
- Either cert or key override set to an empty string

These exit with code `78` (`EX_CONFIG`) from the controller wrapper boot gate.

### Validation responsibilities

| Stage | What it checks |
|-------|----------------|
| Controller wrapper boot gate | File presence and config shape; exits `78` before the BEAM starts |
| Runtime (`config/runtime.exs`) | PEM content, certificate validity window, key type; warns to stderr when the certificate expires within 30 days |

The wrapper boot gate catches file drift, such as deleted certificates, during launchd restarts without waiting for BEAM boot to fail:

- `direct_https` with local-CA helper output requires `controller.crt` and `controller.key`, and warns when `ca.crt` is missing
- `direct_https` with operator cert/key paths requires the configured cert and key files, and requires the CA certificate when `ORCHARD_TLS_CACERTFILE` is set
- `reverse_proxy` and `plain_http_localhost` skip TLS file checks

### Controller transport environment

All variables are set through `controller.env` or the process environment:

| Variable | Default | Description |
|----------|---------|-------------|
| `ORCHARD_TRANSPORT_MODE` | `plain_http_localhost` | Primary transport mode: `plain_http_localhost`, `direct_https`, or `reverse_proxy` |
| `PORT` | `4000` | HTTP listen port for `plain_http_localhost`; HTTP backend port for `reverse_proxy` |
| `ORCHARD_API_HTTPS_PORT` | `8443` | HTTPS listen port for `direct_https` |
| `ORCHARD_API_BIND_IP` | `0.0.0.0` for `direct_https`; `127.0.0.1` for `reverse_proxy`; ignored for `plain_http_localhost` | Bind IP for the active listener. Non-loopback `reverse_proxy` binds require `ORCHARD_TRUSTED_PROXIES`. |
| `ORCHARD_PUBLIC_HOST` | `localhost` | Browser-visible hostname or IP. Required when reaching the Console from a non-`localhost` host such as a Tailscale IP or domain name, and it must match the browser origin exactly. |
| `ORCHARD_PUBLIC_PORT` | `443` | Browser-visible HTTPS port for `reverse_proxy` display URLs and origin checks |
| `ORCHARD_TRUSTED_PROXIES` | loopback only (`127.0.0.1/32`, `::1/128`) | Comma-separated CIDRs allowed to supply `x-forwarded-*` headers in `reverse_proxy` mode |
| `ORCHARD_TLS_CERTFILE` | unset | Legacy shim and `direct_https` operator certificate path |
| `ORCHARD_TLS_KEYFILE` | unset | Legacy shim and `direct_https` operator private key path |
| `ORCHARD_TLS_CACERTFILE` | unset | Optional CA certificate path for generated local CA or operator validation |
| `ORCHARD_TLS_DISABLED` | unset | Legacy shim: truthy maps to `plain_http_localhost`; explicit false maps to `direct_https` during the compatibility window |
| `ORCHARD_CORS_ORIGINS` | empty | Comma-separated CORS origin allowlist |

Truthy values for `ORCHARD_TLS_DISABLED` are `1`, `true`, `TRUE`, `yes`, `YES`, `on`, and `ON`.
Falsy values are `0`, `false`, `FALSE`, `no`, `NO`, `off`, and `OFF`.
Default TLS file paths are relative to `ORCHARD_SUPPORT_ROOT`, default `/Library/Application Support/Orchard`.

`ORCHARD_PUBLIC_HOST` must match the browser URL when the Console is reached from a non-`localhost` host.
Set it to the exact hostname or IP operators type in the browser, for example `100.86.198.38` for Tailscale or `orchard.local` for mDNS.
Left at the default `localhost` and accessed from another host, the Console HTML loads but LiveView stays disconnected: data shows "Loading" or "Unknown" with no visible error.
See [Console troubleshooting](#console-troubleshooting).

### Reverse proxy TLS termination

Use `reverse_proxy` when nginx, Caddy, Traefik, a load balancer, or another operator-managed edge proxy owns public HTTPS.
Orchard listens on HTTP behind that proxy and trusts forwarded headers only from configured proxy CIDRs.

Minimal `controller.env` for a loopback proxy on the same Mac:

```bash
ORCHARD_TRANSPORT_MODE=reverse_proxy
ORCHARD_API_BIND_IP=127.0.0.1
PORT=4000
ORCHARD_PUBLIC_HOST=orchard.example.com
ORCHARD_PUBLIC_PORT=443
```

When the proxy reaches Orchard over a non-loopback interface, set both the backend bind and the trusted proxy CIDRs:

```bash
ORCHARD_TRANSPORT_MODE=reverse_proxy
ORCHARD_API_BIND_IP=10.0.0.10
PORT=4000
ORCHARD_PUBLIC_HOST=orchard.example.com
ORCHARD_TRUSTED_PROXIES=10.0.0.20/32
```

Without `ORCHARD_TRUSTED_PROXIES`, non-loopback reverse-proxy backend binds fail closed.
Spoofed `x-forwarded-*` headers from untrusted clients are stripped and do not affect scheme, host, port, or client IP handling.

Set reverse-proxy timeouts above the six-minute default ceiling in every example below.
The proxy timeout must exceed `ORCHARD_MAX_REQUEST_DEADLINE_MS`, or the cold-start budget is fiction.

#### nginx

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
        proxy_read_timeout 390s;
        proxy_send_timeout 390s;
    }
}
```

#### Caddy

```caddyfile
orchard.example.com {
    reverse_proxy 127.0.0.1:4000 {
        transport http {
            read_timeout 6m30s
            write_timeout 6m30s
            response_header_timeout 6m30s
        }
        header_up Host {host}
        header_up X-Forwarded-Host {host}
        header_up X-Forwarded-Proto https
        header_up X-Forwarded-Port 443
    }
}
```

Caddy can manage public ACME certificates or use operator-provided certificates with `tls /path/to/fullchain.pem /path/to/privkey.pem`.

#### Traefik

Configure the entrypoint's responding timeouts above the six-minute default ceiling:

```yaml
entryPoints:
  websecure:
    address: ":443"
    transport:
      respondingTimeouts:
        readTimeout: 390s
        writeTimeout: 390s
        idleTimeout: 390s
```

The router and service configuration:

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

Configure Traefik certificate resolvers, file certificates, or internal PKI outside Orchard.
Orchard does not inspect or publish proxy-owned certificate material.

### CORS allowlist configuration

CORS is disabled by default.
When `ORCHARD_CORS_ORIGINS` is empty or unset, the controller adds no CORS response headers.

To allow browser-based clients from specific origins, set a comma-separated allowlist in `controller.env`:

```bash
ORCHARD_PUBLIC_HOST=orchard.local
ORCHARD_CORS_ORIGINS=https://app.example.com,https://admin.example.com:3000
```

Each origin is validated at controller boot, and invalid origins abort startup.
An origin must use the `http` or `https` scheme and must include a host.
Wildcard `*`, `null`, a trailing slash, a path component, a query string, a fragment, and userinfo are all rejected.

Response behavior:

- Empty allowlist: no CORS headers on any request
- Allowed origin: `Access-Control-Allow-Origin` set to the request origin, with `x-request-id` exposed
- Allowed preflight (`OPTIONS` carrying `Origin` and `Access-Control-Request-Method`): `204 No Content` with the allowed methods `GET`, `POST`, and `OPTIONS`, then halt
- Disallowed origin: no CORS headers added and the request continues normally

### TLS certificate management

The app lifecycle never runs `orchardctl tls init` automatically.
Use it explicitly, and only as a local CA or dev-lab bootstrap helper for direct HTTPS.

Install and update preserve existing TLS files: they are neither overwritten nor regenerated.
Partial TLS state, where some expected files are missing, fails the lifecycle mutation closed with an error listing which files are present and missing.

Direct HTTPS with operator certificates, for public, paid, proprietary, or internal PKI material:

```bash
sudo tee '/Library/Application Support/Orchard/config/controller.env' >/dev/null <<'EOF'
ORCHARD_TRANSPORT_MODE=direct_https
ORCHARD_PUBLIC_HOST=orchard.example.com
ORCHARD_TLS_CERTFILE=/path/to/server.crt
ORCHARD_TLS_KEYFILE=/path/to/server.key
ORCHARD_TLS_CACERTFILE=/path/to/ca.crt
EOF
sudo chmod 600 '/Library/Application Support/Orchard/config/controller.env'
```

For internal PKI or air-gapped environments, distribute the issuing CA through operator-owned device management, browser, OS trust-store, or application trust configuration.
`/ca.crt` stays disabled for those deployments.

Recovering from partial TLS state:

```bash
# Option 1: remove all TLS files, then re-run the lifecycle operation
sudo rm -f '/Library/Application Support/Orchard/config/tls/'*

# Option 2: regenerate the local CA helper output
sudo orchardctl tls init --no-trust
sudo orchardctl tls trust-ca  # optional: trust the CA in the login Keychain
```

To regenerate local certificates after a hostname change or expiry:

```bash
sudo orchardctl tls init --force
sudo orchardctl stop
sudo orchardctl start
```

Add `--no-trust` to skip the interactive Keychain trust prompt.
LAN clients need the new CA after regeneration.

### LAN client trust and `/ca.crt`

When using the explicit local CA helper, the controller can publish that generated CA certificate for LAN client trust bootstrap at `GET /ca.crt`.

The endpoint serves the CA PEM only when all of the following hold:

- The endpoint is configured with `ca_certfile` and `ca_cert_metadata_path`
- The TLS metadata file exists and contains valid JSON
- The metadata `"source"` field is exactly `"generated_local_ca"`
- The runtime certificate source is `generated_local_ca`
- The CA certificate file is readable

Every other case returns `404`, including operator-provided certificate paths, operator-provided CA certificates, internal PKI roots, proprietary or public CA bundles, missing metadata, and broken local-CA helper state.
Orchard publishes only the CA generated by `orchardctl tls init` and never publishes operator-provided CA or certificate material.

Operator workflow:

1. Install Orchard. The app lifecycle generates no TLS material.
2. Create local CA helper TLS when wanted for dev-lab or local evaluation: `sudo orchardctl tls init --no-trust`
3. Optionally trust the CA on the Orchard host: `sudo orchardctl tls trust-ca`
4. Distribute the CA to LAN clients, either by download or out of band:
   ```bash
   curl -k -o orchard-ca.crt https://<controller-host>:8443/ca.crt
   ```
5. Install the CA on each client through that client's OS or browser trust-store procedure.
6. Verify access:
   ```bash
   curl --cacert orchard-ca.crt https://<controller-host>:8443/health/ready
   ```

Externally certificated deployments should distribute trust through their own CA/PKI workflow; `/ca.crt` is not served for them.

## Console troubleshooting

### Console loads but data stays "Loading" or "Unknown"

The Console shell and sidebar render, all data tiles show "Loading", readiness checks show "Unknown", and the connection banner may report a lost live connection.

This means `ORCHARD_PUBLIC_HOST` does not match the hostname or IP in the browser URL.
Phoenix rejects the LiveView websocket connection because the `Origin` header does not match the configured public host.

Diagnose from the browser console:

```js
window.liveSocket.isConnected()                  // expected true; false means origin mismatch
window.liveSocket.getSocket().connectionState()  // "connecting" means stuck
```

Fix it by setting `ORCHARD_PUBLIC_HOST` in `controller.env` to the exact host used in the browser, then restarting with `sudo orchardctl stop && sudo orchardctl start`.
When local generated TLS is in use and the hostname changed, run `orchardctl tls init --force` before restarting.

### Basic Auth credentials persist in the browser URL

The controller redirects after a successful Basic Auth challenge to strip credentials from the URL.
On an older build showing `https://user:pass@host:8443/console`, navigate to the clean URL manually after authenticating; the session cookie persists.

### Credential prompt and terminal custody

The `orchardctl` wrapper keeps sole custody of the controlling terminal for the whole command and hands the CLI only non-terminal standard input.
Redirected or piped input still reaches the CLI; input typed at the terminal does not.
`sudo orchardctl console enable`, `sudo orchardctl console rotate`, and `sudo orchardctl init --console` therefore collect credentials through a dedicated terminal helper rather than through standard input.

Expected behavior:

- Neither the username nor the password echoes while the prompt is active.
- Input typed or pasted past the prompts is discarded, and the helper waits for a short quiet period after the last keystroke before returning the terminal, so an abandoned paste cannot run as a command in the parent shell.
- The prior terminal settings are restored exactly on success, on `Ctrl-C` or `Ctrl-\`, and on `SIGHUP`/`SIGTERM`. When the terminal window closes there is no terminal left to restore.
- An interrupted, failed, or mismatched `enable` or `rotate` leaves `config/console.env` untouched, so `enable` does not turn the Console on and `rotate` keeps the existing credentials.
- A signalled run exits `129` (HUP), `130` (INT), `131` (QUIT), or `143` (TERM).

When the wrapper cannot confirm that terminal custody ended cleanly it prints `orchardctl: terminal custody guard failed` and deliberately refuses to return the terminal, because unread input may still be queued.
Follow the printed recovery steps: from a second terminal run `sudo kill -9 <printed pid>`, then run `stty sane` in the affected terminal.

`Error: interactive TTY required to collect Console credentials.` means the command has no controlling terminal or is not the terminal's foreground job, for example `ssh` without a TTY, a launchd job, or a backgrounded invocation.
Re-run it as a foreground command in an interactive terminal.

## Service start and stop behavior

`sudo orchardctl start` and `sudo orchardctl stop` act on the services selected by the installed role.
Prefer them over direct `launchctl` control.

`orchardctl start` runs `launchctl enable system/<label>` before `launchctl bootstrap` for each selected service.
This is deliberate: an install upgraded from an older Orchard may still carry persistent launchd job-domain disablement applied by an earlier `orchardctl stop`, and bootstrap alone cannot clear it.
Because the enable is unconditional, `orchardctl start` also overrides an operator's own `sudo launchctl disable system/com.orchard.controller` or `sudo launchctl disable system/com.orchard.node-agent`.
To keep a service down deliberately, leave it stopped rather than relying on job-domain disablement, or remove the role from the install.
`orchardctl start` fails before bootstrap when `launchctl enable` returns nonzero.

`orchardctl stop` boots the selected services out of the system domain and proves the Node Agent process gone under the lifecycle lock.
It does not apply persistent job-domain disablement, so a stopped service starts again after a reboot or a launchd domain reload while its LaunchDaemon plist remains installed.
Use app-owned uninstall, or a role change that removes the service, when a service must stay down across reboots.

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

The `admin` group (GID 80) is the standard macOS administrator group and most developer accounts belong to it.
Admin-group traverse on `config/` and `config/tls/` lets `orchardctl` work for admin users while secrets stay owner-only.

TLS files written by `orchardctl tls init`:

| File | Mode |
|------|------|
| `ca.key` | `0600` |
| `ca.crt` | `0644` |
| `controller.key` | `0600` |
| `controller.crt` | `0644` |
| `.orchard-tls-meta.json` | `0644` |

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

## Upgrade rollout

### Tenant and Model access grant rollout

Releases carrying the Tenant/Model access migration make public Model discovery and inference deny-by-default.
The migration inserts no grants and no routing policies, and no Organization is exempt, including the seeded `legacy` Tenant that the Console Playground runs as.
An upgraded controller therefore omits every model from `/v1/models` and rejects every `/v1/chat/completions` and `/v1/responses` request with `403 model_not_authorized` until an operator grants each approved Organization/model pair.

Do not re-expose the controller until the verification step passes:

1. Stop or drain public inference traffic and keep the controller unexposed from that point on.
2. Back up Postgres.
3. Run the app-owned update, then `sudo orchardctl migrate`.
   App-owned update restores only services that were loaded before the transaction, so confirm the controller state you intend before continuing.
4. Create explicit routing policies only where the canonical `AdmissionPolicy` defaults are insufficient:
   ```bash
   sudo orchardctl models routing-policy create --tenant <uuid-or-slug> \
     --name <name> --residency-preference <required_loaded|prefer_loaded|allow_cold_load>
   ```
   Omitting `--routing-policy-id` on a grant selects those canonical defaults; Orchard never implicitly selects a global policy.
5. Grant every approved Organization/model pair:
   ```bash
   sudo orchardctl models access grant <model_id>@<version> \
     --tenant <uuid-or-slug> [--routing-policy-id <uuid>]
   ```
6. Verify both directions before exposing the controller.
   Positive: a credential of a granted Organization sees the model in `GET /v1/models` and completes one chat completion request.
   Negative: a credential of an Organization without that grant does not see the model in `GET /v1/models` and receives `403 model_not_authorized` from `/v1/chat/completions` and `/v1/responses`.
7. Start services with `sudo orchardctl start` and expose the upgraded controller.

Rollback is asymmetric.
A schema rollback destroys grant and routing-policy data.
Rolling the application back to globally authorized behavior is a security regression, so public inference must stay stopped on that path.

See [Tenant Model access](../apps/orchard_cli/README.md#tenant-model-access) for the full `orchardctl models access` and `orchardctl models routing-policy` command surface.

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
scripts/test-payload-signing-contracts.sh
scripts/test-build-app.sh
scripts/test-app-signing.sh
scripts/test-build-dmg.sh
swift test --package-path packaging/app
```

Developer ID signing, notarization, stapling, draft publication, and system-root lifecycle mutations remain explicit credential or authorization gates.
