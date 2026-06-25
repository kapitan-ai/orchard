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
pg_isready -h localhost
```

The dev config defaults to `PGUSER=postgres`, `PGPASSWORD=postgres`,
`PGHOST=localhost`, and `PGDATABASE=orchard_dev`. Either create that local role
with database-create privileges, or export `PGUSER`/`PGPASSWORD` for an
existing local superuser before running `make dev`.

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
mise exec -- uv sync --directory native/orchard_tokenizer
mise exec -- uv sync --directory native/orchard_worker_mlx
mise exec -- npm ci --ignore-scripts
mise exec -- bin/dev
```

```elixir
# 3. Import a model bundle (in the running IEx session)
OrchardCLI.main(["models", "import", "/path/to/model-bundle", "--activate"])

# 4. Create a tenant and API key for /v1 API calls (in the running IEx session)
OrchardCLI.main(["tenants", "create", "--slug", "dev", "--name", "Dev"])
OrchardCLI.main(["api-keys", "create", "--tenant-id", "<tenant-id>", "--name", "dev"])
```

`make dev` wraps `mise exec -- bin/dev`. `bin/dev` is the single low-level
entrypoint for source development. It creates the dev database if missing, runs
migrations, and starts `iex -S mix phx.server` with the dev gRPC port set to
**50071** (avoiding conflict with the packaged BEAM on 50061).

The controller listens on `http://localhost:4000` and the node-agent
gRPC server on `127.0.0.1:50071`.
Copy the API key token printed by `api-keys create` into
`ORCHARD_API_KEY` for the `curl` examples below.

## Transport Modes

Orchard has two transport profiles:

### Source dev (this page)

When running from a source checkout (`make dev`, `mise exec -- bin/dev`, or
`mise exec -- iex -S mix phx.server`):

- Controller listens on **HTTP** at `http://127.0.0.1:4000`
- Node-agent gRPC listens on `127.0.0.1:50071` (avoids packaged BEAM on 50061)
- Public `/v1/*` API routes require `Authorization: Bearer <api_key>`
- CORS is disabled (empty allowlist in `config/dev.exs`)
- No TLS setup is required

All `curl` examples in this document use plain HTTP because they target the
source dev controller. API examples assume `ORCHARD_API_KEY` contains a
tenant-scoped API key token.

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
| `PGDATABASE` | `orchard_dev` | Database name |

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
| `ORCHARD_RUNTIME_CLIENT_PORT` | Same as listen port | Controller gRPC client port (must match listen port) |
| `ORCHARD_MODELS_ROOT` | `tmp/dev/models` | Model artifact storage |
| `ORCHARD_WORKER_SOCKET_DIR` | `tmp/dev/data/worker-sockets` | Worker UDS directory |
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
`ORCHARD_FAKE_RUNTIME` is a release/runtime config knob; source-dev tests use
the fake runtime through `config/test.exs`, not a dev env override.
Batch generation mode can admit multiple same-model requests up to the worker-reported limit.
The node agent also enforces aggregate active request capacity across loaded models using the resolved worker limits, conservatively falling back to single-request capacity when worker status omits `max_concurrency`.
The node-agent reports aggregate and placement capacity through the current gRPC compatibility status response.
The controller maps that response into Runtime Endpoint Observations before multi-node scheduler candidate filtering and queue wakeups from loaded-placement or cold/no-placement capacity.
Transport failures and ineligible Runtime Endpoint Observations clear endpoint-owned queue capacity sources so queued work is not promoted against stale loaded-placement or cold/no-placement slots.
Stream mode reports max concurrency as `1` at both node and placement levels.

#### Controller Multi-Node (Source Dev)

| Variable | Default | Description |
|----------|---------|-------------|
| `ORCHARD_RUNTIME_CLIENT_HOST` | `127.0.0.1` | Controller’s local gRPC target host |
| `ORCHARD_RUNTIME_CLIENT_TARGETS` | _(empty)_ | Comma-separated `host:port` list for multi-node scheduling. When set with >1 target, the scheduler auto-selects `MultiNode`. |

#### Runtime Endpoint BEAM Guardrails

The current source-dev slice includes a default-off BEAM Runtime Endpoint adapter, Node Agent facade, and guardrail config under `:orchard_controller, :runtime_endpoint, beam: [...]`.
The adapter is implemented behind explicit application config, but source dev keeps using the gRPC compatibility adapter on port `50071` until the accepted two-Mac smoke passes.
There is no supported source-dev env var surface for BEAM target selection in this slice.
The accepted target is for BEAM Runtime Endpoint transport to become the primary source-dev Controller-to-Node Agent path after that smoke passes.
The accepted smoke requires Console Nodes to show local and remote Node Agents reachable, `GET /v1/models` to return `200`, and `POST /v1/chat/completions` to complete through the Console Playground or an equivalent API request.

If enabled directly in application config for future work, guardrail validation requires non-empty `node_name`, `cookie_file`, `listen_host`, `admitted_services`, and `allowed_cidrs`.
The `listen_host` must not be `0.0.0.0` or `::`, and `allowed_cidrs` must not contain `0.0.0.0/0` or `::/0`.

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

### Dev Directory Structure

Dev mode uses `tmp/dev/` under the repo root:

```
tmp/dev/
├── bundles/           # Imported model artifacts (controller)
├── models/            # Model files (node-agent)
└── data/
    └── worker-sockets/ # Worker Unix domain sockets
```

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

Single-node remains the default. To opt into 2-node source-dev testing
with a remote machine (e.g., Tamingsari as node-agent, mawarduri as
controller):

`orchardctl cluster init`, `orchardctl node join`, and
`orchardctl nodes admit` are SPEC-required future node-lifecycle commands. In
this build they return deferred status; use the env-var split-role flow below
for source-dev cluster testing.

### Controller host (mawarduri)

```bash
ORCHARD_RUNTIME_CLIENT_TARGETS="127.0.0.1:50071,<remote-tailscale-ip>:50071" \
  ORCHARD_NODE_DISPLAY_NAME=mawarduri \
  mise exec -- bin/dev
```

The local node-agent still binds to `127.0.0.1:50071`. The controller targets
both local and remote nodes. The scheduler auto-selects `MultiNode` when it
sees >1 target. Use the Tailscale IPv4 address (`100.x.y.z`) — IPv6 addresses
are not supported in the target list.

### Remote node-agent host (Tamingsari)

```bash
ORCHARD_NODE_AGENT_LISTEN_HOST=0.0.0.0 \
  ORCHARD_NODE_AGENT_LISTEN_PORT=50071 \
  ORCHARD_WORKER_BACKEND=stub \
  ORCHARD_NODE_DISPLAY_NAME=tamingsari \
  mise exec -- bin/dev-node-agent
```

The node-agent boots standalone — no Postgres, controller, or asset watchers
needed. Use `stub` backend for cluster mechanics testing; switch to `mlx` when
real inference is required. No `ORCHARD_WORKER_GENERATION_MODE` override is
needed for the stub backend; source dev resolves it to stream mode when unset.

### Verification

1. Both nodes should appear in `/console/nodes` with distinct display names and reachable status
2. `GET /v1/models` should return `200`
3. `POST /v1/chat/completions` should complete through the Console Playground or an equivalent API request
4. Cluster summary should show 2 configured targets
5. Playground inference should attribute requests to specific nodes
6. Killing the remote node-agent should transition its health to
   degraded/unreachable

### Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Controller shows 1 target | `ORCHARD_RUNTIME_CLIENT_TARGETS` unset or malformed | Check env var, use `host:port,host:port` format |
| Remote node-agent unreachable | Listen host still `127.0.0.1` | Set `ORCHARD_NODE_AGENT_LISTEN_HOST=0.0.0.0` |
| Remote node fails on MLX | mise toolchain not installed or no `uv sync` | Use `ORCHARD_WORKER_BACKEND=stub` or run `mise exec -- uv sync --directory native/orchard_worker_mlx --extra mlx` |
| Port conflict on remote | Another BEAM on same port | Change `ORCHARD_NODE_AGENT_LISTEN_PORT` |

> **Security note:** Binding to `0.0.0.0` exposes the gRPC server on all
> interfaces. Use only on trusted networks (Tailscale, private LAN). Source-dev
> gRPC has no TLS — Tailscale provides wire encryption.

## Testing

```bash
# Full test suite (uses fake runtime, no GPU needed)
mise exec -- mix test

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
mise exec -- uv sync --extra mlx
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

`orchardctl requests inspect` is a SPEC-required diagnostics path that returns
deferred status in this build. `orchardctl support bundle create` creates a
local diagnostic `.tar.gz` containing bounded redacted logs, redacted config,
service status, node snapshots, and request summaries; use `--support-root` and
`--output` to point it at an isolated source-dev fixture. Use
`--max-log-bytes` to cap each retained log tail and `--json` when scripting
bundle creation. It records `support_bundle.generated` only when the controller
Repo is already available. Console request views, health/readiness endpoints,
and controller or node-agent logs remain useful for interactive source-dev
diagnostics.

| Failure | Likely Cause | Where to Look |
|---------|-------------|---------------|
| `Bundle is missing manifest.json` | Bundle not prepared correctly | Re-run bundle prep steps above |
| `bundle_path_escape` | Symlinks in bundle dir | Use `cp -L` instead of `ln -s` |
| `model_load_failed` | MLX/mlx-lm version mismatch | Check `mise exec -- uv sync --directory native/orchard_worker_mlx --extra mlx` ran, inspect worker logs |
| `unsupported_runtime_adapter` | Wrong `adapter` in manifest | Must be `"mlx_lm"` |
| `tokenizer_missing` | Wrong `tokenizer.path` | Check `tokenizer.json` exists in bundle |
| Python smoke timeout | Model too large for hardware | Use smaller model (1B recommended) |
| Elixir smoke failure | Node-agent/worker lifecycle issue | Check worker stdout/stderr |
| `mlx_backend_unavailable` | MLX extras not installed | Run `mise exec -- uv sync --directory native/orchard_worker_mlx --extra mlx` |

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
   - Controller boots: Endpoint, Repo, Inference supervisor, gRPC client
   - Node-agent boots: ModelManager, WorkerSupervisor, gRPC server
3. Import at least one model bundle with `OrchardCLI.main(["models", "import", "<path>", "--activate"])`
4. Create a tenant and API key with `OrchardCLI.main(["tenants", ...])` and
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
- Public `/v1/*` API routes require tenant-scoped Bearer API keys; full RBAC and
  quota policy remain incomplete
- Multi-node is supported for source-dev testing only (production/packaged multi-node — M4)
- Live BEAM Runtime Endpoint transport is implemented behind default-off application config; current source dev uses the gRPC compatibility adapter
- BEAM Runtime Endpoint transport becomes the primary source-dev path only after it passes the accepted two-Mac smoke
- Model import from local filesystem only (no remote download)
