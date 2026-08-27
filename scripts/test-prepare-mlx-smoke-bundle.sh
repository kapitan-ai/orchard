#!/usr/bin/env bash
# Prove scripts/prepare-mlx-smoke-bundle.sh without a HuggingFace download.
# Convenience only. Not a CI, make test, or product validation gate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PREPARE="$SCRIPT_DIR/prepare-mlx-smoke-bundle.sh"

fail() {
  printf 'test-prepare-mlx-smoke-bundle: %s\n' "$1" >&2
  exit 1
}

[ -x "$PREPARE" ] || chmod +x "$PREPARE"

help_out="$("$PREPARE" --help)"
printf '%s\n' "$help_out" | grep -q 'Qwen3' || fail "help does not name Qwen3"
printf '%s\n' "$help_out" | grep -q 'does not run in CI' || fail "help does not say this is not a CI gate"

forbidden="$REPO_ROOT/tmp/mlx-smoke-forbidden"
if "$PREPARE" --bundle-dir "$forbidden" >/dev/null 2>&1; then
  fail "should refuse a destination inside the repository"
fi
[ ! -e "$forbidden" ] || fail "refused destination should not be created"

if "$PREPARE" --from-snapshot /no/such/snapshot --bundle-dir "${TMPDIR:-/tmp}/orchard-mlx-smoke-missing" >/dev/null 2>&1; then
  fail "should fail when --from-snapshot does not exist"
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/orchard-mlx-smoke-test.XXXXXX")"
cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

SNAPSHOT="$TMP/snapshot"
DEST="$TMP/bundle"
mkdir -p "$SNAPSHOT"
printf '%s\n' '{"max_position_embeddings": 4096}' > "$SNAPSHOT/config.json"
printf '%s\n' '{"version": "1.0"}' > "$SNAPSHOT/tokenizer.json"
printf '%s\n' '{"chat_template": "{{ bos_token }}{% for m in messages %}{{ m.content }}{% endfor %}"}' \
  > "$SNAPSHOT/tokenizer_config.json"
printf 'fake-weights\n' > "$SNAPSHOT/model.safetensors"
printf 'ignore me\n' > "$SNAPSHOT/README.md"

out="$("$PREPARE" --from-snapshot "$SNAPSHOT" --bundle-dir "$DEST")"
[ -d "$DEST" ] || fail "destination directory was not created"
ABS_DEST="$(cd "$DEST" && pwd)"
printf '%s\n' "$out" | grep -qx "export ORCHARD_MLX_SMOKE_MODEL_PATH=$ABS_DEST" \
  || fail "first run did not print the destination path (got: $out)"
[ -f "$DEST/manifest.json" ] || fail "manifest.json was not written"
[ -f "$DEST/config.json" ] || fail "config.json was not copied"
[ ! -f "$DEST/README.md" ] || fail "README.md should not be copied into the bundle"

python3 - "$DEST/manifest.json" <<'PY' || fail "manifest pin mismatch"
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)
assert manifest["model_id"] == "mlx-community/Qwen3-0.6B-4bit"
assert manifest["version"] == "73e3e38d981303bc594367cd910ea6eb48349da8"
assert manifest["format"] == "mlx"
assert "chat_template" in manifest
PY

again="$("$PREPARE" --from-snapshot "$SNAPSHOT" --bundle-dir "$DEST")"
printf '%s\n' "$again" | grep -qx "export ORCHARD_MLX_SMOKE_MODEL_PATH=$ABS_DEST" \
  || fail "idempotent run did not print the destination path (got: $again)"

printed="$("$PREPARE" --bundle-dir "$DEST" --print-path)"
printf '%s\n' "$printed" | grep -qx "export ORCHARD_MLX_SMOKE_MODEL_PATH=$ABS_DEST" \
  || fail "--print-path did not print the prepared destination (got: $printed)"

printf 'test-prepare-mlx-smoke-bundle: PASS\n'
