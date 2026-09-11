#!/usr/bin/env bash

set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  printf 'test-linux-portable-core: Linux host required\n' >&2
  exit 69
fi

EXCLUDES=(
  --exclude integration
  --exclude macos
  --exclude mlx_smoke
  --exclude mlx_benchmark
)

mise exec -- mix test "${EXCLUDES[@]}"
mise exec -- mix test --cover "${EXCLUDES[@]}"

mise exec -- uv run --locked --directory native/orchard_tokenizer ruff format --check
mise exec -- uv run --locked --directory native/orchard_tokenizer ruff check
mise exec -- uv run --locked --directory native/orchard_tokenizer pytest
mise exec -- uv run --locked --directory native/orchard_tokenizer pytest --cov

mise exec -- uv run --locked --directory native/orchard_worker_mlx ruff format --check
mise exec -- uv run --locked --directory native/orchard_worker_mlx ruff check
mise exec -- uv run --locked --directory native/orchard_worker_mlx \
  pytest tests/test_backends.py tests/test_service.py tests/test_reasoning.py
mise exec -- uv run --locked --directory native/orchard_worker_mlx \
  pytest --cov=orchard_worker_mlx \
  tests/test_backends.py tests/test_service.py tests/test_reasoning.py
