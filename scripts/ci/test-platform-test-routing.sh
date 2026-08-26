#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  printf 'platform test routing failed: %s\n' "$1" >&2
  exit 1
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

printf 'platform test-routing tests passed\n'
