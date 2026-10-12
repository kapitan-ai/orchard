# shellcheck shell=bash
#
# Reads the committed Orchard Distribution Pause Control.
# Callers pass the repository root derived from their own location; the
# control path is never taken from the environment, and no environment
# variable can resume a paused distribution.
#
# Compatible with Bash 3.2 because distribution entrypoints run under
# /bin/bash on macOS.

ORCHARD_DISTRIBUTION_CONTROL_PATH="packaging/distribution-control"
ORCHARD_DISTRIBUTION_PAUSED_STATUS=78

# Sets ORCHARD_DISTRIBUTION_STATE to "active" or "paused" and
# ORCHARD_DISTRIBUTION_STATE_REASON to a short explanation.
# Anything other than exactly one "state=active" line resolves to paused.
orchard_distribution_read_state() {
  local repo_root="$1"
  local control="$repo_root/$ORCHARD_DISTRIBUTION_CONTROL_PATH"
  local line
  local value=""
  local state_lines=0

  ORCHARD_DISTRIBUTION_STATE="paused"
  ORCHARD_DISTRIBUTION_STATE_REASON=""

  if [[ -L "$control" ]]; then
    ORCHARD_DISTRIBUTION_STATE_REASON="control is a symlink"
    return 0
  fi
  if [[ ! -f "$control" ]]; then
    ORCHARD_DISTRIBUTION_STATE_REASON="control file is missing"
    return 0
  fi
  if [[ ! -r "$control" ]]; then
    ORCHARD_DISTRIBUTION_STATE_REASON="control file is unreadable"
    return 0
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      ''|'#'*)
        continue
        ;;
      state=*)
        state_lines=$((state_lines + 1))
        value="${line#state=}"
        ;;
      *)
        ORCHARD_DISTRIBUTION_STATE_REASON="control contains an unrecognized line"
        return 0
        ;;
    esac
  done < "$control"

  if [[ "$state_lines" -ne 1 ]]; then
    ORCHARD_DISTRIBUTION_STATE_REASON="control must declare state exactly once"
    return 0
  fi

  case "$value" in
    active)
      ORCHARD_DISTRIBUTION_STATE="active"
      ORCHARD_DISTRIBUTION_STATE_REASON="control declares state=active"
      ;;
    paused)
      ORCHARD_DISTRIBUTION_STATE_REASON="control declares state=paused"
      ;;
    *)
      ORCHARD_DISTRIBUTION_STATE_REASON="control declares an unsupported state"
      ;;
  esac
  return 0
}

# Returns 0 when distribution is active. Otherwise prints the refusal to
# stderr and returns ORCHARD_DISTRIBUTION_PAUSED_STATUS.
orchard_require_distribution_active() {
  local repo_root="$1"
  local entrypoint="$2"

  orchard_distribution_read_state "$repo_root"
  if [[ "$ORCHARD_DISTRIBUTION_STATE" == "active" ]]; then
    return 0
  fi

  printf '%s: Orchard.app and DMG distribution is paused (%s in %s).\n' \
    "$entrypoint" "$ORCHARD_DISTRIBUTION_STATE_REASON" \
    "$ORCHARD_DISTRIBUTION_CONTROL_PATH" >&2
  printf '%s: source development is the current installation path; see docs/local-dev.md.\n' \
    "$entrypoint" >&2
  printf '%s: resuming requires a reviewed change to %s approved by the accountable product owner; see packaging/dmg/README.md.\n' \
    "$entrypoint" "$ORCHARD_DISTRIBUTION_CONTROL_PATH" >&2
  return "$ORCHARD_DISTRIBUTION_PAUSED_STATUS"
}
