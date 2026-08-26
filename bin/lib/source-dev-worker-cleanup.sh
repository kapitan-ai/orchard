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
# Ambiguous executable or socket ownership leaves a worker resident rather
# than risking termination of an unrelated process.

orchard_source_dev_reject_unsafe_path() {
  local label="$1"
  local value="$2"

  if [[ "$value" =~ [[:space:][:cntrl:]] ]]; then
    echo "error: $label must not contain whitespace or control characters: $value" >&2
    return 64
  fi
}

orchard_source_dev_resolve_executable() {
  local repo_root="$1"
  local executable="$2"
  local require_executable="${3:-true}"
  local resolved canonical

  orchard_source_dev_reject_unsafe_path "worker executable" "$executable" || return

  if [[ "$executable" == */* ]]; then
    if [[ "$executable" == /* ]]; then
      resolved="$executable"
    else
      resolved="$repo_root/$executable"
    fi
  else
    resolved="$(command -v -- "$executable")" || return 1
  fi

  canonical="$(orchard_source_dev_canonical_existing_path "$resolved")" || return 1
  [[ -f "$canonical" ]] || return 1
  if [[ "$require_executable" == "true" ]]; then
    [[ -x "$canonical" ]] || return 1
  fi

  printf '%s\n' "$canonical"
}

# Normalize source-dev worker paths once, before cleanup and Mix startup.
# The exported values are consumed unchanged by config/dev.exs.
orchard_source_dev_configure_worker_runtime() {
  local repo_root="$1"
  local socket_dir worker_executable effective_executable default_wrapper

  if socket_dir="$(orchard_source_dev_worker_socket_dir "$repo_root")"; then
    orchard_source_dev_reject_unsafe_path "ORCHARD_WORKER_SOCKET_DIR" "$socket_dir" || return
    [[ "$socket_dir" == /* ]] || socket_dir="$repo_root/$socket_dir"
    mkdir -p -- "$socket_dir" || return
    socket_dir="$(orchard_source_dev_canonical_directory "$socket_dir")" || return
  else
    socket_dir=""
  fi

  worker_executable="${ORCHARD_WORKER_EXECUTABLE:-$repo_root/native/orchard_worker_mlx/bin/orchard-worker-mlx}"
  worker_executable="$(orchard_source_dev_resolve_executable "$repo_root" "$worker_executable")" || {
    echo "error: unable to resolve ORCHARD_WORKER_EXECUTABLE" >&2
    return 64
  }

  effective_executable="${ORCHARD_WORKER_EFFECTIVE_EXECUTABLE:-}"
  default_wrapper="$repo_root/native/orchard_worker_mlx/bin/orchard-worker-mlx"
  default_wrapper="$(orchard_source_dev_canonical_existing_path "$default_wrapper")" || true
  if [[ -z "$effective_executable" && "$worker_executable" == "$default_wrapper" ]]; then
    effective_executable="$repo_root/native/orchard_worker_mlx/.venv/bin/orchard-worker-mlx"
    if [[ ! -e "$effective_executable" ]]; then
      echo "warning: MLX worker environment is not built; effective-executable cleanup is disabled" >&2
      effective_executable=""
    fi
  elif [[ -z "$effective_executable" ]]; then
    effective_executable="$worker_executable"
  fi
  if [[ -n "$effective_executable" ]]; then
    effective_executable="$(orchard_source_dev_resolve_executable "$repo_root" "$effective_executable" false)" || {
      echo "error: unable to resolve ORCHARD_WORKER_EFFECTIVE_EXECUTABLE" >&2
      return 64
    }
  fi

  export ORCHARD_WORKER_SOCKET_DIR="$socket_dir"
  export ORCHARD_WORKER_EXECUTABLE="$worker_executable"
  export ORCHARD_WORKER_EFFECTIVE_EXECUTABLE="$effective_executable"
}

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
  done < <(ps -ww -A -o pid= -o args= 2>/dev/null || true)
}

orchard_source_dev_process_identity() {
  local pid="$1"

  ps -ww -o uid= -o lstart= -o args= -p "$pid" 2>/dev/null
}

orchard_source_dev_canonical_existing_path() {
  local path="$1"
  local directory basename

  directory="$(dirname -- "$path")" || return 1
  basename="$(basename -- "$path")" || return 1

  (
    cd -P -- "$directory" 2>/dev/null || exit 1
    printf '%s/%s\n' "$PWD" "$basename"
  )
}

orchard_source_dev_canonical_directory() {
  local directory="$1"

  (
    cd -P -- "$directory" 2>/dev/null || exit 1
    printf '%s\n' "$PWD"
  )
}

orchard_source_dev_args_include_executable() {
  local args="$1"
  shift

  local -a tokens=()
  local -a launch_tokens=()
  local token canonical_token expected interpreter
  read -r -a tokens <<< "$args"
  [[ ${#tokens[@]} -gt 0 ]] || return 1

  launch_tokens+=("${tokens[0]}")
  interpreter="$(basename -- "${tokens[0]}")"
  if [[ ${#tokens[@]} -gt 1 && "$interpreter" =~ ^(ba|z|k)?sh$|^python([0-9.]*)?$ ]]; then
    launch_tokens+=("${tokens[1]}")
  fi

  for token in "${launch_tokens[@]}"; do
    [[ "$token" == */* ]] || continue
    canonical_token="$(orchard_source_dev_canonical_existing_path "$token")" || continue

    for expected in "$@"; do
      [[ "$canonical_token" == "$expected" ]] && return 0
    done
  done

  return 1
}

# Terminate source-dev MLX workers owned by this checkout.
#
# Arguments:
#   $1 repo root
#   $2 worker executable path (optional)
#   $3 effective executable path after a wrapper exec (optional)
orchard_source_dev_cleanup_workers() {
  local repo_root="$1"
  local worker_executable="${2:-}"
  local configured_effective_executable="${3:-}"
  local socket_dir canonical_socket_dir

  if ! socket_dir="$(orchard_source_dev_worker_socket_dir "$repo_root")"; then
    echo "warning: unable to determine source-dev worker ownership; skipping cleanup" >&2
    return 0
  fi

  canonical_socket_dir="$(orchard_source_dev_canonical_directory "$socket_dir")" || {
    echo "warning: unable to resolve source-dev worker socket directory; skipping cleanup" >&2
    return 0
  }

  local running_uid
  running_uid="$(id -u)" || {
    echo "warning: unable to determine current user id; skipping cleanup" >&2
    return 0
  }

  local -a pids_to_signal=()
  local -a socket_paths_to_signal=()
  local -a process_identities_to_signal=()
  local -a ambiguous_pids=()
  local -a different_executable_pids=()
  local line pid args socket_path socket_parent owner_uid process_identity
  local identity_weekday identity_month identity_day identity_time identity_year identity_args
  local canonical_worker_executable effective_worker_executable

  canonical_worker_executable=""
  effective_worker_executable=""
  if [[ -n "$worker_executable" ]]; then
    canonical_worker_executable="$(orchard_source_dev_canonical_existing_path "$worker_executable")" || {
      echo "warning: unable to resolve configured worker executable; skipping cleanup" >&2
      return 0
    }

    if [[ -n "$configured_effective_executable" ]]; then
      effective_worker_executable="$(orchard_source_dev_canonical_existing_path "$configured_effective_executable")" || {
        echo "warning: unable to resolve effective worker executable; skipping cleanup" >&2
        return 0
      }
    fi
  fi

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

    socket_parent="$(dirname -- "$socket_path")" || {
      ambiguous_pids+=("$pid")
      continue
    }
    socket_parent="$(orchard_source_dev_canonical_directory "$socket_parent")" || {
      ambiguous_pids+=("$pid")
      continue
    }

    # Compare canonical parent directories so lexical traversal cannot turn an
    # out-of-scope socket into an owned candidate.
    [[ "$socket_parent" == "$canonical_socket_dir" ]] || continue

    # When provided, require the command line to identify this checkout's
    # worker executable as well as its socket directory.
    if [[ -n "$worker_executable" ]]; then
      if ! orchard_source_dev_args_include_executable \
        "$args" \
        "$canonical_worker_executable" \
        "$effective_worker_executable"; then
        different_executable_pids+=("$pid")
        continue
      fi
    fi

    # Capture one identity snapshot, then re-run every ownership predicate
    # against its argv. This prevents a replacement process from inheriting a
    # candidate PID between enumeration and baseline capture.
    if kill -0 "$pid" 2>/dev/null; then
      process_identity="$(orchard_source_dev_process_identity "$pid")" || continue
      [[ -n "$process_identity" ]] || continue

      read -r \
        owner_uid \
        identity_weekday \
        identity_month \
        identity_day \
        identity_time \
        identity_year \
        identity_args <<< "$process_identity"
      [[ "$owner_uid" == "$running_uid" && -n "$identity_args" ]] || continue

      if ! socket_path="$(orchard_source_dev_extract_socket_path "$identity_args")"; then
        ambiguous_pids+=("$pid")
        continue
      fi
      socket_parent="$(dirname -- "$socket_path")" || continue
      socket_parent="$(orchard_source_dev_canonical_directory "$socket_parent")" || continue
      [[ "$socket_parent" == "$canonical_socket_dir" ]] || continue

      if [[ -n "$worker_executable" ]] &&
        ! orchard_source_dev_args_include_executable \
          "$identity_args" \
          "$canonical_worker_executable" \
          "$effective_worker_executable"; then
        different_executable_pids+=("$pid")
        continue
      fi

      pids_to_signal+=("$pid")
      socket_paths_to_signal+=("$socket_path")
      process_identities_to_signal+=("$process_identity")
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

  local -a signalled_pids=()
  local -a signalled_socket_paths=()
  local -a signalled_identities=()
  local -a changed_identity_pids=()
  local current_identity index
  for index in "${!pids_to_signal[@]}"; do
    pid="${pids_to_signal[$index]}"

    echo "==> Revalidating owned source-dev MLX worker before SIGTERM: $pid"
    current_identity="$(orchard_source_dev_process_identity "$pid")" || continue
    if [[ "$current_identity" != "${process_identities_to_signal[$index]}" ]]; then
      changed_identity_pids+=("$pid")
      continue
    fi

    if ! kill -TERM "$pid" 2>/dev/null; then
      if kill -0 "$pid" 2>/dev/null; then
        echo "error: failed to signal source-dev worker $pid" >&2
        return 1
      fi
      continue
    fi

    signalled_pids+=("$pid")
    signalled_socket_paths+=("${socket_paths_to_signal[$index]}")
    signalled_identities+=("$current_identity")
  done

  if [[ ${#changed_identity_pids[@]} -gt 0 ]]; then
    echo "warning: skipping source-dev worker process(es) whose identity changed before signalling: ${changed_identity_pids[*]}" >&2
  fi

  [[ ${#signalled_pids[@]} -gt 0 ]] || return 0

  # Give the workers a moment to shut down cleanly.
  sleep 1

  # Report any survivors so operators can investigate rather than escalate
  # automatically from a startup script.
  local survivors=()
  for index in "${!signalled_pids[@]}"; do
    pid="${signalled_pids[$index]}"
    current_identity="$(orchard_source_dev_process_identity "$pid")" || continue
    if [[ "$current_identity" == "${signalled_identities[$index]}" ]]; then
      survivors+=("$pid (socket: ${signalled_socket_paths[$index]})")
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
  local -a tokens=()
  local token expect_value=0 count=0

  # ps exposes argv as a whitespace-delimited string on supported platforms.
  # Reject repeated or malformed forms because accepting the first value could
  # disagree with the worker parser, which accepts the last repeated option.
  read -r -a tokens <<< "$args"
  for token in "${tokens[@]}"; do
    if [[ "$expect_value" -eq 1 ]]; then
      socket_path="$token"
      expect_value=0
      count=$((count + 1))
      continue
    fi

    case "$token" in
      --socket-path)
        expect_value=1
        ;;
      --socket-path=*)
        socket_path="${token#--socket-path=}"
        [[ -n "$socket_path" ]] || return 1
        count=$((count + 1))
        ;;
    esac
  done

  [[ "$expect_value" -eq 0 && "$count" -eq 1 ]] || return 1

  printf '%s\n' "$socket_path"
}
