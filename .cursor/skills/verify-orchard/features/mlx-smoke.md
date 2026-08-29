# MLX smoke

The pinned Qwen3 MLX snapshot can be wrapped as an Orchard bundle and exercised with the opt-in Apple Silicon smoke tests. This is not a CI gate.

## Sub-features

- `prepare-bundle` — pinned Qwen3 bundle exists with `manifest.json` and `ORCHARD_MLX_SMOKE_MODEL_PATH` is exported.
- `python-smoke` — worker pytest `mlx_backend_real` passes against that bundle.
- `elixir-smoke` — node-agent `mix test --only mlx_smoke` passes against that bundle.

## How to get to it (user POV)

- Prepare the bundle: `mise exec -- ./scripts/prepare-mlx-smoke-bundle.sh` then `eval "$(mise exec -- ./scripts/prepare-mlx-smoke-bundle.sh --print-path)"`.
- Run smoke: `mise exec -- ./scripts/smoke-mlx.sh`.
- Verification wrappers: `control-orchard prepare-bundle` then `control-orchard smoke-mlx`.

## Driving it with control-orchard

Preconditions:

- Apple Silicon macOS (`Darwin` `arm64`).
- `make setup` (or equivalent) already run.
- Do not treat a missing Hugging Face download as a product failure — report `verified-unreachable` with the attempted command.

- **Prepare bundle.** Run `control-orchard prepare-bundle`. Exit 0. stdout includes `export ORCHARD_MLX_SMOKE_MODEL_PATH=...` and `control-orchard meta` shows the same path. The directory contains `manifest.json`. A cache hit (already prepared) is valid proof.
- **Run smoke.** Run `control-orchard smoke-mlx`. Exit 0. Log ends with `Python smoke: PASS`, `Elixir smoke: PASS`, and `Overall: PASS`.
- **Proof.** Save `${ARTIFACTS}/mlx-smoke/smoke.log` (created by the helper) and `proof.txt` with feature id `mlx-smoke`, the bundle path, and the summary lines. Do not commit the bundle or the log.

## Gotchas

- Not a CI, `make test`, or product validation gate. Skip on non-arm64 hosts.
- The helper refuses destinations inside the git checkout. Default cache is `~/.cache/orchard/mlx-smoke-bundles/qwen3-0.6b-4bit` (~335 MB).
- First prepare may download from Hugging Face; `--print-path` fails until a successful prepare. Use `--from-snapshot DIR` when air-gapped.
- `smoke-mlx` is an isolated CLI session. It does not need `control-orchard launch`. If a verification source-dev instance is already up, the helper binds Elixir smoke to a free `ORCHARD_TEST_NODE_AGENT_PORT` so it does not steal `:50071`.
- Qwen3 thinking mode can consume a short generation budget. The Elixir smoke uses a tiny `max_output_tokens`; Chat Completions checks should use non-thinking if added later.
- Playground and `/v1/chat/completions` still need `orchardctl models import`, tenant grants, and an API token. This feature only proves the worker/node-agent smoke path.
