#!/usr/bin/env bash
# Second-UID validation for orchard-transport-publish (SPEC.md §10.7, ADR 0036).
# Requires passwordless `sudo -n` and the `nobody` account; it changes no sudoers,
# users, mounts, or grants and works only inside a disposable fixture tree.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OS="$(uname -s)"
READER="nobody"
ROOT_FIXTURE=""
RUN=""
CHECKS=0

fail() {
  printf 'transport publication second-UID test failed: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  if [[ -n "$ROOT_FIXTURE" ]]; then sudo -n rm -rf "$ROOT_FIXTURE"; fi
  if [[ -n "$RUN" ]]; then rm -rf "$RUN"; fi
}
trap cleanup EXIT INT TERM

case "$OS" in
  Darwin) BASE="/private/tmp" ;;
  Linux) BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)" ;;
  *) fail "unsupported host: $OS" ;;
esac

sudo -n true 2>/dev/null || fail 'passwordless sudo -n is required'
id "$READER" >/dev/null 2>&1 || fail "reader account is missing: $READER"

mode_of() {
  if [[ "$OS" == "Darwin" ]]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

pass() {
  CHECKS=$((CHECKS + 1))
}

as_reader() {
  sudo -n -u "$READER" "$@" >/dev/null 2>&1
}

expect_reader_denied() {
  if as_reader "$@"; then fail "reader unexpectedly succeeded: $*"; fi
  pass
}

expect_reader_allowed() {
  as_reader "$@" || fail "reader was denied: $*"
  pass
}

RUN="$(mktemp -d "$BASE/orchard-transport-uid.XXXXXX")"
chmod 0711 "$RUN"
HELPERS="$RUN/helpers"
mkdir -m 0755 "$HELPERS"
if [[ "$OS" == "Darwin" ]]; then
  "$REPO_ROOT/scripts/build-macos-native-helpers.sh" --output "$HELPERS" --include-test-helper >/dev/null
else
  "$REPO_ROOT/scripts/build-linux-native-helpers.sh" --output "$HELPERS" --include-test-helper >/dev/null
fi
PRODUCTION="$HELPERS/orchard-transport-publish"
TEST_HELPER="$HELPERS/orchard-transport-publish-test"

printf -- '-----BEGIN CERTIFICATE-----\nlocal ca\n-----END CERTIFICATE-----\n' > "$RUN/ca.in"
printf '{"schema_version":1}\n' > "$RUN/endpoint.in"
chmod 0644 "$RUN/ca.in" "$RUN/endpoint.in"

new_support_root() {
  local root
  root="$(mktemp -d "$RUN/support.XXXXXX")"
  chmod 0700 "$root"
  printf '%s\n' "$root"
}

await_file() {
  local path="$1"
  for _ in $(seq 1 1000); do
    [[ -e "$path" ]] && return 0
    sleep 0.01
  done
  fail "timed out waiting for $path"
}

assert_public_profile() {
  local root="$1"
  [[ "$(mode_of "$root")" == "711" ]] || fail "support root mode $(mode_of "$root")"
  [[ "$(mode_of "$root/public")" == "755" ]] || fail "public mode $(mode_of "$root/public")"
  [[ "$(mode_of "$root/public/ca.crt")" == "644" ]] || fail 'ca.crt mode'
  [[ "$(mode_of "$root/public/endpoint.json")" == "644" ]] || fail 'endpoint.json mode'
  expect_reader_allowed cat "$root/public/ca.crt"
  expect_reader_allowed cat "$root/public/endpoint.json"
  expect_reader_allowed ls "$root/public"
  expect_reader_denied ls "$root"
  expect_reader_denied touch "$root/public/foreign"
  expect_reader_denied touch "$root/foreign"
  expect_reader_denied chmod 0777 "$root/public"
}

# The stage must deny the reader at every pause point for every child umask.
for umask_value in 0022 0077 0002 0000; do
  for point in after_stage_mkdir after_stage_write after_file_protect; do
    root="$(new_support_root)"
    pauses="$RUN/pause.$umask_value.$point"
    mkdir -m 0700 "$pauses"
    (
      umask "$umask_value"
      ORCHARD_TRANSPORT_PUBLISH_TEST_PAUSE_DIR="$pauses" \
        ORCHARD_TRANSPORT_PUBLISH_TEST_PAUSE="$point" \
        exec "$TEST_HELPER" --oneshot "$root" "$RUN/ca.in" "$RUN/endpoint.in"
    ) > "$pauses/out" &
    helper_pid=$!
    await_file "$pauses/$point.ready"
    stage="$root/$(head -n 1 "$pauses/$point.ready")"
    [[ -d "$stage" ]] || fail "stage missing at $point"
    [[ "$(mode_of "$stage")" == "700" ]] || fail "stage mode $(mode_of "$stage") at $point"
    expect_reader_denied ls "$stage"
    expect_reader_denied cat "$stage/ca.crt"
    expect_reader_denied cat "$stage/endpoint.json"
    expect_reader_denied touch "$stage/foreign"
    expect_reader_denied mkdir "$stage/foreign-dir"
    : > "$pauses/$point.go"
    wait "$helper_pid" || fail "helper failed after $point: $(cat "$pauses/out")"
    grep -qx 'OK PUBLISHED' "$pauses/out" || fail "unexpected helper output: $(cat "$pauses/out")"
    assert_public_profile "$root"
    [[ -z "$(find "$root" -maxdepth 1 -name '.orchard-public-stage-*' -print -quit)" ]] ||
      fail "stage residue after $point"
  done
done

# Sends one PREPARE frame to a protocol-mode helper and prints its reply text.
prepare_once() {
  local helper="$1"
  local root="$2"
  local frame="PREPARE
$root"
  local length=${#frame}
  local reply

  ((length < 256)) || fail "fixture path too long: $root"
  reply="$({ printf '\000\000\000'"$(printf '\\%03o' "$length")"'%s' "$frame"; } |
    "$helper" --protocol 1 | tail -c +5)"
  printf '%s\n' "$reply"
  [[ "$reply" == OK* ]]
}

expect_refusal() {
  local expected="$1"
  local root="$2"
  local helper="${3:-$TEST_HELPER}"
  local output

  if output="$("$helper" --oneshot "$root" "$RUN/ca.in" "$RUN/endpoint.in" 2>&1)"; then
    fail "expected refusal '$expected' but helper published: $root"
  fi
  [[ "$output" == "ERR $expected"* ]] || fail "expected 'ERR $expected', got: $output"
  [[ -z "$(find "$root" -maxdepth 1 -name '.orchard-public-stage-*' -print -quit)" ]] ||
    fail "refusal '$expected' created a stage"
  pass
}

# Real ACLs refuse, including benign ones.
root="$(new_support_root)"
mkdir -m 0755 "$root/public"
if [[ "$OS" == "Darwin" ]]; then
  chmod +a "$READER allow add_file" "$root/public"
  expect_refusal "acl_present - public" "$root"
  chmod -N "$root/public"
  chmod +a "everyone deny delete" "$root"
  expect_refusal "acl_present - support_root" "$root"
  chmod -N "$root"
else
  command -v setfacl >/dev/null 2>&1 || fail 'setfacl is required (install the acl package)'
  setfacl -m "u:$READER:rx" "$root/public"
  expect_refusal "acl_present - public" "$root"
  setfacl -b "$root/public"
  setfacl -d -m "u:$READER:r" "$root"
  expect_refusal "acl_present - support_root" "$root"
  setfacl -b "$root"
fi
"$TEST_HELPER" --oneshot "$root" "$RUN/ca.in" "$RUN/endpoint.in" >/dev/null ||
  fail 'publication failed after ACL removal'
pass

# Private config custody: ACL-bearing config and foreign-owned controller.env refuse.
root="$(new_support_root)"
mkdir -m 0700 "$root/config"
printf 'SECRET_KEY_BASE="fixture"\n' >"$root/config/controller.env"
chmod 0600 "$root/config/controller.env"
if [[ "$OS" == "Darwin" ]]; then
  chmod +a "$READER allow list" "$root/config"
  expect_refusal "acl_present - config" "$root"
  chmod -N "$root/config"
else
  setfacl -m "u:$READER:---" "$root/config"
  expect_refusal "acl_present - config" "$root"
  setfacl -b "$root/config"
fi
sudo -n chown "$READER" "$root/config/controller.env"
expect_refusal "unsafe_owner - controller_env controller.env" "$root"
sudo -n chown "$(id -u)" "$root/config/controller.env"
[[ "$(cat "$root/config/controller.env")" == 'SECRET_KEY_BASE="fixture"' ]] ||
  fail 'refused controller.env was modified'
pass
"$TEST_HELPER" --oneshot "$root" "$RUN/ca.in" "$RUN/endpoint.in" >/dev/null ||
  fail 'publication failed with a private config directory'
expect_reader_denied ls "$root/config"
expect_reader_denied cat "$root/config/controller.env"
assert_public_profile "$root"

# A support root under a reader-owned ancestor refuses.
foreign="$(sudo -n -u "$READER" mktemp -d "$BASE/orchard-transport-foreign.XXXXXX")"
sudo -n chmod 0755 "$foreign"
if output="$("$TEST_HELPER" --oneshot "$foreign/support" "$RUN/ca.in" "$RUN/endpoint.in" 2>&1)"; then
  sudo -n rm -rf "$foreign"
  fail 'reader-owned ancestor was accepted'
fi
sudo -n rm -rf "$foreign"
[[ "$output" == "ERR unsafe_owner - ancestor"* ]] || fail "reader-owned ancestor: $output"
pass

# Root-owned custody: the root publisher refuses caller-owned ancestry and publishes under root.
root="$(new_support_root)"
if output="$(sudo -n "$TEST_HELPER" --oneshot "$root" "$RUN/ca.in" "$RUN/endpoint.in" 2>&1)"; then
  fail 'root publisher accepted a non-root-owned support root'
fi
[[ "$output" == "ERR unsafe_owner - ancestor $RUN"* ]] || fail "root custody: $output"
pass
ROOT_FIXTURE="$(sudo -n mktemp -d "$BASE/orchard-transport-root.XXXXXX")"
sudo -n chmod 0755 "$ROOT_FIXTURE"
sudo -n mkdir -m 0700 "$ROOT_FIXTURE/support"
sudo -n "$PRODUCTION" --protocol 1 </dev/null || fail 'production helper rejected an idle session'
sudo -n "$TEST_HELPER" --oneshot "$ROOT_FIXTURE/support" "$RUN/ca.in" "$RUN/endpoint.in" >/dev/null ||
  fail 'root publication failed'
assert_public_profile "$ROOT_FIXTURE/support"

# Linux production qualification excludes tmpfs; only the test helper accepts it.
if [[ "$OS" == "Linux" ]]; then
  if [[ "$(stat -f -c %T /dev/shm 2>/dev/null)" == "tmpfs" ]]; then
    shm="$(mktemp -d /dev/shm/orchard-transport-uid.XXXXXX)"
    chmod 0700 "$shm"
    if output="$(prepare_once "$PRODUCTION" "$shm")"; then
      rm -rf "$shm"
      fail 'production helper accepted tmpfs'
    fi
    [[ "$output" == "ERR filesystem_unqualified - support_root"* ]] ||
      { rm -rf "$shm"; fail "production tmpfs refusal: $output"; }
    "$TEST_HELPER" --oneshot "$shm" "$RUN/ca.in" "$RUN/endpoint.in" >/dev/null ||
      { rm -rf "$shm"; fail 'test helper rejected tmpfs'; }
    rm -rf "$shm"
    pass
  else
    printf 'transport publication second-UID test: /dev/shm is not tmpfs; tmpfs refusal not exercised\n'
  fi
fi

printf 'transport publication second-UID test passed (%s checks, %s)\n' "$CHECKS" "$OS"
