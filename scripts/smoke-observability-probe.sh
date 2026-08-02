#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 CONFIG.json" >&2
  exit 64
fi

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

exec mise exec -- mix run --no-start \
  -e 'Code.require_file("scripts/support/observability_probe.exs"); Orchard.ObservabilityProbe.main(System.argv())' \
  -- "$1"
