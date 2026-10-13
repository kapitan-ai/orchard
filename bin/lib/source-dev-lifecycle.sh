#!/usr/bin/env bash

orchard_source_lifecycle_fail() {
  printf 'orchard-source-lifecycle: %s\n' "$1" >&2
  return "${2:-1}"
}

orchard_source_lifecycle_main() {
  local command=${1:-}
  case "$command" in
    classify|diagnose)
      [[ $# -eq 2 ]] || orchard_source_lifecycle_fail "usage: orchard-source-lifecycle $command OBSERVATION" 64 || return $?
      ;;
    transition)
      [[ $# -eq 3 ]] || orchard_source_lifecycle_fail "usage: orchard-source-lifecycle transition OPERATION OBSERVATION" 64 || return $?
      ;;
    recover)
      [[ $# -eq 3 ]] || orchard_source_lifecycle_fail "usage: orchard-source-lifecycle recover OPERATION-UUID OBSERVATION" 64 || return $?
      ;;
    *)
      orchard_source_lifecycle_fail "usage: orchard-source-lifecycle classify|diagnose|transition|recover ..." 64
      return $?
      ;;
  esac

  orchard_source_lifecycle_paths
  orchard_source_lifecycle_validate_invocation || return $?

  case "$command" in
    classify)
      orchard_source_lifecycle_validate_installation || return $?
      orchard_source_lifecycle_validate_observation "$2" || return $?
      orchard_source_lifecycle_classify "$2"
      ;;
    diagnose)
      orchard_source_lifecycle_validate_installation || return $?
      orchard_source_lifecycle_validate_observation "$2" || return $?
      orchard_source_lifecycle_diagnose "$2"
      ;;
    transition)
      orchard_source_lifecycle_safe_file "$ORCHARD_LIFECYCLE_LOCK" || return $?
      orchard_source_lifecycle_lock || return $?
      orchard_source_lifecycle_validate_installation || return $?
      orchard_source_lifecycle_snapshot_observation "$3" || return $?
      orchard_source_lifecycle_validate_observation "$ORCHARD_LIFECYCLE_OBSERVATION_COPY" || return $?
      orchard_source_lifecycle_transition "$2" "$ORCHARD_LIFECYCLE_OBSERVATION_COPY"
      ;;
    recover)
      orchard_source_lifecycle_safe_file "$ORCHARD_LIFECYCLE_LOCK" || return $?
      orchard_source_lifecycle_lock || return $?
      orchard_source_lifecycle_validate_installation || return $?
      orchard_source_lifecycle_snapshot_observation "$3" || return $?
      orchard_source_lifecycle_validate_observation "$ORCHARD_LIFECYCLE_OBSERVATION_COPY" || return $?
      orchard_source_lifecycle_recover "$2" "$ORCHARD_LIFECYCLE_OBSERVATION_COPY"
      ;;
  esac
}

orchard_source_lifecycle_snapshot_observation() {
  local source=$1
  orchard_source_lifecycle_safe_file "$source" || return $?
  ORCHARD_LIFECYCLE_OBSERVATION_COPY=$(mktemp "$ORCHARD_LIFECYCLE_INSTALL/.observation.XXXXXX") || return $?
  trap 'rm -f "${ORCHARD_LIFECYCLE_OBSERVATION_COPY:-}"' EXIT INT TERM
  cat "$source" > "$ORCHARD_LIFECYCLE_OBSERVATION_COPY" || return $?
  chmod 600 "$ORCHARD_LIFECYCLE_OBSERVATION_COPY" || return $?
}

orchard_source_lifecycle_paths() {
  ORCHARD_LIFECYCLE_ROOT=${ORCHARD_SOURCE_DEV_ROOT:-}
  ORCHARD_LIFECYCLE_PREFIX=${ORCHARD_LIFECYCLE_ROOT%/}
  ORCHARD_LIFECYCLE_SOURCE=${ORCHARD_SOURCE_DEV_SOURCE:-${ORCHARD_LIFECYCLE_PREFIX}/opt/orchard/source}
  ORCHARD_LIFECYCLE_INSTALL="${ORCHARD_LIFECYCLE_PREFIX}/var/lib/orchard/install"
  ORCHARD_LIFECYCLE_MANIFEST="$ORCHARD_LIFECYCLE_INSTALL/manifest.json"
  ORCHARD_LIFECYCLE_PREPARE_RECEIPT="$ORCHARD_LIFECYCLE_INSTALL/receipts/prepare.json"
  ORCHARD_LIFECYCLE_COMPOSITION="${ORCHARD_LIFECYCLE_PREFIX}/etc/orchard/source-dev/composition.json"
  ORCHARD_LIFECYCLE_COMPOSITION_RECEIPT="$ORCHARD_LIFECYCLE_INSTALL/receipts/composition.json"
  ORCHARD_LIFECYCLE_LOCK="$ORCHARD_LIFECYCLE_INSTALL/lifecycle.lock"
  ORCHARD_LIFECYCLE_RECEIPTS="$ORCHARD_LIFECYCLE_INSTALL/receipts/lifecycle"
  ORCHARD_LIFECYCLE_STATE="$ORCHARD_LIFECYCLE_INSTALL/lifecycle-state.json"
}

orchard_source_lifecycle_validate_invocation() {
  local required
  for required in git jq sha256sum flock stat install sync find; do
    command -v "$required" >/dev/null 2>&1 || {
      orchard_source_lifecycle_fail "$required is required"
      return $?
    }
  done
  if [[ -n "$ORCHARD_LIFECYCLE_ROOT" ]]; then
    [[ "$ORCHARD_LIFECYCLE_ROOT" == /* && ${ORCHARD_SOURCE_DEV_TESTING:-0} == 1 ]] || {
      orchard_source_lifecycle_fail "relocated roots require an absolute root and ORCHARD_SOURCE_DEV_TESTING=1" 64
      return $?
    }
  else
    [[ ${EUID:-$(id -u)} -eq 0 ]] || {
      orchard_source_lifecycle_fail "canonical lifecycle operations must run as root"
      return $?
    }
  fi
  [[ "$ORCHARD_LIFECYCLE_SOURCE" == "${ORCHARD_LIFECYCLE_PREFIX}/opt/orchard/source" ]] || {
    orchard_source_lifecycle_fail "source checkout must be the canonical /opt/orchard/source"
    return $?
  }
}

orchard_source_lifecycle_validate_installation() {
  local path
  for path in "$ORCHARD_LIFECYCLE_MANIFEST" "$ORCHARD_LIFECYCLE_PREPARE_RECEIPT" \
    "$ORCHARD_LIFECYCLE_COMPOSITION" "$ORCHARD_LIFECYCLE_COMPOSITION_RECEIPT" "$ORCHARD_LIFECYCLE_LOCK"; do
    orchard_source_lifecycle_safe_file "$path" || return $?
  done
  ORCHARD_LIFECYCLE_INSTALLATION_UUID=$(jq -r '.installation_uuid' "$ORCHARD_LIFECYCLE_MANIFEST")
  ORCHARD_LIFECYCLE_COMMIT=$(jq -r '.source.commit' "$ORCHARD_LIFECYCLE_MANIFEST")
  ORCHARD_LIFECYCLE_TREE=$(jq -r '.source.tree' "$ORCHARD_LIFECYCLE_MANIFEST")
  ORCHARD_LIFECYCLE_VERSION=$(jq -r '.product_version' "$ORCHARD_LIFECYCLE_MANIFEST")
  local manifest_sha composition_sha worker_policy_sha current_commit current_tree current_status
  manifest_sha=$(sha256sum "$ORCHARD_LIFECYCLE_MANIFEST" | cut -d ' ' -f1) || return $?
  composition_sha=$(sha256sum "$ORCHARD_LIFECYCLE_COMPOSITION" | cut -d ' ' -f1) || return $?
  worker_policy_sha=$(sha256sum "$ORCHARD_LIFECYCLE_SOURCE/rel/linux/source-dev/worker-custody.json" | cut -d ' ' -f1) || return $?
  jq -e --arg uuid "$ORCHARD_LIFECYCLE_INSTALLATION_UUID" --arg commit "$ORCHARD_LIFECYCLE_COMMIT" \
    --arg tree "$ORCHARD_LIFECYCLE_TREE" --arg worker "$worker_policy_sha" '
    .schema_version == 1 and .profile == "ubuntu_24_04_x86_64_single_host" and
    .activation == "disabled" and .support_status == "unqualified" and
    .installation_uuid == $uuid and .source.commit == $commit and .source.tree == $tree and
    .worker_custody.policy_sha256 == $worker and .worker_custody.activation == "disabled"
  ' "$ORCHARD_LIFECYCLE_MANIFEST" >/dev/null || {
    orchard_source_lifecycle_fail "installation manifest is incompatible or ambiguous"
    return $?
  }
  jq -e '.phase == "source_prepared" and .generation == 4' "$ORCHARD_LIFECYCLE_PREPARE_RECEIPT" >/dev/null || {
    orchard_source_lifecycle_fail "source preparation is incomplete"
    return $?
  }
  jq -e --arg uuid "$ORCHARD_LIFECYCLE_INSTALLATION_UUID" --arg manifest "$manifest_sha" '
    .installation_uuid == $uuid and .activation == "disabled" and
    .support_status == "unqualified" and .source.manifest_sha256 == $manifest and
    .fallback == {grpc:false,cookie:false,static_target:false}
  ' "$ORCHARD_LIFECYCLE_COMPOSITION" >/dev/null || {
    orchard_source_lifecycle_fail "composition identity or fallback policy is incompatible"
    return $?
  }
  jq -e --arg uuid "$ORCHARD_LIFECYCLE_INSTALLATION_UUID" --arg digest "$composition_sha" '
    .installation_uuid == $uuid and .phase == "composition_prepared_inert" and
    .activation == "disabled" and .composition_sha256 == $digest
  ' "$ORCHARD_LIFECYCLE_COMPOSITION_RECEIPT" >/dev/null || {
    orchard_source_lifecycle_fail "composition receipt is stale or ambiguous"
    return $?
  }
  current_commit=$(git -C "$ORCHARD_LIFECYCLE_SOURCE" rev-parse --verify HEAD^{commit}) || return $?
  current_tree=$(git -C "$ORCHARD_LIFECYCLE_SOURCE" rev-parse --verify HEAD^{tree}) || return $?
  current_status=$(git -C "$ORCHARD_LIFECYCLE_SOURCE" status --porcelain=v1 --untracked-files=all) || return $?
  [[ "$current_commit" == "$ORCHARD_LIFECYCLE_COMMIT" && "$current_tree" == "$ORCHARD_LIFECYCLE_TREE" && -z "$current_status" ]] || {
    orchard_source_lifecycle_fail "source checkout no longer matches the prepared manifest"
    return $?
  }
}

orchard_source_lifecycle_validate_observation() {
  local observation=$1
  orchard_source_lifecycle_safe_file "$observation" || return $?
  jq -e --arg uuid "$ORCHARD_LIFECYCLE_INSTALLATION_UUID" --arg commit "$ORCHARD_LIFECYCLE_COMMIT" --arg tree "$ORCHARD_LIFECYCLE_TREE" '
    (keys | sort) == ["ambiguities","controller","database","installation_uuid","node","reboot","schema_version","source","supervisor","worker"] and
    .schema_version == 1 and .installation_uuid == $uuid and .source == {commit:$commit,tree:$tree} and
    (.ambiguities | type == "array" and all(.[]; type == "string")) and
    (.supervisor | keys | sort) == ["ownership"] and (.supervisor.ownership | IN("exact","exact_stale","foreign","ambiguous")) and
    (.database | keys | sort) == ["classification","schema_identity"] and
    (.database.classification | IN("source_prepared","initialized_stopped","database_ready","recovery_required","foreign","ambiguous")) and
    (.database.schema_identity == null or (.database.schema_identity | test("^[0-9]+$"))) and
    (.controller | keys | sort) == ["identity","listener","state"] and
    (.controller.identity | IN("exact","absent","foreign","ambiguous")) and
    (.controller.listener | IN("absent","exact","exact_stale","foreign","ambiguous")) and
    (.controller.state | IN("stopped","ready","failed","unknown")) and
    (.node | keys | sort) == ["admitted","authenticated","drained","identity","observation_fresh","schedulable","state"] and
    (.node.identity | IN("exact","absent","foreign","ambiguous")) and
    (.node.state | IN("stopped","ready","failed","unknown")) and
    ([.node.admitted,.node.authenticated,.node.drained,.node.observation_fresh,.node.schedulable] | all(.[]; type == "boolean")) and
    (.worker | keys | sort) == ["capacity_published","classification","workers_active"] and
    (.worker.classification | IN("stopped_empty","running_owned","recovery_required_owned_survivors","recovery_required_owned_stale_listeners","blocked_ambiguous_ownership","blocked_open_gate_without_agent")) and
    (.worker.capacity_published | type == "boolean") and (.worker.workers_active | type == "boolean") and
    (.reboot | keys | sort) == ["boot_id","intent_boot_id"] and
    (.reboot.boot_id | type == "string" and length > 0) and
    (.reboot.intent_boot_id == null or (.reboot.intent_boot_id | type == "string" and length > 0))
  ' "$observation" >/dev/null || {
    orchard_source_lifecycle_fail "observation is malformed, foreign, or ambiguous"
    return $?
  }
  jq -e '
    (.node.schedulable | not) and (.worker.capacity_published | not) and (.worker.workers_active | not) and
    (if .controller.state == "ready" then .controller.identity == "exact" and .controller.listener == "exact" else true end) and
    (if .controller.state == "stopped" then .controller.listener != "exact" else true end) and
    (if .node.state == "ready" then
      .node.identity == "exact" and .node.admitted and .node.authenticated and .node.observation_fresh and
      .database.classification == "database_ready" and .controller.state == "ready"
    else true end) and
    (if .worker.classification == "running_owned" then .node.state == "ready" else true end)
  ' "$observation" >/dev/null || {
    orchard_source_lifecycle_fail "observation contradicts source-only readiness or capacity boundaries"
    return $?
  }
  ORCHARD_LIFECYCLE_OBSERVATION_SHA=$(sha256sum "$observation" | cut -d ' ' -f1) || return $?
}

orchard_source_lifecycle_lock() {
  exec 9<>"$ORCHARD_LIFECYCLE_LOCK"
  flock -n 9 || {
    orchard_source_lifecycle_fail "lifecycle lock is already held"
    return $?
  }
}

orchard_source_lifecycle_current_phase() {
  if [[ ! -e "$ORCHARD_LIFECYCLE_STATE" && ! -L "$ORCHARD_LIFECYCLE_STATE" ]]; then
    printf 'composition_prepared\n'
    return 0
  fi
  orchard_source_lifecycle_safe_file "$ORCHARD_LIFECYCLE_STATE" || return $?
  orchard_source_lifecycle_validate_receipt_history || return $?
  jq -er --arg uuid "$ORCHARD_LIFECYCLE_INSTALLATION_UUID" --arg commit "$ORCHARD_LIFECYCLE_COMMIT" --arg tree "$ORCHARD_LIFECYCLE_TREE" '
    select(.schema_version == 1 and .installation_uuid == $uuid and .source == {commit:$commit,tree:$tree} and
      (.generation | type == "number" and . >= 1 and floor == .) and
      (.phase | IN("composition_prepared","initialized_stopped","database_ready","schema_current","controller_ready","ready_composed","drained","stopped","reboot_pending","backup_complete","upgrade_prepared","restored_non_serving","retired","recovery_required"))) | .phase
  ' "$ORCHARD_LIFECYCLE_STATE" || {
    orchard_source_lifecycle_fail "lifecycle state is foreign or ambiguous"
    return $?
  }
}

orchard_source_lifecycle_nonterminal_receipt() {
  [[ -d "$ORCHARD_LIFECYCLE_RECEIPTS" ]] || return 1
  orchard_source_lifecycle_validate_receipt_history || return $?
  local receipt
  while IFS= read -r receipt; do
    jq -e '.terminal == true' "$receipt" >/dev/null 2>&1 || {
      printf '%s\n' "$receipt"
      return 0
    }
  done < <(find "$ORCHARD_LIFECYCLE_RECEIPTS" -maxdepth 1 -type f -name '*.json' -print | LC_ALL=C sort)
  return 1
}

orchard_source_lifecycle_classify() {
  local observation=$1 receipt phase
  if [[ -e "$ORCHARD_LIFECYCLE_RECEIPTS" || -L "$ORCHARD_LIFECYCLE_RECEIPTS" ]]; then
    orchard_source_lifecycle_validate_receipt_history || return $?
  fi
  if receipt=$(orchard_source_lifecycle_nonterminal_receipt); then
    printf 'recovery_required\n'
    return 75
  fi
  if [[ $(jq '.ambiguities | length' "$observation") -gt 0 ]] ||
    jq -e '(.supervisor.ownership | IN("foreign","ambiguous"))' "$observation" >/dev/null ||
    jq -e '(.database.classification | IN("foreign","ambiguous","recovery_required"))' "$observation" >/dev/null ||
    jq -e '(.controller.identity | IN("foreign","ambiguous")) or (.controller.listener | IN("foreign","ambiguous")) or (.node.identity | IN("foreign","ambiguous")) or (.worker.classification | startswith("blocked_"))' "$observation" >/dev/null; then
    printf 'blocked_ambiguous_ownership\n'
    return 78
  fi
  if jq -e '.supervisor.ownership == "exact_stale" or .controller.listener == "exact_stale" or (.worker.classification | startswith("recovery_required_"))' "$observation" >/dev/null; then
    printf 'recovery_required\n'
    return 75
  fi
  phase=$(orchard_source_lifecycle_current_phase) || return $?
  printf '%s\n' "$phase"
  [[ "$phase" != recovery_required ]] || return 75
}

orchard_source_lifecycle_transition() {
  local operation=$1 observation=$2 current target
  orchard_source_lifecycle_classify "$observation" >/dev/null || {
    orchard_source_lifecycle_fail "transition requires an unambiguous terminal lifecycle state"
    return $?
  }
  current=$(orchard_source_lifecycle_current_phase) || return $?
  target=$(orchard_source_lifecycle_target "$operation" "$current" "$observation") || return $?
  orchard_source_lifecycle_begin_receipt "$operation" "$current" "$target" "$observation" || return $?
  orchard_source_lifecycle_test_stop after_intent_recorded || return $?
  orchard_source_lifecycle_commit "$target" "$observation" || return $?
  orchard_source_lifecycle_test_stop after_state_recorded || return $?
  orchard_source_lifecycle_finish_receipt "$target" || return $?
  printf '%s\n' "$target"
}

orchard_source_lifecycle_target() {
  local operation=$1 current=$2 observation=$3
  case "$operation:$current" in
    initialize:composition_prepared)
      orchard_source_lifecycle_require "$observation" '.database.classification == "initialized_stopped" and .controller.state == "stopped" and .node.state == "stopped" and .worker.classification == "stopped_empty"' initialize || return $?
      printf 'initialized_stopped\n'
      ;;
    start-database:initialized_stopped|start-database:stopped)
      orchard_source_lifecycle_require "$observation" '.database.classification == "database_ready" and .controller.state == "stopped" and .node.state == "stopped"' start-database || return $?
      printf 'database_ready\n'
      ;;
    migrate:database_ready)
      orchard_source_lifecycle_require "$observation" '.database.classification == "database_ready" and .database.schema_identity != null and .controller.state == "stopped" and .node.state == "stopped"' migrate || return $?
      printf 'schema_current\n'
      ;;
    start-controller:schema_current)
      orchard_source_lifecycle_require "$observation" '.database.classification == "database_ready" and .database.schema_identity != null and .controller.identity == "exact" and .controller.listener == "exact" and .controller.state == "ready" and .node.state == "stopped"' start-controller || return $?
      printf 'controller_ready\n'
      ;;
    start-node:controller_ready|restart-node:ready_composed)
      orchard_source_lifecycle_require "$observation" '.database.classification == "database_ready" and .controller.state == "ready" and .node.identity == "exact" and .node.state == "ready" and .node.admitted and .node.authenticated and .node.observation_fresh and .worker.classification == "running_owned"' "$operation" || return $?
      printf 'ready_composed\n'
      ;;
    drain:ready_composed)
      orchard_source_lifecycle_require "$observation" '.node.drained and (.node.schedulable | not) and .worker.classification == "stopped_empty" and (.worker.capacity_published | not)' drain || return $?
      printf 'drained\n'
      ;;
    stop:initialized_stopped|stop:database_ready|stop:schema_current|stop:controller_ready|stop:ready_composed|stop:drained|stop:backup_complete|stop:restored_non_serving)
      orchard_source_lifecycle_require_stopped "$observation" stop || return $?
      printf 'stopped\n'
      ;;
    restart-database:ready_composed)
      orchard_source_lifecycle_require "$observation" '.database.classification == "database_ready" and .database.schema_identity != null and .controller.state == "stopped" and .node.state == "stopped" and (.node.schedulable | not) and (.worker.capacity_published | not)' restart-database || return $?
      printf 'schema_current\n'
      ;;
    restart-controller:ready_composed)
      orchard_source_lifecycle_require "$observation" '.database.classification == "database_ready" and .controller.state == "ready" and .controller.identity == "exact" and .controller.listener == "exact" and .node.state == "stopped" and .worker.classification == "stopped_empty"' restart-controller || return $?
      printf 'controller_ready\n'
      ;;
    reboot-intent:stopped)
      orchard_source_lifecycle_require_stopped "$observation" reboot-intent || return $?
      orchard_source_lifecycle_require "$observation" '.reboot.intent_boot_id == .reboot.boot_id' reboot-intent || return $?
      printf 'reboot_pending\n'
      ;;
    reconcile-reboot:reboot_pending)
      orchard_source_lifecycle_require_stopped "$observation" reconcile-reboot || return $?
      orchard_source_lifecycle_require "$observation" '.reboot.intent_boot_id != null and .reboot.intent_boot_id != .reboot.boot_id' reconcile-reboot || return $?
      printf 'stopped\n'
      ;;
    backup:drained|backup:stopped)
      orchard_source_lifecycle_require "$observation" '.controller.state == "stopped" and .node.state == "stopped" and .node.drained and .worker.classification == "stopped_empty" and (.worker.capacity_published | not)' backup || return $?
      printf 'backup_complete\n'
      ;;
    upgrade-prepare:backup_complete)
      orchard_source_lifecycle_require_stopped "$observation" upgrade-prepare || return $?
      printf 'upgrade_prepared\n'
      ;;
    rollback:upgrade_prepared)
      orchard_source_lifecycle_require_compatibility || return $?
      orchard_source_lifecycle_require_stopped "$observation" rollback || return $?
      printf 'stopped\n'
      ;;
    restore:stopped|restore:upgrade_prepared)
      orchard_source_lifecycle_require "$observation" '.database.classification == "initialized_stopped" and .controller.state == "stopped" and .node.state == "stopped" and (.node.schedulable | not) and (.worker.capacity_published | not)' restore || return $?
      orchard_source_lifecycle_validate_restore_gate || return $?
      printf 'restored_non_serving\n'
      ;;
    retire:stopped|retire:restored_non_serving)
      orchard_source_lifecycle_require_stopped "$observation" retire || return $?
      printf 'retired\n'
      ;;
    reprepare:retired)
      orchard_source_lifecycle_require_stopped "$observation" reprepare || return $?
      printf 'stopped\n'
      ;;
    *)
      orchard_source_lifecycle_fail "invalid lifecycle transition $current -> $operation"
      return $?
      ;;
  esac
}

orchard_source_lifecycle_require() {
  local observation=$1 predicate=$2 operation=$3
  jq -e "$predicate" "$observation" >/dev/null || {
    orchard_source_lifecycle_fail "$operation observation does not prove its required bounded outcome"
    return $?
  }
}

orchard_source_lifecycle_require_stopped() {
  orchard_source_lifecycle_require "$1" '
    .database.classification == "initialized_stopped" and .controller.state == "stopped" and
    .node.state == "stopped" and (.node.schedulable | not) and
    .worker.classification == "stopped_empty" and (.worker.capacity_published | not)
  ' "$2"
}

orchard_source_lifecycle_require_compatibility() {
  local compatibility=${ORCHARD_SOURCE_DEV_COMPATIBILITY_MANIFEST:-}
  [[ -n "$compatibility" ]] || {
    orchard_source_lifecycle_fail "rollback requires an exact compatibility manifest" 64
    return $?
  }
  orchard_source_lifecycle_safe_file "$compatibility" || return $?
  local schema target_commit=${ORCHARD_SOURCE_DEV_ROLLBACK_COMMIT:-} target_tree=${ORCHARD_SOURCE_DEV_ROLLBACK_TREE:-} checkpoint=${ORCHARD_SOURCE_DEV_ROLLBACK_CHECKPOINT_SHA256:-}
  [[ "$target_commit" =~ ^[0-9a-f]{40}$ && "$target_tree" =~ ^[0-9a-f]{40}$ && "$checkpoint" =~ ^[0-9a-f]{64}$ ]] || {
    orchard_source_lifecycle_fail "rollback requires exact target source and checkpoint identities" 64
    return $?
  }
  schema=$(jq -r '.schema_identity // empty' "$ORCHARD_LIFECYCLE_STATE") || return $?
  jq -e --arg uuid "$ORCHARD_LIFECYCLE_INSTALLATION_UUID" --arg commit "$ORCHARD_LIFECYCLE_COMMIT" \
    --arg tree "$ORCHARD_LIFECYCLE_TREE" --arg version "$ORCHARD_LIFECYCLE_VERSION" --arg schema "$schema" \
    --arg target_commit "$target_commit" --arg target_tree "$target_tree" --arg checkpoint "$checkpoint" '
    (keys | sort) == ["audit_semantics","authorization_contract","checkpoint_sha256","credential_and_governance_writers","durable_cutovers","ingress_fence","installation_uuid","observed_source","product_version","retained_state","rollback_source","schema","schema_identity"] and
    .installation_uuid == $uuid and .product_version == $version and
    .observed_source == {commit:$commit,tree:$tree} and
    .rollback_source == {commit:$target_commit,tree:$target_tree} and .checkpoint_sha256 == $checkpoint and
    .schema_identity == $schema and
    ([.schema,.retained_state,.authorization_contract,.credential_and_governance_writers,
      .audit_semantics,.ingress_fence,.durable_cutovers] | all(.[]; . == true))
  ' "$compatibility" >/dev/null || {
    orchard_source_lifecycle_fail "rollback compatibility is incomplete; roll forward or restore the fenced checkpoint" 78
    return $?
  }
}

orchard_source_lifecycle_validate_restore_gate() {
  local gate="$ORCHARD_LIFECYCLE_INSTALL/restore-recovery.json"
  orchard_source_lifecycle_safe_file "$gate" >/dev/null 2>&1 || {
    orchard_source_lifecycle_fail "restore requires an exact PostgreSQL new-key recovery gate"
    return $?
  }
  local reference
  reference=$(jq -r '.reference // empty' "$gate") || return $?
  jq -e --arg uuid "$ORCHARD_LIFECYCLE_INSTALLATION_UUID" '
    (keys | sort) == ["installation_uuid","reference","schedulable","schema_version","serving","state"] and
    .schema_version == 1 and .installation_uuid == $uuid and
    (.reference | test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")) and
    .state == "new_key_recovery_required" and .serving == false and .schedulable == false
  ' "$gate" >/dev/null || {
    orchard_source_lifecycle_fail "restore requires an exact PostgreSQL new-key recovery gate"
    return $?
  }
  local matched=0 receipt
  while IFS= read -r receipt; do
    if orchard_source_lifecycle_safe_file "$receipt" >/dev/null 2>&1 && jq -e --arg uuid "$ORCHARD_LIFECYCLE_INSTALLATION_UUID" --arg reference "$reference" \
      --arg version "$ORCHARD_LIFECYCLE_VERSION" --arg commit "$ORCHARD_LIFECYCLE_COMMIT" --arg tree "$ORCHARD_LIFECYCLE_TREE" '
      (keys | sort) == ["details","generation","installation_uuid","intended_product_version","operation","operation_uuid","phase","schema_version","source","terminal"] and
      .schema_version == 1 and .installation_uuid == $uuid and .intended_product_version == $version and
      .source == {commit:$commit,tree:$tree} and
      .operation == "restore" and (.operation_uuid | test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")) and
      .generation == 2 and .phase == "database_restored_non_serving" and .terminal == true and
      .details == {backup_id:$reference,recovery:"new_key_recovery_required",serving:false}
    ' "$receipt" >/dev/null; then
      matched=$((matched + 1))
    fi
  done < <(find "$ORCHARD_LIFECYCLE_INSTALL/receipts/postgresql" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null | LC_ALL=C sort)
  [[ "$matched" -eq 1 ]] || {
    orchard_source_lifecycle_fail "restore gate is not bound to one exact terminal PostgreSQL restore receipt"
    return $?
  }
}

orchard_source_lifecycle_validate_receipt_history() {
  orchard_source_lifecycle_safe_directory "$ORCHARD_LIFECYCLE_RECEIPTS" || return $?
  local entry receipt_count=0 terminal_count=0 nonterminal_count=0 state_generation sequence prior target state_operation="" state_phase="" pending_operation="" pending_phase=""
  while IFS= read -r entry; do
    [[ -f "$entry" && ! -L "$entry" ]] || {
      orchard_source_lifecycle_fail "lifecycle receipt history contains an unsafe entry"
      return $?
    }
    orchard_source_lifecycle_safe_file "$entry" || return $?
    jq -e --arg uuid "$ORCHARD_LIFECYCLE_INSTALLATION_UUID" --arg commit "$ORCHARD_LIFECYCLE_COMMIT" --arg tree "$ORCHARD_LIFECYCLE_TREE" '
      (keys | sort) == ["generation","installation_uuid","intended_product_version","observation_sha256","operation","operation_uuid","phase","prior_phase","schedulable","schema_version","sequence","serving","source","target_phase","terminal"] and
      .schema_version == 1 and .installation_uuid == $uuid and .source == {commit:$commit,tree:$tree} and
      (.operation_uuid | test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")) and
      (.observation_sha256 | test("^[0-9a-f]{64}$")) and
      (.sequence | type == "number" and . >= 1 and floor == .) and
      (.generation | IN(1,2)) and (.terminal | type == "boolean") and
      (if .terminal then .generation == 2 and .phase == .target_phase else .generation == 1 and .phase == "intent_recorded" end) and
      .serving == false and .schedulable == false
    ' "$entry" >/dev/null || {
      orchard_source_lifecycle_fail "lifecycle receipt history is malformed, foreign, or non-monotonic"
      return $?
    }
    receipt_count=$((receipt_count + 1))
  done < <(find "$ORCHARD_LIFECYCLE_RECEIPTS" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort)
  prior=composition_prepared
  for ((sequence = 1; sequence <= receipt_count; sequence++)); do
    entry=$(jq -r --argjson sequence "$sequence" 'select(.sequence == $sequence) | input_filename' "$ORCHARD_LIFECYCLE_RECEIPTS"/*.json 2>/dev/null)
    [[ $(wc -l <<< "$entry") -eq 1 && -n "$entry" ]] || {
      orchard_source_lifecycle_fail "lifecycle receipt sequence is duplicated or incomplete"
      return $?
    }
    [[ "$(basename "$entry" .json)" == "$(jq -r '.operation_uuid' "$entry")" && "$(jq -r '.prior_phase' "$entry")" == "$prior" ]] || {
      orchard_source_lifecycle_fail "lifecycle receipt chain is incoherent"
      return $?
    }
    target=$(jq -r '.target_phase' "$entry")
    prior=$target
    if [[ $(jq -r '.terminal' "$entry") == true ]]; then
      terminal_count=$((terminal_count + 1))
      state_operation=$(jq -r '.operation_uuid' "$entry")
      state_phase=$target
    else
      nonterminal_count=$((nonterminal_count + 1))
      pending_operation=$(jq -r '.operation_uuid' "$entry")
      pending_phase=$target
      [[ "$sequence" -eq "$receipt_count" ]] || {
        orchard_source_lifecycle_fail "nonterminal lifecycle receipt is not the latest operation"
        return $?
      }
    fi
  done
  [[ "$nonterminal_count" -le 1 ]] || {
    orchard_source_lifecycle_fail "multiple lifecycle operations are nonterminal"
    return $?
  }
  if [[ -f "$ORCHARD_LIFECYCLE_STATE" ]]; then
    state_generation=$(jq -r '.generation' "$ORCHARD_LIFECYCLE_STATE") || return $?
    local observed_operation observed_phase
    observed_operation=$(jq -r '.last_operation_uuid' "$ORCHARD_LIFECYCLE_STATE") || return $?
    observed_phase=$(jq -r '.phase' "$ORCHARD_LIFECYCLE_STATE") || return $?
    if [[ "$nonterminal_count" -eq 1 && "$state_generation" =~ ^[0-9]+$ && "$state_generation" -eq $((terminal_count + 1)) &&
      "$observed_operation" == "$pending_operation" && "$observed_phase" == "$pending_phase" ]]; then
      return 0
    fi
    [[ "$state_generation" =~ ^[0-9]+$ && "$state_generation" -eq "$terminal_count" &&
      "$observed_operation" == "$state_operation" && "$observed_phase" == "$state_phase" ]] || {
      orchard_source_lifecycle_fail "lifecycle state and receipt generations disagree"
      return $?
    }
  elif [[ "$terminal_count" -ne 0 ]]; then
    orchard_source_lifecycle_fail "terminal lifecycle receipts exist without state"
    return $?
  fi
}

orchard_source_lifecycle_begin_receipt() {
  local operation=$1 current=$2 target=$3 observation=$4
  orchard_source_lifecycle_safe_directory "$(dirname "$ORCHARD_LIFECYCLE_RECEIPTS")" || return $?
  if [[ -e "$ORCHARD_LIFECYCLE_RECEIPTS" || -L "$ORCHARD_LIFECYCLE_RECEIPTS" ]]; then
    orchard_source_lifecycle_safe_directory "$ORCHARD_LIFECYCLE_RECEIPTS" || return $?
  else
    install -d -m 700 "$ORCHARD_LIFECYCLE_RECEIPTS" || return $?
    orchard_source_lifecycle_safe_directory "$ORCHARD_LIFECYCLE_RECEIPTS" || return $?
  fi
  ORCHARD_LIFECYCLE_OPERATION_UUID=${ORCHARD_SOURCE_DEV_TEST_OPERATION_UUID:-}
  if [[ -z "$ORCHARD_LIFECYCLE_OPERATION_UUID" ]]; then
    ORCHARD_LIFECYCLE_OPERATION_UUID=$(cat /proc/sys/kernel/random/uuid)
  fi
  orchard_source_lifecycle_uuid "$ORCHARD_LIFECYCLE_OPERATION_UUID" || return $?
  ORCHARD_LIFECYCLE_RECEIPT="$ORCHARD_LIFECYCLE_RECEIPTS/$ORCHARD_LIFECYCLE_OPERATION_UUID.json"
  [[ ! -e "$ORCHARD_LIFECYCLE_RECEIPT" && ! -L "$ORCHARD_LIFECYCLE_RECEIPT" ]] || {
    orchard_source_lifecycle_fail "operation UUID already has a durable receipt"
    return $?
  }
  local observation_sha sequence=1 temporary="$ORCHARD_LIFECYCLE_RECEIPT.new.$$"
  if [[ -f "$ORCHARD_LIFECYCLE_STATE" ]]; then
    sequence=$(( $(jq -r '.generation' "$ORCHARD_LIFECYCLE_STATE") + 1 ))
  fi
  observation_sha=$(sha256sum "$observation" | cut -d ' ' -f1) || return $?
  [[ "$observation_sha" == "$ORCHARD_LIFECYCLE_OBSERVATION_SHA" ]] || {
    orchard_source_lifecycle_fail "observation changed after validation"
    return $?
  }
  jq -n --arg operation "$operation" --arg operation_uuid "$ORCHARD_LIFECYCLE_OPERATION_UUID" \
    --arg installation "$ORCHARD_LIFECYCLE_INSTALLATION_UUID" --arg version "$ORCHARD_LIFECYCLE_VERSION" \
    --arg current "$current" --arg target "$target" --arg commit "$ORCHARD_LIFECYCLE_COMMIT" \
    --arg tree "$ORCHARD_LIFECYCLE_TREE" --arg observation "$observation_sha" --argjson sequence "$sequence" '
    {schema_version:1,sequence:$sequence,generation:1,operation:$operation,operation_uuid:$operation_uuid,
      installation_uuid:$installation,intended_product_version:$version,phase:"intent_recorded",
      prior_phase:$current,target_phase:$target,terminal:false,serving:false,schedulable:false,
      source:{commit:$commit,tree:$tree},observation_sha256:$observation}
  ' > "$temporary" || return $?
  orchard_source_lifecycle_install_json "$temporary" "$ORCHARD_LIFECYCLE_RECEIPT"
}

orchard_source_lifecycle_commit() {
  local target=$1 observation=$2 generation=${3:-}
  [[ "$(sha256sum "$observation" | cut -d ' ' -f1)" == "$ORCHARD_LIFECYCLE_OBSERVATION_SHA" ]] || {
    orchard_source_lifecycle_fail "observation changed during transition"
    return $?
  }
  if [[ -z "$generation" && ( -e "$ORCHARD_LIFECYCLE_STATE" || -L "$ORCHARD_LIFECYCLE_STATE" ) ]]; then
    orchard_source_lifecycle_safe_file "$ORCHARD_LIFECYCLE_STATE" || return $?
    generation=$(( $(jq -r '.generation' "$ORCHARD_LIFECYCLE_STATE") + 1 ))
  fi
  generation=${generation:-1}
  local schema boot_id temporary="$ORCHARD_LIFECYCLE_STATE.new.$$"
  schema=$(jq -r '.database.schema_identity // empty' "$observation")
  if [[ -z "$schema" && -f "$ORCHARD_LIFECYCLE_STATE" ]]; then
    schema=$(jq -r '.schema_identity // empty' "$ORCHARD_LIFECYCLE_STATE") || return $?
  fi
  boot_id=$(jq -r '.reboot.boot_id' "$observation")
  jq -n --argjson generation "$generation" --arg phase "$target" \
    --arg operation_uuid "$ORCHARD_LIFECYCLE_OPERATION_UUID" --arg installation "$ORCHARD_LIFECYCLE_INSTALLATION_UUID" \
    --arg commit "$ORCHARD_LIFECYCLE_COMMIT" --arg tree "$ORCHARD_LIFECYCLE_TREE" --arg schema "$schema" --arg boot "$boot_id" '
    {schema_version:1,generation:$generation,phase:$phase,last_operation_uuid:$operation_uuid,
      installation_uuid:$installation,source:{commit:$commit,tree:$tree},
      schema_identity:(if $schema == "" then null else $schema end),boot_id:$boot,
      serving:false,schedulable:false,worker_capacity_published:false}
  ' > "$temporary" || return $?
  orchard_source_lifecycle_install_json "$temporary" "$ORCHARD_LIFECYCLE_STATE"
}

orchard_source_lifecycle_finish_receipt() {
  local target=$1 temporary="$ORCHARD_LIFECYCLE_RECEIPT.new.$$"
  jq --arg target "$target" '.generation = 2 | .phase = $target | .terminal = true' \
    "$ORCHARD_LIFECYCLE_RECEIPT" > "$temporary" || return $?
  orchard_source_lifecycle_install_json "$temporary" "$ORCHARD_LIFECYCLE_RECEIPT"
}

orchard_source_lifecycle_recover() {
  local operation_uuid=$1 observation=$2 receipt target operation prior observed_sha
  orchard_source_lifecycle_uuid "$operation_uuid" || return $?
  receipt="$ORCHARD_LIFECYCLE_RECEIPTS/$operation_uuid.json"
  orchard_source_lifecycle_safe_file "$receipt" || return $?
  jq -e --arg uuid "$ORCHARD_LIFECYCLE_INSTALLATION_UUID" --arg commit "$ORCHARD_LIFECYCLE_COMMIT" --arg tree "$ORCHARD_LIFECYCLE_TREE" '
    .installation_uuid == $uuid and .source == {commit:$commit,tree:$tree} and .terminal == false and .phase == "intent_recorded"
  ' "$receipt" >/dev/null || {
    orchard_source_lifecycle_fail "recovery receipt is terminal, foreign, or ambiguous"
    return $?
  }
  target=$(jq -r '.target_phase' "$receipt")
  operation=$(jq -r '.operation' "$receipt")
  prior=$(jq -r '.prior_phase' "$receipt")
  observed_sha=$(sha256sum "$observation" | cut -d ' ' -f1) || return $?
  [[ "$observed_sha" == "$ORCHARD_LIFECYCLE_OBSERVATION_SHA" ]] || {
    orchard_source_lifecycle_fail "observation changed after validation"
    return $?
  }
  if [[ "$observed_sha" == "$(jq -r '.observation_sha256' "$receipt")" ]] &&
    [[ -f "$ORCHARD_LIFECYCLE_STATE" ]] && jq -e --arg operation "$operation_uuid" --arg target "$target" \
    '.last_operation_uuid == $operation and .phase == $target' "$ORCHARD_LIFECYCLE_STATE" >/dev/null; then
    ORCHARD_LIFECYCLE_OPERATION_UUID=$operation_uuid
    ORCHARD_LIFECYCLE_RECEIPT=$receipt
    orchard_source_lifecycle_finish_receipt "$target" || return $?
    printf '%s\n' "$target"
    return 0
  fi
  if [[ "$observed_sha" == "$(jq -r '.observation_sha256' "$receipt")" ]] &&
    [[ "$target" == "$(orchard_source_lifecycle_target "$operation" "$prior" "$observation")" ]]; then
    ORCHARD_LIFECYCLE_OPERATION_UUID=$operation_uuid
    ORCHARD_LIFECYCLE_RECEIPT=$receipt
    orchard_source_lifecycle_commit "$target" "$observation" || return $?
    orchard_source_lifecycle_finish_receipt "$target" || return $?
    printf '%s\n' "$target"
    return 0
  fi
  ORCHARD_LIFECYCLE_OPERATION_UUID=$operation_uuid
  ORCHARD_LIFECYCLE_RECEIPT=$receipt
  orchard_source_lifecycle_commit recovery_required "$observation" "$(jq -r '.sequence' "$receipt")" || return $?
  local temporary="$receipt.new.$$"
  jq '.target_phase = "recovery_required"' "$receipt" > "$temporary" || return $?
  orchard_source_lifecycle_install_json "$temporary" "$receipt" || return $?
  orchard_source_lifecycle_finish_receipt recovery_required || return $?
  orchard_source_lifecycle_fail "interrupted operation cannot be exactly resumed; recovery is required" 75
}

orchard_source_lifecycle_diagnose() {
  local observation=$1 classification status=0 receipt_digest state_digest
  classification=$(orchard_source_lifecycle_classify "$observation") || status=$?
  if [[ -d "$ORCHARD_LIFECYCLE_RECEIPTS" ]] && find "$ORCHARD_LIFECYCLE_RECEIPTS" -type f -name '*.json' -print -quit | grep -q .; then
    receipt_digest=$(find "$ORCHARD_LIFECYCLE_RECEIPTS" -type f -name '*.json' -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d ' ' -f1)
  else
    receipt_digest=$(printf '' | sha256sum | cut -d ' ' -f1)
  fi
  if [[ -f "$ORCHARD_LIFECYCLE_STATE" ]]; then
    state_digest=$(sha256sum "$ORCHARD_LIFECYCLE_STATE" | cut -d ' ' -f1)
  else
    state_digest=null
  fi
  jq -n --arg classification "$classification" --arg uuid "$ORCHARD_LIFECYCLE_INSTALLATION_UUID" \
    --arg version "$ORCHARD_LIFECYCLE_VERSION" --arg commit "$ORCHARD_LIFECYCLE_COMMIT" --arg tree "$ORCHARD_LIFECYCLE_TREE" \
    --arg receipts "$receipt_digest" --arg state "$state_digest" \
    --arg database "$(jq -r '.database.classification' "$observation")" \
    --arg controller "$(jq -r '.controller.state' "$observation")" --arg node "$(jq -r '.node.state' "$observation")" \
    --arg worker "$(jq -r '.worker.classification' "$observation")" '
    {schema_version:1,profile:"ubuntu_24_04_x86_64_single_host",support_status:"unqualified",
      installation_uuid:$uuid,product_version:$version,source:{commit:$commit,tree:$tree},
      lifecycle:{classification:$classification,state_sha256:(if $state == "null" then null else $state end),receipts_sha256:$receipts},
      components:{database:$database,controller:$controller,node:$node,worker:$worker},
      readiness:{serving:false,schedulable:false,worker_capacity_published:false},
      redaction:{policy:"allowlist_only",excluded:["credentials","private_keys","authorization_roots","peer_grants","dsn","environment","logs","request_content","model_content"]}}
  '
  return "$status"
}

orchard_source_lifecycle_install_json() {
  local temporary=$1 destination=$2
  jq -e . "$temporary" >/dev/null || return $?
  chmod 600 "$temporary" || return $?
  sync -f "$temporary" || return $?
  mv "$temporary" "$destination" || return $?
  sync -f "$(dirname "$destination")"
}

orchard_source_lifecycle_safe_file() {
  local path=$1
  orchard_source_lifecycle_safe_components "$path" || return $?
  [[ -f "$path" && ! -L "$path" && $(stat -Lc %h "$path") == 1 ]] || {
    orchard_source_lifecycle_fail "required file is missing or unsafe: $path"
    return $?
  }
  local mode owner
  mode=$(stat -Lc %a "$path") || return $?
  owner=$(stat -Lc %U "$path") || return $?
  [[ $((8#$mode & 0022)) -eq 0 ]] || {
    orchard_source_lifecycle_fail "required file is group/world writable: $path"
    return $?
  }
  if [[ -z "$ORCHARD_LIFECYCLE_ROOT" ]]; then
    [[ "$owner" == root ]] || {
      orchard_source_lifecycle_fail "required file is not root-owned: $path"
      return $?
    }
  fi
}

orchard_source_lifecycle_safe_directory() {
  local path=$1
  orchard_source_lifecycle_safe_components "$path" || return $?
  [[ -d "$path" && ! -L "$path" && $(stat -Lc %h "$path") -ge 2 ]] || {
    orchard_source_lifecycle_fail "required directory is missing or unsafe: $path"
    return $?
  }
  local mode owner
  mode=$(stat -Lc %a "$path") || return $?
  owner=$(stat -Lc %U "$path") || return $?
  [[ $((8#$mode & 0022)) -eq 0 ]] || {
    orchard_source_lifecycle_fail "required directory is group/world writable: $path"
    return $?
  }
  if [[ -z "$ORCHARD_LIFECYCLE_ROOT" ]]; then
    [[ "$owner" == root ]] || {
      orchard_source_lifecycle_fail "required directory is not root-owned: $path"
      return $?
    }
  fi
}

orchard_source_lifecycle_safe_components() {
  local path=$1 current="" component enforce=0 expected_owner owner mode
  if [[ -n "$ORCHARD_LIFECYCLE_ROOT" ]]; then
    expected_owner=$(id -un)
  else
    expected_owner=root
    enforce=1
  fi
  IFS=/ read -r -a components <<< "$path"
  for component in "${components[@]}"; do
    [[ -n "$component" ]] || continue
    current="$current/$component"
    if [[ -n "$ORCHARD_LIFECYCLE_ROOT" && "$current" == "$ORCHARD_LIFECYCLE_ROOT" ]]; then
      enforce=1
    fi
    [[ ! -L "$current" ]] || {
      orchard_source_lifecycle_fail "refusing symlink path component $current"
      return $?
    }
    if (( enforce == 1 )) && [[ -e "$current" ]]; then
      owner=$(stat -Lc %U "$current") || return $?
      mode=$(stat -Lc %a "$current") || return $?
      [[ "$owner" == "$expected_owner" && $((8#$mode & 0022)) -eq 0 ]] || {
        orchard_source_lifecycle_fail "unsafe ancestor owner or writable mode on $current"
        return $?
      }
    fi
  done
}

orchard_source_lifecycle_uuid() {
  [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || {
    orchard_source_lifecycle_fail "operation UUID is invalid" 64
    return $?
  }
}

orchard_source_lifecycle_test_stop() {
  if [[ -n "$ORCHARD_LIFECYCLE_ROOT" && ${ORCHARD_SOURCE_DEV_LIFECYCLE_TEST_STOP:-} == "$1" ]]; then
    orchard_source_lifecycle_fail "injected interruption at $1" 99
    return $?
  fi
}
