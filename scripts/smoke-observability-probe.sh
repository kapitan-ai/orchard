#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 CONFIG.json" >&2
  echo "exit codes: 0=pass 1=probe fail 2=invalid config 64=usage" >&2
  exit 64
fi

CONFIG_PATH=$1
case "$CONFIG_PATH" in
  /*) ;;
  *) CONFIG_PATH="$(pwd -P)/$CONFIG_PATH" ;;
esac

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

mise exec -- mix compile >/dev/null

exec mise exec -- mix run --no-compile --no-start \
  -e 'Code.require_file("scripts/support/observability_probe.exs"); Orchard.ObservabilityProbe.main(System.argv())' \
  -- "$CONFIG_PATH"
