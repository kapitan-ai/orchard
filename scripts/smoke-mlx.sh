#!/usr/bin/env bash
# scripts/smoke-mlx.sh — Run Apple Silicon MLX smoke tests (Python + Elixir)
#
# Requires ORCHARD_MLX_SMOKE_MODEL_PATH pointing to a local Orchard model bundle.
# Exit 0 on all-pass, non-zero on any failure.

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve repo root from script location (macOS-safe, no GNU readlink)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=support/mlx-smoke-budget.sh
source "$SCRIPT_DIR/support/mlx-smoke-budget.sh"
mlx_smoke_configure_budgets

# ---------------------------------------------------------------------------
# Status tracking
# ---------------------------------------------------------------------------
PYTHON_STATUS="NOT RUN"
ELIXIR_STATUS="NOT RUN"
PYTHON_EXIT=0
ELIXIR_EXIT=0
BUNDLE_DISPLAY="<unset>"
FAIL_REASON=""

print_summary() {
  echo ""
  echo "=== Orchard MLX smoke summary ==="
  echo "Bundle:        $BUNDLE_DISPLAY"
  echo "Python smoke:  $PYTHON_STATUS"
  echo "Elixir smoke:  $ELIXIR_STATUS"
  if [ -n "$FAIL_REASON" ]; then
    echo "Overall:       FAIL"
    echo "Reason:        $FAIL_REASON"
  elif [ "$PYTHON_STATUS" = "PASS" ] && [ "$ELIXIR_STATUS" = "PASS" ]; then
    echo "Overall:       PASS"
  else
    echo "Overall:       FAIL"
  fi
}

die() {
  FAIL_REASON="$1"
  echo "ERROR: $1" >&2
  print_summary
  exit 1
}

# ---------------------------------------------------------------------------
# Preflight: platform
# ---------------------------------------------------------------------------
if [ "$(uname -s)" != "Darwin" ]; then
  die "This script requires macOS (detected: $(uname -s))"
fi

if [ "$(uname -m)" != "arm64" ]; then
  die "This script requires Apple Silicon (detected: $(uname -m))"
fi

# ---------------------------------------------------------------------------
# Preflight: tooling
# ---------------------------------------------------------------------------
if ! command -v mise >/dev/null 2>&1; then
  die "'mise' is not installed or not on PATH"
fi

if ! (cd "$REPO_ROOT" && mise exec -- uv --version >/dev/null 2>&1); then
  die "'uv' is not available through mise; run 'mise install' from the repo root"
fi

if ! (cd "$REPO_ROOT" && mise exec -- mix --version >/dev/null 2>&1); then
  die "'mix' is not available through mise; run 'mise install' from the repo root"
fi

# ---------------------------------------------------------------------------
# Preflight: repo layout
# ---------------------------------------------------------------------------
if [ ! -f "$REPO_ROOT/mix.exs" ]; then
  die "Cannot find mix.exs at repo root ($REPO_ROOT)"
fi

if [ ! -f "$REPO_ROOT/native/orchard_worker_mlx/pyproject.toml" ]; then
  die "Cannot find native/orchard_worker_mlx/pyproject.toml"
fi

if [ ! -f "$REPO_ROOT/apps/orchard_node_agent/test/orchard_node_agent_test.exs" ]; then
  die "Cannot find Elixir node-agent test file"
fi

# ---------------------------------------------------------------------------
# Preflight: model bundle
# ---------------------------------------------------------------------------
if [ -z "${ORCHARD_MLX_SMOKE_MODEL_PATH:-}" ]; then
  die "ORCHARD_MLX_SMOKE_MODEL_PATH is not set"
fi

BUNDLE_DISPLAY="$ORCHARD_MLX_SMOKE_MODEL_PATH"

if [ ! -e "$ORCHARD_MLX_SMOKE_MODEL_PATH" ]; then
  die "Bundle path does not exist: $ORCHARD_MLX_SMOKE_MODEL_PATH"
fi

if [ ! -d "$ORCHARD_MLX_SMOKE_MODEL_PATH" ]; then
  die "Bundle path is not a directory: $ORCHARD_MLX_SMOKE_MODEL_PATH"
fi

if [ ! -f "$ORCHARD_MLX_SMOKE_MODEL_PATH/manifest.json" ]; then
  die "Bundle is missing manifest.json: $ORCHARD_MLX_SMOKE_MODEL_PATH"
fi

# Canonicalize to absolute path (Bash 3.2 safe — no GNU readlink -f).
# Prevents breakage when the script cd's into different directories.
ORCHARD_MLX_SMOKE_MODEL_PATH="$(cd "$ORCHARD_MLX_SMOKE_MODEL_PATH" && pwd)"
export ORCHARD_MLX_SMOKE_MODEL_PATH
BUNDLE_DISPLAY="$ORCHARD_MLX_SMOKE_MODEL_PATH"

echo "==> Orchard MLX smoke tests"
echo "    Bundle: $ORCHARD_MLX_SMOKE_MODEL_PATH"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Python worker smoke tests
# ---------------------------------------------------------------------------
echo "==> [1/2] Python worker MLX smoke tests"
echo "    mise exec -- uv run ... in native/orchard_worker_mlx"
echo ""

set +e
(
  cd "$REPO_ROOT/native/orchard_worker_mlx" && \
  mise exec -- uv sync --extra mlx && \
  mise exec -- uv run pytest tests/test_cli.py -k mlx_backend_real -v
)
PYTHON_EXIT=$?
set -e

if [ $PYTHON_EXIT -ne 0 ]; then
  PYTHON_STATUS="FAIL (exit $PYTHON_EXIT)"
  FAIL_REASON="Python smoke tests failed"
  print_summary
  exit 1
fi

PYTHON_STATUS="PASS"
echo ""

# ---------------------------------------------------------------------------
# Step 2: Elixir node-agent smoke tests
# ---------------------------------------------------------------------------
echo "==> [2/2] Elixir node-agent MLX smoke tests"
echo "    mise exec -- mix test --only mlx_smoke --timeout $MLX_SMOKE_EXUNIT_TIMEOUT_MS"
echo ""

set +e
(
  cd "$REPO_ROOT" && \
  mise exec -- mix test apps/orchard_node_agent/test/orchard_node_agent_test.exs \
    --only mlx_smoke \
    --timeout "$MLX_SMOKE_EXUNIT_TIMEOUT_MS"
)
ELIXIR_EXIT=$?
set -e

if [ $ELIXIR_EXIT -ne 0 ]; then
  ELIXIR_STATUS="FAIL (exit $ELIXIR_EXIT)"
  FAIL_REASON="Elixir smoke tests failed"
  print_summary
  exit 1
fi

ELIXIR_STATUS="PASS"

# ---------------------------------------------------------------------------
# All passed
# ---------------------------------------------------------------------------
print_summary
exit 0
