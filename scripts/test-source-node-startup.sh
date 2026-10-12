#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BASH="$BASH"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-node-source-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/repo/bin/lib"
cp "$REPO_ROOT/bin/dev" "$REPO_ROOT/bin/dev-controller" "$REPO_ROOT/bin/dev-node-agent" "$TEST_ROOT/repo/bin/"
cp "$REPO_ROOT/bin/lib/source-node-startup.sh" "$TEST_ROOT/repo/bin/lib/"
touch "$TEST_ROOT/repo/mix.exs"
cat > "$TEST_ROOT/bin/mix" <<'STUB'
#!/usr/bin/env bash
printf 'unexpected mix call\n' >> "$ORCHARD_STARTUP_TEST_SENTINEL"
exit 99
STUB
chmod +x "$TEST_ROOT/bin/mix"

run_refusal() {
  local launcher="$1" profile="$2" status
  shift 2
  set +e
  env -i PATH="$TEST_ROOT/bin:/usr/bin:/bin" HOME="$TEST_ROOT" \
    ORCHARD_STARTUP_TEST_SENTINEL="$TEST_ROOT/sentinel" \
    ORCHARD_NODE_PLATFORM_PROFILE="$profile" "$@" \
    "$TEST_BASH" "$TEST_ROOT/repo/bin/$launcher" > "$TEST_ROOT/output" 2>&1
  status=$?
  set -e
  [[ "$status" == 64 || "$status" == 78 ]] || { cat "$TEST_ROOT/output" >&2; exit 1; }
  [[ ! -e "$TEST_ROOT/sentinel" && ! -e "$TEST_ROOT/repo/tmp" ]] || exit 1
}

for launcher in dev dev-controller dev-node-agent; do
  run_refusal "$launcher" unknown
  run_refusal "$launcher" ''
done
run_refusal dev ubuntu_24_04_x86_64_node
run_refusal dev-controller ubuntu_24_04_x86_64_node
run_refusal dev-node-agent ubuntu_24_04_x86_64_node
run_refusal dev-node-agent ubuntu_24_04_x86_64_node ORCHARD_NODE_ID=fixture
run_refusal dev-node-agent ubuntu_24_04_x86_64_node ORCHARD_NODE_IDENTITY_PATH=/outside/shared
run_refusal dev-node-agent ubuntu_24_04_x86_64_node \
  ORCHARD_NODE_IDENTITY_ROOT="$TEST_ROOT/identity" ORCHARD_BEAM_PEER_GRANT_DESCRIPTOR=/descriptor

printf 'source Node startup: 12 actual-launcher refusal cases passed; no Mix or filesystem bootstrap reached\n'
