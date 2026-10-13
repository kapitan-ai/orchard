#!/usr/bin/env bash
set -euo pipefail

destination=$1
mkdir -p "$destination"
cat > "$destination/fixture-postgresql-tool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

command=$(basename "$0")
root=${ORCHARD_SOURCE_DEV_TEST_ROOT:?}
probes="$root/probes"
identity=${ORCHARD_SOURCE_DEV_TEST_IDENTITY:?}

argument_value() {
  local name=$1 previous="" argument
  shift
  for argument in "$@"; do
    if [[ "$previous" == "$name" ]]; then
      printf '%s\n' "$argument"
      return 0
    fi
    case "$argument" in
      "$name"=*) printf '%s\n' "${argument#*=}"; return 0 ;;
    esac
    previous=$argument
  done
  return 1
}

case "$command" in
  initdb)
    [[ "$identity" == postgres ]]
    data=$(argument_value -D "$@")
    mkdir -p "$data"
    printf '16\n' > "$data/PG_VERSION"
    ;;
  pg_ctl)
    [[ "$identity" == postgres ]]
    data=$(argument_value -D "$@")
    action=${*: -1}
    if [[ "$action" == start ]]; then
      if [[ "$data" == *'.validation-'*'/data' ]]; then
        touch "$(dirname "$data")/running"
      else
        printf '%s\n' 11111111-1111-4111-8111-111111111111 > "$probes/running"
        mkdir -p "$root/run/postgresql"
        touch "$root/run/postgresql/.s.PGSQL.5432"
      fi
    elif [[ "$action" == stop ]]; then
      if [[ "$data" == *'.validation-'*'/data' ]]; then
        rm -f "$(dirname "$data")/running"
      else
        rm -f "$probes/running" "$root/run/postgresql/.s.PGSQL.5432"
      fi
    fi
    ;;
  pg_isready)
    [[ "$identity" == postgres ]]
    [[ -f "$probes/running" && ! -f "$probes/unavailable" ]]
    ;;
  psql)
    if printf '%s\n' "$*" | grep -F 'pg_is_in_recovery' >/dev/null; then
      [[ ! -f "$probes/recovery" ]] && printf 'f\n' || printf 't\n'
    elif printf '%s\n' "$*" | grep -F 'orchard_readiness_probe' >/dev/null; then
      [[ "$identity" == orchard-controller && ! -f "$probes/read-write-fail" ]]
      printf '1\n'
    elif printf '%s\n' "$*" | grep -F 'schema_migrations' >/dev/null; then
      printf '20260919020000\n'
    elif printf '%s\n' "$*" | grep -F "orchard_owner','orchard_controller" >/dev/null; then
      [[ "$identity" == orchard-db-backup ]]
      printf '4\n'
    elif printf '%s\n' "$*" | grep -F 'controller_instances' >/dev/null; then
      [[ "$identity" == orchard-db-backup || "$identity" == postgres ]]
      printf 'controller\tcontroller-1\tauthority-root-1\toperational\n'
      printf 'credential\tnode-1\t7\tcurrent\n'
      printf 'peer_grant\tnode-1\t9\tactive\n'
    fi
    ;;
  mise)
    [[ "$identity" == orchard-db-migrate ]]
    [[ ! -f "$probes/migration-fail" && ! -f "$probes/migration-conflict" ]]
    ;;
  pg_dump)
    [[ "$identity" == orchard-db-backup ]]
    printf 'fixture-custom-dump\n'
    ;;
  createdb)
    [[ "$identity" == postgres ]]
    ;;
  pg_restore)
    [[ "$identity" == postgres ]]
    [[ ! -f "$probes/validation-fail" ]]
    ;;
  *) printf 'unknown fixture command %s\n' "$command" >&2; exit 64 ;;
esac
EOF
chmod 0755 "$destination/fixture-postgresql-tool"
for command in initdb pg_ctl pg_isready psql mise pg_dump createdb pg_restore; do
  ln -s fixture-postgresql-tool "$destination/$command"
done
