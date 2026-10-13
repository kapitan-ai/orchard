#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$REPO_ROOT/scripts/with-disposable-dev-postgres.sh"
TMP_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'test failed: %s\n' "$1" >&2
  exit 1
}

assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "missing '$1' in $2"
}

assert_no_grep() {
  if grep -F -- "$1" "$2" >/dev/null; then
    fail "unexpected '$1' in $2"
  fi
}

make_tools() {
  local root=$1
  mkdir -p "$root/bin" "$root/state"

  cat >"$root/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state=${FAKE_DOCKER_STATE:?}
log=${FAKE_DOCKER_LOG:?}
printf '%s\n' "$*" >>"$log"

case "${1:-} ${2:-}" in
  "context inspect")
    printf 'unix:///var/run/docker.sock\n'
    ;;
  "info ")
    ;;
  "image inspect")
    printf '%s\n' "${FAKE_IMAGE_ID:-sha256:79bd7c99e923138f136f8009d6bffa66e21e9d4fda5c0c561b00fc9c90cfe537}"
    ;;
  "container inspect")
    if [[ -f "$state/running" ]]; then
      cat "$state/ownership-label"
    elif [[ -f "$state/preexisting" ]]; then
      printf 'preexisting\n'
    else
      exit 1
    fi
    ;;
  "container ls")
    if [[ " $* " == *" name="* && -f "$state/preexisting" ]]; then
      printf 'preexisting-container-id\n'
    elif [[ " $* " == *" id="* && -f "$state/running" ]]; then
      printf 'fixture-container-id\n'
    fi
    ;;
  "volume ls")
    [[ "${FAKE_VOLUME_LIST_FAIL:-0}" != "1" ]] || exit 1
    if [[ -f "$state/volumes" ]]; then
      cat "$state/volumes"
    fi
    ;;
  "run --detach")
    env_file="" cidfile="" label=""
    previous=""
    for argument in "$@"; do
      if [[ "$previous" == "--env-file" ]]; then
        env_file="$argument"
      elif [[ "$previous" == "--cidfile" ]]; then
        cidfile="$argument"
      elif [[ "$previous" == "--label" ]]; then
        label="${argument#*=}"
      fi
      previous="$argument"
    done
    [[ -n "$env_file" && -n "$cidfile" && -n "$label" ]]
    stat -c '%a' "$env_file" >"$state/init-mode"
    cut -d= -f1 "$env_file" >"$state/init-keys"
    printf '%s\n' "$label" >"$state/ownership-label"
    printf 'fixture-container-id' >"$cidfile"
    touch "$state/running"
    printf 'fixture-container-id\n'
    ;;
  "inspect --format")
    [[ -f "$state/running" ]]
    ;;
  "stop --time")
    if [[ "${FAKE_STOP_LEAVES_CONTAINER:-0}" == "1" ]]; then
      exit 0
    fi
    rm -f "$state/running"
    ;;
  *)
    if [[ "${1:-}" == "exec" ]]; then
      [[ -f "$state/running" ]]
    elif [[ "${1:-}" == "stop" ]]; then
      rm -f "$state/running"
    else
      printf 'unexpected fake docker invocation: %s\n' "$*" >&2
      exit 99
    fi
    ;;
esac
EOF

  cat >"$root/bin/ss" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${FAKE_SS_FAIL:-0}" != "1" ]] || exit 1
if [[ "${FAKE_PORT_BUSY:-0}" == "1" ]]; then
  printf 'LISTEN 0 4096 127.0.0.1:55432 0.0.0.0:*\n'
fi
EOF

  cat >"$root/bin/openssl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "rand -hex 32") printf '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n' ;;
  "rand -hex 16") printf 'fedcba9876543210fedcba9876543210\n' ;;
  *) exit 1 ;;
esac
EOF

  chmod +x "$root/bin/docker" "$root/bin/ss" "$root/bin/openssl"
}

run_helper() {
  local case_root=$1
  local output=$2
  shift 2
  env \
    PATH="$case_root/bin:/usr/bin:/bin" \
    TMPDIR="$case_root/tmp" \
    FAKE_DOCKER_STATE="$case_root/state" \
    FAKE_DOCKER_LOG="$case_root/docker.log" \
    ORCHARD_CONTAINER_ENGINE=docker \
    ORCHARD_DEV_POSTGRES_CONTAINER_NAME=orchard-linux-dev-postgres-fixture \
    ORCHARD_DEV_POSTGRES_READY_ATTEMPTS=1 \
    "$@" \
    "$HELPER" -- bash "$case_root/command.sh" >"$output" 2>&1
}

SUCCESS="$TMP_ROOT/success"
make_tools "$SUCCESS"
mkdir -p "$SUCCESS/tmp"
cat >"$SUCCESS/command.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$PGHOST" == "127.0.0.1" ]]
[[ "$PGPORT" == "55432" ]]
[[ "$PGUSER" == "postgres" ]]
[[ "$PGDATABASE" == "orchard_linux_dev" ]]
[[ "$PGPASSWORD" == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" ]]
EOF
chmod +x "$SUCCESS/command.sh"
run_helper "$SUCCESS" "$SUCCESS/out"
assert_grep '--pull=never' "$SUCCESS/docker.log"
assert_grep '--rm' "$SUCCESS/docker.log"
assert_grep '--cidfile' "$SUCCESS/docker.log"
assert_grep '--publish 127.0.0.1:55432:5432' "$SUCCESS/docker.log"
assert_grep '--tmpfs /var/lib/postgresql/data:rw,noexec,nosuid,size=1g' "$SUCCESS/docker.log"
assert_grep 'postgres:17-alpine@sha256:f02121de6f74d30d8a94cd1d9584125e2178d7e6c377d8130112d4e52d867995' "$SUCCESS/docker.log"
assert_grep '600' "$SUCCESS/state/init-mode"
assert_grep 'POSTGRES_USER' "$SUCCESS/state/init-keys"
assert_no_grep 'PGPORT' "$SUCCESS/state/init-keys"
[[ ! -e "$SUCCESS/state/running" ]] || fail "success container was not removed"
if find "$SUCCESS/tmp" -mindepth 1 -print -quit | grep -q .; then
  fail "success temporary state was not removed"
fi
assert_grep 'Cleanup verified' "$SUCCESS/out"

COMMAND_FAILURE="$TMP_ROOT/command-failure"
make_tools "$COMMAND_FAILURE"
mkdir -p "$COMMAND_FAILURE/tmp"
printf '#!/usr/bin/env bash\nexit 7\n' >"$COMMAND_FAILURE/command.sh"
chmod +x "$COMMAND_FAILURE/command.sh"
set +e
run_helper "$COMMAND_FAILURE" "$COMMAND_FAILURE/out"
status=$?
set -e
[[ "$status" -eq 7 ]] || fail "command failure status was not preserved"
[[ ! -e "$COMMAND_FAILURE/state/running" ]] || fail "failed command container was not removed"
if find "$COMMAND_FAILURE/tmp" -mindepth 1 -print -quit | grep -q .; then
  fail "failed command temporary state was not removed"
fi

PORT_COLLISION="$TMP_ROOT/port-collision"
make_tools "$PORT_COLLISION"
mkdir -p "$PORT_COLLISION/tmp"
printf '#!/usr/bin/env bash\nexit 0\n' >"$PORT_COLLISION/command.sh"
chmod +x "$PORT_COLLISION/command.sh"
set +e
run_helper "$PORT_COLLISION" "$PORT_COLLISION/out" FAKE_PORT_BUSY=1
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "occupied port was accepted"
assert_grep 'PostgreSQL port is already occupied' "$PORT_COLLISION/out"
assert_no_grep 'run --detach' "$PORT_COLLISION/docker.log"

IMAGE_DRIFT="$TMP_ROOT/image-drift"
make_tools "$IMAGE_DRIFT"
mkdir -p "$IMAGE_DRIFT/tmp"
printf '#!/usr/bin/env bash\nexit 0\n' >"$IMAGE_DRIFT/command.sh"
chmod +x "$IMAGE_DRIFT/command.sh"
set +e
run_helper "$IMAGE_DRIFT" "$IMAGE_DRIFT/out" FAKE_IMAGE_ID=sha256:wrong
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "image identity drift was accepted"
assert_grep 'image identity does not match' "$IMAGE_DRIFT/out"

CONTAINER_COLLISION="$TMP_ROOT/container-collision"
make_tools "$CONTAINER_COLLISION"
mkdir -p "$CONTAINER_COLLISION/tmp"
touch "$CONTAINER_COLLISION/state/preexisting"
printf '#!/usr/bin/env bash\nexit 0\n' >"$CONTAINER_COLLISION/command.sh"
chmod +x "$CONTAINER_COLLISION/command.sh"
set +e
run_helper "$CONTAINER_COLLISION" "$CONTAINER_COLLISION/out"
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "container collision was accepted"
assert_grep 'container name is already present' "$CONTAINER_COLLISION/out"

SS_FAILURE="$TMP_ROOT/ss-failure"
make_tools "$SS_FAILURE"
mkdir -p "$SS_FAILURE/tmp"
printf '#!/usr/bin/env bash\nexit 0\n' >"$SS_FAILURE/command.sh"
chmod +x "$SS_FAILURE/command.sh"
set +e
run_helper "$SS_FAILURE" "$SS_FAILURE/out" FAKE_SS_FAIL=1
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "listener observation failure was accepted"
assert_grep 'unable to observe PostgreSQL port before mutation' "$SS_FAILURE/out"

SIGNAL="$TMP_ROOT/signal"
make_tools "$SIGNAL"
mkdir -p "$SIGNAL/tmp"
cat >"$SIGNAL/command.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' \$\$ >"$SIGNAL/state/command-pid"
trap ':' TERM
trap 'exit 0' INT
while :; do sleep 0.1; done
EOF
chmod +x "$SIGNAL/command.sh"
env \
  PATH="$SIGNAL/bin:/usr/bin:/bin" \
  TMPDIR="$SIGNAL/tmp" \
  FAKE_DOCKER_STATE="$SIGNAL/state" \
  FAKE_DOCKER_LOG="$SIGNAL/docker.log" \
  ORCHARD_CONTAINER_ENGINE=docker \
  ORCHARD_DEV_POSTGRES_CONTAINER_NAME=orchard-linux-dev-postgres-fixture \
  ORCHARD_DEV_POSTGRES_READY_ATTEMPTS=1 \
  "$HELPER" -- bash "$SIGNAL/command.sh" >"$SIGNAL/out" 2>&1 &
wrapper_pid=$!
for _attempt in {1..50}; do
  [[ -f "$SIGNAL/state/command-pid" ]] && break
  sleep 0.1
done
[[ -f "$SIGNAL/state/command-pid" ]] || fail "signal fixture command did not start"
command_pid="$(cat "$SIGNAL/state/command-pid")"
kill -TERM "$wrapper_pid"
set +e
wait "$wrapper_pid"
status=$?
set -e
[[ "$status" -eq 143 ]] || fail "wrapper TERM status was not preserved"
kill -0 "$command_pid" 2>/dev/null && fail "signaled command survived wrapper cleanup"
[[ ! -e "$SIGNAL/state/running" ]] || fail "signal container was not removed"
if find "$SIGNAL/tmp" -mindepth 1 -print -quit | grep -q .; then
  fail "signal temporary state was not removed"
fi

STDIN="$TMP_ROOT/stdin"
make_tools "$STDIN"
mkdir -p "$STDIN/tmp"
cat >"$STDIN/command.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
read -r value
printf '%s\n' "\$value" >"$STDIN/state/stdin-value"
EOF
chmod +x "$STDIN/command.sh"
printf 'foreground-input\n' | env \
  PATH="$STDIN/bin:/usr/bin:/bin" \
  TMPDIR="$STDIN/tmp" \
  FAKE_DOCKER_STATE="$STDIN/state" \
  FAKE_DOCKER_LOG="$STDIN/docker.log" \
  ORCHARD_CONTAINER_ENGINE=docker \
  ORCHARD_DEV_POSTGRES_CONTAINER_NAME=orchard-linux-dev-postgres-fixture \
  ORCHARD_DEV_POSTGRES_READY_ATTEMPTS=1 \
  "$HELPER" -- bash "$STDIN/command.sh" >"$STDIN/out" 2>&1
assert_grep 'foreground-input' "$STDIN/state/stdin-value"

CLEANUP_RESIDUE="$TMP_ROOT/cleanup-residue"
make_tools "$CLEANUP_RESIDUE"
mkdir -p "$CLEANUP_RESIDUE/tmp"
printf '#!/usr/bin/env bash\nexit 0\n' >"$CLEANUP_RESIDUE/command.sh"
chmod +x "$CLEANUP_RESIDUE/command.sh"
set +e
run_helper "$CLEANUP_RESIDUE" "$CLEANUP_RESIDUE/out" FAKE_STOP_LEAVES_CONTAINER=1
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "container cleanup residue was accepted"
assert_grep 'owned disposable PostgreSQL container remains' "$CLEANUP_RESIDUE/out"

printf 'disposable source-development PostgreSQL wrapper tests passed\n'
