# M1 Local Development

All-in-one local boot for the M1 single-node inference MVP.

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

# 2. Create and migrate the database
mix ecto.create
mix ecto.migrate

# 3. Install native Python packages (dev mode)
cd native/orchard_tokenizer && uv sync && cd ../..
cd native/orchard_worker_mlx && uv sync && cd ../..

# 4. Import a model bundle
mix run -e 'OrchardCLI.main(["models", "import", "/path/to/model-bundle", "--activate"])'

# 5. Start the controller (includes node-agent in dev)
iex -S mix phx.server
```

The controller listens on `http://localhost:4000` and the node-agent
gRPC server on `127.0.0.1:50061`.

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
| `ORCHARD_NODE_AGENT_LISTEN_HOST` | `127.0.0.1` | gRPC listen address |
| `ORCHARD_NODE_AGENT_LISTEN_PORT` | `50061` | gRPC listen port |
| `ORCHARD_MODELS_ROOT` | `tmp/dev/models` | Model artifact storage |
| `ORCHARD_WORKER_SOCKET_DIR` | `tmp/dev/data/worker-sockets` | Worker UDS directory |
| `ORCHARD_WORKER_EXECUTABLE` | `orchard-worker-mlx` | Worker binary |
| `ORCHARD_WORKER_BACKEND` | `mlx` | Inference backend |
| `ORCHARD_FAKE_RUNTIME` | `false` | Use fake runtime (for testing without GPU) |

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

```bash
# 1. Create/edit the node-agent env file
sudo mkdir -p "/Library/Application Support/Orchard/config"
echo 'ORCHARD_WORKER_BACKEND=stub' | sudo tee \
  "/Library/Application Support/Orchard/config/node-agent.env"

# 2. Restart the node-agent service
sudo launchctl kickstart -k system/com.orchard.node-agent
```

To restore MLX:

```bash
# Remove the override (or set back to mlx)
sudo rm "/Library/Application Support/Orchard/config/node-agent.env"
sudo launchctl kickstart -k system/com.orchard.node-agent
```

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
2. Database created and migrated (`mix ecto.create && mix ecto.migrate`)
3. Start the application (`iex -S mix phx.server`)
   - Controller boots: Endpoint, Repo, Inference supervisor, gRPC client
   - Node-agent boots: ModelManager, WorkerSupervisor, gRPC server
4. Import at least one model bundle (`orchardctl models import <path> --activate`)
5. API is ready for requests

## M1 Limitations

- Single implicit tenant (no auth/RBAC — deferred to M2)
- Single local node (no multi-node scheduling — deferred to M4)
- No distributed Erlang across machines
- No TLS on HTTP or gRPC (loopback only)
- Model import from local filesystem only (no remote download)
