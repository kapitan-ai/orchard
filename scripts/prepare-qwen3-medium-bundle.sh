#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" == 1 && ( "$1" == --help || "$1" == -h ) ]]; then
  cat <<'HELP'
Usage: scripts/prepare-qwen3-medium-bundle.sh SNAPSHOT NEW_BUNDLE_DIRECTORY

Offline, opt-in preparation of the pinned Qwen3.8-27B MLX8bit bundle.
Both arguments must be absolute paths. Requires the complete materialized
19-file publisher snapshot, existing pinned
dependencies and tokenizer helper. Destination parent must exist; destination
must be new and outside the repository and snapshot. No downloads, inference,
service startup, import, activation or verification-receipt changes.
HELP
  exit 0
fi

if [[ "$#" != 2 ]]; then
  printf 'Expected SNAPSHOT and NEW_BUNDLE_DIRECTORY; use --help.\n' >&2
  exit 64
fi

for pilot_path in "$@"; do
  if [[ "$pilot_path" != /* ]]; then
    printf 'SNAPSHOT and NEW_BUNDLE_DIRECTORY must be absolute paths.\n' >&2
    exit 64
  fi
done

pilot_script_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$pilot_script_dir/.."
exec mise exec -- mix run --no-start -e \
  'Code.require_file("scripts/support/prepare_qwen3_medium_bundle.exs"); [source, dest] = System.argv(); IO.puts(Orchard.Scripts.PrepareQwen3MediumBundle.prepare!(source, dest))' \
  -- "$@"
