#!/usr/bin/env bash
# scripts/benchmark-cold-start-mlx.sh — Benchmark cold-start latency for MLX worker
#
# Measures first-request latency with real controller→node-agent dispatch.
# Requires ORCHARD_MLX_BENCH_MODEL_PATH pointing to a local Orchard model bundle.
#
# Exit 0 on success, non-zero on operational failure.

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve repo root from script location
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Status tracking
# ---------------------------------------------------------------------------
BENCH_STATUS="NOT RUN"
BENCH_EXIT=0
BUNDLE_DISPLAY="<unset>"
FAIL_REASON=""

print_summary() {
  echo ""
  echo "=== Cold-start benchmark summary ==="
  echo "Bundle:        $BUNDLE_DISPLAY"
  echo "Status:        $BENCH_STATUS"
  if [ -n "$FAIL_REASON" ]; then
    echo "Reason:        $FAIL_REASON"
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
  die "This benchmark requires macOS (detected: $(uname -s))"
fi

if [ "$(uname -m)" != "arm64" ]; then
  die "This benchmark requires Apple Silicon (detected: $(uname -m))"
fi

# ---------------------------------------------------------------------------
# Preflight: tooling
# ---------------------------------------------------------------------------
if ! command -v mix >/dev/null 2>&1; then
  die "'mix' is not installed or not on PATH"
fi

# ---------------------------------------------------------------------------
# Preflight: repo layout
# ---------------------------------------------------------------------------
if [ ! -f "$REPO_ROOT/mix.exs" ]; then
  die "Cannot find mix.exs at repo root ($REPO_ROOT)"
fi

if [ ! -f "$REPO_ROOT/apps/orchard_controller/test/orchard/dispatch/cold_start_benchmark_test.exs" ]; then
  die "Cannot find benchmark test file"
fi

# ---------------------------------------------------------------------------
# Preflight: model bundle
# ---------------------------------------------------------------------------
if [ -z "${ORCHARD_MLX_BENCH_MODEL_PATH:-}" ]; then
  die "ORCHARD_MLX_BENCH_MODEL_PATH is not set"
fi

BUNDLE_DISPLAY="$ORCHARD_MLX_BENCH_MODEL_PATH"

if [ ! -e "$ORCHARD_MLX_BENCH_MODEL_PATH" ]; then
  die "Bundle path does not exist: $ORCHARD_MLX_BENCH_MODEL_PATH"
fi

if [ ! -d "$ORCHARD_MLX_BENCH_MODEL_PATH" ]; then
  die "Bundle path is not a directory: $ORCHARD_MLX_BENCH_MODEL_PATH"
fi

if [ ! -f "$ORCHARD_MLX_BENCH_MODEL_PATH/manifest.json" ]; then
  die "Bundle is missing manifest.json: $ORCHARD_MLX_BENCH_MODEL_PATH"
fi

# ---------------------------------------------------------------------------
# Preflight: benchmark config
# ---------------------------------------------------------------------------
if [ ! -f "$REPO_ROOT/config/benchmark.exs" ]; then
  die "Missing benchmark config: $REPO_ROOT/config/benchmark.exs"
fi

# Canonicalize to absolute path
ORCHARD_MLX_BENCH_MODEL_PATH="$(cd "$ORCHARD_MLX_BENCH_MODEL_PATH" && pwd)"
export ORCHARD_MLX_BENCH_MODEL_PATH
BUNDLE_DISPLAY="$ORCHARD_MLX_BENCH_MODEL_PATH"

echo "==> Cold-start benchmark (REAL MLX worker)"
echo "    Bundle: $ORCHARD_MLX_BENCH_MODEL_PATH"
echo "    Backend: mlx (NOT fake/stub - using MIX_ENV=benchmark)"
echo ""

# ---------------------------------------------------------------------------
# Run benchmark
# ---------------------------------------------------------------------------
echo "==> Running mix test with MIX_ENV=benchmark --only mlx_benchmark"
echo ""

set +e
(
  cd "$REPO_ROOT" && \
  MIX_ENV=benchmark mix test apps/orchard_controller/test/orchard/dispatch/cold_start_benchmark_test.exs --only mlx_benchmark
)
BENCH_EXIT=$?
set -e

if [ $BENCH_EXIT -ne 0 ]; then
  BENCH_STATUS="FAIL (exit $BENCH_EXIT)"
  FAIL_REASON="Benchmark tests failed"
  print_summary
  exit 1
fi

BENCH_STATUS="PASS"

# ---------------------------------------------------------------------------
# All passed
# ---------------------------------------------------------------------------
print_summary
exit 0
