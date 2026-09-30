#!/usr/bin/env bash
#
# Regression tests for the Orchard Distribution Pause Control
# (SPEC.md §11.0, openspec packaging-deployment "Native App And DMG
# Distribution Is Paused By A Committed Control").
#
# Every build, signing, image, and publication tool on PATH is a fake that
# records its invocation and exits nonzero, so these tests never assemble,
# sign, notarize, or publish an Orchard.app or DMG even if a guard regresses.
# Active-state behavior is exercised only in copied fixture trees.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB_RELATIVE="scripts/lib/distribution-control.sh"
ENTRYPOINTS=(build-app sign-app build-dmg)
PAUSED_STATUS=78

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-distribution-control.XXXXXX")"
cleanup() {
  chmod -R u+rwx "$TMP_ROOT" 2>/dev/null || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

FAKE_BIN="$TMP_ROOT/fake-bin"
TOOL_LOG="$TMP_ROOT/tool.log"
mkdir -p "$FAKE_BIN"
: > "$TOOL_LOG"

fail() {
  printf 'test-distribution-control: %s\n' "$1" >&2
  exit 1
}

for tool in swift ditto codesign hdiutil amore xcrun plutil shasum jq file install mktemp realpath stapler; do
  cat > "$FAKE_BIN/$tool" <<FAKE
#!/bin/sh
printf '%s %s\n' "$tool" "\$*" >> "$TOOL_LOG"
exit 99
FAKE
  chmod +x "$FAKE_BIN/$tool"
done
FAKE_PATH="$FAKE_BIN:/usr/bin:/bin"

PAYLOAD="$TMP_ROOT/payload"
APP="$TMP_ROOT/Orchard.app"
mkdir -p \
  "$PAYLOAD/releases" \
  "$PAYLOAD/native" \
  "$PAYLOAD/share/bin" \
  "$PAYLOAD/share/launchd" \
  "$PAYLOAD/support/openssl" \
  "$APP/Contents/MacOS" \
  "$APP/Contents/Helpers" \
  "$APP/Contents/Resources/payload"
printf 'fixture\n' > "$APP/Contents/Info.plist"
printf 'Release notes\n' > "$TMP_ROOT/release-notes.md"

# Prints the arguments for an otherwise valid invocation of one entrypoint.
valid_args() {
  local entrypoint="$1"
  local case_dir="$2"

  case "$entrypoint" in
    build-app)
      printf '%s\n' --payload-root "$PAYLOAD" --output "$case_dir/out/Orchard.app" \
        --version 0.1.0 --build pause-test
      ;;
    sign-app)
      printf '%s\n' --identity - "$APP"
      ;;
    build-dmg)
      printf '%s\n' --identity 'Developer ID Application: Example (TEAMID)' \
        --notary-profile orchard-notary --publish-draft \
        --release-notes-file "$TMP_ROOT/release-notes.md" \
        --input "$APP" --output "$case_dir/out/Orchard.dmg"
      ;;
  esac
}

make_fixture_repo() {
  local fixture="$1"

  mkdir -p "$fixture/scripts/lib" "$fixture/packaging"
  cp -p "$REPO_ROOT/$LIB_RELATIVE" "$fixture/$LIB_RELATIVE"
  for entrypoint in "${ENTRYPOINTS[@]}"; do
    cp -p "$REPO_ROOT/scripts/$entrypoint.sh" "$fixture/scripts/$entrypoint.sh"
  done
}

# Runs one entrypoint with valid arguments and asserts a clean paused refusal.
assert_paused_refusal() {
  local name="$1"
  local repo="$2"
  local entrypoint="$3"
  shift 3
  local case_dir="$TMP_ROOT/cases/$name-$entrypoint"
  local status=0
  local args=()
  local arg

  mkdir -p "$case_dir/out"
  printf 'pre-existing operator file\n' > "$case_dir/out/sentinel"
  while IFS= read -r arg; do
    args+=("$arg")
  done < <(valid_args "$entrypoint" "$case_dir")
  if [[ "$entrypoint" == "build-dmg" ]]; then
    cp "$case_dir/out/sentinel" "$case_dir/out/Orchard.dmg"
  fi
  : > "$TOOL_LOG"

  env "$@" PATH="$FAKE_PATH" ORCHARD_AMORE_BIN="$FAKE_BIN/amore" \
    "$repo/scripts/$entrypoint.sh" "${args[@]}" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || status=$?

  [[ "$status" -eq "$PAUSED_STATUS" ]] ||
    fail "$name: $entrypoint exited $status instead of $PAUSED_STATUS"
  grep -Fq 'Orchard.app and DMG distribution is paused' "$case_dir/stderr" ||
    fail "$name: $entrypoint did not report the pause"
  grep -Fq 'packaging/distribution-control' "$case_dir/stderr" ||
    fail "$name: $entrypoint did not name the control file"
  grep -Fq 'accountable product owner' "$case_dir/stderr" ||
    fail "$name: $entrypoint did not state the re-enable approval rule"
  [[ ! -s "$TOOL_LOG" ]] ||
    fail "$name: $entrypoint invoked a build tool while paused: $(cat "$TOOL_LOG")"
  [[ ! -e "$case_dir/out/Orchard.app" ]] ||
    fail "$name: $entrypoint created an app bundle while paused"
  if [[ "$entrypoint" == "build-dmg" ]]; then
    cmp -s "$case_dir/out/sentinel" "$case_dir/out/Orchard.dmg" ||
      fail "$name: build-dmg cleanup touched the output path while paused"
    for sidecar in sha256 before-signing-manifest.json after-signing-manifest.json \
      release-notes.md amore-release.json; do
      [[ ! -e "$case_dir/out/Orchard.dmg.$sidecar" ]] ||
        fail "$name: build-dmg created a $sidecar sidecar while paused"
    done
  fi
}

assert_fixture_paused() {
  local name="$1"
  local fixture="$TMP_ROOT/fixtures/$name"

  for entrypoint in "${ENTRYPOINTS[@]}"; do
    assert_paused_refusal "$name" "$fixture" "$entrypoint"
  done
}

new_fixture() {
  local name="$1"
  local fixture="$TMP_ROOT/fixtures/$name"

  make_fixture_repo "$fixture"
  printf '%s' "$fixture"
}

# The committed control must be paused. Lifting the pause therefore needs a
# reviewed change to this assertion as well as to the control file.
# shellcheck source=scripts/lib/distribution-control.sh
source "$REPO_ROOT/$LIB_RELATIVE"
orchard_distribution_read_state "$REPO_ROOT"
[[ "$ORCHARD_DISTRIBUTION_STATE" == "paused" ]] ||
  fail "committed packaging/distribution-control is not paused ($ORCHARD_DISTRIBUTION_STATE_REASON)"
[[ "$ORCHARD_DISTRIBUTION_STATE_REASON" == "control declares state=paused" ]] ||
  fail "committed control is paused for an unexpected reason: $ORCHARD_DISTRIBUTION_STATE_REASON"

for entrypoint in "${ENTRYPOINTS[@]}"; do
  assert_paused_refusal committed "$REPO_ROOT" "$entrypoint"
done

# Plausible environment claims must not resume distribution.
active_elsewhere="$TMP_ROOT/elsewhere"
mkdir -p "$active_elsewhere/packaging"
printf 'state=active\n' > "$active_elsewhere/packaging/distribution-control"
for entrypoint in "${ENTRYPOINTS[@]}"; do
  assert_paused_refusal env-override "$REPO_ROOT" "$entrypoint" \
    ORCHARD_DISTRIBUTION_STATE=active \
    ORCHARD_DISTRIBUTION_STATE_REASON=override \
    ORCHARD_DISTRIBUTION_CONTROL_PATH="$active_elsewhere/packaging/distribution-control" \
    ORCHARD_DISTRIBUTION_PAUSED_STATUS=0 \
    ORCHARD_DISTRIBUTION_ACTIVE=1 \
    ORCHARD_DISTRIBUTION=active \
    ORCHARD_RESUME_DISTRIBUTION=1 \
    REPO_ROOT="$active_elsewhere"
done

# Help stays available while paused and invokes no build tool.
for entrypoint in "${ENTRYPOINTS[@]}"; do
  : > "$TOOL_LOG"
  help_out="$TMP_ROOT/help-$entrypoint.out"
  PATH="$FAKE_PATH" "$REPO_ROOT/scripts/$entrypoint.sh" --help > "$help_out" ||
    fail "$entrypoint --help failed while paused"
  grep -Fq 'Usage:' "$help_out" || fail "$entrypoint --help did not print usage"
  [[ ! -s "$TOOL_LOG" ]] || fail "$entrypoint --help invoked a build tool"
done

# Every malformed or unsafe control shape fails closed.
fixture="$(new_fixture missing)"
assert_fixture_paused missing

fixture="$(new_fixture directory)"
mkdir "$fixture/packaging/distribution-control"
assert_fixture_paused directory

fixture="$(new_fixture symlink)"
ln -s "$active_elsewhere/packaging/distribution-control" \
  "$fixture/packaging/distribution-control"
assert_fixture_paused symlink

fixture="$(new_fixture empty)"
: > "$fixture/packaging/distribution-control"
assert_fixture_paused empty

fixture="$(new_fixture comments-only)"
printf '# state=active\n\n' > "$fixture/packaging/distribution-control"
assert_fixture_paused comments-only

fixture="$(new_fixture explicit-paused)"
printf 'state=paused\n' > "$fixture/packaging/distribution-control"
assert_fixture_paused explicit-paused

fixture="$(new_fixture duplicate-active)"
printf 'state=active\nstate=active\n' > "$fixture/packaging/distribution-control"
assert_fixture_paused duplicate-active

fixture="$(new_fixture conflicting)"
printf 'state=paused\nstate=active\n' > "$fixture/packaging/distribution-control"
assert_fixture_paused conflicting

fixture="$(new_fixture unrecognized-line)"
printf 'state=active\nresume=true\n' > "$fixture/packaging/distribution-control"
assert_fixture_paused unrecognized-line

for value in Active ACTIVE 'active ' ' active' yes true 1 ''; do
  slug="value-$(printf '%s' "$value" | tr -c 'A-Za-z0-9' '_')"
  fixture="$(new_fixture "$slug")"
  printf 'state=%s\n' "$value" > "$fixture/packaging/distribution-control"
  assert_fixture_paused "$slug"
done

fixture="$(new_fixture crlf)"
printf 'state=active\r\n' > "$fixture/packaging/distribution-control"
assert_fixture_paused crlf

fixture="$(new_fixture spaced-key)"
printf 'state = active\n' > "$fixture/packaging/distribution-control"
assert_fixture_paused spaced-key

if [[ "$(id -u)" -ne 0 ]]; then
  fixture="$(new_fixture unreadable)"
  printf 'state=active\n' > "$fixture/packaging/distribution-control"
  chmod 000 "$fixture/packaging/distribution-control"
  assert_fixture_paused unreadable
fi

fixture="$(new_fixture missing-library)"
rm "$fixture/$LIB_RELATIVE"
printf 'state=active\n' > "$fixture/packaging/distribution-control"
for entrypoint in "${ENTRYPOINTS[@]}"; do
  : > "$TOOL_LOG"
  status=0
  PATH="$FAKE_PATH" "$fixture/scripts/$entrypoint.sh" \
    > /dev/null 2>&1 || status=$?
  [[ "$status" -eq "$PAUSED_STATUS" ]] ||
    fail "missing-library: $entrypoint exited $status instead of $PAUSED_STATUS"
  [[ ! -s "$TOOL_LOG" ]] || fail "missing-library: $entrypoint invoked a build tool"
done

# An active fixture passes the guard and reaches the entrypoint's own usage
# validation, which proves the guard reads the committed control rather than
# refusing unconditionally. No build tool runs because arguments are missing.
fixture="$(new_fixture active)"
printf '# Approved resume fixture.\n\nstate=active\n' > "$fixture/packaging/distribution-control"
for entrypoint in "${ENTRYPOINTS[@]}"; do
  : > "$TOOL_LOG"
  status=0
  PATH="$FAKE_PATH" "$fixture/scripts/$entrypoint.sh" \
    > /dev/null 2> "$TMP_ROOT/active-$entrypoint.err" || status=$?
  [[ "$status" -eq 64 ]] ||
    fail "active: $entrypoint exited $status instead of usage status 64"
  if grep -Fq 'distribution is paused' "$TMP_ROOT/active-$entrypoint.err"; then
    fail "active: $entrypoint reported a pause for an active control"
  fi
  [[ ! -s "$TOOL_LOG" ]] || fail "active: $entrypoint invoked a build tool"
done

printf 'distribution pause control tests passed\n'
