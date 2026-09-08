#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/required-validation.yml"
PEER_GRANT_TEST="$ROOT/apps/orchard_controller/test/orchard/beam_peer_grants_test.exs"
LINUX_PORTABLE_TEST="$ROOT/scripts/test-linux-portable-core.sh"
PORTABLE_HELPER_FIXTURES=(
  "$ROOT/apps/orchard_controller/test/orchard/tokenizer_client_test.exs"
  "$ROOT/apps/orchard_controller/test/orchard/models/bundle_builder_test.exs"
  "$ROOT/apps/orchard_controller/test/orchard/models/safe_tokenization_preflight_test.exs"
)

fail() {
  printf 'platform test routing failed: %s\n' "$1" >&2
  exit 1
}

if ! awk '
  function check_mise_step() {
    if (!mise_step) return
    count++
    if (version !~ /^[0-9][0-9][0-9][0-9]\.[0-9]+\.[0-9]+$/) invalid = 1
    if (count == 1) bootstrap_version = version
    if (version != bootstrap_version) invalid = 1
  }
  /^      - / {
    check_mise_step()
    mise_step = 0
    version = ""
  }
  /uses: jdx\/mise-action@/ { mise_step = 1 }
  /^          version:/ {
    version = $2
    gsub(/["\047]/, "", version)
  }
  END {
    check_mise_step()
    exit invalid || count == 0
  }
' "$WORKFLOW"; then
  fail 'every mise-action step must pin the same explicit bootstrap version'
fi

line_number() {
  local content="$1"
  local pattern="$2"

  awk -v pattern="$pattern" 'index($0, pattern) { print NR; exit }' <<<"$content"
}

assert_precedes() {
  local content="$1"
  local before="$2"
  local after="$3"
  local before_line
  local after_line

  before_line="$(line_number "$content" "$before")"
  after_line="$(line_number "$content" "$after")"

  [[ -n "$before_line" && -n "$after_line" && "$before_line" -lt "$after_line" ]] ||
    fail "expected '$before' before '$after'"
}

darwin_test_plan="$(make --no-print-directory -n -C "$ROOT" HOST_OS=Darwin test)"
linux_test_plan="$(make --no-print-directory -n -C "$ROOT" HOST_OS=Linux test)"
darwin_cover_plan="$(make --no-print-directory -n -C "$ROOT" HOST_OS=Darwin cover)"
linux_cover_plan="$(make --no-print-directory -n -C "$ROOT" HOST_OS=Linux cover)"

grep -Fq 'build-macos-native-helpers.sh' <<<"$darwin_test_plan" ||
  fail 'Darwin test plan did not stage macOS native helpers'
grep -Fq 'build-macos-native-helpers.sh' <<<"$darwin_cover_plan" ||
  fail 'Darwin coverage plan did not stage macOS native helpers'
grep -Fq 'mix test' <<<"$darwin_test_plan" || fail 'Darwin test plan did not run Mix tests'
grep -Fq 'mix test --cover' <<<"$darwin_cover_plan" ||
  fail 'Darwin coverage plan did not run Mix coverage'
grep -Fq -- '--exclude macos' <<<"$darwin_test_plan" &&
  fail 'Darwin test plan excluded macOS-tagged tests'
grep -Fq -- '--exclude macos' <<<"$darwin_cover_plan" &&
  fail 'Darwin coverage plan excluded macOS-tagged tests'

grep -Fq 'build-macos-native-helpers.sh' <<<"$linux_test_plan" &&
  fail 'Linux test plan attempted to stage Darwin helpers'
grep -Fq 'build-macos-native-helpers.sh' <<<"$linux_cover_plan" &&
  fail 'Linux coverage plan attempted to stage Darwin helpers'
grep -Fq 'mix test --exclude macos' <<<"$linux_test_plan" ||
  fail 'Linux test plan did not exclude macOS-tagged tests'
grep -Fq 'mix test --cover --exclude macos' <<<"$linux_cover_plan" ||
  fail 'Linux coverage plan did not exclude macOS-tagged tests'

peer_grant_case="$(grep -B 2 -F 'Node retrieves and stores a grant over a real mTLS control stream' "$PEER_GRANT_TEST")"
grep -Fq '@tag :macos' <<<"$peer_grant_case" ||
  fail 'Darwin lockf-backed peer-grant case was not tagged for macOS routing'

for fixture in "${PORTABLE_HELPER_FIXTURES[@]}"; do
  stat_probe="$(grep -F 'stat -c' "$fixture" | grep -F 'stat -f' | head -n 1)"
  [[ "$stat_probe" == *"stat -c '%a'"*"stat -f '%Lp'"* ]] ||
    fail "portable helper fixture did not probe GNU stat before BSD stat: $fixture"
done

macos_host_job="$(
  awk '
    /^  macos-host:/ { capture = 1 }
    capture && /^  [a-zA-Z0-9_-]+:/ && $0 !~ /^  macos-host:/ { exit }
    capture { print }
  ' "$WORKFLOW"
)"

assert_precedes "$macos_host_job" 'brew install postgresql@16' 'mise exec -- mix test --only macos'
assert_precedes "$macos_host_job" 'pg_isready' 'mise exec -- mix test --only macos'
assert_precedes "$macos_host_job" 'MIX_ENV=test mise exec -- mix ecto.create' 'mise exec -- mix test --only macos'
assert_precedes "$macos_host_job" 'MIX_ENV=test mise exec -- mix ecto.migrate' 'mise exec -- mix test --only macos'
assert_precedes "$macos_host_job" 'Run portable helper transport tests on BSD stat' 'mise exec -- mix test --only macos'

host_stub_dir="$(mktemp -d)"
host_stub_marker="$host_stub_dir/mise-called"
trap 'rm -rf "$host_stub_dir"' EXIT

printf '#!/bin/sh\nprintf "FreeBSD\\n"\n' >"$host_stub_dir/uname"
printf '#!/bin/sh\ntouch "$ORCHARD_TEST_MISE_MARKER"\nexit 99\n' >"$host_stub_dir/mise"
chmod +x "$host_stub_dir/uname" "$host_stub_dir/mise"

host_guard_status=0
ORCHARD_TEST_MISE_MARKER="$host_stub_marker" PATH="$host_stub_dir:$PATH" \
  "$LINUX_PORTABLE_TEST" >/dev/null 2>&1 || host_guard_status=$?

[[ "$host_guard_status" -eq 69 ]] ||
  fail "Linux portable test accepted FreeBSD host (status $host_guard_status)"
[[ ! -e "$host_stub_marker" ]] ||
  fail 'Linux portable test invoked mise on FreeBSD host'

printf 'platform test-routing tests passed\n'
