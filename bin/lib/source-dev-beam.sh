#!/usr/bin/env bash
# Shared source-dev BEAM bootstrap for split-role Orchard scripts.

orchard_source_dev_beam_bootstrap() {
  local role="$1"
  local repo_root="$2"

  ORCHARD_BEAM_IEX_ARGS=()

  local transport
  transport="$(orchard_source_dev_beam_trim "${ORCHARD_RUNTIME_ENDPOINT_TRANSPORT:-}")"
  case "$transport" in
    ""|beam)
      export ORCHARD_RUNTIME_ENDPOINT_TRANSPORT="beam"
      ;;
    grpc)
      export ORCHARD_RUNTIME_ENDPOINT_TRANSPORT="grpc"
      export ORCHARD_SOURCE_DEV_ROLE="$role"
      return 0
      ;;
    *)
      echo "error: ORCHARD_RUNTIME_ENDPOINT_TRANSPORT must be grpc|beam, got: $transport" >&2
      return 64
      ;;
  esac

  export ORCHARD_SOURCE_DEV_ROLE="$role"

  local peer_grant_mode="${ORCHARD_BEAM_PEER_GRANT_MODE:-}"
  if [[ "$role" == "controller" && "${ORCHARD_BEAM_PEER_GRANTS_ENABLED:-}" == "true" && "$peer_grant_mode" == "grant_control" ]]; then
    echo "==> Runtime endpoint transport: beam peer-grant control phase (Distribution disabled)" >&2
    return 0
  fi

  local peer_grant_launch=0
  if [[ "$role" == "controller" && "${ORCHARD_BEAM_PEER_GRANTS_ENABLED:-}" == "true" && "$peer_grant_mode" == "distributed" ]]; then
    peer_grant_launch=1
  elif [[ "$role" == "node_agent" && -n "${ORCHARD_BEAM_PEER_GRANT_DESCRIPTOR:-}" && -n "${ORCHARD_BEAM_DISTRIBUTION_LAUNCH_MANIFEST:-}" ]]; then
    peer_grant_launch=1
  fi

  local node_name node_host
  node_name="$(orchard_source_dev_beam_default_node_name "$role")"
  node_name="${ORCHARD_BEAM_NODE_NAME:-$node_name}"
  orchard_source_dev_beam_validate_node_name "$role" "$node_name" "$peer_grant_launch" || return $?
  node_host="${node_name#*@}"
  export ORCHARD_BEAM_NODE_NAME="$node_name"

  local cookie_file ssl_dist_optfile
  if (( peer_grant_launch == 1 )); then
    if [[ -n "${ORCHARD_BEAM_COOKIE_FILE+x}" ]]; then
      echo "error: ORCHARD_BEAM_COOKIE_FILE is forbidden for peer-grant Distribution" >&2
      return 64
    fi

    if [[ -n "${ORCHARD_RUNTIME_ENDPOINT_TARGETS:-}" ]]; then
      echo "error: ORCHARD_RUNTIME_ENDPOINT_TARGETS is forbidden for peer-grant Distribution" >&2
      return 64
    fi

    orchard_source_dev_beam_validate_owner_only_file \
      "ORCHARD_BEAM_DISTRIBUTION_LAUNCH_MANIFEST" \
      "${ORCHARD_BEAM_DISTRIBUTION_LAUNCH_MANIFEST:-}" || return $?

    ssl_dist_optfile="${ORCHARD_BEAM_SSL_DIST_OPTFILE:-}"
    orchard_source_dev_beam_validate_owner_only_file \
      "ORCHARD_BEAM_SSL_DIST_OPTFILE" \
      "$ssl_dist_optfile" || return $?

    cookie_file="$repo_root/tmp/dev/beam-peer-grant-cookie/$role.cookie"
    orchard_source_dev_beam_prepare_cookie "$cookie_file" "" || return $?
  else
    cookie_file="${ORCHARD_BEAM_COOKIE_FILE:-$repo_root/tmp/dev/beam.cookie}"
    orchard_source_dev_beam_prepare_cookie "$cookie_file" "${ORCHARD_BEAM_COOKIE_FILE+x}" || return $?
    export ORCHARD_BEAM_COOKIE_FILE="$cookie_file"
  fi

  local epmd_port
  epmd_port="${ORCHARD_BEAM_EPMD_PORT:-4369}"
  orchard_source_dev_beam_validate_port "ORCHARD_BEAM_EPMD_PORT" "$epmd_port" || return $?
  export ORCHARD_BEAM_EPMD_PORT="$epmd_port"
  export ERL_EPMD_PORT="$epmd_port"
  export ERL_EPMD_ADDRESS="$node_host"

  local dist_min="${ORCHARD_BEAM_DIST_PORT_MIN:-}"
  local dist_max="${ORCHARD_BEAM_DIST_PORT_MAX:-}"
  if [[ -z "$dist_min" && -z "$dist_max" ]]; then
    case "$role" in
      controller)
        dist_min=52171
        dist_max=52171
        ;;
      node_agent)
        dist_min=52172
        dist_max=52172
        ;;
      *)
        echo "error: unsupported source-dev role: $role" >&2
        return 64
        ;;
    esac
  elif [[ -z "$dist_min" || -z "$dist_max" ]]; then
    echo "error: ORCHARD_BEAM_DIST_PORT_MIN and ORCHARD_BEAM_DIST_PORT_MAX must be set together" >&2
    return 64
  fi

  orchard_source_dev_beam_validate_port "ORCHARD_BEAM_DIST_PORT_MIN" "$dist_min" || return $?
  orchard_source_dev_beam_validate_port "ORCHARD_BEAM_DIST_PORT_MAX" "$dist_max" || return $?
  if (( dist_min > dist_max )); then
    echo "error: ORCHARD_BEAM_DIST_PORT_MIN must be less than or equal to ORCHARD_BEAM_DIST_PORT_MAX" >&2
    return 64
  fi
  export ORCHARD_BEAM_DIST_PORT_MIN="$dist_min"
  export ORCHARD_BEAM_DIST_PORT_MAX="$dist_max"

  local dist_interface
  dist_interface="$(orchard_source_dev_beam_inet_dist_interface "$node_host")" || return $?

  orchard_source_dev_beam_preflight_epmd "$node_host" "$epmd_port" || return $?
  orchard_source_dev_beam_prepare_home "$role" "$repo_root" "$cookie_file" || return $?

  # shellcheck disable=SC2034 # Consumed by caller scripts after this file is sourced.
  if (( peer_grant_launch == 1 )); then
    ORCHARD_BEAM_IEX_ARGS=(
      --name "$node_name"
      --erl "-proto_dist inet_tls -ssl_dist_optfile $ssl_dist_optfile -kernel inet_dist_use_interface $dist_interface inet_dist_listen_min $dist_min inet_dist_listen_max $dist_max"
    )
  else
    ORCHARD_BEAM_IEX_ARGS=(
      --name "$node_name"
      --erl "-kernel inet_dist_use_interface $dist_interface inet_dist_listen_min $dist_min inet_dist_listen_max $dist_max"
    )
  fi

  echo "==> Runtime endpoint transport: beam" >&2
  echo "==> BEAM node name: $node_name" >&2
  if (( peer_grant_launch == 1 )); then
    echo "==> BEAM peer-grant TLS optfile: $ssl_dist_optfile" >&2
    echo "==> BEAM local fallback cookie is role-local and not pair authorization" >&2
  else
    echo "==> BEAM cookie file: $cookie_file" >&2
  fi
  echo "==> BEAM EPMD port: $epmd_port" >&2
  echo "==> BEAM distribution port range: $dist_min..$dist_max" >&2
}

orchard_source_dev_beam_default_node_name() {
  case "$1" in
    controller)
      printf '%s\n' 'orchard_controller@127.0.0.1'
      ;;
    node_agent)
      printf '%s\n' 'orchard_node_agent@127.0.0.1'
      ;;
    *)
      echo "error: unsupported source-dev role: $1" >&2
      return 64
      ;;
  esac
}

orchard_source_dev_beam_validate_node_name() {
  local role="$1"
  local node_name="$2"
  local peer_grant_launch="${3:-0}"
  local peer_grant_name_mode="$peer_grant_launch"
  local service host rest

  if [[ "$role" == "node_agent" && -n "${ORCHARD_BEAM_PEER_GRANT_DESCRIPTOR:-}" ]]; then
    peer_grant_name_mode=1
  fi

  IFS='@' read -r service host rest <<< "$node_name"
  if [[ -z "${service:-}" || -z "${host:-}" || -n "${rest:-}" ]]; then
    echo "error: ORCHARD_BEAM_NODE_NAME must be a long BEAM node name in service@ipv4 form" >&2
    return 64
  fi

  if [[ ! "$service" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    echo "error: ORCHARD_BEAM_NODE_NAME service contains invalid characters" >&2
    return 64
  fi

  case "$role" in
    controller)
      if (( peer_grant_launch == 1 )) && [[ ! "$service" =~ ^orchard_controller_[0-9a-f]{32}$ ]]; then
        echo "error: peer-grant controller BEAM node service must be orchard_controller_<controller-id>" >&2
        return 64
      elif (( peer_grant_launch == 0 )) && [[ "$service" != orchard_controller* ]]; then
        echo "error: controller BEAM node service must start with orchard_controller" >&2
        return 64
      fi
      ;;
    node_agent)
      if [[ -n "${ORCHARD_BEAM_PEER_GRANT_DESCRIPTOR:-}" ]]; then
        if [[ ! "$service" =~ ^orchard_node_agent_[0-9a-f]{32}$ ]]; then
          echo "error: peer-grant node-agent BEAM node service must be orchard_node_agent_<node-id>" >&2
          return 64
        fi
      elif [[ "$service" != orchard_node_agent ]]; then
          echo "error: node-agent BEAM node service must be exactly orchard_node_agent" >&2
          return 64
      fi
      ;;
    *)
      echo "error: unsupported source-dev role: $role" >&2
      return 64
      ;;
  esac

  if ! orchard_source_dev_beam_is_ipv4_literal "$host"; then
    echo "error: ORCHARD_BEAM_NODE_NAME host must be an IPv4 literal" >&2
    return 64
  fi

  if orchard_source_dev_beam_ip_is_unspecified "$host"; then
    echo "error: ORCHARD_BEAM_NODE_NAME host must not be an unspecified or wildcard address" >&2
    return 64
  fi

  if (( peer_grant_name_mode == 1 )) && ! orchard_source_dev_beam_ip_is_rfc1918 "$host"; then
    echo "error: peer-grant BEAM node host must be a private non-loopback RFC1918 IPv4 literal" >&2
    return 64
  fi
}

orchard_source_dev_beam_is_ipv4_literal() {
  local host="$1"

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$host" <<'PY'
import ipaddress
import sys

try:
    addr = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)

raise SystemExit(0 if addr.version == 4 else 1)
PY
    return $?
  fi

  if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    local IFS='.'
    local part
    for part in $host; do
      if (( part > 255 )); then
        return 1
      fi
    done
    return 0
  fi

  return 1
}

orchard_source_dev_beam_ip_is_unspecified() {
  local host="$1"

  case "$host" in
    0.0.0.0)
      return 0
      ;;
  esac

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$host" <<'PY'
import ipaddress
import sys

try:
    addr = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)

if addr.version != 4:
    raise SystemExit(1)

raise SystemExit(0 if addr.is_unspecified else 1)
PY
    return $?
  fi

  return 1
}

orchard_source_dev_beam_ip_is_rfc1918() {
  local host="$1"
  local first second third fourth rest

  IFS='.' read -r first second third fourth rest <<< "$host"
  if [[ -z "${first:-}" || -z "${second:-}" || -z "${third:-}" || -z "${fourth:-}" || -n "${rest:-}" ]]; then
    return 1
  fi

  if [[ "$first" == "10" ]]; then
    return 0
  fi

  if [[ "$first" == "172" ]] && (( 10#$second >= 16 && 10#$second <= 31 )); then
    return 0
  fi

  if [[ "$first" == "192" && "$second" == "168" ]]; then
    return 0
  fi

  return 1
}

orchard_source_dev_beam_inet_dist_interface() {
  local host="$1"

  if command -v python3 >/dev/null 2>&1; then
    if python3 - "$host" <<'PY'
import ipaddress
import sys

addr = ipaddress.ip_address(sys.argv[1])
if addr.version != 4:
    raise SystemExit(1)

parts = [str(part) for part in addr.packed]

print("{" + ",".join(parts) + "}")
PY
    then
      return 0
    fi

    echo "error: ORCHARD_BEAM_NODE_NAME host cannot be converted to inet_dist_use_interface" >&2
    return 64
  fi

  if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    local a b c d rest
    IFS='.' read -r a b c d rest <<< "$host"
    if [[ -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" && -z "${rest:-}" ]]; then
      printf '{%s,%s,%s,%s}\n' "$a" "$b" "$c" "$d"
      return 0
    fi
  fi

  echo "error: ORCHARD_BEAM_NODE_NAME host cannot be converted to inet_dist_use_interface" >&2
  return 64
}

orchard_source_dev_beam_preflight_epmd() {
  local host="$1"
  local port="$2"

  if ! command -v epmd >/dev/null 2>&1; then
    echo "error: epmd not found on PATH; run through the pinned Erlang toolchain" >&2
    return 69
  fi

  if orchard_source_dev_beam_epmd_running "$port"; then
    orchard_source_dev_beam_verify_epmd_listener "$host" "$port"
    return $?
  fi

  if ! epmd -daemon -address "$host" -port "$port" >/dev/null 2>&1; then
    echo "error: failed to start address-constrained EPMD on $host:$port" >&2
    return 69
  fi

  orchard_source_dev_beam_verify_epmd_listener "$host" "$port"
}

orchard_source_dev_beam_epmd_running() {
  local port="$1"
  epmd -port "$port" -names >/dev/null 2>&1
}

orchard_source_dev_beam_verify_epmd_listener() {
  local host="$1"
  local port="$2"
  local listeners listener matched attempts status

  listeners=""
  attempts=0
  status=1
  while (( attempts < 20 )); do
    if listeners="$(orchard_source_dev_beam_epmd_listener_hosts "$port")"; then
      status=0
      if [[ -n "$listeners" ]]; then
        break
      fi
    else
      status=$?
    fi

    sleep 0.05
    attempts=$((attempts + 1))
  done

  if (( status != 0 )); then
    echo "error: unable to verify EPMD listener on port $port; stop any existing EPMD with ERL_EPMD_PORT=$port epmd -kill, then rerun" >&2
    return 69
  elif [[ -z "$listeners" ]]; then
    echo "error: unable to find EPMD listener on port $port after preflight" >&2
    return 69
  fi

  matched=0
  while IFS= read -r listener; do
    if orchard_source_dev_beam_listener_is_wildcard "$listener"; then
      echo "error: EPMD listener on port $port is wildcard-bound; stop it with ERL_EPMD_PORT=$port epmd -kill, then rerun" >&2
      return 69
    fi

    if [[ "$listener" == "$host" ]]; then
      matched=1
      continue
    fi

    if orchard_source_dev_beam_listener_is_loopback "$listener"; then
      continue
    fi

    echo "error: EPMD listener on port $port is not constrained to $host; stop existing EPMD with ERL_EPMD_PORT=$port epmd -kill, then rerun" >&2
    return 69
  done <<< "$listeners"

  if (( matched == 0 )); then
    echo "error: EPMD listener on port $port is not bound to $host; stop existing EPMD with ERL_EPMD_PORT=$port epmd -kill, then rerun" >&2
    return 69
  fi
}

orchard_source_dev_beam_epmd_listener_hosts() {
  local port="$1"
  local output

  if ! command -v lsof >/dev/null 2>&1; then
    return 1
  fi

  output="$(lsof -nP -a -iTCP:"$port" -sTCP:LISTEN -c epmd 2>/dev/null)" || return 1

  printf '%s\n' "$output" | awk '
    / TCP / {
      endpoint = $0
      sub(/^.* TCP /, "", endpoint)
      sub(/ .*/, "", endpoint)
      if (endpoint ~ /^\[/) {
        sub(/^\[/, "", endpoint)
        sub(/\]:[0-9]+$/, "", endpoint)
      } else {
        sub(/:[0-9]+$/, "", endpoint)
      }
      print endpoint
    }
  '
}

orchard_source_dev_beam_listener_is_wildcard() {
  case "$1" in
    ""|"*"|0.0.0.0|::)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

orchard_source_dev_beam_listener_is_loopback() {
  local listener="$1"

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$listener" <<'PY'
import ipaddress
import sys

try:
    addr = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)

raise SystemExit(0 if addr.is_loopback else 1)
PY
    return $?
  fi

  case "$listener" in
    127.*|::1|0:0:0:0:0:0:0:1)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

orchard_source_dev_beam_prepare_cookie() {
  local cookie_file="$1"
  local explicit_marker="$2"

  if [[ -n "$explicit_marker" ]]; then
    orchard_source_dev_beam_validate_cookie_file "$cookie_file" || return $?
    return 0
  fi

  if [[ ! -e "$cookie_file" ]]; then
    orchard_source_dev_beam_create_cookie_file "$cookie_file" || return $?
  fi

  orchard_source_dev_beam_validate_cookie_file "$cookie_file"
}

orchard_source_dev_beam_create_cookie_file() {
  local cookie_file="$1"
  local cookie_dir lock_dir wait_count status

  cookie_dir="$(dirname "$cookie_file")"
  mkdir -p "$cookie_dir"
  lock_dir="$cookie_file.lock"
  wait_count=0

  until mkdir "$lock_dir" 2>/dev/null; do
    if (( wait_count >= 200 )); then
      echo "error: timed out waiting for source-dev BEAM cookie lock: $lock_dir" >&2
      return 75
    fi

    sleep 0.05
    wait_count=$((wait_count + 1))
  done

  status=0
  if [[ ! -e "$cookie_file" ]]; then
    orchard_source_dev_beam_write_cookie_file "$cookie_file" || status=$?
  fi

  rmdir "$lock_dir"
  return "$status"
}

orchard_source_dev_beam_write_cookie_file() {
  local cookie_file="$1"
  local cookie_dir tmp_file cookie old_umask

  cookie_dir="$(dirname "$cookie_file")"
  cookie="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
  if [[ -z "$cookie" ]]; then
    echo "error: failed to generate source-dev BEAM cookie material" >&2
    return 70
  fi

  tmp_file="$cookie_dir/.beam.cookie.$$"
  old_umask="$(umask)"
  umask 077
  printf '%s\n' "$cookie" > "$tmp_file"
  umask "$old_umask"
  chmod 600 "$tmp_file"
  mv "$tmp_file" "$cookie_file"
}

orchard_source_dev_beam_validate_cookie_file() {
  local cookie_file="$1"

  if [[ ! -f "$cookie_file" ]]; then
    echo "error: ORCHARD_BEAM_COOKIE_FILE must point to an existing regular file" >&2
    return 64
  fi

  if [[ ! -s "$cookie_file" ]]; then
    echo "error: ORCHARD_BEAM_COOKIE_FILE must not be empty" >&2
    return 64
  fi

  if ! orchard_source_dev_beam_cookie_is_owner_only "$cookie_file"; then
    echo "error: ORCHARD_BEAM_COOKIE_FILE must be owner-only" >&2
    return 64
  fi
}

orchard_source_dev_beam_validate_owner_only_file() {
  local name="$1"
  local path="$2"

  if [[ -z "$path" || "$path" != /* || ! -f "$path" || -L "$path" ]]; then
    echo "error: $name must point to an absolute existing regular non-symlink file" >&2
    return 64
  fi

  if ! orchard_source_dev_beam_cookie_is_owner_only "$path"; then
    echo "error: $name must be owner-only" >&2
    return 64
  fi
}

orchard_source_dev_beam_cookie_is_owner_only() {
  local cookie_file="$1"
  local mode

  if mode="$(stat -c '%a' "$cookie_file" 2>/dev/null)"; then
    :
  elif mode="$(stat -f '%Lp' "$cookie_file" 2>/dev/null)"; then
    :
  else
    return 1
  fi

  [[ "$mode" =~ ^[0-7]+$ ]] || return 1
  mode="00$mode"
  [[ "${mode: -2}" == "00" ]]
}

orchard_source_dev_beam_prepare_home() {
  local role="$1"
  local repo_root="$2"
  local cookie_file="$3"
  local original_home beam_home

  original_home="${HOME:-$repo_root/tmp/dev/home}"
  export MIX_HOME="${MIX_HOME:-$original_home/.mix}"
  export HEX_HOME="${HEX_HOME:-$original_home/.hex}"

  beam_home="$repo_root/tmp/dev/beam-home/$role"
  mkdir -p "$beam_home"
  cp "$cookie_file" "$beam_home/.erlang.cookie"
  chmod 600 "$beam_home/.erlang.cookie"
  export HOME="$beam_home"
}

orchard_source_dev_beam_validate_port() {
  local name="$1"
  local value="$2"

  if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value < 1 || value > 65535 )); then
    echo "error: $name must be an integer from 1 to 65535" >&2
    return 64
  fi
}

orchard_source_dev_beam_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}
