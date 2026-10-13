#!/usr/bin/env bash

orchard_source_postgresql_fail() {
  printf 'orchard-source-postgresql: %s\n' "$1" >&2
  return "${2:-1}"
}

orchard_source_postgresql_main() {
  local command=${1:-}
  case "$command" in
    classify|diagnose|initialize|start|readiness|migrate|stop|restart|recover|backup|restore|upgrade-prepare|rollback-check|retire) ;;
    *)
      orchard_source_postgresql_fail \
        "usage: bin/orchard-source-postgresql classify|diagnose|initialize|start|readiness|migrate|stop|restart|recover|backup|restore|upgrade-prepare|rollback-check|retire" 64
      return $?
      ;;
  esac

  ORCHARD_PG_ROOT=${ORCHARD_SOURCE_DEV_ROOT:-}
  ORCHARD_PG_PREFIX=${ORCHARD_PG_ROOT%/}
  ORCHARD_PG_SOURCE=${ORCHARD_SOURCE_DEV_SOURCE:-${ORCHARD_PG_PREFIX}/opt/orchard/source}
  ORCHARD_PG_INSTALL_STATE="${ORCHARD_PG_PREFIX}/var/lib/orchard/install"
  ORCHARD_PG_MANIFEST="$ORCHARD_PG_INSTALL_STATE/manifest.json"
  ORCHARD_PG_LOCK="$ORCHARD_PG_INSTALL_STATE/lifecycle.lock"
  ORCHARD_PG_RECEIPTS="$ORCHARD_PG_INSTALL_STATE/receipts/postgresql"
  ORCHARD_PG_DATA="${ORCHARD_PG_PREFIX}/var/lib/postgresql/16/orchard"
  ORCHARD_PG_CONFIG="${ORCHARD_PG_PREFIX}/etc/orchard/postgresql"
  ORCHARD_PG_RUNTIME="${ORCHARD_PG_PREFIX}/run/postgresql"
  ORCHARD_PG_BACKUPS="${ORCHARD_PG_PREFIX}/var/backups/orchard"
  ORCHARD_PG_TEMPLATE="$ORCHARD_PG_SOURCE/rel/linux/source-dev/postgresql"
  ORCHARD_PG_DEPENDENCIES="$ORCHARD_PG_TEMPLATE/dependencies.json"
  ORCHARD_PG_CLOSURE="$ORCHARD_PG_SOURCE/packaging/linux/appliance/postgresql-16-closure.json"
  ORCHARD_PG_PROBES=${ORCHARD_SOURCE_DEV_PG_PROBE_DIR:-}

  orchard_source_postgresql_validate_invocation || return $?
  orchard_source_postgresql_validate_installation || return $?
  orchard_source_postgresql_validate_dependencies || return $?

  case "$command" in
    classify) orchard_source_postgresql_classify ;;
    diagnose) orchard_source_postgresql_diagnose ;;
    readiness) orchard_source_postgresql_readiness ;;
    rollback-check) orchard_source_postgresql_rollback_check "${2:-}" ;;
    *)
      orchard_source_postgresql_require_mutation_authority || return $?
      orchard_source_postgresql_with_lock "$command" "${2:-}"
      ;;
  esac
}

orchard_source_postgresql_validate_invocation() {
  local required
  for required in jq sha256sum flock stat install sync find df xargs; do
    command -v "$required" >/dev/null 2>&1 || {
      orchard_source_postgresql_fail "$required is required"
      return $?
    }
  done

  if [[ -n "$ORCHARD_PG_ROOT" ]]; then
    [[ "$ORCHARD_PG_ROOT" == /* && ${ORCHARD_SOURCE_DEV_TESTING:-0} == 1 ]] || {
      orchard_source_postgresql_fail "relocated roots require an absolute root and ORCHARD_SOURCE_DEV_TESTING=1"
      return $?
    }
    if [[ -n "$ORCHARD_PG_PROBES" && "$ORCHARD_PG_PROBES" != "$ORCHARD_PG_ROOT"/* ]]; then
      orchard_source_postgresql_fail "test probe directory must be inside the relocated root"
      return $?
    fi
  else
    [[ ${EUID:-$(id -u)} -eq 0 ]] || {
      orchard_source_postgresql_fail "canonical database lifecycle must run as root"
      return $?
    }
    [[ -z "$ORCHARD_PG_PROBES" ]] || {
      orchard_source_postgresql_fail "synthetic database probes are forbidden for a real host"
      return $?
    }
  fi
}

orchard_source_postgresql_validate_installation() {
  orchard_source_postgresql_safe_file "$ORCHARD_PG_MANIFEST" || return $?
  orchard_source_postgresql_safe_file "$ORCHARD_PG_LOCK" || return $?
  ORCHARD_PG_INSTALLATION_UUID=$(jq -r '.installation_uuid' "$ORCHARD_PG_MANIFEST")
  ORCHARD_PG_COMMIT=$(jq -r '.source.commit' "$ORCHARD_PG_MANIFEST")
  ORCHARD_PG_TREE=$(jq -r '.source.tree' "$ORCHARD_PG_MANIFEST")
  ORCHARD_PG_VERSION=$(jq -r '.product_version' "$ORCHARD_PG_MANIFEST")
  local dependencies_digest closure_digest current_commit current_tree current_status
  dependencies_digest=$(sha256sum "$ORCHARD_PG_DEPENDENCIES" | cut -d ' ' -f1) || return $?
  closure_digest=$(sha256sum "$ORCHARD_PG_CLOSURE" | cut -d ' ' -f1) || return $?
  jq -e --arg uuid "$ORCHARD_PG_INSTALLATION_UUID" --arg digest "$dependencies_digest" --arg closure "$closure_digest" '
    .schema_version == 1 and
    .profile == "ubuntu_24_04_x86_64_single_host" and
    .canonical_source == "/opt/orchard/source" and
    .activation == "disabled" and
    .support_status == "unqualified" and
    (.installation_uuid == $uuid) and
    ($uuid | test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")) and
    .source.clean == true and
    .source.generated_output_drift == false and
    .postgresql == {
      major: 16,
      dependencies_path: "rel/linux/source-dev/postgresql/dependencies.json",
      dependencies_sha256: $digest,
      closure_path: "packaging/linux/appliance/postgresql-16-closure.json",
      closure_sha256: $closure,
      activation: "disabled"
    }
  ' "$ORCHARD_PG_MANIFEST" >/dev/null || {
    orchard_source_postgresql_fail "prepared installation manifest does not authorize this database closure"
    return $?
  }
  current_commit=$(git -C "$ORCHARD_PG_SOURCE" rev-parse --verify HEAD^{commit}) || return $?
  current_tree=$(git -C "$ORCHARD_PG_SOURCE" rev-parse --verify HEAD^{tree}) || return $?
  current_status=$(git -C "$ORCHARD_PG_SOURCE" status --porcelain=v1 --untracked-files=all) || return $?
  [[ "$current_commit" == "$ORCHARD_PG_COMMIT" && "$current_tree" == "$ORCHARD_PG_TREE" && -z "$current_status" ]] || {
    orchard_source_postgresql_fail "source checkout no longer matches the clean prepared manifest"
    return $?
  }
}

orchard_source_postgresql_validate_dependencies() {
  jq -e '
    .schema_version == 1 and
    .profile == "ubuntu_24_04_x86_64_single_host" and
    .architecture == "amd64" and
    .postgresql.major == 16 and
    .postgresql.closure_path == "packaging/linux/appliance/postgresql-16-closure.json" and
    .postgresql.install_policy == "source_lifecycle_owned_no_automatic_cluster" and
    .postgresql.socket == "/run/postgresql/.s.PGSQL.5432" and
    .postgresql.data_directory == "/var/lib/postgresql/16/orchard" and
    (.postgresql.packages | length) == 4
  ' "$ORCHARD_PG_DEPENDENCIES" >/dev/null || {
    orchard_source_postgresql_fail "PostgreSQL dependency contract is invalid"
    return $?
  }
  jq -e '
    .schema_version == 1 and .profile == "ubuntu_24_04_x86_64_single_host" and
    .architecture == "amd64" and (.packages | length) >= 80 and
    ([.packages[].name] | unique | length) == (.packages | length) and
    ([.packages[] | select(.name == "postgresql-16" and .version == "16.15-0ubuntu0.24.04.1")] | length) == 1
  ' "$ORCHARD_PG_CLOSURE" >/dev/null || {
    orchard_source_postgresql_fail "exact PostgreSQL dependency closure is invalid"
    return $?
  }
  local package expected actual
  while IFS=$'\t' read -r package expected; do
    if [[ -n "$ORCHARD_PG_ROOT" ]]; then
      actual=$(awk -F '\t' -v package="$package" '$1 == package {print $2}' "$ORCHARD_PG_PROBES/packages.tsv" 2>/dev/null || true)
    else
      actual=$(dpkg-query -W -f='${db:Status-Abbrev}\t${Version}' "$package" 2>/dev/null || true)
      [[ "$actual" == $'ii \t'* ]] && actual=${actual#*$'\t'}
    fi
    [[ "$actual" == "$expected" ]] || {
      orchard_source_postgresql_fail "$package has unsupported or absent version ${actual:-missing}; expected $expected"
      return $?
    }
  done < <(jq -r '.packages[] | [.name, .version] | @tsv' "$ORCHARD_PG_CLOSURE")
}

orchard_source_postgresql_require_mutation_authority() {
  [[ ${ORCHARD_SOURCE_DEV_DATABASE_MUTATION_AUTHORIZED:-} == "$ORCHARD_PG_INSTALLATION_UUID" ]] || {
    orchard_source_postgresql_fail "database mutation requires the exact installation UUID authorization" 77
    return $?
  }
}

orchard_source_postgresql_with_lock() {
  local command=$1 argument=${2:-}
  exec 9<>"$ORCHARD_PG_LOCK"
  flock -n 9 || {
    orchard_source_postgresql_fail "lifecycle lock is already held" 75
    return $?
  }
  orchard_source_postgresql_detect_conflicts "$command" || return $?
  case "$command" in
    initialize) orchard_source_postgresql_initialize ;;
    start) orchard_source_postgresql_start ;;
    migrate) orchard_source_postgresql_migrate ;;
    stop) orchard_source_postgresql_stop ;;
    restart) orchard_source_postgresql_restart ;;
    recover) orchard_source_postgresql_recover "$argument" ;;
    backup) orchard_source_postgresql_backup ;;
    restore) orchard_source_postgresql_restore "$argument" ;;
    upgrade-prepare) orchard_source_postgresql_upgrade_prepare "$argument" ;;
    retire) orchard_source_postgresql_retire ;;
  esac
}

orchard_source_postgresql_safe_components() {
  local path=$1 current="" component
  IFS=/ read -r -a components <<< "$path"
  for component in "${components[@]}"; do
    [[ -n "$component" ]] || continue
    current="$current/$component"
    [[ ! -L "$current" ]] || {
      orchard_source_postgresql_fail "refusing symlink path component $current"
      return $?
    }
  done
}

orchard_source_postgresql_safe_file() {
  local path=$1 mode owner expected_owner
  orchard_source_postgresql_safe_components "$path" || return $?
  [[ -f "$path" && ! -L "$path" && $(stat -Lc %h "$path") == 1 ]] || {
    orchard_source_postgresql_fail "missing safe regular file $path"
    return $?
  }
  mode=$(stat -Lc %a "$path") || return $?
  owner=$(stat -Lc %U "$path") || return $?
  if [[ -n "$ORCHARD_PG_ROOT" ]]; then expected_owner=$(id -un); else expected_owner=root; fi
  [[ "$owner" == "$expected_owner" && $((8#$mode & 0022)) -eq 0 ]] || {
    orchard_source_postgresql_fail "$path has unsafe owner or group/other writable mode"
    return $?
  }
}

orchard_source_postgresql_detect_conflicts() {
  local command=$1 socket="${ORCHARD_PG_RUNTIME}/.s.PGSQL.5432"
  orchard_source_postgresql_safe_components "$ORCHARD_PG_DATA" || return $?
  orchard_source_postgresql_safe_components "$ORCHARD_PG_CONFIG" || return $?
  [[ "$command" != recover ]] || return 0
  if [[ -e "$socket" || -L "$socket" ]]; then
    if ! orchard_source_postgresql_expected_running; then
      orchard_source_postgresql_fail "foreign or ambiguous PostgreSQL socket owner"
      return $?
    fi
  fi
  if [[ -f "$ORCHARD_PG_DATA/PG_VERSION" ]]; then
    [[ $(<"$ORCHARD_PG_DATA/PG_VERSION") == 16 ]] || {
      orchard_source_postgresql_fail "foreign PostgreSQL major version in canonical data root"
      return $?
    }
    orchard_source_postgresql_verify_cluster_identity || return $?
  elif [[ -e "$ORCHARD_PG_DATA" && -n $(find "$ORCHARD_PG_DATA" -mindepth 1 -print -quit 2>/dev/null) ]]; then
    orchard_source_postgresql_fail "non-empty unowned PostgreSQL data root"
    return $?
  fi
  if [[ "$command" != stop && "$command" != retire && "$command" != recover ]] && orchard_source_postgresql_has_nonterminal_receipt; then
    orchard_source_postgresql_fail "nonterminal database lifecycle receipt requires explicit recovery" 75
    return $?
  fi
}

orchard_source_postgresql_expected_running() {
  if [[ -n "$ORCHARD_PG_ROOT" ]]; then
    [[ -f "$ORCHARD_PG_PROBES/running" && $(<"$ORCHARD_PG_PROBES/running") == "$ORCHARD_PG_INSTALLATION_UUID" ]]
  else
    [[ -f "$ORCHARD_PG_DATA/postmaster.pid" ]] || return 1
    local pid
    pid=$(head -n 1 "$ORCHARD_PG_DATA/postmaster.pid")
    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/cmdline" ]] || return 1
    tr '\0' ' ' < "/proc/$pid/cmdline" | grep -F -- "-D /var/lib/postgresql/16/orchard" >/dev/null
  fi
}

orchard_source_postgresql_verify_cluster_identity() {
  local identity="$ORCHARD_PG_DATA/orchard-installation.json"
  orchard_source_postgresql_safe_file "$identity" || return $?
  jq -e --arg uuid "$ORCHARD_PG_INSTALLATION_UUID" '
    .schema_version == 1 and .installation_uuid == $uuid and .postgresql_major == 16
  ' "$identity" >/dev/null || {
    orchard_source_postgresql_fail "PostgreSQL cluster identity is foreign or ambiguous"
    return $?
  }
}

orchard_source_postgresql_has_nonterminal_receipt() {
  [[ -d "$ORCHARD_PG_RECEIPTS" ]] || return 1
  local receipt
  while IFS= read -r receipt; do
    jq -e '.terminal == true' "$receipt" >/dev/null 2>&1 || return 0
  done < <(find "$ORCHARD_PG_RECEIPTS" -maxdepth 1 -type f -name '*.json' -print | LC_ALL=C sort)
  return 1
}

orchard_source_postgresql_classify() {
  if orchard_source_postgresql_has_nonterminal_receipt; then
    printf 'recovery_required\n'
    return 75
  fi
  if [[ ! -e "$ORCHARD_PG_DATA" ]] || [[ -z $(find "$ORCHARD_PG_DATA" -mindepth 1 -print -quit 2>/dev/null) ]]; then
    printf 'source_prepared\n'
    return 0
  fi
  orchard_source_postgresql_verify_cluster_identity || return $?
  if orchard_source_postgresql_expected_running; then
    if orchard_source_postgresql_readiness >/dev/null 2>&1; then
      printf 'database_ready\n'
    else
      printf 'recovery_required\n'
      return 75
    fi
  else
    printf 'initialized_stopped\n'
  fi
}

orchard_source_postgresql_diagnose() {
  local classification status=0
  classification=$(orchard_source_postgresql_classify) || status=$?
  jq -n --arg classification "$classification" --arg uuid "$ORCHARD_PG_INSTALLATION_UUID" \
    --arg commit "$ORCHARD_PG_COMMIT" --arg tree "$ORCHARD_PG_TREE" \
    --argjson ready "$(orchard_source_postgresql_readiness >/dev/null 2>&1 && printf true || printf false)" \
    '{schema_version:1, profile:"ubuntu_24_04_x86_64_single_host", installation_uuid:$uuid,
      source:{commit:$commit,tree:$tree}, database:{classification:$classification,ready:$ready},
      redaction:"no credentials, keys, grants, query text, request content, or model content"}'
  return "$status"
}

orchard_source_postgresql_initialize() {
  [[ ! -e "$ORCHARD_PG_DATA" ]] || [[ -z $(find "$ORCHARD_PG_DATA" -mindepth 1 -print -quit 2>/dev/null) ]] || {
    orchard_source_postgresql_fail "initialization requires an empty canonical data root"
    return $?
  }
  orchard_source_postgresql_require_space || return $?
  orchard_source_postgresql_begin_receipt initialize || return $?
  orchard_source_postgresql_install_roots_and_config || return $?
  orchard_source_postgresql_advance_receipt roots_prepared 2 false || return $?
  orchard_source_postgresql_run_as postgres initdb -D "$ORCHARD_PG_DATA" --encoding=UTF8 --locale=C.UTF-8 --auth-local=peer --auth-host=reject || return $?
  orchard_source_postgresql_write_cluster_identity || return $?
  orchard_source_postgresql_advance_receipt cluster_initialized 3 false || return $?
  orchard_source_postgresql_run_as postgres pg_ctl -D "$ORCHARD_PG_DATA" -o "-c config_file=$ORCHARD_PG_CONFIG/postgresql.conf" -w start || return $?
  orchard_source_postgresql_run_as postgres psql --host="$ORCHARD_PG_RUNTIME" --dbname=postgres --file="$ORCHARD_PG_TEMPLATE/bootstrap.sql" || {
    orchard_source_postgresql_run_as postgres pg_ctl -D "$ORCHARD_PG_DATA" -m fast -w stop || true
    return 1
  }
  orchard_source_postgresql_run_as postgres pg_ctl -D "$ORCHARD_PG_DATA" -m fast -w stop || return $?
  orchard_source_postgresql_advance_receipt initialized_stopped 4 true || return $?
}

orchard_source_postgresql_install_roots_and_config() {
  orchard_source_postgresql_install_directory "$ORCHARD_PG_DATA" postgres postgres 700 || return $?
  orchard_source_postgresql_install_directory "$ORCHARD_PG_CONFIG" root postgres 750 || return $?
  orchard_source_postgresql_install_directory "$ORCHARD_PG_RUNTIME" root orchard-postgresql 770 || return $?
  orchard_source_postgresql_install_directory "$ORCHARD_PG_BACKUPS" root root 700 || return $?
  orchard_source_postgresql_install_directory "${ORCHARD_PG_PREFIX}/var/log/orchard/postgresql" postgres postgres 750 || return $?
  local file mode
  for file in postgresql.conf pg_hba.conf pg_ident.conf; do
    mode=640
    orchard_source_postgresql_install_file "$ORCHARD_PG_TEMPLATE/$file" "$ORCHARD_PG_CONFIG/$file" "$mode" root postgres || return $?
  done
  orchard_source_postgresql_write_lifecycle_environment || return $?
}

orchard_source_postgresql_write_lifecycle_environment() {
  local destination="$ORCHARD_PG_CONFIG/lifecycle.env" temporary="$ORCHARD_PG_CONFIG/lifecycle.env.new.$$"
  printf 'ORCHARD_SOURCE_DEV_DATABASE_MUTATION_AUTHORIZED=%s\n' "$ORCHARD_PG_INSTALLATION_UUID" > "$temporary" || return $?
  orchard_source_postgresql_identity root root
  chown "$ORCHARD_PG_OWNER:$ORCHARD_PG_GROUP" "$temporary" && chmod 600 "$temporary" && sync -f "$temporary" || return $?
  if [[ -e "$destination" ]]; then
    orchard_source_postgresql_safe_file "$destination" || return $?
    cmp -s "$temporary" "$destination" || {
      rm -f "$temporary"
      orchard_source_postgresql_fail "lifecycle environment claims another installation"
      return $?
    }
    rm -f "$temporary"
  else
    mv "$temporary" "$destination" && sync -f "$ORCHARD_PG_CONFIG"
  fi
}

orchard_source_postgresql_install_directory() {
  local path=$1 owner=$2 group=$3 mode=$4
  orchard_source_postgresql_identity "$owner" "$group"
  orchard_source_postgresql_safe_components "$path" || return $?
  if [[ -d "$path" ]]; then
    [[ $(stat -Lc '%U:%G:%a' "$path") == "$ORCHARD_PG_OWNER:$ORCHARD_PG_GROUP:$mode" ]] || {
      orchard_source_postgresql_fail "$path has incompatible custody or mode"
      return $?
    }
  else
    install -d -o "$ORCHARD_PG_OWNER" -g "$ORCHARD_PG_GROUP" -m "$mode" "$path" || return $?
  fi
}

orchard_source_postgresql_install_file() {
  local source=$1 destination=$2 mode=$3 owner=$4 group=$5 temporary="$2.new.$$"
  orchard_source_postgresql_identity "$owner" "$group"
  if [[ -e "$destination" ]]; then
    orchard_source_postgresql_safe_file "$destination" || return $?
    cmp -s "$source" "$destination" || {
      orchard_source_postgresql_fail "$destination has foreign or ambiguous content"
      return $?
    }
    return 0
  fi
  install -o "$ORCHARD_PG_OWNER" -g "$ORCHARD_PG_GROUP" -m "$mode" "$source" "$temporary" || return $?
  sync -f "$temporary" && mv "$temporary" "$destination" && sync -f "$(dirname "$destination")"
}

orchard_source_postgresql_identity() {
  if [[ -n "$ORCHARD_PG_ROOT" ]]; then
    ORCHARD_PG_OWNER=$(id -un)
    ORCHARD_PG_GROUP=$(id -gn)
  else
    ORCHARD_PG_OWNER=$1
    ORCHARD_PG_GROUP=$2
  fi
}

orchard_source_postgresql_write_cluster_identity() {
  local destination="$ORCHARD_PG_DATA/orchard-installation.json" temporary
  temporary="$destination.new.$$"
  jq -n --arg uuid "$ORCHARD_PG_INSTALLATION_UUID" --arg commit "$ORCHARD_PG_COMMIT" \
    '{schema_version:1,installation_uuid:$uuid,postgresql_major:16,initialized_by_commit:$commit}' > "$temporary" || return $?
  chmod 600 "$temporary" && sync -f "$temporary" && mv "$temporary" "$destination" && sync -f "$ORCHARD_PG_DATA"
}

orchard_source_postgresql_start() {
  orchard_source_postgresql_assert_restore_gate_clear || return $?
  orchard_source_postgresql_verify_cluster_identity || return $?
  orchard_source_postgresql_require_space || return $?
  if orchard_source_postgresql_expected_running; then
    orchard_source_postgresql_readiness
    return $?
  fi
  orchard_source_postgresql_begin_receipt start || return $?
  orchard_source_postgresql_run_as postgres pg_ctl -D "$ORCHARD_PG_DATA" -o "-c config_file=$ORCHARD_PG_CONFIG/postgresql.conf" -w start || return $?
  orchard_source_postgresql_readiness || return $?
  orchard_source_postgresql_advance_receipt database_ready 2 true
}

orchard_source_postgresql_readiness() {
  orchard_source_postgresql_expected_running || {
    orchard_source_postgresql_fail "expected PostgreSQL cluster is not running"
    return $?
  }
  orchard_source_postgresql_run_as postgres pg_isready --host="$ORCHARD_PG_RUNTIME" --port=5432 --dbname=orchard --timeout=5 >/dev/null || {
    orchard_source_postgresql_fail "PostgreSQL is unavailable"
    return $?
  }
  local recovery
  recovery=$(orchard_source_postgresql_run_as postgres psql --host="$ORCHARD_PG_RUNTIME" --dbname=orchard --tuples-only --no-align --command='SELECT pg_is_in_recovery()') || return $?
  [[ "$recovery" == f ]] || {
    orchard_source_postgresql_fail "PostgreSQL is in recovery"
    return $?
  }
  local transaction_probe
  transaction_probe=$(orchard_source_postgresql_run_as orchard-controller psql --host="$ORCHARD_PG_RUNTIME" \
    --username=orchard_controller --dbname=orchard --tuples-only --no-align --no-psqlrc \
    --command='BEGIN; CREATE TEMP TABLE orchard_readiness_probe(value integer) ON COMMIT DROP; INSERT INTO orchard_readiness_probe VALUES (1); SELECT count(*) FROM orchard_readiness_probe; ROLLBACK;') || {
      orchard_source_postgresql_fail "PostgreSQL bounded read/write readiness probe failed"
      return $?
    }
  grep -Fx 1 <<< "$transaction_probe" >/dev/null || {
    orchard_source_postgresql_fail "PostgreSQL bounded read/write readiness probe returned an invalid result"
    return $?
  }
  orchard_source_postgresql_require_space
}

orchard_source_postgresql_migrate() {
  orchard_source_postgresql_assert_restore_gate_clear || return $?
  orchard_source_postgresql_readiness || return $?
  orchard_source_postgresql_begin_receipt migrate || return $?
  orchard_source_postgresql_run_migrations || return $?
  orchard_source_postgresql_advance_receipt schema_current 2 true
  unset ORCHARD_PG_RECEIPT_EXTRA
}

orchard_source_postgresql_run_migrations() {
  (cd "$ORCHARD_PG_SOURCE" && \
    DATABASE_URL="ecto://orchard_migrator@/orchard?host=/run/postgresql&pool_size=1" PGOPTIONS='-c role=orchard_owner' \
      orchard_source_postgresql_run_as orchard-db-migrate mise exec -- mix run -e 'Orchard.Release.migrate()') || {
      orchard_source_postgresql_fail "exclusive migration failed or conflicted"
      return $?
    }
  local schema
  schema=$(orchard_source_postgresql_run_as orchard-db-migrate psql --host="$ORCHARD_PG_RUNTIME" --username=orchard_migrator \
    --dbname=orchard --tuples-only --no-align --command='SELECT COALESCE(max(version),0) FROM schema_migrations') || return $?
  [[ "$schema" =~ ^[0-9]+$ ]] || {
    orchard_source_postgresql_fail "migration did not establish a durable schema identity"
    return $?
  }
  ORCHARD_PG_RECEIPT_EXTRA=$(jq -cn --arg schema "$schema" '{schema_identity:$schema}')
}

orchard_source_postgresql_stop() {
  if ! orchard_source_postgresql_expected_running; then
    return 0
  fi
  orchard_source_postgresql_begin_receipt stop || return $?
  orchard_source_postgresql_run_as postgres pg_ctl -D "$ORCHARD_PG_DATA" -m fast -w stop || return $?
  orchard_source_postgresql_expected_running && {
    orchard_source_postgresql_fail "PostgreSQL survivor remains after stop"
    return $?
  }
  orchard_source_postgresql_advance_receipt initialized_stopped 2 true
}

orchard_source_postgresql_restart() {
  orchard_source_postgresql_assert_restore_gate_clear || return $?
  orchard_source_postgresql_verify_cluster_identity || return $?
  orchard_source_postgresql_require_space || return $?
  orchard_source_postgresql_expected_running || {
    orchard_source_postgresql_fail "restart requires the expected running PostgreSQL cluster"
    return $?
  }
  orchard_source_postgresql_begin_receipt restart || return $?
  orchard_source_postgresql_run_as postgres pg_ctl -D "$ORCHARD_PG_DATA" -m fast \
    -o "-c config_file=$ORCHARD_PG_CONFIG/postgresql.conf" -w restart || return $?
  orchard_source_postgresql_readiness || return $?
  orchard_source_postgresql_advance_receipt database_ready 2 true
}

orchard_source_postgresql_assert_restore_gate_clear() {
  local gate="$ORCHARD_PG_INSTALL_STATE/restore-recovery.json"
  [[ ! -e "$gate" && ! -L "$gate" ]] || {
    orchard_source_postgresql_fail "restored authority remains non-serving until explicit new-key and authorization recovery completes" 78
    return $?
  }
}

orchard_source_postgresql_recover() {
  local operation_uuid=$1 receipt="$ORCHARD_PG_RECEIPTS/$1.json" temporary operation phase generation extra recovery_phase
  [[ "$operation_uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || {
    orchard_source_postgresql_fail "recover requires an exact operation UUID" 64
    return $?
  }
  orchard_source_postgresql_safe_file "$receipt" || return $?
  jq -e --arg uuid "$ORCHARD_PG_INSTALLATION_UUID" --arg commit "$ORCHARD_PG_COMMIT" --arg tree "$ORCHARD_PG_TREE" '
    .installation_uuid == $uuid and .source.commit == $commit and .source.tree == $tree and .terminal == false
  ' "$receipt" >/dev/null || {
    orchard_source_postgresql_fail "recovery receipt is terminal, foreign, or ambiguous"
    return $?
  }
  operation=$(jq -r '.operation' "$receipt")
  phase=$(jq -r '.phase' "$receipt")
  generation=$(jq -r '.generation' "$receipt")
  [[ "$phase" == intent_recorded || "$phase" == roots_prepared || "$phase" == cluster_initialized || "$phase" == snapshot_created ]] || {
    orchard_source_postgresql_fail "recovery receipt phase is unsupported or ambiguous"
    return $?
  }
  extra=$(orchard_source_postgresql_reconcile_interruption "$operation" "$phase" "$operation_uuid") || return $?
  recovery_phase=$(jq -r '.result' <<< "$extra") || return $?
  temporary="$receipt.new.$$"
  jq --argjson generation "$((generation + 1))" --arg phase "$recovery_phase" --argjson extra "$extra" \
    '.generation = $generation | .phase = $phase | .terminal = true | .details = $extra' "$receipt" > "$temporary" || return $?
  chmod 600 "$temporary" && sync -f "$temporary" && mv "$temporary" "$receipt" && sync -f "$ORCHARD_PG_RECEIPTS"
}

orchard_source_postgresql_reconcile_interruption() {
  local operation=$1 phase=$2 operation_uuid=$3
  case "$operation:$phase" in
    initialize:intent_recorded|initialize:roots_prepared|initialize:cluster_initialized)
      orchard_source_postgresql_stop_expected_for_recovery || return $?
      orchard_source_postgresql_quarantine_partial_data "$operation_uuid" || return $?
      jq -cn '{exact_recovery:true,result:"source_prepared",partial_cluster_quarantined:true}'
      ;;
    start:intent_recorded|restart:intent_recorded)
      if orchard_source_postgresql_expected_running; then
        orchard_source_postgresql_readiness || return $?
      else
        orchard_source_postgresql_verify_cluster_identity || return $?
        orchard_source_postgresql_run_as postgres pg_ctl -D "$ORCHARD_PG_DATA" \
          -o "-c config_file=$ORCHARD_PG_CONFIG/postgresql.conf" -w start || return $?
        orchard_source_postgresql_readiness || return $?
      fi
      jq -cn '{exact_recovery:true,result:"database_ready"}'
      ;;
    stop:intent_recorded|retire:intent_recorded)
      orchard_source_postgresql_stop_expected_for_recovery || return $?
      jq -cn --arg operation "$operation" '{exact_recovery:true,result:(if $operation == "retire" then "retired_stopped" else "initialized_stopped" end)}'
      ;;
    migrate:intent_recorded)
      orchard_source_postgresql_readiness || return $?
      orchard_source_postgresql_run_migrations || return $?
      jq -cn --argjson migration "$ORCHARD_PG_RECEIPT_EXTRA" '{exact_recovery:true,result:"schema_current",migration:$migration}'
      unset ORCHARD_PG_RECEIPT_EXTRA
      ;;
    backup:intent_recorded|backup:snapshot_created)
      orchard_source_postgresql_consume_pending_writer_fence backup "$operation_uuid" || return $?
      orchard_source_postgresql_cleanup_validation "$operation_uuid" || return $?
      rm -rf "$ORCHARD_PG_BACKUPS/.staging-$operation_uuid" || return $?
      sync -f "$ORCHARD_PG_BACKUPS" || return $?
      jq -cn '{exact_recovery:true,result:"backup_not_published",new_writer_fence_required:true}'
      ;;
    restore:intent_recorded)
      orchard_source_postgresql_consume_pending_restore_fence "$operation_uuid" || return $?
      orchard_source_postgresql_stop_expected_for_recovery || return $?
      orchard_source_postgresql_quarantine_partial_data "$operation_uuid" || return $?
      orchard_source_postgresql_write_restore_gate "interrupted_restore_requires_fenced_retry" "$operation_uuid" || return $?
      jq -cn '{exact_recovery:true,result:"restore_not_published",new_restore_fence_required:true,serving:false}'
      ;;
    upgrade:intent_recorded)
      orchard_source_postgresql_consume_pending_writer_fence upgrade "$operation_uuid" || return $?
      ! orchard_source_postgresql_expected_running || {
        orchard_source_postgresql_fail "upgrade recovery requires PostgreSQL stopped"
        return $?
      }
      jq -cn '{exact_recovery:true,result:"initialized_stopped",new_writer_fence_required:true}'
      ;;
    *)
      orchard_source_postgresql_fail "recovery operation and phase are unsupported or ambiguous"
      return $?
      ;;
  esac
}

orchard_source_postgresql_consume_pending_writer_fence() {
  local operation=$1 operation_uuid=$2 fence="$ORCHARD_PG_INSTALL_STATE/fences/database-writers.json"
  [[ ! -e "$fence" && ! -L "$fence" ]] || {
    orchard_source_postgresql_verify_writer_fence "$operation" || return $?
    ORCHARD_PG_OPERATION_UUID=$operation_uuid
    orchard_source_postgresql_consume_fence database-writers "$ORCHARD_PG_FENCE_UUID" || return $?
  }
}

orchard_source_postgresql_consume_pending_restore_fence() {
  local operation_uuid=$1 fence="$ORCHARD_PG_INSTALL_STATE/fences/restore-source.json" backup_id
  [[ ! -e "$fence" && ! -L "$fence" ]] || {
    orchard_source_postgresql_safe_file "$fence" || return $?
    backup_id=$(jq -r '.backup_id // empty' "$fence")
    orchard_source_postgresql_verify_source_fence "$backup_id" || return $?
    ORCHARD_PG_OPERATION_UUID=$operation_uuid
    orchard_source_postgresql_consume_fence restore-source "$ORCHARD_PG_FENCE_UUID" || return $?
  }
}

orchard_source_postgresql_stop_expected_for_recovery() {
  if orchard_source_postgresql_expected_running; then
    orchard_source_postgresql_run_as postgres pg_ctl -D "$ORCHARD_PG_DATA" -m fast -w stop
  elif [[ -e "$ORCHARD_PG_RUNTIME/.s.PGSQL.5432" || -L "$ORCHARD_PG_RUNTIME/.s.PGSQL.5432" ]]; then
    orchard_source_postgresql_fail "recovery refuses a foreign or ambiguous PostgreSQL socket owner"
    return $?
  fi
}

orchard_source_postgresql_quarantine_partial_data() {
  local operation_uuid=$1 quarantine="$ORCHARD_PG_DATA.recovery-$1"
  if [[ -d "$ORCHARD_PG_DATA" && -n $(find "$ORCHARD_PG_DATA" -mindepth 1 -print -quit) ]]; then
    [[ ! -e "$quarantine" ]] || {
      orchard_source_postgresql_fail "exact recovery quarantine already exists"
      return $?
    }
    mv "$ORCHARD_PG_DATA" "$quarantine" || return $?
    sync -f "$(dirname "$ORCHARD_PG_DATA")" || return $?
  fi
}

orchard_source_postgresql_backup() {
  orchard_source_postgresql_readiness || return $?
  orchard_source_postgresql_verify_writer_fence backup || return $?
  local operation staging final metadata role_count
  metadata="$ORCHARD_PG_INSTALL_STATE/public-generation.json"
  orchard_source_postgresql_safe_public_metadata "$metadata" || return $?
  role_count=$(orchard_source_postgresql_run_as orchard-db-backup psql --host="$ORCHARD_PG_RUNTIME" --username=orchard_backup \
    --dbname=orchard --tuples-only --no-align \
    --command="SELECT count(*) FROM pg_roles WHERE rolname IN ('orchard_owner','orchard_controller','orchard_migrator','orchard_backup') AND rolsuper = false AND rolcreatedb = false AND rolcreaterole = false AND rolreplication = false AND rolbypassrls = false") || return $?
  [[ "$role_count" == 4 ]] || {
    orchard_source_postgresql_fail "database role custody is missing or over-privileged"
    return $?
  }
  orchard_source_postgresql_begin_receipt backup || return $?
  orchard_source_postgresql_consume_fence database-writers "$ORCHARD_PG_FENCE_UUID" || return $?
  operation=$ORCHARD_PG_OPERATION_UUID
  staging="$ORCHARD_PG_BACKUPS/.staging-$operation"
  final="$ORCHARD_PG_BACKUPS/$operation"
  [[ ! -e "$staging" && ! -e "$final" ]] || {
    orchard_source_postgresql_fail "backup operation path already exists"
    return $?
  }
  install -d -m 700 "$staging" || return $?
  orchard_source_postgresql_capture_authority "$ORCHARD_PG_RUNTIME" 5432 orchard-db-backup orchard_backup "$staging/database-authority.tsv" || return $?
  local authority_digest expected_authority
  authority_digest=$(sha256sum "$staging/database-authority.tsv" | cut -d ' ' -f1)
  expected_authority=$(jq -r '.database_authority_sha256 // empty' "$metadata")
  [[ "$authority_digest" == "$expected_authority" ]] || {
    orchard_source_postgresql_fail "database authority and local public-generation metadata are incoherent"
    return $?
  }
  orchard_source_postgresql_run_as orchard-db-backup pg_dump --host="$ORCHARD_PG_RUNTIME" --username=orchard_backup \
    --dbname=orchard --format=custom > "$staging/orchard.dump" || return $?
  cp "$ORCHARD_PG_TEMPLATE/roles.sql" "$staging/roles.sql" || return $?
  cp "$metadata" "$staging/public-generation.json" || return $?
  orchard_source_postgresql_write_backup_manifest "$staging" || return $?
  orchard_source_postgresql_advance_receipt snapshot_created 2 false || return $?
  orchard_source_postgresql_validate_backup "$staging" || return $?
  mv "$staging" "$final" && sync -f "$ORCHARD_PG_BACKUPS" || return $?
  ORCHARD_PG_RECEIPT_EXTRA=$(jq -cn --arg backup "$operation" '{backup_id:$backup,validation:"isolated_non_serving_restore"}')
  orchard_source_postgresql_advance_receipt backup_complete 3 true
  unset ORCHARD_PG_RECEIPT_EXTRA
}

orchard_source_postgresql_capture_authority() {
  local socket=$1 port=$2 identity=$3 database_role=$4 destination=$5 query
  query="COPY (
    SELECT 'controller', id::text, beam_authorization_root_id::text, status FROM controller_instances
    UNION ALL
    SELECT 'credential', node_id::text, generation::text, state FROM node_credential_generations
    UNION ALL
    SELECT 'peer_grant', node_id::text, generation::text, state::text FROM beam_peer_grants
    UNION ALL
    SELECT 'disconnect', node_id::text, id::text, state FROM beam_disconnect_obligations
    ORDER BY 1, 2, 3, 4
  ) TO STDOUT"
  orchard_source_postgresql_run_as "$identity" psql --host="$socket" --port="$port" --username="$database_role" \
    --dbname=orchard --no-psqlrc --command="$query" > "$destination"
}

orchard_source_postgresql_verify_writer_fence() {
  local operation=$1
  local fence="$ORCHARD_PG_INSTALL_STATE/fences/database-writers.json"
  orchard_source_postgresql_safe_file "$fence" >/dev/null 2>&1 || {
    orchard_source_postgresql_fail "complete database writer fence is absent or invalid"
    return $?
  }
  jq -e --arg uuid "$ORCHARD_PG_INSTALLATION_UUID" --arg operation "$operation" \
    --arg commit "$ORCHARD_PG_COMMIT" --arg tree "$ORCHARD_PG_TREE" '
    .schema_version == 1 and .installation_uuid == $uuid and .operation == $operation and
    .source == {commit:$commit,tree:$tree} and
    (.fence_uuid | test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")) and
    .ingress_closed == true and .controller_stopped == true and .node_cordoned == true and
    .node_drained == true and .node_stopped == true and .workers_stopped == true and
    .credential_writers_stopped == true and .governance_writers_stopped == true and
    .direct_database_writers_stopped == true
  ' "$fence" >/dev/null || {
    orchard_source_postgresql_fail "complete database writer fence is absent or invalid"
    return $?
  }
  ORCHARD_PG_FENCE_UUID=$(jq -r '.fence_uuid' "$fence")
  orchard_source_postgresql_assert_fence_unconsumed database-writers "$ORCHARD_PG_FENCE_UUID"
}

orchard_source_postgresql_assert_fence_unconsumed() {
  local name=$1 fence_uuid=$2
  if [[ -d "$ORCHARD_PG_RECEIPTS/fences" ]] &&
    find "$ORCHARD_PG_RECEIPTS/fences" -maxdepth 1 -type f -name "*-$name-$fence_uuid.json" -print -quit | grep -q .; then
    orchard_source_postgresql_fail "lifecycle fence was already consumed"
    return $?
  fi
}

orchard_source_postgresql_consume_fence() {
  local name=$1 fence_uuid=$2 source="$ORCHARD_PG_INSTALL_STATE/fences/$1.json" destination
  install -d -m 700 "$ORCHARD_PG_RECEIPTS/fences" || return $?
  destination="$ORCHARD_PG_RECEIPTS/fences/$ORCHARD_PG_OPERATION_UUID-$name-$fence_uuid.json"
  [[ ! -e "$destination" ]] || {
    orchard_source_postgresql_fail "lifecycle fence was already consumed"
    return $?
  }
  mv "$source" "$destination" && sync -f "$ORCHARD_PG_RECEIPTS/fences" && sync -f "$ORCHARD_PG_INSTALL_STATE/fences"
}

orchard_source_postgresql_safe_public_metadata() {
  local path=$1
  orchard_source_postgresql_safe_file "$path" >/dev/null 2>&1 || {
    orchard_source_postgresql_fail "public-generation metadata is absent, incoherent, or contains forbidden custody"
    return $?
  }
  jq -e --arg uuid "$ORCHARD_PG_INSTALLATION_UUID" '
    .schema_version == 1 and .installation_uuid == $uuid and
    (.database_authority_sha256 | test("^[0-9a-f]{64}$")) and
    (.private_keys == null) and (.authorization_roots == null) and (.peer_grants == null) and
    (.database_credentials == null)
  ' "$path" >/dev/null || {
    orchard_source_postgresql_fail "public-generation metadata is absent, incoherent, or contains forbidden custody"
    return $?
  }
}

orchard_source_postgresql_write_backup_manifest() {
  local staging=$1 manifest="$1/manifest.json" dump roles metadata authority schema source_manifest config receipts
  dump=$(sha256sum "$staging/orchard.dump" | cut -d ' ' -f1)
  roles=$(sha256sum "$staging/roles.sql" | cut -d ' ' -f1)
  metadata=$(sha256sum "$staging/public-generation.json" | cut -d ' ' -f1)
  authority=$(sha256sum "$staging/database-authority.tsv" | cut -d ' ' -f1)
  schema=$(orchard_source_postgresql_run_as orchard-db-backup psql --host="$ORCHARD_PG_RUNTIME" --username=orchard_backup \
    --dbname=orchard --tuples-only --no-align --command='SELECT COALESCE(max(version),0) FROM schema_migrations') || return $?
  source_manifest=$(sha256sum "$ORCHARD_PG_MANIFEST" | cut -d ' ' -f1)
  config=$(cat "$ORCHARD_PG_CONFIG/postgresql.conf" "$ORCHARD_PG_CONFIG/pg_hba.conf" "$ORCHARD_PG_CONFIG/pg_ident.conf" | sha256sum | cut -d ' ' -f1)
  receipts=$(find "$ORCHARD_PG_INSTALL_STATE/receipts" -type f -name '*.json' -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d ' ' -f1)
  jq -n --arg uuid "$ORCHARD_PG_INSTALLATION_UUID" --arg version "$ORCHARD_PG_VERSION" \
    --arg commit "$ORCHARD_PG_COMMIT" --arg tree "$ORCHARD_PG_TREE" --arg dump "$dump" \
    --arg roles "$roles" --arg metadata "$metadata" --arg authority "$authority" --arg schema "$schema" \
    --arg source_manifest "$source_manifest" --arg config "$config" --arg receipts "$receipts" \
    --slurpfile installation "$ORCHARD_PG_MANIFEST" \
    '{schema_version:1,installation_uuid:$uuid,product_version:$version,source:{commit:$commit,tree:$tree},
      private_material_included:false,reusable_database_credentials_included:false,
      checkpoint:{schema_identity:$schema,source_manifest_sha256:$source_manifest,configuration_sha256:$config,
        lifecycle_receipts_sha256:$receipts,dependency_locks:$installation[0].dependency_locks,
        toolchain:$installation[0].toolchain,postgresql_closure:$installation[0].postgresql,
        authorization_contract:$installation[0].compatibility.runtime_endpoint_contract},
      files:{"orchard.dump":$dump,"roles.sql":$roles,"public-generation.json":$metadata,"database-authority.tsv":$authority},
      retention:"preserve_no_automatic_prune",
      validation:{state:"pending",mode:"isolated_non_serving_restore"}}' > "$manifest" || return $?
  chmod 600 "$manifest" && sync -f "$manifest" && sync -f "$staging"
}

orchard_source_postgresql_validate_backup() {
  local staging=$1 validation="$ORCHARD_PG_DATA.validation-$ORCHARD_PG_OPERATION_UUID" manifest="$1/manifest.json" status=0 cleanup_status=0
  orchard_source_postgresql_validate_backup_body "$staging" "$validation" "$manifest" || {
    status=$?
    orchard_source_postgresql_fail "isolated backup validation failed"
  }
  orchard_source_postgresql_stop_validation "$validation" || cleanup_status=$?
  if [[ "$status" -ne 0 ]]; then
    return "$status"
  fi
  [[ "$cleanup_status" -eq 0 ]] || return "$cleanup_status"
  rm -rf "$validation" || return $?
  local temporary="$manifest.new.$$"
  jq '.validation.state = "complete"' "$manifest" > "$temporary" && chmod 600 "$temporary" && \
    sync -f "$temporary" && mv "$temporary" "$manifest" && sync -f "$staging"
}

orchard_source_postgresql_validate_backup_body() {
  local staging=$1 validation=$2 manifest=$3 file expected actual
  for file in orchard.dump roles.sql public-generation.json database-authority.tsv; do
    expected=$(jq -r --arg file "$file" '.files[$file]' "$manifest")
    actual=$(sha256sum "$staging/$file" | cut -d ' ' -f1)
    [[ "$actual" == "$expected" ]] || {
      orchard_source_postgresql_fail "backup checksum mismatch for $file"
      return $?
    }
  done
  orchard_source_postgresql_identity postgres postgres
  install -d -o "$ORCHARD_PG_OWNER" -g "$ORCHARD_PG_GROUP" -m 700 "$validation" || return $?
  orchard_source_postgresql_run_as postgres initdb -D "$validation/data" --encoding=UTF8 --locale=C.UTF-8 --auth-local=trust --auth-host=reject || return $?
  orchard_source_postgresql_run_as postgres pg_ctl -D "$validation/data" -o "-k $validation -p 55432 -c listen_addresses=''" -w start || return $?
  orchard_source_postgresql_run_as postgres createdb --host="$validation" --port=55432 orchard || return $?
  orchard_source_postgresql_run_as postgres pg_restore --host="$validation" --port=55432 --dbname=orchard --no-owner < "$staging/orchard.dump" || return $?
  orchard_source_postgresql_capture_authority "$validation" 55432 postgres postgres "$validation/database-authority.tsv" || return $?
  cmp -s "$staging/database-authority.tsv" "$validation/database-authority.tsv" || {
    orchard_source_postgresql_fail "isolated restore authority disagrees with local public-generation metadata"
    return $?
  }
}

orchard_source_postgresql_stop_validation() {
  local validation=$1
  if [[ -n "$ORCHARD_PG_ROOT" ]]; then
    [[ ! -f "$validation/running" ]] || orchard_source_postgresql_run_as postgres pg_ctl -D "$validation/data" -m immediate -w stop
  elif [[ -f "$validation/data/postmaster.pid" ]]; then
    orchard_source_postgresql_run_as postgres pg_ctl -D "$validation/data" -m immediate -w stop
  fi
}

orchard_source_postgresql_cleanup_validation() {
  local operation_uuid=$1 validation="$ORCHARD_PG_DATA.validation-$1"
  [[ ! -e "$validation" ]] || {
    orchard_source_postgresql_stop_validation "$validation" || return $?
    rm -rf "$validation" || return $?
  }
}

orchard_source_postgresql_restore() {
  local backup_id=$1
  [[ "$backup_id" =~ ^[0-9a-f-]{36}$ ]] || {
    orchard_source_postgresql_fail "restore requires an exact backup operation UUID" 64
    return $?
  }
  local backup="$ORCHARD_PG_BACKUPS/$backup_id" manifest="$ORCHARD_PG_BACKUPS/$backup_id/manifest.json"
  orchard_source_postgresql_safe_file "$manifest" || return $?
  jq -e --arg uuid "$ORCHARD_PG_INSTALLATION_UUID" \
    '.installation_uuid == $uuid and .validation.state == "complete" and .private_material_included == false and .reusable_database_credentials_included == false' \
    "$manifest" >/dev/null || {
    orchard_source_postgresql_fail "backup is incomplete, foreign, or unsafe"
    return $?
  }
  orchard_source_postgresql_verify_backup_files "$backup" || return $?
  orchard_source_postgresql_verify_source_fence "$backup_id" || return $?
  [[ ! -e "$ORCHARD_PG_DATA" ]] || [[ -z $(find "$ORCHARD_PG_DATA" -mindepth 1 -print -quit 2>/dev/null) ]] || {
    orchard_source_postgresql_fail "restore requires a stopped empty target"
    return $?
  }
  orchard_source_postgresql_begin_receipt restore || return $?
  orchard_source_postgresql_consume_fence restore-source "$ORCHARD_PG_FENCE_UUID" || return $?
  orchard_source_postgresql_write_restore_gate restore_in_progress "$backup_id" || return $?
  orchard_source_postgresql_install_roots_and_config || return $?
  orchard_source_postgresql_run_as postgres initdb -D "$ORCHARD_PG_DATA" --encoding=UTF8 --locale=C.UTF-8 --auth-local=peer --auth-host=reject || return $?
  orchard_source_postgresql_write_cluster_identity || return $?
  orchard_source_postgresql_run_as postgres pg_ctl -D "$ORCHARD_PG_DATA" -o "-c config_file=$ORCHARD_PG_CONFIG/postgresql.conf" -w start || return $?
  orchard_source_postgresql_run_as postgres psql --host="$ORCHARD_PG_RUNTIME" --dbname=postgres < "$backup/roles.sql" || return $?
  orchard_source_postgresql_run_as postgres createdb --host="$ORCHARD_PG_RUNTIME" --owner=orchard_owner orchard || return $?
  orchard_source_postgresql_run_as postgres psql --host="$ORCHARD_PG_RUNTIME" --dbname=postgres --no-psqlrc \
    --command='REVOKE CONNECT ON DATABASE orchard FROM PUBLIC; GRANT CONNECT ON DATABASE orchard TO orchard_controller, orchard_migrator, orchard_backup; GRANT TEMPORARY ON DATABASE orchard TO orchard_controller;' || return $?
  orchard_source_postgresql_run_as postgres pg_restore --host="$ORCHARD_PG_RUNTIME" --dbname=orchard --no-owner < "$backup/orchard.dump" || return $?
  local restored_authority="$ORCHARD_PG_INSTALL_STATE/restored-authority-$ORCHARD_PG_OPERATION_UUID.tsv"
  orchard_source_postgresql_capture_authority "$ORCHARD_PG_RUNTIME" 5432 postgres postgres "$restored_authority" || return $?
  cmp -s "$backup/database-authority.tsv" "$restored_authority" || {
    orchard_source_postgresql_fail "restored database authority disagrees with its public-generation checkpoint"
    return $?
  }
  rm -f "$restored_authority" || return $?
  orchard_source_postgresql_install_restored_public_metadata "$backup/public-generation.json" || return $?
  orchard_source_postgresql_write_restore_gate new_key_recovery_required "$backup_id" || return $?
  orchard_source_postgresql_run_as postgres pg_ctl -D "$ORCHARD_PG_DATA" -m fast -w stop || return $?
  ORCHARD_PG_RECEIPT_EXTRA=$(jq -cn --arg backup "$backup_id" '{backup_id:$backup,recovery:"new_key_recovery_required",serving:false}')
  orchard_source_postgresql_advance_receipt database_restored_non_serving 2 true
  unset ORCHARD_PG_RECEIPT_EXTRA
}

orchard_source_postgresql_install_restored_public_metadata() {
  local source=$1 destination="$ORCHARD_PG_INSTALL_STATE/public-generation.json" temporary="$ORCHARD_PG_INSTALL_STATE/public-generation.json.new.$$"
  orchard_source_postgresql_safe_public_metadata "$source" || return $?
  if [[ -e "$destination" || -L "$destination" ]]; then
    orchard_source_postgresql_safe_file "$destination" || return $?
  fi
  install -m 600 "$source" "$temporary" || return $?
  sync -f "$temporary" && mv "$temporary" "$destination" && sync -f "$ORCHARD_PG_INSTALL_STATE"
}

orchard_source_postgresql_write_restore_gate() {
  local state=$1 reference=$2 destination="$ORCHARD_PG_INSTALL_STATE/restore-recovery.json" temporary="$ORCHARD_PG_INSTALL_STATE/restore-recovery.json.new.$$"
  jq -n --arg uuid "$ORCHARD_PG_INSTALLATION_UUID" --arg reference "$reference" --arg state "$state" \
    '{schema_version:1,installation_uuid:$uuid,reference:$reference,state:$state,serving:false,schedulable:false}' \
    > "$temporary" || return $?
  chmod 600 "$temporary" && sync -f "$temporary" && mv "$temporary" "$destination" && sync -f "$ORCHARD_PG_INSTALL_STATE"
}

orchard_source_postgresql_verify_backup_files() {
  local backup=$1 manifest="$1/manifest.json" file expected actual
  for file in orchard.dump roles.sql public-generation.json database-authority.tsv; do
    expected=$(jq -r --arg file "$file" '.files[$file] // empty' "$manifest")
    actual=$(sha256sum "$backup/$file" | cut -d ' ' -f1) || return $?
    [[ -n "$expected" && "$actual" == "$expected" ]] || {
      orchard_source_postgresql_fail "backup checksum mismatch for $file"
      return $?
    }
  done
}

orchard_source_postgresql_verify_source_fence() {
  local backup_id=$1
  local fence="$ORCHARD_PG_INSTALL_STATE/fences/restore-source.json"
  orchard_source_postgresql_safe_file "$fence" >/dev/null 2>&1 || {
    orchard_source_postgresql_fail "restore source fencing is absent or incomplete"
    return $?
  }
  jq -e --arg uuid "$ORCHARD_PG_INSTALLATION_UUID" --arg backup "$backup_id" \
    --arg commit "$ORCHARD_PG_COMMIT" --arg tree "$ORCHARD_PG_TREE" '
    .schema_version == 1 and .installation_uuid == $uuid and .operation == "restore" and .backup_id == $backup and
    .source == {commit:$commit,tree:$tree} and
    (.fence_uuid | test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")) and
    .source_fenced == true and .revocation_or_recovery_authority_recorded == true
  ' "$fence" >/dev/null || {
    orchard_source_postgresql_fail "restore source fencing is absent or incomplete"
    return $?
  }
  ORCHARD_PG_FENCE_UUID=$(jq -r '.fence_uuid' "$fence")
  orchard_source_postgresql_assert_fence_unconsumed restore-source "$ORCHARD_PG_FENCE_UUID"
}

orchard_source_postgresql_upgrade_prepare() {
  local backup=${1:-}
  orchard_source_postgresql_verify_writer_fence upgrade || return $?
  ! orchard_source_postgresql_expected_running || {
    orchard_source_postgresql_fail "upgrade preparation requires PostgreSQL stopped after a complete backup"
    return $?
  }
  [[ "$backup" =~ ^[0-9a-f-]{36}$ ]] && jq -e '.validation.state == "complete"' "$ORCHARD_PG_BACKUPS/$backup/manifest.json" >/dev/null 2>&1 || {
    orchard_source_postgresql_fail "upgrade requires an exact complete validated backup ID"
    return $?
  }
  orchard_source_postgresql_begin_receipt upgrade || return $?
  orchard_source_postgresql_consume_fence database-writers "$ORCHARD_PG_FENCE_UUID" || return $?
  ORCHARD_PG_RECEIPT_EXTRA=$(jq -cn --arg backup "$backup" '{pre_upgrade_backup:$backup,database_stopped:true}')
  orchard_source_postgresql_advance_receipt upgrade_prepared 2 true
  unset ORCHARD_PG_RECEIPT_EXTRA
}

orchard_source_postgresql_rollback_check() {
  local compatibility=$1
  [[ -n "$compatibility" ]] || {
    orchard_source_postgresql_fail "rollback-check requires a compatibility manifest" 64
    return $?
  }
  orchard_source_postgresql_safe_file "$compatibility" || return $?
  jq -e '
    .schema == true and .retained_state == true and .authorization_contract == true and
    .credential_and_governance_writers == true and .audit_semantics == true and
    .ingress_fence == true and .durable_cutovers == true
  ' "$compatibility" >/dev/null || {
    orchard_source_postgresql_fail "binary rollback is prohibited; roll forward or restore the complete fenced pre-upgrade set" 78
    return $?
  }
  printf 'compatible_rollback\n'
}

orchard_source_postgresql_retire() {
  orchard_source_postgresql_stop || return $?
  orchard_source_postgresql_begin_receipt retire || return $?
  ORCHARD_PG_RECEIPT_EXTRA='{"data_retained":true,"configuration_retained":true,"backups_retained":true}'
  orchard_source_postgresql_advance_receipt retired_stopped 2 true
  unset ORCHARD_PG_RECEIPT_EXTRA
}

orchard_source_postgresql_require_space() {
  if [[ -n "$ORCHARD_PG_ROOT" && -f "$ORCHARD_PG_PROBES/storage-state" ]]; then
    case $(<"$ORCHARD_PG_PROBES/storage-state") in
      full|corrupt)
        orchard_source_postgresql_fail "PostgreSQL storage is $(<"$ORCHARD_PG_PROBES/storage-state"); automatic replacement and deletion are forbidden"
        return $?
        ;;
    esac
  fi
  local available probe=$ORCHARD_PG_DATA
  while [[ ! -e "$probe" ]]; do
    [[ "$probe" != / ]] || break
    probe=$(dirname "$probe")
  done
  available=$(df -Pk "$probe" 2>/dev/null | awk 'NR == 2 {print $4}') || return $?
  [[ "$available" =~ ^[0-9]+$ && "$available" -ge ${ORCHARD_SOURCE_DEV_PG_MIN_FREE_KB:-1048576} ]] || {
    orchard_source_postgresql_fail "insufficient PostgreSQL recovery headroom"
    return $?
  }
}

orchard_source_postgresql_begin_receipt() {
  local operation=$1 receipt
  install -d -m 700 "$ORCHARD_PG_RECEIPTS" || return $?
  ORCHARD_PG_OPERATION_UUID=${ORCHARD_SOURCE_DEV_TEST_OPERATION_UUID:-}
  if [[ -z "$ORCHARD_PG_OPERATION_UUID" ]]; then
    ORCHARD_PG_OPERATION_UUID=$(cat /proc/sys/kernel/random/uuid)
  fi
  [[ "$ORCHARD_PG_OPERATION_UUID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || {
    orchard_source_postgresql_fail "operation UUID is invalid"
    return $?
  }
  ORCHARD_PG_RECEIPT="$ORCHARD_PG_RECEIPTS/$ORCHARD_PG_OPERATION_UUID.json"
  [[ ! -e "$ORCHARD_PG_RECEIPT" ]] || {
    orchard_source_postgresql_fail "operation UUID already has a durable receipt"
    return $?
  }
  ORCHARD_PG_OPERATION=$operation
  orchard_source_postgresql_advance_receipt intent_recorded 1 false
}

orchard_source_postgresql_advance_receipt() {
  local phase=$1 generation=$2 terminal=$3 temporary="$ORCHARD_PG_RECEIPT.new.$$" extra=${ORCHARD_PG_RECEIPT_EXTRA:-null}
  orchard_source_postgresql_test_failure "before_$phase" || return $?
  jq -n --arg operation "$ORCHARD_PG_OPERATION" --arg operation_uuid "$ORCHARD_PG_OPERATION_UUID" \
    --arg installation_uuid "$ORCHARD_PG_INSTALLATION_UUID" --arg phase "$phase" --arg version "$ORCHARD_PG_VERSION" \
    --arg commit "$ORCHARD_PG_COMMIT" --arg tree "$ORCHARD_PG_TREE" --argjson generation "$generation" \
    --argjson terminal "$terminal" --argjson extra "$extra" \
    '{schema_version:1,generation:$generation,operation:$operation,operation_uuid:$operation_uuid,
      installation_uuid:$installation_uuid,intended_product_version:$version,phase:$phase,terminal:$terminal,
      source:{commit:$commit,tree:$tree},details:$extra}' > "$temporary" || return $?
  chmod 600 "$temporary" && sync -f "$temporary" && mv "$temporary" "$ORCHARD_PG_RECEIPT" && sync -f "$ORCHARD_PG_RECEIPTS" || return $?
  orchard_source_postgresql_test_failure "after_$phase"
}

orchard_source_postgresql_test_failure() {
  local point=$1
  if [[ -n "$ORCHARD_PG_ROOT" && ${ORCHARD_SOURCE_DEV_PG_TEST_STOP:-} == "$point" ]]; then
    orchard_source_postgresql_fail "injected interruption at $point" 99
    return $?
  fi
}

orchard_source_postgresql_run_as() {
  local identity=$1 command=$2
  shift 2
  local executable
  if [[ -n "$ORCHARD_PG_ROOT" ]]; then
    executable="${ORCHARD_SOURCE_DEV_PG_BIN:-$ORCHARD_PG_PROBES/bin}/$command"
    [[ -x "$executable" ]] || {
      orchard_source_postgresql_fail "test adapter for $command is absent"
      return $?
    }
    ORCHARD_SOURCE_DEV_TEST_IDENTITY="$identity" ORCHARD_SOURCE_DEV_TEST_ROOT="$ORCHARD_PG_ROOT" "$executable" "$@"
  else
    executable=$(command -v "$command") || {
      orchard_source_postgresql_fail "$command is required"
      return $?
    }
    runuser -u "$identity" -- "$executable" "$@"
  fi
}
