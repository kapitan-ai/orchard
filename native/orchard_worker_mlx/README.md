# orchard_worker_mlx

S6 bootstrap scaffold for Orchard's MLX worker runtime package.

## Entrypoints

- project script (run from `native/orchard_worker_mlx/`): `uv run orchard-worker-mlx`
- dev-only repo wrapper from the repo root: `native/orchard_worker_mlx/bin/orchard-worker-mlx`

## Current behavior

The CLI currently emits a structured JSON placeholder so the package, tests, and
entrypoint wiring exist before the real gRPC worker implementation lands in R5.
