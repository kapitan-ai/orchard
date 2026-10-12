#!/usr/bin/env bash

# The candidate is opt-in; ordinary source development keeps its existing path.
orchard_source_node_startup() {
  local repo_root="$1" role="$2" stage="${3:-}"
  local profile="${ORCHARD_NODE_PLATFORM_PROFILE-}"

  if [[ -z "${ORCHARD_NODE_PLATFORM_PROFILE+x}" ]]; then
    if [[ -n "${ORCHARD_NODE_ROOT_GUARD-}" || "$stage" == "--orchard-node-guarded" ]]; then
      echo 'error: candidate guardian context requires an explicit platform profile' >&2
      return 64
    fi
    return 0
  fi

  if [[ "$profile" != 'ubuntu_24_04_x86_64_node' || "$role" != 'node_agent' ]]; then
    echo 'error: experimental Node profile requires the Node-only source launcher' >&2
    return 64
  fi
  if [[ -n "${ORCHARD_NODE_ID+x}" || -n "${ORCHARD_NODE_IDENTITY_PATH+x}" ]]; then
    echo 'error: candidate identity must come from its registered Node Identity Root' >&2
    return 64
  fi
  if [[ -z "${ORCHARD_NODE_IDENTITY_ROOT-}" || -z "${ORCHARD_BEAM_PEER_GRANT_DESCRIPTOR-}" ]]; then
    echo 'error: candidate requires an explicit registered root and Peer Grant descriptor' >&2
    return 64
  fi
  if [[ "${ORCHARD_RUNTIME_ENDPOINT_TRANSPORT:-beam}" != 'beam' ||
        -n "${ORCHARD_BEAM_COOKIE_FILE+x}" || -n "${ORCHARD_RUNTIME_ENDPOINT_TARGETS+x}" ]]; then
    echo 'error: candidate requires the certificate and Peer Grant source path' >&2
    return 64
  fi

  local helper="$repo_root/.local/linux-node-root-guardian/orchard-node-root-guardian"
  if [[ ! -x "$helper" ]]; then
    echo 'error: build the Linux Node root guardian before selecting the candidate' >&2
    return 78
  fi

  if [[ "$stage" == '--orchard-node-guarded' ]]; then
    if [[ -z "${ORCHARD_NODE_ROOT_GUARD-}" ]]; then
      echo 'error: candidate source stage requires a live root guardian' >&2
      return 64
    fi
    "$helper" --verify "$ORCHARD_NODE_IDENTITY_ROOT" "$ORCHARD_NODE_ROOT_GUARD" "$$"
    return $?
  fi
  if [[ -n "${ORCHARD_NODE_ROOT_GUARD-}" || -n "$stage" ]]; then
    echo 'error: invalid candidate source guardian entrypoint' >&2
    return 64
  fi

  exec "$helper" --run "$ORCHARD_NODE_IDENTITY_ROOT" -- \
    "$repo_root/bin/dev-node-agent" --orchard-node-guarded
}

orchard_source_node_preflight() {
  local repo_root="$1"
  if [[ -z "${ORCHARD_NODE_PLATFORM_PROFILE+x}" ]]; then
    return 0
  fi

  # This VM has no Distribution and starts no applications. The guardian remains
  # the parent of the launcher; the final exec preserves the guarded child PID.
  local script="$repo_root/scripts/support/linux-node-source-preflight.exs"
  if [[ "${ORCHARD_SOURCE_DEV_NO_COMPILE:-0}" == '1' ]]; then
    mix run --no-compile --no-start "$script"
  else
    mix run --no-start "$script"
  fi
}
