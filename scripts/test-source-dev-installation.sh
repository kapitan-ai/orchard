#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-source-installation-test.XXXXXX")"
INSTALLATION_UUID=11111111-1111-4111-8111-111111111111
OPERATION_UUID=22222222-2222-4222-8222-222222222222
CONTROLLER_UUID=33333333-3333-4333-8333-333333333333
NODE_UUID=44444444-4444-4444-8444-444444444444
PRIVATE_IPV4=10.77.0.10
CASE_NUMBER=0
LOCK_PID=""

cleanup() {
  if [[ -n "$LOCK_PID" ]]; then
    kill "$LOCK_PID" >/dev/null 2>&1 || true
    wait "$LOCK_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'test-source-dev-installation: %s\n' "$1" >&2
  exit 1
}

new_fixture() {
  CASE_NUMBER=$((CASE_NUMBER + 1))
  FIXTURE="$TMP_ROOT/case-$CASE_NUMBER"
  SOURCE="$FIXTURE/opt/orchard/source"
  PROBES="$FIXTURE/probes"
  mkdir -p "$SOURCE" "$PROBES" "$FIXTURE/etc"
  cat > "$FIXTURE/etc/os-release" <<'EOF'
ID=ubuntu
VERSION_ID="24.04"
EOF

  mkdir -p \
    "$SOURCE/native/orchard_tokenizer" \
    "$SOURCE/native/orchard_worker_mlx/src/orchard_worker_mlx/generated" \
    "$SOURCE/proto/orchard/worker/tooling" \
    "$SOURCE/proto/orchard/worker/v1" \
    "$SOURCE/openspec/specs/runtime-endpoints" \
    "$SOURCE/apps/orchard_shared/lib/cluster/v1" \
    "$SOURCE/rel/linux/source-dev" \
    "$SOURCE/packaging/linux/appliance"
  cp -R "$REPO_ROOT/rel/linux/source-dev/systemd" "$SOURCE/rel/linux/source-dev/systemd"
  cp -R "$REPO_ROOT/rel/linux/source-dev/postgresql" "$SOURCE/rel/linux/source-dev/postgresql"
  cp "$REPO_ROOT/rel/linux/source-dev/worker-custody.json" "$SOURCE/rel/linux/source-dev/worker-custody.json"
  cp "$REPO_ROOT/packaging/linux/appliance/postgresql-16-closure.json" "$SOURCE/packaging/linux/appliance/postgresql-16-closure.json"
  printf 'defmodule Fixture.MixProject do\nend\n' > "$SOURCE/mix.exs"
  printf '0.1.0-dev\n' > "$SOURCE/VERSION"
  printf '{:fixture, "1.0.0"}\n' > "$SOURCE/mix.lock"
  printf '[tools]\nelixir = "1.20.0-otp-29"\nerlang = "29.0.2"\n' > "$SOURCE/mise.toml"
  printf '{"lockfileVersion":3}\n' > "$SOURCE/package-lock.json"
  printf 'tokenizer-lock\n' > "$SOURCE/native/orchard_tokenizer/uv.lock"
  printf 'worker-lock\n' > "$SOURCE/native/orchard_worker_mlx/uv.lock"
  printf 'proto-lock\n' > "$SOURCE/proto/orchard/worker/tooling/uv.lock"
  printf 'syntax = "proto3";\n' > "$SOURCE/proto/orchard/worker/v1/worker_runtime.proto"
  printf 'descriptor\n' > "$SOURCE/proto/orchard/worker/v1/worker_runtime.descriptor.pb"
  printf '# runtime endpoints\n' > "$SOURCE/openspec/specs/runtime-endpoints/spec.md"
  printf 'generated\n' > "$SOURCE/native/orchard_worker_mlx/src/orchard_worker_mlx/generated/worker_pb2.py"
  printf 'generated\n' > "$SOURCE/apps/orchard_shared/lib/cluster/v1/runtime.pb.ex"
  mkdir -p "$SOURCE/bin/lib"
  cp "$REPO_ROOT/bin/dev-controller" "$SOURCE/bin/dev-controller"
  cp "$REPO_ROOT/bin/dev-node-agent" "$SOURCE/bin/dev-node-agent"
  cp "$REPO_ROOT/bin/source-dev-role-guard" "$SOURCE/bin/source-dev-role-guard"
  cp "$REPO_ROOT/bin/orchard-source-postgresql" "$SOURCE/bin/orchard-source-postgresql"
  cp "$REPO_ROOT/bin/orchard-source-composition" "$SOURCE/bin/orchard-source-composition"
  cp "$REPO_ROOT/bin/lib/source-dev-postgresql.sh" "$SOURCE/bin/lib/source-dev-postgresql.sh"
  cp "$REPO_ROOT/bin/lib/source-dev-composition.sh" "$SOURCE/bin/lib/source-dev-composition.sh"
  chmod 0755 \
    "$SOURCE/bin/source-dev-role-guard" \
    "$SOURCE/bin/dev-controller" \
    "$SOURCE/bin/dev-node-agent" \
    "$SOURCE/bin/orchard-source-postgresql" \
    "$SOURCE/bin/orchard-source-composition"

  git -C "$SOURCE" init -q
  git -C "$SOURCE" config user.name 'Orchard Test'
  git -C "$SOURCE" config user.email 'orchard-test@example.invalid'
  git -C "$SOURCE" remote add origin https://github.com/kapitan-ai/orchard.git
  git -C "$SOURCE" add .
  git -C "$SOURCE" commit -qm fixture
}

run_installation() {
  env \
    ORCHARD_SOURCE_DEV_ROOT="$FIXTURE" \
    ORCHARD_SOURCE_DEV_SOURCE="$SOURCE" \
    ORCHARD_SOURCE_DEV_PROBE_DIR="$PROBES" \
    ORCHARD_SOURCE_DEV_TESTING=1 \
    ORCHARD_SOURCE_DEV_TEST_ARCH=x86_64 \
    ORCHARD_SOURCE_DEV_TEST_INSTALLATION_UUID="$INSTALLATION_UUID" \
    ORCHARD_SOURCE_DEV_TEST_OPERATION_UUID="$OPERATION_UUID" \
    "$REPO_ROOT/bin/orchard-source-installation" "$@"
}

run_composition() {
  env \
    ORCHARD_SOURCE_DEV_ROOT="$FIXTURE" \
    ORCHARD_SOURCE_DEV_SOURCE="$SOURCE" \
    ORCHARD_SOURCE_DEV_TESTING=1 \
    ORCHARD_SOURCE_DEV_CONTROLLER_UUID="$CONTROLLER_UUID" \
    ORCHARD_SOURCE_DEV_NODE_UUID="$NODE_UUID" \
    ORCHARD_SOURCE_DEV_PRIVATE_IPV4="$PRIVATE_IPV4" \
    "$REPO_ROOT/bin/orchard-source-composition" "$@"
}

expect_failure() {
  local expected=$1
  shift
  local output="$FIXTURE/failure.out"
  if "$@" > "$output" 2>&1; then
    fail "command unexpectedly succeeded; expected $expected"
  fi
  grep -F "$expected" "$output" >/dev/null || {
    cat "$output" >&2
    fail "failure did not contain: $expected"
  }
}

assert_no_activation() {
  [[ ! -e "$FIXTURE/etc/orchard/source-dev/activation-authorized" ]] || fail "preparation authorized activation"
  [[ ! -e "$FIXTURE/var/lib/postgresql/16/orchard/PG_VERSION" ]] || fail "preparation initialized PostgreSQL"
  [[ ! -e "$FIXTURE/etc/orchard/node/node-agent.env" ]] || fail "preparation enrolled or configured a Node"
  [[ ! -e "$FIXTURE/var/lib/orchard/node/identity" ]] || fail "preparation created a Node identity"
  [[ ! -d "$FIXTURE/opt/orchard/workers" ]] || fail "preparation installed a provider"
  [[ ! -d "$FIXTURE/var/lib/orchard/models" || -z "$(find "$FIXTURE/var/lib/orchard/models" -mindepth 1 -print -quit)" ]] ||
    fail "preparation installed a model"
  [[ ! -d "$FIXTURE/etc/systemd/system/multi-user.target.wants" ]] ||
    [[ -z "$(find "$FIXTURE/etc/systemd/system/multi-user.target.wants" -mindepth 1 -print -quit)" ]] ||
    fail "preparation enabled a unit"
}

new_fixture
run_installation classify | grep -Fx clean >/dev/null || fail "clean fixture was not classified clean"
run_installation prepare >/dev/null
MANIFEST="$FIXTURE/var/lib/orchard/install/manifest.json"
RECEIPT="$FIXTURE/var/lib/orchard/install/receipts/prepare.json"
jq -e \
  --arg uuid "$INSTALLATION_UUID" \
  --arg commit "$(git -C "$SOURCE" rev-parse HEAD)" \
  --arg tree "$(git -C "$SOURCE" rev-parse HEAD^{tree})" '
    .installation_uuid == $uuid and
    .source.commit == $commit and
    .source.tree == $tree and
    .source.clean == true and
    .source.generated_output_drift == false and
    .activation == "disabled" and
    .support_status == "unqualified" and
    (.dependency_locks | length) == 5 and
    (.generated_outputs | length) == 3 and
    .postgresql.major == 16 and
    .postgresql.activation == "disabled" and
    (.postgresql.dependencies_sha256 | test("^[0-9a-f]{64}$")) and
    (.postgresql.closure_sha256 | test("^[0-9a-f]{64}$")) and
    .worker_custody.policy_path == "rel/linux/source-dev/worker-custody.json" and
    (.worker_custody.policy_sha256 | test("^[0-9a-f]{64}$")) and
    .worker_custody.activation == "disabled" and
    .worker_custody.authority == "custody_only" and
    .worker_custody.node_uuid == null and
    .source.repository == "https://github.com/kapitan-ai/orchard.git" and
    .compatibility.schema_range == {state: "undeclared"} and
    .compatibility.runtime_endpoint_contract.state == "undeclared" and
    (.compatibility.runtime_endpoint_contract.sha256 | test("^[0-9a-f]{64}$")) and
    (.compatibility.worker_runtime_protocol.sha256 | test("^[0-9a-f]{64}$")) and
    .compatibility.worker_runtime_protocol.version == "v1" and
    .compatibility.controller_node == {state: "undeclared"} and
    ([.dependency_locks[].sha256, .generated_outputs[].sha256, .toolchain.sha256] | all(test("^[0-9a-f]{64}$")))
  ' "$MANIFEST" >/dev/null || fail "source manifest lacks exact provenance"
jq -e --arg operation "$OPERATION_UUID" '
  .generation == 4 and .operation_uuid == $operation and .phase == "source_prepared"
' "$RECEIPT" >/dev/null || fail "prepare receipt is not durable and monotonic"
jq -e '
  .activation == "disabled" and
  .roles.controller.user == "orchard-controller" and
  .roles.migration.user == "orchard-db-migrate" and
  .roles.backup.user == "orchard-db-backup" and
  .roles.database_socket.group == "orchard-postgresql" and
  .roles.postgresql.user == "postgres" and
  .roles.node_agent.user == "orchard-node" and
  .roles.worker.user == "orchard-worker"
' "$FIXTURE/etc/orchard/source-dev/identities.json" >/dev/null || fail "role identity manifest is incomplete"
[[ "$(stat -c %a "$FIXTURE/var/lib/orchard/install")" == 700 ]] || fail "install state mode is not 0700"
[[ "$(stat -c %a "$FIXTURE/var/lib/orchard/controller")" == 700 ]] || fail "Controller state mode is not 0700"
[[ "$(stat -c %a "$FIXTURE/var/lib/orchard/models")" == 750 ]] || fail "model root mode is not 0750"
grep -F 'User=orchard-controller' "$FIXTURE/etc/systemd/system/orchard-controller.service" >/dev/null || fail "Controller identity is absent"
grep -F 'orchard-source-postgresql start' "$FIXTURE/etc/systemd/system/orchard-postgresql.service" >/dev/null || fail "PostgreSQL lifecycle coordinator is absent"
grep -F 'User=orchard-node' "$FIXTURE/etc/systemd/system/orchard-node-agent.service" >/dev/null || fail "Node identity is absent"
grep -F 'KillMode=control-group' "$FIXTURE/etc/systemd/system/orchard-node-agent.service" >/dev/null || fail "Node custody is absent"
grep -F 'ExecStartPre=+/opt/orchard/source/bin/source-dev-role-guard controller' "$FIXTURE/etc/systemd/system/orchard-controller.service" >/dev/null ||
  fail "Controller lacks privileged fail-closed preflight"
grep -F 'ExecStart=/opt/orchard/source/bin/dev-controller' "$FIXTURE/etc/systemd/system/orchard-controller.service" >/dev/null ||
  fail "Controller does not drop to its configured service identity"
grep -F 'ExecStartPre=+/opt/orchard/source/bin/source-dev-role-guard node-agent' "$FIXTURE/etc/systemd/system/orchard-node-agent.service" >/dev/null ||
  fail "Node lacks privileged fail-closed preflight"
grep -F 'ExecStart=/opt/orchard/source/bin/dev-node-agent' "$FIXTURE/etc/systemd/system/orchard-node-agent.service" >/dev/null ||
  fail "Node does not drop to its configured service identity"
grep -F 'User=root' "$FIXTURE/etc/systemd/system/orchard-worker-launcher.service" >/dev/null || fail "bounded Worker launcher identity is absent"
grep -F 'ConditionPathExists=/etc/orchard/source-dev/activation-authorized.json' "$FIXTURE/etc/systemd/system/orchard-source-dev.target" >/dev/null ||
  fail "target lacks its absent activation gate"
grep -F 'RefuseManualStart=yes' "$FIXTURE/etc/systemd/system/orchard-source-dev.target" >/dev/null || fail "target allows manual activation"
cat > "$FIXTURE/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/false
postgres:x:110:110:postgres:/var/lib/postgresql:/usr/sbin/nologin
orchard-controller:x:991:991:controller:/var/lib/orchard/controller:/usr/sbin/nologin
orchard-db-migrate:x:992:992:migration:/var/lib/orchard/install:/usr/sbin/nologin
orchard-db-backup:x:993:993:backup:/var/backups/orchard:/usr/sbin/nologin
orchard-node:x:994:994:node:/var/lib/orchard/node:/usr/sbin/nologin
orchard-worker:x:995:995:worker:/var/lib/orchard/worker:/usr/sbin/nologin
EOF
cat > "$FIXTURE/etc/group" <<'EOF'
root:x:0:
postgres:x:110:
orchard-controller:x:991:
orchard-db-migrate:x:992:
orchard-db-backup:x:993:
orchard-node:x:994:
orchard-worker:x:995:
EOF
if ! systemd-analyze verify --root="$FIXTURE" \
  orchard.slice orchard-control.slice orchard-database.slice orchard-lifecycle.slice \
  orchard-postgresql.service orchard-db-migrate.service orchard-db-backup.service \
  orchard-controller.service orchard-node-agent.service \
  orchard-worker-launcher.socket orchard-worker-launcher.service \
  orchard-source-dev.target > /dev/null 2> "$FIXTURE/systemd-verify.err"; then
  sed -E \
    -e '/Unit (sysinit|basic|network-online|slices|shutdown)\.target not found/d' \
    -e '/Failed to create orchard.*: No such file or directory/d' \
    "$FIXTURE/systemd-verify.err" > "$FIXTURE/systemd-verify.unexpected"
  [[ ! -s "$FIXTURE/systemd-verify.unexpected" ]] || {
    cat "$FIXTURE/systemd-verify.unexpected" >&2
    fail "source-development unit verification failed"
  }
fi
assert_no_activation
run_installation classify | grep -Fx prepared >/dev/null || fail "prepared fixture was not classified prepared"
run_composition prepare >/dev/null
COMPOSITION="$FIXTURE/etc/orchard/source-dev/composition.json"
COMPOSITION_RECEIPT="$FIXTURE/var/lib/orchard/install/receipts/composition.json"
CONTROLLER_ENV="$FIXTURE/etc/orchard/controller/controller.env"
NODE_ENV="$FIXTURE/etc/orchard/node/node-agent.env"
jq -e \
  --arg installation "$INSTALLATION_UUID" \
  --arg controller "$CONTROLLER_UUID" \
  --arg node "$NODE_UUID" \
  --arg address "$PRIVATE_IPV4" '
    .activation == "disabled" and .support_status == "unqualified" and
    .installation_uuid == $installation and .controller.id == $controller and
    .node.id == $node and .host.private_ipv4 == $address and
    .controller.beam_name == "orchard_controller_33333333333343338333333333333333@10.77.0.10" and
    .node.beam_name == "orchard_node_agent_44444444444444448444444444444444@10.77.0.10" and
    .ordering == ["postgresql", "migration", "controller", "node_agent"] and
    .fallback == {grpc: false, cookie: false, static_target: false} and
    .authority.locality == "none"
  ' "$COMPOSITION" >/dev/null || fail "composition does not preserve exact identity and authority"
jq -e '.phase == "composition_prepared_inert" and .activation == "disabled"' "$COMPOSITION_RECEIPT" >/dev/null ||
  fail "composition receipt is not inert and durable"
grep -Fx 'ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam' "$CONTROLLER_ENV" >/dev/null || fail "Controller does not use BEAM"
grep -Fx 'ORCHARD_ALLOW_STATIC_RUNTIME_TARGET_FALLBACK=false' "$CONTROLLER_ENV" >/dev/null || fail "Controller permits static fallback"
grep -Fx 'ORCHARD_NODE_AGENT_GRPC_LISTENER_ENABLED=false' "$NODE_ENV" >/dev/null || fail "Node gRPC listener is enabled"
if grep -E 'ORCHARD_BEAM_COOKIE_FILE|ORCHARD_RUNTIME_ENDPOINT_TARGETS|ORCHARD_RUNTIME_CLIENT_TARGETS' "$CONTROLLER_ENV" "$NODE_ENV" >/dev/null; then
  fail "composition emitted shared-cookie or static-target authority"
fi
[[ ! -e "$FIXTURE/etc/orchard/source-dev/activation-authorized.json" ]] || fail "composition authorized activation"
[[ ! -e "$FIXTURE/var/lib/postgresql/16/orchard/PG_VERSION" ]] || fail "composition initialized PostgreSQL"
[[ ! -e "$FIXTURE/var/lib/orchard/node/identity" ]] || fail "composition created a Node identity"
[[ ! -d "$FIXTURE/opt/orchard/workers" ]] || fail "composition installed a provider"
expect_failure 'required authority file is missing or unsafe' bash -c '
  set -a
  source "$1"
  set +a
  ORCHARD_SOURCE_DEV_ROOT="$2" ORCHARD_SOURCE_DEV_TESTING=1 "$3" controller
' _ "$CONTROLLER_ENV" "$FIXTURE" "$SOURCE/bin/source-dev-role-guard"

mkdir -p \
  "$FIXTURE/var/lib/orchard/controller/beam/authorization-root" \
  "$FIXTURE/var/lib/orchard/controller/beam/node-trust" \
  "$FIXTURE/var/lib/orchard/node/identity" \
  "$FIXTURE/var/lib/orchard/node/beam"
chmod 0700 \
  "$FIXTURE/var/lib/orchard/controller/beam/authorization-root" \
  "$FIXTURE/var/lib/orchard/controller/beam/node-trust" \
  "$FIXTURE/var/lib/orchard/node/identity" \
  "$FIXTURE/var/lib/orchard/node/beam"
printf '%s\n' "$NODE_UUID" > "$FIXTURE/var/lib/orchard/node/identity/node-id"
printf '[].\n' > "$FIXTURE/var/lib/orchard/controller/beam/ssl-dist.conf"
printf '[].\n' > "$FIXTURE/var/lib/orchard/node/beam/ssl-dist.conf"
controller_optfile_sha=$(sha256sum "$FIXTURE/var/lib/orchard/controller/beam/ssl-dist.conf" | cut -d ' ' -f1)
node_optfile_sha=$(sha256sum "$FIXTURE/var/lib/orchard/node/beam/ssl-dist.conf" | cut -d ' ' -f1)
jq -n \
  --arg controller "$CONTROLLER_UUID" --arg node "$NODE_UUID" \
  --arg controller_name 'orchard_controller_33333333333343338333333333333333@10.77.0.10' \
  --arg node_name 'orchard_node_agent_44444444444444448444444444444444@10.77.0.10' \
  --arg optfile /var/lib/orchard/controller/beam/ssl-dist.conf --arg digest "$controller_optfile_sha" '
  {schema_version: 1, role: "controller", generation: 1, contract_version: 1,
   grant_id: "55555555-5555-4555-8555-555555555555", controller_id: $controller, node_id: $node,
   controller_beam_name: $controller_name, node_beam_name: $node_name,
   optfile_path: $optfile, optfile_digest_sha256: $digest}
' > "$FIXTURE/var/lib/orchard/controller/beam/launch.json"
jq -n \
  --arg controller "$CONTROLLER_UUID" --arg node "$NODE_UUID" \
  --arg controller_name 'orchard_controller_33333333333343338333333333333333@10.77.0.10' \
  --arg node_name 'orchard_node_agent_44444444444444448444444444444444@10.77.0.10' \
  --arg optfile /var/lib/orchard/node/beam/ssl-dist.conf --arg digest "$node_optfile_sha" '
  {schema_version: 1, role: "node_agent", generation: 1, contract_version: 1,
   grant_id: "55555555-5555-4555-8555-555555555555", controller_id: $controller, node_id: $node,
   controller_beam_name: $controller_name, node_beam_name: $node_name,
   optfile_path: $optfile, optfile_digest_sha256: $digest}
' > "$FIXTURE/var/lib/orchard/node/beam/launch.json"
jq -n --arg controller "$CONTROLLER_UUID" '
  {grant_id: "55555555-5555-4555-8555-555555555555", generation: 1,
   controller_id: $controller, control_endpoint: "https://10.77.0.10:8444"}
' > "$FIXTURE/var/lib/orchard/node/beam/peer-grant.json"
chmod 0600 \
  "$FIXTURE/var/lib/orchard/node/identity/node-id" \
  "$FIXTURE/var/lib/orchard/controller/beam/launch.json" \
  "$FIXTURE/var/lib/orchard/controller/beam/ssl-dist.conf" \
  "$FIXTURE/var/lib/orchard/node/beam/peer-grant.json" \
  "$FIXTURE/var/lib/orchard/node/beam/launch.json" \
  "$FIXTURE/var/lib/orchard/node/beam/ssl-dist.conf"
composition_sha=$(sha256sum "$COMPOSITION" | cut -d ' ' -f1)
jq -n --arg installation "$INSTALLATION_UUID" --arg composition_sha "$composition_sha" '
  {schema_version: 1, installation_uuid: $installation, composition_sha256: $composition_sha,
   authorized: true, scope: "authenticated_same_host_start"}
' > "$FIXTURE/etc/orchard/source-dev/activation-authorized.json"
chmod 0600 "$FIXTURE/etc/orchard/source-dev/activation-authorized.json"

(
  set -a
  # shellcheck disable=SC1090
  source "$CONTROLLER_ENV"
  set +a
  ORCHARD_SOURCE_DEV_ROOT="$FIXTURE" ORCHARD_SOURCE_DEV_TESTING=1 \
    "$SOURCE/bin/source-dev-role-guard" controller
) || fail "Controller role guard rejected exact composition"
(
  set -a
  # shellcheck disable=SC1090
  source "$NODE_ENV"
  set +a
  ORCHARD_SOURCE_DEV_ROOT="$FIXTURE" ORCHARD_SOURCE_DEV_TESTING=1 \
    "$SOURCE/bin/source-dev-role-guard" node-agent
) || fail "Node role guard rejected exact composition"
expect_failure 'shared/static BEAM cookies are forbidden' bash -c '
  set -a
  source "$1"
  set +a
  ORCHARD_BEAM_COOKIE_FILE=/tmp/forbidden ORCHARD_SOURCE_DEV_ROOT="$2" ORCHARD_SOURCE_DEV_TESTING=1 "$3" controller
' _ "$CONTROLLER_ENV" "$FIXTURE" "$SOURCE/bin/source-dev-role-guard"
expect_failure 'node-agent BEAM identity differs' bash -c '
  set -a
  source "$1"
  set +a
  ORCHARD_BEAM_NODE_NAME=orchard_node_agent@127.0.0.1 ORCHARD_SOURCE_DEV_ROOT="$2" ORCHARD_SOURCE_DEV_TESTING=1 "$3" node-agent
' _ "$NODE_ENV" "$FIXTURE" "$SOURCE/bin/source-dev-role-guard"
cp "$FIXTURE/var/lib/orchard/node/identity/node-id" "$TMP_ROOT/node-id"
printf '%s\n' "$CONTROLLER_UUID" > "$FIXTURE/var/lib/orchard/node/identity/node-id"
expect_failure 'Node identity custody differs' bash -c '
  set -a
  source "$1"
  set +a
  ORCHARD_SOURCE_DEV_ROOT="$2" ORCHARD_SOURCE_DEV_TESTING=1 "$3" node-agent
' _ "$NODE_ENV" "$FIXTURE" "$SOURCE/bin/source-dev-role-guard"
mv "$TMP_ROOT/node-id" "$FIXTURE/var/lib/orchard/node/identity/node-id"
expect_failure 'private address must be an RFC1918 IPv4 literal' env \
  ORCHARD_SOURCE_DEV_ROOT="$FIXTURE" ORCHARD_SOURCE_DEV_SOURCE="$SOURCE" ORCHARD_SOURCE_DEV_TESTING=1 \
  ORCHARD_SOURCE_DEV_CONTROLLER_UUID="$CONTROLLER_UUID" ORCHARD_SOURCE_DEV_NODE_UUID="$NODE_UUID" \
  ORCHARD_SOURCE_DEV_PRIVATE_IPV4=127.0.0.1 "$REPO_ROOT/bin/orchard-source-composition" validate
expect_failure 'identities must be distinct' env \
  ORCHARD_SOURCE_DEV_ROOT="$FIXTURE" ORCHARD_SOURCE_DEV_SOURCE="$SOURCE" ORCHARD_SOURCE_DEV_TESTING=1 \
  ORCHARD_SOURCE_DEV_CONTROLLER_UUID="$NODE_UUID" ORCHARD_SOURCE_DEV_NODE_UUID="$NODE_UUID" \
  ORCHARD_SOURCE_DEV_PRIVATE_IPV4="$PRIVATE_IPV4" "$REPO_ROOT/bin/orchard-source-composition" validate
composition_digest=$(sha256sum "$COMPOSITION" "$COMPOSITION_RECEIPT" "$CONTROLLER_ENV" "$NODE_ENV")
rm "$FIXTURE/etc/orchard/source-dev/activation-authorized.json"
run_composition prepare >/dev/null
[[ "$(sha256sum "$COMPOSITION" "$COMPOSITION_RECEIPT" "$CONTROLLER_ENV" "$NODE_ENV")" == "$composition_digest" ]] ||
  fail "idempotent composition rewrote durable state"
manifest_digest=$(sha256sum "$MANIFEST")
receipt_digest=$(sha256sum "$RECEIPT")
run_installation prepare >/dev/null
[[ "$(sha256sum "$MANIFEST")" == "$manifest_digest" ]] || fail "idempotent prepare rewrote the manifest"
[[ "$(sha256sum "$RECEIPT")" == "$receipt_digest" ]] || fail "idempotent prepare rewrote the receipt"

new_fixture
printf 'dirty\n' > "$SOURCE/untracked"
expect_failure 'canonical source checkout is dirty' run_installation prepare
[[ ! -e "$FIXTURE/var/lib/orchard/install" ]] || fail "dirty source mutated installation state"

new_fixture
chmod 0775 "$FIXTURE/opt/orchard"
expect_failure 'unsafe ancestor owner or writable mode' run_installation prepare
[[ ! -e "$FIXTURE/var/lib/orchard/install" ]] || fail "writable source ancestor mutated installation state"

new_fixture
chmod 0664 "$SOURCE/mix.exs"
expect_failure 'canonical source contains unowned or writable path' run_installation prepare
[[ ! -e "$FIXTURE/var/lib/orchard/install" ]] || fail "writable source file mutated installation state"

new_fixture
rm "$SOURCE/mix.lock"
git -C "$SOURCE" add -u
git -C "$SOURCE" commit -qm remove-lock
expect_failure 'required provenance file is missing or unsafe: mix.lock' run_installation prepare

new_fixture
alternate="$FIXTURE/srv/orchard"
mkdir -p "$alternate"
expect_failure 'source checkout must be the canonical /opt/orchard/source' env \
  ORCHARD_SOURCE_DEV_ROOT="$FIXTURE" ORCHARD_SOURCE_DEV_SOURCE="$alternate" ORCHARD_SOURCE_DEV_TESTING=1 \
  "$REPO_ROOT/bin/orchard-source-installation" prepare

for conflict in \
  'claims|checkout|/srv/orchard/source|foreign|checkout conflict' \
  'claims|installation|22222222-2222-4222-8222-222222222222|foreign|installation conflict' \
  'claims|state|/var/lib/orchard-other|ambiguous|state conflict' \
  'processes|4100|orchard_controller|foreign|process conflict' \
  'processes|4101|orchard_node_agent|ambiguous|process conflict' \
  'listeners|0.0.0.0:8443|foreign||listener conflict' \
  'listeners|0.0.0.0:52171|ambiguous||listener conflict' \
  'epmd-names|epmd:4369|foreign||EPMD/BEAM conflict' \
  'epmd-names|orchard_controller_deadbeef@10.0.0.2|foreign||EPMD/BEAM conflict'; do
  new_fixture
  IFS='|' read -r probe first second third expected <<< "$conflict"
  case "$probe" in
    claims|processes) printf '%s\t%s\t%s\n' "$first" "$second" "$third" > "$PROBES/$probe.tsv" ;;
    listeners|epmd-names) printf '%s\t%s\n' "$first" "$second" > "$PROBES/$probe.tsv" ;;
  esac
  expect_failure "$expected" run_installation prepare
  [[ ! -e "$FIXTURE/var/lib/orchard/install" ]] || fail "$expected mutated installation state"
done

new_fixture
mkdir -p "$FIXTURE/var/lib/orchard/appliance"
expect_failure 'a legacy package installation state identity claims the host' run_installation prepare
[[ ! -e "$FIXTURE/var/lib/orchard/install" ]] || fail "legacy state conflict mutated installation state"

new_fixture
mkdir -p "$FIXTURE/var/lib/orchard/other"
printf '{}\n' > "$FIXTURE/var/lib/orchard/other/manifest.json"
expect_failure 'an alternate installation manifest claims state' run_installation prepare
[[ ! -e "$FIXTURE/var/lib/orchard/install" ]] || fail "alternate manifest conflict mutated installation state"

new_fixture
expect_failure 'installation UUID is invalid' env \
  ORCHARD_SOURCE_DEV_ROOT="$FIXTURE" \
  ORCHARD_SOURCE_DEV_SOURCE="$SOURCE" \
  ORCHARD_SOURCE_DEV_PROBE_DIR="$PROBES" \
  ORCHARD_SOURCE_DEV_TESTING=1 \
  ORCHARD_SOURCE_DEV_TEST_INSTALLATION_UUID=invalid \
  ORCHARD_SOURCE_DEV_TEST_OPERATION_UUID="$OPERATION_UUID" \
  "$REPO_ROOT/bin/orchard-source-installation" prepare
[[ ! -e "$FIXTURE/var/lib/orchard/install" ]] || fail "invalid UUID mutated installation state"

new_fixture
mkdir -p "$FIXTURE/var/lib/postgresql/16/orchard"
printf '16\n' > "$FIXTURE/var/lib/postgresql/16/orchard/PG_VERSION"
expect_failure 'a PostgreSQL cluster or socket already claims the profile' run_installation prepare

new_fixture
mkdir -p "$FIXTURE/sys/fs/cgroup/orchard.slice"
expect_failure 'an Orchard cgroup already claims the profile' run_installation prepare

new_fixture
mkdir -p "$FIXTURE/etc/systemd/system"
printf 'foreign\n' > "$FIXTURE/etc/systemd/system/orchard-controller.service"
expect_failure 'supervisor unit orchard-controller.service has foreign or ambiguous content' run_installation prepare

new_fixture
mkdir -p "$FIXTURE/etc/systemd/system/orchard-controller.service.d"
printf '[Service]\nExecStart=\nExecStart=/bin/true\n' > "$FIXTURE/etc/systemd/system/orchard-controller.service.d/override.conf"
expect_failure 'foreign Orchard supervisor drop-in blocks preparation' run_installation prepare

new_fixture
mkdir -p "$FIXTURE/etc/systemd/system"
printf '[Unit]\nDescription=foreign\n' > "$FIXTURE/etc/systemd/system/orchard-foreign.service"
expect_failure 'unexpected Orchard supervisor unit blocks preparation' run_installation prepare

new_fixture
mkdir -p "$FIXTURE/etc/systemd/system"
ln -s "$TMP_ROOT/outside-dropin" "$FIXTURE/etc/systemd/system/orchard-controller.service.d"
expect_failure 'foreign Orchard supervisor drop-in blocks preparation' run_installation prepare

new_fixture
mkdir -p "$FIXTURE/etc/systemd/system/multi-user.target.wants"
ln -s ../orchard-controller.service "$FIXTURE/etc/systemd/system/multi-user.target.wants/orchard-controller.service"
expect_failure 'an Orchard supervisor unit is enabled' run_installation prepare

new_fixture
mkdir -p "$FIXTURE/var/lib/orchard/install"
chmod 0755 "$FIXTURE/var/lib/orchard"
chmod 0700 "$FIXTURE/var/lib/orchard/install"
touch "$FIXTURE/var/lib/orchard/install/lifecycle.lock"
flock "$FIXTURE/var/lib/orchard/install/lifecycle.lock" sleep 30 &
LOCK_PID=$!
sleep 0.1
lock_digest=$(sha256sum "$FIXTURE/var/lib/orchard/install/lifecycle.lock")
expect_failure 'lifecycle lock is already held' run_installation prepare
expect_failure 'lifecycle lock is already held' run_installation classify
[[ "$(sha256sum "$FIXTURE/var/lib/orchard/install/lifecycle.lock")" == "$lock_digest" ]] || fail "held lock refusal modified the lock"
[[ ! -e "$FIXTURE/var/lib/orchard/install/receipts" ]] || fail "held lock refusal created receipts"
kill "$LOCK_PID"
wait "$LOCK_PID" >/dev/null 2>&1 || true
LOCK_PID=""

new_fixture
mkdir -p "$FIXTURE/var/lib/orchard/install"
chmod 0755 "$FIXTURE/var/lib/orchard"
chmod 0700 "$FIXTURE/var/lib/orchard/install"
outside_lock="$TMP_ROOT/outside-lock"
ln -s "$outside_lock" "$FIXTURE/var/lib/orchard/install/lifecycle.lock"
expect_failure 'refusing symlink path component' run_installation prepare
[[ ! -e "$outside_lock" ]] || fail "dangling lock symlink created an external target"

new_fixture
outside="$TMP_ROOT/outside"
mkdir -p "$outside"
mkdir -p "$FIXTURE/var/lib"
ln -s "$outside" "$FIXTURE/var/lib/orchard"
expect_failure 'refusing symlink path component' run_installation prepare
[[ -z "$(find "$outside" -mindepth 1 -print -quit)" ]] || fail "symlink refusal mutated the external target"

new_fixture
if ORCHARD_SOURCE_DEV_TEST_STOP_AFTER=roots_prepared run_installation prepare >/dev/null 2>&1; then
  fail "injected interruption succeeded"
else
  status=$?
  [[ "$status" == 99 ]] || fail "injected interruption returned $status, expected 99"
fi
if run_installation classify > "$FIXTURE/classification" 2>/dev/null; then
  fail "nonterminal receipt classified terminal"
else
  [[ $? == 75 ]] || fail "nonterminal receipt did not return recoverable status"
fi
grep -Fx resume_required "$FIXTURE/classification" >/dev/null || fail "nonterminal receipt was not classified resumable"
run_installation prepare >/dev/null
jq -e '.phase == "source_prepared" and .generation == 4' "$FIXTURE/var/lib/orchard/install/receipts/prepare.json" >/dev/null ||
  fail "interrupted exact prepare did not resume monotonically"

uuid=$(jq -r '.installation_uuid' "$FIXTURE/var/lib/orchard/install/manifest.json")
printf 'cgroup\t%s\t/sys/fs/cgroup/orchard.slice\n' "$uuid" > "$PROBES/stale.tsv"
if run_installation classify > "$FIXTURE/stale-classification" 2>/dev/null; then
  fail "exact stale state classified terminal"
else
  [[ $? == 75 ]] || fail "exact stale state did not return recovery status"
fi
grep -Fx recovery_required "$FIXTURE/stale-classification" >/dev/null || fail "exact stale state was not classified for recovery"
expect_failure 'exact stale state requires a separately authorized recovery operation' run_installation prepare
printf 'cgroup\t33333333-3333-4333-8333-333333333333\t/sys/fs/cgroup/orchard.slice\n' > "$PROBES/stale.tsv"
expect_failure 'stale state has foreign or ambiguous ownership' run_installation classify

new_fixture
mkdir -p "$FIXTURE/var/lib/orchard/controller"
printf 'foreign identity\n' > "$FIXTURE/var/lib/orchard/controller/identity"
expect_failure 'unclaimed retained role state blocks preparation' run_installation prepare
[[ ! -e "$FIXTURE/var/lib/orchard/install" ]] || fail "retained role state conflict mutated installation state"

new_fixture
run_installation prepare >/dev/null
manifest="$FIXTURE/var/lib/orchard/install/manifest.json"
temporary="$manifest.new"
jq '.installation_uuid = "33333333-3333-4333-8333-333333333333"' "$manifest" > "$temporary"
mv "$temporary" "$manifest"
expect_failure 'manifest and receipt installation UUIDs disagree' run_installation classify

new_fixture
run_installation prepare >/dev/null
manifest="$FIXTURE/var/lib/orchard/install/manifest.json"
ln "$manifest" "$FIXTURE/manifest-hardlink"
expect_failure 'refusing unsafe regular file' run_installation classify

new_fixture
run_installation prepare >/dev/null
receipt="$FIXTURE/var/lib/orchard/install/receipts/prepare.json"
temporary="$receipt.new"
jq '.operation = "upgrade"' "$receipt" > "$temporary"
mv "$temporary" "$receipt"
expect_failure 'existing prepare receipt has conflicting or invalid inputs' run_installation classify

new_fixture
run_installation prepare >/dev/null
receipt="$FIXTURE/var/lib/orchard/install/receipts/prepare.json"
temporary="$receipt.new"
jq '.phase = "unknown_phase"' "$receipt" > "$temporary"
mv "$temporary" "$receipt"
expect_failure 'existing prepare receipt has conflicting or invalid inputs' run_installation classify

new_fixture
run_installation prepare >/dev/null
receipt="$FIXTURE/var/lib/orchard/install/receipts/prepare.json"
temporary="$receipt.new"
jq '.generation = 1.5' "$receipt" > "$temporary"
mv "$temporary" "$receipt"
expect_failure 'existing prepare receipt has conflicting or invalid inputs' run_installation classify

new_fixture
run_installation prepare >/dev/null
receipt="$FIXTURE/var/lib/orchard/install/receipts/prepare.json"
temporary="$receipt.new"
jq '.generation = 9223372036854775807' "$receipt" > "$temporary"
mv "$temporary" "$receipt"
expect_failure 'existing prepare receipt has conflicting or invalid inputs' run_installation classify

new_fixture
run_installation prepare >/dev/null
receipt="$FIXTURE/var/lib/orchard/install/receipts/prepare.json"
temporary="$receipt.new"
jq '.phase = "units_prepared"' "$receipt" > "$temporary"
mv "$temporary" "$receipt"
expect_failure 'existing prepare receipt has conflicting or invalid inputs' run_installation classify

new_fixture
expect_failure 'cannot enumerate source-development supervisor units' env \
  ORCHARD_SOURCE_DEV_ROOT="$FIXTURE" \
  ORCHARD_SOURCE_DEV_SOURCE="$SOURCE" \
  ORCHARD_SOURCE_DEV_PROBE_DIR="$PROBES" \
  ORCHARD_SOURCE_DEV_TESTING=1 \
  ORCHARD_SOURCE_DEV_TEST_FAIL_UNIT_ENUMERATION=1 \
  "$REPO_ROOT/bin/orchard-source-installation" prepare
[[ ! -e "$FIXTURE/var/lib/orchard/install" ]] || fail "failed unit observation mutated installation state"

new_fixture
run_installation prepare >/dev/null
uuid=$(jq -r '.installation_uuid' "$FIXTURE/var/lib/orchard/install/manifest.json")
mkdir -p "$FIXTURE/proc/4242"
printf 'process\t%s\t4242\n' "$uuid" > "$PROBES/stale.tsv"
expect_failure 'stale process evidence still has a live or ambiguous owner' run_installation classify
rm -rf "$FIXTURE/proc/4242"
if run_installation classify > "$FIXTURE/process-stale-classification" 2>/dev/null; then
  fail "absent exact stale process classified terminal"
else
  [[ $? == 75 ]] || fail "absent exact stale process did not return recovery status"
fi
grep -Fx recovery_required "$FIXTURE/process-stale-classification" >/dev/null ||
  fail "absent exact stale process was not classified for recovery"

new_fixture
run_installation prepare >/dev/null
manifest="$FIXTURE/var/lib/orchard/install/manifest.json"
temporary="$manifest.new"
jq '.dependency_locks[0].sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$manifest" > "$temporary"
mv "$temporary" "$manifest"
expect_failure 'prepared manifest verification failed' run_installation classify

new_fixture
run_installation prepare >/dev/null
manifest="$FIXTURE/var/lib/orchard/install/manifest.json"
temporary="$manifest.new"
jq '.source.repository = "https://example.invalid/foreign.git"' "$manifest" > "$temporary"
mv "$temporary" "$manifest"
expect_failure 'prepared manifest verification failed' run_installation classify

new_fixture
run_installation prepare >/dev/null
chmod 0666 "$FIXTURE/var/lib/orchard/install/manifest.json"
expect_failure 'writable mode' run_installation classify

for failure_point in receipt_write receipt_fsync receipt_rename receipt_directory_fsync; do
  new_fixture
  expect_failure "injected I/O failure at $failure_point" env \
    ORCHARD_SOURCE_DEV_ROOT="$FIXTURE" \
    ORCHARD_SOURCE_DEV_SOURCE="$SOURCE" \
    ORCHARD_SOURCE_DEV_PROBE_DIR="$PROBES" \
    ORCHARD_SOURCE_DEV_TESTING=1 \
    ORCHARD_SOURCE_DEV_TEST_INSTALLATION_UUID="$INSTALLATION_UUID" \
    ORCHARD_SOURCE_DEV_TEST_OPERATION_UUID="$OPERATION_UUID" \
    ORCHARD_SOURCE_DEV_TEST_FAIL_IO="$failure_point" \
    "$REPO_ROOT/bin/orchard-source-installation" prepare
  [[ ! -e "$FIXTURE/var/lib/orchard/controller" ]] || fail "$failure_point mutated role state without durable intent"
done

for failure_point in manifest_write manifest_fsync manifest_rename manifest_directory_fsync; do
  new_fixture
  expect_failure "injected I/O failure at $failure_point" env \
    ORCHARD_SOURCE_DEV_ROOT="$FIXTURE" \
    ORCHARD_SOURCE_DEV_SOURCE="$SOURCE" \
    ORCHARD_SOURCE_DEV_PROBE_DIR="$PROBES" \
    ORCHARD_SOURCE_DEV_TESTING=1 \
    ORCHARD_SOURCE_DEV_TEST_INSTALLATION_UUID="$INSTALLATION_UUID" \
    ORCHARD_SOURCE_DEV_TEST_OPERATION_UUID="$OPERATION_UUID" \
    ORCHARD_SOURCE_DEV_TEST_FAIL_IO="$failure_point" \
    "$REPO_ROOT/bin/orchard-source-installation" prepare
  jq -e '.phase == "units_prepared" and .generation == 3' \
    "$FIXTURE/var/lib/orchard/install/receipts/prepare.json" >/dev/null ||
    fail "$failure_point published terminal success without a durable manifest"
done

new_fixture
run_installation prepare >/dev/null
printf '# drift\n' >> "$SOURCE/mise.toml"
expect_failure 'canonical source checkout is dirty' run_installation classify

if "$REPO_ROOT/bin/source-dev-role-guard" controller > "$TMP_ROOT/guard.out" 2>&1; then
  fail "role guard authorized Controller startup"
else
  [[ $? == 78 ]] || fail "role guard returned the wrong refusal status"
fi
grep -F 'role preflight must run as root' "$TMP_ROOT/guard.out" >/dev/null ||
  fail "role guard lacks stable privilege refusal"

printf 'test-source-dev-installation: PASS\n'
