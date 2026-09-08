#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-process-snapshot.XXXXXX")"
HARNESS="$TMP_ROOT/lifecycle-process-snapshot-harness"
BEAM_FIXTURE="$TMP_ROOT/beam.smp"
COVERAGE=0
FAILURES=0
SOURCE="$REPO_ROOT/packaging/macos/native_helpers/orchard_lifecycle_helper.c"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'lifecycle process snapshot test failed: %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
  --cover)
    COVERAGE=1
    shift
    ;;
  --source)
    if [[ "$#" -lt 2 ]]; then
      printf 'usage: %s [--cover] [--source PATH]\n' "$0" >&2
      exit 64
    fi
    SOURCE="$2"
    shift 2
    ;;
  *)
    printf 'usage: %s [--cover] [--source PATH]\n' "$0" >&2
    exit 64
    ;;
  esac
done
if [[ ! -f "$SOURCE" ]]; then
  printf 'lifecycle process snapshot source is missing: %s\n' "$SOURCE" >&2
  exit 66
fi

COMPILE_FLAGS=(-std=c11 -Wall -Wextra -Werror -pedantic)
COMPILE_FLAGS+=("-DORCHARD_LIFECYCLE_HELPER_SOURCE=\"$SOURCE\"")
if [[ "$COVERAGE" -eq 1 ]]; then
  COMPILE_FLAGS+=(-fprofile-instr-generate -fcoverage-mapping)
fi

xcrun clang "${COMPILE_FLAGS[@]}" \
  "$REPO_ROOT/apps/orchard_cli/test/support/lifecycle_process_snapshot_harness.c" \
  -o "$HARNESS"
printf '#!/bin/sh\nexit 0\n' >"$BEAM_FIXTURE"
chmod 0755 "$BEAM_FIXTURE"

run_case() {
  local scenario="$1"
  local expected_status="$2"
  local output_kind="$3"
  local stdout_file="$TMP_ROOT/$scenario.stdout"
  local stderr_file="$TMP_ROOT/$scenario.stderr"
  local status

  set +e
  if [[ "$COVERAGE" -eq 1 ]]; then
    LLVM_PROFILE_FILE="$TMP_ROOT/$scenario.profraw" \
      "$HARNESS" "$scenario" "$BEAM_FIXTURE" \
      >"$stdout_file" 2>"$stderr_file"
    status=$?
  else
    "$HARNESS" "$scenario" "$BEAM_FIXTURE" \
      >"$stdout_file" 2>"$stderr_file"
    status=$?
  fi
  set -e

  if [[ "$status" -ne "$expected_status" ]]; then
    fail "$scenario exited $status, expected $expected_status; stderr: $(tr '\n' ' ' <"$stderr_file")"
    return
  fi

  case "$output_kind" in
  empty)
    if [[ "$(cat "$stdout_file")" != "[]" ]]; then
      fail "$scenario emitted unexpected stdout: $(tr '\n' ' ' <"$stdout_file")"
    elif [[ -s "$stderr_file" ]]; then
      fail "$scenario emitted unexpected stderr: $(tr '\n' ' ' <"$stderr_file")"
    fi
    ;;
  failure)
    if ! grep -Fq 'snapshot_failed' "$stderr_file"; then
      fail "$scenario did not emit a bounded snapshot failure diagnostic"
    fi
    ;;
  identity)
    local device inode expected expected_pid
    device="$(stat -f '%d' "$BEAM_FIXTURE")"
    inode="$(stat -f '%i' "$BEAM_FIXTURE")"
    expected_pid=4242
    if [[ "$scenario" == "inaccessible-then-expected-beam" ]]; then
      expected_pid=4343
    fi
    expected="[{\"pid\":$expected_pid,\"start_sec\":1700000000,\"start_usec\":123456,\"device\":$device,\"inode\":$inode,\"executable\":\"$BEAM_FIXTURE\"}]"
    if [[ "$(cat "$stdout_file")" != "$expected" ]]; then
      fail "$scenario did not preserve the expected BEAM identity"
    elif [[ -s "$stderr_file" ]]; then
      fail "$scenario emitted unexpected stderr: $(tr '\n' ' ' <"$stderr_file")"
    fi
    ;;
  *)
    fail "$scenario has unknown output assertion $output_kind"
    ;;
  esac
}

run_case fallback-nonbeam 0 empty
run_case fallback-permission-nonbeam 0 empty
run_case fallback-beam 74 failure
run_case fallback-empty-name 74 failure
run_case fallback-unterminated-name 74 failure
run_case fallback-denied 74 failure
run_case fallback-gone 0 empty
run_case fallback-zero-size 0 empty
run_case fallback-truncated 74 failure
run_case fallback-pid-mismatch 74 failure
run_case expected-fallback-denied 74 failure
run_case expected-fallback-nonbeam 74 failure
run_case positive-expected-beam 0 identity
run_case inaccessible-then-expected-beam 0 identity

if [[ "$COVERAGE" -eq 1 ]]; then
  LLVM_PROFDATA="$(xcrun --find llvm-profdata)"
  LLVM_COV="$(xcrun --find llvm-cov)"
  "$LLVM_PROFDATA" merge -sparse "$TMP_ROOT"/*.profraw \
    -o "$TMP_ROOT/snapshot.profdata"
  printf 'lifecycle snapshot function coverage:\n'
  coverage_report="$(
    "$LLVM_COV" report "$HARNESS" \
      -instr-profile="$TMP_ROOT/snapshot.profdata" \
      -show-functions \
      -sources "$SOURCE"
  )"
  for function in command_snapshot snapshot_error; do
    if ! grep -Fq ":$function " <<<"$coverage_report"; then
      fail "LLVM coverage omitted $function"
    fi
  done
  if grep -Fq 'can_exclude_unresolved_process' "$SOURCE" &&
    ! grep -Fq ':can_exclude_unresolved_process ' <<<"$coverage_report"; then
    fail 'LLVM coverage omitted can_exclude_unresolved_process'
  fi
  awk 'NR <= 3 || /:can_exclude_unresolved_process / || /:command_snapshot / || /:snapshot_error / || /^TOTAL/' \
    <<<"$coverage_report"
fi

if [[ "$FAILURES" -ne 0 ]]; then
  printf 'lifecycle process snapshot test failed with %d scenario(s)\n' \
    "$FAILURES" >&2
  exit 1
fi

printf 'lifecycle process snapshot test passed\n'
