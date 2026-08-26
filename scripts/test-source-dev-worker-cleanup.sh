#!/usr/bin/env bash
# Focused tests for the source-dev worker cleanup helper.
#
# Verifies that the helper kills only workers whose socket path lives in this
# checkout's source-dev socket directory, skips ambiguous workers, and leaves
# foreign / out-of-tree workers alone.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$REPO_ROOT/bin/lib/source-dev-worker-cleanup.sh"
TMP_ROOT="$(mktemp -d)"

owned_pid=""
foreign_pid=""
other_pid=""
ambiguous_pid=""
wrapper_pid=""
traversal_pid=""
duplicate_pid=""
resistant_pid=""
race_pid=""
override_pid=""
long_argv_pid=""
path_pid=""
unrelated_arg_pid=""
relative_socket_dir=""
baseline_pid=""
default_effective_pid=""

cleanup() {
  local pid
  local socket_path
  local active_jobs

  active_jobs=" $(jobs -pr | tr '\n' ' ') "

  for pid in \
    "$owned_pid" \
    "$foreign_pid" \
    "$other_pid" \
    "$ambiguous_pid" \
    "$wrapper_pid" \
    "$traversal_pid" \
    "$duplicate_pid" \
    "$resistant_pid" \
    "$race_pid" \
    "$override_pid" \
    "$long_argv_pid" \
    "$path_pid" \
    "$unrelated_arg_pid" \
    "$baseline_pid" \
    "$default_effective_pid"; do
    [[ -n "$pid" ]] || continue
    [[ "$active_jobs" == *" $pid "* ]] || continue
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done

  for socket_path in \
    "${socket_owned:-}" \
    "${socket_other:-}" \
    "${socket_wrapper:-}" \
    "${socket_duplicate_owned:-}" \
    "${socket_resistant:-}" \
    "${socket_race:-}" \
    "${socket_long_argv:-}" \
    "${socket_path_resolved:-}" \
    "${socket_traversal:-}" \
    "${socket_baseline:-}" \
    "${socket_default_effective:-}"; do
    [[ -n "$socket_path" ]] || continue
    rm -f -- "$socket_path"
  done

  if [[ -n "$relative_socket_dir" ]]; then
    rm -rf -- "$REPO_ROOT/$relative_socket_dir"
  fi

  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

process_is_running() {
  local pid="$1"
  local state

  state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  [[ -n "$state" && "$state" != Z* ]]
}

# shellcheck source=../bin/lib/source-dev-worker-cleanup.sh
source "$HELPER"

SOCKET_DIR="$(orchard_source_dev_worker_socket_dir "$REPO_ROOT")"
FOREIGN_SOCKET_DIR="$TMP_ROOT/foreign-ws"
mkdir -p "$SOCKET_DIR" "$FOREIGN_SOCKET_DIR"

# A fake orchard-worker-mlx process that idles until SIGTERM. We use a wrapper
# script so the command line contains the substring "orchard-worker-mlx" and a
# --socket-path argument.
FAKE_WORKER="$TMP_ROOT/orchard-worker-mlx"
cat > "$FAKE_WORKER" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
socket_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --socket-path)
      socket_path="$2"
      shift 2
      ;;
    --socket-path=*)
      socket_path="${1#*=}"
      shift
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "$socket_path" ]] || exit 1
# Touch the socket file so the cleanup helper sees an owned socket path.
mkdir -p "$(dirname "$socket_path")"
touch "$socket_path"
# Stay alive with the original argv intact: exec would replace the command
# line, hiding this process from pgrep -f matching. Exit promptly on TERM.
trap 'exit 0' TERM
while :; do sleep 0.2; done
SCRIPT
chmod +x "$FAKE_WORKER"

FAKE_OTHER="$TMP_ROOT/orchard-worker-mlx-other"
cp "$FAKE_WORKER" "$FAKE_OTHER"
chmod +x "$FAKE_OTHER"

FAKE_UNRELATED="$TMP_ROOT/unrelated-command"
cp "$FAKE_WORKER" "$FAKE_UNRELATED"
chmod +x "$FAKE_UNRELATED"

FAKE_AMBIGUOUS="$TMP_ROOT/orchard-worker-mlx-ambiguous"
cat > "$FAKE_AMBIGUOUS" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
trap 'exit 0' TERM
while :; do sleep 0.2; done
SCRIPT
chmod +x "$FAKE_AMBIGUOUS"

FAKE_SOURCE_PACKAGE="$TMP_ROOT/native/orchard_worker_mlx"
FAKE_WRAPPER="$FAKE_SOURCE_PACKAGE/bin/orchard-worker-mlx"
FAKE_VENV_ENTRY="$FAKE_SOURCE_PACKAGE/.venv/bin/orchard-worker-mlx"
mkdir -p "$(dirname "$FAKE_WRAPPER")" "$(dirname "$FAKE_VENV_ENTRY")"
cp "$FAKE_WORKER" "$FAKE_VENV_ENTRY"
cat > "$FAKE_WRAPPER" <<SCRIPT
#!/usr/bin/env bash
exec "$FAKE_VENV_ENTRY" "\$@"
SCRIPT
chmod +x "$FAKE_WRAPPER" "$FAKE_VENV_ENTRY"

FAKE_RESISTANT="$TMP_ROOT/orchard-worker-mlx-resistant"
cat > "$FAKE_RESISTANT" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
socket_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --socket-path)
      socket_path="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "$socket_path" ]] || exit 1
mkdir -p "$(dirname "$socket_path")"
touch "$socket_path"
trap ':' TERM
while :; do read -r -t 1 _ || true; done
SCRIPT
chmod +x "$FAKE_RESISTANT"

socket_owned="$SOCKET_DIR/owned-$$.sock"
socket_foreign="$FOREIGN_SOCKET_DIR/foreign.sock"
socket_other="$SOCKET_DIR/other-$$.sock"
socket_wrapper="$SOCKET_DIR/wrapper-$$.sock"
socket_traversal="$SOCKET_DIR/../../foreign-traversal-$$.sock"
socket_duplicate_owned="$SOCKET_DIR/duplicate-owned-$$.sock"
socket_duplicate_foreign="$FOREIGN_SOCKET_DIR/duplicate-foreign.sock"
socket_resistant="$SOCKET_DIR/resistant-$$.sock"
socket_race="$SOCKET_DIR/race-$$.sock"
socket_long_argv="$SOCKET_DIR/long-argv-$$.sock"

# Start a worker that belongs to this checkout and one that belongs elsewhere.
# Note: capturing the pid via command substitution ($(cmd & echo $!)) would
# hang — the background child inherits the substitution's stdout pipe and the
# read blocks until the child exits.
bash "$FAKE_WORKER" --socket-path "$socket_owned" &
owned_pid=$!
bash "$FAKE_WORKER" --socket-path "$socket_foreign" &
foreign_pid=$!
bash "$FAKE_OTHER" --socket-path "$socket_other" &
other_pid=$!
bash "$FAKE_AMBIGUOUS" &
ambiguous_pid=$!
bash "$FAKE_VENV_ENTRY" --socket-path "$socket_wrapper" &
wrapper_pid=$!
bash "$FAKE_WORKER" --socket-path "$socket_traversal" &
traversal_pid=$!
bash "$FAKE_WORKER" \
  --socket-path "$socket_duplicate_owned" \
  --socket-path "$socket_duplicate_foreign" &
duplicate_pid=$!

# Give the background jobs a moment to establish their command lines.
sleep 0.2

# Verify both are alive before cleanup.
kill -0 "$owned_pid" 2>/dev/null || fail "owned worker was not running before cleanup"
kill -0 "$foreign_pid" 2>/dev/null || fail "foreign worker was not running before cleanup"
kill -0 "$other_pid" 2>/dev/null || fail "different-executable worker was not running before cleanup"
kill -0 "$ambiguous_pid" 2>/dev/null || fail "ambiguous worker was not running before cleanup"
kill -0 "$wrapper_pid" 2>/dev/null || fail "exec-wrapped worker was not running before cleanup"
kill -0 "$traversal_pid" 2>/dev/null || fail "traversal worker was not running before cleanup"
kill -0 "$duplicate_pid" 2>/dev/null || fail "duplicate-socket worker was not running before cleanup"

# Confirm the cleanup enumeration exposes the full argv for a known worker.
enumeration_output="$(orchard_source_dev_worker_processes)"
[[ "$enumeration_output" == *"$owned_pid"* ]] || fail "worker enumeration omitted the known pid"
[[ "$enumeration_output" == *"$FAKE_WORKER"* ]] ||
  fail "worker enumeration omitted the known executable path"
[[ "$enumeration_output" == *"--socket-path $socket_owned"* ]] ||
  fail "worker enumeration omitted the known socket argument"

# Run the cleanup helper.
cleanup_output="$(orchard_source_dev_cleanup_workers "$REPO_ROOT" "$FAKE_WORKER" 2>&1)"
printf '%s\n' "$cleanup_output"
[[ "$cleanup_output" == *"warning: skipping orchard-worker-mlx process(es) without a parseable --socket-path"* ]] ||
  fail "ambiguous worker warning was not emitted"
[[ "$cleanup_output" == *"$ambiguous_pid"* ]] ||
  fail "ambiguous worker warning did not name its pid"
[[ "$cleanup_output" == *"warning: skipping in-scope orchard-worker-mlx process(es) with a different executable"* ]] ||
  fail "different-executable worker warning was not emitted"
[[ "$cleanup_output" == *"$other_pid"* ]] ||
  fail "different-executable worker warning did not name its pid"
[[ "$cleanup_output" != *"$foreign_pid"* ]] ||
  fail "out-of-scope worker was incorrectly reported"

# Reap the owned worker first: it is a child of this shell, so until wait(2)
# collects it the zombie still answers kill -0.
wait "$owned_pid" 2>/dev/null || true
owned_pid=""

# The owned worker should be gone.
if kill -0 "$owned_pid" 2>/dev/null; then
  fail "owned source-dev worker survived cleanup"
fi

process_is_running "$wrapper_pid" || fail "exec-wrapped worker was killed for a different executable"
orchard_source_dev_cleanup_workers \
  "$REPO_ROOT" \
  "$FAKE_WRAPPER" \
  "$FAKE_VENV_ENTRY" >/dev/null 2>&1

if process_is_running "$wrapper_pid"; then
  fail "exec-wrapped source-dev worker survived cleanup"
fi
wait "$wrapper_pid" 2>/dev/null || true
wrapper_pid=""

# The foreign worker should still be alive.
if ! kill -0 "$foreign_pid" 2>/dev/null; then
  fail "foreign worker was incorrectly killed by cleanup"
fi

if ! kill -0 "$other_pid" 2>/dev/null; then
  fail "different-executable worker was incorrectly killed by cleanup"
fi

# The ambiguous worker should still be alive and the helper should have
# returned success despite not being able to establish ownership.
if ! kill -0 "$ambiguous_pid" 2>/dev/null; then
  fail "ambiguous worker was incorrectly killed by cleanup"
fi

if ! process_is_running "$traversal_pid"; then
  fail "path-traversal worker was incorrectly killed by cleanup"
fi

if ! process_is_running "$duplicate_pid"; then
  fail "duplicate-socket worker was incorrectly killed by cleanup"
fi

# Carrying the expected executable as an unrelated argument must not establish
# ownership. Only argv0, or argv1 after a recognized interpreter, is valid.
bash "$FAKE_UNRELATED" "$FAKE_WORKER" --socket-path "$socket_other" &
unrelated_arg_pid=$!
sleep 0.2
unrelated_enumeration="$(orchard_source_dev_worker_processes)"
[[ "$unrelated_enumeration" != *"$unrelated_arg_pid "* ]] ||
  fail "worker enumeration matched an unrelated executable argument"
orchard_source_dev_cleanup_workers "$REPO_ROOT" "$FAKE_WORKER" >/dev/null 2>&1
process_is_running "$unrelated_arg_pid" || fail "unrelated executable argument established ownership"
kill -TERM "$unrelated_arg_pid" 2>/dev/null || true
wait "$unrelated_arg_pid" 2>/dev/null || true
unrelated_arg_pid=""

bash "$FAKE_RESISTANT" --socket-path "$socket_resistant" &
resistant_pid=$!
sleep 0.2

resistant_cleanup_output="$(
  orchard_source_dev_cleanup_workers "$REPO_ROOT" "$FAKE_RESISTANT" 2>&1
)" || fail "cleanup failed while a confirmed owned worker survived SIGTERM"
[[ "$resistant_cleanup_output" == *"warning: source-dev MLX workers still alive after SIGTERM"* ]] ||
  fail "cleanup did not warn about the confirmed owned worker that survived SIGTERM"

kill -0 "$resistant_pid" 2>/dev/null || fail "TERM-resistant fixture exited unexpectedly"

# Clean up the foreign and ambiguous workers.
kill -TERM "$foreign_pid" 2>/dev/null || true
wait "$foreign_pid" 2>/dev/null || true
foreign_pid=""
kill -TERM "$other_pid" 2>/dev/null || true
wait "$other_pid" 2>/dev/null || true
other_pid=""
kill -TERM "$ambiguous_pid" 2>/dev/null || true
wait "$ambiguous_pid" 2>/dev/null || true
ambiguous_pid=""
kill -TERM "$traversal_pid" 2>/dev/null || true
wait "$traversal_pid" 2>/dev/null || true
traversal_pid=""
kill -TERM "$duplicate_pid" 2>/dev/null || true
wait "$duplicate_pid" 2>/dev/null || true
duplicate_pid=""
kill -KILL "$resistant_pid" 2>/dev/null || true
wait "$resistant_pid" 2>/dev/null || true
resistant_pid=""

override_socket_dir="$TMP_ROOT/override-ws"
mkdir -p "$override_socket_dir"
bash "$FAKE_WORKER" --socket-path "$override_socket_dir/owned.sock" &
override_pid=$!
sleep 0.2
ORCHARD_WORKER_SOCKET_DIR="$override_socket_dir/" \
  orchard_source_dev_cleanup_workers "$REPO_ROOT" "$FAKE_WORKER" >/dev/null 2>&1
wait "$override_pid" 2>/dev/null || true
override_pid=""
process_is_running "$override_pid" && fail "trailing-slash socket override missed an owned worker"

relative_socket_dir="tmp/source-dev-worker-cleanup-$$"
export ORCHARD_WORKER_SOCKET_DIR="$relative_socket_dir"
export ORCHARD_WORKER_EXECUTABLE="$FAKE_WORKER"
export ORCHARD_WORKER_EFFECTIVE_EXECUTABLE="$FAKE_WORKER"
orchard_source_dev_configure_worker_runtime "$REPO_ROOT"
[[ "$ORCHARD_WORKER_SOCKET_DIR" == "$REPO_ROOT/$relative_socket_dir" ]] ||
  fail "relative socket override was not normalized from the repo root"

export ORCHARD_WORKER_SOCKET_DIR=""
orchard_source_dev_configure_worker_runtime "$REPO_ROOT"
canonical_default_socket_dir="$(orchard_source_dev_canonical_directory "$SOCKET_DIR")"
[[ "$ORCHARD_WORKER_SOCKET_DIR" == "$canonical_default_socket_dir" ]] ||
  fail "empty socket override did not select the hashed default"

hashless_startup_log="$TMP_ROOT/hashless-startup.log"
if ! bash -c '
  set -euo pipefail
  source "$1"
  orchard_source_dev_worker_socket_hash() { return 69; }
  unset ORCHARD_WORKER_SOCKET_DIR
  export ORCHARD_WORKER_EXECUTABLE="$3"
  export ORCHARD_WORKER_EFFECTIVE_EXECUTABLE="$3"
  orchard_source_dev_configure_worker_runtime "$2"
  orchard_source_dev_cleanup_workers \
    "$2" \
    "$ORCHARD_WORKER_EXECUTABLE" \
    "$ORCHARD_WORKER_EFFECTIVE_EXECUTABLE"
  printf "startup-continued\n"
' bash "$HELPER" "$REPO_ROOT" "$FAKE_WORKER" >"$hashless_startup_log" 2>&1; then
  fail "source-dev startup aborted when socket hashing was unavailable"
fi
hashless_startup_output="$(cat "$hashless_startup_log")"
[[ "$hashless_startup_output" == *"cannot resolve the source-dev worker socket directory; skipping cleanup"* ]] ||
  fail "hashless source-dev startup did not explain that cleanup was skipped"
[[ "$hashless_startup_output" == *"startup-continued"* ]] ||
  fail "hashless source-dev startup did not continue after cleanup was skipped"

if ORCHARD_WORKER_SOCKET_DIR="$TMP_ROOT/socket dir" \
  ORCHARD_WORKER_EXECUTABLE="$FAKE_WORKER" \
  orchard_source_dev_configure_worker_runtime "$REPO_ROOT" >/dev/null 2>&1; then
  fail "whitespace socket override was accepted"
fi

if ORCHARD_WORKER_SOCKET_DIR="$SOCKET_DIR" \
  ORCHARD_WORKER_EXECUTABLE="$TMP_ROOT/missing-worker" \
  orchard_source_dev_configure_worker_runtime "$REPO_ROOT" >/dev/null 2>&1; then
  fail "missing explicit worker executable was accepted"
fi

NONEXEC_WORKER="$TMP_ROOT/non-executable-worker"
: > "$NONEXEC_WORKER"
chmod 600 "$NONEXEC_WORKER"
if ORCHARD_WORKER_SOCKET_DIR="$SOCKET_DIR" \
  ORCHARD_WORKER_EXECUTABLE="$NONEXEC_WORKER" \
  orchard_source_dev_configure_worker_runtime "$REPO_ROOT" >/dev/null 2>&1; then
  fail "non-executable explicit worker executable was accepted"
fi

if ORCHARD_WORKER_SOCKET_DIR="$SOCKET_DIR" \
  ORCHARD_WORKER_EXECUTABLE="$FAKE_WORKER" \
  ORCHARD_WORKER_EFFECTIVE_EXECUTABLE="$TMP_ROOT/missing-effective-worker" \
  orchard_source_dev_configure_worker_runtime "$REPO_ROOT" >/dev/null 2>&1; then
  fail "missing explicit effective worker executable was accepted"
fi

DEFAULT_REPO="$TMP_ROOT/default-repo"
DEFAULT_WRAPPER="$DEFAULT_REPO/native/orchard_worker_mlx/bin/orchard-worker-mlx"
DEFAULT_EFFECTIVE="$DEFAULT_REPO/native/orchard_worker_mlx/.venv/bin/orchard-worker-mlx"
mkdir -p "$(dirname "$DEFAULT_WRAPPER")" "$(dirname "$DEFAULT_EFFECTIVE")"
cp "$FAKE_WORKER" "$DEFAULT_WRAPPER"
cp "$FAKE_WORKER" "$DEFAULT_EFFECTIVE"
chmod +x "$DEFAULT_WRAPPER" "$DEFAULT_EFFECTIVE"
default_socket_dir="$TMP_ROOT/default-ws"
mkdir -p "$default_socket_dir"
socket_default_effective="$default_socket_dir/non-executable-effective.sock"
bash "$DEFAULT_EFFECTIVE" --socket-path "$socket_default_effective" &
default_effective_pid=$!
sleep 0.2
chmod 600 "$DEFAULT_EFFECTIVE"
unset ORCHARD_WORKER_EXECUTABLE ORCHARD_WORKER_EFFECTIVE_EXECUTABLE
export ORCHARD_WORKER_SOCKET_DIR="$default_socket_dir"
orchard_source_dev_configure_worker_runtime "$DEFAULT_REPO"
canonical_default_effective="$(orchard_source_dev_canonical_existing_path "$DEFAULT_EFFECTIVE")"
[[ "$ORCHARD_WORKER_EFFECTIVE_EXECUTABLE" == "$canonical_default_effective" ]] ||
  fail "existing default effective worker lost its cleanup identity after an execute-bit change"
orchard_source_dev_cleanup_workers \
  "$DEFAULT_REPO" \
  "$ORCHARD_WORKER_EXECUTABLE" \
  "$ORCHARD_WORKER_EFFECTIVE_EXECUTABLE" >/dev/null 2>&1
wait "$default_effective_pid" 2>/dev/null || true
default_effective_pid=""

original_path="$PATH"
export PATH="$TMP_ROOT:$PATH"
export ORCHARD_WORKER_SOCKET_DIR="$SOCKET_DIR"
export ORCHARD_WORKER_EXECUTABLE="orchard-worker-mlx"
export ORCHARD_WORKER_EFFECTIVE_EXECUTABLE=""
orchard_source_dev_configure_worker_runtime "$REPO_ROOT"
export PATH="$original_path"
canonical_fake_worker="$(orchard_source_dev_canonical_existing_path "$FAKE_WORKER")"
[[ "$ORCHARD_WORKER_EXECUTABLE" == "$canonical_fake_worker" ]] ||
  fail "bare worker executable was not resolved through PATH"
socket_path_resolved="$SOCKET_DIR/path-resolved-$$.sock"
bash "$FAKE_WORKER" --socket-path "$socket_path_resolved" &
path_pid=$!
sleep 0.2
orchard_source_dev_cleanup_workers \
  "$REPO_ROOT" \
  "$ORCHARD_WORKER_EXECUTABLE" \
  "$ORCHARD_WORKER_EFFECTIVE_EXECUTABLE" >/dev/null 2>&1
wait "$path_pid" 2>/dev/null || true
path_pid=""
process_is_running "$path_pid" && fail "PATH-resolved worker survived cleanup"

export ORCHARD_WORKER_SOCKET_DIR="$SOCKET_DIR"
export ORCHARD_WORKER_EXECUTABLE="native/orchard_worker_mlx/bin/orchard-worker-mlx"
export ORCHARD_WORKER_EFFECTIVE_EXECUTABLE=""
orchard_source_dev_configure_worker_runtime "$REPO_ROOT"
[[ "$ORCHARD_WORKER_EXECUTABLE" == "$REPO_ROOT/native/orchard_worker_mlx/bin/orchard-worker-mlx" ]] ||
  fail "relative default wrapper was not normalized"
[[ "$ORCHARD_WORKER_EFFECTIVE_EXECUTABLE" == "$REPO_ROOT/native/orchard_worker_mlx/.venv/bin/orchard-worker-mlx" ]] ||
  fail "relative default wrapper did not resolve its effective entrypoint"

printf -v long_padding '%*s' 300 ''
long_padding="${long_padding// /x}"
bash "$FAKE_WORKER" --padding "$long_padding" --socket-path "$socket_long_argv" &
long_argv_pid=$!
sleep 0.2
long_enumeration="$(orchard_source_dev_worker_processes)"
[[ "$long_enumeration" == *"$socket_long_argv"* ]] || fail "wide process enumeration truncated worker argv"
orchard_source_dev_cleanup_workers "$REPO_ROOT" "$FAKE_WORKER" >/dev/null 2>&1
wait "$long_argv_pid" 2>/dev/null || true
long_argv_pid=""
process_is_running "$long_argv_pid" && fail "long-argv worker survived cleanup"

socket_baseline="$SOCKET_DIR/baseline-$$.sock"
bash "$FAKE_WORKER" --socket-path "$socket_baseline" &
baseline_pid=$!
sleep 0.2
identity_marker="$TMP_ROOT/race-identity-read"

orchard_source_dev_process_identity() {
  local pid="$1"

  if [[ "$pid" == "$baseline_pid" ]]; then
    printf '%s\n' "$(id -u) Fri Aug 21 09:00:00 2026 bash $FAKE_OTHER --socket-path $socket_foreign"
    return 0
  fi

  if [[ "$pid" == "$race_pid" ]]; then
    if [[ -e "$identity_marker" ]]; then
      printf '%s\n' "changed process identity"
      return 0
    fi
    touch "$identity_marker"
  fi

  ps -ww -o uid= -o lstart= -o args= -p "$pid" 2>/dev/null
}

orchard_source_dev_cleanup_workers "$REPO_ROOT" "$FAKE_WORKER" >/dev/null 2>&1
process_is_running "$baseline_pid" || fail "replacement before baseline capture was signalled"
kill -TERM "$baseline_pid" 2>/dev/null || true
wait "$baseline_pid" 2>/dev/null || true
baseline_pid=""

bash "$FAKE_WORKER" --socket-path "$socket_race" &
race_pid=$!
sleep 0.2

orchard_source_dev_cleanup_workers "$REPO_ROOT" "$FAKE_WORKER" >/dev/null 2>&1
[[ -e "$identity_marker" ]] || fail "cleanup did not capture process identity"
process_is_running "$race_pid" || fail "worker with changed process identity was signalled"
kill -TERM "$race_pid" 2>/dev/null || true
wait "$race_pid" 2>/dev/null || true
race_pid=""

echo "source-dev worker cleanup tests passed"
