#!/usr/bin/env bash
# control-orchard — launch, doctor, and stop Orchard source-dev for verification runs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SKILL_DIR/../../.." && pwd)"

RUN_ID="${ORCHARD_VERIFY_RUN_ID:-$(date +%Y%m%d%H%M%S)-$$}"
STATE_DIR="${ORCHARD_VERIFY_STATE_DIR:-/tmp/orchard-verify-${RUN_ID}}"
PID_FILE="${STATE_DIR}/dev.pid"
LOG_FILE="${STATE_DIR}/dev.log"
META_FILE="${STATE_DIR}/meta.env"
PORT="${ORCHARD_VERIFY_PORT:-4000}"
BASE_URL="http://127.0.0.1:${PORT}"
READY_TIMEOUT_SEC="${ORCHARD_VERIFY_READY_TIMEOUT_SEC:-300}"

mkdir -p "$STATE_DIR"

preserved_bundle_path() {
  if [[ -n "${ORCHARD_MLX_SMOKE_MODEL_PATH:-}" ]]; then
    printf '%s' "$ORCHARD_MLX_SMOKE_MODEL_PATH"
    return
  fi
  if [[ -f "$META_FILE" ]]; then
    sed -n 's/^ORCHARD_MLX_SMOKE_MODEL_PATH=//p' "$META_FILE" | tail -n 1
  fi
}

write_meta() {
  local bundle_path
  bundle_path="$(preserved_bundle_path)"
  cat >"$META_FILE" <<EOF
ORCHARD_VERIFY_RUN_ID=${RUN_ID}
ORCHARD_VERIFY_STATE_DIR=${STATE_DIR}
ORCHARD_VERIFY_PORT=${PORT}
ORCHARD_VERIFY_BASE_URL=${BASE_URL}
ORCHARD_VERIFY_PID_FILE=${PID_FILE}
ORCHARD_VERIFY_LOG_FILE=${LOG_FILE}
ORCHARD_VERIFY_ARTIFACTS_DIR=${STATE_DIR}/artifacts
ORCHARD_MLX_SMOKE_MODEL_PATH=${bundle_path}
EOF
}

usage() {
  cat <<EOF
Usage: control-orchard <command>

Commands:
  bootstrap       Ensure tmp/dev/node-trust exists (opt-in orphan recover)
  launch          Start source-dev in the background (mix phx.server)
  doctor          Read-only health check for the verification instance
  stop            Stop the instance started by launch (PID file only)
  meta            Print state paths for the current run
  curl            curl wrapper against the verification base URL
  prepare-bundle  Prepare the pinned Qwen3 MLX smoke bundle (not a CI gate)
  smoke-mlx       Run scripts/smoke-mlx.sh against that bundle

Environment:
  ORCHARD_VERIFY_PORT          HTTP port (default: 4000)
  ORCHARD_VERIFY_RUN_ID        Stable run id for state dir naming
  ORCHARD_VERIFY_STATE_DIR     Override state directory
  ORCHARD_VERIFY_READY_TIMEOUT_SEC  Launch wait timeout (default: 300)
  ORCHARD_VERIFY_TRUST_RECOVER      Set to 1 to allow wiping orphaned DB trust
                                    when local node-trust files are missing
  ORCHARD_MLX_SMOKE_MODEL_PATH      Absolute Orchard bundle dir (set by prepare-bundle)
EOF
}

port_owner_pid() {
  lsof -ti "tcp:${PORT}" -sTCP:LISTEN 2>/dev/null | head -n 1 || true
}

require_repo() {
  [[ -f "${REPO_ROOT}/mix.exs" ]] || {
    echo "error: repo root not found at ${REPO_ROOT}" >&2
    exit 1
  }
}

cmd_bootstrap() {
  require_repo
  local trust_root="${ORCHARD_NODE_TRUST_ROOT:-${REPO_ROOT}/tmp/dev/node-trust}"
  local allow_recover="${ORCHARD_VERIFY_TRUST_RECOVER:-0}"

  if [[ -e "${trust_root}/current" ]]; then
    echo "==> Node trust files present at ${trust_root}/current"
    return 0
  fi

  echo "==> Bootstrapping dev node trust at ${trust_root}"

  (
    cd "$REPO_ROOT"
    export MIX_ENV=dev
    export ORCHARD_VERIFY_TRUST_RECOVER="$allow_recover"
    mise exec -- mix run --no-start -e '
      Application.ensure_all_started(:logger)
      Application.load(:orchard_controller)

      allow_recover? = System.get_env("ORCHARD_VERIFY_TRUST_RECOVER") == "1"

      init = fn ->
        Ecto.Migrator.with_repo(Orchard.Repo, fn _repo ->
          case Orchard.NodeTrust.initialize(actor_id: "verify-orchard") do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end)
        |> case do
          {:ok, :ok, _} -> :ok
          {:ok, {:error, reason}, _} -> {:error, reason}
          other -> {:error, other}
        end
      end

      recover = fn ->
        Ecto.Migrator.with_repo(Orchard.Repo, fn repo ->
          Ecto.Adapters.SQL.query!(repo, "DELETE FROM controller_instances")
          Ecto.Adapters.SQL.query!(repo, "DELETE FROM node_trust_authorities")
          Ecto.Adapters.SQL.query!(repo, "DELETE FROM cluster_identities")
          :recovered
        end)
      end

      case init.() do
        :ok ->
          IO.puts("==> Node trust initialized")

        {:error, :not_found} when allow_recover? ->
          IO.puts("==> Orphaned DB trust (local files missing); recovering with ORCHARD_VERIFY_TRUST_RECOVER=1")
          {:ok, _, _} = recover.()

          case init.() do
            :ok -> IO.puts("==> Node trust initialized after orphan recovery")
            other -> IO.inspect(other); System.halt(1)
          end

        {:error, :not_found} ->
          IO.puts(:stderr, """
          error: orchard_dev has cluster trust rows but #{System.get_env("ORCHARD_NODE_TRUST_ROOT") || "tmp/dev/node-trust"} has no current files.
          Refusing to delete shared DB trust by default (this would disrupt an existing make dev session).
          Restore the missing node-trust files, or re-run with ORCHARD_VERIFY_TRUST_RECOVER=1 only if you intend to wipe and re-init local trust.
          """)
          System.halt(1)

        {:error, reason} ->
          IO.puts(:stderr, "error: node trust init failed: #{inspect(reason)}")
          System.halt(1)
      end
    '
  )
}

cmd_launch() {
  require_repo
  write_meta

  if [[ -f "$PID_FILE" ]]; then
    existing_pid="$(cat "$PID_FILE")"
    if kill -0 "$existing_pid" 2>/dev/null; then
      echo "error: verification instance already running (pid ${existing_pid})" >&2
      echo "error: run 'control-orchard stop' first" >&2
      exit 1
    fi
  fi

  foreign_pid="$(port_owner_pid)"
  if [[ -n "$foreign_pid" ]]; then
    echo "error: port ${PORT} is already in use by pid ${foreign_pid}" >&2
    echo "error: stop that server or set ORCHARD_VERIFY_PORT to a free port" >&2
    exit 1
  fi

  if ! pg_isready -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" >/dev/null 2>&1; then
    echo "error: PostgreSQL is not accepting connections on ${PGHOST:-localhost}:${PGPORT:-5432}" >&2
    exit 1
  fi

  cmd_bootstrap

  echo "==> Ensuring dev database..."
  (
    cd "$REPO_ROOT"
    export MIX_ENV=dev
    mise exec -- mix ecto.create --quiet
    mise exec -- mix ecto.migrate --quiet
  )

  echo "==> Compiling dev apps (foreground)..."
  (
    cd "$REPO_ROOT"
    export MIX_ENV=dev
    mise exec -- mix compile
    mise exec -- mix assets.build
  )

  echo "==> Launching Orchard source-dev on ${BASE_URL}"
  echo "    state: ${STATE_DIR}"
  echo "    log:   ${LOG_FILE}"

  # Detach into a new session so the BEAM survives this helper returning
  # (agent shells send SIGHUP to the launch process group when the command ends).
  if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 is required to detach the verification server" >&2
    exit 1
  fi

  python3 - "$REPO_ROOT" "$LOG_FILE" "$PID_FILE" "$PORT" <<'PY'
import os
import sys
import time

repo, log_path, pid_path, port = sys.argv[1:5]
env_update = {
    "MIX_ENV": "dev",
    "ORCHARD_VERIFY_MODE": "1",
    "PORT": port,
    "ORCHARD_SOURCE_DEV_ROLE": "all_in_one",
    "ORCHARD_NODE_AGENT_LISTEN_PORT": "50071",
    "ORCHARD_RUNTIME_CLIENT_PORT": "50071",
}

pid = os.fork()
if pid > 0:
    for _ in range(100):
        try:
            with open(pid_path, encoding="utf-8") as handle:
                child = int(handle.read().strip())
            os.kill(child, 0)
            os._exit(0)
        except (OSError, ValueError):
            time.sleep(0.05)
    sys.stderr.write("error: detached server did not record a live pid\n")
    os._exit(1)

os.setsid()
pid = os.fork()
if pid > 0:
    os._exit(0)

os.chdir(repo)
os.environ.update(env_update)
devnull = os.open(os.devnull, os.O_RDONLY)
log_fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
os.dup2(devnull, 0)
os.dup2(log_fd, 1)
os.dup2(log_fd, 2)
if devnull > 2:
    os.close(devnull)
if log_fd > 2:
    os.close(log_fd)

child = os.fork()
if child == 0:
    os.execvp("mise", ["mise", "exec", "--", "mix", "phx.server"])
with open(pid_path, "w", encoding="utf-8") as handle:
    handle.write(f"{child}\n")
os._exit(0)
PY

  pid="$(cat "$PID_FILE")"

  deadline=$((SECONDS + READY_TIMEOUT_SEC))
  while (( SECONDS < deadline )); do
    if curl -sf "${BASE_URL}/health/live" >/dev/null 2>&1; then
      echo "==> Ready (${BASE_URL}/health/live)"
      echo "    pid: ${pid}"
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "error: dev server exited before becoming ready; see ${LOG_FILE}" >&2
      tail -n 40 "$LOG_FILE" >&2 || true
      exit 1
    fi
    sleep 2
  done

  echo "error: timed out waiting for ${BASE_URL}/health/live" >&2
  tail -n 40 "$LOG_FILE" >&2 || true
  exit 1
}

cmd_doctor() {
  [[ -f "$META_FILE" ]] || write_meta

  # shellcheck disable=SC1090
  source "$META_FILE"

  echo "==> Doctor for ${BASE_URL}"

  if [[ ! -f "$PID_FILE" ]]; then
    echo "FAIL: no pid file at ${PID_FILE} (was launch run?)"
    exit 1
  fi

  pid="$(cat "$PID_FILE")"
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "FAIL: pid ${pid} is not running"
    exit 1
  fi

  owner="$(port_owner_pid)"
  if [[ "$owner" != "$pid" ]]; then
    echo "FAIL: port ${PORT} listener pid ${owner:-none} != verification pid ${pid}"
    exit 1
  fi

  live_body="$(curl -sf "${BASE_URL}/health/live")" || {
    echo "FAIL: GET /health/live unreachable"
    exit 1
  }
  if [[ "$live_body" != '{"status":"ok"}' ]]; then
    echo "FAIL: unexpected /health/live body: ${live_body}"
    exit 1
  fi

  ready_code="$(curl -s -o /tmp/orchard-verify-ready.$$ -w '%{http_code}' "${BASE_URL}/health/ready")"
  ready_body="$(cat /tmp/orchard-verify-ready.$$)"
  rm -f /tmp/orchard-verify-ready.$$
  echo "OK: /health/live"
  echo "INFO: /health/ready -> HTTP ${ready_code} ${ready_body}"

  console_code="$(curl -s -o /tmp/orchard-verify-console.$$ -w '%{http_code}' "${BASE_URL}/console")"
  console_body="$(cat /tmp/orchard-verify-console.$$)"
  rm -f /tmp/orchard-verify-console.$$
  if [[ "$console_code" != "200" ]]; then
    echo "FAIL: GET /console -> HTTP ${console_code}"
    exit 1
  fi
  if ! grep -q "Orchard Console" <<<"$console_body"; then
    echo "FAIL: /console body missing 'Orchard Console'"
    exit 1
  fi

  echo "OK: /console loads (dev auth: none)"
  echo "OK: verification instance healthy (pid ${pid}, port ${PORT})"
}

cmd_stop() {
  [[ -f "$META_FILE" ]] && source "$META_FILE"

  if [[ ! -f "$PID_FILE" ]]; then
    echo "==> No pid file; nothing to stop"
    return 0
  fi

  pid="$(cat "$PID_FILE")"
  if kill -0 "$pid" 2>/dev/null; then
    echo "==> Stopping verification dev server (pid ${pid})"
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 30); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "==> Sending SIGTERM did not exit; sending SIGKILL"
      kill -9 "$pid" 2>/dev/null || true
    fi
  else
    echo "==> pid ${pid} already stopped"
  fi

  rm -f "$PID_FILE"
  echo "==> Stopped"
}

cmd_meta() {
  write_meta
  cat "$META_FILE"
}

cmd_curl() {
  [[ -f "$META_FILE" ]] && source "$META_FILE"
  curl -sS "${BASE_URL}$*"
}

require_apple_silicon() {
  if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "error: MLX smoke requires Apple Silicon macOS (detected $(uname -s) $(uname -m))" >&2
    exit 1
  fi
}

free_tcp_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

cmd_prepare_bundle() {
  require_repo
  write_meta
  local prepare="${REPO_ROOT}/scripts/prepare-mlx-smoke-bundle.sh"
  [[ -f "$prepare" ]] || {
    echo "error: missing ${prepare}" >&2
    exit 1
  }

  echo "==> Preparing pinned Qwen3 MLX smoke bundle (not a CI gate)"
  local out
  out="$(
    cd "$REPO_ROOT"
    mise exec -- ./scripts/prepare-mlx-smoke-bundle.sh "$@"
  )"
  printf '%s\n' "$out"
  local export_line
  export_line="$(printf '%s\n' "$out" | grep '^export ORCHARD_MLX_SMOKE_MODEL_PATH=' | tail -n 1 || true)"
  if [[ -z "$export_line" ]]; then
    echo "error: prepare-mlx-smoke-bundle.sh did not print export ORCHARD_MLX_SMOKE_MODEL_PATH=..." >&2
    exit 1
  fi
  eval "$export_line"
  write_meta
  echo "==> Bundle ready: ${ORCHARD_MLX_SMOKE_MODEL_PATH}"
}

cmd_smoke_mlx() {
  require_repo
  require_apple_silicon
  [[ -f "$META_FILE" ]] && source "$META_FILE"
  if [[ -z "${ORCHARD_MLX_SMOKE_MODEL_PATH:-}" || ! -f "${ORCHARD_MLX_SMOKE_MODEL_PATH}/manifest.json" ]]; then
    cmd_prepare_bundle
    source "$META_FILE"
  fi

  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    ORCHARD_TEST_NODE_AGENT_PORT="$(free_tcp_port)"
    export ORCHARD_TEST_NODE_AGENT_PORT
    echo "==> Verification instance is running; Elixir smoke will use ORCHARD_TEST_NODE_AGENT_PORT=${ORCHARD_TEST_NODE_AGENT_PORT}"
  fi

  local art="${STATE_DIR}/artifacts/mlx-smoke"
  mkdir -p "$art"
  echo "==> Running scripts/smoke-mlx.sh"
  echo "    bundle: ${ORCHARD_MLX_SMOKE_MODEL_PATH}"
  (
    cd "$REPO_ROOT"
    export ORCHARD_MLX_SMOKE_MODEL_PATH
    if [[ -n "${ORCHARD_TEST_NODE_AGENT_PORT:-}" ]]; then
      export ORCHARD_TEST_NODE_AGENT_PORT
    fi
    mise exec -- ./scripts/smoke-mlx.sh
  ) | tee "${art}/smoke.log"
}

main() {
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    launch) cmd_launch "$@" ;;
    bootstrap) cmd_bootstrap "$@" ;;
    doctor) cmd_doctor "$@" ;;
    stop) cmd_stop "$@" ;;
    meta) cmd_meta "$@" ;;
    prepare-bundle) cmd_prepare_bundle "$@" ;;
    smoke-mlx) cmd_smoke_mlx "$@" ;;
    curl)
      if (($# == 0)); then
        echo "error: control-orchard curl expects a path such as /health/live" >&2
        exit 1
      fi
      cmd_curl "$@"
      ;;
    -h | --help | help | "") usage ;;
    *)
      echo "error: unknown command: ${cmd}" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
