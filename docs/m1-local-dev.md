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
