#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMAND="$REPO_ROOT/bin/orchard-source-lifecycle"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-source-lifecycle-test.XXXXXX")"
FIXTURE="$TMP_ROOT/root"
SOURCE="$FIXTURE/opt/orchard/source"
INSTALLATION_UUID=11111111-1111-4111-8111-111111111111
CONTROLLER_UUID=22222222-2222-4222-8222-222222222222
NODE_UUID=33333333-3333-4333-8333-333333333333

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'test-source-dev-lifecycle: %s\n' "$1" >&2
  exit 1
}

expect_failure() {
  local expected=$1
  shift
  if "$@" >"$TMP_ROOT/failure.out" 2>&1; then
    fail "command unexpectedly succeeded; expected $expected"
  fi
  grep -F "$expected" "$TMP_ROOT/failure.out" >/dev/null || {
    cat "$TMP_ROOT/failure.out" >&2
    fail "failure did not contain: $expected"
  }
}

base_env() {
  env ORCHARD_SOURCE_DEV_ROOT="$FIXTURE" ORCHARD_SOURCE_DEV_SOURCE="$SOURCE" \
    ORCHARD_SOURCE_DEV_TESTING=1 "$@"
}

next_operation() {
  local number
  number=$(<"$TMP_ROOT/operation-number")
  number=$((number + 1))
  printf '%s\n' "$number" > "$TMP_ROOT/operation-number"
  printf -v OPERATION_UUID '00000000-0000-4000-8000-%012d' "$number"
}

run_transition() {
  local operation=$1
  next_operation
  base_env ORCHARD_SOURCE_DEV_TEST_OPERATION_UUID="$OPERATION_UUID" "$COMMAND" transition "$operation" "$OBSERVATION"
}

write_observation() {
  local database=${1:-source_prepared} schema=${2:-null} controller=${3:-stopped} node=${4:-stopped}
  local admitted=${5:-false} authenticated=${6:-false} fresh=${7:-false} drained=${8:-false}
  local custody=${9:-stopped_empty}
  local controller_identity=absent controller_listener=absent node_identity=absent
  [[ "$controller" == ready ]] && controller_identity=exact && controller_listener=exact
  [[ "$node" == ready ]] && node_identity=exact
  jq -n --arg uuid "$INSTALLATION_UUID" --arg commit "$(git -C "$SOURCE" rev-parse HEAD)" \
    --arg tree "$(git -C "$SOURCE" rev-parse HEAD^{tree})" --arg database "$database" \
    --argjson schema "$schema" --arg controller "$controller" --arg node "$node" \
    --arg custody "$custody" \
    --arg controller_identity "$controller_identity" --arg controller_listener "$controller_listener" \
    --arg node_identity "$node_identity" --argjson admitted "$admitted" --argjson authenticated "$authenticated" \
    --argjson fresh "$fresh" --argjson drained "$drained" '
    {schema_version:1,installation_uuid:$uuid,source:{commit:$commit,tree:$tree},ambiguities:[],
      supervisor:{ownership:"exact"},database:{classification:$database,schema_identity:$schema},
      controller:{identity:$controller_identity,listener:$controller_listener,state:$controller},
      node:{identity:$node_identity,state:$node,admitted:$admitted,authenticated:$authenticated,
        observation_fresh:$fresh,drained:$drained,schedulable:false},
      worker:{classification:$custody,workers_active:false,capacity_published:false},
      reboot:{boot_id:"boot-a",intent_boot_id:null}}
  ' > "$OBSERVATION"
  chmod 600 "$OBSERVATION"
}

mkdir -p "$(dirname "$SOURCE")" "$FIXTURE/etc"
printf '100\n' > "$TMP_ROOT/operation-number"
git clone -q --shared "$REPO_ROOT" "$SOURCE"
git -C "$SOURCE" remote set-url origin https://github.com/kapitan-ai/orchard.git
git -C "$SOURCE" config core.filemode false
chmod -R go-w "$SOURCE"
rm "$SOURCE/.cursor/skills/verify-orchard/scripts/control-orchard"
git -C "$SOURCE" add -u
git -C "$SOURCE" -c user.name='Orchard Test' -c user.email='orchard-test@example.invalid' commit -qm fixture-custody
cat > "$FIXTURE/etc/os-release" <<'EOF'
ID=ubuntu
VERSION_ID="24.04"
EOF
mkdir -p "$FIXTURE/probes"
base_env ORCHARD_SOURCE_DEV_PROBE_DIR="$FIXTURE/probes" ORCHARD_SOURCE_DEV_TEST_ARCH=x86_64 \
  ORCHARD_SOURCE_DEV_TEST_INSTALLATION_UUID="$INSTALLATION_UUID" \
  ORCHARD_SOURCE_DEV_TEST_OPERATION_UUID=44444444-4444-4444-8444-444444444444 \
  "$REPO_ROOT/bin/orchard-source-installation" prepare >/dev/null
base_env ORCHARD_SOURCE_DEV_CONTROLLER_UUID="$CONTROLLER_UUID" ORCHARD_SOURCE_DEV_NODE_UUID="$NODE_UUID" \
  ORCHARD_SOURCE_DEV_PRIVATE_IPV4=10.0.0.10 "$REPO_ROOT/bin/orchard-source-composition" prepare >/dev/null

OBSERVATION="$TMP_ROOT/observation.json"
write_observation
[[ "$(base_env "$COMMAND" classify "$OBSERVATION")" == composition_prepared ]] || fail "initial phase was not classified"

write_observation initialized_stopped
[[ "$(run_transition initialize)" == initialized_stopped ]] || fail "initialize transition failed"
write_observation database_ready
[[ "$(run_transition start-database)" == database_ready ]] || fail "database transition failed"
write_observation database_ready '"20260921000000"'
[[ "$(run_transition migrate)" == schema_current ]] || fail "migration transition failed"
write_observation database_ready '"20260921000000"' ready
[[ "$(run_transition start-controller)" == controller_ready ]] || fail "Controller transition failed"
write_observation database_ready '"20260921000000"' ready ready true true true false running_owned
[[ "$(run_transition start-node)" == ready_composed ]] || fail "Node transition failed"

# Independent failure ordering cannot leave stale readiness or capacity.
write_observation database_ready '"20260921000000"' stopped stopped
[[ "$(run_transition restart-database)" == schema_current ]] || fail "database restart did not stop dependants"
write_observation database_ready '"20260921000000"' ready
run_transition start-controller >/dev/null
write_observation database_ready '"20260921000000"' ready ready true true true false running_owned
run_transition start-node >/dev/null
write_observation database_ready '"20260921000000"' ready stopped
[[ "$(run_transition restart-controller)" == controller_ready ]] || fail "Controller restart did not keep Node stopped"
write_observation database_ready '"20260921000000"' ready ready true true true false running_owned
run_transition start-node >/dev/null
write_observation database_ready '"20260921000000"' ready ready true true true true stopped_empty
[[ "$(run_transition drain)" == drained ]] || fail "drain transition failed"

write_observation initialized_stopped null stopped stopped false false false true
[[ "$(run_transition backup)" == backup_complete ]] || fail "backup transition failed"
[[ "$(run_transition stop)" == stopped ]] || fail "stop transition failed"

# Reboot intent must be reconciled only after the boot identity changes.
jq '.reboot.intent_boot_id = "boot-a"' "$OBSERVATION" > "$TMP_ROOT/reboot.json"
mv "$TMP_ROOT/reboot.json" "$OBSERVATION"; chmod 600 "$OBSERVATION"
[[ "$(run_transition reboot-intent)" == reboot_pending ]] || fail "reboot intent failed"
expect_failure 'reconcile-reboot observation does not prove' run_transition reconcile-reboot
jq '.reboot.boot_id = "boot-b"' "$OBSERVATION" > "$TMP_ROOT/reboot.json"
mv "$TMP_ROOT/reboot.json" "$OBSERVATION"; chmod 600 "$OBSERVATION"
[[ "$(run_transition reconcile-reboot)" == stopped ]] || fail "reboot reconciliation failed"

# Upgrade and rollback require all seven explicit compatibility dimensions.
write_observation initialized_stopped null stopped stopped false false false true
run_transition backup >/dev/null
run_transition upgrade-prepare >/dev/null
jq -n --arg uuid "$INSTALLATION_UUID" --arg version "$(<"$SOURCE/VERSION")" \
  --arg commit "$(git -C "$SOURCE" rev-parse HEAD)" --arg tree "$(git -C "$SOURCE" rev-parse HEAD^{tree})" \
  --arg target_commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --arg target_tree bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  --arg checkpoint cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc '
  {installation_uuid:$uuid,product_version:$version,observed_source:{commit:$commit,tree:$tree},
    rollback_source:{commit:$target_commit,tree:$target_tree},checkpoint_sha256:$checkpoint,schema_identity:"20260921000000",
    schema:true,retained_state:true,authorization_contract:true,credential_and_governance_writers:true,
    audit_semantics:true,ingress_fence:true,durable_cutovers:false}
' > "$TMP_ROOT/compatibility.json"
chmod 600 "$TMP_ROOT/compatibility.json"
rollback_env=(ORCHARD_SOURCE_DEV_COMPATIBILITY_MANIFEST="$TMP_ROOT/compatibility.json"
  ORCHARD_SOURCE_DEV_ROLLBACK_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  ORCHARD_SOURCE_DEV_ROLLBACK_TREE=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  ORCHARD_SOURCE_DEV_ROLLBACK_CHECKPOINT_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc)
expect_failure 'rollback compatibility is incomplete' base_env "${rollback_env[@]}" \
  ORCHARD_SOURCE_DEV_TEST_OPERATION_UUID=55555555-5555-4555-8555-555555555555 "$COMMAND" transition rollback "$OBSERVATION"
jq '.durable_cutovers = true' "$TMP_ROOT/compatibility.json" > "$TMP_ROOT/compatibility.new"
mv "$TMP_ROOT/compatibility.new" "$TMP_ROOT/compatibility.json"; chmod 600 "$TMP_ROOT/compatibility.json"
next_operation
base_env "${rollback_env[@]}" \
  ORCHARD_SOURCE_DEV_TEST_OPERATION_UUID="$OPERATION_UUID" "$COMMAND" transition rollback "$OBSERVATION" | grep -Fx stopped >/dev/null ||
  fail "compatible rollback failed"

# Restore remains non-serving behind PostgreSQL new-key recovery.
expect_failure 'restore requires an exact PostgreSQL new-key recovery gate' run_transition restore
jq -n --arg uuid "$INSTALLATION_UUID" '{schema_version:1,installation_uuid:$uuid,reference:"66666666-6666-4666-8666-666666666666",state:"new_key_recovery_required",serving:false,schedulable:false}' \
  > "$FIXTURE/var/lib/orchard/install/restore-recovery.json"
chmod 600 "$FIXTURE/var/lib/orchard/install/restore-recovery.json"
mkdir -p "$FIXTURE/var/lib/orchard/install/receipts/postgresql"
jq -n --arg uuid "$INSTALLATION_UUID" --arg version "$(<"$SOURCE/VERSION")" \
  --arg commit "$(git -C "$SOURCE" rev-parse HEAD)" --arg tree "$(git -C "$SOURCE" rev-parse HEAD^{tree})" '
  {schema_version:1,generation:2,operation:"restore",operation_uuid:"77777777-7777-4777-8777-777777777777",
    installation_uuid:$uuid,intended_product_version:$version,phase:"database_restored_non_serving",terminal:true,
    source:{commit:$commit,tree:$tree},details:{backup_id:"66666666-6666-4666-8666-666666666666",recovery:"new_key_recovery_required",serving:false}}
' > "$FIXTURE/var/lib/orchard/install/receipts/postgresql/77777777-7777-4777-8777-777777777777.json"
chmod 600 "$FIXTURE/var/lib/orchard/install/receipts/postgresql/77777777-7777-4777-8777-777777777777.json"
cp "$FIXTURE/var/lib/orchard/install/receipts/postgresql/77777777-7777-4777-8777-777777777777.json" "$TMP_ROOT/restore-receipt.json"
jq '.intended_product_version = "different-version"' "$TMP_ROOT/restore-receipt.json" \
  > "$FIXTURE/var/lib/orchard/install/receipts/postgresql/77777777-7777-4777-8777-777777777777.json"
chmod 600 "$FIXTURE/var/lib/orchard/install/receipts/postgresql/77777777-7777-4777-8777-777777777777.json"
expect_failure 'restore gate is not bound to one exact terminal PostgreSQL restore receipt' run_transition restore
mv "$TMP_ROOT/restore-receipt.json" "$FIXTURE/var/lib/orchard/install/receipts/postgresql/77777777-7777-4777-8777-777777777777.json"
chmod 600 "$FIXTURE/var/lib/orchard/install/receipts/postgresql/77777777-7777-4777-8777-777777777777.json"
[[ "$(run_transition restore)" == restored_non_serving ]] || fail "fenced restore transition failed"
[[ "$(run_transition retire)" == retired ]] || fail "retirement failed"
[[ "$(run_transition reprepare)" == stopped ]] || fail "re-preparation failed"

# A durable interrupted intent is exactly resumable only from identical evidence.
rm -rf "$FIXTURE/var/lib/orchard/install/receipts/lifecycle" "$FIXTURE/var/lib/orchard/install/lifecycle-state.json"
write_observation initialized_stopped
next_operation
expect_failure 'injected interruption' base_env ORCHARD_SOURCE_DEV_TEST_OPERATION_UUID="$OPERATION_UUID" \
  ORCHARD_SOURCE_DEV_LIFECYCLE_TEST_STOP=after_intent_recorded "$COMMAND" transition initialize "$OBSERVATION"
if base_env "$COMMAND" classify "$OBSERVATION" > "$TMP_ROOT/classification"; then
  fail "interrupted receipt classified terminal"
else
  [[ $? == 75 ]] || fail "interrupted receipt returned the wrong status"
fi
grep -Fx recovery_required "$TMP_ROOT/classification" >/dev/null || fail "interruption did not require recovery"
[[ "$(base_env "$COMMAND" recover "$OPERATION_UUID" "$OBSERVATION")" == initialized_stopped ]] || fail "exact recovery failed"

# Interruption after state publication resumes without incrementing state twice.
rm -rf "$FIXTURE/var/lib/orchard/install/receipts/lifecycle" "$FIXTURE/var/lib/orchard/install/lifecycle-state.json"
next_operation
expect_failure 'injected interruption' base_env ORCHARD_SOURCE_DEV_TEST_OPERATION_UUID="$OPERATION_UUID" \
  ORCHARD_SOURCE_DEV_LIFECYCLE_TEST_STOP=after_state_recorded "$COMMAND" transition initialize "$OBSERVATION"
if base_env "$COMMAND" classify "$OBSERVATION" > "$TMP_ROOT/classification"; then
  fail "post-state interruption classified terminal"
else
  [[ $? == 75 ]] || fail "post-state interruption returned the wrong status"
fi
grep -Fx recovery_required "$TMP_ROOT/classification" >/dev/null || fail "post-state interruption did not require recovery"
[[ "$(base_env "$COMMAND" recover "$OPERATION_UUID" "$OBSERVATION")" == initialized_stopped ]] ||
  fail "post-state interruption did not finish its receipt"
jq -e '.generation == 1' "$FIXTURE/var/lib/orchard/install/lifecycle-state.json" >/dev/null ||
  fail "post-state recovery advanced state twice"

# Changed evidence after state publication cannot finalize the pending receipt.
rm -rf "$FIXTURE/var/lib/orchard/install/receipts/lifecycle" "$FIXTURE/var/lib/orchard/install/lifecycle-state.json"
next_operation
expect_failure 'injected interruption' base_env ORCHARD_SOURCE_DEV_TEST_OPERATION_UUID="$OPERATION_UUID" \
  ORCHARD_SOURCE_DEV_LIFECYCLE_TEST_STOP=after_state_recorded "$COMMAND" transition initialize "$OBSERVATION"
jq '.reboot.boot_id = "post-state-other-boot"' "$OBSERVATION" > "$TMP_ROOT/changed.json"
mv "$TMP_ROOT/changed.json" "$OBSERVATION"; chmod 600 "$OBSERVATION"
expect_failure 'recovery is required' base_env "$COMMAND" recover "$OPERATION_UUID" "$OBSERVATION"
jq -e '.phase == "recovery_required" and .serving == false and .schedulable == false' \
  "$FIXTURE/var/lib/orchard/install/lifecycle-state.json" >/dev/null || fail "changed post-state evidence published readiness"

# Changed evidence cannot resume and moves to an explicit recovery-required state.
rm -rf "$FIXTURE/var/lib/orchard/install/receipts/lifecycle" "$FIXTURE/var/lib/orchard/install/lifecycle-state.json"
next_operation
expect_failure 'injected interruption' base_env ORCHARD_SOURCE_DEV_TEST_OPERATION_UUID="$OPERATION_UUID" \
  ORCHARD_SOURCE_DEV_LIFECYCLE_TEST_STOP=after_intent_recorded "$COMMAND" transition initialize "$OBSERVATION"
jq '.reboot.boot_id = "other-boot"' "$OBSERVATION" > "$TMP_ROOT/changed.json"
mv "$TMP_ROOT/changed.json" "$OBSERVATION"; chmod 600 "$OBSERVATION"
expect_failure 'recovery is required' base_env "$COMMAND" recover "$OPERATION_UUID" "$OBSERVATION"
jq -e '.phase == "recovery_required" and .serving == false and .schedulable == false' \
  "$FIXTURE/var/lib/orchard/install/lifecycle-state.json" >/dev/null || fail "uncertain recovery published readiness"
if base_env "$COMMAND" classify "$OBSERVATION" > "$TMP_ROOT/classification"; then
  fail "changed-evidence recovery classified as healthy"
else
  [[ $? == 75 ]] || fail "changed-evidence recovery receipt chain is invalid"
fi

# Every ambiguity class blocks before a receipt is written.
rm -rf "$FIXTURE/var/lib/orchard/install/receipts/lifecycle" "$FIXTURE/var/lib/orchard/install/lifecycle-state.json"
write_observation
for mutation in \
  '.ambiguities = ["duplicate checkout"]' \
  '.supervisor.ownership = "foreign"' \
  '.database.classification = "ambiguous"' \
  '.controller.identity = "foreign"' \
  '.controller.listener = "ambiguous"' \
  '.node.identity = "foreign"' \
  '.worker.classification = "blocked_ambiguous_ownership"'; do
  jq "$mutation" "$OBSERVATION" > "$TMP_ROOT/blocked.json"
  chmod 600 "$TMP_ROOT/blocked.json"
  if base_env "$COMMAND" classify "$TMP_ROOT/blocked.json" > "$TMP_ROOT/classification"; then
    fail "$mutation was not blocked"
  else
    [[ $? == 78 ]] || fail "$mutation returned the wrong status"
  fi
  grep -Fx blocked_ambiguous_ownership "$TMP_ROOT/classification" >/dev/null || fail "$mutation was misclassified"
done

for mutation in '.node.schedulable = true' '.worker.capacity_published = true' '.worker.workers_active = true' \
  '.controller = {identity:"absent",listener:"absent",state:"ready"}' \
  '.node = {identity:"exact",state:"ready",admitted:false,authenticated:true,observation_fresh:true,drained:false,schedulable:false}' \
  '.node = {identity:"exact",state:"ready",admitted:true,authenticated:true,observation_fresh:true,drained:false,schedulable:false}'; do
  jq "$mutation" "$OBSERVATION" > "$TMP_ROOT/contradictory.json"
  chmod 600 "$TMP_ROOT/contradictory.json"
  expect_failure 'contradicts source-only readiness or capacity boundaries' \
    base_env "$COMMAND" classify "$TMP_ROOT/contradictory.json"
done

for mutation in '.supervisor.ownership = "exact_stale"' '.controller.listener = "exact_stale"' \
  '.worker.classification = "recovery_required_owned_survivors"'; do
  jq "$mutation" "$OBSERVATION" > "$TMP_ROOT/stale.json"
  chmod 600 "$TMP_ROOT/stale.json"
  if base_env "$COMMAND" classify "$TMP_ROOT/stale.json" > "$TMP_ROOT/classification"; then
    fail "$mutation was not sent to recovery"
  else
    [[ $? == 75 ]] || fail "$mutation returned the wrong recovery status"
  fi
done

# Diagnostics are deterministic allowlisted evidence, not raw observation or logs.
base_env "$COMMAND" diagnose "$OBSERVATION" > "$TMP_ROOT/diagnostics-a.json"
base_env "$COMMAND" diagnose "$OBSERVATION" > "$TMP_ROOT/diagnostics-b.json"
cmp -s "$TMP_ROOT/diagnostics-a.json" "$TMP_ROOT/diagnostics-b.json" || fail "diagnostics are nondeterministic"
jq -e '.readiness == {serving:false,schedulable:false,worker_capacity_published:false} and
  .redaction.policy == "allowlist_only" and .support_status == "unqualified"' "$TMP_ROOT/diagnostics-a.json" >/dev/null ||
  fail "diagnostics omitted fail-closed or redaction status"
printf 'password=forbidden\npeer_grant=forbidden\nDATABASE_URL=forbidden\nrequest secret\n' >> "$OBSERVATION"
expect_failure 'observation is malformed' base_env "$COMMAND" diagnose "$OBSERVATION"
grep -R -E 'password=|peer_grant=|DATABASE_URL=|request secret' "$FIXTURE/var/lib/orchard/install" >/dev/null &&
  fail "diagnostics or receipts retained forbidden fixture secrets"

# Unsafe receipt directories and malformed terminal history fail closed.
write_observation
rm -rf "$FIXTURE/var/lib/orchard/install/receipts/lifecycle" "$FIXTURE/var/lib/orchard/install/lifecycle-state.json"
ln -s "$TMP_ROOT" "$FIXTURE/var/lib/orchard/install/receipts/lifecycle"
expect_failure 'refusing symlink path component' run_transition initialize
rm "$FIXTURE/var/lib/orchard/install/receipts/lifecycle"
mkdir -m 700 "$FIXTURE/var/lib/orchard/install/receipts/lifecycle"
printf '{}\n' > "$FIXTURE/var/lib/orchard/install/receipts/lifecycle/foreign.json"
chmod 600 "$FIXTURE/var/lib/orchard/install/receipts/lifecycle/foreign.json"
expect_failure 'receipt history is malformed' base_env "$COMMAND" classify "$OBSERVATION"
rm -rf "$FIXTURE/var/lib/orchard/install/receipts/lifecycle"

# Shared lifecycle exclusion is non-blocking and does not steal the lock.
write_observation
exec 8<>"$FIXTURE/var/lib/orchard/install/lifecycle.lock"
flock 8
expect_failure 'lifecycle lock is already held' run_transition initialize
flock -u 8

printf 'test-source-dev-lifecycle: PASS\n'
