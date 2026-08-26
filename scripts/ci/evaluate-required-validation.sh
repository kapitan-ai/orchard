#!/usr/bin/env bash

set -euo pipefail

require_result() {
  local label="$1"
  local required="$2"
  local result="$3"

  if [[ "$required" == "true" && "$result" != "success" ]]; then
    printf '%s was required but finished with result: %s\n' "$label" "$result" >&2
    return 1
  fi

  if [[ "$required" != "true" && "$result" != "skipped" ]]; then
    printf '%s was not required but finished with result: %s\n' "$label" "$result" >&2
    return 1
  fi
}

if [[ "${CHANGES_RESULT:?}" != "success" ]]; then
  printf 'Changed-path classification finished with result: %s\n' "$CHANGES_RESULT" >&2
  exit 1
fi

require_result "Linux portable-core validation" "${PORTABLE_REQUIRED:?}" "${PORTABLE_RESULT:?}"
require_result "Provider-neutral conformance" "${CONFORMANCE_REQUIRED:?}" "${CONFORMANCE_RESULT:?}"
require_result "macOS host validation" "${MACOS_REQUIRED:?}" "${MACOS_RESULT:?}"
require_result "MLX validation" "${MLX_REQUIRED:?}" "${MLX_RESULT:?}"
require_result "Packaging validation" "${PACKAGING_REQUIRED:?}" "${PACKAGING_RESULT:?}"
require_result "OpenSpec validation" "${OPENSPEC_REQUIRED:?}" "${OPENSPEC_RESULT:?}"

printf 'All applicable Orchard validation lanes passed and all other lanes were skipped.\n'
