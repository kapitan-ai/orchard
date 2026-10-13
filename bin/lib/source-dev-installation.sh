#!/usr/bin/env bash

orchard_source_installation_fail() {
  printf 'orchard-source-installation: %s\n' "$1" >&2
  return "${2:-1}"
}

orchard_source_installation_main() {
  local command=${1:-}
  case "$command" in
    prepare|classify) ;;
    *)
      orchard_source_installation_fail "usage: bin/orchard-source-installation prepare|classify"
      return 64
      ;;
  esac

  ORCHARD_INSTALL_ROOT=${ORCHARD_SOURCE_DEV_ROOT:-}
  ORCHARD_INSTALL_PREFIX=${ORCHARD_INSTALL_ROOT%/}
  ORCHARD_INSTALL_SOURCE=${ORCHARD_SOURCE_DEV_SOURCE:-${ORCHARD_INSTALL_PREFIX}/opt/orchard/source}
  ORCHARD_INSTALL_CANONICAL_SOURCE="${ORCHARD_INSTALL_PREFIX}/opt/orchard/source"
  ORCHARD_INSTALL_STATE="${ORCHARD_INSTALL_PREFIX}/var/lib/orchard/install"
  ORCHARD_INSTALL_MANIFEST="$ORCHARD_INSTALL_STATE/manifest.json"
  ORCHARD_INSTALL_RECEIPT="$ORCHARD_INSTALL_STATE/receipts/prepare.json"
  ORCHARD_INSTALL_LOCK="$ORCHARD_INSTALL_STATE/lifecycle.lock"
  ORCHARD_INSTALL_UNITS_SOURCE="$ORCHARD_INSTALL_SOURCE/rel/linux/source-dev/systemd"
  ORCHARD_INSTALL_UNITS_DEST="${ORCHARD_INSTALL_PREFIX}/etc/systemd/system"
  ORCHARD_INSTALL_PROBE_DIR=${ORCHARD_SOURCE_DEV_PROBE_DIR:-}

  orchard_source_installation_validate_invocation || return $?
  orchard_source_installation_preflight_paths || return $?
  orchard_source_installation_collect_provenance || return $?
  orchard_source_installation_preflight_claims || return $?

  if [[ "$command" == "prepare" ]]; then
    orchard_source_installation_create_install_root || return $?
    exec 9<>"$ORCHARD_INSTALL_LOCK"
    flock -n 9 || {
      orchard_source_installation_fail "lifecycle lock is already held"
      return $?
    }
    # Repeat under the exclusive lock so a competing Orchard preparation
    # cannot win between the read-only preflight and the first durable receipt.
    orchard_source_installation_preflight_claims || return $?
  elif [[ -e "$ORCHARD_INSTALL_LOCK" || -L "$ORCHARD_INSTALL_LOCK" ]]; then
    orchard_source_installation_assert_safe_file "$ORCHARD_INSTALL_LOCK" || return $?
    exec 8<>"$ORCHARD_INSTALL_LOCK"
    flock -n 8 || {
      orchard_source_installation_fail "lifecycle lock is already held"
      return $?
    }
  fi

  local classification
  classification=$(orchard_source_installation_classification) || return $?
  if [[ "$command" == "classify" ]]; then
    printf '%s\n' "$classification"
    case "$classification" in
      clean|prepared) return 0 ;;
      resume_required|recovery_required) return 75 ;;
      *) return 1 ;;
    esac
  fi

  case "$classification" in
    clean|resume_required) ;;
    prepared)
      printf 'orchard-source-installation: already prepared %s at %s\n' "$ORCHARD_INSTALL_UUID" "$ORCHARD_INSTALL_SOURCE"
      return 0
      ;;
    recovery_required)
      orchard_source_installation_fail "exact stale state requires a separately authorized recovery operation" 75
      return $?
      ;;
    *)
      orchard_source_installation_fail "installation state is blocked"
      return $?
      ;;
  esac

  orchard_source_installation_prepare
}

orchard_source_installation_validate_invocation() {
  if [[ -n "$ORCHARD_INSTALL_ROOT" ]]; then
    [[ "$ORCHARD_INSTALL_ROOT" == /* ]] || {
      orchard_source_installation_fail "ORCHARD_SOURCE_DEV_ROOT must be absolute"
      return $?
    }
    [[ "${ORCHARD_SOURCE_DEV_TESTING:-0}" == "1" ]] || {
      orchard_source_installation_fail "relocated roots require ORCHARD_SOURCE_DEV_TESTING=1"
      return $?
    }
    if [[ -n "$ORCHARD_INSTALL_PROBE_DIR" && "$ORCHARD_INSTALL_PROBE_DIR" != "$ORCHARD_INSTALL_ROOT"/* ]]; then
      orchard_source_installation_fail "test probe directory must be inside the relocated root"
      return $?
    fi
    if [[ -n "${ORCHARD_SOURCE_DEV_TEST_INSTALLATION_UUID:-}" ]]; then
      orchard_source_installation_validate_uuid installation "$ORCHARD_SOURCE_DEV_TEST_INSTALLATION_UUID" || return $?
    fi
    if [[ -n "${ORCHARD_SOURCE_DEV_TEST_OPERATION_UUID:-}" ]]; then
      orchard_source_installation_validate_uuid operation "$ORCHARD_SOURCE_DEV_TEST_OPERATION_UUID" || return $?
    fi
  else
    [[ ${EUID:-$(id -u)} -eq 0 ]] || {
      orchard_source_installation_fail "canonical preparation must run as root"
      return $?
    }
    [[ -z "$ORCHARD_INSTALL_PROBE_DIR" ]] || {
      orchard_source_installation_fail "synthetic probes are forbidden for a real host"
      return $?
    }
  fi

  [[ "$ORCHARD_INSTALL_SOURCE" == "$ORCHARD_INSTALL_CANONICAL_SOURCE" ]] || {
    orchard_source_installation_fail "source checkout must be the canonical /opt/orchard/source"
    return $?
  }
  [[ -d "$ORCHARD_INSTALL_SOURCE/.git" && -f "$ORCHARD_INSTALL_SOURCE/mix.exs" ]] || {
    orchard_source_installation_fail "canonical source is not an Orchard Git checkout"
    return $?
  }

  local os_release="${ORCHARD_INSTALL_PREFIX}/etc/os-release"
  [[ -f "$os_release" && ! -L "$os_release" ]] || {
    orchard_source_installation_fail "exact Ubuntu platform evidence is missing"
    return $?
  }
  local os_id version_id
  os_id=$(sed -n 's/^ID=//p' "$os_release" | tr -d '"')
  version_id=$(sed -n 's/^VERSION_ID=//p' "$os_release" | tr -d '"')
  [[ "$os_id" == "ubuntu" && "$version_id" == "24.04" ]] || {
    orchard_source_installation_fail "requires exact Ubuntu Server 24.04"
    return $?
  }
  local architecture
  if [[ -n "$ORCHARD_INSTALL_ROOT" ]]; then
    architecture=${ORCHARD_SOURCE_DEV_TEST_ARCH:-x86_64}
  else
    architecture=$(uname -m)
  fi
  [[ "$architecture" == "x86_64" ]] || {
    orchard_source_installation_fail "requires x86_64, observed $architecture"
    return $?
  }

  local required_command
  for required_command in git jq sha256sum flock stat install cmp sync find; do
    command -v "$required_command" >/dev/null 2>&1 || {
      orchard_source_installation_fail "$required_command is required"
      return $?
    }
  done
  if [[ -z "$ORCHARD_INSTALL_ROOT" ]]; then
    for required_command in ps grep ss systemctl getent groupadd useradd usermod; do
      command -v "$required_command" >/dev/null 2>&1 || {
        orchard_source_installation_fail "$required_command is required for canonical host preflight"
        return $?
      }
    done
  fi
}

orchard_source_installation_collect_provenance() {
  ORCHARD_INSTALL_COMMIT=$(git -C "$ORCHARD_INSTALL_SOURCE" rev-parse --verify HEAD^{commit}) || return $?
  ORCHARD_INSTALL_TREE=$(git -C "$ORCHARD_INSTALL_SOURCE" rev-parse --verify HEAD^{tree}) || return $?
  ORCHARD_INSTALL_STATUS=$(git -C "$ORCHARD_INSTALL_SOURCE" status --porcelain=v1 --untracked-files=all) || return $?
  [[ -z "$ORCHARD_INSTALL_STATUS" ]] || {
    orchard_source_installation_fail "canonical source checkout is dirty"
    return $?
  }
  ORCHARD_INSTALL_VERSION=$(tr -d '\n' < "$ORCHARD_INSTALL_SOURCE/VERSION")
  [[ -n "$ORCHARD_INSTALL_VERSION" ]] || {
    orchard_source_installation_fail "VERSION is empty"
    return $?
  }
  local origin
  origin=$(git -C "$ORCHARD_INSTALL_SOURCE" remote get-url origin 2>/dev/null) || {
    orchard_source_installation_fail "canonical source origin is missing"
    return $?
  }
  case "$origin" in
    https://github.com/kapitan-ai/orchard.git|git@github.com:kapitan-ai/orchard.git)
      ORCHARD_INSTALL_REPOSITORY=https://github.com/kapitan-ai/orchard.git
      ;;
    *)
      orchard_source_installation_fail "canonical source origin is not kapitan-ai/orchard"
      return $?
      ;;
  esac

  local required
  for required in \
    mix.lock \
    mise.toml \
    package-lock.json \
    packaging/linux/appliance/postgresql-16-closure.json \
    rel/linux/source-dev/postgresql/dependencies.json \
    native/orchard_tokenizer/uv.lock \
    native/orchard_worker_mlx/uv.lock \
    proto/orchard/worker/tooling/uv.lock \
    proto/orchard/worker/v1/worker_runtime.proto \
    openspec/specs/runtime-endpoints/spec.md; do
    [[ -f "$ORCHARD_INSTALL_SOURCE/$required" && ! -L "$ORCHARD_INSTALL_SOURCE/$required" ]] || {
      orchard_source_installation_fail "required provenance file is missing or unsafe: $required"
      return $?
    }
  done
}

orchard_source_installation_assert_safe_components() {
  local path=$1 final_owner=${2:-} current="" component enforce_custody=0 expected_owner owner mode
  if [[ -n "$ORCHARD_INSTALL_ROOT" ]]; then
    expected_owner=$(id -un)
  else
    expected_owner=root
    enforce_custody=1
  fi
  IFS=/ read -r -a components <<< "$path"
  for component in "${components[@]}"; do
    [[ -n "$component" ]] || continue
    current="$current/$component"
    if [[ -n "$ORCHARD_INSTALL_ROOT" && "$current" == "$ORCHARD_INSTALL_ROOT" ]]; then
      enforce_custody=1
    fi
    [[ ! -L "$current" ]] || {
      orchard_source_installation_fail "refusing symlink path component $current"
      return $?
    }
    if (( enforce_custody == 1 )) && [[ -e "$current" ]]; then
      owner=$(stat -Lc %U "$current") || return $?
      mode=$(stat -Lc %a "$current") || return $?
      if [[ "$current" == "$path" && -n "$final_owner" ]]; then
        expected_owner=$final_owner
      fi
      [[ "$owner" == "$expected_owner" && $((8#$mode & 0022)) -eq 0 ]] || {
        orchard_source_installation_fail "unsafe ancestor owner or writable mode on $current"
        return $?
      }
    fi
  done
}

orchard_source_installation_assert_safe_file() {
  local path=$1
  orchard_source_installation_assert_safe_components "$path" || return $?
  [[ -f "$path" && ! -L "$path" && $(stat -Lc %h "$path") == "1" ]] || {
    orchard_source_installation_fail "refusing unsafe regular file $path"
    return $?
  }
  local expected_owner actual_owner mode
  if [[ -n "$ORCHARD_INSTALL_ROOT" ]]; then
    expected_owner=$(id -un)
  else
    expected_owner=root
  fi
  actual_owner=$(stat -Lc %U "$path") || return $?
  mode=$(stat -Lc %a "$path") || return $?
  [[ "$actual_owner" == "$expected_owner" && $((8#$mode & 0022)) -eq 0 ]] || {
    orchard_source_installation_fail "unsafe owner or writable mode on $path"
    return $?
  }
}

orchard_source_installation_preflight_paths() {
  local path
  for path in \
    "$ORCHARD_INSTALL_SOURCE" \
    "${ORCHARD_INSTALL_PREFIX}/etc/orchard" \
    "${ORCHARD_INSTALL_PREFIX}/var/lib/orchard" \
    "${ORCHARD_INSTALL_PREFIX}/run/orchard" \
    "${ORCHARD_INSTALL_PREFIX}/var/log/orchard" \
    "${ORCHARD_INSTALL_PREFIX}/var/backups/orchard" \
    "$ORCHARD_INSTALL_UNITS_DEST"; do
    orchard_source_installation_assert_safe_components "$path" || return $?
  done

  local expected_source_owner unsafe_source
  if [[ -n "$ORCHARD_INSTALL_ROOT" ]]; then
    expected_source_owner=$(id -un)
  else
    expected_source_owner=root
  fi
  unsafe_source=$(find "$ORCHARD_INSTALL_SOURCE" -xdev \( ! -user "$expected_source_owner" -o -perm /022 \) -print -quit) || {
    orchard_source_installation_fail "cannot inspect canonical source custody"
    return $?
  }
  [[ -z "$unsafe_source" ]] || {
    orchard_source_installation_fail "canonical source contains unowned or writable path $unsafe_source"
    return $?
  }

  [[ -d "$ORCHARD_INSTALL_UNITS_SOURCE" ]] || {
    orchard_source_installation_fail "source-development unit definitions are missing"
    return $?
  }
}

orchard_source_installation_preflight_claims() {
  orchard_source_installation_existing_manifest || return $?
  orchard_source_installation_existing_receipt || return $?
  orchard_source_installation_preflight_accounts || return $?
  orchard_source_installation_state_conflicts || return $?
  orchard_source_installation_probe_conflicts || return $?
  orchard_source_installation_supervisor_conflicts || return $?
  orchard_source_installation_database_conflicts || return $?
  orchard_source_installation_cgroup_conflicts || return $?
}

orchard_source_installation_preflight_accounts() {
  [[ -z "$ORCHARD_INSTALL_ROOT" ]] || return 0
  local name group home account actual_group actual_home actual_shell
  while IFS=: read -r name group home; do
    if ! getent passwd "$name" >/dev/null; then
      continue
    fi
    account=$(getent passwd "$name")
    actual_group=$(id -gn "$name")
    actual_home=$(cut -d: -f6 <<< "$account")
    actual_shell=$(cut -d: -f7 <<< "$account")
    [[ "$actual_group" == "$group" && "$actual_home" == "$home" ]] || {
      orchard_source_installation_fail "existing $name account has incompatible group or home"
      return $?
    }
    case "$actual_shell" in
      /usr/sbin/nologin|/sbin/nologin|/bin/false) ;;
      *)
        orchard_source_installation_fail "$name must be a non-login account"
        return $?
        ;;
    esac
  done <<'EOF'
orchard-controller:orchard-controller:/var/lib/orchard/controller
orchard-db-migrate:orchard-db-migrate:/var/lib/orchard/install
orchard-db-backup:orchard-db-backup:/var/backups/orchard
orchard-node:orchard-node:/var/lib/orchard/node
orchard-worker:orchard-worker:/var/lib/orchard/worker
EOF

  if [[ -n "$ORCHARD_INSTALL_UUID" ]]; then
    getent group orchard-postgresql >/dev/null || {
      orchard_source_installation_fail "prepared database socket group is missing"
      return $?
    }
    for name in postgres orchard-controller orchard-db-migrate orchard-db-backup; do
      id -nG "$name" | tr ' ' '\n' | grep -Fx orchard-postgresql >/dev/null || {
        orchard_source_installation_fail "$name is missing prepared database socket membership"
        return $?
      }
    done
  fi
}

orchard_source_installation_state_conflicts() {
  local legacy="${ORCHARD_INSTALL_PREFIX}/var/lib/orchard/appliance"
  [[ ! -e "$legacy" && ! -L "$legacy" ]] || {
    orchard_source_installation_fail "a legacy package installation state identity claims the host"
    return $?
  }
  local unexpected
  unexpected=""
  if [[ -d "${ORCHARD_INSTALL_PREFIX}/var/lib/orchard" ]]; then
    if ! unexpected=$(find "${ORCHARD_INSTALL_PREFIX}/var/lib/orchard" -mindepth 2 -maxdepth 5 -name manifest.json ! -path "$ORCHARD_INSTALL_MANIFEST" -print -quit 2>/dev/null); then
      orchard_source_installation_fail "cannot inspect installation-state ownership"
      return $?
    fi
  fi
  [[ -z "$unexpected" ]] || {
    orchard_source_installation_fail "an alternate installation manifest claims state at $unexpected"
    return $?
  }

  if [[ -z "$ORCHARD_INSTALL_UUID" ]]; then
    local role_root retained
    for role_root in \
      "${ORCHARD_INSTALL_PREFIX}/etc/orchard/controller" \
      "${ORCHARD_INSTALL_PREFIX}/etc/orchard/node" \
      "${ORCHARD_INSTALL_PREFIX}/etc/orchard/postgresql" \
      "${ORCHARD_INSTALL_PREFIX}/var/lib/orchard/controller" \
      "${ORCHARD_INSTALL_PREFIX}/var/lib/orchard/node" \
      "${ORCHARD_INSTALL_PREFIX}/var/lib/orchard/models" \
      "${ORCHARD_INSTALL_PREFIX}/var/lib/orchard/worker"; do
      if [[ -d "$role_root" ]]; then
        retained=$(find "$role_root" -mindepth 1 -print -quit) || {
          orchard_source_installation_fail "cannot inspect retained role state at $role_root"
          return $?
        }
        [[ -z "$retained" ]] || {
          orchard_source_installation_fail "unclaimed retained role state blocks preparation at $retained"
          return $?
        }
      fi
    done
  fi

  local identities="${ORCHARD_INSTALL_PREFIX}/etc/orchard/source-dev/identities.json"
  if [[ -e "$identities" || -L "$identities" ]]; then
    orchard_source_installation_assert_safe_file "$identities" || return $?
    jq -e '
      .schema_version == 1 and .activation == "disabled" and
      .roles.controller.user == "orchard-controller" and
      .roles.migration.user == "orchard-db-migrate" and
      .roles.backup.user == "orchard-db-backup" and
      .roles.postgresql.user == "postgres" and
      .roles.node_agent.user == "orchard-node" and
      .roles.worker.user == "orchard-worker"
    ' "$identities" >/dev/null || {
      orchard_source_installation_fail "existing role identity manifest is foreign or ambiguous"
      return $?
    }
  fi
}

orchard_source_installation_existing_manifest() {
  ORCHARD_INSTALL_UUID=""
  if [[ -e "$ORCHARD_INSTALL_MANIFEST" ]]; then
    orchard_source_installation_assert_safe_file "$ORCHARD_INSTALL_MANIFEST" || return $?
    jq -e --arg source /opt/orchard/source --arg profile ubuntu_24_04_x86_64_single_host '
      .schema_version == 1 and
      .canonical_source == $source and
      .profile == $profile and
      .activation == "disabled" and
      .support_status == "unqualified" and
      (.installation_uuid | test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))
    ' "$ORCHARD_INSTALL_MANIFEST" >/dev/null || {
      orchard_source_installation_fail "existing installation manifest is invalid or ambiguous"
      return $?
    }
    ORCHARD_INSTALL_UUID=$(jq -r '.installation_uuid' "$ORCHARD_INSTALL_MANIFEST")
    local commit tree
    commit=$(jq -r '.source.commit' "$ORCHARD_INSTALL_MANIFEST")
    tree=$(jq -r '.source.tree' "$ORCHARD_INSTALL_MANIFEST")
    [[ "$commit" == "$ORCHARD_INSTALL_COMMIT" && "$tree" == "$ORCHARD_INSTALL_TREE" ]] || {
      orchard_source_installation_fail "existing manifest claims a different source commit/tree"
      return $?
    }
    orchard_source_installation_verify_manifest || return $?
  fi
}

orchard_source_installation_existing_receipt() {
  ORCHARD_INSTALL_RECEIPT_PHASE=""
  if [[ -e "$ORCHARD_INSTALL_RECEIPT" ]]; then
    orchard_source_installation_assert_safe_file "$ORCHARD_INSTALL_RECEIPT" || return $?
    jq -e \
      --arg commit "$ORCHARD_INSTALL_COMMIT" \
      --arg tree "$ORCHARD_INSTALL_TREE" \
      --arg version "$ORCHARD_INSTALL_VERSION" '
      .schema_version == 1 and
      .operation == "prepare" and
      (.operation_uuid | test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")) and
      (.installation_uuid | test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")) and
      .intended_product_version == $version and
      ((.phase == "intent_recorded" and .generation == 1) or
       (.phase == "roots_prepared" and .generation == 2) or
       (.phase == "units_prepared" and .generation == 3) or
       (.phase == "source_prepared" and .generation == 4)) and
      .source.commit == $commit and .source.tree == $tree
    ' "$ORCHARD_INSTALL_RECEIPT" >/dev/null || {
      orchard_source_installation_fail "existing prepare receipt has conflicting or invalid inputs"
      return $?
    }
    local receipt_uuid
    receipt_uuid=$(jq -r '.installation_uuid' "$ORCHARD_INSTALL_RECEIPT")
    if [[ -n "$ORCHARD_INSTALL_UUID" && "$receipt_uuid" != "$ORCHARD_INSTALL_UUID" ]]; then
      orchard_source_installation_fail "manifest and receipt installation UUIDs disagree"
      return $?
    fi
    ORCHARD_INSTALL_UUID=$receipt_uuid
    ORCHARD_INSTALL_RECEIPT_PHASE=$(jq -r '.phase' "$ORCHARD_INSTALL_RECEIPT")
  fi
}

orchard_source_installation_probe_conflicts() {
  if [[ -n "$ORCHARD_INSTALL_PROBE_DIR" ]]; then
    orchard_source_installation_probe_fixture_claims || return $?
    return 0
  fi

  local process_pattern='(orchard_controller|orchard_node_agent|orchard-worker|beam\.smp.*orchard_(controller|node_agent))'
  local process_output process_match
  process_output=$(ps -eo pid=,args=) || {
    orchard_source_installation_fail "cannot determine process ownership"
    return $?
  }
  process_match=$(grep -E "$process_pattern" <<< "$process_output" | grep -v -E '(grep -E|orchard-source-installation)' | head -n 1 || true)
  if [[ -n "$process_match" ]]; then
    orchard_source_installation_fail "an Orchard Controller, Node, Worker, or BEAM process already claims the host"
    return $?
  fi
  local listener_output listener_match
  listener_output=$(ss -H -lnt 2>/dev/null) || {
    orchard_source_installation_fail "cannot determine listener ownership"
    return $?
  }
  listener_match=$(grep -E ':(8443|8444|4369|52171|52172|9444)([[:space:]]|$)' <<< "$listener_output" | head -n 1 || true)
  if [[ -n "$listener_match" ]]; then
    orchard_source_installation_fail "a required Orchard listener port is already claimed"
    return $?
  fi
  if command -v epmd >/dev/null 2>&1; then
    local epmd_output epmd_match epmd_status=0
    epmd_output=$(epmd -names 2>&1) || epmd_status=$?
    if (( epmd_status != 0 )) && ! grep -Eiq '(cannot connect|failed to connect)' <<< "$epmd_output"; then
      orchard_source_installation_fail "cannot determine EPMD/BEAM-name ownership"
      return $?
    fi
    epmd_match=$(grep -E 'name orchard_(controller|node_agent)' <<< "$epmd_output" | head -n 1 || true)
    if [[ -n "$epmd_match" ]]; then
      orchard_source_installation_fail "an Orchard EPMD/BEAM name already claims the host"
      return $?
    fi
  fi
}

orchard_source_installation_probe_fixture_claims() {
  local file first second third
  file="$ORCHARD_INSTALL_PROBE_DIR/claims.tsv"
  if [[ -e "$file" || -L "$file" ]]; then
    orchard_source_installation_assert_safe_file "$file" || return $?
    if [[ -s "$file" ]]; then
      IFS=$'\t' read -r first second third < "$file"
      orchard_source_installation_fail "$first conflict (${third:-ambiguous}): $second"
      return $?
    fi
  fi
  file="$ORCHARD_INSTALL_PROBE_DIR/processes.tsv"
  if [[ -e "$file" || -L "$file" ]]; then
    orchard_source_installation_assert_safe_file "$file" || return $?
    if [[ -s "$file" ]]; then
      IFS=$'\t' read -r first second third < "$file"
      orchard_source_installation_fail "process conflict (${third:-ambiguous}): pid=$first $second"
      return $?
    fi
  fi
  file="$ORCHARD_INSTALL_PROBE_DIR/listeners.tsv"
  if [[ -e "$file" || -L "$file" ]]; then
    orchard_source_installation_assert_safe_file "$file" || return $?
    if [[ -s "$file" ]]; then
      IFS=$'\t' read -r first second < "$file"
      orchard_source_installation_fail "listener conflict (${second:-ambiguous}): $first"
      return $?
    fi
  fi
  file="$ORCHARD_INSTALL_PROBE_DIR/epmd-names.tsv"
  if [[ -e "$file" || -L "$file" ]]; then
    orchard_source_installation_assert_safe_file "$file" || return $?
    if [[ -s "$file" ]]; then
      IFS=$'\t' read -r first second < "$file"
      orchard_source_installation_fail "EPMD/BEAM conflict (${second:-ambiguous}): $first"
      return $?
    fi
  fi
}

orchard_source_installation_unit_names() {
  if [[ -n "$ORCHARD_INSTALL_ROOT" && ${ORCHARD_SOURCE_DEV_TEST_FAIL_UNIT_ENUMERATION:-} == 1 ]]; then
    orchard_source_installation_fail "injected supervisor unit observation failure" 74
    return $?
  fi
  find "$ORCHARD_INSTALL_UNITS_SOURCE" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort
}

orchard_source_installation_supervisor_conflicts() {
  local unit source destination unit_names
  unit_names=$(orchard_source_installation_unit_names) || {
    orchard_source_installation_fail "cannot enumerate source-development supervisor units"
    return $?
  }
  while IFS= read -r unit; do
    [[ -n "$unit" ]] || continue
    source="$ORCHARD_INSTALL_UNITS_SOURCE/$unit"
    destination="$ORCHARD_INSTALL_UNITS_DEST/$unit"
    if [[ -e "$destination" || -L "$destination" ]]; then
      orchard_source_installation_assert_safe_file "$destination" || return $?
      cmp -s "$source" "$destination" || {
        orchard_source_installation_fail "supervisor unit $unit has foreign or ambiguous content"
        return $?
      }
    fi
  done <<< "$unit_names"

  local candidate basename candidates
  if [[ -d "$ORCHARD_INSTALL_UNITS_DEST" ]]; then
    candidates=$(find "$ORCHARD_INSTALL_UNITS_DEST" -maxdepth 1 \( -type f -o -type l \) -name 'orchard-*' -print) || {
      orchard_source_installation_fail "cannot inspect installed supervisor units"
      return $?
    }
    while IFS= read -r candidate; do
      [[ -n "$candidate" ]] || continue
      basename=${candidate##*/}
      [[ "$basename" != *.d ]] || continue
      [[ -f "$ORCHARD_INSTALL_UNITS_SOURCE/$basename" ]] || {
        orchard_source_installation_fail "unexpected Orchard supervisor unit blocks preparation at $candidate"
        return $?
      }
    done <<< "$candidates"
  fi

  local supervisor_root unexpected
  for supervisor_root in \
    "${ORCHARD_INSTALL_PREFIX}/etc/systemd/system" \
    "${ORCHARD_INSTALL_PREFIX}/run/systemd/system" \
    "${ORCHARD_INSTALL_PREFIX}/usr/lib/systemd/system" \
    "${ORCHARD_INSTALL_PREFIX}/lib/systemd/system"; do
    [[ -d "$supervisor_root" ]] || continue
    unexpected=$(find "$supervisor_root" \( -type d -o -type l \) -name 'orchard*.d' -print -quit) || return $?
    [[ -z "$unexpected" ]] || {
      orchard_source_installation_fail "foreign Orchard supervisor drop-in blocks preparation at $unexpected"
      return $?
    }
    if [[ "$supervisor_root" != "$ORCHARD_INSTALL_UNITS_DEST" ]]; then
      unexpected=$(find "$supervisor_root" -maxdepth 1 \( -type f -o -type l \) -name 'orchard-*' -print -quit) || return $?
      [[ -z "$unexpected" ]] || {
        orchard_source_installation_fail "a foreign supervisor unit claims the host at $unexpected"
        return $?
      }
    fi
    unexpected=$(find "$supervisor_root" -type l \( -path '*.wants/orchard-*' -o -path '*.requires/orchard-*' \) -print -quit) || return $?
    [[ -z "$unexpected" ]] || {
      orchard_source_installation_fail "an Orchard supervisor unit is enabled at $unexpected"
      return $?
    }
  done

  if [[ -z "$ORCHARD_INSTALL_ROOT" ]]; then
    while IFS= read -r unit; do
      [[ -n "$unit" ]] || continue
      if systemctl is-active --quiet "$unit" 2>/dev/null; then
        orchard_source_installation_fail "supervisor unit $unit is active"
        return $?
      else
        local status=$?
        case "$status" in
          3|4) ;;
          *)
            orchard_source_installation_fail "cannot determine supervisor ownership for $unit"
            return $?
            ;;
        esac
      fi
    done <<< "$unit_names"
  fi
}

orchard_source_installation_database_conflicts() {
  local pg_version="${ORCHARD_INSTALL_PREFIX}/var/lib/postgresql/16/orchard/PG_VERSION"
  local pg_socket="${ORCHARD_INSTALL_PREFIX}/run/postgresql/.s.PGSQL.5432"
  [[ ! -e "$pg_version" && ! -e "$pg_socket" && ! -L "$pg_socket" ]] || {
    orchard_source_installation_fail "a PostgreSQL cluster or socket already claims the profile"
    return $?
  }
}

orchard_source_installation_cgroup_conflicts() {
  local cgroup="${ORCHARD_INSTALL_PREFIX}/sys/fs/cgroup/orchard.slice"
  [[ ! -e "$cgroup" && ! -L "$cgroup" ]] || {
    orchard_source_installation_fail "an Orchard cgroup already claims the profile"
    return $?
  }
}

orchard_source_installation_classification() {
  local stale_file
  if [[ -n "$ORCHARD_INSTALL_PROBE_DIR" ]]; then
    stale_file="$ORCHARD_INSTALL_PROBE_DIR/stale.tsv"
  else
    stale_file="${ORCHARD_INSTALL_PREFIX}/run/orchard/install/stale.tsv"
  fi
  if [[ -e "$stale_file" || -L "$stale_file" ]]; then
    orchard_source_installation_assert_safe_file "$stale_file" || return $?
    if [[ -s "$stale_file" ]]; then
      local kind uuid detail
      IFS=$'\t' read -r kind uuid detail < "$stale_file"
      if [[ -n "$ORCHARD_INSTALL_UUID" && "$uuid" == "$ORCHARD_INSTALL_UUID" ]]; then
        orchard_source_installation_prove_stale "$kind" "$detail" || return $?
        printf 'recovery_required'
        return 0
      fi
      orchard_source_installation_fail "$kind stale state has foreign or ambiguous ownership: $detail"
      return $?
    fi
  fi

  if [[ -z "$ORCHARD_INSTALL_RECEIPT_PHASE" ]]; then
    [[ -z "$ORCHARD_INSTALL_UUID" ]] || {
      orchard_source_installation_fail "manifest exists without a prepare receipt"
      return $?
    }
    printf 'clean'
  elif [[ "$ORCHARD_INSTALL_RECEIPT_PHASE" == "source_prepared" ]]; then
    [[ -f "$ORCHARD_INSTALL_MANIFEST" ]] || {
      orchard_source_installation_fail "terminal receipt exists without a manifest"
      return $?
    }
    orchard_source_installation_verify_prepared || return $?
    printf 'prepared'
  else
    printf 'resume_required'
  fi
}

orchard_source_installation_prove_stale() {
  local kind=$1 detail=$2 observed
  case "$kind" in
    cgroup)
      [[ "$detail" == "/sys/fs/cgroup/orchard.slice" ]] || {
        orchard_source_installation_fail "stale cgroup evidence names an unsupported resource"
        return $?
      }
      [[ ! -e "${ORCHARD_INSTALL_PREFIX}$detail" && ! -L "${ORCHARD_INSTALL_PREFIX}$detail" ]] || {
        orchard_source_installation_fail "stale cgroup evidence still has a live or ambiguous resource"
        return $?
      }
      ;;
    process)
      [[ "$detail" =~ ^[1-9][0-9]*$ ]] || {
        orchard_source_installation_fail "stale process evidence has an invalid PID"
        return $?
      }
      if [[ -e "${ORCHARD_INSTALL_PREFIX}/proc/$detail" || -L "${ORCHARD_INSTALL_PREFIX}/proc/$detail" ]]; then
        orchard_source_installation_fail "stale process evidence still has a live or ambiguous owner"
        return $?
      fi
      ;;
    listener)
      case "$detail" in
        8443|8444|4369|52171|52172|9444) ;;
        *)
          orchard_source_installation_fail "stale listener evidence names an unsupported port"
          return $?
          ;;
      esac
      if [[ -n "$ORCHARD_INSTALL_PROBE_DIR" ]]; then
        local listeners="$ORCHARD_INSTALL_PROBE_DIR/listeners.tsv"
        if [[ -f "$listeners" ]] && grep -E "(^|:)$detail([[:space:]]|$)" "$listeners" >/dev/null; then
          orchard_source_installation_fail "stale listener evidence still has a live or ambiguous owner"
          return $?
        fi
      else
        observed=$(ss -H -lnt 2>/dev/null) || {
          orchard_source_installation_fail "cannot prove stale listener ownership"
          return $?
        }
        if grep -E ":$detail([[:space:]]|$)" <<< "$observed" >/dev/null; then
          orchard_source_installation_fail "stale listener evidence still has a live or ambiguous owner"
          return $?
        fi
      fi
      ;;
    *)
      orchard_source_installation_fail "unsupported stale evidence kind $kind"
      return $?
      ;;
  esac
}

orchard_source_installation_prepare() {
  if [[ -z "$ORCHARD_INSTALL_UUID" ]]; then
    ORCHARD_INSTALL_UUID=$(orchard_source_installation_uuid installation) || return $?
  fi
  ORCHARD_INSTALL_OPERATION_UUID=$(orchard_source_installation_operation_uuid) || return $?
  orchard_source_installation_validate_uuid installation "$ORCHARD_INSTALL_UUID" || return $?
  orchard_source_installation_validate_uuid operation "$ORCHARD_INSTALL_OPERATION_UUID" || return $?
  orchard_source_installation_ensure_directory "$ORCHARD_INSTALL_STATE/receipts" root root 700 || return $?
  if [[ -z "$ORCHARD_INSTALL_RECEIPT_PHASE" ]]; then
    orchard_source_installation_write_receipt intent_recorded || return $?
    orchard_source_installation_test_stop intent_recorded
  fi

  if [[ "$ORCHARD_INSTALL_RECEIPT_PHASE" == "intent_recorded" ]]; then
    orchard_source_installation_prepare_accounts || return $?
    orchard_source_installation_prepare_roots || return $?
    orchard_source_installation_write_receipt roots_prepared || return $?
    orchard_source_installation_test_stop roots_prepared
  fi

  if [[ "$ORCHARD_INSTALL_RECEIPT_PHASE" == "roots_prepared" ]]; then
    orchard_source_installation_prepare_accounts || return $?
    orchard_source_installation_prepare_roots || return $?
    orchard_source_installation_install_units || return $?
    orchard_source_installation_write_receipt units_prepared || return $?
    orchard_source_installation_test_stop units_prepared
  fi

  if [[ "$ORCHARD_INSTALL_RECEIPT_PHASE" == "units_prepared" ]]; then
    orchard_source_installation_prepare_accounts || return $?
    orchard_source_installation_prepare_roots || return $?
    orchard_source_installation_install_units || return $?
    orchard_source_installation_write_manifest || return $?
    orchard_source_installation_write_receipt source_prepared || return $?
  fi
  orchard_source_installation_verify_prepared || return $?
  printf 'orchard-source-installation: prepared inert installation %s\n' "$ORCHARD_INSTALL_UUID"
}

orchard_source_installation_create_install_root() {
  local parent="${ORCHARD_INSTALL_PREFIX}/var/lib/orchard"
  orchard_source_installation_ensure_directory "$parent" root root 755 || return $?
  orchard_source_installation_ensure_directory "$ORCHARD_INSTALL_STATE" root root 700 || return $?
  if [[ -e "$ORCHARD_INSTALL_LOCK" || -L "$ORCHARD_INSTALL_LOCK" ]]; then
    orchard_source_installation_assert_safe_file "$ORCHARD_INSTALL_LOCK" || return $?
  else
    (set -o noclobber; umask 077; : > "$ORCHARD_INSTALL_LOCK") 2>/dev/null || {
      orchard_source_installation_fail "could not exclusively create lifecycle lock"
      return $?
    }
    orchard_source_installation_assert_safe_file "$ORCHARD_INSTALL_LOCK" || return $?
    sync -f "$ORCHARD_INSTALL_LOCK" || return $?
    sync -f "$ORCHARD_INSTALL_STATE" || return $?
  fi
}

orchard_source_installation_uuid() {
  local kind=$1 override=""
  if [[ -n "$ORCHARD_INSTALL_ROOT" ]]; then
    case "$kind" in
      installation) override=${ORCHARD_SOURCE_DEV_TEST_INSTALLATION_UUID:-} ;;
      operation) override=${ORCHARD_SOURCE_DEV_TEST_OPERATION_UUID:-} ;;
    esac
  fi
  if [[ -n "$override" ]]; then
    printf '%s\n' "$override"
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-F' 'a-f'
  else
    cat /proc/sys/kernel/random/uuid
  fi
}

orchard_source_installation_operation_uuid() {
  if [[ -f "$ORCHARD_INSTALL_RECEIPT" ]]; then
    jq -r '.operation_uuid' "$ORCHARD_INSTALL_RECEIPT"
  else
    orchard_source_installation_uuid operation
  fi
}

orchard_source_installation_validate_uuid() {
  local kind=$1 value=$2
  [[ "$value" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || {
    orchard_source_installation_fail "$kind UUID is invalid"
    return $?
  }
}

orchard_source_installation_prepare_accounts() {
  local name group home
  if [[ -z "$ORCHARD_INSTALL_ROOT" ]] && ! getent group orchard-postgresql >/dev/null; then
    groupadd --system orchard-postgresql || return $?
  fi
  while IFS=: read -r name group home; do
    if [[ -n "$ORCHARD_INSTALL_ROOT" ]]; then
      continue
    fi
    if ! getent group "$group" >/dev/null; then
      groupadd --system "$group" || return $?
    fi
    if ! getent passwd "$name" >/dev/null; then
      useradd --system --gid "$group" --home-dir "$home" --no-create-home --shell /usr/sbin/nologin "$name" || return $?
    fi
    local account actual_group actual_home actual_shell
    account=$(getent passwd "$name")
    actual_group=$(id -gn "$name")
    actual_home=$(cut -d: -f6 <<< "$account")
    actual_shell=$(cut -d: -f7 <<< "$account")
    [[ "$actual_group" == "$group" && "$actual_home" == "$home" ]] || {
      orchard_source_installation_fail "existing $name account has incompatible group or home"
      return $?
    }
    case "$actual_shell" in
      /usr/sbin/nologin|/sbin/nologin|/bin/false) ;;
      *)
        orchard_source_installation_fail "$name must be a non-login account"
        return $?
        ;;
    esac
  done <<'EOF'
orchard-controller:orchard-controller:/var/lib/orchard/controller
orchard-db-migrate:orchard-db-migrate:/var/lib/orchard/install
orchard-db-backup:orchard-db-backup:/var/backups/orchard
orchard-node:orchard-node:/var/lib/orchard/node
orchard-worker:orchard-worker:/var/lib/orchard/worker
EOF

  if [[ -z "$ORCHARD_INSTALL_ROOT" ]]; then
    for name in postgres orchard-controller orchard-db-migrate orchard-db-backup; do
      id -nG "$name" | tr ' ' '\n' | grep -Fx orchard-postgresql >/dev/null ||
        usermod -a -G orchard-postgresql "$name" || return $?
    done
  fi
}

orchard_source_installation_resolve_identity() {
  local owner=$1 group=$2
  if [[ -n "$ORCHARD_INSTALL_ROOT" ]]; then
    ORCHARD_INSTALL_OWNER=$(id -un)
    ORCHARD_INSTALL_GROUP=$(id -gn)
  else
    ORCHARD_INSTALL_OWNER=$owner
    ORCHARD_INSTALL_GROUP=$group
  fi
}

orchard_source_installation_ensure_directory() {
  local path=$1 owner=$2 group=$3 mode=$4
  orchard_source_installation_resolve_identity "$owner" "$group"
  orchard_source_installation_assert_safe_components "$path" "$ORCHARD_INSTALL_OWNER" || return $?
  if [[ -e "$path" && ! -d "$path" ]]; then
    orchard_source_installation_fail "refusing non-directory path $path"
    return $?
  fi
  if [[ -d "$path" ]]; then
    local actual expected
    actual=$(stat -Lc '%U:%G:%a' "$path")
    expected="$ORCHARD_INSTALL_OWNER:$ORCHARD_INSTALL_GROUP:$mode"
    [[ "$actual" == "$expected" ]] || {
      orchard_source_installation_fail "$path is $actual, expected $expected"
      return $?
    }
  else
    install -d -o "$ORCHARD_INSTALL_OWNER" -g "$ORCHARD_INSTALL_GROUP" -m "$mode" "$path" || return $?
  fi
}

orchard_source_installation_prepare_roots() {
  local path owner group mode
  while IFS=: read -r path owner group mode; do
    orchard_source_installation_ensure_directory "${ORCHARD_INSTALL_PREFIX}$path" "$owner" "$group" "$mode" || return $?
  done <<'EOF'
/etc/orchard:root:root:750
/etc/orchard/source-dev:root:root:750
/etc/orchard/controller:root:orchard-controller:750
/etc/orchard/node:root:orchard-node:750
/etc/orchard/postgresql:root:postgres:750
/var/lib/orchard/controller:orchard-controller:orchard-controller:700
/var/lib/orchard/node:orchard-node:orchard-node:700
/var/lib/orchard/models:orchard-node:orchard-worker:750
/var/lib/orchard/worker:orchard-worker:orchard-worker:700
/run/orchard:root:root:755
/run/orchard/install:root:root:700
/var/log/orchard:root:root:755
/var/log/orchard/install:root:root:700
/var/log/orchard/postgresql:postgres:postgres:750
/var/log/orchard/controller:orchard-controller:orchard-controller:750
/var/log/orchard/node:orchard-node:orchard-node:750
/var/log/orchard/worker:orchard-worker:orchard-worker:750
/var/backups/orchard:root:root:700
EOF

  local identity_manifest="${ORCHARD_INSTALL_PREFIX}/etc/orchard/source-dev/identities.json"
  orchard_source_installation_atomic_json "$identity_manifest" 640 root root <<'EOF'
{
  "schema_version": 1,
  "activation": "disabled",
  "roles": {
    "controller": {"user": "orchard-controller", "group": "orchard-controller"},
    "migration": {"user": "orchard-db-migrate", "group": "orchard-db-migrate"},
    "backup": {"user": "orchard-db-backup", "group": "orchard-db-backup"},
    "postgresql": {"user": "postgres", "group": "postgres", "ownership": "ubuntu-postgresql-package"},
    "database_socket": {"group": "orchard-postgresql", "members": ["postgres", "orchard-controller", "orchard-db-migrate", "orchard-db-backup"]},
    "node_agent": {"user": "orchard-node", "group": "orchard-node"},
    "worker": {"user": "orchard-worker", "group": "orchard-worker"}
  }
}
EOF
}

orchard_source_installation_install_units() {
  orchard_source_installation_ensure_directory "$ORCHARD_INSTALL_UNITS_DEST" root root 755 || return $?
  local unit source destination temporary unit_names
  unit_names=$(orchard_source_installation_unit_names) || {
    orchard_source_installation_fail "cannot enumerate source-development supervisor units"
    return $?
  }
  while IFS= read -r unit; do
    [[ -n "$unit" ]] || continue
    source="$ORCHARD_INSTALL_UNITS_SOURCE/$unit"
    destination="$ORCHARD_INSTALL_UNITS_DEST/$unit"
    if [[ -e "$destination" || -L "$destination" ]]; then
      cmp -s "$source" "$destination" || {
        orchard_source_installation_fail "refusing to replace foreign supervisor unit $unit"
        return $?
      }
      continue
    fi
    temporary="$destination.new.$$"
    install -o "$(if [[ -n "$ORCHARD_INSTALL_ROOT" ]]; then id -un; else printf root; fi)" \
      -g "$(if [[ -n "$ORCHARD_INSTALL_ROOT" ]]; then id -gn; else printf root; fi)" \
      -m 644 "$source" "$temporary" || return $?
    sync -f "$temporary" || return $?
    mv "$temporary" "$destination" || return $?
    sync -f "$ORCHARD_INSTALL_UNITS_DEST" || return $?
  done <<< "$unit_names"
}

orchard_source_installation_dependency_json() {
  local path digest first=1
  printf '['
  for path in \
    mix.lock \
    package-lock.json \
    native/orchard_tokenizer/uv.lock \
    native/orchard_worker_mlx/uv.lock \
    proto/orchard/worker/tooling/uv.lock; do
    digest=$(sha256sum "$ORCHARD_INSTALL_SOURCE/$path" | cut -d ' ' -f1) || return $?
    (( first == 1 )) || printf ','
    first=0
    jq -cn --arg path "$path" --arg sha256 "$digest" '{path:$path,sha256:$sha256}' || return $?
  done
  printf ']'
}

orchard_source_installation_generated_json() {
  local path digest first=1 generated_paths
  generated_paths=$(git -C "$ORCHARD_INSTALL_SOURCE" ls-files |
    awk '/(^|\/)(generated\/.*|[^/]+\.pb\.ex|[^/]+\.descriptor\.pb)$/ {print}' |
    LC_ALL=C sort) || {
    orchard_source_installation_fail "cannot enumerate generated source outputs"
    return $?
  }
  printf '['
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    digest=$(sha256sum "$ORCHARD_INSTALL_SOURCE/$path" | cut -d ' ' -f1) || return $?
    (( first == 1 )) || printf ','
    first=0
    jq -cn --arg path "$path" --arg sha256 "$digest" '{path:$path,sha256:$sha256}' || return $?
  done <<< "$generated_paths"
  printf ']'
}

orchard_source_installation_write_manifest() {
  local destination=$ORCHARD_INSTALL_MANIFEST dependencies generated toolchain_digest worker_protocol_digest runtime_contract_digest postgresql_dependencies_digest postgresql_closure_digest worker_custody_digest
  orchard_source_installation_verify_source_unchanged || return $?
  dependencies=$(orchard_source_installation_dependency_json) || return $?
  generated=$(orchard_source_installation_generated_json) || return $?
  toolchain_digest=$(sha256sum "$ORCHARD_INSTALL_SOURCE/mise.toml" | cut -d ' ' -f1) || return $?
  worker_protocol_digest=$(sha256sum "$ORCHARD_INSTALL_SOURCE/proto/orchard/worker/v1/worker_runtime.proto" | cut -d ' ' -f1) || return $?
  runtime_contract_digest=$(sha256sum "$ORCHARD_INSTALL_SOURCE/openspec/specs/runtime-endpoints/spec.md" | cut -d ' ' -f1) || return $?
  postgresql_dependencies_digest=$(sha256sum "$ORCHARD_INSTALL_SOURCE/rel/linux/source-dev/postgresql/dependencies.json" | cut -d ' ' -f1) || return $?
  postgresql_closure_digest=$(sha256sum "$ORCHARD_INSTALL_SOURCE/packaging/linux/appliance/postgresql-16-closure.json" | cut -d ' ' -f1) || return $?
  worker_custody_digest=$(sha256sum "$ORCHARD_INSTALL_SOURCE/rel/linux/source-dev/worker-custody.json" | cut -d ' ' -f1) || return $?
  local temporary="$destination.new.$$"
  if [[ -e "$destination" || -L "$destination" ]]; then
    orchard_source_installation_assert_safe_file "$destination" || return $?
  fi
  umask 077
  orchard_source_installation_test_io_failure manifest_write || return $?
  jq -n \
    --arg uuid "$ORCHARD_INSTALL_UUID" \
    --arg version "$ORCHARD_INSTALL_VERSION" \
    --arg commit "$ORCHARD_INSTALL_COMMIT" \
    --arg tree "$ORCHARD_INSTALL_TREE" \
    --arg origin "$ORCHARD_INSTALL_REPOSITORY" \
    --arg toolchain "$toolchain_digest" \
    --arg worker_protocol "$worker_protocol_digest" \
    --arg runtime_contract "$runtime_contract_digest" \
    --arg postgresql_dependencies "$postgresql_dependencies_digest" \
    --arg postgresql_closure "$postgresql_closure_digest" \
    --arg worker_custody "$worker_custody_digest" \
    --argjson dependencies "$dependencies" \
    --argjson generated "$generated" \
    '{
      schema_version: 1,
      installation_uuid: $uuid,
      product_version: $version,
      profile: "ubuntu_24_04_x86_64_single_host",
      canonical_source: "/opt/orchard/source",
      activation: "disabled",
      support_status: "unqualified",
      source: {
        repository: $origin,
        commit: $commit,
        tree: $tree,
        clean: true,
        generated_output_drift: false
      },
      dependency_locks: $dependencies,
      toolchain: {path: "mise.toml", sha256: $toolchain},
      generated_outputs: $generated,
      postgresql: {
        major: 16,
        dependencies_path: "rel/linux/source-dev/postgresql/dependencies.json",
        dependencies_sha256: $postgresql_dependencies,
        closure_path: "packaging/linux/appliance/postgresql-16-closure.json",
        closure_sha256: $postgresql_closure,
        activation: "disabled"
      },
      worker_custody: {
        policy_path: "rel/linux/source-dev/worker-custody.json",
        policy_sha256: $worker_custody,
        activation: "disabled",
        authority: "custody_only",
        node_uuid: null
      },
      compatibility: {
        schema_range: {state: "undeclared"},
        runtime_endpoint_contract: {
          state: "undeclared",
          path: "openspec/specs/runtime-endpoints/spec.md",
          sha256: $runtime_contract
        },
        worker_runtime_protocol: {
          path: "proto/orchard/worker/v1/worker_runtime.proto",
          version: "v1",
          sha256: $worker_protocol
        },
        controller_node: {
          state: "undeclared"
        }
      }
    }' > "$temporary" || return $?
  chmod 600 "$temporary" || return $?
  orchard_source_installation_test_io_failure manifest_fsync || return $?
  sync -f "$temporary" || return $?
  orchard_source_installation_test_io_failure manifest_rename || return $?
  mv "$temporary" "$destination" || return $?
  orchard_source_installation_test_io_failure manifest_directory_fsync || return $?
  sync -f "$(dirname "$destination")" || return $?
}

orchard_source_installation_verify_source_unchanged() {
  local current_commit current_tree current_status
  current_commit=$(git -C "$ORCHARD_INSTALL_SOURCE" rev-parse --verify HEAD^{commit}) || return $?
  current_tree=$(git -C "$ORCHARD_INSTALL_SOURCE" rev-parse --verify HEAD^{tree}) || return $?
  current_status=$(git -C "$ORCHARD_INSTALL_SOURCE" status --porcelain=v1 --untracked-files=all) || return $?
  [[ "$current_commit" == "$ORCHARD_INSTALL_COMMIT" && "$current_tree" == "$ORCHARD_INSTALL_TREE" && -z "$current_status" ]] || {
    orchard_source_installation_fail "source provenance changed during preparation"
    return $?
  }
}

orchard_source_installation_write_receipt() {
  local phase=$1 generation
  case "${ORCHARD_INSTALL_RECEIPT_PHASE:-}:$phase" in
    :intent_recorded) generation=1 ;;
    intent_recorded:roots_prepared) generation=2 ;;
    roots_prepared:units_prepared) generation=3 ;;
    units_prepared:source_prepared) generation=4 ;;
    *)
      orchard_source_installation_fail "invalid prepare receipt transition ${ORCHARD_INSTALL_RECEIPT_PHASE:-none} -> $phase"
      return $?
      ;;
  esac
  local temporary="$ORCHARD_INSTALL_RECEIPT.new.$$"
  umask 077
  orchard_source_installation_test_io_failure receipt_write || return $?
  jq -n \
    --argjson generation "$generation" \
    --arg operation "$ORCHARD_INSTALL_OPERATION_UUID" \
    --arg installation "$ORCHARD_INSTALL_UUID" \
    --arg phase "$phase" \
    --arg version "$ORCHARD_INSTALL_VERSION" \
    --arg commit "$ORCHARD_INSTALL_COMMIT" \
    --arg tree "$ORCHARD_INSTALL_TREE" \
    '{
      schema_version: 1,
      generation: $generation,
      operation: "prepare",
      operation_uuid: $operation,
      installation_uuid: $installation,
      intended_product_version: $version,
      phase: $phase,
      source: {commit: $commit, tree: $tree}
    }' > "$temporary" || return $?
  chmod 600 "$temporary" || return $?
  orchard_source_installation_test_io_failure receipt_fsync || return $?
  sync -f "$temporary" || return $?
  orchard_source_installation_test_io_failure receipt_rename || return $?
  mv "$temporary" "$ORCHARD_INSTALL_RECEIPT" || return $?
  orchard_source_installation_test_io_failure receipt_directory_fsync || return $?
  sync -f "$(dirname "$ORCHARD_INSTALL_RECEIPT")" || return $?
  ORCHARD_INSTALL_RECEIPT_PHASE=$phase
}

orchard_source_installation_atomic_json() {
  local destination=$1 mode=$2 owner=$3 group=$4 temporary="$1.new.$$"
  orchard_source_installation_resolve_identity "$owner" "$group"
  if [[ -e "$destination" || -L "$destination" ]]; then
    orchard_source_installation_assert_safe_file "$destination" || return $?
  fi
  cat > "$temporary" || return $?
  jq -e . "$temporary" >/dev/null || {
    rm -f "$temporary" || true
    orchard_source_installation_fail "refusing invalid JSON for $destination"
    return $?
  }
  chown "$ORCHARD_INSTALL_OWNER:$ORCHARD_INSTALL_GROUP" "$temporary" || return $?
  chmod "$mode" "$temporary" || return $?
  sync -f "$temporary" || return $?
  mv "$temporary" "$destination" || return $?
  sync -f "$(dirname "$destination")" || return $?
}

orchard_source_installation_verify_prepared() {
  orchard_source_installation_verify_manifest || return $?
  jq -e '.phase == "source_prepared" and .generation == 4' "$ORCHARD_INSTALL_RECEIPT" >/dev/null || {
    orchard_source_installation_fail "prepare receipt is not terminal"
    return $?
  }
  local unit unit_names
  unit_names=$(orchard_source_installation_unit_names) || {
    orchard_source_installation_fail "cannot enumerate source-development supervisor units"
    return $?
  }
  while IFS= read -r unit; do
    [[ -n "$unit" ]] || continue
    cmp -s "$ORCHARD_INSTALL_UNITS_SOURCE/$unit" "$ORCHARD_INSTALL_UNITS_DEST/$unit" || {
      orchard_source_installation_fail "prepared unit $unit drifted"
      return $?
    }
  done <<< "$unit_names"
}

orchard_source_installation_verify_manifest() {
  local dependencies generated toolchain_digest worker_protocol_digest runtime_contract_digest postgresql_dependencies_digest postgresql_closure_digest worker_custody_digest
  dependencies=$(orchard_source_installation_dependency_json) || return $?
  generated=$(orchard_source_installation_generated_json) || return $?
  toolchain_digest=$(sha256sum "$ORCHARD_INSTALL_SOURCE/mise.toml" | cut -d ' ' -f1) || return $?
  worker_protocol_digest=$(sha256sum "$ORCHARD_INSTALL_SOURCE/proto/orchard/worker/v1/worker_runtime.proto" | cut -d ' ' -f1) || return $?
  runtime_contract_digest=$(sha256sum "$ORCHARD_INSTALL_SOURCE/openspec/specs/runtime-endpoints/spec.md" | cut -d ' ' -f1) || return $?
  postgresql_dependencies_digest=$(sha256sum "$ORCHARD_INSTALL_SOURCE/rel/linux/source-dev/postgresql/dependencies.json" | cut -d ' ' -f1) || return $?
  postgresql_closure_digest=$(sha256sum "$ORCHARD_INSTALL_SOURCE/packaging/linux/appliance/postgresql-16-closure.json" | cut -d ' ' -f1) || return $?
  worker_custody_digest=$(sha256sum "$ORCHARD_INSTALL_SOURCE/rel/linux/source-dev/worker-custody.json" | cut -d ' ' -f1) || return $?
  jq -e \
    --arg uuid "$ORCHARD_INSTALL_UUID" \
    --arg version "$ORCHARD_INSTALL_VERSION" \
    --arg commit "$ORCHARD_INSTALL_COMMIT" \
    --arg tree "$ORCHARD_INSTALL_TREE" \
    --arg repository "$ORCHARD_INSTALL_REPOSITORY" \
    --arg toolchain "$toolchain_digest" \
    --arg worker_protocol "$worker_protocol_digest" \
    --arg runtime_contract "$runtime_contract_digest" \
    --arg postgresql_dependencies "$postgresql_dependencies_digest" \
    --arg postgresql_closure "$postgresql_closure_digest" \
    --arg worker_custody "$worker_custody_digest" \
    --argjson dependencies "$dependencies" \
    --argjson generated "$generated" '
      .schema_version == 1 and
      .installation_uuid == $uuid and
      .product_version == $version and
      .profile == "ubuntu_24_04_x86_64_single_host" and
      .canonical_source == "/opt/orchard/source" and
      .source.repository == $repository and
      .source.commit == $commit and
      .source.tree == $tree and
      .source.clean == true and
      .source.generated_output_drift == false and
      .activation == "disabled" and
      .support_status == "unqualified" and
      .dependency_locks == $dependencies and
      .toolchain == {path: "mise.toml", sha256: $toolchain} and
      .generated_outputs == $generated and
      .postgresql == {
        major: 16,
        dependencies_path: "rel/linux/source-dev/postgresql/dependencies.json",
        dependencies_sha256: $postgresql_dependencies,
        closure_path: "packaging/linux/appliance/postgresql-16-closure.json",
        closure_sha256: $postgresql_closure,
        activation: "disabled"
      } and
      .worker_custody.policy_path == "rel/linux/source-dev/worker-custody.json" and
      .worker_custody.policy_sha256 == $worker_custody and
      .worker_custody.activation == "disabled" and
      .worker_custody.authority == "custody_only" and
      (.worker_custody.node_uuid == null or
        (.worker_custody.node_uuid | test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))) and
      (.worker_custody | keys | sort) == ["activation", "authority", "node_uuid", "policy_path", "policy_sha256"] and
      .compatibility.schema_range == {state: "undeclared"} and
      .compatibility.runtime_endpoint_contract == {
        state: "undeclared",
        path: "openspec/specs/runtime-endpoints/spec.md",
        sha256: $runtime_contract
      } and
      .compatibility.worker_runtime_protocol == {
        path: "proto/orchard/worker/v1/worker_runtime.proto",
        version: "v1",
        sha256: $worker_protocol
      } and
      .compatibility.controller_node == {
        state: "undeclared"
      }
    ' "$ORCHARD_INSTALL_MANIFEST" >/dev/null || {
    orchard_source_installation_fail "prepared manifest verification failed"
    return $?
  }
}

orchard_source_installation_test_stop() {
  local phase=$1
  if [[ -n "$ORCHARD_INSTALL_ROOT" && ${ORCHARD_SOURCE_DEV_TEST_STOP_AFTER:-} == "$phase" ]]; then
    orchard_source_installation_fail "injected interruption after $phase" 99
    return $?
  fi
}

orchard_source_installation_test_io_failure() {
  local point=$1
  if [[ -n "$ORCHARD_INSTALL_ROOT" && ${ORCHARD_SOURCE_DEV_TEST_FAIL_IO:-} == "$point" ]]; then
    orchard_source_installation_fail "injected I/O failure at $point" 74
    return $?
  fi
}
