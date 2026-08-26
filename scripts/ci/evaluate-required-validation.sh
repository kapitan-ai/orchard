#!/usr/bin/env bash

set -euo pipefail

validate_required() {
  local label="$1"
  local required="$2"

  case "$required" in
    true|false)
      ;;
    *)
      printf '%s requirement must be true or false, got: %s\n' "$label" "$required" >&2
      return 1
      ;;
  esac
}

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

validate_required "Linux portable-core validation" "${PORTABLE_REQUIRED:?}"
validate_required "Provider-neutral conformance" "${CONFORMANCE_REQUIRED:?}"
validate_required "macOS host validation" "${MACOS_REQUIRED:?}"
validate_required "MLX validation" "${MLX_REQUIRED:?}"
validate_required "Packaging validation" "${PACKAGING_REQUIRED:?}"
validate_required "OpenSpec validation" "${OPENSPEC_REQUIRED:?}"

require_result "Linux portable-core validation" "${PORTABLE_REQUIRED:?}" "${PORTABLE_RESULT:?}"
require_result "Provider-neutral conformance" "${CONFORMANCE_REQUIRED:?}" "${CONFORMANCE_RESULT:?}"
require_result "macOS host validation" "${MACOS_REQUIRED:?}" "${MACOS_RESULT:?}"
require_result "MLX validation" "${MLX_REQUIRED:?}" "${MLX_RESULT:?}"
require_result "Packaging validation" "${PACKAGING_REQUIRED:?}" "${PACKAGING_RESULT:?}"
require_result "OpenSpec validation" "${OPENSPEC_REQUIRED:?}" "${OPENSPEC_RESULT:?}"

printf 'All applicable Orchard validation lanes passed and all other lanes were skipped.\n'
