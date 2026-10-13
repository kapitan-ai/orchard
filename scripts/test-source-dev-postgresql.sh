#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-source-postgresql-test.XXXXXX")"
INSTALLATION_UUID=11111111-1111-4111-8111-111111111111
CASE_NUMBER=0
OPERATION_NUMBER=100
FENCE_NUMBER=500
LOCK_PID=""
AUTHORITY_DIGEST=$(printf 'controller\tcontroller-1\tauthority-root-1\toperational\ncredential\tnode-1\t7\tcurrent\npeer_grant\tnode-1\t9\tactive\n' | sha256sum | cut -d ' ' -f1)

cleanup() {
  if [[ -n "$LOCK_PID" ]]; then
    kill "$LOCK_PID" >/dev/null 2>&1 || true
    wait "$LOCK_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'test-source-dev-postgresql: %s\n' "$1" >&2
  exit 1
}

new_fixture() {
  CASE_NUMBER=$((CASE_NUMBER + 1))
  FIXTURE="$TMP_ROOT/case-$CASE_NUMBER"
  SOURCE="$FIXTURE/opt/orchard/source"
  PROBES="$FIXTURE/probes"
  mkdir -p "$SOURCE" "$PROBES/bin" "$FIXTURE/etc"
  cat > "$FIXTURE/etc/os-release" <<'EOF'
ID=ubuntu
VERSION_ID="24.04"
EOF
  mkdir -p \
    "$SOURCE/bin" "$SOURCE/native/orchard_tokenizer" \
    "$SOURCE/native/orchard_worker_mlx/src/orchard_worker_mlx/generated" \
    "$SOURCE/proto/orchard/worker/tooling" "$SOURCE/proto/orchard/worker/v1" \
    "$SOURCE/openspec/specs/runtime-endpoints" \
    "$SOURCE/apps/orchard_shared/lib/cluster/v1" "$SOURCE/rel/linux/source-dev"
  mkdir -p "$SOURCE/packaging/linux/appliance"
  cp -R "$REPO_ROOT/rel/linux/source-dev/systemd" "$SOURCE/rel/linux/source-dev/systemd"
  cp -R "$REPO_ROOT/rel/linux/source-dev/postgresql" "$SOURCE/rel/linux/source-dev/postgresql"
  cp "$REPO_ROOT/rel/linux/source-dev/worker-custody.json" "$SOURCE/rel/linux/source-dev/worker-custody.json"
  cp "$REPO_ROOT/packaging/linux/appliance/postgresql-16-closure.json" "$SOURCE/packaging/linux/appliance/postgresql-16-closure.json"
  cp "$REPO_ROOT/bin/source-dev-role-guard" "$SOURCE/bin/source-dev-role-guard"
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
  chmod 0755 "$SOURCE/bin/source-dev-role-guard"
  git -C "$SOURCE" init -q
  git -C "$SOURCE" config user.name 'Orchard Test'
  git -C "$SOURCE" config user.email 'orchard-test@example.invalid'
  git -C "$SOURCE" remote add origin https://github.com/kapitan-ai/orchard.git
  git -C "$SOURCE" add .
  git -C "$SOURCE" commit -qm fixture

  "$REPO_ROOT/scripts/test-source-dev-postgresql-fixture-tools.sh" "$PROBES/bin"
  jq -r '.packages[] | [.name,.version] | @tsv' \
    "$SOURCE/packaging/linux/appliance/postgresql-16-closure.json" > "$PROBES/packages.tsv"
  run_installation prepare >/dev/null
}

next_operation_uuid() {
  OPERATION_NUMBER=$((OPERATION_NUMBER + 1))
  printf -v OPERATION_UUID '00000000-0000-4000-8000-%012d' "$OPERATION_NUMBER"
}

base_env() {
  env \
    ORCHARD_SOURCE_DEV_ROOT="$FIXTURE" \
    ORCHARD_SOURCE_DEV_SOURCE="$SOURCE" \
    ORCHARD_SOURCE_DEV_PG_PROBE_DIR="$PROBES" \
    ORCHARD_SOURCE_DEV_PG_BIN="$PROBES/bin" \
    ORCHARD_SOURCE_DEV_TESTING=1 \
    ORCHARD_SOURCE_DEV_PG_MIN_FREE_KB=1 \
    "$@"
}

run_installation() {
  env \
    ORCHARD_SOURCE_DEV_ROOT="$FIXTURE" \
    ORCHARD_SOURCE_DEV_SOURCE="$SOURCE" \
    ORCHARD_SOURCE_DEV_PROBE_DIR="$PROBES" \
    ORCHARD_SOURCE_DEV_TESTING=1 \
    ORCHARD_SOURCE_DEV_TEST_ARCH=x86_64 \
    ORCHARD_SOURCE_DEV_TEST_INSTALLATION_UUID="$INSTALLATION_UUID" \
    ORCHARD_SOURCE_DEV_TEST_OPERATION_UUID=22222222-2222-4222-8222-222222222222 \
    "$REPO_ROOT/bin/orchard-source-installation" "$@"
}

run_pg() {
  next_operation_uuid
  base_env ORCHARD_SOURCE_DEV_DATABASE_MUTATION_AUTHORIZED="$INSTALLATION_UUID" \
    ORCHARD_SOURCE_DEV_TEST_OPERATION_UUID="$OPERATION_UUID" "$REPO_ROOT/bin/orchard-source-postgresql" "$@"
}

read_pg() {
  base_env "$REPO_ROOT/bin/orchard-source-postgresql" "$@"
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

initialize_fixture() {
  run_pg initialize
  [[ "$(<"$FIXTURE/var/lib/postgresql/16/orchard/PG_VERSION")" == 16 ]] || fail "cluster major was not initialized"
  jq -e --arg uuid "$INSTALLATION_UUID" '.installation_uuid == $uuid and .postgresql_major == 16' \
    "$FIXTURE/var/lib/postgresql/16/orchard/orchard-installation.json" >/dev/null || fail "cluster identity is missing"
  [[ ! -f "$PROBES/running" ]] || fail "initialization left PostgreSQL running"
}

write_writer_fence() {
  local operation=$1
  local fence_uuid
  FENCE_NUMBER=$((FENCE_NUMBER + 1))
  printf -v fence_uuid '33333333-3333-4333-8333-%012d' "$FENCE_NUMBER"
  mkdir -p "$FIXTURE/var/lib/orchard/install/fences"
  jq -n --arg uuid "$INSTALLATION_UUID" --arg operation "$operation" --arg fence_uuid "$fence_uuid" \
    --arg commit "$(git -C "$SOURCE" rev-parse HEAD)" --arg tree "$(git -C "$SOURCE" rev-parse HEAD^{tree})" \
    '{schema_version:1,installation_uuid:$uuid,operation:$operation,
    fence_uuid:$fence_uuid,source:{commit:$commit,tree:$tree},ingress_closed:true,
    controller_stopped:true,node_cordoned:true,node_drained:true,node_stopped:true,workers_stopped:true,
    credential_writers_stopped:true,governance_writers_stopped:true,direct_database_writers_stopped:true}' \
    > "$FIXTURE/var/lib/orchard/install/fences/database-writers.json"
  chmod 600 "$FIXTURE/var/lib/orchard/install/fences/database-writers.json"
}

write_restore_fence() {
  local backup=$1
  local fence_uuid
  FENCE_NUMBER=$((FENCE_NUMBER + 1))
  printf -v fence_uuid '44444444-4444-4444-8444-%012d' "$FENCE_NUMBER"
  mkdir -p "$FIXTURE/var/lib/orchard/install/fences"
  jq -n --arg uuid "$INSTALLATION_UUID" --arg backup "$backup" --arg fence_uuid "$fence_uuid" \
    --arg commit "$(git -C "$SOURCE" rev-parse HEAD)" --arg tree "$(git -C "$SOURCE" rev-parse HEAD^{tree})" \
    '{schema_version:1,installation_uuid:$uuid,operation:"restore",backup_id:$backup,
    fence_uuid:$fence_uuid,source:{commit:$commit,tree:$tree},
    source_fenced:true,revocation_or_recovery_authority_recorded:true}' \
    > "$FIXTURE/var/lib/orchard/install/fences/restore-source.json"
  chmod 600 "$FIXTURE/var/lib/orchard/install/fences/restore-source.json"
}

new_fixture
read_pg classify | grep -Fx source_prepared >/dev/null || fail "prepared source was misclassified"
expect_failure 'exact installation UUID authorization' read_pg initialize
initialize_fixture
read_pg classify | grep -Fx initialized_stopped >/dev/null || fail "initialized cluster was misclassified"
grep -Fx "listen_addresses = ''" "$FIXTURE/etc/orchard/postgresql/postgresql.conf" >/dev/null || fail "TCP was not disabled"
grep -F 'all                  reject' "$FIXTURE/etc/orchard/postgresql/pg_hba.conf" >/dev/null || fail "HBA lacks fail-closed fallback"
run_pg start
read_pg readiness
run_pg restart
read_pg readiness
run_pg migrate
jq -e '.operation == "migrate" and .phase == "schema_current" and .terminal == true and .details.schema_identity == "20260919020000"' \
  "$(find "$FIXTURE/var/lib/orchard/install/receipts/postgresql" -type f -print | LC_ALL=C sort | tail -n 1)" >/dev/null ||
  fail "migration receipt lacks schema identity"
run_pg stop
read_pg classify | grep -Fx initialized_stopped >/dev/null || fail "stop did not preserve initialized state"

new_fixture
initialize_fixture
printf 'foreign-installation\n' > "$PROBES/running"
touch "$FIXTURE/run/postgresql/.s.PGSQL.5432"
expect_failure 'foreign or ambiguous PostgreSQL socket owner' run_pg start

new_fixture
initialize_fixture
printf '15\n' > "$FIXTURE/var/lib/postgresql/16/orchard/PG_VERSION"
expect_failure 'foreign PostgreSQL major version' run_pg start

new_fixture
initialize_fixture
jq '.installation_uuid = "99999999-9999-4999-8999-999999999999"' \
  "$FIXTURE/var/lib/postgresql/16/orchard/orchard-installation.json" > "$FIXTURE/cluster.tmp"
mv "$FIXTURE/cluster.tmp" "$FIXTURE/var/lib/postgresql/16/orchard/orchard-installation.json"
chmod 600 "$FIXTURE/var/lib/postgresql/16/orchard/orchard-installation.json"
expect_failure 'cluster identity is foreign or ambiguous' run_pg start

for storage_state in full corrupt; do
  new_fixture
  printf '%s\n' "$storage_state" > "$PROBES/storage-state"
  expect_failure "PostgreSQL storage is $storage_state" run_pg initialize
  [[ ! -e "$FIXTURE/var/lib/postgresql/16/orchard/PG_VERSION" ]] || fail "$storage_state initialized replacement data"
done

for readiness_state in unavailable recovery; do
  new_fixture
  initialize_fixture
  run_pg start
  touch "$PROBES/$readiness_state"
  expect_failure "$(if [[ "$readiness_state" == unavailable ]]; then printf 'PostgreSQL is unavailable'; else printf 'PostgreSQL is in recovery'; fi)" \
    read_pg readiness
done

new_fixture
initialize_fixture
run_pg start
touch "$PROBES/read-write-fail"
expect_failure 'bounded read/write readiness probe failed' read_pg readiness

for migration_state in migration-fail migration-conflict; do
  new_fixture
  initialize_fixture
  run_pg start
  touch "$PROBES/$migration_state"
  expect_failure 'exclusive migration failed or conflicted' run_pg migrate
  if read_pg classify > "$FIXTURE/classification" 2>/dev/null; then
    fail "$migration_state classified terminal"
  else
    [[ $? == 75 ]] || fail "$migration_state returned the wrong classification status"
  fi
  grep -Fx recovery_required "$FIXTURE/classification" >/dev/null || fail "$migration_state did not require recovery"
done

new_fixture
next_operation_uuid
interrupted_operation=$OPERATION_UUID
expect_failure 'injected interruption at after_roots_prepared' base_env \
  ORCHARD_SOURCE_DEV_DATABASE_MUTATION_AUTHORIZED="$INSTALLATION_UUID" \
  ORCHARD_SOURCE_DEV_TEST_OPERATION_UUID="$OPERATION_UUID" \
  ORCHARD_SOURCE_DEV_PG_TEST_STOP=after_roots_prepared \
  "$REPO_ROOT/bin/orchard-source-postgresql" initialize
if read_pg classify > "$FIXTURE/classification" 2>/dev/null; then
  fail "interrupted initialization classified terminal"
else
  [[ $? == 75 ]] || fail "interrupted initialization returned the wrong status"
fi
grep -Fx recovery_required "$FIXTURE/classification" >/dev/null || fail "interruption did not require recovery"
run_pg recover "$interrupted_operation"
read_pg classify | grep -Fx source_prepared >/dev/null || fail "exact recovery did not clear interrupted preparation"

new_fixture
initialize_fixture
next_operation_uuid
interrupted_operation=$OPERATION_UUID
expect_failure 'injected interruption at after_intent_recorded' base_env \
  ORCHARD_SOURCE_DEV_DATABASE_MUTATION_AUTHORIZED="$INSTALLATION_UUID" \
  ORCHARD_SOURCE_DEV_TEST_OPERATION_UUID="$OPERATION_UUID" \
  ORCHARD_SOURCE_DEV_PG_TEST_STOP=after_intent_recorded \
  "$REPO_ROOT/bin/orchard-source-postgresql" start
run_pg recover "$interrupted_operation"
read_pg classify | grep -Fx database_ready >/dev/null || fail "start recovery did not establish readiness"
next_operation_uuid
interrupted_operation=$OPERATION_UUID
expect_failure 'injected interruption at after_intent_recorded' base_env \
  ORCHARD_SOURCE_DEV_DATABASE_MUTATION_AUTHORIZED="$INSTALLATION_UUID" \
  ORCHARD_SOURCE_DEV_TEST_OPERATION_UUID="$OPERATION_UUID" \
  ORCHARD_SOURCE_DEV_PG_TEST_STOP=after_intent_recorded \
  "$REPO_ROOT/bin/orchard-source-postgresql" migrate
run_pg recover "$interrupted_operation"
jq -e '.phase == "schema_current" and .details.migration.schema_identity == "20260919020000"' \
  "$FIXTURE/var/lib/orchard/install/receipts/postgresql/$interrupted_operation.json" >/dev/null ||
  fail "migration recovery did not establish schema identity"
run_pg stop

new_fixture
initialize_fixture
run_pg start
expect_failure 'complete database writer fence is absent' run_pg backup
write_writer_fence backup
cat > "$FIXTURE/var/lib/orchard/install/public-generation.json" <<EOF
{"schema_version":1,"installation_uuid":"$INSTALLATION_UUID","private_keys":["forbidden"]}
EOF
chmod 600 "$FIXTURE/var/lib/orchard/install/public-generation.json"
expect_failure 'contains forbidden custody' run_pg backup
cat > "$FIXTURE/var/lib/orchard/install/public-generation.json" <<EOF
{"schema_version":1,"installation_uuid":"$INSTALLATION_UUID","controller_public_generation":3,"node_public_generation":7,"database_authority_sha256":"$AUTHORITY_DIGEST"}
EOF
chmod 600 "$FIXTURE/var/lib/orchard/install/public-generation.json"
next_operation_uuid
interrupted_operation=$OPERATION_UUID
expect_failure 'injected interruption at after_snapshot_created' base_env \
  ORCHARD_SOURCE_DEV_DATABASE_MUTATION_AUTHORIZED="$INSTALLATION_UUID" \
  ORCHARD_SOURCE_DEV_TEST_OPERATION_UUID="$OPERATION_UUID" \
  ORCHARD_SOURCE_DEV_PG_TEST_STOP=after_snapshot_created \
  "$REPO_ROOT/bin/orchard-source-postgresql" backup
run_pg recover "$interrupted_operation"
[[ ! -e "$FIXTURE/var/backups/orchard/.staging-$interrupted_operation" ]] || fail "backup recovery retained staging output"
write_writer_fence backup
run_pg backup
backup=$(find "$FIXTURE/var/backups/orchard" -mindepth 1 -maxdepth 1 -type d ! -name '.staging-*' -printf '%f\n')
jq -e '.validation.state == "complete" and .private_material_included == false and .reusable_database_credentials_included == false' \
  "$FIXTURE/var/backups/orchard/$backup/manifest.json" >/dev/null || fail "backup was not validated or excluded private custody"
grep -F 'PASSWORD' "$FIXTURE/var/backups/orchard/$backup/roles.sql" >/dev/null && fail "backup retained a role password"
expect_failure 'complete database writer fence is absent' run_pg backup
mkdir -p "$FIXTURE/var/lib/orchard/install/fences"
cp "$(find "$FIXTURE/var/lib/orchard/install/receipts/postgresql/fences" -type f -name '*-database-writers-*.json' | head -n 1)" \
  "$FIXTURE/var/lib/orchard/install/fences/database-writers.json"
expect_failure 'lifecycle fence was already consumed' run_pg backup
rm "$FIXTURE/var/lib/orchard/install/fences/database-writers.json"
run_pg stop
write_writer_fence upgrade
run_pg upgrade-prepare "$backup"
rm -rf "$FIXTURE/var/lib/postgresql/16/orchard"
printf '%s\n' '{"schema_version":1,"installation_uuid":"11111111-1111-4111-8111-111111111111","controller_public_generation":99,"database_authority_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' \
  > "$FIXTURE/var/lib/orchard/install/public-generation.json"
expect_failure 'restore source fencing is absent' run_pg restore "$backup"
write_restore_fence "$backup"
next_operation_uuid
interrupted_operation=$OPERATION_UUID
expect_failure 'injected interruption at after_intent_recorded' base_env \
  ORCHARD_SOURCE_DEV_DATABASE_MUTATION_AUTHORIZED="$INSTALLATION_UUID" \
  ORCHARD_SOURCE_DEV_TEST_OPERATION_UUID="$OPERATION_UUID" \
  ORCHARD_SOURCE_DEV_PG_TEST_STOP=after_intent_recorded \
  "$REPO_ROOT/bin/orchard-source-postgresql" restore "$backup"
run_pg recover "$interrupted_operation"
jq -e '.state == "interrupted_restore_requires_fenced_retry" and .serving == false' \
  "$FIXTURE/var/lib/orchard/install/restore-recovery.json" >/dev/null || fail "restore recovery did not remain fenced"
write_restore_fence "$backup"
cp "$FIXTURE/var/backups/orchard/$backup/orchard.dump" "$FIXTURE/dump.safe"
printf 'tamper\n' >> "$FIXTURE/var/backups/orchard/$backup/orchard.dump"
expect_failure 'backup checksum mismatch' run_pg restore "$backup"
mv "$FIXTURE/dump.safe" "$FIXTURE/var/backups/orchard/$backup/orchard.dump"
run_pg restore "$backup"
jq -e '.controller_public_generation == 3' "$FIXTURE/var/lib/orchard/install/public-generation.json" >/dev/null ||
  fail "restore did not republish the coherent public-generation checkpoint"
jq -e '.state == "new_key_recovery_required" and .serving == false and .schedulable == false' \
  "$FIXTURE/var/lib/orchard/install/restore-recovery.json" >/dev/null || fail "restore did not require new local keys"
[[ ! -f "$PROBES/running" ]] || fail "restore target became serving"
expect_failure 'restored authority remains non-serving' run_pg start

new_fixture
initialize_fixture
run_pg start
write_writer_fence backup
cat > "$FIXTURE/var/lib/orchard/install/public-generation.json" <<EOF
{"schema_version":1,"installation_uuid":"$INSTALLATION_UUID","database_authority_sha256":"$AUTHORITY_DIGEST"}
EOF
chmod 600 "$FIXTURE/var/lib/orchard/install/public-generation.json"
touch "$PROBES/validation-fail"
expect_failure 'isolated backup validation failed' run_pg backup
if find "$FIXTURE/var/lib/postgresql/16" -path '*.validation-*/running' -print -quit | grep -q .; then
  fail "failed isolated validation left PostgreSQL running"
fi

new_fixture
initialize_fixture
run_pg start
run_pg stop
run_pg retire
[[ -f "$FIXTURE/var/lib/postgresql/16/orchard/PG_VERSION" ]] || fail "retirement removed database data"
[[ -d "$FIXTURE/var/backups/orchard" ]] || fail "retirement removed backups"

new_fixture
cat > "$FIXTURE/compatibility.json" <<'EOF'
{"schema":false,"retained_state":true,"authorization_contract":true,"credential_and_governance_writers":true,"audit_semantics":true,"ingress_fence":true,"durable_cutovers":true}
EOF
chmod 600 "$FIXTURE/compatibility.json"
expect_failure 'binary rollback is prohibited' read_pg rollback-check "$FIXTURE/compatibility.json"
jq '.schema = true' "$FIXTURE/compatibility.json" > "$FIXTURE/compatibility.tmp"
mv "$FIXTURE/compatibility.tmp" "$FIXTURE/compatibility.json"
chmod 600 "$FIXTURE/compatibility.json"
read_pg rollback-check "$FIXTURE/compatibility.json" | grep -Fx compatible_rollback >/dev/null || fail "compatible rollback was rejected"

new_fixture
mkdir -p "$FIXTURE/var/lib/postgresql/16"
ln -s "$FIXTURE/foreign" "$FIXTURE/var/lib/postgresql/16/orchard"
expect_failure 'refusing symlink path component' run_pg initialize

new_fixture
exec 8<>"$FIXTURE/var/lib/orchard/install/lifecycle.lock"
flock 8
expect_failure 'lifecycle lock is already held' run_pg initialize
flock -u 8

new_fixture
read_pg diagnose > "$FIXTURE/diagnostics.json"
jq -e '.database.classification == "source_prepared" and .database.ready == false and (.redaction | contains("no credentials"))' \
  "$FIXTURE/diagnostics.json" >/dev/null || fail "diagnostics are incomplete or unredacted"

printf 'test-source-dev-postgresql: PASS\n'
