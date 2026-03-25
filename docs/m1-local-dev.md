# M1 Local Development

Local development setup for the Orchard inference stack. Default mode is
single-node; multi-node source-dev testing is supported via env vars
(see [Two-Node Source-Dev Cluster Testing](#two-node-source-dev-cluster-testing)).

## Prerequisites

| Dependency | Version | Notes |
|------------|---------|-------|
| Elixir | ≥ 1.17 | Tested on 1.19.5 |
| Erlang/OTP | ≥ 27 | Tested on OTP 28 |
| PostgreSQL | ≥ 15 | Local instance |
| Python | ≥ 3.10 | Via `uv` for native packages |
| uv | latest | Python package manager |

## Quick Start

```bash
# 1. Clone and install dependencies
cd orchard
mix deps.get

# 2. Install native Python packages (dev mode)
cd native/orchard_tokenizer && uv sync && cd ../..
cd native/orchard_worker_mlx && uv sync && cd ../..

# 3. Start the dev server (creates DB, migrates, starts Phoenix + node-agent)
bin/dev

# 4. Import a model bundle (in the running IEx session)
OrchardCLI.main(["models", "import", "/path/to/model-bundle", "--activate"])
```

`bin/dev` is the single entrypoint for source development. It creates the dev
database if missing, runs migrations, and starts `iex -S mix phx.server` with
the dev gRPC port set to **50071** (avoiding conflict with the packaged BEAM
on 50061).

The controller listens on `http://localhost:4000` and the node-agent
gRPC server on `127.0.0.1:50071`.

## Transport Modes

Orchard has two transport profiles:

### Source dev (this page)

When running from a source checkout (`bin/dev` or `iex -S mix phx.server`):

- Controller listens on **HTTP** at `http://127.0.0.1:4000`
- Node-agent gRPC listens on `127.0.0.1:50071` (avoids packaged BEAM on 50061)
- CORS is disabled (empty allowlist in `config/dev.exs`)
- No TLS setup is required

All `curl` examples in this document use plain HTTP because they target the
source dev controller.

### Packaged install

When installed via the macOS PKG:

- Controller defaults to **HTTPS** on `0.0.0.0:8443` with managed TLS
  certificates
- Supports managed TLS, external certificate override, or emergency disabled
  (loopback HTTP) mode
- CORS is configurable via `ORCHARD_CORS_ORIGINS`

See [packaging/pkg/README.md](../packaging/pkg/README.md) for full operator
documentation on transport modes, TLS management, and CORS configuration.

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
| `PORT` | `4000` | HTTP listen port |

#### Node Agent Runtime

| Variable | Default | Description |
|----------|---------|-------------|
| `ORCHARD_NODE_AGENT_LISTEN_HOST` | `127.0.0.1` | gRPC listen address. Set to `0.0.0.0` on a remote node-agent for 2-node testing. |
| `ORCHARD_NODE_AGENT_LISTEN_PORT` | `50071` (source dev) / `50061` (packaged) | gRPC listen port |
| `ORCHARD_RUNTIME_CLIENT_PORT` | Same as listen port | Controller gRPC client port (must match listen port) |
| `ORCHARD_MODELS_ROOT` | `tmp/dev/models` | Model artifact storage |
| `ORCHARD_WORKER_SOCKET_DIR` | `tmp/dev/data/worker-sockets` | Worker UDS directory |
| `ORCHARD_WORKER_EXECUTABLE` | `native/orchard_worker_mlx/bin/orchard-worker-mlx` (repo-root) | Worker binary path. Override via env var; default resolves from repo root in source-dev mode. |
| `ORCHARD_WORKER_BACKEND` | `mlx` | Inference backend |
| `ORCHARD_FAKE_RUNTIME` | `false` | Use fake runtime (for testing without GPU) |
| `ORCHARD_NODE_DISPLAY_NAME` | hostname | Human-readable node name shown in console |

#### Controller Multi-Node (Source Dev)

| Variable | Default | Description |
|----------|---------|-------------|
| `ORCHARD_RUNTIME_CLIENT_HOST` | `127.0.0.1` | Controller’s local gRPC target host |
| `ORCHARD_RUNTIME_CLIENT_TARGETS` | _(empty)_ | Comma-separated `host:port` list for multi-node scheduling. When set with >1 target, the scheduler auto-selects `MultiNode`. |

#### Packaged Controller Transport (release only)

These variables apply to packaged/release controller installs, not source dev:

| Variable | Default | Description |
|----------|---------|-------------|
| `ORCHARD_API_HTTPS_PORT` | `8443` | HTTPS listen port |
| `ORCHARD_API_BIND_IP` | `0.0.0.0` | HTTPS bind IP address |
| `ORCHARD_PUBLIC_HOST` | `localhost` | Browser-visible hostname or IP. **Required for console access** when not using `localhost`. See [packaging README](../packaging/pkg/README.md#console-troubleshooting). |
| `ORCHARD_TLS_CERTFILE` | `config/tls/controller.crt` | Server certificate path |
| `ORCHARD_TLS_KEYFILE` | `config/tls/controller.key` | Server private key path |
| `ORCHARD_TLS_CACERTFILE` | `config/tls/ca.crt` | CA certificate path |
| `ORCHARD_TLS_DISABLED` | `false` | Emergency loopback HTTP mode |
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
| `config/m1_runtime_defaults.exs` | Shared defaults for M1 runtime settings |

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
| GET | `/health/ready` | Readiness probe (DB check) |
| GET | `/v1/models` | List active models |
| POST | `/v1/chat/completions` | Chat completion (stream + non-stream) |

### Example: Non-streaming

```bash
curl -X POST http://localhost:4000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "your-model@v1",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

### Example: Streaming

```bash
curl -N -X POST http://localhost:4000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "your-model@v1",
    "messages": [{"role": "user", "content": "Hello!"}],
    "stream": true
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

Packaged installs using managed TLS can bootstrap LAN client trust:

1. **Generate certificates** — the PKG installer runs `orchardctl tls init`
   automatically on fresh install
2. **Trust CA locally** (optional):
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

### Controller host (mawarduri)

```bash
ORCHARD_RUNTIME_CLIENT_TARGETS="127.0.0.1:50071,<remote-tailscale-ip>:50071" \
  ORCHARD_NODE_DISPLAY_NAME=mawarduri \
  bin/dev
```

The local node-agent still binds to `127.0.0.1:50071`. The controller targets
both local and remote nodes. The scheduler auto-selects `MultiNode` when it
sees >1 target. Use the Tailscale IPv4 address (`100.x.y.z`) — IPv6 addresses
are not supported in the target list.

### Remote node-agent host (Tamingsari)

```bash
cd apps/orchard_node_agent

MIX_ENV=dev \
  ORCHARD_NODE_AGENT_LISTEN_HOST=0.0.0.0 \
  ORCHARD_NODE_AGENT_LISTEN_PORT=50071 \
  ORCHARD_WORKER_BACKEND=stub \
  ORCHARD_NODE_DISPLAY_NAME=tamingsari \
  mix run --no-halt
```

The node-agent boots standalone from the sub-app directory — no Postgres,
controller, or asset watchers needed. Use `stub` backend for cluster mechanics
testing; switch to `mlx` when real inference is required.

### Verification

1. Both nodes should appear in `/console/nodes` with distinct display names
2. Cluster summary should show 2 configured targets
3. Playground inference should attribute requests to specific nodes
4. Killing the remote node-agent should transition its health to
   degraded/unreachable

### Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Controller shows 1 target | `ORCHARD_RUNTIME_CLIENT_TARGETS` unset or malformed | Check env var, use `host:port,host:port` format |
| Remote node-agent unreachable | Listen host still `127.0.0.1` | Set `ORCHARD_NODE_AGENT_LISTEN_HOST=0.0.0.0` |
| Remote node fails on MLX | Python <3.11 or no `uv sync` | Use `ORCHARD_WORKER_BACKEND=stub` or run `cd native/orchard_worker_mlx && uv sync --extra mlx` |
| Port conflict on remote | Another BEAM on same port | Change `ORCHARD_NODE_AGENT_LISTEN_PORT` |

> **Security note:** Binding to `0.0.0.0` exposes the gRPC server on all
> interfaces. Use only on trusted networks (Tailscale, private LAN). Source-dev
> gRPC has no TLS — Tailscale provides wire encryption.

## Testing

```bash
# Full test suite (uses fake runtime, no GPU needed)
mix test

# With coverage
mix test --cover

# Strict checks
mix credo --strict
mix dialyzer
```

## Apple Silicon MLX Smoke Tests

Opt-in smoke tests verify real MLX inference on Apple Silicon hardware. These are
separate from `mix test`, which uses the fake/stub runtime and requires no GPU.

### Prerequisites

- Apple Silicon Mac (M1/M2/M3/M4)
- A local Orchard model bundle directory (not downloaded by the script)
- `uv` installed
- `mix deps.get` already run in the repo

### Required Environment Variable

| Variable | Required | Description |
|----------|----------|-------------|
| `ORCHARD_MLX_SMOKE_MODEL_PATH` | Yes | Absolute path to an Orchard model bundle directory containing `manifest.json` |

Both Python and Elixir smoke tests gate on this variable. When unset, the smoke
tests are skipped (Python) or not compiled (Elixir).

### Running the Smoke Script

```bash
export ORCHARD_MLX_SMOKE_MODEL_PATH=/path/to/your/orchard-bundle
./scripts/smoke-mlx.sh
```

The script can be invoked from any directory — it resolves the repo root from
its own location.

### What the Script Does

1. **Validates** platform (macOS arm64), tooling (`uv`, `mix`), repo layout,
   and the bundle path (exists, is a directory, contains `manifest.json`)
2. **Python smoke** (step 1/2): installs MLX extras (`uv sync --extra mlx`)
   then runs `pytest tests/test_cli.py -k mlx_backend_real -v` in the worker
   package — exercises real model load/unload and streaming generation via gRPC
3. **Elixir smoke** (step 2/2): runs
   `mix test apps/orchard_node_agent/test/orchard_node_agent_test.exs --only mlx_smoke`
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
uv sync --extra mlx
uv run pytest tests/test_cli.py -k mlx_backend_real -v

# Elixir only
mix test apps/orchard_node_agent/test/orchard_node_agent_test.exs --only mlx_smoke
```

## Preparing a Smoke Test Bundle from HuggingFace

The smoke tests require an **Orchard bundle** — a directory containing a
`manifest.json` plus model files. HuggingFace MLX models don't include this
manifest, so you must create a wrapper bundle.

### Quick Setup

```bash
# 1. Download a small MLX model (if not already cached)
pip install huggingface-hub
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

## Rollback Procedure

Orchard supports a binary backend switch: `mlx` (real inference) or `stub`
(no-op responses). Rollback means switching the worker backend.

### Development (Source Checkout)

```bash
# Switch to stub backend
export ORCHARD_WORKER_BACKEND=stub

# Restart the app
iex -S mix phx.server
```

Verify: the node-agent log will show `worker starting backend=stub`.

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
3. Test inference: `curl http://localhost:4000/health/ready`
4. Run a chat completion — stub returns canned responses, mlx returns real inference

## Smoke Test Troubleshooting

| Failure | Likely Cause | Where to Look |
|---------|-------------|---------------|
| `Bundle is missing manifest.json` | Bundle not prepared correctly | Re-run bundle prep steps above |
| `bundle_path_escape` | Symlinks in bundle dir | Use `cp -L` instead of `ln -s` |
| `model_load_failed` | MLX/mlx-lm version mismatch | Check `uv sync --extra mlx` ran, inspect worker logs |
| `unsupported_runtime_adapter` | Wrong `adapter` in manifest | Must be `"mlx_lm"` |
| `tokenizer_missing` | Wrong `tokenizer.path` | Check `tokenizer.json` exists in bundle |
| Python smoke timeout | Model too large for hardware | Use smaller model (1B recommended) |
| Elixir smoke failure | Node-agent/worker lifecycle issue | Check worker stdout/stderr |
| `mlx_backend_unavailable` | MLX extras not installed | Run `uv sync --extra mlx` |

## Releases (Production)

Three release targets are defined:

| Release | Apps | Purpose |
|---------|------|---------|
| `orchard_controller` | shared + controller | HTTP API + dispatch |
| `orchard_node_agent` | shared + node-agent | gRPC runtime server |
| `orchard_cli` | shared + controller + cli | `orchardctl` CLI |

```bash
# Build a release
MIX_ENV=prod mix release orchard_controller

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
2. Run `bin/dev` — this handles DB bootstrap and server start:
   - Creates `orchard_dev` database if missing
   - Runs pending migrations
   - Exports dev gRPC port (50071)
   - Starts `iex -S mix phx.server`
   - Controller boots: Endpoint, Repo, Inference supervisor, gRPC client
   - Node-agent boots: ModelManager, WorkerSupervisor, gRPC server
3. Import at least one model bundle (`orchardctl models import <path> --activate`)
4. API is ready for requests

Alternatively, for advanced debugging or when you need a BEAM without the
HTTP server, you can run the steps manually:

```bash
export MIX_ENV=dev
export ORCHARD_NODE_AGENT_LISTEN_PORT=50071
export ORCHARD_RUNTIME_CLIENT_PORT=50071
mix ecto.create && mix ecto.migrate
iex -S mix phx.server
```

## M1 Limitations

- Source dev controller uses loopback HTTP (`127.0.0.1:4000`); packaged
  installs default to HTTPS (see [Transport Modes](#transport-modes))
- Source dev gRPC on port 50071; packaged installs on 50061
- Node-agent gRPC remains loopback and non-TLS in M1
- Single implicit tenant (no auth/RBAC — deferred to M2)
- Multi-node is supported for source-dev testing only (production/packaged multi-node — M4)
- No distributed Erlang across machines
- Model import from local filesystem only (no remote download)
