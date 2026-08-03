# Local Development

Local development setup for the Orchard inference stack. Default mode is
single-node; multi-node source-dev testing is supported via env vars
(see [Two-Node Source-Dev Cluster Testing](#two-node-source-dev-cluster-testing)).

Read [`architecture.md`](architecture.md) first if you need repo/runtime boundary
orientation, and [`tooling.md`](tooling.md) for pinned tool versions.

## Prerequisites

| Dependency | Version | Notes |
|------------|---------|-------|
| mise | see `../mise.toml` | Required for Erlang/OTP, Elixir, Python, uv, Node.js, and npm |
| PostgreSQL | ≥ 15 | Local instance |

See [Tooling](tooling.md) for the pinned runtime versions and standard
`mise exec --` command forms.

PostgreSQL must be accepting TCP connections before `make dev` runs. On a
Homebrew-managed Mac, install and start it with:

```bash
brew install postgresql@16
brew services start postgresql@16
pg_isready -h "${PGHOST-localhost}" -p "${PGPORT-5432}"
```

The dev config defaults to `PGUSER=postgres`, `PGPASSWORD=postgres`,
`PGHOST=localhost`, `PGPORT=5432`, and `PGDATABASE=orchard_dev`.
Either create that local role with database-create privileges, or export `PGUSER`/`PGPASSWORD` for an existing local superuser before running `make dev`.

## Quick Start

```bash
# 1. Clone and install dependencies
cd orchard
make setup

# 2. Start the dev server (creates DB, migrates, starts Phoenix + node-agent)
make dev
```

If you need the underlying commands instead of Makefile aliases:

```bash
mise trust
mise install
ERL_AFLAGS="-ssl protocol_version \"['tlsv1.2']\"" mise exec -- mix local.hex --if-missing --force
ERL_AFLAGS="-ssl protocol_version \"['tlsv1.2']\"" mise exec -- mix local.rebar --if-missing --force
ERL_AFLAGS="-ssl protocol_version \"['tlsv1.2']\"" mise exec -- mix deps.get
mise exec -- uv sync --locked --directory native/orchard_tokenizer
mise exec -- uv sync --locked --directory native/orchard_worker_mlx
mise exec -- npm ci --ignore-scripts
mise exec -- bin/dev
```

```elixir
# 3. Import a model bundle (in the running IEx session)
OrchardCLI.main(["models", "import", "/path/to/model-bundle", "--activate"])

# 4. Create an Organization and direct API Token for /v1 API calls (in the running IEx session)
OrchardCLI.main(["tenants", "create", "--slug", "dev", "--name", "Dev"])
OrchardCLI.main(["api-keys", "create", "--tenant-id", "<tenant-id>", "--name", "dev"])
```

`make dev` wraps `mise exec -- bin/dev`. `bin/dev` is the single low-level
entrypoint for source development. It creates the dev database if missing, runs
migrations, and starts `iex -S mix phx.server` with the dev gRPC port set to
**50071** (avoiding conflict with the packaged BEAM on 50061).

The controller listens on `http://localhost:4000` and the node-agent
gRPC server on `127.0.0.1:50071`.
Copy the API Token printed by `api-keys create` into
`ORCHARD_API_KEY` for the `curl` examples below.

## Phase 0 observability acceptance probe

Copy `scripts/support/observability_probe.example.json` to a non-secret local
configuration, set the two environment variables named by that file, and run:

```bash
export ORCHARD_OBSERVABILITY_PROBE_MODEL="<active-model-id>"
printf "API token: " >&2
stty -echo
IFS= read -r ORCHARD_OBSERVABILITY_PROBE_API_KEY
stty echo
printf "\n" >&2
export ORCHARD_OBSERVABILITY_PROBE_API_KEY
scripts/smoke-observability-probe.sh relative/or/absolute/observability-probe.json
```

Do not put the credential in a command argument, configuration file, shell
history, chat, or retained evidence. Non-loopback endpoints must use HTTPS; the
probe explicitly verifies the peer and hostname with the host system CA store.
Plain HTTP is accepted only for `localhost`, `127.0.0.1`, and `::1` source-dev
Controllers.

The launcher resolves a relative configuration path against the caller's
working directory before entering the repository root. Its owned exit codes are
`0` for a validated pass, `1` for a validated failed observation, `2` for a
configuration or environment refusal before a request, and `64` for invalid
arguments. An unexpected `mise`, Mix, VM, or dependency failure may return a
different runtime exit code. Stdout is reserved for the result JSON; retain
stderr separately and never merge it into pilot result storage.

The default `http_only` mode first requires exactly one `text/event-stream`
response media type, with optional parameters, then validates exactly one legal
typed terminal in the complete buffered `/v1/responses` SSE body. It does not
prove incremental stream delivery, progress timing, or persistence. On a
Controller host with direct access to the same configured Postgres database, set
`terminal_validation` to `controller_local` to additionally require exactly one
durable terminal `state_transition` matching both the request row and the HTTP
terminal outcome.

Pilot #118 pin ownership and digest instructions are in
[`pilots/README.md`](pilots/README.md).

## Transport Modes

Orchard has two transport profiles:

### Source dev (this page)

When running from a source checkout (`make dev`, `mise exec -- bin/dev`, or
`mise exec -- iex -S mix phx.server`):

- Controller listens on **HTTP** at `http://127.0.0.1:4000`
- Node-agent gRPC listens on `127.0.0.1:50071` (avoids packaged BEAM on 50061)
- Public `/v1/*` API routes require `Authorization: Bearer <api-token>`
- CORS is disabled (empty allowlist in `config/dev.exs`)
- No TLS setup is required

All `curl` examples in this document use plain HTTP because they target the source dev controller.
API examples assume `ORCHARD_API_KEY` contains a tenant-direct API Token or a service-account-owned API Token whose API Client has the `inference_client` Access Level for the Organization.

### Bulk API Client provisioning

Use `orchardctl api-clients bulk-provision` when a source-dev Organization needs service-account-owned API Tokens for internal developers, applications, coding agents, or automation clients.
The input CSV must target one Organization slug and include `organization`, `api_client`, `owner_contact`, and `key_name`.
Optional columns are `team`, `owner_name`, `external_ref`, `description`, `purpose`, `expires_at`, and `metadata_json`.

```csv
organization,api_client,owner_contact,key_name,team,external_ref
dev,ci-agent,ci@example.com,default,Platform,ci-agent
```

```elixir
OrchardCLI.main(["api-clients", "bulk-provision", "--dry-run", "--file", "/path/to/api-clients.csv"])
OrchardCLI.main(["api-clients", "bulk-provision", "--apply", "--file", "/path/to/api-clients.csv", "--output", "/path/to/api-client-tokens.csv"])
```

Apply writes One-time Secret Output to the chosen output CSV only after the batch commits.
The output CSV contains `organization`, `api_client`, `external_ref`, `key_name`, `api_token_id`, `api_token_prefix`, `api_token`, and `expires_at`.

### Packaged install

When installed via the macOS PKG:

- Controller defaults to degraded **loopback HTTP** (`plain_http_localhost`) until an operator chooses a transport mode
- Supports first-class transport modes: `reverse_proxy`, `direct_https`, and `plain_http_localhost`
- `reverse_proxy` uses an operator-managed HTTPS proxy in front of Orchard's HTTP backend; forwarded headers are trusted from loopback only unless `ORCHARD_TRUSTED_PROXIES` is set
- `direct_https` consumes operator-provided cert/key material from public, proprietary/paid, or internal PKI CAs, or explicit local-CA helper output for dev-lab bootstrap
- The PKG does not generate, procure, or trust production TLS certificates by default; `orchardctl tls init` is an explicit local CA helper only
- `/ca.crt` publishes only generated-local CA metadata output and returns `404` for operator-provided CA/cert material
- CORS is configurable via `ORCHARD_CORS_ORIGINS`

See [packaging/pkg/README.md](../packaging/pkg/README.md) for full operator
documentation on transport modes, TLS management, CORS configuration,
nginx/Caddy/Traefik reverse-proxy snippets, and the packaged licensing rollout
posture.

## Configuration

### Environment Variables

#### Database

| Variable | Default | Description |
|----------|---------|-------------|
| `PGUSER` | `postgres` | PostgreSQL user |
| `PGPASSWORD` | `postgres` | PostgreSQL password |
| `PGHOST` | `localhost` | PostgreSQL host |
| `PGPORT` | `5432` | Source controller, test, and benchmark PostgreSQL port. Must be an unsigned decimal integer in `1..65535`; explicit empty or malformed values fail during configuration evaluation. |
| `PGDATABASE` | `orchard_dev` | Database name |

Controller-bearing source roles validate and use `PGPORT`.
`bin/dev-node-agent` ignores it because the node-agent-only role does not use PostgreSQL.
Packaged controller and CLI releases continue to take the database port from `DATABASE_URL`.

#### Controller Inference

| Variable | Default | Description |
|----------|---------|-------------|
| `ORCHARD_TOKENIZER_EXECUTABLE` | `native/.../orchard-tokenizer` | Path to tokenizer helper |
| `ORCHARD_CACHE_AFFINITY_ENABLED` | `false` | Enable cache-affinity scheduler hints in source-dev mode. |
| `ORCHARD_CACHE_AFFINITY_LIVE_FINGERPRINT_MATCH_ENABLED` | `false` | Enable live fingerprint tie-break behavior for cache-affinity in source-dev mode. |
| `ORCHARD_CACHE_AFFINITY_MAX_PREFIX_BYTES` | `8192` | Advanced tuning knob for prefix bytes used in cache-affinity keying. |
| `ORCHARD_CACHE_AFFINITY_MAX_AGE_MS` | `300000` | Advanced tuning knob for max age window (ms) when reusing cache-affinity hints. |
| `ORCHARD_CACHE_AFFINITY_MAX_RECENT_REQUESTS` | `32` | Advanced tuning knob for number of recent requests considered for cache-affinity hints. |
| `ORCHARD_CACHE_AFFINITY_HMAC_SECRET` | _(unset)_ | Optional independent HMAC secret for cache-affinity keys. When unset, cache-affinity falls back to the endpoint `secret_key_base`. |
| `ORCHARD_CACHE_INTROSPECTION_ENABLED` | `false` | Enable cache-introspection metadata publication in source-dev mode. |
| `ORCHARD_MEMORY_ADMISSION_ENABLED` | `false` | Enable Phase 4E memory-headroom scheduler ranking hints in source-dev mode. |
| `PORT` | `4000` | HTTP listen port |

Cache-affinity, cache-introspection, and memory-admission env vars are read
when `config/dev.exs` is evaluated at BEAM startup. Restart `make dev`,
`mise exec -- bin/dev`, or `mise exec -- iex -S mix phx.server` after changing
them.

Source-dev defaults remain disabled unless explicitly enabled via env vars:
`ORCHARD_CACHE_AFFINITY_ENABLED=false`,
`ORCHARD_CACHE_AFFINITY_LIVE_FINGERPRINT_MATCH_ENABLED=false`,
`ORCHARD_CACHE_INTROSPECTION_ENABLED=false`, and
`ORCHARD_MEMORY_ADMISSION_ENABLED=false` when unset. The three advanced
cache-affinity numeric knobs above are optional overrides for
`:orchard_controller, :inference` and otherwise use shared runtime defaults.

##### Cache-affinity and memory-admission config regression smoke (source-dev)

Use these quick checks to confirm default-off behavior and env override wiring
into `:orchard_controller, :inference`.

```bash
# 1) Unset -> default-off remains in controller inference config
MIX_ENV=dev \
mise exec -- mix run --no-start -e "$(cat <<'ELIXIR'
inference = Application.get_env(:orchard_controller, :inference)
IO.inspect(inference[:cache_affinity], label: "cache_affinity")
ELIXIR
)"

# 2) Override selected knobs -> values land in :orchard_controller, :inference
ORCHARD_CACHE_AFFINITY_ENABLED=true \
ORCHARD_CACHE_AFFINITY_MAX_PREFIX_BYTES=4096 \
ORCHARD_CACHE_AFFINITY_MAX_AGE_MS=600000 \
ORCHARD_CACHE_AFFINITY_MAX_RECENT_REQUESTS=7 \
ORCHARD_CACHE_INTROSPECTION_ENABLED=true \
ORCHARD_MEMORY_ADMISSION_ENABLED=true \
MIX_ENV=dev \
mise exec -- mix run --no-start -e "$(cat <<'ELIXIR'
inference = Application.get_env(:orchard_controller, :inference)
IO.inspect(inference[:cache_affinity], label: "cache_affinity")
IO.inspect(inference[:cache_introspection], label: "cache_introspection")
IO.inspect(inference[:memory_admission], label: "memory_admission")
ELIXIR
)"
```

#### Node Agent Runtime

| Variable | Default | Description |
|----------|---------|-------------|
| `ORCHARD_NODE_AGENT_LISTEN_HOST` | `127.0.0.1` | gRPC listen address. Set to `0.0.0.0` on a remote node-agent for 2-node testing. |
| `ORCHARD_NODE_AGENT_LISTEN_PORT` | `50071` (source dev) / `50061` (packaged) | gRPC listen port |
| `ORCHARD_NODE_AGENT_ADVERTISE_HOST` | Listen host or `127.0.0.1` | Controller-reachable host persisted during `orchardctl node join`; required when the listen host is wildcard-bound. |
| `ORCHARD_NODE_AGENT_ADVERTISE_PORT` | Listen port | Controller-reachable gRPC compatibility port persisted during `orchardctl node join`. |
| `ORCHARD_NODE_HOSTNAME` | Local hostname | Stable Node inventory hostname persisted during `orchardctl node join`. |
| `ORCHARD_RUNTIME_CLIENT_PORT` | Same as listen port | Controller gRPC client port (must match listen port) |
| `ORCHARD_MODELS_ROOT` | `tmp/dev/models` | Model artifact storage |
| `ORCHARD_WORKER_SOCKET_DIR` | `/tmp/od-<hash>/ws` | Worker UDS directory |
| `ORCHARD_WORKER_EXECUTABLE` | `native/orchard_worker_mlx/bin/orchard-worker-mlx` (repo-root) | Worker binary path. Override via env var; default resolves from repo root in source-dev mode. |
| `ORCHARD_WORKER_BACKEND` | `mlx` | Worker backend (`mlx` or `stub`) |
| `ORCHARD_WORKER_GENERATION_MODE` | `batch` for `mlx`, `stream` for unset `stub` | Worker generation runtime (`stream` or `batch`). Leave unset when using the stub backend. |
| `ORCHARD_WORKER_MAX_CONCURRENT_REQUESTS_PER_MODEL` | `auto` | Batch request admission limit reported by MLX workers for loaded placement capacity. Use an integer `>= 1` or `auto`. |
| `ORCHARD_WORKER_AUTO_MAX_CONCURRENT_REQUESTS_PER_MODEL` | `3` | Effective worker request limit when the max-concurrency setting is `auto`. |
| `ORCHARD_NODE_DISPLAY_NAME` | hostname | Human-readable node name shown in console |
| `ORCHARD_LICENSE_ENFORCEMENT` | `off` (source dev) / `hard` (distributed packaged channels) | Licensing mode for startup and packaged useful-work admission: `off`, `warn`, or `hard` |

Node-agent runtime env vars are read when `config/dev.exs` is evaluated at BEAM
startup. Restart `make dev`, `mise exec -- bin/dev`, or `mise exec --
bin/dev-node-agent` after changing them. Use `ORCHARD_WORKER_BACKEND=stub` for
cluster mechanics or rollback testing when real MLX inference is not required;
when `ORCHARD_WORKER_GENERATION_MODE` is unset, the stub backend resolves to
stream mode automatically.
By default, source-dev worker Unix sockets live under a short, worktree-specific `/tmp/od-<hash>/ws` directory to avoid macOS Unix socket path length limits.
Set `ORCHARD_WORKER_SOCKET_DIR` to override that location.
`ORCHARD_FAKE_RUNTIME` is a release/runtime config knob; source-dev tests use
the fake runtime through `config/test.exs`, not a dev env override.
Batch generation mode can admit multiple same-model requests up to the worker-reported limit.
The node agent also enforces aggregate active request capacity across loaded models using the resolved worker limits, conservatively falling back to single-request capacity when worker status omits `max_concurrency`.
The node-agent reports aggregate and placement capacity through Runtime Endpoint status.
The default split-role source-dev path maps BEAM Runtime Endpoint Observations before multi-node scheduler candidate filtering and queue wakeups from loaded-placement or cold/no-placement capacity.
When the gRPC compatibility adapter is explicitly selected, the Node Agent facade maps the current gRPC status response into Runtime Endpoint Observations.
Transport failures and ineligible Runtime Endpoint Observations clear endpoint-owned queue capacity sources so queued work is not promoted against stale loaded-placement or cold/no-placement slots.
BEAM observations publish queue capacity only when the target resolves back to the same persisted node identity.
Stream mode reports max concurrency as `1` at both node and placement levels.

#### Controller Multi-Node (Source Dev)

| Variable | Default | Description |
|----------|---------|-------------|
| `ORCHARD_RUNTIME_CLIENT_HOST` | `127.0.0.1` | Controller’s local gRPC target host |
| `ORCHARD_RUNTIME_CLIENT_TARGETS` | _(empty)_ | Comma-separated `host:port` list for multi-node scheduling. When set with at least one target, the scheduler auto-selects `MultiNode`. |

These env vars configure only the gRPC compatibility target path.
Split-role source-dev defaults to BEAM Runtime Endpoint mode and uses a separate Runtime Endpoint env surface, not `ORCHARD_RUNTIME_CLIENT_TARGETS`.
The accepted source-dev BEAM surface is `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT` plus `ORCHARD_RUNTIME_ENDPOINT_TARGETS`, with BEAM node and distribution settings under `ORCHARD_BEAM_*` variables.
Console Nodes live runtime diagnostics follow the active Runtime Endpoint target source.
When BEAM Runtime Endpoint targets are configured, Console probes those BEAM targets through the configured Runtime Endpoint client.
Keep `ORCHARD_RUNTIME_CLIENT_TARGETS` alongside BEAM targets only when deliberately comparing the gRPC compatibility path.
Do not rely on automatic gRPC fallback when BEAM mode is selected.

#### Source-dev BEAM Runtime Endpoint Split-role Mode

Source dev defaults to BEAM Runtime Endpoint mode for split-role launches through `bin/dev-controller` and `bin/dev-node-agent`.
Accepted two-Mac smoke evidence is summarized in `docs/decisions/0001-runtime-endpoints-beam-first.md`, and the BEAM default was promoted on 2026-07-05.
Leave `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT` unset or set it to `beam` for the default split-role BEAM path.
Set `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc` only when intentionally opting into the gRPC compatibility path on port `50071`.
All-in-one `bin/dev` intentionally rejects explicit BEAM mode and remains the single-host gRPC default.

The BEAM source-dev env surface is separate from the legacy gRPC compatibility target surface.
`ORCHARD_RUNTIME_CLIENT_TARGETS` remains gRPC compatibility-only and accepts only `host:port` targets.
`ORCHARD_RUNTIME_ENDPOINT_TARGETS` is BEAM target-only when BEAM mode is selected and accepts BEAM node names such as `orchard_node_agent@100.x.y.z`.
`ORCHARD_RUNTIME_ENDPOINT_TARGETS` does not configure gRPC targets.
`ORCHARD_RUNTIME_CLIENT_TARGETS` does not configure BEAM targets.
When BEAM mode is selected, BEAM configuration, guardrail, connection, identity, and Runtime Endpoint RPC failures fail visibly.
The controller does not automatically retry the same request through gRPC.
`orchardctl env init` renders this BEAM env surface in the packaged
`controller.env` and `node-agent.env` templates, but source-dev split-role
launches still set these variables directly in the shell rather than through
generated env files.
For a default BEAM controller launch, `ORCHARD_RUNTIME_ENDPOINT_TARGETS` is effectively required, and startup fails early naming the variable when it is absent.

| Variable | Default | Description |
|----------|---------|-------------|
| `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT` | `beam` for split-role scripts | Runtime Endpoint transport selector. Leave unset for split-role BEAM source dev, or set `grpc` for compatibility opt-out. |
| `ORCHARD_RUNTIME_ENDPOINT_TARGETS` | _(empty)_ | Controller-only comma-separated BEAM target list. Each target must be `orchard_node_agent@<ipv4-literal>`. |
| `ORCHARD_BEAM_NODE_NAME` | `orchard_controller@127.0.0.1` or `orchard_node_agent@127.0.0.1` | Long BEAM node name for the current split-role VM. The host part must be an IPv4 literal. |
| `ORCHARD_CONTROLLER_MEMBERSHIP_HOST` | the `ORCHARD_BEAM_NODE_NAME` host, or `127.0.0.1` under `grpc`; **required when `ORCHARD_BEAM_PEER_GRANTS_ENABLED=true`** | Controller-only override for the private IPv4 address that names the Controller's durable membership identity. It must be a private IPv4 literal and must match the `ORCHARD_BEAM_NODE_NAME` host under `beam`. When BEAM Peer Grants are enabled there is no default and it must be set explicitly. Only controller and all-in-one roles resolve it; a node-agent-only host ignores it. |
| `ORCHARD_BEAM_COOKIE_FILE` | `tmp/dev/beam.cookie` | Cookie file path. Same-host source dev generates it when absent. Two-Mac source dev must provision the same cookie material on each Mac. |
| `ORCHARD_BEAM_DIST_PORT_MIN` | `52171` for controller, `52172` for node-agent | Lower bound for the BEAM distribution listener port range. Set both min and max together when overriding. |
| `ORCHARD_BEAM_DIST_PORT_MAX` | `52171` for controller, `52172` for node-agent | Upper bound for the BEAM distribution listener port range. Set both min and max together when overriding. |
| `ORCHARD_BEAM_EPMD_PORT` | `4369` | EPMD port for source-dev node discovery. |

The split-role scripts print non-secret startup diagnostics for the BEAM node name, cookie file path, EPMD port, and distribution port range.
They never print cookie contents.
Explicit cookie files must exist, be regular files, be non-empty, and be owner-only before Mix starts.
Owner-only means mode `0600` or stricter.
Same-host default cookie generation writes `tmp/dev/beam.cookie` with mode `0600`.
The helper copies the selected cookie into a private per-role BEAM home under `tmp/dev/beam-home/` so Erlang can read `.erlang.cookie` without using the contributor's normal home directory.
Packaged or release runtime configuration must not inherit this repo-local cookie model.
Use release secret injection for packaged distributed BEAM cookie material instead.

Same-host BEAM split-role smoke can run from two terminals in the same checkout.
Start the node-agent first:

```bash
ORCHARD_WORKER_BACKEND=stub \
mise exec -- bin/dev-node-agent
```

Then start the controller:

```bash
ORCHARD_RUNTIME_ENDPOINT_TARGETS=orchard_node_agent@127.0.0.1 \
mise exec -- bin/dev-controller
```

For same-host mode, the controller defaults to `orchard_controller@127.0.0.1` and distribution port `52171`.
The node-agent defaults to `orchard_node_agent@127.0.0.1` and distribution port `52172`.
Both roles use `ERL_EPMD_PORT=4369` unless `ORCHARD_BEAM_EPMD_PORT` is set.

Two-Mac BEAM source-dev mode requires explicit IPv4-literal node names and the same cookie material on every participating Mac.
Do not use hostnames such as `worker.local` for BEAM target hosts in this slice.
Use Tailscale IPv4 addresses or another trusted private IPv4-literal address.
Provision the cookie out of band without pasting the cookie value into docs, tickets, chat, shell history, or evidence files.

From one Mac, create the cookie file if you are not using an existing secret manager output:

```bash
umask 077
mkdir -p tmp/dev
openssl rand -hex 32 > tmp/dev/beam.cookie
chmod 600 tmp/dev/beam.cookie
shasum -a 256 tmp/dev/beam.cookie
```

Copy the file to the same repo-relative path on each participating Mac through a trusted channel such as `scp` over Tailscale.
After copying, run `chmod 600 tmp/dev/beam.cookie` on each Mac.
Verify that the SHA-256 digests match without showing or committing the cookie contents.
The durable smoke note may say that cookie digests matched, but it must not include the cookie value.

EPMD and the bounded distribution ports must be reachable between the BEAM hosts.
For the defaults, allow TCP `4369`, controller TCP `52171`, and node-agent TCP `52172` between the participating private IPs.
If you override `ORCHARD_BEAM_EPMD_PORT`, `ORCHARD_BEAM_DIST_PORT_MIN`, or `ORCHARD_BEAM_DIST_PORT_MAX`, update the firewall and smoke notes to match.
A quick reachability check after the roles start is:

```bash
nc -vz <worker-ipv4> 4369
nc -vz <worker-ipv4> 52172
nc -vz <controller-ipv4> 4369
nc -vz <controller-ipv4> 52171
```

For BEAM Runtime Endpoint RPC evidence from the controller IEx session, use the configured target through the BEAM client.
This checks the Runtime Endpoint adapter path rather than the legacy gRPC compatibility path.

```elixir
target = %{transport: :beam, address: "orchard_node_agent@<worker-ipv4>"}
{:ok, conn} = Orchard.RuntimeEndpoint.BeamClient.connect(target)
{:ok, observation} = Orchard.RuntimeEndpoint.BeamClient.status(conn)
observation
```

Console Nodes live runtime diagnostics use the same Runtime Endpoint target list as scheduler and dispatch.
For a BEAM-only smoke, do not duplicate `ORCHARD_RUNTIME_CLIENT_TARGETS` just to make Console Nodes show both Macs.
If `ORCHARD_RUNTIME_CLIENT_TARGETS` is also set, treat it as an explicit gRPC comparison path only.
It is not a fallback path for BEAM request failures.

Application-config opt-in still uses the Runtime Endpoint client and target keys under `:orchard_controller, :inference`.
Source-dev BEAM env parsing writes equivalent target maps when the controller starts in BEAM mode.

```elixir
config :orchard_controller, :inference,
  runtime_endpoint_client_impl: Orchard.RuntimeEndpoint.BeamClient,
  runtime_endpoint_targets: [
    %{
      transport: :beam,
      address: "orchard_node_agent@100.64.1.10",
      metadata: %{source_dev: true}
    }
  ]
```

When source-dev BEAM mode is configured through env vars, `config/dev.exs` also enables BEAM guardrails under `:orchard_controller, :runtime_endpoint, beam: [...]`.
Guardrail validation requires a matching controller node name, a cookie file path, the controller listen IP, admitted `orchard_node_agent` services, and per-target CIDRs derived from the BEAM target IPs.
The `listen_host` must not be `0.0.0.0` or `::`.
Allowed CIDRs must not contain `0.0.0.0/0` or `::/0`.
BEAM target services must be admitted and BEAM target hosts must fall inside `allowed_cidrs`.

#### Packaged Controller Transport (release only)

These variables apply to packaged/release controller installs, not source dev:

| Variable | Default | Description |
|----------|---------|-------------|
| `ORCHARD_TRANSPORT_MODE` | `plain_http_localhost` | Primary transport mode: `plain_http_localhost`, `direct_https`, or `reverse_proxy` |
| `PORT` | `4000` | HTTP listen port for `plain_http_localhost`; HTTP backend port for `reverse_proxy` |
| `ORCHARD_API_HTTPS_PORT` | `8443` | HTTPS listen port for `direct_https` |
| `ORCHARD_API_BIND_IP` | `0.0.0.0` for `direct_https`; `127.0.0.1` for `reverse_proxy`; ignored for `plain_http_localhost` | Bind IP for the active listener. Non-loopback `reverse_proxy` binds require `ORCHARD_TRUSTED_PROXIES`. |
| `ORCHARD_PUBLIC_HOST` | `localhost` | Browser-visible hostname or IP. **Required for console access** when not using `localhost`. See [packaging README](../packaging/pkg/README.md#console-troubleshooting). |
| `ORCHARD_PUBLIC_PORT` | `443` | Browser-visible HTTPS port for `reverse_proxy` display URLs and origin checks |
| `ORCHARD_TRUSTED_PROXIES` | loopback only (`127.0.0.1/32`, `::1/128`) | Comma-separated CIDRs allowed to supply `x-forwarded-*` headers in `reverse_proxy` mode |
| `ORCHARD_TLS_CERTFILE` | _(unset)_ | Legacy shim / `direct_https` operator certificate path |
| `ORCHARD_TLS_KEYFILE` | _(unset)_ | Legacy shim / `direct_https` operator private key path |
| `ORCHARD_TLS_CACERTFILE` | _(unset)_ | Optional CA certificate path for generated local CA or operator validation |
| `ORCHARD_TLS_DISABLED` | _(unset)_ | Legacy shim: truthy maps to `plain_http_localhost`; explicit false maps to `direct_https` during compatibility window |
| `ORCHARD_CORS_ORIGINS` | _(empty)_ | Comma-separated CORS origin allowlist |

See [packaging/pkg/README.md](../packaging/pkg/README.md) for full details
on transport modes, truthy/falsy values, and validation behavior.

### Config Files

| File | Purpose |
|------|---------|
| `config/config.exs` | Base config (all envs) |
| `config/dev.exs` | Dev environment: local paths, `fake_runtime?: false` |
| `config/test.exs` | Test environment: sandbox DB, `fake_runtime?: true` |
| `config/prod.exs` | Prod placeholder |
| `config/runtime.exs` | Release-time config from env vars |
| `config/m1_runtime_defaults.exs` | Shared defaults for source-dev runtime settings |
| `config/source_postgres.exs` | Shared `PGPORT` parsing/validation for source dev, test, and benchmark database config |

### Dev Directory Structure

Dev mode uses `tmp/dev/` under the repo root for model and controller data:

```
tmp/dev/
├── bundles/           # Imported model artifacts (controller)
├── models/            # Model files (node-agent)
└── data/              # Source-dev runtime data
```

Worker Unix domain sockets default to `/tmp/od-<hash>/ws`, outside the repo tree, and can be overridden with `ORCHARD_WORKER_SOCKET_DIR`.

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health/live` | Liveness probe |
| GET | `/health/ready` | Readiness probe (DB, transport, runtime summary) |
| GET | `/v1/models` | List active models; Bearer token required |
| POST | `/v1/chat/completions` | Chat completion; stream + non-stream; Bearer token required |
| POST | `/v1/responses` | Bounded Responses API subset; stream + non-stream; Bearer token required |

### Example: Non-streaming

```bash
curl -X POST http://localhost:4000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $ORCHARD_API_KEY" \
  -d '{
    "model": "your-model@v1",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

### Example: Streaming

```bash
curl -N -X POST http://localhost:4000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $ORCHARD_API_KEY" \
  -d '{
    "model": "your-model@v1",
    "messages": [{"role": "user", "content": "Hello!"}],
    "stream": true
  }'
```

### Example: Responses

```bash
curl -X POST http://localhost:4000/v1/responses \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $ORCHARD_API_KEY" \
  -d '{
    "model": "your-model@v1",
    "input": "Hello!"
  }'
```

## CORS Allowlist

The packaged controller supports an explicit CORS origin allowlist for
browser-based LAN clients. CORS is **disabled by default** — when
`ORCHARD_CORS_ORIGINS` is empty or unset, no CORS headers are added to any
response.

To enable CORS, set a comma-separated list of allowed origins:

```bash
ORCHARD_CORS_ORIGINS=https://app.example.com,https://admin.example.com:3000
```

Each origin must be a full `http(s)://host[:port]` value. The following are
**rejected** at controller boot:

- `*` (wildcard) and `null`
- Origins with a path, trailing slash, query string, fragment, or userinfo

Source dev does not require CORS configuration — the dev controller listens
on localhost only.

## LAN Client Trust Workflow

Packaged installs can bootstrap LAN client trust only when the operator explicitly chooses local generated TLS:

1. **Generate certificates** — after install, run `sudo orchardctl tls init --no-trust`; the PKG installer does not generate certificates automatically
2. **Select direct HTTPS** — configure `ORCHARD_TRANSPORT_MODE=direct_https` for the controller before restart
3. **Trust CA locally** (optional):
   ```bash
   sudo orchardctl tls trust-ca
   ```
3. **Download CA on LAN clients** — the controller serves its CA at
   `GET /ca.crt` (only for Orchard-generated certificates; returns `404` for
   external certificate deployments)
4. **Verify:**
   ```bash
   curl --cacert orchard-ca.crt https://<controller-host>:8443/health/ready
   ```

Managed TLS files are stored under
`/Library/Application Support/Orchard/config/tls/`. To regenerate after a
hostname change or expiry:

```bash
sudo orchardctl tls init --force
```

Source dev does not require TLS setup — the dev controller uses plain HTTP on
localhost.

See [packaging/pkg/README.md](../packaging/pkg/README.md) for the full
operator workflow, permission expectations, and external certificate setup.

## Two-Node Source-Dev Cluster Testing

Single-node all-in-one remains available through `bin/dev`.
Use the BEAM Runtime Endpoint flow for the default split-role source-dev cluster path.
Use the gRPC compatibility flow only when you intentionally opt out with `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc` or need side-by-side comparison.

`orchardctl cluster init` mints the first cluster-admin API Client credential as a local, one-shot, audited controller-host operation behind the leader-only write gate and requires a `--output` One-time Secret Output path.
Confirmed success leaves the chosen destination as the only intentional plaintext path and never writes the token to stdout.
If publication cannot be confirmed after credential authority commits, the command returns nonzero, reports the token prefix and containment state without plaintext, and may report protected residue that requires recovery beginning with prefix revocation.
The command refuses a second init with `cluster_already_initialized` and supports `--force-new-admin --yes` recovery minting, `--client-name`, and `--json`.
`orchardctl nodes trust init` initializes the internal Node trust authority on the controller host and is a required, idempotent, leader-gated prerequisite before any enrollment bundle can be issued; it is separate from the credential-only `orchardctl cluster init`.
`orchardctl nodes enrollment create --output PATH` issues an owner-only, single-Node Enrollment bundle from the active controller, and `orchardctl node join --enrollment-bundle PATH` redeems it with pinned controller trust before persisting the Node identity and validated gRPC compatibility advertisement.
Set `ORCHARD_NODE_AGENT_ADVERTISE_HOST` to a Controller-reachable private address when `ORCHARD_NODE_AGENT_LISTEN_HOST` is `0.0.0.0`; wildcard addresses fail closed and are never persisted as trusted targets.
`orchardctl cluster status [--json]` is implemented for read-only cluster and control-plane status, with the shared `ControlPlaneStatus` payload and a control-plane summary in `--json` mode.
`orchardctl nodes inspect`, `orchardctl nodes pending`, `orchardctl nodes admit`, and `orchardctl nodes reject` are implemented for the current node-admission-review slice, with stable JSON and human output, `--dry-run` previews, and `--yes` execution gating; `orchardctl nodes reject` additionally requires a nonblank `--reason`.
`orchardctl nodes admit` requires a nonblank `--capacity-policy-reason` and accepts an optional non-negative `--controller-dispatch-ceiling`, which defaults to `1` when omitted; the Controller Dispatch Ceiling is persisted atomically with admission, and while the cluster dispatch-capacity phase is `pre_cutover` the preview warns `controller_dispatch_ceiling_not_yet_enforcing` because an approved ceiling is recorded policy that is not yet allocation authority.
Admission executes its capacity-policy write while holding that Node's Controller-local acceptance gate, so it fails fast with `dispatch_capacity_acceptance_gate_busy` when a dispatch is mid-handoff on the same Node instead of blocking for the length of a request, and with `dispatch_capacity_authority_unavailable` when the Controller's allocation authority is not running; both are retryable.
`orchardctl nodes inspect` also renders an observe-only runtime memory-budget block in both human and `--json` output when the matching Runtime Endpoint snapshot reports memory-budget telemetry, and fails open by omitting the block when none is available.
`orchardctl nodes inspect` renders a counterfactual dispatch-capacity block in both human and `--json` output, showing what F11 enforcement would decide without changing dispatch behavior; the block reports the capacity management class, authority decision, Placement Capacity and placement headroom, and decision-specific available slots alongside the ceiling and limit values, and under `pre_cutover` it reports Effective Dispatch Limit and Dispatch Headroom `0`, exposes temporary legacy slots separately, and reports `consumers_ready` as `false` because the block itself is read-only observability, not the Controller capability declaration published on the membership heartbeat.
`orchardctl nodes cordon`, `orchardctl nodes uncordon`, `orchardctl nodes drain`, `orchardctl nodes cancel-drain`, `orchardctl nodes maintenance`, `orchardctl nodes resume`, and `orchardctl nodes decommission` add node lifecycle previews and execution on the shared Action Preview contract, gated by `--yes`, `--acknowledge`, and `--typed-node-id`; `orchardctl nodes cancel-drain` stops an in-progress drain and holds the node `cordoned`, allowed only from `draining` and otherwise reporting a `drain_not_running` blocker; `orchardctl nodes maintenance` previews only, with its `draining -> maintenance` execution deferred until drain completion can be verified.
Use the env-var split-role flows below for source-dev cluster testing.

### gRPC compatibility flow

The gRPC compatibility flow keeps all-in-one `bin/dev` on the controller Mac and starts one remote node-agent.
It uses `ORCHARD_RUNTIME_CLIENT_TARGETS` as a comma-separated `host:port` list.
This variable is gRPC-only and is not used by BEAM Runtime Endpoint mode.
For split-role compatibility testing, set `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc` on `bin/dev-controller` and `bin/dev-node-agent`.

#### Controller host

```bash
ORCHARD_RUNTIME_CLIENT_TARGETS="127.0.0.1:50071,<remote-tailscale-ip>:50071" \
  ORCHARD_NODE_DISPLAY_NAME=<controller-label> \
  mise exec -- bin/dev
```

The local node-agent still binds to `127.0.0.1:50071`.
The controller targets both local and remote gRPC nodes.
The scheduler auto-selects `MultiNode` whenever at least one target is configured.
Use a Tailscale IPv4 address such as `100.x.y.z` in the target list.
IPv6 addresses are not supported in the gRPC compatibility target list.

#### Remote node-agent host

```bash
ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc \
  ORCHARD_NODE_AGENT_LISTEN_HOST=0.0.0.0 \
  ORCHARD_NODE_AGENT_LISTEN_PORT=50071 \
  ORCHARD_WORKER_BACKEND=stub \
  ORCHARD_NODE_DISPLAY_NAME=<worker-label> \
  mise exec -- bin/dev-node-agent
```

The node-agent boots standalone.
It does not need Postgres, the controller, or asset watchers.
Use the `stub` backend for cluster mechanics testing.
Switch to `mlx` when real inference is required.
No `ORCHARD_WORKER_GENERATION_MODE` override is needed for the stub backend.
Source dev resolves stub mode to stream mode when the variable is unset.

### BEAM Runtime Endpoint flow

The BEAM flow uses named distributed BEAM nodes and `ORCHARD_RUNTIME_ENDPOINT_TARGETS`.
Do not use `ORCHARD_RUNTIME_CLIENT_TARGETS` for BEAM target selection.
The accepted two-Mac smoke should include a controller-side node-agent and a remote node-agent when validating local and remote Console reachability.
Start the node-agents first, then start the controller.

Provision the same `tmp/dev/beam.cookie` file on every participating Mac before starting the two-Mac BEAM flow.
Keep the cookie mode at `0600` or stricter.
Verify matching cookie files by comparing SHA-256 digests, not by printing cookie contents.
Do not commit cookie material, raw local evidence logs, or machine-specific paths.

#### Controller Mac local node-agent terminal

```bash
ORCHARD_BEAM_NODE_NAME=orchard_node_agent@<controller-ipv4> \
ORCHARD_BEAM_COOKIE_FILE="$PWD/tmp/dev/beam.cookie" \
ORCHARD_WORKER_BACKEND=stub \
ORCHARD_NODE_DISPLAY_NAME=<controller-node-agent-label> \
mise exec -- bin/dev-node-agent
```

#### Remote node-agent Mac terminal

```bash
ORCHARD_BEAM_NODE_NAME=orchard_node_agent@<worker-ipv4> \
ORCHARD_BEAM_COOKIE_FILE="$PWD/tmp/dev/beam.cookie" \
ORCHARD_WORKER_BACKEND=stub \
ORCHARD_NODE_DISPLAY_NAME=<worker-label> \
mise exec -- bin/dev-node-agent
```

#### Controller Mac controller terminal

```bash
ORCHARD_RUNTIME_ENDPOINT_TARGETS="orchard_node_agent@<controller-ipv4>,orchard_node_agent@<worker-ipv4>" \
ORCHARD_BEAM_NODE_NAME=orchard_controller@<controller-ipv4> \
ORCHARD_BEAM_COOKIE_FILE="$PWD/tmp/dev/beam.cookie" \
ORCHARD_NODE_DISPLAY_NAME=<controller-label> \
mise exec -- bin/dev-controller
```

The default controller distribution port is TCP `52171`.
The default node-agent distribution port is TCP `52172`.
The default EPMD port is TCP `4369`.
Those ports must be reachable between the participating private IPs.
If another EPMD already owns `4369`, set the same nonstandard `ORCHARD_BEAM_EPMD_PORT` on every participating terminal.
The validated two-Mac smokes used `ORCHARD_BEAM_EPMD_PORT=43690` on hosts with EPMD conflicts.
If you override the EPMD or distribution port variables, use the same values in your firewall rules and smoke notes.

For a remote Runtime Endpoint RPC check from the controller IEx session:

```elixir
target = %{transport: :beam, address: "orchard_node_agent@<worker-ipv4>"}
{:ok, conn} = Orchard.RuntimeEndpoint.BeamClient.connect(target)
{:ok, observation} = Orchard.RuntimeEndpoint.BeamClient.status(conn)
observation
```

This check exercises the BEAM Runtime Endpoint adapter.
It does not prove the gRPC compatibility path.
It should fail visibly if EPMD, distribution ports, cookies, target identity, or guardrails are wrong.
It should not fall back to gRPC.

### Verification

1. Console Nodes should show the configured Runtime Endpoint targets with distinct display names and reachable status.
2. The BEAM smoke should include both the controller-side node-agent and the remote node-agent when validating local and remote reachability.
3. `GET /v1/models` should return `200`.
4. `POST /v1/chat/completions` should complete through the Console Playground or an equivalent API request.
5. Cluster summary should show the configured target count for the selected transport.
6. Playground inference should attribute requests to specific nodes when the scheduler has multiple eligible targets.
7. Killing the remote node-agent should transition its health to degraded or unreachable.

Do not commit smoke evidence notes or investigation documents; record smoke evidence in the promoting pull request, issue, or decision record, and only for smokes that actually ran.
When recording that evidence, sanitize host labels, commands, node names, pass/fail status, and Runtime Endpoint RPC evidence.
The evidence must not include cookie material, credentials, raw logs, prompt exports, local tool session identifiers, DSNs, or machine-specific filesystem paths.
BEAM split-role default promotion was accepted on 2026-07-05 after the smoke evidence gate passed.

### Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| gRPC controller shows 1 target | `ORCHARD_RUNTIME_CLIENT_TARGETS` unset or malformed | Check env var, use `host:port,host:port` format. |
| BEAM controller exits before Mix starts | `ORCHARD_RUNTIME_ENDPOINT_TARGETS` is empty, malformed, or uses a hostname or IPv6 address | Use comma-separated `orchard_node_agent@<ipv4-literal>` targets. |
| All-in-one `bin/dev` rejects BEAM mode | `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam` was set with the all-in-one entrypoint | Use `bin/dev-controller` and `bin/dev-node-agent` for BEAM mode. |
| BEAM node-name validation fails | `ORCHARD_BEAM_NODE_NAME` is not `service@ipv4` or uses the wrong role service | Use `orchard_controller@<controller-ipv4>` for the controller and exactly `orchard_node_agent@<node-ipv4>` for node-agents. |
| BEAM cookie validation fails | Cookie file is missing, empty, or group/world-readable | Create or copy the cookie file, then run `chmod 600 tmp/dev/beam.cookie`. |
| BEAM `connect` returns `:pang` or `:unknown_beam_node` | EPMD cannot resolve the target, the target node is not running, or the cookie does not match | Check `ERL_EPMD_PORT`, node names, cookie digest match, and `nc -vz <target-ipv4> 4369`. |
| BEAM RPC times out or is unreachable | Distribution listener port is blocked | Check TCP `52171` for the controller and TCP `52172` for node-agents, or check your overridden range. |
| BEAM Console shows stale gRPC expectations | gRPC targets were configured as a comparison path | Use Console Runtime Endpoint target diagnostics and remember that `ORCHARD_RUNTIME_CLIENT_TARGETS` is not a BEAM fallback. |
| Remote gRPC node-agent unreachable | Listen host still `127.0.0.1` | Set `ORCHARD_NODE_AGENT_LISTEN_HOST=0.0.0.0` for the gRPC compatibility flow. |
| Requests to an admitted Node return busy instead of dispatching | The Controller could not assemble that Node's capacity facts from current authenticated evidence — probe failure, stale observation, or missing policy — so capacity authorization fails closed rather than trusting telemetry | Check the Node's trust, lifecycle, health, and observation freshness, and read the persisted scheduler explanation for `dispatch_capacity_facts_unavailable` with `orchardctl requests inspect <request-id>`. |
| A Node stops taking any dispatch after a cancelled or timed-out request | The Controller could not resolve whether that request's runtime execution ended, so the allocation authority quarantined the Node and now evaluates it as unreachable | Expected fail-closed behavior in source dev: confirm the Node has no orphaned execution, then restart the Controller, since quarantine has no expiry and no operator-release seam yet. |
| Every Node stops taking dispatch at once with no capacity change | The Controller-local quarantine store stopped; it is a temporary child that is not restarted, and the authority blocks all dispatch rather than resuming from a clean quarantine set | Restart the Controller and check its logs for `dispatch-capacity quarantine store stopped`, or for `dispatch-capacity authority started without a reachable quarantine store` when the store was already gone at boot. |
| Remote node fails on MLX | mise toolchain not installed or no `uv sync` | Use `ORCHARD_WORKER_BACKEND=stub` or run `mise exec -- uv sync --locked --directory native/orchard_worker_mlx --extra mlx`. |
| Port conflict on remote gRPC node-agent | Another BEAM or node-agent owns the gRPC port | Change `ORCHARD_NODE_AGENT_LISTEN_PORT`. |

> **Security note:** Binding gRPC to `0.0.0.0` exposes the gRPC server on all interfaces.
> Use it only on trusted networks such as Tailscale or a private LAN.
> Source-dev gRPC has no TLS, so rely on the private network for wire encryption.

### Source-dev BEAM Peer Grant tracer (experimental)

`bin/source-dev-peer-grant` drives the narrow one-Controller, one-Node BEAM Peer
Grant tracer described by ADR 0012 and `SPEC.md` §7.5 and §10.6.
It exercises certificate-bound scoped grants, certificate-authenticated grant
delivery, owner-only custody, and TLS 1.3 Distribution launch without the legacy
shared cookie.
It is a source-development-only path; root-owned packaged and two-Mac acceptance
remain future work, and the packaged runbook above still uses the shared-cookie
first cut.

The helper refuses `ORCHARD_BEAM_COOKIE_FILE`, `ORCHARD_RUNTIME_ENDPOINT_TARGETS`,
and `ORCHARD_RUNTIME_CLIENT_TARGETS`, because peer-grant Distribution derives its
authorization and targets from the grant descriptor and trusted inventory rather
than from static cookie or target overrides.
There is no silent gRPC fallback; the gRPC/mTLS control path is used only for the
explicit grant-delivery step.

Subcommands:

| Subcommand | Role | Purpose |
|------------|------|---------|
| `controller-control` | controller | Start the controller in `grant_control` mode so it serves the certificate-authenticated grant-delivery control listener. |
| `node-retrieve` | node-agent | Retrieve the scoped grant over gRPC/mTLS and persist it under owner-only custody. |
| `node-preflight` | node-agent | Prepare the node's TLS Distribution launch manifest and `ssl-dist` optfile from the stored grant. |
| `controller-preflight` | controller | Prepare the controller's TLS Distribution launch from the grant descriptor. |
| `node-run` | node-agent | Start `bin/dev-node-agent` with distributed BEAM using the prepared manifest and optfile. |
| `controller-run` | controller | Start `bin/dev-controller` in `distributed` mode using the prepared manifest and optfile. |

Env surface:

| Variable | Default | Description |
|----------|---------|-------------|
| `ORCHARD_BEAM_PEER_GRANT_STATE_ROOT` | `tmp/dev/beam-peer-grant` | Owner-only (`0700`) root for per-role launch manifests, `ssl-dist` optfiles, and grant state. |
| `ORCHARD_BEAM_PEER_GRANT_CONTROL_HOST` | _(required, controller)_ | Private, non-loopback IPv4 address the grant-delivery control listener binds. |
| `ORCHARD_BEAM_PEER_GRANT_CONTROL_PORT` | _(required, controller)_ | Port for the grant-delivery control listener. |
| `ORCHARD_BEAM_AUTHORIZATION_ROOT_PATH` | _(required, controller)_ | Path to the Controller-local BEAM Authorization Root that derives pair-secret material. |
| `ORCHARD_CONTROLLER_MEMBERSHIP_HOST` | _(required, controller)_ | Private, non-loopback IPv4 address that fixes the Controller's durable canonical BEAM name across both tracer phases. It is independent of the control listener host and must match the `ORCHARD_BEAM_NODE_NAME` host in `distributed` mode. |
| `ORCHARD_NODE_TRUST_ROOT` | _(required, controller preflight/run)_ | Controller node-trust root used by the distributed controller preflight and run; conventionally `tmp/dev/node-trust` in source dev. |
| `ORCHARD_NODE_IDENTITY_ROOT` | _(required, node)_ | Owner-only node identity root holding the Node key, Node Certificate, and stored grant; conventionally `tmp/dev/config/node-identity` in source dev. |
| `ORCHARD_BEAM_PEER_GRANT_DESCRIPTOR` | _(required, node; controller preflight)_ | Path to the grant descriptor that binds the exact Controller-to-Node pair. |
| `ORCHARD_BEAM_NODE_NAME` | _(required)_ | Long BEAM node name for the current role. In grant mode the node-agent service must be `orchard_node_agent_<32-hex>@<ipv4-literal>` and the distributed controller service must be `orchard_controller_<32-hex>@<ipv4-literal>`. |

`ORCHARD_BEAM_PEER_GRANTS_ENABLED`, `ORCHARD_BEAM_PEER_GRANT_MODE`
(`grant_control` or `distributed`), `ORCHARD_BEAM_DISTRIBUTION_LAUNCH_MANIFEST`,
and `ORCHARD_BEAM_SSL_DIST_OPTFILE` are set by the helper per subcommand and
normally do not need to be exported by hand.
Peer-grant mode requires `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam`; the helper
sets it.

The tracer and its supporting flows are validated by
`scripts/test-beam-peer-grant-tracer.sh`,
`scripts/test-beam-peer-grant-application-smoke.sh`,
`scripts/test-beam-peer-grant-expiry-smoke.sh`,
`scripts/test-beam-legacy-first-connect-smoke.sh`, and
`scripts/test-source-dev-beam-bootstrap.sh`.

## Testing

```bash
# Full test suite (uses fake runtime, no GPU needed)
mise exec -- mix test

# If another worktree already owns the default test node-agent port
ORCHARD_TEST_NODE_AGENT_PORT=50171 mise exec -- mix test

# With coverage
mise exec -- mix test --cover

# Strict checks
mise exec -- mix credo --strict
mise exec -- mix dialyzer
```

## Apple Silicon MLX Smoke Tests

Opt-in smoke tests verify real MLX inference on Apple Silicon hardware. These are
separate from `mix test`, which uses the fake/stub runtime and requires no GPU.

### Prerequisites

- Apple Silicon Mac (M1/M2/M3/M4)
- A local Orchard model bundle directory (not downloaded by the script)
- `make setup` already run in the repo, or the equivalent manual setup commands
  from [Quick Start](#quick-start)

### Required Environment Variable

| Variable | Required | Description |
|----------|----------|-------------|
| `ORCHARD_MLX_SMOKE_MODEL_PATH` | Yes | Absolute path to an Orchard model bundle directory containing `manifest.json` |

Both Python and Elixir smoke tests gate on this variable. When unset, the smoke
tests are skipped (Python) or not compiled (Elixir).

### Running the Smoke Script

```bash
export ORCHARD_MLX_SMOKE_MODEL_PATH=/path/to/your/orchard-bundle
mise exec -- ./scripts/smoke-mlx.sh
```

The script can be invoked from any directory — it resolves the repo root from
its own location.

### What the Script Does

1. **Validates** platform (macOS arm64), tooling (`uv`, `mix` through the
   mise-pinned toolchain), repo layout, and the bundle path (exists, is a
   directory, contains `manifest.json`)
2. **Python smoke** (step 1/2): installs MLX extras (`uv sync --extra mlx`)
   then runs `pytest tests/test_cli.py -k mlx_backend_real -v` in the worker
   package — exercises real model load/unload and streaming generation via gRPC
3. **Elixir smoke** (step 2/2): runs
   `mise exec -- mix test apps/orchard_node_agent/test/orchard_node_agent_test.exs --only mlx_smoke`
   from the repo root — exercises the full node-agent stack including acquisition,
   worker lifecycle, and gRPC inference

Python runs first because it tests the lower-level worker directly. If Python
fails, Elixir smoke is skipped (the full stack depends on a working worker).

### Expected Output

Test runner output streams live. The script ends with a summary block:

```text
=== Orchard MLX smoke summary ===
Bundle:        /path/to/your/orchard-bundle
Python smoke:  PASS
Elixir smoke:  PASS
Overall:       PASS
```

On failure:

```text
=== Orchard MLX smoke summary ===
Bundle:        /path/to/your/orchard-bundle
Python smoke:  FAIL (exit 1)
Elixir smoke:  NOT RUN
Overall:       FAIL
Reason:        Python smoke tests failed
```

### Exit Codes

- **0** — all smoke tests passed
- **1** — validation failure or any smoke test failure

### Running Individual Smoke Tests

You can also run each smoke suite independently:

```bash
export ORCHARD_MLX_SMOKE_MODEL_PATH=/path/to/your/orchard-bundle

# Python only
cd native/orchard_worker_mlx
mise exec -- uv sync --locked --extra mlx
mise exec -- uv run pytest tests/test_cli.py -k mlx_backend_real -v

# Elixir only, from the repo root
cd ../..
mise exec -- mix test apps/orchard_node_agent/test/orchard_node_agent_test.exs --only mlx_smoke
```

## Preparing a Smoke Test Bundle from HuggingFace

The smoke tests require an **Orchard bundle** — a directory containing a
`manifest.json` plus model files. HuggingFace MLX models don't include this
manifest, so you must create a wrapper bundle.

### Quick Setup

```bash
# 1. Download a small MLX model (if not already cached).
# This helper is convenience-only, not a build or validation gate.
mise exec -- uvx --from huggingface-hub \
  huggingface-cli download mlx-community/Llama-3.2-1B-Instruct-4bit

# 2. Create a bundle directory with copies of the model files
BUNDLE_DIR="$HOME/Models/orchard-smoke/llama-3.2-1b-instruct-4bit"
mkdir -p "$BUNDLE_DIR"

HF_SNAPSHOT="$HOME/.cache/huggingface/hub/models--mlx-community--Llama-3.2-1B-Instruct-4bit/snapshots/<commit-hash>"
for f in config.json model.safetensors model.safetensors.index.json \
         tokenizer.json tokenizer_config.json special_tokens_map.json; do
    cp -L "$HF_SNAPSHOT/$f" "$BUNDLE_DIR/$f"
done

# 3. Create manifest.json
cat > "$BUNDLE_DIR/manifest.json" << 'EOF'
{
  "model_id": "mlx-community/Llama-3.2-1B-Instruct-4bit",
  "version": "08231374eeacb049a0eade7922910865b8fce912",
  "format": "mlx",
  "artifact_layout": "directory",
  "entrypoint": ".",
  "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
  "size_bytes": 696254464,
  "max_context_tokens": 131072,
  "capabilities": ["chat"],
  "tokenizer": {
    "kind": "huggingface_tokenizer_json",
    "path": "tokenizer.json"
  },
  "runtime_requirements": {
    "adapter": "mlx_lm",
    "min_agent_capability": "mlx"
  }
}
EOF
```

**Important:** Use `cp -L` (follow symlinks), not `ln -s`. The worker's
bundle-path validation rejects symlinks that resolve outside the bundle root.

### Manifest Field Reference

| Field | Value | Notes |
|-------|-------|-------|
| `model_id` | HF repo name | e.g. `mlx-community/Llama-3.2-1B-Instruct-4bit` |
| `version` | HF commit hash | Pin for reproducibility |
| `format` | `"mlx"` | Required |
| `artifact_layout` | `"directory"` | Required |
| `entrypoint` | `"."` | Path to model weights dir (`.` = bundle root) |
| `sha256` | 64-char hex | Placeholder OK for smoke; real value for production |
| `max_context_tokens` | From `config.json` `max_position_embeddings` | |
| `tokenizer.kind` | `"huggingface_tokenizer_json"` | Required |
| `tokenizer.path` | `"tokenizer.json"` | Relative to bundle root |
| `runtime_requirements.adapter` | `"mlx_lm"` | Required |
| `runtime_requirements.min_agent_capability` | `"mlx"` | Required |

### Recommended Smoke Models

| Model | Size | Load Time (M3 Max) | Notes |
|-------|------|--------------------|-------|
| `mlx-community/Llama-3.2-1B-Instruct-4bit` | ~664 MB | ~1.5s | Fastest, recommended for CI |
| `mlx-community/Qwen2.5-7B-Instruct-4bit` | ~4.5 GB | ~5s | Good mid-size validation |

## Licensing v0 notes

### Contract

- Orchard persists one Orchard-owned local bundle at
  `<support_root>/config/licensing/current.json`.
- The bundle stores only the extracted certificate pair:
  - `license_certificate`
  - `machine_certificate`
- `orchardctl license activate --key-stdin` and
  `orchardctl license activate --key-file PATH` use the stable Orchard node ID
  as the machine fingerprint, check out both certificates, verify them offline,
  and install the pair atomically without putting the activation key in process
  arguments.
- Failed activation keeps the previous local bundle untouched.
- Orchard does **not** persist Keygen JSON envelopes as runtime state and does
  **not** ship a Keygen admin token dependency.

### Observation surfaces

- `orchardctl license status` inspects only local licensing state; it does not
  contact the controller.
- Controller `/health/ready` exposes license state for observation only; it
  remains **non-gating** and does not change readiness reasons or HTTP status.
- `orchardctl status` renders the controller's additive license payload when it
  is present.

### Optional tracking metadata

License certificates may include optional AIEH/100E/SIP tracking metadata under
the signed Keygen payload's `data.attributes.metadata` object. Orchard accepts
both nested key forms: `orchardTracking` (observed Keygen checkout payload) and
`orchard_tracking` (compatibility alias). Orchard extracts only the tracking
`program` and `reference` fields and treats them as observational, non-gating
attribution data.

Recommended program values:

- `aieh`
- `100e`
- `sip`

Tracking metadata is derived only from the signed certificate payload. It is not
persisted outside the certificate pair, and `current.json` continues to contain
only `license_certificate` and `machine_certificate`. Missing or malformed
tracking metadata does not affect license validity or startup enforcement.

When present, tracking metadata appears in:

- `orchardctl license status`
- Controller `/health/ready` JSON under `license.tracking`
- `orchardctl status`, rendered from the controller health payload

### Licensing environment variables

| Variable | Default | Notes |
|----------|---------|-------|
| `ORCHARD_LICENSE_ENFORCEMENT` | `off` (source dev/test) / `hard` (distributed packaged channels) | Node-agent startup and packaged useful-work admission mode: `off`, `warn`, `hard` |
| `ORCHARD_LICENSE_BUNDLE_PATH` | `<support_root>/config/licensing/current.json` | Rare override for Orchard-directed alternate layouts/debugging |
| `ORCHARD_NODE_IDENTITY_PATH` | `<support_root>/data/node-id` | Override only when Orchard support-root layout is intentionally changed |
| `ORCHARD_NODE_IDENTITY_ROOT` | `<support_root>/config/node-identity` | Owner-only root for the Node key, issued Node Certificate, and runtime trust persisted during `orchardctl node join`; override only when the support-root layout is intentionally changed |
| `ORCHARD_KEYGEN_API_BASE_URL` | `https://api.keygen.sh` | Optional override for Orchard-directed alternate environments |
| `ORCHARD_KEYGEN_ACCOUNT_ID` | built-in Orchard Keygen account ID | Optional override; keep paired with matching public key |
| `ORCHARD_KEYGEN_PUBLIC_KEY` | built-in Orchard Ed25519 verification key | Optional override; keep paired with matching account ID |

### Rollout and rollback posture

- Source dev/test defaults to `off`; distributed packaged channels default to `hard`. Use an explicit `warn` override only for a deliberately waived rollout/rehearsal.
- Node-agent licensing is checked at startup and at packaged useful-work admission points; source dev/test defaults keep it off unless explicitly enabled.
- To remove runtime licensing impact quickly, set
  `ORCHARD_LICENSE_ENFORCEMENT=off` and restart the node-agent (or the dev app
  process when validating from source).

### Confidence caveat

Packaged-host lifecycle smoke was completed on 2026-04-18 for the current PKG lifecycle surface (`orchardctl status`, `start`, and `stop`), including non-root status checks. Treat that as historical packaged verification context rather than an active source-dev gate.

## Rollback Procedure

Orchard supports a binary backend switch: `mlx` (real inference) or `stub`
(no-op responses). Rollback means switching the worker backend.

### Development (Source Checkout)

```bash
# Switch to stub backend
export ORCHARD_WORKER_BACKEND=stub

# Restart the app
mise exec -- iex -S mix phx.server
```

Verify: the node-agent log will show `worker starting backend=stub`. No
generation-mode override is required; `stub` resolves to stream mode when the
mode env var is unset.

### Packaged Install (launchd)

Env file overrides let you change service configuration without editing
launchd plists. The node-agent env file controls the worker backend; the
controller env file can override database URL, ports, or other settings.

```bash
# 1. Create/edit the node-agent env file (must be root-owned, mode 0600)
sudo mkdir -p "/Library/Application Support/Orchard/config"
echo 'ORCHARD_WORKER_BACKEND=stub' | sudo tee \
  "/Library/Application Support/Orchard/config/node-agent.env"
sudo chmod 600 "/Library/Application Support/Orchard/config/node-agent.env"

# 2. Restart the node-agent service
sudo launchctl kickstart -k system/com.orchard.node-agent
```

To restore MLX:

```bash
# Remove the override (or set back to mlx)
sudo rm "/Library/Application Support/Orchard/config/node-agent.env"
sudo launchctl kickstart -k system/com.orchard.node-agent
```

> **Note:** The wrapper scripts validate env file ownership and permissions
> before sourcing. Files not owned by root or with group/world permissions
> are ignored with a warning in the service logs.

### Verification After Rollback

1. Check service is running: `sudo launchctl list | grep orchard`
2. Check backend in logs: look for `worker starting backend=stub` or `backend=mlx`
3. Test source-dev liveness: `curl http://localhost:4000/health/live`
4. Run a chat completion — stub returns canned responses, mlx returns real inference

## Smoke Test Troubleshooting

`orchardctl requests inspect <request-id>` reads the local controller Repo and renders the persisted scheduler explanation for a request, with stable human and `--json` output from the shared Operator API presenter.
Broader request execution diagnostics beyond persisted scheduler explanations remain future work.
`orchardctl support bundle create` creates a
local diagnostic `.tar.gz` containing bounded redacted logs, redacted config,
service status, node snapshots, shared cluster-management node status, and
request summaries; use `--support-root` and
`--output` to point it at an isolated source-dev fixture. Use
`--max-log-bytes` to cap each retained log tail and `--json` when scripting
bundle creation. It records `support_bundle.generated` only when the controller
Repo is already available. `orchardctl nodes list --json` emits the same shared
cluster-management node status contract for scripting node inventory checks.
Console request views, health/readiness endpoints,
and controller or node-agent logs remain useful for interactive source-dev
diagnostics.

| Failure | Likely Cause | Where to Look |
|---------|-------------|---------------|
| `Bundle is missing manifest.json` | Bundle not prepared correctly | Re-run bundle prep steps above |
| `bundle_path_escape` | Symlinks in bundle dir | Use `cp -L` instead of `ln -s` |
| `model_load_failed` | MLX/mlx-lm version mismatch | Check `mise exec -- uv sync --locked --directory native/orchard_worker_mlx --extra mlx` ran, inspect worker logs |
| `unsupported_runtime_adapter` | Wrong `adapter` in manifest | Must be `"mlx_lm"` |
| `tokenizer_missing` | Wrong `tokenizer.path` | Check `tokenizer.json` exists in bundle |
| Python smoke timeout | Model too large for hardware | Use smaller model (1B recommended) |
| Elixir smoke failure | Node-agent/worker lifecycle issue | Check worker stdout/stderr |
| `mlx_backend_unavailable` | MLX extras not installed | Run `mise exec -- uv sync --locked --directory native/orchard_worker_mlx --extra mlx` |

## Releases (Production)

Three release targets are defined:

| Release | Apps | Purpose |
|---------|------|---------|
| `orchard_controller` | shared + controller | HTTP API + dispatch |
| `orchard_node_agent` | shared + node-agent | gRPC runtime server |
| `orchard_cli` | shared + controller + cli | `orchardctl` CLI |

```bash
# Build a release
MIX_ENV=prod mise exec -- mix release orchard_controller

# Run migrations
_build/prod/rel/orchard_controller/bin/orchard_controller eval 'Orchard.Release.migrate()'

# Start
DATABASE_URL=postgres://... SECRET_KEY_BASE=... \
  _build/prod/rel/orchard_controller/bin/orchard_controller start
```

Required production env vars:
- `DATABASE_URL` — Postgres connection string
- `SECRET_KEY_BASE` — Phoenix secret (min 64 bytes)
- `ORCHARD_SUPPORT_ROOT` — Base directory for artifacts/models/sockets (default: `/Library/Application Support/Orchard`)

## Startup Order

All-in-one local boot (dev):

1. PostgreSQL must be running
2. Run `make dev` or `mise exec -- bin/dev` — this handles DB bootstrap and server start:
   - Creates `orchard_dev` database if missing
   - Runs pending migrations
   - Exports dev gRPC port (50071)
   - Starts `iex -S mix phx.server`
   - Controller boots: Endpoint, Repo, membership owner, Inference supervisor, Runtime Endpoint clients
   - Node-agent boots: ModelManager, WorkerSupervisor, Runtime Endpoint task supervisor, gRPC server
3. Import at least one model bundle with `OrchardCLI.main(["models", "import", "<path>", "--activate"])`
4. Create an Organization and API Token with `OrchardCLI.main(["tenants", ...])` and
   `OrchardCLI.main(["api-keys", ...])`
5. Source-dev HTTP is live at `/health/live`; `/health/ready` can remain
   degraded under the default `plain_http_localhost` transport until HTTPS or a
   reverse proxy is configured.
6. API routes are reachable over loopback HTTP for authenticated local testing.

Alternatively, for advanced debugging or when you need a BEAM without the
HTTP server, you can run the steps manually:

```bash
export MIX_ENV=dev
export ORCHARD_NODE_AGENT_LISTEN_PORT=50071
export ORCHARD_RUNTIME_CLIENT_PORT=50071
mise exec -- mix ecto.create
mise exec -- mix ecto.migrate
mise exec -- iex -S mix phx.server
```

## Current Source-Dev Limitations

- Source dev controller uses loopback HTTP (`127.0.0.1:4000`); packaged
  installs default to degraded loopback HTTP until an operator selects
  `reverse_proxy` or `direct_https` (see [Transport Modes](#transport-modes))
- Source dev gRPC on port 50071; packaged installs on 50061
- Source-dev node-agent gRPC remains loopback and non-TLS
- Public `/v1/*` API routes require Bearer API Tokens.
  Tenant-direct API Tokens remain supported, and service-account-owned API Tokens require an enabled API Client with tenant-scoped `inference_client` access.
  Full quota policy remains incomplete
- Multi-node is supported for source-dev testing and the packaged external-sites multi-Mac BEAM cut documented in the [packaging README](../packaging/pkg/README.md#packaged-external-sites-multi-mac-first-cut); broader production multi-node scheduling remains M4
- Split-role BEAM Runtime Endpoint mode is the default for `bin/dev-controller` and `bin/dev-node-agent`
- All-in-one `bin/dev` rejects explicit `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam`
- gRPC compatibility remains available for split-role source dev only through `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc`
- Model import from local filesystem only (no remote download)
