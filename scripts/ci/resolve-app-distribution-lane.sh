#!/usr/bin/env bash
#
# Reads lane classification lines on stdin, passes them through, and appends
# app_distribution=<true|false>. The Orchard.app and DMG assembly lane is
# required only when packaging is affected and the committed Distribution
# Pause Control is active (SPEC.md §11.0).

set -euo pipefail

unset CDPATH
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$SCRIPT_DIR" != "${BASH_SOURCE[0]}" ]] || SCRIPT_DIR=.
REPO_ROOT="$(builtin cd -P -- "$SCRIPT_DIR/../.." && builtin pwd -P)"
# shellcheck source=scripts/lib/distribution-control.sh
source "$REPO_ROOT/scripts/lib/distribution-control.sh"

reject() {
  printf 'resolve-app-distribution-lane: %s\n' "$1" >&2
  exit 1
}

lines=()
packaging=""

while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  case "$line" in
    packaging=true|packaging=false)
      [[ -z "$packaging" ]] || reject 'packaging classification appears more than once'
      packaging="${line#packaging=}"
      ;;
    packaging=*)
      reject "malformed packaging classification: $line"
      ;;
    app_distribution=*)
      reject 'input already contains an app_distribution classification'
      ;;
  esac
  lines+=("$line")
done

[[ -n "$packaging" ]] || reject 'input has no packaging classification'

orchard_distribution_read_state "$REPO_ROOT"
printf 'resolve-app-distribution-lane: distribution %s (%s)\n' \
  "$ORCHARD_DISTRIBUTION_STATE" "$ORCHARD_DISTRIBUTION_STATE_REASON" >&2

app_distribution=false
if [[ "$packaging" == "true" && "$ORCHARD_DISTRIBUTION_STATE" == "active" ]]; then
  app_distribution=true
fi

printf '%s\n' "${lines[@]}"
printf 'app_distribution=%s\n' "$app_distribution"
