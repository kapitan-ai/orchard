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

[[ "$META_FILE" == "$ORCHARD_VERIFY_STATE_DIR/meta.json" ]] ||
  fail "metadata file is not data-only JSON"

ORCHARD_MLX_SMOKE_MODEL_PATH=""
write_meta
ORCHARD_MLX_SMOKE_MODEL_PATH="$TMP_ROOT/operator-override"
load_meta_preserving_bundle_path
[[ "$ORCHARD_MLX_SMOKE_MODEL_PATH" == "$TMP_ROOT/operator-override" ]] ||
  fail "operator bundle path was overwritten by empty meta"

sentinel="$TMP_ROOT/meta-executed"
hostile_bundle="$TMP_ROOT/bundle with spaces;\$(touch $sentinel)"
ORCHARD_MLX_SMOKE_MODEL_PATH="$hostile_bundle"
write_meta
unset ORCHARD_MLX_SMOKE_MODEL_PATH
load_meta_preserving_bundle_path
[[ "$ORCHARD_MLX_SMOKE_MODEL_PATH" == "$hostile_bundle" ]] ||
  fail "shell-sensitive bundle path did not round trip through meta"
[[ ! -e "$sentinel" ]] || fail "bundle path executed as shell code"

rm -f "$META_FILE"
legacy_sentinel="$TMP_ROOT/legacy-meta-executed"
printf '%s\n' "ORCHARD_MLX_SMOKE_MODEL_PATH=\$(touch '$legacy_sentinel')" >"$LEGACY_META_FILE"

for command in doctor stop meta "curl /health/live"; do
  if "$CONTROL" $command >"$TMP_ROOT/legacy.stdout" 2>"$TMP_ROOT/legacy.stderr"; then
    fail "$command accepted legacy executable metadata"
  fi
  grep -q 'legacy metadata.*rejected' "$TMP_ROOT/legacy.stderr" ||
    fail "$command did not explain legacy metadata rejection"
done

if load_meta_preserving_bundle_path >/dev/null 2>"$TMP_ROOT/legacy.stderr"; then
  fail "smoke metadata loader accepted legacy executable metadata"
fi
[[ ! -e "$legacy_sentinel" ]] || fail "legacy metadata executed as shell code"
rm -f "$LEGACY_META_FILE"

python_version="$(pinned_python -c 'import sys; print(sys.version_info[:2])')"
[[ "$python_version" == "(3, 11)" ]] || fail "pinned Python 3.11 was not used"

if grep -q 'python3' "$CONTROL"; then
  fail "control helper still bypasses the pinned Python interpreter"
fi

printf 'test-verify-orchard-control: PASS\n'
