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

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
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

FAKE_AMBIGUOUS="$TMP_ROOT/orchard-worker-mlx-ambiguous"
cat > "$FAKE_AMBIGUOUS" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
trap 'exit 0' TERM
while :; do sleep 0.2; done
SCRIPT
chmod +x "$FAKE_AMBIGUOUS"

socket_owned="$SOCKET_DIR/owned.sock"
socket_foreign="$FOREIGN_SOCKET_DIR/foreign.sock"

# Start a worker that belongs to this checkout and one that belongs elsewhere.
# Note: capturing the pid via command substitution ($(cmd & echo $!)) would
# hang — the background child inherits the substitution's stdout pipe and the
# read blocks until the child exits.
"$FAKE_WORKER" --socket-path "$socket_owned" &
owned_pid=$!
"$FAKE_WORKER" --socket-path "$socket_foreign" &
foreign_pid=$!
"$FAKE_AMBIGUOUS" &
ambiguous_pid=$!

# Give the background jobs a moment to establish their command lines.
sleep 0.2

# Verify both are alive before cleanup.
kill -0 "$owned_pid" 2>/dev/null || fail "owned worker was not running before cleanup"
kill -0 "$foreign_pid" 2>/dev/null || fail "foreign worker was not running before cleanup"
kill -0 "$ambiguous_pid" 2>/dev/null || fail "ambiguous worker was not running before cleanup"

# Run the cleanup helper.
cleanup_output="$(orchard_source_dev_cleanup_workers "$REPO_ROOT" "$FAKE_WORKER" 2>&1)"
printf '%s\n' "$cleanup_output"
[[ "$cleanup_output" == *"warning: skipping orchard-worker-mlx process(es) with unknown ownership"* ]] ||
  fail "ambiguous worker warning was not emitted"
[[ "$cleanup_output" == *"$ambiguous_pid"* ]] ||
  fail "ambiguous worker warning did not name its pid"

# Reap the owned worker first: it is a child of this shell, so until wait(2)
# collects it the zombie still answers kill -0.
wait "$owned_pid" 2>/dev/null || true

# The owned worker should be gone.
if kill -0 "$owned_pid" 2>/dev/null; then
  fail "owned source-dev worker survived cleanup"
fi

# The foreign worker should still be alive.
if ! kill -0 "$foreign_pid" 2>/dev/null; then
  fail "foreign worker was incorrectly killed by cleanup"
fi

# The ambiguous worker should still be alive and the helper should have
# returned success despite not being able to establish ownership.
if ! kill -0 "$ambiguous_pid" 2>/dev/null; then
  fail "ambiguous worker was incorrectly killed by cleanup"
fi

# Clean up the foreign and ambiguous workers.
kill -TERM "$foreign_pid" 2>/dev/null || true
wait "$foreign_pid" 2>/dev/null || true
kill -TERM "$ambiguous_pid" 2>/dev/null || true
wait "$ambiguous_pid" 2>/dev/null || true

echo "source-dev worker cleanup tests passed"
