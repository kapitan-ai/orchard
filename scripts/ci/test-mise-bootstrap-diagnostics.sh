#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REPORT="$ROOT/scripts/ci/mise-bootstrap-diagnostics.sh"
WORKFLOW="$ROOT/.github/workflows/required-validation.yml"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
cases=0

fail() { printf 'mise bootstrap diagnostic test failed: %s\n' "$1" >&2; exit 1; }
pass() { cases=$((cases + 1)); }

cat > "$FIXTURE/expected" <<'EXPECTED'
bootstrap.action_outcome=failure
bootstrap.mise_version_requested=2026.9.2
bootstrap.failure_boundary=mise-action
bootstrap.failure_stage=unknown
bootstrap.http_status=unknown
bootstrap.retries_observed=unknown
bootstrap.download_retry_limit_configured=5
bootstrap.download_retry_delay_ms_configured=2000
EXPECTED

"$REPORT" failure 2026.9.2 > "$FIXTURE/actual"
cmp "$FIXTURE/expected" "$FIXTURE/actual" || fail 'allowlisted report differs'
pass

# Deliberately hostile environment, args and working directory are never logged.
mkdir "$FIXTURE/private-host-signed-url"
(cd "$FIXTURE/private-host-signed-url"; PRIVATE_TOKEN='do-not-print-token' \
  PRIVATE_URL='https://private.example/?signature=do-not-print' \
  "$REPORT" failure 2026.9.2) > "$FIXTURE/actual"
cmp "$FIXTURE/expected" "$FIXTURE/actual" || fail 'environment or cwd leaked'
pass

reject() {
  local status=0
  "$REPORT" "$@" > "$FIXTURE/stdout" 2> "$FIXTURE/stderr" || status=$?
  [[ "$status" == 64 && ! -s "$FIXTURE/stdout" ]] || fail 'invalid input was accepted'
  [[ "$(cat "$FIXTURE/stderr")" == 'Invalid mise bootstrap diagnostic input' ]] ||
    fail 'raw invalid input reached diagnostic error'
  pass
}

reject
reject failure
reject failure 2026.9.2 extra
reject success 2026.9.2
reject cancelled 2026.9.2
reject skipped 2026.9.2
reject unknown 2026.9.2
reject failure ''
reject failure $'2026.9.2\nPRIVATE_TOKEN=secret'
reject failure 'https://private.example/?signature=secret'
reject failure '2026.999.2'
reject $'failure\nsecret' 2026.9.2

# Controlled action failures exit before tests under fail-fast shell semantics.
# The observer is a separate step, just as in Actions; its success or failure
# does not change the failed action status. No installer or network is invoked.
cat > "$FIXTURE/install" <<'INSTALL'
#!/usr/bin/env bash
printf 'private fixture error, token and URL must not be copied\n' >&2
exit "$FIXTURE_EXIT"
INSTALL
chmod +x "$FIXTURE/install"
for original in 22 1 127; do
  status=0
  FIXTURE_EXIT="$original" bash -e -c '"$1"; touch "$2"' \
    fixture "$FIXTURE/install" "$FIXTURE/tests-ran" > /dev/null 2> "$FIXTURE/raw-error" || status=$?
  [[ "$status" == "$original" && ! -e "$FIXTURE/tests-ran" ]] || fail 'original failure or fail-fast changed'
  "$REPORT" failure 2026.9.2 > "$FIXTURE/actual"
  cmp "$FIXTURE/expected" "$FIXTURE/actual" || fail 'failure fixture changed report'
  [[ "$status" == "$original" ]] || fail 'observer masked the original failure'
  pass

  reporter_status=0
  "$REPORT" failure invalid > "$FIXTURE/stdout" 2> "$FIXTURE/stderr" || reporter_status=$?
  [[ "$reporter_status" == 64 && "$status" == "$original" && ! -e "$FIXTURE/tests-ran" ]] ||
    fail 'reporter failure changed the original failure'
  pass
done

# Closing the output stream can break a reporter; the install failure remains.
status=22
reporter_status=0
"$REPORT" failure 2026.9.2 >&- 2> "$FIXTURE/stderr" || reporter_status=$?
[[ "$reporter_status" != 0 && "$status" == 22 ]] || fail 'write failure masked original error'
pass

# Assert the actual workflow scheduling boundary: only the diagnostic has
# continue-on-error, no bootstrap arguments/retries change, and cancellation
# suppresses observation. These are runner conditions, not installer wrappers.
awk '
  function check_step() {
    if (bootstrap) {
      installs++
      if (id != "mise-bootstrap" || version != "2026.9.2" || !cache || coe || guard || run) bad = 1
    }
    if (diagnostic) {
      reports++
      if (!coe || !guard || !outcome || report_version != "2026.9.2" || !run) bad = 1
    }
  }
  /^      - / {
    check_step()
    bootstrap = diagnostic = coe = guard = cache = run = outcome = 0
    id = version = report_version = ""
    diagnostic = ($0 == "      - name: Diagnose toolchain bootstrap failure")
  }
  /^        uses: jdx\/mise-action@/ {
    bootstrap = 1
    if ($2 != "jdx/mise-action@c2a87611a18de5b3828c5652fe268e992400cb5c") bad = 1
  }
  /^        id:/ { id = $2 }
  /^          version:/ { version = $2 }
  /^          cache: (true|false)$/ { cache = 1 }
  /^        continue-on-error:/ { coe = ($2 == "true") }
  /^        if:/ {
    guard = ($0 == "        if: ${{ !cancelled() && steps.mise-bootstrap.outcome == '\''failure'\'' }}")
  }
  /^          BOOTSTRAP_OUTCOME:/ {
    outcome = ($0 == "          BOOTSTRAP_OUTCOME: ${{ steps.mise-bootstrap.outcome }}")
  }
  /^          BOOTSTRAP_VERSION:/ { report_version = $2; gsub(/"/, "", report_version) }
  /^        run:/ {
    run = ($0 == "        run: scripts/ci/mise-bootstrap-diagnostics.sh \"$BOOTSTRAP_OUTCOME\" \"$BOOTSTRAP_VERSION\"")
  }
  END { check_step(); exit bad || installs != 7 || reports != 7 }
' "$WORKFLOW" || fail 'workflow changed bootstrap or diagnostic conditions'
pass

grep -Fq '          scripts/ci/test-mise-bootstrap-diagnostics.sh' "$WORKFLOW" || fail 'regressions missing from classifier lane'
pass

printf 'mise bootstrap diagnostic tests passed (%s cases)\n' "$cases"
