#!/usr/bin/env bash
# Shared source-dev worker cleanup helpers.
#
# These helpers identify and terminate worker subprocesses that belong to the
# current source-dev checkout. They deliberately avoid:
#   - packaged workers (different socket directory)
#   - workers from other repo checkouts (different socket-directory hash)
#   - processes owned by another user
#   - processes whose command line does not declare an exact socket path
#     inside this checkout's source-dev socket directory.
#
# Matching the configured worker executable is intentionally fail-open:
# wrappers, relative argv, or a changed ORCHARD_WORKER_EXECUTABLE can leave an
# in-scope worker resident rather than risk terminating the wrong process.

# Compute the source-dev worker socket directory for a repo root.
# This must stay in sync with the default in config/dev.exs.
# config/test.exs intentionally uses the separate "ot-" prefix and is out of
# scope for source-dev cleanup.
orchard_source_dev_worker_socket_dir() {
  local repo_root="$1"
  local hash

  # config/dev.exs honors this override before falling back to the hashed
  # default; the cleanup scope must follow the same resolution order.
  if [[ -n "${ORCHARD_WORKER_SOCKET_DIR:-}" ]]; then
    printf '%s\n' "$ORCHARD_WORKER_SOCKET_DIR"
    return 0
  fi

  if ! hash="$(orchard_source_dev_worker_socket_hash "$repo_root")"; then
    echo "warning: cannot resolve the source-dev worker socket directory; skipping cleanup" >&2
    return 69
  fi

  printf '%s\n' "/tmp/od-${hash}/ws"
}

# Compute the first eight URL-safe base64 characters of SHA-256(repo_root).
orchard_source_dev_worker_socket_hash() {
  local repo_root="$1"
  local digest_hex

  if command -v shasum >/dev/null 2>&1 &&
    command -v xxd >/dev/null 2>&1 &&
    command -v base64 >/dev/null 2>&1; then
    digest_hex="$(printf '%s' "$repo_root" | shasum -a 256 | awk '{print $1}')" || return 1
    printf '%s' "$digest_hex" |
      xxd -r -p |
      base64 |
      tr -d '\n' |
      tr '+/' '-_' |
      tr -d '=' |
      cut -c1-8
    return 0
  fi

  if command -v openssl >/dev/null 2>&1 && command -v base64 >/dev/null 2>&1; then
    printf '%s' "$repo_root" |
      openssl dgst -binary -sha256 |
      base64 |
      tr -d '\n' |
      tr '+/' '-_' |
      tr -d '=' |
      cut -c1-8
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$repo_root" <<'PY'
import base64
import hashlib
import sys
repo = sys.argv[1]
digest = hashlib.sha256(repo.encode("utf-8")).digest()
encoded = base64.urlsafe_b64encode(digest).decode("ascii")
print(encoded.rstrip("=")[:8])
PY
    return $?
  fi

  return 69
}

# List matching workers as "pid full argv". The ps format is supported by both
# BSD/macOS and Linux; avoid pgrep flags whose full-argv behavior is not
# portable across those platforms.
orchard_source_dev_worker_processes() {
  local line pid args

  while IFS= read -r line; do
    read -r pid args <<< "$line"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "$args" == *orchard-worker-mlx* ]] || continue
    [[ "$pid" != "$$" ]] || continue
    printf '%s %s\n' "$pid" "$args"
  done < <(ps -A -o pid= -o args= 2>/dev/null || true)
}

# Terminate source-dev MLX workers owned by this checkout.
#
# Arguments:
#   $1 repo root
#   $2 worker executable path (optional)
orchard_source_dev_cleanup_workers() {
  local repo_root="$1"
  local worker_executable="${2:-}"
  local socket_dir

  if ! socket_dir="$(orchard_source_dev_worker_socket_dir "$repo_root")"; then
    echo "warning: unable to determine source-dev worker ownership; skipping cleanup" >&2
    return 0
  fi

  local running_uid
  running_uid="$(id -u)" || {
    echo "warning: unable to determine current user id; skipping cleanup" >&2
    return 0
  }

  local -a pids_to_signal=()
  local -a socket_paths_to_signal=()
  local -a ambiguous_pids=()
  local -a different_executable_pids=()
  local line pid args socket_path owner_uid

  while IFS= read -r line; do
    # Skip empty lines produced by ps when no matches exist.
    [[ -z "$line" ]] && continue

    # pid is the first whitespace-delimited token; everything else is args.
    pid="${line%% *}"
    args="${line#* }"

    # Require a parseable socket path argument. Anything else is treated as
    # unknown ownership and skipped rather than risking an unrelated kill.
    if ! socket_path="$(orchard_source_dev_extract_socket_path "$args")"; then
      ambiguous_pids+=("$pid")
      continue
    fi

    # Only consider workers whose socket lives in this checkout's directory.
    [[ "$socket_path" == "$socket_dir/"* ]] || continue

    # When provided, require the command line to identify this checkout's
    # worker executable as well as its socket directory.
    if [[ -n "$worker_executable" ]]; then
      case " $args " in
        *" $worker_executable "*) ;;
        *)
          different_executable_pids+=("$pid")
          continue
          ;;
      esac
    fi

    # Only consider processes owned by the current user. Signals to other
    # users would fail anyway, but this also guards against accidentally
    # reporting them as candidates.
    owner_uid="$(ps -o uid= -p "$pid" 2>/dev/null | tr -d '[:space:]')" || continue
    [[ "$owner_uid" == "$running_uid" ]] || continue

    # Do not signal a process that already exited between enumeration and now.
    if kill -0 "$pid" 2>/dev/null; then
      pids_to_signal+=("$pid")
      socket_paths_to_signal+=("$socket_path")
    fi
  done < <(orchard_source_dev_worker_processes)

  if [[ ${#ambiguous_pids[@]} -gt 0 ]]; then
    echo "warning: skipping orchard-worker-mlx process(es) without a parseable --socket-path: ${ambiguous_pids[*]}" >&2
  fi

  if [[ ${#different_executable_pids[@]} -gt 0 ]]; then
    echo "warning: skipping in-scope orchard-worker-mlx process(es) with a different executable: ${different_executable_pids[*]}" >&2
  fi

  if [[ ${#pids_to_signal[@]} -eq 0 ]]; then
    return 0
  fi

  echo "==> Sending SIGTERM to owned source-dev MLX workers: ${pids_to_signal[*]}"

  local index
  for index in "${!pids_to_signal[@]}"; do
    pid="${pids_to_signal[$index]}"
    if ! kill -TERM "$pid" 2>/dev/null; then
      # The process may have exited between the -0 check and the signal. If it
      # is genuinely gone, ignore; otherwise this is a real permission/signal
      # failure and we abort.
      if kill -0 "$pid" 2>/dev/null; then
        echo "error: failed to signal source-dev worker $pid" >&2
        return 1
      fi
    fi
  done

  # Give the workers a moment to shut down cleanly.
  sleep 1

  # Report any survivors so operators can investigate rather than escalate
  # automatically from a startup script.
  local survivors=()
  for index in "${!pids_to_signal[@]}"; do
    pid="${pids_to_signal[$index]}"
    if kill -0 "$pid" 2>/dev/null; then
      survivors+=("$pid (socket: ${socket_paths_to_signal[$index]})")
    fi
  done

  if [[ ${#survivors[@]} -gt 0 ]]; then
    echo "warning: source-dev MLX workers still alive after SIGTERM: ${survivors[*]}" >&2
  fi

  return 0
}

# Extract --socket-path VALUE from a command-line string.
# Prints the path and returns 0 on success; returns 1 if missing or ambiguous.
orchard_source_dev_extract_socket_path() {
  local args="$1"
  local socket_path=""

  # Match both --socket-path VALUE and --socket-path=VALUE.
  if [[ "$args" =~ --socket-path[[:space:]]+([^[:space:]]+) ]]; then
    socket_path="${BASH_REMATCH[1]}"
  elif [[ "$args" =~ --socket-path=([^[:space:]]+) ]]; then
    socket_path="${BASH_REMATCH[1]}"
  else
    return 1
  fi

  printf '%s\n' "$socket_path"
}
