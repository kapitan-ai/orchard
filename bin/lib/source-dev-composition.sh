#!/usr/bin/env bash

orchard_source_composition_fail() {
  printf 'orchard-source-composition: %s\n' "$1" >&2
  return "${2:-1}"
}

orchard_source_composition_main() {
  local command=${1:-}
  case "$command" in
    prepare|validate) ;;
    *)
      orchard_source_composition_fail "usage: bin/orchard-source-composition prepare|validate" 64
      return $?
      ;;
  esac

  orchard_source_composition_paths
  orchard_source_composition_validate_invocation || return $?
  orchard_source_composition_validate_source_installation || return $?

  exec 9<>"$ORCHARD_COMPOSITION_LOCK"
  flock -n 9 || {
    orchard_source_composition_fail "lifecycle lock is already held"
    return $?
  }

  orchard_source_composition_validate_inputs || return $?

  if [[ "$command" == "prepare" ]]; then
    orchard_source_composition_prepare || return $?
  fi

  orchard_source_composition_validate_prepared
}

orchard_source_composition_paths() {
  ORCHARD_COMPOSITION_ROOT=${ORCHARD_SOURCE_DEV_ROOT:-}
  ORCHARD_COMPOSITION_PREFIX=${ORCHARD_COMPOSITION_ROOT%/}
  ORCHARD_COMPOSITION_SOURCE=${ORCHARD_SOURCE_DEV_SOURCE:-${ORCHARD_COMPOSITION_PREFIX}/opt/orchard/source}
  ORCHARD_COMPOSITION_INSTALL_STATE="${ORCHARD_COMPOSITION_PREFIX}/var/lib/orchard/install"
  ORCHARD_COMPOSITION_INSTALL_MANIFEST="$ORCHARD_COMPOSITION_INSTALL_STATE/manifest.json"
  ORCHARD_COMPOSITION_INSTALL_RECEIPT="$ORCHARD_COMPOSITION_INSTALL_STATE/receipts/prepare.json"
  ORCHARD_COMPOSITION_LOCK="$ORCHARD_COMPOSITION_INSTALL_STATE/lifecycle.lock"
  ORCHARD_COMPOSITION_CONFIG="${ORCHARD_COMPOSITION_PREFIX}/etc/orchard/source-dev/composition.json"
  ORCHARD_COMPOSITION_CONTROLLER_ENV="${ORCHARD_COMPOSITION_PREFIX}/etc/orchard/controller/controller.env"
  ORCHARD_COMPOSITION_NODE_ENV="${ORCHARD_COMPOSITION_PREFIX}/etc/orchard/node/node-agent.env"
  ORCHARD_COMPOSITION_RECEIPT="$ORCHARD_COMPOSITION_INSTALL_STATE/receipts/composition.json"
}

orchard_source_composition_validate_invocation() {
  if [[ -n "$ORCHARD_COMPOSITION_ROOT" ]]; then
    [[ "$ORCHARD_COMPOSITION_ROOT" == /* && "${ORCHARD_SOURCE_DEV_TESTING:-0}" == "1" ]] || {
      orchard_source_composition_fail "relocated roots require an absolute ORCHARD_SOURCE_DEV_ROOT and ORCHARD_SOURCE_DEV_TESTING=1" 64
      return $?
    }
  else
    [[ ${EUID:-$(id -u)} -eq 0 ]] || {
      orchard_source_composition_fail "canonical composition preparation must run as root"
      return $?
    }
  fi

  [[ "$ORCHARD_COMPOSITION_SOURCE" == "${ORCHARD_COMPOSITION_PREFIX}/opt/orchard/source" ]] || {
    orchard_source_composition_fail "source checkout must be the canonical /opt/orchard/source"
    return $?
  }

  local required
  for required in git jq sha256sum flock stat install sync; do
    command -v "$required" >/dev/null 2>&1 || {
      orchard_source_composition_fail "$required is required"
      return $?
    }
  done
}

orchard_source_composition_validate_source_installation() {
  local path
  for path in "$ORCHARD_COMPOSITION_INSTALL_MANIFEST" "$ORCHARD_COMPOSITION_INSTALL_RECEIPT" "$ORCHARD_COMPOSITION_LOCK"; do
    orchard_source_composition_safe_file "$path" 600 root root || return $?
  done

  jq -e '
    .schema_version == 1 and
    .profile == "ubuntu_24_04_x86_64_single_host" and
    .activation == "disabled" and
    .support_status == "unqualified" and
    (.installation_uuid | type == "string") and
    .source.clean == true
  ' "$ORCHARD_COMPOSITION_INSTALL_MANIFEST" >/dev/null || {
    orchard_source_composition_fail "source installation manifest is not an inert canonical profile"
    return $?
  }
  jq -e '.generation == 4 and .phase == "source_prepared"' "$ORCHARD_COMPOSITION_INSTALL_RECEIPT" >/dev/null || {
    orchard_source_composition_fail "source installation is not fully prepared"
    return $?
  }

  ORCHARD_COMPOSITION_INSTALLATION_UUID=$(jq -r '.installation_uuid' "$ORCHARD_COMPOSITION_INSTALL_MANIFEST")
  ORCHARD_COMPOSITION_COMMIT=$(jq -r '.source.commit' "$ORCHARD_COMPOSITION_INSTALL_MANIFEST")
  ORCHARD_COMPOSITION_TREE=$(jq -r '.source.tree' "$ORCHARD_COMPOSITION_INSTALL_MANIFEST")
  orchard_source_composition_uuid installation "$ORCHARD_COMPOSITION_INSTALLATION_UUID" || return $?

  local current_commit current_tree current_status
  current_commit=$(git -C "$ORCHARD_COMPOSITION_SOURCE" rev-parse --verify HEAD^{commit}) || return $?
  current_tree=$(git -C "$ORCHARD_COMPOSITION_SOURCE" rev-parse --verify HEAD^{tree}) || return $?
  current_status=$(git -C "$ORCHARD_COMPOSITION_SOURCE" status --porcelain=v1 --untracked-files=all) || return $?
  [[ "$current_commit" == "$ORCHARD_COMPOSITION_COMMIT" && "$current_tree" == "$ORCHARD_COMPOSITION_TREE" && -z "$current_status" ]] || {
    orchard_source_composition_fail "source provenance differs from the prepared installation"
    return $?
  }
}

orchard_source_composition_validate_inputs() {
  ORCHARD_COMPOSITION_CONTROLLER_UUID=${ORCHARD_SOURCE_DEV_CONTROLLER_UUID:-}
  ORCHARD_COMPOSITION_NODE_UUID=${ORCHARD_SOURCE_DEV_NODE_UUID:-}
  ORCHARD_COMPOSITION_PRIVATE_IPV4=${ORCHARD_SOURCE_DEV_PRIVATE_IPV4:-}
  orchard_source_composition_uuid controller "$ORCHARD_COMPOSITION_CONTROLLER_UUID" || return $?
  orchard_source_composition_uuid node "$ORCHARD_COMPOSITION_NODE_UUID" || return $?
  [[ "$ORCHARD_COMPOSITION_CONTROLLER_UUID" != "$ORCHARD_COMPOSITION_NODE_UUID" &&
     "$ORCHARD_COMPOSITION_CONTROLLER_UUID" != "$ORCHARD_COMPOSITION_INSTALLATION_UUID" &&
     "$ORCHARD_COMPOSITION_NODE_UUID" != "$ORCHARD_COMPOSITION_INSTALLATION_UUID" ]] || {
    orchard_source_composition_fail "installation, Controller, and Node identities must be distinct"
    return $?
  }
  orchard_source_composition_private_ipv4 "$ORCHARD_COMPOSITION_PRIVATE_IPV4" || return $?

  local controller_compact=${ORCHARD_COMPOSITION_CONTROLLER_UUID//-/}
  local node_compact=${ORCHARD_COMPOSITION_NODE_UUID//-/}
  ORCHARD_COMPOSITION_CONTROLLER_NAME="orchard_controller_${controller_compact}@${ORCHARD_COMPOSITION_PRIVATE_IPV4}"
  ORCHARD_COMPOSITION_NODE_NAME="orchard_node_agent_${node_compact}@${ORCHARD_COMPOSITION_PRIVATE_IPV4}"
}

orchard_source_composition_prepare() {
  [[ ! -e "${ORCHARD_COMPOSITION_PREFIX}/etc/orchard/source-dev/activation-authorized.json" ]] || {
    orchard_source_composition_fail "composition preparation cannot adopt an existing activation authorization"
    return $?
  }
  orchard_source_composition_write_json || return $?
  orchard_source_composition_write_controller_env || return $?
  orchard_source_composition_write_node_env || return $?
  orchard_source_composition_write_receipt || return $?
}

orchard_source_composition_write_json() {
  local manifest_sha temporary="$ORCHARD_COMPOSITION_CONFIG.new.$$"
  manifest_sha=$(sha256sum "$ORCHARD_COMPOSITION_INSTALL_MANIFEST" | cut -d ' ' -f1) || return $?
  jq -n \
    --arg installation "$ORCHARD_COMPOSITION_INSTALLATION_UUID" \
    --arg controller "$ORCHARD_COMPOSITION_CONTROLLER_UUID" \
    --arg node "$ORCHARD_COMPOSITION_NODE_UUID" \
    --arg address "$ORCHARD_COMPOSITION_PRIVATE_IPV4" \
    --arg controller_name "$ORCHARD_COMPOSITION_CONTROLLER_NAME" \
    --arg node_name "$ORCHARD_COMPOSITION_NODE_NAME" \
    --arg commit "$ORCHARD_COMPOSITION_COMMIT" \
    --arg tree "$ORCHARD_COMPOSITION_TREE" \
    --arg manifest_sha "$manifest_sha" '
    {
      schema_version: 1,
      profile: "ubuntu_24_04_x86_64_single_host",
      activation: "disabled",
      support_status: "unqualified",
      installation_uuid: $installation,
      source: {commit: $commit, tree: $tree, manifest_sha256: $manifest_sha},
      host: {private_ipv4: $address},
      controller: {id: $controller, beam_name: $controller_name, distribution_port: 52171, grant_control_port: 8444},
      node: {id: $node, beam_name: $node_name, distribution_port: 52172, grpc_listener: "disabled"},
      authority: {
        enrollment: "postgres",
        admission: "postgres",
        certificate: "postgres_and_role_custody",
        peer_grant: "pair_scoped_postgres_and_role_custody",
        runtime_endpoint: "authenticated_beam_only",
        locality: "none"
      },
      ordering: ["postgresql", "migration", "controller", "node_agent"],
      fallback: {grpc: false, cookie: false, static_target: false}
    }
  ' > "$temporary" || return $?
  orchard_source_composition_install_file "$temporary" "$ORCHARD_COMPOSITION_CONFIG" 640 root root
}

orchard_source_composition_write_controller_env() {
  local temporary="$ORCHARD_COMPOSITION_CONTROLLER_ENV.new.$$"
  cat > "$temporary" <<EOF
ORCHARD_SOURCE_DEV_COMPOSITION=1
ORCHARD_INSTALLATION_UUID=$ORCHARD_COMPOSITION_INSTALLATION_UUID
ORCHARD_CONTROLLER_ID=$ORCHARD_COMPOSITION_CONTROLLER_UUID
ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam
ORCHARD_BEAM_PEER_GRANTS_ENABLED=true
ORCHARD_BEAM_PEER_GRANT_MODE=distributed
ORCHARD_BEAM_NODE_NAME=$ORCHARD_COMPOSITION_CONTROLLER_NAME
ORCHARD_CONTROLLER_MEMBERSHIP_HOST=$ORCHARD_COMPOSITION_PRIVATE_IPV4
ORCHARD_BEAM_PEER_GRANT_CONTROL_HOST=$ORCHARD_COMPOSITION_PRIVATE_IPV4
ORCHARD_BEAM_PEER_GRANT_CONTROL_PORT=8444
ORCHARD_BEAM_DIST_PORT_MIN=52171
ORCHARD_BEAM_DIST_PORT_MAX=52171
ORCHARD_BEAM_AUTHORIZATION_ROOT_PATH=/var/lib/orchard/controller/beam/authorization-root
ORCHARD_NODE_TRUST_ROOT=/var/lib/orchard/controller/beam/node-trust
ORCHARD_BEAM_DISTRIBUTION_LAUNCH_MANIFEST=/var/lib/orchard/controller/beam/launch.json
ORCHARD_BEAM_SSL_DIST_OPTFILE=/var/lib/orchard/controller/beam/ssl-dist.conf
ORCHARD_SOURCE_DEV_SKIP_DB_SETUP=1
ORCHARD_ALLOW_STATIC_RUNTIME_TARGET_FALLBACK=false
PGHOST=/run/postgresql
PGPORT=5432
PGDATABASE=orchard
PGUSER=orchard_controller
EOF
  orchard_source_composition_install_file "$temporary" "$ORCHARD_COMPOSITION_CONTROLLER_ENV" 640 root orchard-controller
}

orchard_source_composition_write_node_env() {
  local temporary="$ORCHARD_COMPOSITION_NODE_ENV.new.$$"
  cat > "$temporary" <<EOF
ORCHARD_SOURCE_DEV_COMPOSITION=1
ORCHARD_INSTALLATION_UUID=$ORCHARD_COMPOSITION_INSTALLATION_UUID
ORCHARD_NODE_ID=$ORCHARD_COMPOSITION_NODE_UUID
ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam
ORCHARD_BEAM_NODE_NAME=$ORCHARD_COMPOSITION_NODE_NAME
ORCHARD_BEAM_DIST_PORT_MIN=52172
ORCHARD_BEAM_DIST_PORT_MAX=52172
ORCHARD_NODE_IDENTITY_ROOT=/var/lib/orchard/node/identity
ORCHARD_NODE_IDENTITY_PATH=/var/lib/orchard/node/identity/node-id
ORCHARD_BEAM_PEER_GRANT_DESCRIPTOR=/var/lib/orchard/node/beam/peer-grant.json
ORCHARD_BEAM_DISTRIBUTION_LAUNCH_MANIFEST=/var/lib/orchard/node/beam/launch.json
ORCHARD_BEAM_SSL_DIST_OPTFILE=/var/lib/orchard/node/beam/ssl-dist.conf
ORCHARD_NODE_AGENT_LISTEN_HOST=$ORCHARD_COMPOSITION_PRIVATE_IPV4
ORCHARD_NODE_AGENT_LISTEN_PORT=9444
ORCHARD_RUNTIME_CLIENT_PORT=9444
ORCHARD_NODE_AGENT_GRPC_LISTENER_ENABLED=false
EOF
  orchard_source_composition_install_file "$temporary" "$ORCHARD_COMPOSITION_NODE_ENV" 640 root orchard-node
}

orchard_source_composition_write_receipt() {
  local composition_sha temporary="$ORCHARD_COMPOSITION_RECEIPT.new.$$"
  composition_sha=$(sha256sum "$ORCHARD_COMPOSITION_CONFIG" | cut -d ' ' -f1) || return $?
  jq -n \
    --arg installation "$ORCHARD_COMPOSITION_INSTALLATION_UUID" \
    --arg controller "$ORCHARD_COMPOSITION_CONTROLLER_UUID" \
    --arg node "$ORCHARD_COMPOSITION_NODE_UUID" \
    --arg commit "$ORCHARD_COMPOSITION_COMMIT" \
    --arg tree "$ORCHARD_COMPOSITION_TREE" \
    --arg composition_sha "$composition_sha" '
    {
      schema_version: 1,
      generation: 1,
      operation: "compose_authenticated_same_host",
      phase: "composition_prepared_inert",
      installation_uuid: $installation,
      controller_id: $controller,
      node_id: $node,
      source: {commit: $commit, tree: $tree},
      composition_sha256: $composition_sha,
      activation: "disabled"
    }
  ' > "$temporary" || return $?
  orchard_source_composition_install_file "$temporary" "$ORCHARD_COMPOSITION_RECEIPT" 600 root root
}

orchard_source_composition_validate_prepared() {
  local expected_manifest_sha expected_composition_sha
  orchard_source_composition_safe_file "$ORCHARD_COMPOSITION_CONFIG" 640 root root || return $?
  orchard_source_composition_safe_file "$ORCHARD_COMPOSITION_CONTROLLER_ENV" 640 root orchard-controller || return $?
  orchard_source_composition_safe_file "$ORCHARD_COMPOSITION_NODE_ENV" 640 root orchard-node || return $?
  orchard_source_composition_safe_file "$ORCHARD_COMPOSITION_RECEIPT" 600 root root || return $?
  expected_manifest_sha=$(sha256sum "$ORCHARD_COMPOSITION_INSTALL_MANIFEST" | cut -d ' ' -f1) || return $?
  expected_composition_sha=$(sha256sum "$ORCHARD_COMPOSITION_CONFIG" | cut -d ' ' -f1) || return $?
  jq -e \
    --arg installation "$ORCHARD_COMPOSITION_INSTALLATION_UUID" \
    --arg controller "$ORCHARD_COMPOSITION_CONTROLLER_UUID" \
    --arg node "$ORCHARD_COMPOSITION_NODE_UUID" \
    --arg address "$ORCHARD_COMPOSITION_PRIVATE_IPV4" \
    --arg controller_name "$ORCHARD_COMPOSITION_CONTROLLER_NAME" \
    --arg node_name "$ORCHARD_COMPOSITION_NODE_NAME" \
    --arg manifest_sha "$expected_manifest_sha" '
    .schema_version == 1 and .activation == "disabled" and .support_status == "unqualified" and
    .installation_uuid == $installation and .source.manifest_sha256 == $manifest_sha and
    .host.private_ipv4 == $address and .controller.id == $controller and .node.id == $node and
    .controller.beam_name == $controller_name and .node.beam_name == $node_name and
    .authority.enrollment == "postgres" and .authority.admission == "postgres" and
    .authority.peer_grant == "pair_scoped_postgres_and_role_custody" and
    .authority.runtime_endpoint == "authenticated_beam_only" and .authority.locality == "none" and
    .fallback == {grpc:false,cookie:false,static_target:false}
  ' "$ORCHARD_COMPOSITION_CONFIG" >/dev/null || {
    orchard_source_composition_fail "prepared composition differs from the requested exact identities"
    return $?
  }
  jq -e --arg sha "$expected_composition_sha" '
    .generation == 1 and .phase == "composition_prepared_inert" and
    .activation == "disabled" and .composition_sha256 == $sha
  ' "$ORCHARD_COMPOSITION_RECEIPT" >/dev/null || {
    orchard_source_composition_fail "composition receipt is invalid or stale"
    return $?
  }
  orchard_source_composition_validate_env controller "$ORCHARD_COMPOSITION_CONTROLLER_ENV" || return $?
  orchard_source_composition_validate_env node-agent "$ORCHARD_COMPOSITION_NODE_ENV" || return $?
  printf 'orchard-source-composition: prepared inert authenticated composition %s\n' "$ORCHARD_COMPOSITION_INSTALLATION_UUID"
}

orchard_source_composition_validate_env() {
  local role=$1 path=$2
  grep -Fx 'ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam' "$path" >/dev/null || return 1
  if grep -E 'ORCHARD_BEAM_COOKIE_FILE|ORCHARD_RUNTIME_ENDPOINT_TARGETS|ORCHARD_RUNTIME_CLIENT_TARGETS' "$path" >/dev/null; then
    orchard_source_composition_fail "$role environment contains forbidden fallback authority"
    return $?
  fi
  case "$role" in
    controller)
      grep -Fx "ORCHARD_BEAM_NODE_NAME=$ORCHARD_COMPOSITION_CONTROLLER_NAME" "$path" >/dev/null &&
        grep -Fx 'ORCHARD_ALLOW_STATIC_RUNTIME_TARGET_FALLBACK=false' "$path" >/dev/null
      ;;
    node-agent)
      grep -Fx "ORCHARD_BEAM_NODE_NAME=$ORCHARD_COMPOSITION_NODE_NAME" "$path" >/dev/null &&
        grep -Fx 'ORCHARD_NODE_AGENT_GRPC_LISTENER_ENABLED=false' "$path" >/dev/null
      ;;
  esac || {
    orchard_source_composition_fail "$role environment does not preserve authenticated composition"
    return $?
  }
}

orchard_source_composition_install_file() {
  local temporary=$1 destination=$2 mode=$3 owner=$4 group=$5
  if [[ -n "$ORCHARD_COMPOSITION_ROOT" ]]; then
    owner=$(id -un)
    group=$(id -gn)
  fi
  if [[ -e "$destination" || -L "$destination" ]]; then
    orchard_source_composition_safe_file "$destination" "$mode" "$owner" "$group" || return $?
    cmp -s "$temporary" "$destination" || {
      rm -f "$temporary"
      orchard_source_composition_fail "refusing to replace conflicting composition file $destination"
      return $?
    }
    rm -f "$temporary"
    return 0
  fi
  install -o "$owner" -g "$group" -m "$mode" "$temporary" "$destination" || return $?
  rm -f "$temporary"
  sync -f "$destination" || return $?
  sync -f "$(dirname "$destination")" || return $?
}

orchard_source_composition_safe_file() {
  local path=$1 expected_mode=${2:-} expected_owner=${3:-} expected_group=${4:-}
  if [[ -n "$ORCHARD_COMPOSITION_ROOT" ]]; then
    expected_owner=$(id -un)
    expected_group=$(id -gn)
  fi
  [[ -f "$path" && ! -L "$path" && $(stat -Lc %h "$path") == "1" ]] || {
    orchard_source_composition_fail "required file is missing or unsafe: $path"
    return $?
  }
  local mode owner group
  mode=$(stat -Lc %a "$path") || return $?
  owner=$(stat -Lc %U "$path") || return $?
  group=$(stat -Lc %G "$path") || return $?
  [[ $((8#$mode & 0022)) -eq 0 ]] || {
    orchard_source_composition_fail "required file is group/world writable: $path"
    return $?
  }
  [[ -z "$expected_mode" || "$mode" == "$expected_mode" ]] || {
    orchard_source_composition_fail "required file has mode $mode, expected $expected_mode: $path"
    return $?
  }
  [[ -z "$expected_owner" || "$owner" == "$expected_owner" ]] || {
    orchard_source_composition_fail "required file has owner $owner, expected $expected_owner: $path"
    return $?
  }
  [[ -z "$expected_group" || "$group" == "$expected_group" ]] || {
    orchard_source_composition_fail "required file has group $group, expected $expected_group: $path"
    return $?
  }
}

orchard_source_composition_uuid() {
  local kind=$1 value=${2:-}
  [[ "$value" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || {
    orchard_source_composition_fail "$kind UUID is invalid"
    return $?
  }
}

orchard_source_composition_private_ipv4() {
  local value=$1 a b c d
  IFS=. read -r a b c d <<< "$value"
  [[ -n "$a" && -n "$b" && -n "$c" && -n "$d" && "$value" != *[!0-9.]* ]] || {
    orchard_source_composition_fail "private address must be an RFC1918 IPv4 literal"
    return $?
  }
  local octet
  for octet in "$a" "$b" "$c" "$d"; do
    [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ && "$octet" -le 255 ]] || {
      orchard_source_composition_fail "private address must be an RFC1918 IPv4 literal"
      return $?
    }
  done
  if [[ "$a" == 10 || ( "$a" == 172 && "$b" -ge 16 && "$b" -le 31 ) || ( "$a" == 192 && "$b" == 168 ) ]]; then
    return 0
  fi
  orchard_source_composition_fail "private address must be an RFC1918 IPv4 literal"
}
