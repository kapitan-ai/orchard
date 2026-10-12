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
# These are installer stand-ins, not a GitHub runner simulation. They prove
# fail-fast before tests and that the observer output never copies raw errors.
# The separate per-job workflow contract below protects runner scheduling.
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
  pass
done

# A reporter write failure must remain a failure for its continue-on-error step.
reporter_status=0
"$REPORT" failure 2026.9.2 >&- 2> "$FIXTURE/stderr" || reporter_status=$?
[[ "$reporter_status" != 0 ]] || fail 'reporter hid a write failure'
pass

# Assert the actual workflow scheduling boundary: only the diagnostic has
# continue-on-error, no bootstrap arguments/retries change, and cancellation
# suppresses observation. These are runner conditions, not installer wrappers.
check_workflow() {
  awk '
  function check_step() {
    if (bootstrap) {
      installs[job]++
      expected = "      - name: Install pinned toolchain\n" \
        "        id: mise-bootstrap\n" \
        "        uses: jdx/mise-action@c2a87611a18de5b3828c5652fe268e992400cb5c # v4.3.0\n" \
        "        with:\n          version: 2026.9.2\n          cache: " \
        (job == "openspec-validation" ? "true" : "false") "\n"
      if (stanza != expected) bad = 1
    }
    if (diagnostic) {
      reports[job]++
      expected = "      - name: Diagnose toolchain bootstrap failure\n" \
        "        if: ${{ !cancelled() && steps.mise-bootstrap.outcome == '\''failure'\'' }}\n" \
        "        continue-on-error: true\n        env:\n" \
        "          BOOTSTRAP_OUTCOME: ${{ steps.mise-bootstrap.outcome }}\n" \
        "          BOOTSTRAP_VERSION: \"2026.9.2\"\n" \
        "        run: scripts/ci/mise-bootstrap-diagnostics.sh \"$BOOTSTRAP_OUTCOME\" \"$BOOTSTRAP_VERSION\"\n"
      if (stanza != expected || previous != "bootstrap") bad = 1
    }
    previous = bootstrap ? "bootstrap" : "other"
  }
  /^  [a-zA-Z0-9_-]+:$/ {
    check_step()
    job = $1; sub(/:$/, "", job)
    bootstrap = diagnostic = 0; stanza = previous = ""
  }
  /^      - / {
    check_step()
    bootstrap = diagnostic = 0; stanza = ""
    diagnostic = ($0 == "      - name: Diagnose toolchain bootstrap failure")
  }
  /^        uses: jdx\/mise-action@|^      - uses: jdx\/mise-action@/ { bootstrap = 1 }
  NF && $0 !~ /^[ \t]*#/ { stanza = stanza $0 "\n" }
  END {
    check_step()
    count = split("linux-portable provider-conformance macos-host mlx-validation packaging-validation app-distribution-validation openspec-validation", jobs, " ")
    for (i = 1; i <= count; i++) if (installs[jobs[i]] != 1 || reports[jobs[i]] != 1) bad = 1
    for (name in installs) if (installs[name] != 1 || reports[name] != 1) bad = 1
    for (name in reports) if (installs[name] != 1 || reports[name] != 1) bad = 1
    exit bad
  }
  ' "$1"
}

check_workflow "$WORKFLOW" || fail 'workflow changed per-job bootstrap or diagnostic conditions'
pass

reject_workflow() {
  if check_workflow "$FIXTURE/mutated.yml"; then fail "$1 escaped the workflow contract"; fi
  pass
}

sed 's/          cache: true/          cache: false/' "$WORKFLOW" > "$FIXTURE/mutated.yml"
reject_workflow 'changed openspec cache input'
sed '/          version: 2026.9.2/a\
          install: false
' "$WORKFLOW" > "$FIXTURE/mutated.yml"
reject_workflow 'extra installer input'
sed '/        id: mise-bootstrap/a\
        if: always()
' "$WORKFLOW" > "$FIXTURE/mutated.yml"
reject_workflow 'changed installer condition'
sed 's/!cancelled()/always()/g' "$WORKFLOW" > "$FIXTURE/mutated.yml"
reject_workflow 'cancellation guard removed'
awk '/^      - name: Diagnose toolchain bootstrap failure/ && !inserted++ { print "      - name: Intervening step"; print "        run: true" } { print }' \
  "$WORKFLOW" > "$FIXTURE/mutated.yml"
reject_workflow 'observer separated from its bootstrap'

cat "$WORKFLOW" > "$FIXTURE/mutated.yml"
cat >> "$FIXTURE/mutated.yml" <<'EXTRA'
  eighth-job:
    steps:
      - uses: jdx/mise-action@c2a87611a18de5b3828c5652fe268e992400cb5c
EXTRA
reject_workflow 'new inline bootstrap without an observer'

sed '/        run: scripts\/ci\/mise-bootstrap-diagnostics.sh/a\
      # A comment after the observer has no scheduling effect.
' "$WORKFLOW" > "$FIXTURE/mutated.yml"
check_workflow "$FIXTURE/mutated.yml" || fail 'ordinary comment changed the workflow contract'
pass

grep -Fq '          scripts/ci/test-mise-bootstrap-diagnostics.sh' "$WORKFLOW" || fail 'regressions missing from classifier lane'
pass

printf 'mise bootstrap diagnostic tests passed (%s cases)\n' "$cases"
