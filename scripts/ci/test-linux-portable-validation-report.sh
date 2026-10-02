#!/usr/bin/env bash
#
# Tests the Linux portable lane script and its bounded validation report
# (docs/tooling.md, openspec portability-validation "Linux Portable
# Validation Reporting"). Disposable `uname` and `mise` stubs record the exact
# argv of every lane command, so no toolchain, database, or Linux host is used.
#
# Set ORCHARD_TEST_BASH=/bin/bash to run the lane script and report helper
# under another bash (for example macOS bash 3.2).
#
# shellcheck disable=SC2016 # Workflow assertions match literal ${{ }} expressions.

set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/test-linux-portable-core.sh"
HELPER="$ROOT/scripts/ci/linux-portable-validation-report.sh"
WORKFLOW="$ROOT/.github/workflows/required-validation.yml"
TEST_BASH="${ORCHARD_TEST_BASH:-bash}"

# The interrupt cases need SIGINT to be trappable. A shell that starts with
# SIGINT ignored (for example a job backgrounded by a non-interactive shell)
# cannot trap it, so refuse instead of reporting a misleading failure.
if [[ "$(trap -p INT)" == *"''"* ]]; then
  printf 'linux portable validation report test: SIGINT is ignored here; run this proof in the foreground\n' >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-portable-report-test.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT INT TERM

STUB_BIN="$TMP_ROOT/bin"
FIXTURES="$TMP_ROOT/fixtures"
mkdir -p "$STUB_BIN" "$FIXTURES"

fail() {
  printf 'linux portable validation report test failed: %s\n' "$1" >&2
  exit 1
}

cat > "$STUB_BIN/uname" <<'EOF'
#!/bin/sh
printf '%s\n' "${ORCHARD_STUB_UNAME-Linux}"
EOF

# Records argv as [arg][arg]..., replays per-call fixtures, then fails or
# signals the lane script at the configured call number.
cat > "$STUB_BIN/mise" <<'EOF'
#!/bin/sh
{ for arg in "$@"; do printf '[%s]' "$arg"; done; printf '\n'; } >> "$ORCHARD_STUB_LOG"
call=$(wc -l < "$ORCHARD_STUB_LOG" | tr -d ' ')
fixtures="${ORCHARD_STUB_FIXTURES:-/nonexistent}"
if [ -f "$fixtures/$call.out" ]; then cat "$fixtures/$call.out"; fi
if [ -f "$fixtures/$call.err" ]; then cat "$fixtures/$call.err" >&2; fi
if [ "${ORCHARD_STUB_SIGNAL_AT:-}" = "$call" ]; then
  kill -s "$ORCHARD_STUB_SIGNAL" "$PPID"
  exit 0
fi
if [ "${ORCHARD_STUB_FAIL_AT:-}" = "$call" ]; then exit "$ORCHARD_STUB_FAIL_STATUS"; fi
exit 0
EOF
chmod +x "$STUB_BIN/uname" "$STUB_BIN/mise"
if [[ "$TEST_BASH" != bash ]]; then
  ln -s "$TEST_BASH" "$STUB_BIN/bash"
fi

EXPECTED_ARGV="$TMP_ROOT/expected-argv"
cat > "$EXPECTED_ARGV" <<'EOF'
[exec][--][mix][test][--exclude][integration][--exclude][macos][--exclude][mlx_smoke][--exclude][mlx_benchmark]
[exec][--][mix][test][--cover][--exclude][integration][--exclude][macos][--exclude][mlx_smoke][--exclude][mlx_benchmark]
[exec][--][uv][run][--locked][--directory][native/orchard_tokenizer][ruff][format][--check]
[exec][--][uv][run][--locked][--directory][native/orchard_tokenizer][ruff][check]
[exec][--][uv][run][--locked][--directory][native/orchard_tokenizer][pytest]
[exec][--][uv][run][--locked][--directory][native/orchard_tokenizer][pytest][--cov]
[exec][--][uv][run][--locked][--directory][native/orchard_worker_mlx][ruff][format][--check]
[exec][--][uv][run][--locked][--directory][native/orchard_worker_mlx][ruff][check]
[exec][--][uv][run][--locked][--directory][native/orchard_worker_mlx][pytest][tests/test_backends.py][tests/test_service.py]
[exec][--][uv][run][--locked][--directory][native/orchard_worker_mlx][pytest][--cov=orchard_worker_mlx][tests/test_backends.py][tests/test_service.py]
EOF

# Success-path fixtures shaped like real Elixir 1.20 ExUnit, Mix cover,
# ExCoveralls, Ruff, and pytest -q output.
cat > "$FIXTURES/1.out" <<'EOF'
==> orchard_shared
Running ExUnit with seed: 424242, max_cases: 8
Excluding tags: [:integration, :macos, :mlx_smoke, :mlx_benchmark]

....
Finished in 0.4 seconds (0.3s async, 0.1s sync)

Result: 4 passed (4 tests), 2 excluded
==> orchard_controller
Running ExUnit with seed: 424242, max_cases: 8
Excluding tags: [:integration, :macos, :mlx_smoke, :mlx_benchmark]

............
Finished in 3.1 seconds (2.0s async, 1.1s sync)

Result: 12 passed (1 doctest, 11 tests)
EOF
{
  cat "$FIXTURES/1.out"
  cat <<'EOF'
Generating cover results ...

| Percentage | Module     |
|------------|------------|
|     91.20% | Total      |
----------------
COV    FILE                                        LINES RELEVANT   MISSED
[TOTAL]  87.3%
----------------
EOF
} > "$FIXTURES/2.out"
printf '42 files already formatted\n' > "$FIXTURES/3.out"
printf 'All checks passed!\n' > "$FIXTURES/4.out"
printf '........\n12 passed in 0.50s\n' > "$FIXTURES/5.out"
printf 'Name  Stmts  Miss  Cover\nTOTAL   120      6    95%%\n12 passed in 0.61s\n' > "$FIXTURES/6.out"
printf '17 files already formatted\n' > "$FIXTURES/7.out"
printf 'All checks passed!\n' > "$FIXTURES/8.out"
printf '30 passed, 2 skipped in 1.20s\n' > "$FIXTURES/9.out"
printf 'TOTAL   300     30    90%%\n30 passed, 2 skipped in 1.31s\n' > "$FIXTURES/10.out"
printf 'stderr passthrough from call 1\n' > "$FIXTURES/1.err"

# Runs the lane script in CASE_DIR. Remaining arguments are extra `env`
# assignments. Sets RUN_STATUS.
run_lane() {
  local case_dir="$1"
  shift

  mkdir -p "$case_dir/tmp"
  : > "$case_dir/argv.log"
  RUN_STATUS=0
  (
    cd "$case_dir"
    env -u ORCHARD_LINUX_PORTABLE_REPORT_DIR PATH="$STUB_BIN:$PATH" TMPDIR="$case_dir/tmp" \
      ORCHARD_STUB_LOG="$case_dir/argv.log" "$@" "$TEST_BASH" "$SCRIPT"
  ) > "$case_dir/stdout" 2> "$case_dir/stderr" || RUN_STATUS=$?
}

assert_argv_prefix() {
  local case_dir="$1"
  local count="$2"

  head -n "$count" "$EXPECTED_ARGV" | cmp -s - "$case_dir/argv.log" ||
    fail "$case_dir: argv was not the first $count expected commands in order"
}

assert_has() {
  grep -Fxq -- "$2" "$1" || fail "$1: missing line '$2'"
}

assert_lacks_key() {
  if grep -q "^$2=" "$1"; then
    fail "$1: unexpected key $2"
  fi
}

assert_report_shape() {
  local file="$1"
  local bytes

  [[ -f "$file" ]] || fail "missing report $file"
  if LC_ALL=C grep -Ev '^[a-z0-9_]+(\.[a-z0-9_]+)*=[][A-Za-z0-9 _.,:/()+|%-]*$' "$file" >/dev/null; then
    fail "$file: report has a line outside the key=value allowlist shape"
  fi
  if LC_ALL=C awk 'length($0) > 320 { found = 1 } END { exit !found }' "$file"; then
    fail "$file: report line exceeds the bound"
  fi
  bytes="$(wc -c < "$file" | tr -d ' ')"
  [[ "$bytes" -le 131072 ]] || fail "$file: report exceeds the size bound"
}

assert_no_capture_left() {
  if [[ -n "$(find "$1/tmp" -mindepth 1 -print -quit)" ]]; then
    fail "$1: private capture files were left behind"
  fi
}

# Runs the report helper with a clean environment, so ambient variables
# cannot trigger credential scrubbing; scrub cases inject their own.
helper() {
  env -i PATH="$PATH" "$TEST_BASH" "$HELPER" "$@"
}

# --- Success path: exact argv, order, exclusions, and passthrough ----------

plain="$TMP_ROOT/plain-success"
run_lane "$plain" ORCHARD_STUB_FIXTURES="$FIXTURES"
[[ "$RUN_STATUS" -eq 0 ]] || fail "plain success exited $RUN_STATUS"
cmp -s "$EXPECTED_ARGV" "$plain/argv.log" || fail 'plain run argv differs from the lane contract'

reported="$TMP_ROOT/report-success"
run_lane "$reported" ORCHARD_STUB_FIXTURES="$FIXTURES" ORCHARD_LINUX_PORTABLE_REPORT_DIR="$reported/report"
[[ "$RUN_STATUS" -eq 0 ]] || fail "reported success exited $RUN_STATUS"
cmp -s "$EXPECTED_ARGV" "$reported/argv.log" || fail 'reporting changed lane argv or order'
cmp -s "$plain/stdout" "$reported/stdout" || fail 'reporting changed lane stdout'
cat "$FIXTURES"/{1,2,3,4,5,6,7,8,9,10}.out | cmp -s - "$reported/stdout" ||
  fail 'reported stdout is not the unmodified command output'
grep -Fxq 'stderr passthrough from call 1' "$reported/stderr" || fail 'reporting swallowed command stderr'
if grep -Eq -- '--(trace|slowest)' "$reported/argv.log" "$SCRIPT"; then
  fail 'lane commands must not enable ExUnit trace or slowest'
fi
assert_no_capture_left "$reported"

report="$reported/report/report.staging"
[[ ! -e "$reported/report/report.txt" ]] || fail 'the lane script published an unfinalized report'
assert_report_shape "$report"
assert_has "$report" 'run.started=true'
assert_has "$report" 'run.expected_steps=10'
assert_has "$report" 'run.exit=0'
assert_has "$report" 'run.end_reason=completed'
assert_has "$report" 'run.interrupted_step=none'
index=0
for label in mix-test mix-test-cover tokenizer-ruff-format tokenizer-ruff-check tokenizer-pytest \
  tokenizer-pytest-cov worker-ruff-format worker-ruff-check worker-pytest worker-pytest-cov; do
  index=$((index + 1))
  assert_has "$report" "step.$index.label=$label"
  assert_has "$report" "step.$index.exit=0"
  assert_has "$report" "step.$index.capture=ok"
  grep -Eq "^step\.$index\.elapsed_ms=[0-9]+$" "$report" || fail "step $index elapsed is not numeric"
done
assert_has "$report" 'step.1.app.orchard_shared.seed=424242'
assert_has "$report" 'step.1.app.orchard_shared.result=4 passed (4 tests), 2 excluded'
assert_has "$report" 'step.1.app.orchard_controller.result=12 passed (1 doctest, 11 tests)'
assert_has "$report" 'step.1.failure_identities=0'
assert_has "$report" 'step.2.app.orchard_controller.coverage_total=87.3%'
assert_has "$report" 'step.3.parse=not_applicable'
assert_has "$report" 'step.5.totals=12 passed'
assert_has "$report" 'step.6.coverage_total=95%'
assert_has "$report" 'step.10.totals=30 passed, 2 skipped'
assert_has "$report" 'step.10.coverage_total=90%'
for index in 1 2 5 6 9 10; do
  assert_has "$report" "step.$index.summary=found"
  assert_has "$report" "step.$index.parse=ok"
done
assert_has "$report" 'step.1.apps_started=2'
assert_has "$report" 'step.1.apps_completed=2'
if grep -q 'passed in\|\.\.\.\.' "$report"; then
  fail 'report copied raw output or enumerated passing tests'
fi
# The helper's fixed step sequence matches the real lane script.
helper finalize "$reported/report" success
assert_has "$reported/report/report.txt" 'tests.result=success'

# --- A failing capture tee never changes a command's status ---------------

# A `set -e` bash producer writing more than a pipe buffer gets SIGPIPE and
# exits 141 if its consumer stops reading. Each tee stub stops early; the
# draining consumer group must keep every command and its status intact.
TEE_BIN="$TMP_ROOT/tee-bin"
mkdir -p "$TEE_BIN"
cp -p "$STUB_BIN/uname" "$TEE_BIN/uname"
[[ ! -e "$STUB_BIN/bash" ]] || ln -s "$TEST_BASH" "$TEE_BIN/bash"
BIG_OUTPUT="$TMP_ROOT/big-output"
awk 'BEGIN { for (i = 1; i <= 4000; i++) printf "line %05d of a producer output larger than one pipe buffer\n", i }' \
  > "$BIG_OUTPUT"
[[ "$(wc -c < "$BIG_OUTPUT" | tr -d ' ')" -gt 131072 ]] || fail 'producer fixture is not larger than the pipe buffer'
cat > "$TEE_BIN/mise" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{ for arg in "$@"; do printf '[%s]' "$arg"; done; printf '\n'; } >> "$ORCHARD_STUB_LOG"
call="$(wc -l < "$ORCHARD_STUB_LOG" | tr -d ' ')"
cat "$ORCHARD_STUB_BIG"
if [[ "${ORCHARD_STUB_FAIL_AT:-}" == "$call" ]]; then
  exit "$ORCHARD_STUB_FAIL_STATUS"
fi
EOF
chmod +x "$TEE_BIN/mise"

# Runs the lane with the bash producer and a tee stub MODE: real, exit (never
# reads), or partial (reads some input, then exits). Sets RUN_STATUS.
run_tee_lane() {
  local case_dir="$1"
  local mode="$2"
  local report_mode="$3"
  local bin="$case_dir/bin"
  shift 3

  mkdir -p "$case_dir/tmp" "$bin"
  cp -p "$TEE_BIN"/* "$bin/" 2>/dev/null || true
  [[ ! -L "$TEE_BIN/bash" ]] || ln -sf "$TEST_BASH" "$bin/bash"
  case "$mode" in
    exit) printf '#!/bin/sh\nexit 9\n' > "$bin/tee" ;;
    partial) printf '#!/bin/sh\nhead -c 1000 >/dev/null\nexit 9\n' > "$bin/tee" ;;
  esac
  [[ ! -f "$bin/tee" ]] || chmod +x "$bin/tee"
  : > "$case_dir/argv.log"
  RUN_STATUS=0
  local report_env=(-u ORCHARD_LINUX_PORTABLE_REPORT_DIR)
  [[ "$report_mode" == plain ]] || report_env=(ORCHARD_LINUX_PORTABLE_REPORT_DIR="$case_dir/report")
  (
    cd "$case_dir"
    env "${report_env[@]}" PATH="$bin:$PATH" TMPDIR="$case_dir/tmp" ORCHARD_STUB_LOG="$case_dir/argv.log" \
      ORCHARD_STUB_BIG="$BIG_OUTPUT" "$@" "$TEST_BASH" "$SCRIPT"
  ) > "$case_dir/stdout" 2> "$case_dir/stderr" || RUN_STATUS=$?
}

for fail_case in 0:: 3:1:3; do
  IFS=: read -r expected_status fail_at fail_status <<<"$fail_case"
  calls=10
  [[ -z "$fail_at" ]] || calls="$fail_at"
  baseline="$TMP_ROOT/tee-plain-$expected_status"
  run_tee_lane "$baseline" real plain ORCHARD_STUB_FAIL_AT="$fail_at" ORCHARD_STUB_FAIL_STATUS="${fail_status:-0}"
  [[ "$RUN_STATUS" -eq "$expected_status" ]] || fail "plain bash producer run exited $RUN_STATUS"
  for mode in real exit partial; do
    case_dir="$TMP_ROOT/tee-$mode-$expected_status"
    run_tee_lane "$case_dir" "$mode" report ORCHARD_STUB_FAIL_AT="$fail_at" ORCHARD_STUB_FAIL_STATUS="${fail_status:-0}"
    [[ "$RUN_STATUS" -eq "$expected_status" ]] ||
      fail "tee $mode with producer status $expected_status changed the lane status to $RUN_STATUS"
    assert_argv_prefix "$case_dir" "$calls"
    [[ "$(wc -l < "$case_dir/argv.log" | tr -d ' ')" -eq "$calls" ]] ||
      fail "tee $mode ran the wrong number of commands"
    staged="$case_dir/report/report.staging"
    assert_has "$staged" "step.$calls.exit=$expected_status"
    assert_has "$staged" "run.exit=$expected_status"
    if [[ "$mode" == real ]]; then
      assert_has "$staged" 'step.1.capture=ok'
      cmp -s "$baseline/stdout" "$case_dir/stdout" || fail 'real tee changed the lane stdout'
    else
      assert_has "$staged" 'step.1.capture=failed'
      assert_has "$staged" 'step.1.parse=unavailable'
      if [[ "$mode" == exit ]]; then
        # tee read nothing, so the drained stdout is byte-identical.
        cmp -s "$baseline/stdout" "$case_dir/stdout" || fail 'a non-reading tee lost lane stdout'
      fi
      helper finalize "$case_dir/report" success
      if grep -Fxq 'report.result=success' "$case_dir/report/report.txt"; then
        fail "tee $mode capture failure produced a success report"
      fi
    fi
  done
done

# --- Failure at each command stops later commands and keeps its status ----

for mode in plain report; do
  for call in 1 2 3 4 5 6 7 8 9 10; do
    status=$((call + 40))
    [[ "$call" -ne 4 ]] || status=1
    [[ "$call" -ne 9 ]] || status=255
    case_dir="$TMP_ROOT/fail-$mode-$call"
    extra=()
    [[ "$mode" == plain ]] || extra=(ORCHARD_LINUX_PORTABLE_REPORT_DIR="$case_dir/report")
    run_lane "$case_dir" ORCHARD_STUB_FIXTURES="$FIXTURES" ORCHARD_STUB_FAIL_AT="$call" \
      ORCHARD_STUB_FAIL_STATUS="$status" ${extra[@]+"${extra[@]}"}
    [[ "$RUN_STATUS" -eq "$status" ]] ||
      fail "$mode failure at call $call exited $RUN_STATUS instead of $status"
    assert_argv_prefix "$case_dir" "$call"
    [[ "$mode" == report ]] || continue

    report="$case_dir/report/report.staging"
    assert_report_shape "$report"
    assert_has "$report" "step.$call.exit=$status"
    assert_lacks_key "$report" "step.$((call + 1)).label"
    assert_has "$report" "run.exit=$status"
    assert_has "$report" 'run.end_reason=failed'
    assert_no_capture_left "$case_dir"
    helper finalize "$case_dir/report" failure
    report="$case_dir/report/report.txt"
    assert_has "$report" 'tests.result=failure'
    assert_has "$report" "tests.first_failed_step=$call"
    assert_has "$report" 'report.result=failure'
  done
done

# A caller that branches on the lane result still sees the original status.
case_dir="$TMP_ROOT/fail-conditional"
mkdir -p "$case_dir/tmp"
: > "$case_dir/argv.log"
if (cd "$case_dir" && env PATH="$STUB_BIN:$PATH" TMPDIR="$case_dir/tmp" ORCHARD_STUB_LOG="$case_dir/argv.log" \
  ORCHARD_STUB_FAIL_AT=2 ORCHARD_STUB_FAIL_STATUS=9 ORCHARD_LINUX_PORTABLE_REPORT_DIR="$case_dir/report" \
  "$TEST_BASH" "$SCRIPT" >/dev/null 2>&1); then
  fail 'conditional caller saw success for a failing lane'
else
  conditional_status=$?
fi
[[ "$conditional_status" -eq 9 ]] || fail "conditional caller saw status $conditional_status instead of 9"

# --- Unsupported hosts refuse before any toolchain or report work ---------

for host in Darwin FreeBSD ''; do
  case_dir="$TMP_ROOT/host-${host:-empty}"
  run_lane "$case_dir" ORCHARD_STUB_UNAME="$host" ORCHARD_LINUX_PORTABLE_REPORT_DIR="$case_dir/report"
  [[ "$RUN_STATUS" -eq 69 ]] || fail "host '$host' exited $RUN_STATUS instead of 69"
  [[ ! -s "$case_dir/argv.log" ]] || fail "host '$host' invoked the toolchain"
  [[ ! -e "$case_dir/report" ]] || fail "host '$host' started a report before the host guard"
done

# --- Interrupts end the run as unknown and keep the signal status ---------

for signal_case in INT:2:130:int TERM:6:143:term; do
  IFS=: read -r signal call status reason <<<"$signal_case"
  case_dir="$TMP_ROOT/signal-$signal"
  run_lane "$case_dir" ORCHARD_STUB_SIGNAL="$signal" ORCHARD_STUB_SIGNAL_AT="$call" \
    ORCHARD_LINUX_PORTABLE_REPORT_DIR="$case_dir/report"
  [[ "$RUN_STATUS" -eq "$status" ]] || fail "$signal exited $RUN_STATUS instead of $status"
  assert_argv_prefix "$case_dir" "$call"
  report="$case_dir/report/report.staging"
  assert_report_shape "$report"
  assert_has "$report" "run.exit=$status"
  assert_has "$report" "run.end_reason=signal_$reason"
  assert_has "$report" "run.interrupted_step=$call"
  assert_lacks_key "$report" "step.$call.exit"
  assert_no_capture_left "$case_dir"
  helper finalize "$case_dir/report" cancelled
  report="$case_dir/report/report.txt"
  assert_has "$report" 'tests.result=unknown'
  assert_has "$report" 'report.result=unknown'
done

case_dir="$TMP_ROOT/signal-plain-TERM"
run_lane "$case_dir" ORCHARD_STUB_SIGNAL=TERM ORCHARD_STUB_SIGNAL_AT=3
[[ "$RUN_STATUS" -eq 143 ]] || fail "plain TERM exited $RUN_STATUS instead of 143"
assert_argv_prefix "$case_dir" 3

# --- Dangerous and malformed output never reaches the report --------------

DANGER="$TMP_ROOT/danger-fixtures"
mkdir -p "$DANGER"
long_line="$(printf 'Result: 1 passed%04000d' 0)"
{
  printf '\033[32mRunning ExUnit with seed: 77, max_cases: 2\033[0m\n'
  printf 'connecting to postgres://orchard:SENTINELDSNPASS@db.internal/orchard_test\n'
  printf 'ORCHARD_BEAM_COOKIE=SENTINELCOOKIEVALUE\n'
  printf 'grant token SENTINELGRANTVALUE for /Users/someone/SENTINELPRIVATEPATH\n'
  printf '::add-mask::SENTINELMASK\n'
  printf '::set-output name=result::SENTINELOUTPUT\n'
  printf '==> ../../SENTINELAPP\n'
  printf '  1) test leaks SENTINELTESTNAME (Orchard.LeakTest)\n'
  printf '     /home/runner/work/SENTINELWORK/apps/leak_test.exs:3\n'
  printf '     Assertion with == failed\n'
  printf '     left:  "SENTINELASSERTPAYLOAD"\n'
  printf '  2) test lower module (orchard.lower)\n'
  printf '     test/lower_test.exs:1\n'
  printf '  3) test no location (Orchard.NoLocationTest)\n'
  printf '     ** (RuntimeError) SENTINELRAISE\n'
  printf '     stacktrace:\n'
  printf '       test/x.exs:1: (test)\n'
  printf '  4) Orchard.SetupTest: failure on setup_all callback, all tests have been invalidated\n'
  printf '  5) test traversal (Orchard.TraversalTest)\n'
  printf '     apps/../../SENTINELTRAVERSE_test.exs:4\n'
  for n in $(seq 6 35); do
    printf '  %s) test bulk %s (Orchard.BulkTest)\n     apps/orchard_shared/test/bulk_test.exs:%s\n' "$n" "$n" "$n"
  done
  printf 'Result: 1 passed; rm -rf SENTINELRESULT\n'
  printf '%s\n' "$long_line"
  printf 'Result: 3/35 passed (3/35 tests)\r\n'
  printf 'Failed: 32 tests\n'
  printf '| SENTINELTABLE%% | Total |\n'
  printf 'binary \001\002\377 bytes\n'
  printf 'env %s %s %s\n' "$(printf '%s' 'SENTINELENVPASSWORD')" "$(printf '%s' 'SENTINELENVSECRETX')" 'tail'
} > "$DANGER/1.out"
{
  printf '=========================== short test summary info ============================\n'
  printf 'FAILED tests/test_a.py::test_param[postgres://u:SENTINELPARAM@h/x] - AssertionError: SENTINELPYASSERT\n'
  printf 'FAILED tests/test_a.py::test_bad - assert SENTINELPYASSERT2\n'
  printf 'FAILED tests/space SENTINELSPACE.py::test_x\n'
  printf 'ERROR /abs/SENTINELABS/test_x.py\n'
  printf 'ERROR tests/test_broken.py\n'
  printf '2 failed, 1 passed, 2 errors in 0.20s\n'
} > "$DANGER/5.out"
case_dir="$TMP_ROOT/danger"
run_lane "$case_dir" ORCHARD_STUB_FIXTURES="$DANGER" ORCHARD_LINUX_PORTABLE_REPORT_DIR="$case_dir/report" \
  ORCHARD_STUB_FAIL_AT=5 ORCHARD_STUB_FAIL_STATUS=1 \
  PGPASSWORD=SENTINELENVPASSWORD ORCHARD_TEST_SECRET=SENTINELENVSECRETX
[[ "$RUN_STATUS" -eq 1 ]] || fail "dangerous-output run exited $RUN_STATUS instead of 1"
report="$case_dir/report/report.staging"
assert_report_shape "$report"
if grep -q 'SENTINEL' "$report"; then
  fail "report leaked sensitive or raw output: $(grep 'SENTINEL' "$report" | head -n 1)"
fi
grep -q 'SENTINELDSNPASS' "$case_dir/stdout" || fail 'stdout log no longer carries the raw command output'
assert_has "$report" 'step.1.app.project.seed=77'
assert_has "$report" 'step.1.app.project.result=3/35 passed (3/35 tests)'
assert_has "$report" 'step.1.app.project.failed=32 tests'
assert_has "$report" 'step.1.failure.1=_ Orchard.LeakTest redacted'
assert_has "$report" 'step.1.failure.2=_ Orchard.NoLocationTest unknown'
assert_has "$report" 'step.1.failure.3=_ Orchard.SetupTest setup_all'
assert_has "$report" 'step.1.failure.4=_ Orchard.TraversalTest redacted'
assert_has "$report" 'step.1.failure.5=_ Orchard.BulkTest apps/orchard_shared/test/bulk_test.exs:6'
assert_has "$report" 'step.1.failure_identities=34'
assert_has "$report" 'step.1.failure_identities_truncated=true'
assert_lacks_key "$report" 'step.1.failure.21'
assert_has "$report" 'step.5.failure.1=failed tests/test_a.py::test_param[param]'
assert_has "$report" 'step.5.failure.2=failed tests/test_a.py::test_bad'
assert_has "$report" 'step.5.failure.3=failed redacted'
assert_has "$report" 'step.5.failure.4=error redacted'
assert_has "$report" 'step.5.failure.5=error tests/test_broken.py'
assert_has "$report" 'step.5.totals=2 failed, 1 passed, 2 errors'
assert_has "$report" 'step.5.exit=1'

# A validly shaped fact that contains a known credential value, of any
# length, or a local path root is redacted at finalize and never published;
# the report is then incomplete. Case: VAR|VALUE|STAGED LINE|EXPECTED LINE
# (`-` when the whole line must be dropped).
scrub_index=0
while IFS='|' read -r scrub_var scrub_value staged expected; do
  [[ -n "$scrub_var" ]] || continue
  scrub_index=$((scrub_index + 1))
  scrub="$TMP_ROOT/scrub-$scrub_index"
  helper start "$scrub"
  printf '%s\n' "$staged" >> "$scrub/report.staging"
  scrub_value="${scrub_value//\\n/$'\n'}"
  env -i PATH="$PATH" "$scrub_var=$scrub_value" "$TEST_BASH" "$HELPER" finalize "$scrub" success
  while IFS= read -r secret_line; do
    [[ -z "$secret_line" ]] || ! grep -Fq -- "$secret_line" "$scrub/report.txt" ||
      fail "scrub case $scrub_index published the $scrub_var value"
  done <<<"$scrub_value"
  if [[ "$expected" == - ]]; then
    assert_lacks_key "$scrub/report.txt" "${staged%%=*}"
  else
    assert_has "$scrub/report.txt" "$expected"
  fi
  assert_has "$scrub/report.txt" 'report.redacted_lines=1'
  assert_has "$scrub/report.txt" 'report.complete=false'
  assert_has "$scrub/report.txt" 'report.result=unknown'
  assert_report_shape "$scrub/report.txt"
done <<'EOF'
ORCHARD_TEST_TOKEN|SENTINELSCRUBTOKEN99|step.1.failure.1=_ Orchard.SENTINELSCRUBTOKEN99 test/x.exs:1|step.1.failure.1=redacted
ORCHARD_TEST_TOKEN|Qz7|step.1.failure.1=_ Orchard.AQz7Test test/a_test.exs:1|step.1.failure.1=redacted
PGPASSWORD|pw9|step.2.failure.1=_ Orchard.LockTest test/pw9_test.exs:2|step.2.failure.1=redacted
ORCHARD_BEAM_COOKIE|c0|step.5.failure.1=failed tests/test_c0.py::test_x|step.5.failure.1=redacted
ORCHARD_GRANT_SECRET|first-line\nQq8|step.1.failure.1=_ Orchard.Qq8Test test/q_test.exs:1|step.1.failure.1=redacted
HOME|/home/runner|step.1.failure.1=_ Orchard.PathTest apps/home/runner/x_test.exs:1|step.1.failure.1=redacted
ORCHARD_TEST_TOKEN|zz9|step.1.app.zz9app.seed=7|-
ORCHARD_DEPLOY_KEY|X64|runner.arch=X64|runner.arch=redacted
EOF
[[ "$scrub_index" -eq 8 ]] || fail "only $scrub_index scrub cases ran"

# --- Reporting failures never change the lane status ----------------------

case_dir="$TMP_ROOT/report-unwritable"
mkdir -p "$case_dir"
: > "$case_dir/not-a-directory"
run_lane "$case_dir" ORCHARD_LINUX_PORTABLE_REPORT_DIR="$case_dir/not-a-directory/report"
[[ "$RUN_STATUS" -eq 0 ]] || fail "unwritable report changed success to $RUN_STATUS"
cmp -s "$EXPECTED_ARGV" "$case_dir/argv.log" || fail 'unwritable report changed lane argv'
grep -Fq 'command status is unaffected' "$case_dir/stderr" || fail 'report failure was not warned'
run_lane "$case_dir" ORCHARD_LINUX_PORTABLE_REPORT_DIR="$case_dir/not-a-directory/report" \
  ORCHARD_STUB_FAIL_AT=3 ORCHARD_STUB_FAIL_STATUS=7
[[ "$RUN_STATUS" -eq 7 ]] || fail "unwritable report changed failure status to $RUN_STATUS"

case_dir="$TMP_ROOT/capture-unavailable"
mkdir -p "$case_dir/tmp"
: > "$case_dir/argv.log"
capture_status=0
(cd "$case_dir" && env PATH="$STUB_BIN:$PATH" TMPDIR="$case_dir/missing-tmp" ORCHARD_STUB_LOG="$case_dir/argv.log" \
  ORCHARD_STUB_FIXTURES="$FIXTURES" ORCHARD_STUB_FAIL_AT=6 ORCHARD_STUB_FAIL_STATUS=5 \
  ORCHARD_LINUX_PORTABLE_REPORT_DIR="$case_dir/report" "$TEST_BASH" "$SCRIPT" > "$case_dir/stdout" 2>&1) ||
  capture_status=$?
[[ "$capture_status" -eq 5 ]] || fail "unavailable capture changed status to $capture_status"
assert_argv_prefix "$case_dir" 6
assert_has "$case_dir/report/report.staging" 'step.1.capture=unavailable'
assert_has "$case_dir/report/report.staging" 'step.1.parse=unavailable'
assert_has "$case_dir/report/report.staging" 'step.6.exit=5'

broken_tree="$TMP_ROOT/broken-helper-tree"
mkdir -p "$broken_tree/scripts/ci"
cp -p "$SCRIPT" "$broken_tree/scripts/test-linux-portable-core.sh"
printf '#!/bin/sh\nprintf "helper exploded\\n" >&2\nexit 3\n' > "$broken_tree/scripts/ci/linux-portable-validation-report.sh"
chmod +x "$broken_tree/scripts/ci/linux-portable-validation-report.sh"
for broken_case in 0:: 4:4:4; do
  IFS=: read -r expected fail_at fail_status <<<"$broken_case"
  case_dir="$TMP_ROOT/broken-helper-$expected"
  mkdir -p "$case_dir/tmp"
  : > "$case_dir/argv.log"
  broken_status=0
  (cd "$case_dir" && env PATH="$STUB_BIN:$PATH" TMPDIR="$case_dir/tmp" ORCHARD_STUB_LOG="$case_dir/argv.log" \
    ORCHARD_STUB_FAIL_AT="$fail_at" ORCHARD_STUB_FAIL_STATUS="${fail_status:-0}" \
    ORCHARD_LINUX_PORTABLE_REPORT_DIR="$case_dir/report" \
    "$TEST_BASH" "$broken_tree/scripts/test-linux-portable-core.sh" >/dev/null 2>&1) || broken_status=$?
  [[ "$broken_status" -eq "$expected" ]] || fail "broken helper changed status to $broken_status"
  assert_no_capture_left "$case_dir"
done

# Neither the helper failing nor its warning failing to write (closed or full
# stderr) may replace the command status, including inside the EXIT trap.
stderr_sinks=(closed)
[[ ! -w /dev/full ]] || stderr_sinks+=(full)
for sink in "${stderr_sinks[@]}"; do
  for broken_case in 0:: 3:3:6 10:10:2; do
    IFS=: read -r call fail_at fail_status <<<"$broken_case"
    case_dir="$TMP_ROOT/warning-$sink-$call"
    mkdir -p "$case_dir/tmp"
    : > "$case_dir/argv.log"
    warning_status=0
    if [[ "$sink" == closed ]]; then
      (cd "$case_dir" && env PATH="$STUB_BIN:$PATH" TMPDIR="$case_dir/tmp" ORCHARD_STUB_LOG="$case_dir/argv.log" \
        ORCHARD_STUB_FAIL_AT="$fail_at" ORCHARD_STUB_FAIL_STATUS="${fail_status:-0}" \
        ORCHARD_LINUX_PORTABLE_REPORT_DIR="$case_dir/report" \
        "$TEST_BASH" "$broken_tree/scripts/test-linux-portable-core.sh" >/dev/null 2>&-) || warning_status=$?
    else
      (cd "$case_dir" && env PATH="$STUB_BIN:$PATH" TMPDIR="$case_dir/tmp" ORCHARD_STUB_LOG="$case_dir/argv.log" \
        ORCHARD_STUB_FAIL_AT="$fail_at" ORCHARD_STUB_FAIL_STATUS="${fail_status:-0}" \
        ORCHARD_LINUX_PORTABLE_REPORT_DIR="$case_dir/report" \
        "$TEST_BASH" "$broken_tree/scripts/test-linux-portable-core.sh" >/dev/null 2>/dev/full) || warning_status=$?
    fi
    expected="${fail_status:-0}"
    [[ "$warning_status" -eq "$expected" ]] ||
      fail "stderr $sink with a failing helper changed status to $warning_status instead of $expected"
    if [[ "$call" -eq 0 ]]; then
      cmp -s "$EXPECTED_ARGV" "$case_dir/argv.log" || fail "stderr $sink changed lane argv"
    else
      assert_argv_prefix "$case_dir" "$call"
    fi
  done
done

# --- Parse completeness: no recognized summary is never complete --------

parse_dir="$TMP_ROOT/parse-completeness"
helper start "$parse_dir"
: > "$TMP_ROOT/empty.log"
printf 'garbage\n\001\002\nnothing recognizable here\n' > "$TMP_ROOT/garbage.log"
printf '==> orchard_shared\nRunning ExUnit with seed: 5, max_cases: 2\nResult: 1 passed (1 test)\n==> orchard_cli\nRunning ExUnit with seed: 5, max_cases: 2\n....\n' \
  > "$TMP_ROOT/unfinished.log"
helper step "$parse_dir" 1 mix-test exunit 0 1 "$TMP_ROOT/empty.log" ok
helper step "$parse_dir" 2 mix-test-cover exunit 0 1 "$TMP_ROOT/garbage.log" ok
helper step "$parse_dir" 3 tokenizer-pytest pytest 0 1 "$TMP_ROOT/empty.log" ok
helper step "$parse_dir" 4 worker-pytest pytest 0 1 "$TMP_ROOT/garbage.log" ok
helper step "$parse_dir" 5 mix-test exunit 0 1 "$TMP_ROOT/unfinished.log" ok
helper step "$parse_dir" 6 mix-test exunit 0 1 "$TMP_ROOT/missing.log" ok
helper step "$parse_dir" 7 mix-test exunit 0 1 '' failed
for index in 1 2 3 4 5; do
  assert_has "$parse_dir/report.staging" "step.$index.summary=missing"
  assert_has "$parse_dir/report.staging" "step.$index.failure_identities=unknown"
  assert_has "$parse_dir/report.staging" "step.$index.parse=partial"
done
assert_has "$parse_dir/report.staging" 'step.1.seed=unknown'
assert_has "$parse_dir/report.staging" 'step.5.apps_started=2'
assert_has "$parse_dir/report.staging" 'step.5.apps_completed=1'
assert_has "$parse_dir/report.staging" 'step.6.parse=unavailable'
assert_has "$parse_dir/report.staging" 'step.7.parse=unavailable'
assert_report_shape "$parse_dir/report.staging"

# --- Finalize: only a complete, successful record is success -------------

# `mise --version` plus `mise current` for the pinned mise.toml.
CONFIGURED_LINES=('mise 2026.9.2' 'erlang 29.1.1' 'elixir 1.20.0-otp-29' 'python 3.11.15' 'uv 0.11.23'
  'node 24.17.0')

# The lane's label:kind sequence and one realistic capture per kind.
LANE_STEPS=(mix-test:exunit mix-test-cover:exunit tokenizer-ruff-format:none tokenizer-ruff-check:none
  tokenizer-pytest:pytest tokenizer-pytest-cov:pytest worker-ruff-format:none worker-ruff-check:none
  worker-pytest:pytest worker-pytest-cov:pytest)
FULL_CAPTURES="$TMP_ROOT/full-captures"
mkdir -p "$FULL_CAPTURES"
printf '==> orchard_shared\nRunning ExUnit with seed: 11, max_cases: 2\n...\nResult: 3 passed (3 tests)\n' \
  > "$FULL_CAPTURES/exunit.log"
printf '...\n3 passed in 0.10s\n' > "$FULL_CAPTURES/pytest.log"
printf 'All checks passed!\n' > "$FULL_CAPTURES/none.log"

LOCK_TREE="$TMP_ROOT/lock-tree"
mkdir -p "$LOCK_TREE/native/orchard_tokenizer" "$LOCK_TREE/native/orchard_worker_mlx"
printf 'mix\n' > "$LOCK_TREE/mix.lock"
printf 'tokenizer\n' > "$LOCK_TREE/native/orchard_tokenizer/uv.lock"
printf 'worker\n' > "$LOCK_TREE/native/orchard_worker_mlx/uv.lock"

# Builds a complete, valid staged report. EVENT defaults to pull_request,
# which supplies head and base SHAs; push supplies neither.
full_report() {
  local dir="$1"
  local event="${2:-pull_request}"
  local step
  local pr_env=()

  if [[ "$event" == pull_request ]]; then
    pr_env=(ORCHARD_REPORT_HEAD_SHA=89abcdef0123456789abcdef0123456789abcdef
      ORCHARD_REPORT_BASE_SHA=fedcba9876543210fedcba9876543210fedcba98)
  fi
  (
    cd "$LOCK_TREE"
    helper start "$dir"
    env -u ORCHARD_REPORT_HEAD_SHA -u ORCHARD_REPORT_BASE_SHA GITHUB_REPOSITORY=example/orchard \
      GITHUB_EVENT_NAME="$event" GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 \
      GITHUB_RUN_ID=123456789 GITHUB_RUN_ATTEMPT=1 RUNNER_OS=Linux RUNNER_ARCH=X64 \
      RUNNER_ENVIRONMENT=github-hosted ImageOS=ubuntu24 ImageVersion=20260928.1.0 \
      ${pr_env[@]+"${pr_env[@]}"} "$TEST_BASH" "$HELPER" source "$dir"
    helper lockfiles "$dir" before
    printf '%s\n' "${CONFIGURED_LINES[@]}" | helper tools "$dir"
    printf 'erlang 29.1.1\nelixir 1.20.0\nuv 0.11.23\npython_tokenizer 3.11.15\npython_worker_mlx 3.11.15\n' |
      helper runtime "$dir"
    printf '160010\n' | helper postgres "$dir"
    helper lockfiles "$dir" after
    helper cache "$dir" dialyzer_plt success true 'orchard-dialyzer-plt-v2-Linux-X64-abc123'
    helper run-start "$dir" 10
    step=0
    for entry in "${LANE_STEPS[@]}"; do
      step=$((step + 1))
      helper step "$dir" "$step" "${entry%%:*}" "${entry#*:}" 0 12 "$FULL_CAPTURES/${entry#*:}.log" ok
    done
    helper run-end "$dir" 0 completed none
  )
}

final="$TMP_ROOT/final-success"
full_report "$final"
[[ ! -e "$final/report.txt" ]] || fail 'a report was published before finalize'
helper finalize "$final" success
assert_report_shape "$final/report.txt"
key_digest="$(printf '%s' 'orchard-dialyzer-plt-v2-Linux-X64-abc123' | shasum -a 256 | cut -d ' ' -f 1)"
for line in report.complete=true tests.result=success report.result=success report.finalized=true \
  source.repository=example/orchard source.event=pull_request source.run_attempt=1 \
  runner.image_os=ubuntu24 runner.image_version=20260928.1.0 toolchain.configured.mise=2026.9.2 \
  toolchain.configured.elixir=1.20.0-otp-29 toolchain.configured_count=6 runtime.erlang=29.1.1 \
  runtime.elixir=1.20.0 runtime.uv=0.11.23 runtime.python_tokenizer=3.11.15 runtime.python_worker_mlx=3.11.15 \
  postgres.server_version_num=160010 cache.dialyzer_plt=hit "cache.dialyzer_plt.key_sha256=$key_digest" \
  lockfile.mix_lock.changed=false job.status_at_finalize=success; do
  assert_has "$final/report.txt" "$line"
done
if grep -q 'abc123' "$final/report.txt"; then
  fail 'cache key was recorded instead of its digest'
fi

# A push has no pull request head or base, and that is still complete.
final="$TMP_ROOT/final-push"
full_report "$final" push
helper finalize "$final" success
for line in source.event=push source.head_sha=not_applicable source.base_sha=not_applicable \
  report.complete=true report.result=success; do
  assert_has "$final/report.txt" "$line"
done

# Rewrites one staged fact: VALUE replaces it, or `-` deletes the line.
mutate_fact() {
  local file="$1"
  local key="$2"
  local value="$3"

  awk -v key="$key" -v value="$value" '
    value == "--" && index($0, key ".") == 1 { next }
    index($0, key "=") == 1 { if (value != "-" && value != "--") print key "=" value; next }
    { print }
  ' "$file" > "$file.edited"
  mv "$file.edited" "$file"
}

# Every metadata fact that is missing, a sentinel, or invalid makes an
# otherwise successful report incomplete and unknown, never success.
mutation_index=0
while IFS='|' read -r event key value; do
  [[ -n "$key" ]] || continue
  mutation_index=$((mutation_index + 1))
  final="$TMP_ROOT/final-mutation-$mutation_index"
  full_report "$final" "$event"
  grep -q "^$key=" "$final/report.staging" || fail "mutation $key is not in the full report"
  mutate_fact "$final/report.staging" "$key" "$value"
  helper finalize "$final" success
  for line in tests.result=success report.complete=false report.result=unknown; do
    grep -Fxq "$line" "$final/report.txt" ||
      fail "mutation $event $key=$value did not give $line"
  done
done <<'EOF'
pull_request|report.started|-
pull_request|source.repository|unknown
pull_request|source.repository|-
pull_request|source.event|unknown
pull_request|source.sha|unknown
pull_request|source.sha|invalid
pull_request|source.sha|0123
pull_request|source.sha|-
pull_request|source.run_id|unknown
pull_request|source.run_id|-
pull_request|source.run_attempt|unknown
pull_request|runner.os|unknown
pull_request|runner.os|-
pull_request|runner.arch|unknown
pull_request|runner.environment|unknown
pull_request|runner.image_os|unknown
pull_request|runner.image_version|unknown
pull_request|runner.image_version|-
pull_request|source.head_sha|unknown
pull_request|source.head_sha|not_applicable
pull_request|source.head_sha|-
pull_request|source.base_sha|not_applicable
pull_request|source.base_sha|unknown
push|source.head_sha|unknown
push|source.base_sha|invalid
pull_request|toolchain.configured_count|0
pull_request|toolchain.configured_count|5
pull_request|toolchain.configured_count|-
pull_request|toolchain.configured.elixir|unknown
pull_request|toolchain.configured.elixir|invalid
pull_request|toolchain.configured.mise|-
pull_request|runtime.erlang|unknown
pull_request|runtime.uv|invalid
pull_request|runtime.elixir|-
pull_request|lockfile.mix_lock.before|unknown
pull_request|lockfile.mix_lock.before|missing
pull_request|lockfile.mix_lock.before|-
pull_request|lockfile.tokenizer_uv_lock.after|missing
pull_request|lockfile.tokenizer_uv_lock.after|unknown
pull_request|lockfile.worker_mlx_uv_lock.after|-
pull_request|lockfile.worker_mlx_uv_lock.changed|unknown
pull_request|lockfile.mix_lock.changed|-
pull_request|postgres.server_version_num|unknown
pull_request|postgres.server_version_num|-
pull_request|cache.dialyzer_plt|unknown
pull_request|cache.dialyzer_plt|-
pull_request|cache.dialyzer_plt.key_sha256|unknown
pull_request|cache.dialyzer_plt.key_sha256|-
EOF
[[ "$mutation_index" -ge 48 ]] || fail "only $mutation_index metadata mutations ran"

# The same mutations never turn a recorded command failure into anything
# other than failure.
final="$TMP_ROOT/final-mutation-failure"
full_report "$final"
mutate_fact "$final/report.staging" step.4.exit 3
mutate_fact "$final/report.staging" source.sha unknown
helper finalize "$final" success
assert_has "$final/report.txt" 'tests.result=failure'
assert_has "$final/report.txt" 'report.result=failure'

# Every per-step or run fact that is missing, malformed, out of sequence, or
# inconsistent makes the report incomplete. A malformed exit is unknown and
# never manufactures a failure. Case: KEY|VALUE|EXPECTED tests.result, where
# VALUE `-` deletes the line and `--` deletes every KEY.* line.
mutation_index=0
while IFS='|' read -r key value expected_tests; do
  [[ -n "$key" ]] || continue
  mutation_index=$((mutation_index + 1))
  final="$TMP_ROOT/final-run-mutation-$mutation_index"
  full_report "$final"
  mutate_fact "$final/report.staging" "$key" "$value"
  [[ "$value" == -- || "$value" == - ]] || grep -q "^$key=" "$final/report.staging" ||
    printf '%s=%s\n' "$key" "$value" >> "$final/report.staging"
  helper finalize "$final" success
  for line in "tests.result=$expected_tests" report.complete=false; do
    grep -Fxq "$line" "$final/report.txt" || fail "run mutation $key=$value did not give $line"
  done
  if [[ "$expected_tests" != failure ]]; then
    assert_has "$final/report.txt" 'tests.first_failed_step=none'
  fi
  assert_has "$final/report.txt" "report.result=$([[ "$expected_tests" == failure ]] && printf failure || printf unknown)"
done <<'EOF'
step.3.elapsed_ms|-|unknown
step.3.elapsed_ms|unknown|unknown
step.3.elapsed_ms|1234567890123|unknown
step.3.label|-|unknown
step.3.label|worker-pytest|unknown
step.3.kind|-|unknown
step.3.kind|pytest|unknown
step.3.capture|-|unknown
step.3.capture|maybe|unknown
step.3.capture|failed|unknown
step.3.capture|unavailable|unknown
step.1.capture|failed|unknown
step.3.parse|-|unknown
step.3.parse|ok|unknown
step.1.parse|partial|unknown
step.1.parse|-|unknown
step.3.exit|unknown|unknown
step.3.exit|invalid|unknown
step.3.exit|00|unknown
step.3.exit|256|unknown
step.3.exit|-|unknown
step.10.exit|-|unknown
step.10.label|-|unknown
step.5|--|unknown
step.10|--|unknown
step.11.label|extra|unknown
run.started|-|unknown
run.expected_steps|9|unknown
run.expected_steps|-|unknown
run.exit|-|unknown
run.exit|unknown|unknown
run.exit|1|unknown
run.end_reason|-|unknown
run.end_reason|failed|unknown
run.end_reason|signal_int|unknown
run.interrupted_step|-|unknown
run.interrupted_step|unknown|unknown
run.interrupted_step|4|unknown
step.4.exit|3|failure
EOF
[[ "$mutation_index" -ge 39 ]] || fail "only $mutation_index run mutations ran"

# Every configured tool identity is required, even when the count is
# consistent and every probed runtime is healthy.
tool_index=0
for tool_case in 'mise 2026.9.2' \
  'mise 2026.9.2|erlang 29.1.1|elixir 1.20.0-otp-29|python 3.11.15|uv 0.11.23' \
  'mise 2026.9.2|erlang 29.1.1|elixir 1.20.0-otp-29|python unknown|uv 0.11.23|node 24.17.0'; do
  tool_index=$((tool_index + 1))
  final="$TMP_ROOT/final-configured-tools-$tool_index"
  full_report "$final"
  grep -v '^toolchain\.' "$final/report.staging" > "$final/edited"
  mv "$final/edited" "$final/report.staging"
  printf '%s\n' "$tool_case" | tr '|' '\n' | helper tools "$final"
  helper finalize "$final" success
  for line in tests.result=success report.complete=false report.result=unknown runtime.uv=0.11.23; do
    assert_has "$final/report.txt" "$line"
  done
done
assert_has "$TMP_ROOT/final-configured-tools-1/report.txt" 'toolchain.configured_count=1'
assert_has "$TMP_ROOT/final-configured-tools-2/report.txt" 'toolchain.configured_count=5'

# An interrupted run or a cancelled job keeps its recorded command facts but
# is never an overall failure. Case: SIGNAL_EXIT|END_REASON|INTERRUPTED|JOB
# for a run stopped after step 4 exited 3.
while IFS='|' read -r run_exit end_reason interrupted job expected; do
  [[ -n "$run_exit" ]] || continue
  final="$TMP_ROOT/final-stopped-$end_reason-$job"
  full_report "$final"
  mutate_fact "$final/report.staging" step.4.exit 3
  for gone in 5 6 7 8 9 10; do
    mutate_fact "$final/report.staging" "step.$gone" --
  done
  mutate_fact "$final/report.staging" run.exit "$run_exit"
  mutate_fact "$final/report.staging" run.end_reason "$end_reason"
  mutate_fact "$final/report.staging" run.interrupted_step "$interrupted"
  helper finalize "$final" "$job"
  for line in tests.result=failure tests.first_failed_step=4 step.4.exit=3 "run.exit=$run_exit" \
    "run.end_reason=$end_reason" "job.status_at_finalize=$job" "report.result=$expected"; do
    assert_has "$final/report.txt" "$line"
  done
  [[ "$expected" == failure ]] || assert_has "$final/report.txt" 'report.complete=false'
done <<'EOF'
130|signal_int|4|cancelled|unknown
143|signal_term|4|cancelled|unknown
130|signal_int|4|success|unknown
3|failed|none|failure|failure
3|failed|none|cancelled|unknown
EOF

# A capture failure never hides a known command failure.
final="$TMP_ROOT/final-capture-failure-with-failure"
full_report "$final"
mutate_fact "$final/report.staging" step.3.capture failed
mutate_fact "$final/report.staging" step.3.exit 2
for gone in 4 5 6 7 8 9 10; do
  mutate_fact "$final/report.staging" "step.$gone" --
done
mutate_fact "$final/report.staging" run.exit 2
mutate_fact "$final/report.staging" run.end_reason failed
helper finalize "$final" failure
for line in tests.result=failure tests.first_failed_step=3 report.result=failure report.complete=false \
  step.3.exit=2 run.exit=2; do
  assert_has "$final/report.txt" "$line"
done

# Keys outside the fixed staging vocabulary, including final-only fields and
# credential-shaped names, are never published and make the report incomplete.
for bogus in 'token=ghs_abcdef0123' 'report.result=success' 'tests.result=success' 'job.status_at_finalize=success' \
  'step.3.bogus=1' 'step.3.app.x.secret=1' 'runtime.node=24.17.0' 'cache.other=hit' 'lockfile.other_lock.before=x'; do
  final="$TMP_ROOT/final-unknown-key-${bogus%%=*}"
  full_report "$final"
  printf '%s\n' "$bogus" >> "$final/report.staging"
  helper finalize "$final" success
  case "$bogus" in
    report.* | tests.* | job.*)
      # Final-only fields appear once, computed by finalize, never staged.
      [[ "$(grep -c "^${bogus%%=*}=" "$final/report.txt")" -eq 1 ]] ||
        fail "staged final-only field $bogus was published"
      ;;
    *)
      assert_lacks_key "$final/report.txt" "${bogus%%=*}"
      ;;
  esac
  if grep -q 'ghs_' "$final/report.txt"; then
    fail 'a credential-shaped staged key was published'
  fi
  assert_has "$final/report.txt" 'report.unknown_keys=1'
  assert_has "$final/report.txt" 'report.complete=false'
  assert_has "$final/report.txt" 'report.result=unknown'
done

# Publication is atomic: a failed write or rename leaves no report.txt, even
# when a stale published report existed, and a later finalize can recover.
final="$TMP_ROOT/final-rename-failure"
full_report "$final"
helper finalize "$final" success
FAIL_BIN="$TMP_ROOT/fail-bin"
mkdir -p "$FAIL_BIN"
printf '#!/bin/sh\nexit 1\n' > "$FAIL_BIN/mv"
chmod +x "$FAIL_BIN/mv"
if PATH="$FAIL_BIN:$PATH" helper finalize "$final" success 2>/dev/null; then
  fail 'finalize reported success when the publishing rename failed'
fi
[[ ! -e "$final/report.txt" ]] || fail 'a failed rename left a published report'
if [[ -n "$(find "$final" -name '.report.finalize.*' -print -quit)" ]]; then
  fail 'a failed finalize left its work file behind'
fi
helper finalize "$final" success
assert_has "$final/report.txt" 'report.result=success'

final="$TMP_ROOT/final-write-failure"
full_report "$final"
chmod 500 "$final"
write_status=0
helper finalize "$final" success 2>/dev/null || write_status=$?
chmod 700 "$final"
[[ "$write_status" -ne 0 ]] || fail 'finalize reported success when the work file could not be written'
[[ ! -e "$final/report.txt" ]] || fail 'a failed write published a report'

final="$TMP_ROOT/final-published-directory"
full_report "$final"
mkdir "$final/report.txt"
printf 'SENTINELDIRECTORYLEAK\n' > "$final/report.txt/leak.txt"
if helper finalize "$final" success 2>/dev/null; then
  fail 'finalize replaced an unexpected report.txt directory'
fi
[[ -f "$final/report.txt/leak.txt" ]] || fail 'finalize deleted contents of an unexpected directory'

final="$TMP_ROOT/final-restart"
full_report "$final"
helper finalize "$final" success
helper start "$final"
[[ ! -e "$final/report.txt" ]] || fail 'start kept a stale published report'

final="$TMP_ROOT/final-partial-parse"
full_report "$final"
printf 'Running ExUnit with seed: 1, max_cases: 1\n' > "$TMP_ROOT/partial.log"
grep -v '^step\.1\.' "$final/report.staging" > "$final/edited"
mv "$final/edited" "$final/report.staging"
helper step "$final" 1 mix-test exunit 0 12 "$TMP_ROOT/partial.log" ok
helper finalize "$final" success
assert_has "$final/report.txt" 'step.1.parse=partial'
assert_has "$final/report.txt" 'tests.result=unknown'
assert_has "$final/report.txt" 'report.complete=false'
assert_has "$final/report.txt" 'report.result=unknown'

final="$TMP_ROOT/final-cancelled"
full_report "$final"
helper finalize "$final" cancelled
assert_has "$final/report.txt" 'tests.result=success'
assert_has "$final/report.txt" 'report.result=unknown'

final="$TMP_ROOT/final-bad-job-status"
full_report "$final"
helper finalize "$final" 'success; echo'
assert_has "$final/report.txt" 'job.status_at_finalize=unknown'
assert_has "$final/report.txt" 'report.result=unknown'

final="$TMP_ROOT/final-missing-step"
full_report "$final"
grep -v '^step\.10\.' "$final/report.staging" > "$final/edited"
mv "$final/edited" "$final/report.staging"
helper finalize "$final" success
assert_has "$final/report.txt" 'tests.result=unknown'
assert_has "$final/report.txt" 'report.result=unknown'

final="$TMP_ROOT/final-incomplete-run"
full_report "$final"
grep -v '^run\.\(exit\|end_reason\|interrupted_step\)=' "$final/report.staging" > "$final/edited"
mv "$final/edited" "$final/report.staging"
helper finalize "$final" success
assert_has "$final/report.txt" 'tests.result=unknown'
assert_has "$final/report.txt" 'report.complete=false'
assert_has "$final/report.txt" 'report.result=unknown'

final="$TMP_ROOT/final-missing-tools"
full_report "$final"
grep -v '^toolchain' "$final/report.staging" > "$final/edited"
mv "$final/edited" "$final/report.staging"
helper finalize "$final" success
assert_has "$final/report.txt" 'report.complete=false'
assert_has "$final/report.txt" 'report.result=unknown'

final="$TMP_ROOT/final-tampered"
full_report "$final"
printf 'step.1.exit=0\nbad line\nUPPER=x\nnote=a@b\nnote2=/abs/path\n' >> "$final/report.staging"
helper finalize "$final" success
assert_report_shape "$final/report.txt"
assert_has "$final/report.txt" 'report.duplicate_keys=1'
assert_has "$final/report.txt" 'report.dropped_lines=4'
assert_has "$final/report.txt" 'report.result=unknown'

final="$TMP_ROOT/final-absent"
helper finalize "$final" success
assert_report_shape "$final/report.txt"
assert_has "$final/report.txt" 'tests.result=unknown'
assert_has "$final/report.txt" 'report.complete=false'
assert_has "$final/report.txt" 'report.result=unknown'

# --- Metadata: lockfiles, cache, source, and tool identity ----------------

meta="$TMP_ROOT/meta-lock"
(
  cd "$LOCK_TREE"
  helper start "$meta"
  helper lockfiles "$meta" before
  printf 'changed\n' >> native/orchard_tokenizer/uv.lock
  rm native/orchard_worker_mlx/uv.lock
  helper lockfiles "$meta" after
) || fail 'a changed lockfile made lockfile reporting fail'
assert_has "$meta/report.staging" 'lockfile.mix_lock.changed=false'
assert_has "$meta/report.staging" 'lockfile.tokenizer_uv_lock.changed=true'
assert_has "$meta/report.staging" 'lockfile.worker_mlx_uv_lock.after=missing'
assert_has "$meta/report.staging" 'lockfile.worker_mlx_uv_lock.changed=true'
grep -Eq '^lockfile\.mix_lock\.before=[0-9a-f]{64}$' "$meta/report.staging" || fail 'lockfile digest is not SHA-256'

meta="$TMP_ROOT/meta-cache"
helper start "$meta"
index=0
for cache_case in success:true:hit success::miss success:false:miss failure::unknown skipped::unknown \
  cancelled:true:unknown ::unknown success:yes:unknown; do
  IFS=: read -r outcome hit expected <<<"$cache_case"
  index=$((index + 1))
  helper cache "$meta" "case_$index" "$outcome" "$hit" key
  assert_has "$meta/report.staging" "cache.case_$index=$expected"
done
helper cache "$meta" empty_key success true ''
assert_has "$meta/report.staging" 'cache.empty_key.key_sha256=unknown'
helper cache "$meta" long_key success true "$(printf 'k%0600d' 0)"
assert_has "$meta/report.staging" 'cache.long_key.key_sha256=unknown'

meta="$TMP_ROOT/meta-runtime"
helper start "$meta"
{
  printf 'erlang 29.1.1\n'
  printf 'erlang 1.0.0\n'
  printf 'elixir \n'
  printf 'uv 0.11.23 (abc 2026-09-01)\n'
  printf 'python_tokenizer 3.11.15\n'
  printf 'python_worker_mlx /home/runner/.venv/bin/python\n'
  printf 'node 24.17.0\n'
} | helper runtime "$meta"
for line in runtime.erlang=29.1.1 runtime.elixir=unknown runtime.uv=unknown runtime.python_tokenizer=3.11.15 \
  runtime.python_worker_mlx=unknown; do
  assert_has "$meta/report.staging" "$line"
done
assert_lacks_key "$meta/report.staging" 'runtime.node'

index=0
for pg_case in '160010:160010' '90624:90624' '16.10:unknown' '160010; DROP TABLE x:unknown' ':unknown' \
  '12345678:unknown'; do
  index=$((index + 1))
  meta="$TMP_ROOT/meta-postgres-$index"
  helper start "$meta"
  printf '%s\nextra line\n' "${pg_case%:*}" | helper postgres "$meta"
  assert_has "$meta/report.staging" "postgres.server_version_num=${pg_case##*:}"
done
meta="$TMP_ROOT/meta-postgres-empty"
helper start "$meta"
helper postgres "$meta" < /dev/null
assert_has "$meta/report.staging" 'postgres.server_version_num=unknown'

meta="$TMP_ROOT/meta-source"
helper start "$meta"
env -i PATH="$PATH" GITHUB_EVENT_NAME=push GITHUB_SHA='abc;rm -rf' GITHUB_REPOSITORY='a/b c' \
  GITHUB_RUN_ATTEMPT=x ImageVersion='1.0 && evil' "$TEST_BASH" "$HELPER" source "$meta"
for line in source.event=push source.sha=unknown source.repository=unknown source.run_attempt=unknown \
  source.head_sha=not_applicable source.base_sha=not_applicable runner.image_version=unknown runner.os=unknown; do
  assert_has "$meta/report.staging" "$line"
done
meta="$TMP_ROOT/meta-source-pr"
helper start "$meta"
env -i PATH="$PATH" GITHUB_EVENT_NAME=pull_request "$TEST_BASH" "$HELPER" source "$meta"
assert_has "$meta/report.staging" 'source.head_sha=unknown'

meta="$TMP_ROOT/meta-tools"
helper start "$meta"
{
  printf 'mise 2026.9.2\n'
  printf 'erlang 29.1.1\n'
  printf 'erlang 99.0.0\n'
  printf 'python-build 3.11.15\n'
  printf 'bad tool line with spaces 1.0\n'
  printf 'node $(evil)\n'
  printf 'secret postgres://u:p@h/x\n'
  printf 'longname%0100d 1.0\n' 0
  for n in $(seq 1 30); do printf 'tool%s 1.%s\n' "$n" "$n"; done
} | helper tools "$meta"
assert_has "$meta/report.staging" 'toolchain.configured.erlang=29.1.1'
assert_has "$meta/report.staging" 'toolchain.configured.python_build=3.11.15'
assert_has "$meta/report.staging" 'toolchain.configured_count=16'
assert_lacks_key "$meta/report.staging" 'toolchain.configured.node'
assert_lacks_key "$meta/report.staging" 'toolchain.configured.secret'
[[ "$(grep -c '^toolchain\.configured\.' "$meta/report.staging")" -eq 16 ]] ||
  fail 'configured toolchain identity was not bounded'
assert_report_shape "$meta/report.staging"

# --- Workflow wiring ------------------------------------------------------

job_block() {
  awk -v job="  $1:" '
    $0 == job { capture = 1; print; next }
    capture && /^  [a-zA-Z0-9_-]+:/ { exit }
    capture { print }
  ' "$WORKFLOW"
}

step_block() {
  awk -v name="      - name: $2" '
    $0 == name { capture = 1; print; next }
    capture && /^      - / { exit }
    capture { print }
  ' <<<"$1"
}

line_of() {
  awk -v pattern="$2" 'index($0, pattern) { print NR; exit }' <<<"$1"
}

linux_job="$(job_block linux-portable)"
changes_job="$(job_block changes)"
previous=0
for marker in 'name: Check out repository' 'linux-portable-validation-report.sh start' \
  'uses: jdx/mise-action@' 'make setup-elixir' 'lockfiles "$REPORT_DIR" after' \
  'name: Cache Dialyzer PLTs' 'run: scripts/test-linux-portable-core.sh' \
  'linux-portable-validation-report.sh finalize' 'uses: actions/upload-artifact@'; do
  current="$(line_of "$linux_job" "$marker")"
  [[ -n "$current" && "$current" -gt "$previous" ]] || fail "linux-portable job is missing or misorders '$marker'"
  previous="$current"
done

test_step="$(step_block "$linux_job" 'Run portable tests and coverage')"
grep -Fxq '        run: scripts/test-linux-portable-core.sh' <<<"$test_step" ||
  fail 'portable test step no longer runs the lane script directly'
grep -Fq 'ORCHARD_LINUX_PORTABLE_REPORT_DIR: ${{ runner.temp }}/orchard-linux-portable-report' <<<"$test_step" ||
  fail 'portable test step does not enable the bounded report'
if grep -Fq 'continue-on-error' <<<"$test_step"; then
  fail 'portable test step must keep its failure semantics'
fi

report_steps=('Start validation report' 'Record setup identity' 'Record cache identity'
  'Finalize validation report' 'Upload validation report')
for name in "${report_steps[@]}"; do
  block="$(step_block "$linux_job" "$name")"
  [[ -n "$block" ]] || fail "missing workflow step '$name'"
  grep -Fq 'continue-on-error: true' <<<"$block" || fail "report step '$name' can fail the lane"
  if grep -Fq 'report.staging' <<<"$block"; then
    fail "report step '$name' references the unfinalized staging file"
  fi
done
for name in 'Record setup identity' 'Record cache identity'; do
  grep -Fq 'if: ${{ !cancelled() }}' <<<"$(step_block "$linux_job" "$name")" ||
    fail "probe step '$name' is not fail-soft after failures"
done
for name in 'Finalize validation report' 'Upload validation report'; do
  grep -Fq 'if: always()' <<<"$(step_block "$linux_job" "$name")" || fail "report step '$name' is not always()"
done

setup_identity="$(step_block "$linux_job" 'Record setup identity')"
for fact in 'lockfiles "$REPORT_DIR" after' 'tools "$REPORT_DIR"' 'runtime "$REPORT_DIR"' 'postgres "$REPORT_DIR"'; do
  grep -Fq "$fact" <<<"$setup_identity" || fail "setup identity does not record '$fact'"
done
psql_lines="$(grep -F 'psql' <<<"$setup_identity")"
[[ -n "$psql_lines" ]] || fail 'setup identity does not probe the PostgreSQL server version'
while IFS= read -r psql_line; do
  grep -Fq -- "-c 'SHOW server_version_num'" <<<"$psql_line" ||
    fail "PostgreSQL probe is not the read-only server_version_num query: $psql_line"
done <<<"$psql_lines"

# Probes never install tools or create environments.
grep -Fxq '          MISE_EXEC_AUTO_INSTALL: "false"' <<<"$setup_identity" ||
  fail 'setup identity probes may auto-install mise tools'
[[ "$(grep -c 'MISE_EXEC_AUTO_INSTALL' "$WORKFLOW")" -eq 1 ]] ||
  fail 'mise auto-install must be disabled only for the diagnostic probe step'
grep -Fq 'interpreter="native/$package/.venv/bin/python"' <<<"$setup_identity" ||
  fail 'Python probes must run the existing package interpreter directly'
if grep -Eq 'uv (run|sync)|pip ' <<<"$setup_identity"; then
  fail 'setup identity probes must not run or sync package environments'
fi

cache_step="$(step_block "$linux_job" 'Cache Dialyzer PLTs')"
cache_identity="$(step_block "$linux_job" 'Record cache identity')"
cache_key="$(sed -n 's/^          key: //p' <<<"$cache_step")"
identity_key="$(sed -n 's/^          DIALYZER_PLT_KEY: //p' <<<"$cache_identity")"
[[ -n "$cache_key" && "$cache_key" == "$identity_key" ]] ||
  fail 'recorded Dialyzer cache key expression drifted from the cache step key'
grep -Fq 'id: dialyzer-plt' <<<"$cache_step" || fail 'cache step lost the id the identity step reads'
grep -Fq 'steps.dialyzer-plt.outputs.cache-hit' <<<"$cache_identity" || fail 'cache identity does not read cache-hit'
[[ "$(line_of "$linux_job" 'name: Record cache identity')" -gt "$(line_of "$linux_job" 'name: Cache Dialyzer PLTs')" ]] ||
  fail 'cache identity must follow the cache step'

upload="$(step_block "$linux_job" 'Upload validation report')"
grep -Eq 'uses: actions/upload-artifact@[0-9a-f]{40} # v[0-9.]+$' <<<"$upload" ||
  fail 'artifact upload is not pinned to a full commit SHA'
upload_paths="$(awk '/^          path:/ { capture = 1 } capture && /^          [a-z-]+:/ && !/^          path:/ { exit } capture { print }' <<<"$upload")"
[[ "$(grep -c . <<<"$upload_paths")" -eq 1 ]] || fail 'artifact upload must name exactly one path'
grep -Eq '^          path: [^*?]*/orchard-linux-portable-report/report\.txt$' <<<"$upload_paths" ||
  fail 'artifact upload must contain only the published report file'

# --- Upload gate: only a finalize receipt for a regular file uploads -------

finalize_step="$(step_block "$linux_job" 'Finalize validation report')"
grep -Fxq '        id: finalize-report' <<<"$finalize_step" || fail 'finalize step lost its receipt id'
grep -Fxq "        if: always() && steps.finalize-report.outcome == 'success' && steps.finalize-report.outputs.published == 'true'" <<<"$upload" ||
  fail 'artifact upload is not gated on the finalize receipt'
[[ "$(grep -c 'GITHUB_OUTPUT' <<<"$linux_job")" -eq 1 ]] ||
  fail 'only the finalize step may write the publication receipt'
finalize_script="$(awk '
  /^        run: \|$/ { capture = 1; next }
  capture && /^          / { print substr($0, 11); next }
  capture { exit }
' <<<"$finalize_step")"
[[ -n "$finalize_script" ]] || fail 'finalize step has no run block to exercise'

# Runs the workflow finalize step for DIR with PATH_VALUE under the default
# `bash -e` step shell, then decides the upload as the gated upload step
# would. Sets UPLOAD to true or false.
run_finalize_step() {
  local dir="$1"
  local path_value="$2"
  local script="${3:-$finalize_script}"
  local output="$dir.github-output"
  local outcome=success

  : > "$output"
  (cd "$ROOT" && env -i PATH="$path_value" REPORT_DIR="$dir" JOB_STATUS=success GITHUB_OUTPUT="$output" \
    "$TEST_BASH" -e -c "$script") >/dev/null 2>&1 || outcome=failure
  # The upload needs the step's own outcome (before continue-on-error) and
  # the receipt.
  UPLOAD=false
  if [[ "$outcome" == success ]] && grep -Fxq 'published=true' "$output"; then
    UPLOAD=true
  fi
}

gate="$TMP_ROOT/gate-success"
full_report "$gate"
run_finalize_step "$gate" "$PATH"
[[ "$UPLOAD" == true && -f "$gate/report.txt" && ! -L "$gate/report.txt" ]] ||
  fail 'a successful finalize did not produce an upload receipt'

# A receipt from a step that then fails is not admitted.
gate="$TMP_ROOT/gate-failed-after-receipt"
full_report "$gate"
run_finalize_step "$gate" "$PATH" "$finalize_script"$'\nfalse'
grep -Fxq 'published=true' "$gate.github-output" || fail 'receipt case did not write a receipt'
[[ "$UPLOAD" == false ]] || fail 'a failed finalize outcome with a receipt would be uploaded'

gate="$TMP_ROOT/gate-directory"
full_report "$gate"
mkdir "$gate/report.txt"
printf 'SENTINELDIRECTORYLEAK\n' > "$gate/report.txt/leak.txt"
run_finalize_step "$gate" "$PATH"
[[ "$UPLOAD" == false ]] || fail 'a report.txt directory would be uploaded'
[[ -f "$gate/report.txt/leak.txt" ]] || fail 'finalize deleted contents of an unexpected directory'

gate="$TMP_ROOT/gate-rename-failure"
full_report "$gate"
run_finalize_step "$gate" "$FAIL_BIN:$PATH"
[[ "$UPLOAD" == false && ! -e "$gate/report.txt" ]] || fail 'a failed rename would be uploaded'

SYMLINK_BIN="$TMP_ROOT/symlink-bin"
mkdir -p "$SYMLINK_BIN"
printf 'SENTINELSYMLINKTARGET\n' > "$TMP_ROOT/symlink-target"
cat > "$SYMLINK_BIN/mv" <<SYMLINK_MV
#!/bin/sh
for arg; do dest="\$arg"; done
ln -s "$TMP_ROOT/symlink-target" "\$dest"
SYMLINK_MV
chmod +x "$SYMLINK_BIN/mv"
gate="$TMP_ROOT/gate-symlink-publish"
full_report "$gate"
run_finalize_step "$gate" "$SYMLINK_BIN:$PATH"
[[ "$UPLOAD" == false && ! -L "$gate/report.txt" && ! -e "$gate/report.txt" ]] ||
  fail 'a symlinked publication would be uploaded'

gate="$TMP_ROOT/gate-stale-symlink"
full_report "$gate"
ln -s "$TMP_ROOT/symlink-target" "$gate/report.txt"
run_finalize_step "$gate" "$PATH"
[[ "$UPLOAD" == true && -f "$gate/report.txt" && ! -L "$gate/report.txt" ]] ||
  fail 'finalize did not replace a stale symlink with a regular report'
grep -Fxq 'SENTINELSYMLINKTARGET' "$TMP_ROOT/symlink-target" || fail 'finalize wrote through a stale symlink'

[[ "$(grep -c 'uses: actions/cache@' <<<"$linux_job")" -eq 1 ]] || fail 'reporting must not add a cache'
grep -Fq 'cache: false' <<<"$linux_job" || fail 'linux-portable mise cache setting changed'
grep -Fq 'scripts/ci/test-linux-portable-validation-report.sh' <<<"$changes_job" ||
  fail 'changes job does not run the portable report tests'

printf 'linux portable validation report tests passed\n'
