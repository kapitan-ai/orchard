#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PREPARE="$SCRIPT_DIR/prepare-mlx-smoke-bundle.sh"

fail() {
  printf 'test-prepare-mlx-smoke-bundle: %s\n' "$1" >&2
  exit 1
}

want_export() {
  printf 'export ORCHARD_MLX_SMOKE_MODEL_PATH=%q' "$1"
}

assert_export() {
  local got="$1"
  local dest="$2"
  local want
  want="$(want_export "$dest")"
  [ "$got" = "$want" ] || fail "expected $want (got: $got)"
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
assert_export "$out" "$ABS_DEST"
[ -f "$DEST/manifest.json" ] || fail "manifest.json was not written"
[ -f "$DEST/config.json" ] || fail "config.json was not copied"
[ ! -f "$DEST/README.md" ] || fail "README.md should not be copied into the bundle"

(cd "$REPO_ROOT" && mise exec -- python - "$DEST/manifest.json") <<'PY' || fail "manifest pin mismatch"
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
assert_export "$again" "$ABS_DEST"

printed="$("$PREPARE" --bundle-dir "$DEST" --print-path)"
assert_export "$printed" "$ABS_DEST"

rm -f "$DEST/model.safetensors"
if "$PREPARE" --bundle-dir "$DEST" --print-path >/dev/null 2>&1; then
  fail "--print-path should fail when weights are missing"
fi
rebuilt="$("$PREPARE" --from-snapshot "$SNAPSHOT" --bundle-dir "$DEST")"
[ -f "$DEST/model.safetensors" ] || fail "incomplete dest was not rebuilt"
assert_export "$rebuilt" "$ABS_DEST"

SPACE_DEST="$TMP/bundle dir"
space_out="$("$PREPARE" --from-snapshot "$SNAPSHOT" --bundle-dir "$SPACE_DEST")"
SPACE_ABS="$(cd "$SPACE_DEST" && pwd)"
assert_export "$space_out" "$SPACE_ABS"
eval "$space_out"
[ "$ORCHARD_MLX_SMOKE_MODEL_PATH" = "$SPACE_ABS" ] || fail "eval of %q export did not set the spaced dest"

printf 'test-prepare-mlx-smoke-bundle: PASS\n'
