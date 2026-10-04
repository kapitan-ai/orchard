#!/usr/bin/env bash
# Relocated-root fixtures do NOT qualify host/user/trust, Agent boot or Worker
# cessation/resource release. The fixture binary bypasses only host facts.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# == 0 ]] || { printf 'Usage: %s\n' "$0" >&2; exit 64; }
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-root-guardian-test.XXXXXX")"
GUARDIAN=""
SUBJECT=""
cleanup() {
  if [[ -n "$GUARDIAN" ]]; then
    kill -KILL "$GUARDIAN" 2>/dev/null || true
    wait "$GUARDIAN" 2>/dev/null || true
  fi
  if [[ -n "$SUBJECT" ]]; then kill -KILL "$SUBJECT" 2>/dev/null || true; fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
expect() {
  local expected="$1" actual=0
  shift
  "$@" >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr" || actual=$?
  if [[ "$actual" != "$expected" ]]; then
    tail -n 40 -- "$TMP_ROOT/stdout" "$TMP_ROOT/stderr" >&2 || true
    fail "expected status $expected, got $actual"
  fi
}
bounded() { timeout --signal=KILL 10 "$@"; }
await_file() {
  local i
  for ((i=0; i<200; i++)); do
    [[ -s "$1" ]] && return 0
    sleep 0.025
  done
  fail 'child readiness timeout'
}
await_dead() {
  local i state
  for ((i=0; i<200; i++)); do
    [[ -e "/proc/$1/stat" ]] || return 0
    state="$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null || true)"
    [[ "$state" == Z\ * ]] && return 0
    sleep 0.025
  done
  fail 'subject survived guardian death'
}

HELPER="$TMP_ROOT/bin/orchard-node-root-guardian-test"
PRODUCTION="$TMP_ROOT/bin/orchard-node-root-guardian"
if [[ "$(uname -s)" != Linux ]]; then
  # Compile the actual non-Linux refusal branch, not a mock Linux build.
  mkdir "$TMP_ROOT/bin"
  for variant in production fixture; do
    flags=()
    target="$PRODUCTION"
    if [[ "$variant" == fixture ]]; then
      flags=(-DORCHARD_NODE_ROOT_GUARDIAN_TEST)
      target="$HELPER"
    fi
    "${CC:-cc}" -std=c11 -Wall -Wextra -Werror -pedantic -O2 ${flags[@]+"${flags[@]}"} \
      "$REPO_ROOT/packaging/native_helpers/orchard_node_root_guardian.c" -o "$target"
  done
  expect 0 "$HELPER" --test-host-validator
  expect 64 "$PRODUCTION" --test-host-validator
  expect 69 "$PRODUCTION" --check-host
  expect 69 "$PRODUCTION" --run "$TMP_ROOT/absent" -- /bin/false
  expect 69 "$PRODUCTION" --verify "$TMP_ROOT/absent" forged "$$"
  expect 69 "$HELPER" --run "$TMP_ROOT/absent" -- /bin/false
  expect 69 bash "$REPO_ROOT/scripts/build-linux-node-root-guardian.sh" --output "$TMP_ROOT/not-created"
  [[ ! -e "$TMP_ROOT/absent" && ! -e "$TMP_ROOT/not-created" ]] || fail 'non-Linux refusal mutated root'
  printf 'PASS: portable host-fact validator and non-Linux refusal checks.\n'
  printf 'SKIP: Linux kernel guardian tests require Linux; no native proof on this host.\n'
  exit 77
fi
for tool in cc timeout stat flock bash elixir; do
  command -v "$tool" >/dev/null || { printf 'Missing test prerequisite: %s\n' "$tool" >&2; exit 69; }
done
# The actual lock tests deliberately retain the production filesystem gate.
case "$(stat -f -c %T "$TMP_ROOT")" in
  ext2/ext3|xfs) ;;
  *) printf 'SKIP: test root needs local ext/XFS; filesystem gate not bypassed.\n'; exit 77 ;;
esac
bash "$REPO_ROOT/scripts/build-linux-node-root-guardian.sh" --output "$TMP_ROOT/bin" --include-test-helper
expect 0 "$HELPER" --test-host-validator
expect 0 bounded "$HELPER" --test-parsers
expect 0 bounded "$HELPER" --test-parent-race
expect 64 "$PRODUCTION" --test-host-validator
expect 64 "$PRODUCTION" --test-parsers
expect 64 "$PRODUCTION" --test-parent-race
ROOT="$TMP_ROOT/identity"
mkdir -m 0700 "$ROOT"
mkdir -m 0700 "$ROOT/generations" "$ROOT/generations/g"
printf 'registered-tree-sentinel\n' >"$ROOT/sentinel"
export HELPER ROOT TMP_ROOT

# No implicit host bypass, even when the marker/subject are forged. Hosted CI
# should refuse; a genuinely admitted host may pass preflight but not verify.
host_status=0
bounded "$PRODUCTION" --check-host >"$TMP_ROOT/host-out" 2>"$TMP_ROOT/host-error" || host_status=$?
case "$host_status" in
  0) expect 77 bounded "$PRODUCTION" --verify "$ROOT" forged "$$" ;;
  69)
    # Expansion belongs to the child process.
    # shellcheck disable=SC2016
    expect 69 bounded "$PRODUCTION" --run "$ROOT" -- /bin/sh -c 'touch "$ROOT/forbidden"'
    expect 69 bounded "$PRODUCTION" --verify "$ROOT" forged "$$"
    [[ ! -e "$ROOT/forbidden" ]] || fail 'production host refusal ran command'
    ;;
  *) fail 'unexpected production preflight status' ;;
esac

# Real shell subject, then exec into sleep with exactly the same PID.
start_owner() {
  rm -f "$TMP_ROOT/ready" "$TMP_ROOT/marker"
  # Inspect the subject's environment, PID and FDs.
  # shellcheck disable=SC2016
  "$HELPER" --run "$ROOT" -- /bin/bash -c '
    set -eu
    "$HELPER" --verify "$ROOT" "$ORCHARD_NODE_ROOT_GUARD" "$$"
    [[ "$ORCHARD_NODE_IDENTITY_ROOT" == "$ROOT" ]]
    identity=$(stat -c "%d:%i" "$ROOT")
    for fd in /proc/$$/fd/*; do
      [[ "$(stat -Lc "%d:%i" "$fd" 2>/dev/null || true)" != "$identity" ]]
    done
    printf "%s\n" "$ORCHARD_NODE_ROOT_GUARD" >"$TMP_ROOT/marker"
    printf "%s\n" "$$" >"$TMP_ROOT/ready"
    exec /bin/sleep 60
  ' >"$TMP_ROOT/owner-out" 2>"$TMP_ROOT/owner-error" &
  GUARDIAN=$!
  await_file "$TMP_ROOT/ready"
  SUBJECT="$(cat "$TMP_ROOT/ready")"
  MARKER="$(cat "$TMP_ROOT/marker")"
  local i
  for ((i=0; i<200; i++)); do
    [[ "$(readlink "/proc/$SUBJECT/exe" 2>/dev/null || true)" == */sleep ]] && break
    sleep 0.025
  done
  [[ "$i" -lt 200 ]] || fail 'subject failed to exec'
  expect 0 bounded "$HELPER" --verify "$ROOT" "$MARKER" "$SUBJECT"
  local fd identity
  identity="$(stat -c '%d:%i' "$ROOT")"
  for fd in /proc/"$SUBJECT"/fd/*; do
    [[ "$(stat -Lc '%d:%i' "$fd" 2>/dev/null || true)" != "$identity" ]] || fail 'root FD survived exec'
  done
}
finish_owner() {
  local signal="$1" expected="$2" actual=0
  kill -"$signal" "$GUARDIAN"
  await_dead "$SUBJECT"
  wait "$GUARDIAN" || actual=$?
  GUARDIAN=""; SUBJECT=""
  [[ "$actual" == "$expected" ]] || fail 'guardian exit status mismatch'
}

start_owner
before="$(stat -c '%d:%i:%s:%y:%z' "$ROOT")"
listing="$(ls -a "$ROOT")"
# This sentinel must be created only by the child.
# shellcheck disable=SC2016
expect 75 bounded "$HELPER" --run "$ROOT" -- /bin/sh -c 'touch "$ROOT/forbidden"'
[[ "$(stat -c '%d:%i:%s:%y:%z' "$ROOT")" == "$before" && "$(ls -a "$ROOT")" == "$listing" ]] || fail 'duplicate mutated root'
[[ ! -e "$ROOT/forbidden" ]] || fail 'duplicate executed command'
expect 0 bounded "$HELPER" --verify "$ROOT" "$MARKER" "$SUBJECT"
expect 77 bounded "$HELPER" --verify "$ROOT" "$MARKER" "$$"
expect 77 bounded "$HELPER" --verify-preflight "$ROOT" "$MARKER" "$$"
expect 77 bounded "$HELPER" --verify-preflight "$ROOT" "$MARKER" "$SUBJECT"
IFS=: read -r version guardian child maj min inode <<<"$MARKER"
[[ "$version" == v1 && "$guardian" == "$GUARDIAN" && "$child" == "$SUBJECT" ]] || fail 'marker ABI'
# Coherent subject field, but that real subject is not this guardian's child.
expect 77 bounded "$HELPER" --verify "$ROOT" "v1:$guardian:$$:$maj:$min:$inode" "$$"
mkdir -m 0700 "$TMP_ROOT/unlocked"
unlocked_inode="$(stat -c %i "$TMP_ROOT/unlocked")"
expect 77 bounded "$HELPER" --verify "$TMP_ROOT/unlocked" "v1:$guardian:$child:$maj:$min:$unlocked_inode" "$child"
for forged in '' 'v2:1:2:3:4:5' "v1:$guardian:$child:$maj:$min:$((inode + 1))" \
  "v1:$guardian:$$:$maj:$min:$inode" "v1:$$:$child:$maj:$min:$inode" \
  "v1:$guardian:$child:$maj:$min:18446744073709551616" "$MARKER:extra" \
  "v1:-$guardian:$child:$maj:$min:$inode"; do
  expect 77 bounded "$HELPER" --verify "$ROOT" "$forged" "$SUBJECT"
done
cp "$HELPER" "$TMP_ROOT/different-executable"
expect 77 bounded "$TMP_ROOT/different-executable" --verify "$ROOT" "$MARKER" "$SUBJECT"

# Renames/replacements never turn an old marker into authority for a new root.
mv "$ROOT" "$ROOT.moved"
expect 77 bounded "$HELPER" --verify "$ROOT" "$MARKER" "$SUBJECT"
mkdir -m 0700 "$ROOT"
expect 77 bounded "$HELPER" --verify "$ROOT" "$MARKER" "$SUBJECT"
expect 75 bounded "$HELPER" --run "$ROOT.moved" -- /bin/true
rmdir "$ROOT"
mv "$ROOT.moved" "$ROOT"
expect 0 bounded "$HELPER" --verify "$ROOT" "$MARKER" "$SUBJECT"
finish_owner TERM 143
expect 77 bounded "$HELPER" --verify "$ROOT" "$MARKER" "$child"
expect 0 bounded "$HELPER" --run "$ROOT" -- /bin/true
expect 37 bounded "$HELPER" --run "$ROOT" -- /bin/sh -c 'exit 37'
expect 127 bounded "$HELPER" --run "$ROOT" -- "$TMP_ROOT/missing-command"
expect 126 bounded "$HELPER" --run "$ROOT" -- "$ROOT/sentinel"
expect 143 bounded "$HELPER" --run "$ROOT" -- /bin/sh -c 'kill -TERM $$'
start_owner; finish_owner HUP 129
start_owner; finish_owner KILL 137
expect 0 bounded "$HELPER" --run "$ROOT" -- /bin/true

# The launcher-to-BEAM exec chain must retain the child PID and parent-death
# link. This VM starts no Orchard role and loads no model or worker provider.
ELIXIR="$(command -v elixir)"
rm -f "$TMP_ROOT/ready"
"$HELPER" --run "$ROOT" -- "$ELIXIR" --erl '+S 2:2' -e '
  root = System.fetch_env!("ROOT")
  helper = System.fetch_env!("HELPER")
  marker = System.fetch_env!("ORCHARD_NODE_ROOT_GUARD")
  {_, 0} = System.cmd(helper, ["--verify", root, marker, System.pid()])
  File.write!(Path.join(System.fetch_env!("TMP_ROOT"), "ready"), System.pid())
  Process.sleep(:infinity)
' >"$TMP_ROOT/beam-out" 2>"$TMP_ROOT/beam-error" &
GUARDIAN=$!
await_file "$TMP_ROOT/ready"
SUBJECT="$(cat "$TMP_ROOT/ready")"
[[ "$(readlink "/proc/$SUBJECT/exe")" == */beam.smp ]] || fail 'guarded subject was not BEAM'
finish_owner KILL 137
expect 0 bounded "$HELPER" --run "$ROOT" -- /bin/true

# Real source/Application composition. Only the identity and launch readers are
# synthetic; the adapter uses its production System.cmd kernel-verifier runner.
export ORCHARD_NODE_PLATFORM_PROFILE=ubuntu_24_04_x86_64_node
export ORCHARD_NODE_IDENTITY_ROOT="$ROOT"
export ORCHARD_SOURCE_DEV_ROLE=node_agent ORCHARD_BEAM_PEER_GRANT_DESCRIPTOR=/fixture-descriptor
export FIXTURE_IDENTITY_READ="$TMP_ROOT/identity-read"
FIXTURE_SCRIPT="$REPO_ROOT/scripts/support/linux-node-source-guard-fixture.exs"
FIXTURE_VM="$TMP_ROOT/fixture-vm"
export FIXTURE_SCRIPT REPO_ROOT ELIXIR
cat > "$FIXTURE_VM" <<'STUB'
#!/usr/bin/env bash
exec "$ELIXIR" --erl '+S 2:2' -pa "$REPO_ROOT/_build/test/lib/*/ebin" "$FIXTURE_SCRIPT"
STUB
chmod +x "$FIXTURE_VM"
export FIXTURE_VM
rm -f "$FIXTURE_IDENTITY_READ"
expect 0 bounded env FIXTURE_MODE=application "$HELPER" --run "$ROOT" -- \
  "$FIXTURE_VM"
[[ -s "$FIXTURE_IDENTITY_READ" ]] || fail 'Application did not reach registered identity'
rm -f "$FIXTURE_IDENTITY_READ"
# shellcheck disable=SC2016
expect 0 bounded env FIXTURE_MODE=preflight "$HELPER" --run "$ROOT" -- /bin/bash -c \
  '"$FIXTURE_VM"; status=$?; exit "$status"'
[[ -s "$FIXTURE_IDENTITY_READ" ]] || fail 'preflight did not reach registered identity'
start_owner
rm -f "$FIXTURE_IDENTITY_READ"
expect 0 bounded env FIXTURE_MODE=refuse ORCHARD_NODE_ROOT_GUARD="$MARKER" \
  "$FIXTURE_VM"
expect 0 bounded env FIXTURE_MODE=refuse_preflight ORCHARD_NODE_ROOT_GUARD="$MARKER" \
  "$FIXTURE_VM"
finish_owner TERM 143

# Actual launcher stages and exec ordering with synthetic downstream bootstrap.
# The disposable copy changes ONLY the helper binding to the separately named
# fixture binary. No production-path binary or production bypass is created.
LAUNCH_REPO="$TMP_ROOT/launcher-repo"
mkdir -p "$LAUNCH_REPO/bin/lib" "$LAUNCH_REPO/apps/orchard_node_agent" \
  "$LAUNCH_REPO/.local/linux-node-root-guardian" "$TMP_ROOT/tools"
cp "$REPO_ROOT/bin/dev-node-agent" "$LAUNCH_REPO/bin/dev-node-agent"
cp "$REPO_ROOT/bin/lib/source-dev-worker-cleanup.sh" "$LAUNCH_REPO/bin/lib/"
sed 's@/orchard-node-root-guardian"@/orchard-node-root-guardian-test"@' \
  "$REPO_ROOT/bin/lib/source-node-startup.sh" > "$LAUNCH_REPO/bin/lib/source-node-startup.sh"
ln -s "$HELPER" "$LAUNCH_REPO/.local/linux-node-root-guardian/orchard-node-root-guardian-test"
touch "$LAUNCH_REPO/mix.exs"
cat > "$LAUNCH_REPO/bin/lib/source-dev-beam.sh" <<'STUB'
orchard_source_dev_beam_bootstrap() {
  printf 'bootstrap\n' >> "$LAUNCH_CALLS"
  export ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam
  ORCHARD_BEAM_IEX_ARGS=()
}
STUB
cat > "$TMP_ROOT/tools/mix" <<'STUB'
#!/usr/bin/env bash
printf 'preflight\n' >> "$LAUNCH_CALLS"
STUB
cat > "$TMP_ROOT/tools/iex" <<'STUB'
#!/usr/bin/env bash
exec "$ELIXIR" --erl '+S 2:2' -e '
  {_, 0} = System.cmd(System.fetch_env!("HELPER"), ["--verify",
    System.fetch_env!("ORCHARD_NODE_IDENTITY_ROOT"),
    System.fetch_env!("ORCHARD_NODE_ROOT_GUARD"), System.pid()])
  File.write!(System.fetch_env!("LAUNCH_READY"), System.pid())
  File.write!(System.fetch_env!("LAUNCH_MARKER"), System.fetch_env!("ORCHARD_NODE_ROOT_GUARD"))
  Process.sleep(:infinity)
'
STUB
chmod +x "$TMP_ROOT/tools/mix" "$TMP_ROOT/tools/iex"
export ELIXIR LAUNCH_CALLS="$TMP_ROOT/launch-calls" LAUNCH_READY="$TMP_ROOT/launch-ready" \
  LAUNCH_MARKER="$TMP_ROOT/launch-marker"
PATH="$TMP_ROOT/tools:$PATH" "$LAUNCH_REPO/bin/dev-node-agent" \
  >"$TMP_ROOT/launcher-out" 2>"$TMP_ROOT/launcher-error" &
GUARDIAN=$!
await_file "$LAUNCH_READY"
SUBJECT="$(cat "$LAUNCH_READY")"
MARKER="$(cat "$LAUNCH_MARKER")"
IFS=: read -r _version marker_guardian marker_child _major _minor _inode <<< "$MARKER"
[[ "$marker_guardian" == "$GUARDIAN" && "$marker_child" == "$SUBJECT" ]] || fail 'launcher lost PID'
[[ "$(cat "$LAUNCH_CALLS")" == $'preflight\nbootstrap' ]] || fail 'launcher stage ordering'
expect 75 bounded env PATH="$TMP_ROOT/tools:$PATH" "$LAUNCH_REPO/bin/dev-node-agent"
expect 77 bounded env PATH="$TMP_ROOT/tools:$PATH" ORCHARD_NODE_ROOT_GUARD="$MARKER" \
  "$LAUNCH_REPO/bin/dev-node-agent" --orchard-node-guarded
[[ "$(cat "$LAUNCH_CALLS")" == $'preflight\nbootstrap' ]] || fail 'refused launcher ran bootstrap'
finish_owner KILL 137
unset ORCHARD_NODE_PLATFORM_PROFILE ORCHARD_SOURCE_DEV_ROLE ORCHARD_BEAM_PEER_GRANT_DESCRIPTOR

# Mode, absent root, symlink leaf/ancestor, and lexical alias refusals.
for mode in 0755 0770 1700; do
  chmod "$mode" "$ROOT"
  expect 73 bounded "$HELPER" --run "$ROOT" -- /bin/true
done
chmod 0700 "$ROOT"
ln -s "$ROOT" "$TMP_ROOT/link"
ln -s "$TMP_ROOT" "$TMP_ROOT/ancestor-link"
for bad in relative "$TMP_ROOT/missing" "$TMP_ROOT/link" "$TMP_ROOT/ancestor-link/identity" \
  "$ROOT/../identity" "$ROOT/." "$ROOT/" "$TMP_ROOT//identity"; do
  expect 73 bounded "$HELPER" --run "$bad" -- /bin/true
done
mkdir -m 0777 "$TMP_ROOT/unsafe"
mkdir -m 0700 "$TMP_ROOT/unsafe/root"
expect 73 bounded "$HELPER" --run "$TMP_ROOT/unsafe/root" -- /bin/true
[[ ! -e "$TMP_ROOT/missing" ]] || fail 'guardian created root'

# A genuine flock held by a different executable is not guardian authority.
# Capture the foreign subject PID, not this shell.
# shellcheck disable=SC2016
flock --exclusive --nonblock "$ROOT" /bin/bash -c '
  printf "%s\n" "$$" >"$TMP_ROOT/foreign-ready"
  exec /bin/sleep 60
' &
GUARDIAN=$!
await_file "$TMP_ROOT/foreign-ready"
SUBJECT="$(cat "$TMP_ROOT/foreign-ready")"
foreign="v1:$GUARDIAN:$SUBJECT:$maj:$min:$inode"
expect 77 bounded "$HELPER" --verify "$ROOT" "$foreign" "$SUBJECT"
kill -TERM "$SUBJECT"
wait "$GUARDIAN" || true
GUARDIAN=""; SUBJECT=""

# Distinct roots intentionally do not enforce UUID/credential uniqueness.
cp -a "$ROOT" "$TMP_ROOT/clone"
start_owner
expect 0 bounded "$HELPER" --run "$TMP_ROOT/clone" -- /bin/true
finish_owner TERM 143

bash "$REPO_ROOT/scripts/build-linux-node-root-guardian.sh" --output "$TMP_ROOT/bin" >/dev/null
[[ -x "$PRODUCTION" && ! -e "$HELPER" ]] || fail 'production-only staging retained fixture'
printf 'PASS: Linux relocated-root process fixtures. Host/user/trust/Agent boot/native Worker release NOT qualified.\n'
printf 'NOT RUN: privileged bind-mount/second-UID host fixtures; full candidate source qualification.\n'
