#!/usr/bin/env bash
set -euo pipefail

readonly POSTGRES_IMAGE="postgres:17-alpine@sha256:f02121de6f74d30d8a94cd1d9584125e2178d7e6c377d8130112d4e52d867995"
readonly POSTGRES_IMAGE_ID="sha256:79bd7c99e923138f136f8009d6bffa66e21e9d4fda5c0c561b00fc9c90cfe537"

container_engine="${ORCHARD_CONTAINER_ENGINE:-docker}"
port="${ORCHARD_DEV_POSTGRES_PORT:-55432}"
database="${ORCHARD_DEV_POSTGRES_DATABASE:-orchard_linux_dev}"
container_name="${ORCHARD_DEV_POSTGRES_CONTAINER_NAME:-orchard-linux-dev-postgres-${UID}}"
ready_attempts="${ORCHARD_DEV_POSTGRES_READY_ATTEMPTS:-60}"
temp_root=""
cidfile=""
owned_container_id=""
ownership_label=""
child_pid=""
requested_status=""

usage() {
  cat >&2 <<'EOF'
usage: scripts/with-disposable-dev-postgres.sh [--port PORT] [--database NAME] -- COMMAND [ARG...]

Runs COMMAND with client PG* variables for a disposable, loopback-only
PostgreSQL 17 container. The accepted image must already be cached locally.
EOF
}

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

port_state() {
  local output
  if ! output="$(ss -H -ltn "sport = :$port" 2>/dev/null)"; then
    printf 'unknown\n'
  elif [[ -n "$output" ]]; then
    printf 'present\n'
  else
    printf 'absent\n'
  fi
}

container_id_by_name() {
  "$container_engine" container ls --all --no-trunc \
    --filter "name=^/${container_name}$" --format '{{.ID}}'
}

container_id_is_present() {
  local container_id=$1 output
  output="$($container_engine container ls --all --no-trunc \
    --filter "id=$container_id" --format '{{.ID}}')" || return 2
  [[ "$output" == "$container_id" ]]
}

capture_owned_container_id() {
  if [[ -z "$owned_container_id" && -n "$cidfile" && -s "$cidfile" ]]; then
    owned_container_id="$(cat -- "$cidfile")" || return 1
  fi
  if [[ -z "$owned_container_id" && -n "$ownership_label" ]]; then
    owned_container_id="$("$container_engine" container ls --all --no-trunc \
      --filter "label=com.orchard.source-dev.disposable-postgresql=$ownership_label" \
      --format '{{.ID}}')" || return 1
  fi
}

signal_process_tree() {
  local signal=$1 parent=$2 child

  while read -r child; do
    [[ -n "$child" ]] || continue
    signal_process_tree "$signal" "$child"
  done < <(ps -o pid= --ppid "$parent" 2>/dev/null)
  kill -s "$signal" "$parent" 2>/dev/null || true
}

request_stop() {
  local signal=$1 status=$2
  requested_status="$status"
  if [[ -n "$child_pid" ]]; then
    signal_process_tree "$signal" "$child_pid"
  fi
}

process_is_running() {
  local process_id=$1 state
  state="$(ps -o stat= -p "$process_id" 2>/dev/null | tr -d '[:space:]')"
  [[ -n "$state" && "$state" != Z* ]]
}

terminate_owned_command() {
  local attempt

  [[ -n "$child_pid" ]] || return 0
  if process_is_running "$child_pid"; then
    signal_process_tree TERM "$child_pid"
    for attempt in {1..50}; do
      process_is_running "$child_pid" || break
      sleep 0.1
    done
    if process_is_running "$child_pid"; then
      signal_process_tree KILL "$child_pid"
    fi
  fi
  wait "$child_pid" 2>/dev/null || true
}

cleanup() {
  local failed=0 attempt state label post_volumes

  if ! capture_owned_container_id; then
    printf 'error: unable to recover disposable PostgreSQL ownership\n' >&2
    failed=1
  fi

  terminate_owned_command
  child_pid=""

  if [[ -n "$owned_container_id" ]]; then
    if label="$($container_engine container inspect \
      --format '{{index .Config.Labels "com.orchard.source-dev.disposable-postgresql"}}' \
      "$owned_container_id" 2>/dev/null)"; then
      if [[ "$label" != "$ownership_label" ]]; then
        printf 'error: refusing to stop container whose ownership label changed\n' >&2
        failed=1
      elif ! "$container_engine" stop --time 10 "$owned_container_id" >/dev/null; then
        printf 'error: failed to stop owned disposable PostgreSQL container\n' >&2
        failed=1
      fi
    else
      state=0
      container_id_is_present "$owned_container_id" || state=$?
      if [[ "$state" -eq 0 ]]; then
        printf 'error: unable to verify owned disposable PostgreSQL container\n' >&2
        failed=1
      elif [[ "$state" -eq 2 ]]; then
        printf 'error: unable to observe disposable PostgreSQL containers\n' >&2
        failed=1
      fi
    fi
  fi

  if [[ -n "$owned_container_id" ]]; then
    for attempt in {1..50}; do
      state=0
      container_id_is_present "$owned_container_id" || state=$?
      [[ "$state" -eq 1 ]] && break
      [[ "$state" -eq 2 ]] && break
      sleep 0.1
    done
    if [[ "$state" -eq 0 ]]; then
      printf 'error: owned disposable PostgreSQL container remains\n' >&2
      failed=1
    elif [[ "$state" -eq 2 ]]; then
      printf 'error: unable to prove disposable PostgreSQL container absence\n' >&2
      failed=1
    fi
  fi

  for attempt in {1..50}; do
    state="$(port_state)"
    [[ "$state" != "present" ]] && break
    sleep 0.1
  done
  if [[ "$state" == "present" ]]; then
    printf 'error: loopback PostgreSQL port remains occupied after cleanup: %s\n' "$port" >&2
    failed=1
  elif [[ "$state" == "unknown" ]]; then
    printf 'error: unable to prove loopback PostgreSQL port is clear\n' >&2
    failed=1
  fi

  if [[ -n "$temp_root" && -f "$temp_root/pre-volumes.txt" ]]; then
    if post_volumes="$($container_engine volume ls --quiet)"; then
      if [[ "$post_volumes" != "$(cat "$temp_root/pre-volumes.txt")" ]]; then
        printf 'error: container volume inventory changed during disposable PostgreSQL run\n' >&2
        failed=1
      fi
    else
      printf 'error: unable to prove container volume inventory is unchanged\n' >&2
      failed=1
    fi
  fi

  if [[ -n "$temp_root" ]]; then
    rm -rf -- "$temp_root"
    if [[ -e "$temp_root" ]]; then
      printf 'error: disposable PostgreSQL temporary state remains\n' >&2
      failed=1
    fi
  fi

  if [[ "$failed" -eq 0 ]]; then
    printf '==> Cleanup verified: port %s clear; container, volume, and temporary state absent\n' "$port"
  fi

  return "$failed"
}

finish() {
  local status=$?
  trap - EXIT
  trap ':' INT TERM
  if ! cleanup; then
    status=1
  fi
  if [[ -n "$requested_status" && "$status" -eq 0 ]]; then
    status="$requested_status"
  fi
  exit "$status"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --port)
      [[ "$#" -ge 2 ]] || { usage; exit 64; }
      port="$2"
      shift 2
      ;;
    --database)
      [[ "$#" -ge 2 ]] || { usage; exit 64; }
      database="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

[[ "$#" -gt 0 ]] || { usage; exit 64; }
[[ "$port" =~ ^[0-9]+$ ]] || fail "PostgreSQL port must be an integer"
((port >= 1024 && port <= 65535)) || fail "PostgreSQL port must be between 1024 and 65535"
[[ "$database" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || fail "invalid PostgreSQL database name"
[[ "$container_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]+$ ]] || fail "invalid container name"
[[ "$ready_attempts" =~ ^[1-9][0-9]*$ ]] || fail "readiness attempts must be a positive integer"

command -v "$container_engine" >/dev/null || fail "container engine not found: $container_engine"
command -v ss >/dev/null || fail "ss is required for listener collision checks"
command -v openssl >/dev/null || fail "openssl is required for ephemeral password generation"
command -v ps >/dev/null || fail "ps is required for foreground command cleanup"

engine_host="$("$container_engine" context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null)" ||
  fail "unable to inspect the container engine endpoint"
[[ "$engine_host" == unix://* ]] || fail "container engine must use a local Unix socket"
"$container_engine" info >/dev/null 2>&1 || fail "unable to query the local container engine"

actual_image_id="$("$container_engine" image inspect --format '{{.Id}}' "$POSTGRES_IMAGE" 2>/dev/null)" ||
  fail "accepted PostgreSQL image is not cached; refusing to pull"
[[ "$actual_image_id" == "$POSTGRES_IMAGE_ID" ]] ||
  fail "cached PostgreSQL image identity does not match the accepted image"

case "$(port_state)" in
  present) fail "PostgreSQL port is already occupied: $port" ;;
  unknown) fail "unable to observe PostgreSQL port before mutation" ;;
esac
existing_container_id="$(container_id_by_name)" || fail "unable to inspect container-name pre-state"
[[ -z "$existing_container_id" ]] ||
  fail "disposable PostgreSQL container name is already present: $container_name"

trap finish EXIT
trap 'request_stop INT 130' INT
trap 'request_stop TERM 143' TERM
temp_root="$(mktemp -d "${TMPDIR:-/tmp}/orchard-linux-dev-postgres.XXXXXX")"
chmod 0700 "$temp_root"
init_env="$temp_root/container-init.env"
client_env="$temp_root/orchard-client.env"
pre_state="$temp_root/pre-state.txt"
cidfile="$temp_root/container.cid"
password="$(openssl rand -hex 32)"
ownership_label="$(openssl rand -hex 16)"

umask 077
cat >"$init_env" <<EOF
POSTGRES_USER=postgres
POSTGRES_DB=postgres
POSTGRES_PASSWORD=$password
EOF
cat >"$client_env" <<EOF
PGHOST=127.0.0.1
PGPORT=$port
PGUSER=postgres
PGPASSWORD=$password
PGDATABASE=$database
EOF
chmod 0600 "$init_env" "$client_env"
"$container_engine" volume ls --quiet >"$temp_root/pre-volumes.txt" ||
  fail "unable to capture container volume pre-state"
chmod 0600 "$temp_root/pre-volumes.txt"

{
  printf 'source_commit=%s\n' "$(git rev-parse HEAD 2>/dev/null || printf unknown)"
  printf 'source_tree=%s\n' "$(git rev-parse HEAD^{tree} 2>/dev/null || printf unknown)"
  printf 'source_dirty=%s\n' "$(if git diff --quiet --ignore-submodules HEAD 2>/dev/null; then printf false; else printf true; fi)"
  printf 'image=%s\n' "$POSTGRES_IMAGE"
  printf 'image_id=%s\n' "$actual_image_id"
  printf 'listen=127.0.0.1:%s\n' "$port"
  printf 'container=%s\n' "$container_name"
} >"$pre_state"
chmod 0600 "$pre_state"

printf '==> Starting disposable PostgreSQL: %s (%s) on 127.0.0.1:%s\n' \
  "$POSTGRES_IMAGE" "$actual_image_id" "$port"

"$container_engine" run --detach --pull=never --rm \
  --name "$container_name" \
  --cidfile "$cidfile" \
  --label "com.orchard.source-dev.disposable-postgresql=$ownership_label" \
  --env-file "$init_env" \
  --tmpfs /var/lib/postgresql/data:rw,noexec,nosuid,size=1g \
  --publish "127.0.0.1:${port}:5432" \
  "$POSTGRES_IMAGE" >/dev/null
capture_owned_container_id
[[ -n "$owned_container_id" ]] || fail "container engine did not record the owned container ID"
[[ -z "$requested_status" ]] || exit "$requested_status"
observed_label="$($container_engine container inspect \
  --format '{{index .Config.Labels "com.orchard.source-dev.disposable-postgresql"}}' \
  "$owned_container_id")" || fail "unable to verify disposable PostgreSQL ownership"
[[ "$observed_label" == "$ownership_label" ]] || fail "disposable PostgreSQL ownership mismatch"

volume_mounts="$($container_engine inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{println .Name}}{{end}}{{end}}' "$owned_container_id")"
[[ -z "$volume_mounts" ]] || fail "disposable PostgreSQL unexpectedly created a Docker volume"

ready=0
for ((attempt = 1; attempt <= ready_attempts; attempt++)); do
  if "$container_engine" exec "$owned_container_id" \
    pg_isready --host=127.0.0.1 --port=5432 --username=postgres --dbname=postgres \
    >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.5
done
[[ "$ready" -eq 1 ]] || fail "disposable PostgreSQL did not become ready"

[[ -z "$requested_status" ]] || exit "$requested_status"

set -a
# shellcheck disable=SC1090 # Generated owner-only file containing controlled values.
source "$client_env"
set +a

printf '==> PostgreSQL ready; running command with database %s\n' "$database"
env --default-signal=INT,QUIT -- "$@" <&0 &
child_pid=$!
if [[ -n "$requested_status" ]]; then
  terminate_owned_command
  child_pid=""
  exit "$requested_status"
fi
set +e
wait "$child_pid"
command_status=$?
set -e
if [[ -n "$requested_status" ]]; then
  terminate_owned_command
  child_pid=""
  exit "$requested_status"
fi
child_pid=""
exit "$command_status"
