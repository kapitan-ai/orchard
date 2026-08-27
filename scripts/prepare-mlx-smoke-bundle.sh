#!/usr/bin/env bash
set -euo pipefail

REPO_ID="mlx-community/Qwen3-0.6B-4bit"
REVISION="73e3e38d981303bc594367cd910ea6eb48349da8"
SKIP_NAMES='README.md
README.txt
LICENSE
LICENSE.txt
.gitattributes
.git'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKER_DIR="$REPO_ROOT/native/orchard_worker_mlx"
MANIFEST_SCRIPT="$SCRIPT_DIR/support/write_mlx_smoke_manifest.exs"

FORCE=0
PRINT_PATH=0
FROM_SNAPSHOT=""
BUNDLE_DIR="${ORCHARD_MLX_SMOKE_BUNDLE_DIR:-$HOME/.cache/orchard/mlx-smoke-bundles/qwen3-0.6b-4bit}"

usage() {
  cat <<EOF
Usage: scripts/prepare-mlx-smoke-bundle.sh [options]

Download and wrap the pinned Qwen3 MLX 4-bit snapshot as an Orchard bundle.

Options:
  --bundle-dir DIR       Destination directory (default: ~/.cache/orchard/mlx-smoke-bundles/qwen3-0.6b-4bit)
  --from-snapshot DIR    Copy from an existing snapshot instead of downloading
  --force                Rebuild even when the pinned manifest already exists
  --print-path           Print export ORCHARD_MLX_SMOKE_MODEL_PATH=... and exit if the bundle is already prepared
  -h, --help             Show this help

Pinned model: $REPO_ID @$REVISION

This script is opt-in local convenience. It does not run in CI.
EOF
}

fail() {
  printf 'prepare-mlx-smoke-bundle: %s\n' "$1" >&2
  exit 1
}

abs_path() {
  local target="$1"
  local parent
  parent="$(cd "$(dirname "$target")" && pwd)"
  printf '%s/%s\n' "$parent" "$(basename "$target")"
}

skip_name() {
  local name="$1"
  printf '%s\n' "$SKIP_NAMES" | grep -Fxq "$name"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --bundle-dir)
      [ "$#" -ge 2 ] || fail "--bundle-dir requires a directory"
      BUNDLE_DIR="$2"
      shift 2
      ;;
    --from-snapshot)
      [ "$#" -ge 2 ] || fail "--from-snapshot requires a directory"
      FROM_SNAPSHOT="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --print-path)
      PRINT_PATH=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

inside_repo() {
  python3 - "$REPO_ROOT" "$1" <<'PY'
import os
import sys

repo = os.path.realpath(sys.argv[1])
dest = os.path.abspath(sys.argv[2])
try:
    common = os.path.commonpath([repo, dest])
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if common == repo else 1)
PY
}

refuse_repo_dest() {
  if inside_repo "$1"; then
    fail "refusing to write model weights inside the repository ($1)"
  fi
}

command -v mise >/dev/null 2>&1 || fail "'mise' is not installed or not on PATH"
[ -f "$REPO_ROOT/mix.exs" ] || fail "cannot find mix.exs at $REPO_ROOT"
[ -f "$MANIFEST_SCRIPT" ] || fail "missing $MANIFEST_SCRIPT"

case "$BUNDLE_DIR" in
  /*) ;;
  *) BUNDLE_DIR="$PWD/$BUNDLE_DIR" ;;
esac
refuse_repo_dest "$BUNDLE_DIR"

mkdir -p "$(dirname "$BUNDLE_DIR")"
BUNDLE_DIR="$(abs_path "$BUNDLE_DIR")"
refuse_repo_dest "$BUNDLE_DIR"

manifest_matches() {
  local manifest="$1"
  python3 - "$manifest" "$REPO_ID" "$REVISION" <<'PY'
import json
import sys

path, repo_id, revision = sys.argv[1:4]
try:
    with open(path, encoding="utf-8") as handle:
        manifest = json.load(handle)
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)
if manifest.get("model_id") == repo_id and manifest.get("version") == revision:
    raise SystemExit(0)
raise SystemExit(1)
PY
}

print_path() {
  printf 'export ORCHARD_MLX_SMOKE_MODEL_PATH=%s\n' "$BUNDLE_DIR"
}

if [ "$FORCE" -eq 0 ] && [ -f "$BUNDLE_DIR/manifest.json" ] && manifest_matches "$BUNDLE_DIR/manifest.json"; then
  print_path
  exit 0
fi

if [ "$PRINT_PATH" -eq 1 ]; then
  fail "pinned bundle is not prepared at $BUNDLE_DIR; run without --print-path"
fi

resolve_snapshot() {
  if [ -n "$FROM_SNAPSHOT" ]; then
    [ -d "$FROM_SNAPSHOT" ] || fail "snapshot directory does not exist: $FROM_SNAPSHOT"
    cd "$FROM_SNAPSHOT" && pwd
    return
  fi

  [ -f "$WORKER_DIR/pyproject.toml" ] || fail "cannot find $WORKER_DIR/pyproject.toml"
  (
    cd "$REPO_ROOT"
    mise exec -- uv run --locked --directory native/orchard_worker_mlx --extra mlx python -c \
      "from huggingface_hub import snapshot_download; print(snapshot_download(repo_id='$REPO_ID', revision='$REVISION'))"
  )
}

SNAPSHOT="$(resolve_snapshot)"
[ -f "$SNAPSHOT/config.json" ] || fail "snapshot is missing config.json: $SNAPSHOT"
[ -f "$SNAPSHOT/tokenizer.json" ] || fail "snapshot is missing tokenizer.json: $SNAPSHOT"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/orchard-mlx-smoke-bundle.XXXXXX")"
cleanup() {
  rm -rf "$STAGE"
}
trap cleanup EXIT INT TERM

shopt -s dotglob nullglob
for path in "$SNAPSHOT"/*; do
  name="$(basename "$path")"
  if skip_name "$name"; then
    continue
  fi
  if [ -d "$path" ] && [ ! -L "$path" ]; then
    cp -R -L "$path" "$STAGE/$name"
  else
    cp -L "$path" "$STAGE/$name"
  fi
done
shopt -u dotglob nullglob

(cd "$REPO_ROOT" && mise exec -- mix run --no-start "$MANIFEST_SCRIPT" "$STAGE" "$REPO_ID" "$REVISION") >/dev/null
[ -f "$STAGE/manifest.json" ] || fail "BundleBuilder did not write manifest.json"
manifest_matches "$STAGE/manifest.json" || fail "written manifest does not match $REPO_ID @$REVISION"

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR"
cp -R "$STAGE"/. "$BUNDLE_DIR"/

printf 'Qwen3 thinking mode can consume a short smoke. Use enable_thinking=false / non-thinking on Chat Completions.\n' >&2
print_path
