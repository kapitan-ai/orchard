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

write_meta() {
  cat >"$META_FILE" <<EOF
ORCHARD_VERIFY_RUN_ID=${RUN_ID}
ORCHARD_VERIFY_STATE_DIR=${STATE_DIR}
ORCHARD_VERIFY_PORT=${PORT}
ORCHARD_VERIFY_BASE_URL=${BASE_URL}
ORCHARD_VERIFY_PID_FILE=${PID_FILE}
ORCHARD_VERIFY_LOG_FILE=${LOG_FILE}
ORCHARD_VERIFY_ARTIFACTS_DIR=${STATE_DIR}/artifacts
EOF
}

usage() {
  cat <<EOF
Usage: control-orchard <command>

Commands:
  bootstrap Ensure tmp/dev/node-trust exists (opt-in orphan recover)
  launch    Start source-dev in the background (mix phx.server)
  doctor    Read-only health check for the verification instance
  stop      Stop the instance started by launch (PID file only)
  meta      Print state paths for the current run
  curl      curl wrapper against the verification base URL

Environment:
  ORCHARD_VERIFY_PORT          HTTP port (default: 4000)
  ORCHARD_VERIFY_RUN_ID        Stable run id for state dir naming
  ORCHARD_VERIFY_STATE_DIR     Override state directory
  ORCHARD_VERIFY_READY_TIMEOUT_SEC  Launch wait timeout (default: 300)
  ORCHARD_VERIFY_TRUST_RECOVER      Set to 1 to allow wiping orphaned DB trust
                                    when local node-trust files are missing
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

  (
    cd "$REPO_ROOT"
    export MIX_ENV=dev
    export ORCHARD_VERIFY_MODE=1
    export PORT="$PORT"
    export ORCHARD_SOURCE_DEV_ROLE=all_in_one
    export ORCHARD_NODE_AGENT_LISTEN_PORT=50071
    export ORCHARD_RUNTIME_CLIENT_PORT=50071
    exec mise exec -- mix phx.server
  ) >"$LOG_FILE" 2>&1 &

  pid=$!
  echo "$pid" >"$PID_FILE"

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

main() {
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    launch) cmd_launch "$@" ;;
    bootstrap) cmd_bootstrap "$@" ;;
    doctor) cmd_doctor "$@" ;;
    stop) cmd_stop "$@" ;;
    meta) cmd_meta "$@" ;;
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
