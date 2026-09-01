#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMITTED_ROOT="$REPO_ROOT"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --committed-root)
      [[ $# -ge 2 ]] || {
        printf '%s\n' 'check-worker-runtime-bindings: --committed-root requires a value' >&2
        exit 2
      }
      COMMITTED_ROOT="$2"
      shift 2
      ;;
    *)
      printf 'check-worker-runtime-bindings: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

case "$COMMITTED_ROOT" in
  /*) ;;
  *) COMMITTED_ROOT="$(pwd)/$COMMITTED_ROOT" ;;
esac

GENERATED_ROOT="$(mktemp -d /tmp/orchard-worker-runtime-check.XXXXXX)"
trap 'rm -rf "$GENERATED_ROOT"' EXIT

"$REPO_ROOT/scripts/generate-worker-runtime-bindings.sh" \
  --output-root "$GENERATED_ROOT" >/dev/null

MANIFEST="$GENERATED_ROOT/manifest.txt"
DISCOVERED="$GENERATED_ROOT/discovered.txt"
"$REPO_ROOT/scripts/generate-worker-runtime-bindings.sh" --list-outputs | sort > "$MANIFEST"

{
  printf '%s\n' \
    apps/orchard_node_agent/lib/orchard/node/worker_runtime.pb.ex \
    proto/orchard/worker/v1/worker_runtime.descriptor.pb
  find "$COMMITTED_ROOT/native/orchard_worker_mlx/src/orchard_worker_mlx/generated" \
    -type f \( -name '*_pb2.py' -o -name '*_pb2_grpc.py' \) -print \
    | sed "s#^$COMMITTED_ROOT/##"
} | sort > "$DISCOVERED"

if ! cmp -s "$MANIFEST" "$DISCOVERED"; then
  printf '%s\n' 'generated output manifest does not match committed generated bindings' >&2
  diff -u "$MANIFEST" "$DISCOVERED" >&2 || true
  exit 1
fi

drift=false
while IFS= read -r relative_path; do
  committed="$COMMITTED_ROOT/$relative_path"
  generated="$GENERATED_ROOT/$relative_path"

  if [[ ! -f "$committed" ]]; then
    printf 'missing committed generated output: %s\n' "$relative_path" >&2
    drift=true
  elif ! cmp -s "$committed" "$generated"; then
    printf 'generated output drift: %s\n' "$relative_path" >&2
    drift=true
  fi
done < "$MANIFEST"

if [[ "$drift" == "true" ]]; then
  printf '%s\n' \
    'Worker Runtime bindings drifted; run mise exec -- mix proto.gen.worker and commit the outputs' >&2
  exit 1
fi

printf 'committed Worker Runtime bindings match the canonical schema\n'
