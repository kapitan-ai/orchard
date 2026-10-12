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
  chmod "${1:-0700}" "$root"
  printf '%s\n' "$root"
}

owner_of() {
  if [[ "$OS" == "Darwin" ]]; then stat -f %u "$1"; else stat -c %u "$1"; fi
}

inode_of() {
  if [[ "$OS" == "Darwin" ]]; then stat -f %i "$1"; else stat -c %i "$1"; fi
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

# Outer-blocked control: a 0700 support root alone denies the reader, so stage denials
# beneath it would prove nothing. The matrix below therefore uses searchable 0711 roots.
root="$(new_support_root 0700)"
printf 'control\n' >"$root/control-readable"
chmod 0644 "$root/control-readable"
expect_reader_denied cat "$root/control-readable"

# Under a searchable 0711 root the stage must deny the reader at every pause point, for every
# child umask, whether public/ is absent or an existing 0755 directory. Sibling controls in the
# same root prove the reader can traverse it and that a writable directory is attackable.
for public_state in absent existing; do
  points="after_stage_mkdir after_stage_write after_file_protect"
  if [[ "$public_state" == "absent" ]]; then points="$points before_public_rename"; fi
  for umask_value in 0022 0077 0002 0000; do
    for point in $points; do
      root="$(new_support_root 0711)"
      if [[ "$public_state" == "existing" ]]; then mkdir -m 0755 "$root/public"; fi
      printf 'control\n' >"$root/control-readable"
      chmod 0644 "$root/control-readable"
      mkdir -m 0700 "$root/control-unsafe-stage"
      chmod 0777 "$root/control-unsafe-stage"
      pauses="$RUN/pause.$public_state.$umask_value.$point"
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
      [[ -d "$stage" ]] || fail "stage missing at $public_state/$umask_value/$point"
      [[ "$(mode_of "$stage")" == "700" ]] ||
        fail "stage mode $(mode_of "$stage") at $public_state/$umask_value/$point"
      expect_reader_allowed cat "$root/control-readable"
      expect_reader_allowed touch "$root/control-unsafe-stage/foreign"
      expect_reader_allowed ls "$root/control-unsafe-stage"
      expect_reader_denied ls "$stage"
      expect_reader_denied cat "$stage/ca.crt"
      expect_reader_denied cat "$stage/endpoint.json"
      expect_reader_denied touch "$stage/foreign"
      expect_reader_denied mkdir "$stage/foreign-dir"
      expect_reader_denied chmod 0777 "$stage"
      expect_reader_denied touch "$root/foreign"
      if [[ "$public_state" == "existing" ]]; then
        expect_reader_allowed ls "$root/public"
        expect_reader_denied touch "$root/public/foreign"
      fi
      rm -rf "$root/control-readable" "$root/control-unsafe-stage"
      : > "$pauses/$point.go"
      wait "$helper_pid" || fail "helper failed after $point: $(cat "$pauses/out")"
      grep -qx 'OK PUBLISHED' "$pauses/out" || fail "unexpected helper output: $(cat "$pauses/out")"
      assert_public_profile "$root"
      [[ -z "$(find "$root" -maxdepth 1 -name '.orchard-public-stage-*' -print -quit)" ]] ||
        fail "stage residue after $public_state/$umask_value/$point"
    done
  done
done

# Retained-descriptor control (Linux /proc descriptor links): a reader that opened config/tls/
# while a legacy group-traversable layout let it reach that directory keeps the descriptor after
# config/ is narrowed to 0700. A directory born with a permissive mode beneath tls/ is attackable
# through it; one born beneath the private stage, where Transport runs TLS generation, is not.
if [[ "$OS" == "Linux" ]]; then
  root="$(new_support_root 0711)"
  mkdir -m 0750 "$root/config" "$root/config/tls"
  sudo -n chgrp "$(id -gn "$READER")" "$root/config" "$root/config/tls"
  chmod 0750 "$root/config" "$root/config/tls"
  sync_dir="$RUN/retained-tls"
  mkdir -m 0700 "$sync_dir"
  chmod 0777 "$sync_dir"
  # shellcheck disable=SC2016
  sudo -n -u "$READER" bash -c '
    exec 3<"$1"
    : >"$2/opened"
    until [[ -e "$2/narrowed" ]]; do sleep 0.01; done
    stage="$(cat "$2/stage")"
    result=""
    if ls "$1" >/dev/null 2>&1; then result+=" path-open"; else result+=" path-denied"; fi
    if cd /proc/self/fd/3 2>/dev/null && ls . >/dev/null 2>&1; then
      result+=" fd-open"
    else
      result+=" fd-denied"
    fi
    if touch .staging-legacy/foreign 2>/dev/null; then
      result+=" legacy-writable"
    else
      result+=" legacy-denied"
    fi
    if touch "../../$stage/.staging-probe/foreign" 2>/dev/null; then
      result+=" stage-relative-writable"
    else
      result+=" stage-relative-denied"
    fi
    if touch "$3/$stage/.staging-probe/foreign" 2>/dev/null; then
      result+=" stage-writable"
    else
      result+=" stage-denied"
    fi
    printf "%s\n" "$result" >"$2/result"
  ' _ "$root/config/tls" "$sync_dir" "$root" &
  holder_pid=$!
  await_file "$sync_dir/opened"
  chmod 0700 "$root/config"
  expect_reader_denied ls "$root/config/tls"
  pauses="$RUN/pause.retained-tls"
  mkdir -m 0700 "$pauses"
  (
    ORCHARD_TRANSPORT_PUBLISH_TEST_PAUSE_DIR="$pauses" \
      ORCHARD_TRANSPORT_PUBLISH_TEST_PAUSE=after_stage_mkdir \
      exec "$TEST_HELPER" --oneshot "$root" "$RUN/ca.in" "$RUN/endpoint.in"
  ) >"$pauses/out" &
  helper_pid=$!
  await_file "$pauses/after_stage_mkdir.ready"
  stage_name="$(head -n 1 "$pauses/after_stage_mkdir.ready")"
  (
    umask 0000
    mkdir "$root/$stage_name/.staging-probe" "$root/config/tls/.staging-legacy"
  )
  printf '%s\n' "$stage_name" >"$sync_dir/stage"
  : >"$sync_dir/narrowed"
  wait "$holder_pid" || fail 'retained-descriptor reader failed'
  result="$(cat "$sync_dir/result")"
  expected=" path-denied fd-open legacy-writable stage-relative-denied stage-denied"
  [[ "$result" == "$expected" ]] || fail "retained-descriptor control: '$result' (expected '$expected')"
  pass
  [[ -z "$(ls -A "$root/$stage_name/.staging-probe")" ]] || fail 'reader wrote into the private stage'
  rmdir "$root/$stage_name/.staging-probe"
  rm -rf "$root/config/tls/.staging-legacy"
  : >"$pauses/after_stage_mkdir.go"
  wait "$helper_pid" || fail "helper failed after retained-descriptor control: $(cat "$pauses/out")"
  grep -qx 'OK PUBLISHED' "$pauses/out" || fail "unexpected helper output: $(cat "$pauses/out")"
  pass
fi

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
mkdir -m 0700 "$root/config/tls"
printf 'private ca key\n' >"$root/config/tls/ca.key"
chmod 0600 "$root/config/tls/ca.key"
printf 'public ca cert\n' >"$root/config/tls/ca.crt"
sudo -n chown "$READER" "$root/config/tls/ca.key"
expect_refusal "unsafe_owner - tls_source ca.key" "$root"
sudo -n chown "$(id -u)" "$root/config/tls/ca.key"
[[ "$(cat "$root/config/tls/ca.key")" == 'private ca key' ]] || fail 'refused ca.key was modified'
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

# Root production protocol: drive the production helper's framed protocol through PREPARE,
# PUBLISH, and COMMIT, then PREPARE, PUBLISH, ROLLBACK, and COMMIT, on the qualified host
# filesystem that holds the fixture.
u32_bytes() {
  local n="$1"
  # shellcheck disable=SC2059
  printf "$(printf '\\%03o\\%03o\\%03o\\%03o' $(((n >> 24) & 255)) $(((n >> 16) & 255)) \
    $(((n >> 8) & 255)) $((n & 255)))"
}

byte_count() {
  wc -c <"$1" | tr -d ' '
}

# Named FIFOs on fixed descriptors keep the driver portable to Bash 3.2.
start_production() {
  rm -f "$RUN/to-helper" "$RUN/from-helper"
  mkfifo -m 0600 "$RUN/to-helper" "$RUN/from-helper"
  sudo -n "$PRODUCTION" --protocol 1 <"$RUN/to-helper" >"$RUN/from-helper" 2>"$RUN/production.err" &
  HELPER_PROCESS=$!
  exec 8>"$RUN/to-helper" 9<"$RUN/from-helper"
}

send_frame() {
  u32_bytes "$(byte_count "$1")" >&8
  cat "$1" >&8
}

recv_frame() {
  local b0 b1 b2 b3
  read -r b0 b1 b2 b3 < <(dd bs=1 count=4 2>/dev/null <&9 | od -An -tu1)
  [[ -n "${b3:-}" ]] || fail "production helper closed without a reply: $(cat "$RUN/production.err")"
  dd bs=1 count=$(((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)) 2>/dev/null <&9
}

request() {
  send_frame "$1"
  recv_frame >"$RUN/reply"
  REPLY_TEXT="$(cat "$RUN/reply")"
  [[ "$REPLY_TEXT" =~ $2 ]] || fail "production helper replied '$REPLY_TEXT' (expected $2)"
  pass
}

finish_production() {
  local status=0
  exec 8>&- 9<&-
  wait "$HELPER_PROCESS" || status=$?
  [[ "$status" == 0 ]] || fail "production helper exited $status: $(cat "$RUN/production.err")"
  pass
}

publish_frame() {
  {
    printf 'PUBLISH\n'
    u32_bytes "$(byte_count "$RUN/ca.in")"
    cat "$RUN/ca.in"
    u32_bytes "$(byte_count "$1")"
    cat "$1"
  } >"$RUN/publish.frame"
  printf '%s\n' "$RUN/publish.frame"
}

expect_reader_content() {
  sudo -n -u "$READER" cat "$1" | cmp -s - "$2" || fail "reader content mismatch: $1"
  pass
}

support="$ROOT_FIXTURE/support"
printf 'PREPARE\n%s' "$support" >"$RUN/prepare.frame"
printf 'COMMIT' >"$RUN/commit.frame"
printf 'ROLLBACK' >"$RUN/rollback.frame"
printf '{"schema_version":1,"next":true}\n' >"$RUN/endpoint-next.in"

start_production
request "$RUN/prepare.frame" '^OK PREPARED absent absent \.orchard-public-stage-[A-Za-z0-9]+$'
stage="${REPLY_TEXT##* }"
[[ "$(sudo -n stat -c %a "$support/$stage" 2>/dev/null || sudo -n stat -f %Lp "$support/$stage")" == 700 ]] ||
  fail 'production stage is not 0700'
pass
request "$(publish_frame "$RUN/endpoint.in")" '^OK PUBLISHED$'
assert_public_profile "$support"
for path in "$support" "$support/public" "$support/public/ca.crt" "$support/public/endpoint.json"; do
  [[ "$(owner_of "$path")" == 0 ]] || fail "production publication is not root-owned: $path"
done
pass
expect_reader_content "$support/public/ca.crt" "$RUN/ca.in"
expect_reader_content "$support/public/endpoint.json" "$RUN/endpoint.in"
request "$RUN/commit.frame" '^OK COMMITTED$'
finish_production

start_production
request "$RUN/prepare.frame" '^OK PREPARED existing existing \.orchard-public-stage-[A-Za-z0-9]+$'
request "$(publish_frame "$RUN/endpoint-next.in")" '^OK PUBLISHED$'
expect_reader_content "$support/public/endpoint.json" "$RUN/endpoint-next.in"
published_inode="$(inode_of "$support/public/endpoint.json")"
request "$RUN/rollback.frame" '^OK ROLLED_BACK$'
expect_reader_content "$support/public/endpoint.json" "$RUN/endpoint.in"
[[ "$(inode_of "$support/public/endpoint.json")" != "$published_inode" ]] ||
  fail 'rollback reused the published endpoint inode'
pass
request "$RUN/commit.frame" '^OK COMMITTED$'
finish_production
assert_public_profile "$support"
expect_reader_content "$support/public/ca.crt" "$RUN/ca.in"
[[ -z "$(sudo -n find "$support" -maxdepth 1 -name '.orchard-public-stage-*' -print -quit)" ]] ||
  fail 'production protocol left stage residue'
pass

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
