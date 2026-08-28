#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTROL="$REPO_ROOT/.cursor/skills/verify-orchard/scripts/control-orchard.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-verify-control-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'test-verify-orchard-control: %s\n' "$1" >&2
  exit 1
}

export ORCHARD_VERIFY_RUN_ID=test
export ORCHARD_VERIFY_STATE_DIR="$TMP_ROOT/state"
export ORCHARD_MLX_SMOKE_MODEL_PATH="$TMP_ROOT/operator-bundle"

# shellcheck source=../.cursor/skills/verify-orchard/scripts/control-orchard.sh
source "$CONTROL"

printf '%s\n' 99999999 >"$PID_FILE"
ensure_launch_pid_slot
[[ ! -e "$PID_FILE" ]] || fail "stale pid file was not removed"

printf '%s\n' "$$" >"$PID_FILE"
if ensure_launch_pid_slot >/dev/null 2>&1; then
  fail "live pid should prevent launch"
fi
[[ -f "$PID_FILE" ]] || fail "live pid file should be retained"
rm -f "$PID_FILE"

write_meta
unset ORCHARD_MLX_SMOKE_MODEL_PATH
load_meta_preserving_bundle_path
[[ "$ORCHARD_MLX_SMOKE_MODEL_PATH" == "$TMP_ROOT/operator-bundle" ]] ||
  fail "stored bundle path was not loaded"

printf '%s\n' 'ORCHARD_MLX_SMOKE_MODEL_PATH=' >"$META_FILE"
ORCHARD_MLX_SMOKE_MODEL_PATH="$TMP_ROOT/operator-override"
load_meta_preserving_bundle_path
[[ "$ORCHARD_MLX_SMOKE_MODEL_PATH" == "$TMP_ROOT/operator-override" ]] ||
  fail "operator bundle path was overwritten by empty meta"

python_version="$(pinned_python -c 'import sys; print(sys.version_info[:2])')"
[[ "$python_version" == "(3, 11)" ]] || fail "pinned Python 3.11 was not used"

if grep -q 'python3' "$CONTROL"; then
  fail "control helper still bypasses the pinned Python interpreter"
fi

printf 'test-verify-orchard-control: PASS\n'
