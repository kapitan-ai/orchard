#!/usr/bin/env bash
# scripts/smoke-safe-tokenization.sh — Run Safe Tokenization deterministic
# ExUnit smoke cells. No external resources required (no MLX bundle, no GPU,
# no env vars). Exit 0 on all-pass, non-zero on any failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ELIXIR_STATUS="NOT RUN"
ELIXIR_EXIT=0
FAIL_REASON=""

print_summary() {
  echo ""
  echo "=== Orchard Safe Tokenization smoke summary ==="
  echo "ExUnit smoke: $ELIXIR_STATUS"
  if [ -n "$FAIL_REASON" ]; then
    echo "Overall:      FAIL"
    echo "Reason:       $FAIL_REASON"
  elif [ "$ELIXIR_STATUS" = "PASS" ]; then
    echo "Overall:      PASS"
  else
    echo "Overall:      FAIL"
  fi
}

die() {
  FAIL_REASON="$1"
  echo "ERROR: $1" >&2
  print_summary
  exit 1
}

command -v mix >/dev/null 2>&1 || die "mix is not on PATH"
test -f "$REPO_ROOT/mix.exs" || die "could not find Orchard umbrella mix.exs at $REPO_ROOT"
test -f "$REPO_ROOT/apps/orchard_controller/test/orchard/dispatch/safe_tokenization_smoke_test.exs" || \
  die "safe tokenization smoke test file is missing"
test -f "$REPO_ROOT/apps/orchard_controller/test/orchard/api/safe_tokenization_lifecycle_test.exs" || \
  die "safe tokenization lifecycle smoke test file is missing"

# Document packaged/prod and source-dev parity. Both runtime.exs and dev.exs
# parse ORCHARD_TOKENIZER_SAFE_MODE_PREFER_CAPABLE; the deterministic ExUnit
# cells still set app env directly via Application.put_env/3 because they run
# under :test (where neither config layer is re-evaluated), so the export
# below is intentionally redundant for the cells but useful for any future
# smoke that boots the controller via mix run / bin/dev / a release.
export ORCHARD_TOKENIZER_SAFE_MODE="${ORCHARD_TOKENIZER_SAFE_MODE:-on}"
export ORCHARD_TOKENIZER_SAFE_MODE_PREFER_CAPABLE="${ORCHARD_TOKENIZER_SAFE_MODE_PREFER_CAPABLE:-true}"

echo "==> Orchard Safe Tokenization smoke (ExUnit, deterministic)"
echo "    cwd:                       $REPO_ROOT"
echo "    safe mode (env):           $ORCHARD_TOKENIZER_SAFE_MODE"
echo "    prefer-capable (env):      $ORCHARD_TOKENIZER_SAFE_MODE_PREFER_CAPABLE"
echo ""

set +e
(
  cd "$REPO_ROOT" && \
    mix test \
      apps/orchard_controller/test/orchard/dispatch/safe_tokenization_smoke_test.exs \
      apps/orchard_controller/test/orchard/api/safe_tokenization_lifecycle_test.exs \
      --only safe_tokenization_smoke
)
ELIXIR_EXIT=$?
set -e

if [ $ELIXIR_EXIT -ne 0 ]; then
  ELIXIR_STATUS="FAIL (exit $ELIXIR_EXIT)"
  FAIL_REASON="ExUnit smoke cells failed"
  print_summary
  exit 1
fi

ELIXIR_STATUS="PASS"
print_summary
