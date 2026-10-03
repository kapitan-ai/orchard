#!/usr/bin/env bash
#
# Writes the bounded Linux portable validation report (docs/tooling.md,
# openspec portability-validation "Linux Portable Validation Reporting").
#
# The report is diagnostic. It never decides a lane or gate result: the
# portable test script keeps every command's exit status, and the required
# gate reads job results. A missing, incomplete, or cancelled report means
# unknown, never success.
#
# Every line is `key=value`. Keys come from a fixed vocabulary and values are
# validated against narrow patterns before they are written, so raw command
# output, assertion payloads, environment values, DSNs, cookies, grants, and
# local paths never reach the report.
#
# Facts accumulate in DIR/report.staging, which is never uploaded. Only a
# successful `finalize` publishes DIR/report.txt, by a single rename after
# validation, bounds, and redaction. A failed or interrupted finalize leaves
# no report.txt, so no artifact is published.
#
# Usage:
#   linux-portable-validation-report.sh start DIR
#   linux-portable-validation-report.sh source DIR
#   linux-portable-validation-report.sh tools DIR < "tool version" lines (configured toolchain)
#   linux-portable-validation-report.sh runtime DIR < "name version" lines (probed runtimes)
#   linux-portable-validation-report.sh postgres DIR < server_version_num
#   linux-portable-validation-report.sh lockfiles DIR before|after
#   linux-portable-validation-report.sh cache DIR NAME STEP_OUTCOME CACHE_HIT CACHE_KEY
#   linux-portable-validation-report.sh run-start DIR EXPECTED_STEPS
#   linux-portable-validation-report.sh step DIR INDEX LABEL KIND EXIT ELAPSED_MS CAPTURE CAPTURE_STATUS
#   linux-portable-validation-report.sh run-end DIR EXIT REASON CURRENT_STEP
#   linux-portable-validation-report.sh finalize DIR JOB_STATUS

set -euo pipefail

REPORT_FORMAT='orchard-linux-portable-validation-report/v1'
STAGING_FILE_NAME='report.staging'
PUBLISHED_FILE_NAME='report.txt'
MAX_REPORT_BYTES=131072
MAX_LINE_BYTES=320
MAX_VALUE_BYTES=240
MAX_TOOLS=16
MAX_STEPS=32
MAX_FAILURE_IDENTITIES=20
MAX_CAPTURE_LINE_BYTES=4096
MIN_SCRUB_PATH_BYTES=6

# Runtimes probed after setup. Each is reported, as `unknown` when the probe
# gave nothing usable.
RUNTIMES=(erlang elixir uv python_tokenizer python_worker_mlx)

# Configured toolchain identities (`mise --version` plus `mise current` for
# mise.toml) that a complete report must name with a known version.
CONFIGURED_TOOLS=(mise erlang elixir python uv node)

# The lane's command sequence as label:kind. Finalize requires recorded steps
# to match it in order; scripts/test-linux-portable-core.sh owns the commands.
STEP_SEQUENCE=(
  mix-test:exunit
  mix-test-cover:exunit
  tokenizer-ruff-format:none
  tokenizer-ruff-check:none
  tokenizer-pytest:pytest
  tokenizer-pytest-cov:pytest
  worker-ruff-format:none
  worker-ruff-check:none
  worker-pytest:pytest
  worker-pytest-cov:pytest
)

# Committed lockfiles whose identity is recorded before and after setup.
LOCKFILES=(
  mix_lock:mix.lock
  tokenizer_uv_lock:native/orchard_tokenizer/uv.lock
  worker_mlx_uv_lock:native/orchard_worker_mlx/uv.lock
)

KEY_PATTERN='^[a-z0-9_]+(\.[a-z0-9_]+)*$'
VALUE_PATTERN='^[][A-Za-z0-9 _.,:/()+|%-]*$'
SHA_PATTERN='^([0-9a-f]{40}|[0-9a-f]{64})$'
SHA256_PATTERN='^[0-9a-f]{64}$'
NUMBER_PATTERN='^[0-9]+$'
# A process exit status: a decimal 0-255 without leading zeros.
EXIT_PATTERN='^(0|[1-9][0-9]?|1[0-9][0-9]|2[0-4][0-9]|25[0-5])$'
FINALIZE_WORK=""

fail_usage() {
  printf 'linux-portable-validation-report: %s\n' "$1" >&2
  exit 64
}

report_path() {
  printf '%s/%s' "$1" "$STAGING_FILE_NAME"
}

# Creates the report with its format line when an earlier step never ran.
ensure_report() {
  local dir="$1"
  local file

  [[ -n "$dir" ]] || fail_usage 'report directory is required'
  file="$(report_path "$dir")"
  if [[ ! -f "$file" ]]; then
    (umask 077 && mkdir -p -- "$dir" && printf 'format=%s\n' "$REPORT_FORMAT" > "$file")
  fi
}

valid_value() {
  local value="$1"

  [[ "${#value}" -le "$MAX_VALUE_BYTES" ]] || return 1
  [[ "$value" =~ $VALUE_PATTERN ]] || return 1
  [[ "$value" != /* && "$value" != *//* && "$value" != *..* ]] || return 1
}

# The single write path: rejects any key outside the vocabulary shape and
# replaces any value that fails validation with `invalid`.
append() {
  local dir="$1"
  local key="$2"
  local value="$3"

  [[ "$key" =~ $KEY_PATTERN && "${#key}" -le 80 ]] || return 1
  valid_value "$value" || value=invalid
  printf '%s=%s\n' "$key" "$value" >> "$(report_path "$dir")"
}

# Prints the value when it matches the pattern and the length bound, or
# `unknown` (or a caller-provided fallback) otherwise.
checked() {
  local value="$1"
  local pattern="$2"
  local max="$3"
  local fallback="${4:-unknown}"

  if [[ -n "$value" && "${#value}" -le "$max" && "$value" =~ $pattern ]]; then
    printf '%s' "$value"
  else
    printf '%s' "$fallback"
  fi
}

report_value() {
  local file="$1"
  local key="$2"

  [[ -f "$file" ]] || return 0
  awk -v key="$key" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$file"
}

cmd_start() {
  local dir="$1"
  local file

  [[ -n "$dir" ]] || fail_usage 'report directory is required'
  file="$(report_path "$dir")"
  (umask 077 && mkdir -p -- "$dir" && rm -f -- "$dir/$PUBLISHED_FILE_NAME" &&
    printf 'format=%s\n' "$REPORT_FORMAT" > "$file")
  append "$dir" report.started true
}

cmd_source() {
  local dir="$1"
  local event
  local pr_fallback=unknown

  ensure_report "$dir"
  event="$(checked "${GITHUB_EVENT_NAME:-}" '^[a-z_]+$' 40)"
  [[ "$event" == pull_request* || "$event" == unknown ]] || pr_fallback=not_applicable

  append "$dir" source.repository "$(checked "${GITHUB_REPOSITORY:-}" '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' 140)"
  append "$dir" source.event "$event"
  append "$dir" source.sha "$(checked "${GITHUB_SHA:-}" "$SHA_PATTERN" 64)"
  append "$dir" source.head_sha "$(checked "${ORCHARD_REPORT_HEAD_SHA:-}" "$SHA_PATTERN" 64 "$pr_fallback")"
  append "$dir" source.base_sha "$(checked "${ORCHARD_REPORT_BASE_SHA:-}" "$SHA_PATTERN" 64 "$pr_fallback")"
  append "$dir" source.run_id "$(checked "${GITHUB_RUN_ID:-}" "$NUMBER_PATTERN" 20)"
  append "$dir" source.run_attempt "$(checked "${GITHUB_RUN_ATTEMPT:-}" "$NUMBER_PATTERN" 6)"
  append "$dir" runner.os "$(checked "${RUNNER_OS:-}" '^[A-Za-z]+$' 20)"
  append "$dir" runner.arch "$(checked "${RUNNER_ARCH:-}" '^[A-Za-z0-9]+$' 20)"
  append "$dir" runner.environment "$(checked "${RUNNER_ENVIRONMENT:-}" '^[a-z-]+$' 20)"
  append "$dir" runner.image_os "$(checked "${ImageOS:-}" '^[a-z0-9]+$' 20)"
  append "$dir" runner.image_version "$(checked "${ImageVersion:-}" '^[0-9A-Za-z._-]+$' 40)"
}

# Reads at most 64 `name version` lines from stdin and prints the valid,
# first-seen pairs as `name version`, with `-` in names mapped to `_`.
read_versions() {
  local line
  local name
  local version
  local lines=0
  local seen=' '
  local pattern='^([a-z0-9_-]+) ([0-9A-Za-z._+-]+)$'

  while IFS= read -r line || [[ -n "$line" ]]; do
    lines=$((lines + 1))
    [[ "$lines" -le 64 ]] || break
    [[ "${#line}" -le 120 && "$line" =~ $pattern ]] || continue
    name="${BASH_REMATCH[1]}"
    version="${BASH_REMATCH[2]}"
    [[ "${#name}" -le 32 && "${#version}" -le 64 ]] || continue
    name="${name//-/_}"
    [[ "$seen" != *" $name "* ]] || continue
    seen="$seen$name "
    printf '%s %s\n' "$name" "$version"
  done
}

# Records the configured toolchain (for example `mise current` output). These
# are resolved configuration versions, not proof of what each runtime reports.
cmd_tools() {
  local dir="$1"
  local name
  local version
  local count=0

  ensure_report "$dir"
  while read -r name version; do
    [[ "$count" -lt "$MAX_TOOLS" ]] || break
    count=$((count + 1))
    append "$dir" "toolchain.configured.$name" "$version"
  done < <(read_versions)
  append "$dir" toolchain.configured_count "$count"
}

# Records versions reported by the runtimes themselves for the fixed RUNTIMES
# list. Unexpected names are ignored.
cmd_runtime() {
  local dir="$1"
  local versions
  local runtime
  local value

  ensure_report "$dir"
  versions="$(read_versions)"
  for runtime in "${RUNTIMES[@]}"; do
    value="$(awk -v name="$runtime" '$1 == name { print $2; exit }' <<<"$versions")"
    append "$dir" "runtime.$runtime" "${value:-unknown}"
  done
}

# Records the PostgreSQL `server_version_num` read from stdin, numeric only.
cmd_postgres() {
  local dir="$1"
  local line=""

  ensure_report "$dir"
  IFS= read -r line || true
  append "$dir" postgres.server_version_num "$(checked "$line" '^[0-9]{5,7}$' 7)"
}

# Prints the SHA-256 of stdin, or `unknown`.
sha256_stdin() {
  local out=""

  if command -v sha256sum >/dev/null 2>&1; then
    out="$(sha256sum 2>/dev/null)" || out=""
  elif command -v shasum >/dev/null 2>&1; then
    out="$(shasum -a 256 2>/dev/null)" || out=""
  fi
  out="${out%% *}"
  checked "$out" "$SHA256_PATTERN" 64
}

file_sha256() {
  local path="$1"

  if [[ ! -f "$path" ]]; then
    printf 'missing'
    return 0
  fi
  sha256_stdin < "$path"
}

# Records lockfile identity from the current directory. A changed lockfile is
# reported, never treated as an error.
cmd_lockfiles() {
  local dir="$1"
  local phase="$2"
  local file
  local entry
  local id
  local path
  local digest
  local before
  local changed

  [[ "$phase" == before || "$phase" == after ]] || fail_usage 'lockfile phase must be before or after'
  ensure_report "$dir"
  file="$(report_path "$dir")"
  for entry in "${LOCKFILES[@]}"; do
    id="${entry%%:*}"
    path="${entry#*:}"
    digest="$(file_sha256 "$path")"
    append "$dir" "lockfile.$id.$phase" "$digest"
    [[ "$phase" == after ]] || continue

    before="$(report_value "$file" "lockfile.$id.before")"
    if [[ -z "$before" || "$before" == unknown || "$digest" == unknown ]]; then
      changed=unknown
    elif [[ "$before" == "$digest" ]]; then
      changed=false
    else
      changed=true
    fi
    append "$dir" "lockfile.$id.changed" "$changed"
  done
}

# Maps an existing actions/cache step outcome and its cache-hit output. `hit`
# means the exact key was restored; anything unproven is unknown. The key is
# recorded only as a SHA-256 identity.
cmd_cache() {
  local dir="$1"
  local name="$2"
  local outcome="$3"
  local hit="$4"
  local key="$5"
  local result=unknown
  local key_digest=unknown

  [[ "$name" =~ ^[a-z0-9_]+$ && "${#name}" -le 40 ]] || fail_usage 'cache name is invalid'
  ensure_report "$dir"
  if [[ "$outcome" == success ]]; then
    case "$hit" in
      true) result=hit ;;
      false|'') result=miss ;;
    esac
  fi
  append "$dir" "cache.$name" "$result"
  if [[ -n "$key" && "${#key}" -le 512 && "$key" != *$'\n'* ]]; then
    key_digest="$(printf '%s' "$key" | sha256_stdin)"
  fi
  append "$dir" "cache.$name.key_sha256" "$key_digest"
}

cmd_run_start() {
  local dir="$1"
  local expected="$2"

  [[ "$expected" =~ $NUMBER_PATTERN && "$expected" -ge 1 && "$expected" -le "$MAX_STEPS" ]] ||
    fail_usage 'expected step count is invalid'
  ensure_report "$dir"
  append "$dir" run.started true
  append "$dir" run.expected_steps "$expected"
}

# Extracts allowlisted facts from one captured command log. Emits
# `subkey<TAB>value` lines; the caller validates and prefixes every line.
# Portable POSIX awk only: no interval expressions or gawk extensions.
parse_capture() {
  local kind="$1"
  local capture="$2"

  LC_ALL=C awk -v kind="$kind" -v max_line="$MAX_CAPTURE_LINE_BYTES" \
    -v max_failures="$MAX_FAILURE_IDENTITIES" '
    function out(key, value) { printf "%s\t%s\n", key, value }
    function safe_location(loc) {
      if (length(loc) > 160 || substr(loc, 1, 1) == "/" || index(loc, "..") || index(loc, "//")) return "redacted"
      return loc
    }
    function record_failure(identity) {
      failures++
      if (failures <= max_failures) failure[failures] = identity
    }
    function flush_pending(location) {
      if (!pending) return
      record_failure(app " " pending_module " " location)
      pending = 0
    }
    function remember(app_key, field, value) {
      if (!(app_key in app_seen)) {
        if (app_count >= 16) { app_overflow = 1; return }
        app_seen[app_key] = 1
        app_count++
        app_order[app_count] = app_key
      }
      app_value[app_key, field] = value
    }
    function count_list_ok(text, words,    n, i, items, parts) {
      n = split(text, items, ", ")
      for (i = 1; i <= n; i++) {
        if (split(items[i], parts, " ") != 2) return 0
        if (parts[1] !~ /^[0-9]+$/) return 0
        if (index(" " words " ", " " parts[2] " ") == 0) return 0
      }
      return n > 0
    }
    function exunit(line,    value, module, start) {
      if (line ~ /^==> [a-z][a-z0-9_]*$/ && length(line) <= 68) {
        flush_pending("unknown")
        app = substr(line, 5)
        return
      }
      if (line ~ /^Running ExUnit with seed: [0-9]+, max_cases: [0-9]+$/) {
        value = substr(line, length("Running ExUnit with seed: ") + 1)
        sub(/,.*/, "", value)
        if (length(value) <= 20) remember(app, "seed", value)
        return
      }
      if (line ~ /^Randomized with seed [0-9]+$/ && length(line) <= 42) {
        remember(app, "seed", substr(line, 22))
        return
      }
      if (line ~ /^Result: [0-9]/ && line ~ /^Result: [0-9a-z\/(), ]+$/ && length(line) <= 168) {
        remember(app, "result", substr(line, 9))
        return
      }
      if (line ~ /^Failed: [0-9]+ [a-z]+(, [0-9]+ [a-z]+)*$/ && length(line) <= 96) {
        if (count_list_ok(substr(line, 9), "test tests doctest doctests property properties")) remember(app, "failed", substr(line, 9))
        return
      }
      if (line ~ /^[0-9]+ [a-z]+(, [0-9]+ [a-z]+)*$/ && length(line) <= 120) {
        if (count_list_ok(line, "test tests doctest doctests property properties failure failures excluded skipped invalid")) remember(app, "totals", line)
        return
      }
      if (line ~ /^\| +[0-9.]+% \| Total +\|$/) {
        value = line
        sub(/^\| +/, "", value)
        sub(/ .*/, "", value)
        if (length(value) <= 8) remember(app, "coverage_total", value)
        return
      }
      if (line ~ /^\[TOTAL\] +[0-9.]+%$/) {
        value = line
        sub(/^\[TOTAL\] +/, "", value)
        if (length(value) <= 8) remember(app, "coverage_total", value)
        return
      }
      if (line ~ /^Coverage test failed, threshold not met/ || line ~ /^FAILED: Expected minimum coverage of /) {
        remember(app, "coverage_threshold", "not_met")
        return
      }
      if (line ~ /^  [0-9]+\) [A-Z][A-Za-z0-9_.]*: failure on setup_all callback/) {
        flush_pending("unknown")
        module = line
        sub(/^  [0-9]+\) /, "", module)
        sub(/:.*/, "", module)
        if (length(module) <= 120) record_failure(app " " module " setup_all")
        return
      }
      if (line ~ /^  [0-9]+\) (test|doctest|property) .* \([A-Z][A-Za-z0-9_.]*\)$/) {
        flush_pending("unknown")
        start = length(line)
        while (start > 1 && substr(line, start - 1, 2) != " (") start--
        module = substr(line, start + 1, length(line) - start - 1)
        if (module ~ /^[A-Z][A-Za-z0-9_.]*$/ && length(module) <= 120) {
          pending = 1
          pending_module = module
          pending_lines = 0
        }
        return
      }
      if (pending) {
        if (line ~ /^     [A-Za-z0-9_.\/-]+\.exs?:[0-9]+$/) {
          value = line
          sub(/^ +/, "", value)
          flush_pending(safe_location(value))
        } else if (++pending_lines > 2) {
          flush_pending("unknown")
        }
      }
    }
    function pytest(line,    text, rest, identity, cut, n, fields) {
      if (line ~ /short test summary info/) { in_summary = 1; return }
      if (line ~ /^Using --randomly-seed=[0-9]+$/ && length(line) <= 44) {
        seed = substr(line, 23)
        return
      }
      if (line ~ /^TOTAL( +[0-9]+)+ +[0-9.]+%$/ && length(line) <= 120) {
        n = split(line, fields, " ")
        coverage = fields[n]
        return
      }
      text = line
      sub(/^=+ */, "", text)
      sub(/ *=+$/, "", text)
      if (text ~ /^[0-9]+ [a-z]+(, [0-9]+ [a-z]+)* in [0-9.]+s/ && length(text) <= 160) {
        sub(/ in [0-9.]+s.*$/, "", text)
        if (count_list_ok(text, "passed failed skipped deselected xfailed xpassed warning warnings error errors")) totals = text
        return
      }
      if (text ~ /^no tests ran in [0-9.]+s/) {
        totals = "no tests ran"
        return
      }
      if (in_summary && line ~ /^(FAILED|ERROR) [^ ]/) {
        rest = substr(line, index(line, " ") + 1)
        cut = index(rest, "[")
        if (cut > 0) {
          identity = substr(rest, 1, cut - 1) "[param]"
        } else {
          cut = index(rest, " - ")
          identity = cut > 0 ? substr(rest, 1, cut - 1) : rest
        }
        if (identity !~ /^[A-Za-z0-9_.\/:-]+(\[param\])?$/) identity = "redacted"
        record_failure(tolower(substr(line, 1, index(line, " ") - 1)) " " safe_location(identity))
      }
    }
    BEGIN { app = "_" }
    {
      line = $0
      if (length(line) > max_line) next
      gsub(/\r/, "", line)
      gsub(/\033\[[0-9;]*[A-Za-z]/, "", line)
      if (kind == "exunit") exunit(line)
      else if (kind == "pytest") pytest(line)
    }
    END {
      flush_pending("unknown")
      started = 0
      completed = 0
      incomplete = 0
      for (i = 1; i <= app_count; i++) {
        key = app_order[i]
        split("seed result failed totals coverage_total coverage_threshold", fields, " ")
        for (j = 1; j <= 6; j++) {
          if ((key, fields[j]) in app_value) out("app." (key == "_" ? "project" : key) "." fields[j], app_value[key, fields[j]])
        }
        done = ((key, "result") in app_value) || ((key, "totals") in app_value)
        if ((key, "seed") in app_value) {
          started++
          if (!done) incomplete = 1
        }
        if (done) completed++
      }
      # The suite summary is found only when every started ExUnit run printed
      # its result, or pytest printed its final totals line.
      if (kind == "exunit") {
        if (started == 0) out("seed", "unknown")
        out("apps_started", started)
        out("apps_completed", completed)
        summary = (completed > 0 && !incomplete && !app_overflow) ? "found" : "missing"
      } else {
        if (seed != "") out("seed", seed)
        if (totals != "") out("totals", totals)
        if (coverage != "") out("coverage_total", coverage)
        summary = totals != "" ? "found" : "missing"
      }
      out("summary", summary)
      for (i = 1; i <= failures && i <= max_failures; i++) out("failure." i, failure[i])
      out("failure_identities", summary == "found" ? failures + 0 : "unknown")
      if (failures > max_failures) out("failure_identities_truncated", "true")
    }
  ' "$capture"
}

cmd_step() {
  local dir="$1"
  local index="$2"
  local label="$3"
  local kind="$4"
  local status="$5"
  local elapsed="$6"
  local capture="$7"
  local capture_status="$8"
  local prefix
  local parsed
  local key
  local value
  local parse=not_applicable

  [[ "$index" =~ $NUMBER_PATTERN && "$index" -ge 1 && "$index" -le "$MAX_STEPS" ]] || fail_usage 'step index is invalid'
  [[ "$label" =~ ^[a-z0-9-]+$ && "${#label}" -le 40 ]] || fail_usage 'step label is invalid'
  [[ "$kind" == exunit || "$kind" == pytest || "$kind" == none ]] || fail_usage 'step kind is invalid'
  [[ "$capture_status" == ok || "$capture_status" == failed || "$capture_status" == unavailable ]] ||
    fail_usage 'capture status is invalid'
  ensure_report "$dir"

  prefix="step.$index"
  append "$dir" "$prefix.label" "$label"
  append "$dir" "$prefix.kind" "$kind"
  append "$dir" "$prefix.exit" "$(checked "$status" '^[0-9]+$' 3)"
  append "$dir" "$prefix.elapsed_ms" "$(checked "$elapsed" "$NUMBER_PATTERN" 12)"
  append "$dir" "$prefix.capture" "$capture_status"

  if [[ "$kind" != none ]]; then
    parse=unavailable
    if [[ "$capture_status" == ok && -f "$capture" && -r "$capture" ]]; then
      if parsed="$(parse_capture "$kind" "$capture")"; then
        # Extraction is complete only when the suite summary was recognized.
        parse=partial
        [[ $'\n'"$parsed"$'\n' != *$'\nsummary\tfound\n'* ]] || parse=ok
        while IFS=$'\t' read -r key value; do
          [[ -n "$key" ]] || continue
          append "$dir" "$prefix.$key" "$value" || parse=partial
        done <<<"$parsed"
      else
        parse=failed
      fi
    fi
  fi
  append "$dir" "$prefix.parse" "$parse"
}

cmd_run_end() {
  local dir="$1"
  local status="$2"
  local reason="$3"
  local current="$4"

  ensure_report "$dir"
  append "$dir" run.exit "$(checked "$status" '^[0-9]+$' 3)"
  append "$dir" run.end_reason "$(checked "$reason" '^[a-z_]+$' 32)"
  append "$dir" run.interrupted_step "$(checked "$current" '^([0-9]+|none)$' 4)"
}

# Collects environment values that must never appear in the uploaded report:
# every nonempty line of a credential-shaped variable, whatever its length,
# and local filesystem roots. Runs in a subshell, so the case-insensitive
# match setting stays local.
scrub_values() {
  local name
  local value
  local sensitive='pass|secret|token|cookie|dsn|credential|private|grant|key|database_url|auth'

  shopt -s nocasematch
  while IFS= read -r name; do
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    value="${!name-}"
    [[ -n "$value" ]] || continue
    case "$name" in
      HOME | PWD | OLDPWD | TMPDIR | RUNNER_TEMP | RUNNER_TOOL_CACHE | RUNNER_WORKSPACE | GITHUB_WORKSPACE | \
        GITHUB_ACTION_PATH | ORCHARD_LINUX_PORTABLE_REPORT_DIR)
        if [[ "${#value}" -ge "$MIN_SCRUB_PATH_BYTES" && "$value" != *$'\n'* ]]; then
          printf '%s\n' "$value"
        fi
        ;;
      *)
        if [[ "$name" =~ $sensitive ]]; then
          printf '%s\n' "$value" | awk 'length($0) > 0'
        fi
        ;;
    esac
  done < <(compgen -e)
}

# Succeeds when KEY holds a known value matching PATTERN. The sentinels
# `unknown`, `invalid`, and `not_applicable` never count as known.
require_fact() {
  local file="$1"
  local key="$2"
  local pattern="$3"
  local value

  value="$(report_value "$file" "$key")"
  [[ -n "$value" && "$value" != unknown && "$value" != invalid && "$value" != not_applicable &&
    "$value" =~ $pattern ]]
}

# Succeeds only when every metadata fact is present and known: report start,
# source, run, and runner identity; pull request head and base SHAs (or
# not_applicable outside pull request events); the configured toolchain;
# runtime versions; committed lockfile digests before and after setup; the
# PostgreSQL server version; and the cache result and key digest. Any value
# replaced by `invalid` anywhere in the report also makes it incomplete.
metadata_complete() {
  local file="$1"
  local key
  local entry
  local event
  local value
  local count
  local configured
  local version_pattern='^[0-9A-Za-z._+-]+$'

  [[ "$(report_value "$file" format)" == "$REPORT_FORMAT" ]] || return 1
  [[ "$(report_value "$file" report.started)" == true ]] || return 1
  if grep -q '=invalid$' "$file"; then
    return 1
  fi

  require_fact "$file" source.repository '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || return 1
  require_fact "$file" source.event '^[a-z_]+$' || return 1
  require_fact "$file" source.sha "$SHA_PATTERN" || return 1
  require_fact "$file" source.run_id "$NUMBER_PATTERN" || return 1
  require_fact "$file" source.run_attempt "$NUMBER_PATTERN" || return 1
  require_fact "$file" runner.os '^[A-Za-z]+$' || return 1
  require_fact "$file" runner.arch '^[A-Za-z0-9]+$' || return 1
  require_fact "$file" runner.environment '^[a-z-]+$' || return 1
  require_fact "$file" runner.image_os '^[a-z0-9]+$' || return 1
  require_fact "$file" runner.image_version '^[0-9A-Za-z._-]+$' || return 1

  event="$(report_value "$file" source.event)"
  for key in source.head_sha source.base_sha; do
    if [[ "$event" == pull_request* ]]; then
      require_fact "$file" "$key" "$SHA_PATTERN" || return 1
    elif [[ "$(report_value "$file" "$key")" != not_applicable ]]; then
      require_fact "$file" "$key" "$SHA_PATTERN" || return 1
    fi
  done

  count="$(report_value "$file" toolchain.configured_count)"
  [[ "$count" =~ $NUMBER_PATTERN && "$count" -gt 0 ]] || return 1
  configured="$(grep -c '^toolchain\.configured\.' "$file" || true)"
  [[ "$configured" -eq "$count" ]] || return 1
  while IFS= read -r key; do
    require_fact "$file" "$key" "$version_pattern" || return 1
  done < <(sed -n 's/^\(toolchain\.configured\.[a-z0-9_]*\)=.*/\1/p' "$file")
  for entry in "${CONFIGURED_TOOLS[@]}"; do
    require_fact "$file" "toolchain.configured.$entry" "$version_pattern" || return 1
  done

  for entry in "${RUNTIMES[@]}"; do
    require_fact "$file" "runtime.$entry" "$version_pattern" || return 1
  done
  for entry in "${LOCKFILES[@]}"; do
    require_fact "$file" "lockfile.${entry%%:*}.before" "$SHA256_PATTERN" || return 1
    require_fact "$file" "lockfile.${entry%%:*}.after" "$SHA256_PATTERN" || return 1
    value="$(report_value "$file" "lockfile.${entry%%:*}.changed")"
    [[ "$value" == true || "$value" == false ]] || return 1
  done
  require_fact "$file" postgres.server_version_num '^[0-9]{5,7}$' || return 1
  require_fact "$file" cache.dialyzer_plt '^(hit|miss)$' || return 1
  require_fact "$file" cache.dialyzer_plt.key_sha256 "$SHA256_PATTERN" || return 1
}

# Prints the anchored pattern of every key the helper may stage. Final-only
# fields (report.*, tests.*, job.*) are deliberately absent, so a staged copy
# of one is rejected rather than published.
staging_key_pattern() {
  local runtimes
  local lockfiles=""
  local entry

  runtimes="$(IFS='|'; printf '%s' "${RUNTIMES[*]}")"
  for entry in "${LOCKFILES[@]}"; do
    lockfiles="$lockfiles${lockfiles:+|}${entry%%:*}"
  done
  printf '%s' '^(format|report\.started'
  printf '%s' '|source\.(repository|event|sha|head_sha|base_sha|run_id|run_attempt)'
  printf '%s' '|runner\.(os|arch|environment|image_os|image_version)'
  printf '%s' '|toolchain\.configured_count|toolchain\.configured\.[a-z0-9_]+'
  printf '%s' "|runtime\\.($runtimes)|lockfile\\.($lockfiles)\\.(before|after|changed)"
  printf '%s' '|postgres\.server_version_num|cache\.dialyzer_plt|cache\.dialyzer_plt\.key_sha256'
  printf '%s' '|run\.(started|expected_steps|exit|end_reason|interrupted_step)'
  printf '%s' '|step\.[1-9][0-9]?\.(label|kind|exit|elapsed_ms|capture|parse|seed|totals|coverage_total'
  printf '%s' '|summary|apps_started|apps_completed|failure_identities|failure_identities_truncated'
  printf '%s' '|failure\.[1-9][0-9]?'
  printf '%s' '|app\.[a-z0-9_]+\.(seed|result|failed|totals|coverage_total|coverage_threshold)))$'
}

# Checks the run and per-step facts against STEP_SEQUENCE and sets:
#   RUN_FACTS_COMPLETE  true only when every mandatory fact is present, valid,
#                       and consistent, every recorded step was captured, and
#                       every recorded test step parsed
#   TESTS               failure when a recorded step has a known nonzero exit,
#                       success when all expected steps exited 0, were
#                       captured, and parsed,
#                       unknown otherwise (a malformed exit is never failure)
#   FIRST_FAILED        index of the first known nonzero exit, or empty
evaluate_run() {
  local file="$1"
  local facts=true
  local all_zero=true
  local all_parsed=true
  local all_captured=true
  local gap=false
  local recorded=0
  local steps="${#STEP_SEQUENCE[@]}"
  local index
  local entry
  local label
  local kind
  local exit_value
  local elapsed
  local capture
  local parse
  local run_exit
  local end_reason
  local interrupted
  local failed_exit=""

  RUN_FACTS_COMPLETE=false
  TESTS=unknown
  FIRST_FAILED=""

  run_exit="$(report_value "$file" run.exit)"
  end_reason="$(report_value "$file" run.end_reason)"
  interrupted="$(report_value "$file" run.interrupted_step)"
  [[ "$(report_value "$file" run.started)" == true ]] || facts=false
  [[ "$(report_value "$file" run.expected_steps)" == "$steps" ]] || facts=false
  [[ "$run_exit" =~ $EXIT_PATTERN ]] || facts=false
  [[ "$end_reason" =~ ^(completed|failed|signal_int|signal_term)$ ]] || facts=false
  [[ "$interrupted" =~ ^(none|[1-9][0-9]?)$ ]] || facts=false

  for ((index = 1; index <= MAX_STEPS; index++)); do
    if ! grep -q "^step\.$index\." "$file"; then
      gap=true
      continue
    fi
    # Recorded steps must be contiguous, within the sequence, and stop at
    # the first failure (the lane is fail-fast).
    if [[ "$gap" == true || "$index" -gt "$steps" || -n "$FIRST_FAILED" ]]; then
      facts=false
    fi
    [[ "$index" -le "$steps" ]] || continue
    recorded=$((recorded + 1))
    entry="${STEP_SEQUENCE[$((index - 1))]}"
    label="$(report_value "$file" "step.$index.label")"
    kind="$(report_value "$file" "step.$index.kind")"
    exit_value="$(report_value "$file" "step.$index.exit")"
    elapsed="$(report_value "$file" "step.$index.elapsed_ms")"
    capture="$(report_value "$file" "step.$index.capture")"
    parse="$(report_value "$file" "step.$index.parse")"

    [[ "$label" == "${entry%%:*}" && "$kind" == "${entry#*:}" ]] || facts=false
    [[ "$elapsed" =~ $NUMBER_PATTERN && "${#elapsed}" -le 12 ]] || facts=false
    [[ "$capture" =~ ^(ok|failed|unavailable)$ ]] || facts=false
    # A failed or unavailable capture, for any kind, is never complete.
    [[ "$capture" == ok ]] || all_captured=false
    if [[ "${entry#*:}" == none ]]; then
      [[ "$parse" == not_applicable ]] || facts=false
    else
      [[ "$parse" =~ ^(ok|partial|unavailable|failed)$ ]] || facts=false
      [[ "$parse" == ok ]] || all_parsed=false
    fi
    if [[ "$exit_value" =~ $EXIT_PATTERN ]]; then
      if [[ "$exit_value" != 0 && -z "$FIRST_FAILED" ]]; then
        FIRST_FAILED="$index"
        failed_exit="$exit_value"
      fi
      [[ "$exit_value" == 0 ]] || all_zero=false
    else
      facts=false
      all_zero=false
    fi
  done

  case "$end_reason" in
    completed)
      [[ "$run_exit" == 0 && "$interrupted" == none && "$recorded" -eq "$steps" && -z "$FIRST_FAILED" ]] ||
        facts=false
      ;;
    failed)
      [[ -n "$FIRST_FAILED" && "$run_exit" == "$failed_exit" && "$interrupted" == none &&
        "$recorded" -eq "$FIRST_FAILED" ]] || facts=false
      ;;
    signal_int)
      [[ "$run_exit" == 130 && "$interrupted" != none ]] || facts=false
      ;;
    signal_term)
      [[ "$run_exit" == 143 && "$interrupted" != none ]] || facts=false
      ;;
  esac

  if [[ -n "$FIRST_FAILED" ]]; then
    TESTS=failure
  elif [[ "$facts" == true && "$end_reason" == completed && "$all_zero" == true && "$all_parsed" == true &&
    "$all_captured" == true ]]; then
    TESTS=success
  fi
  if [[ "$facts" == true && "$all_parsed" == true && "$all_captured" == true ]]; then
    RUN_FACTS_COMPLETE=true
  fi
}

cmd_finalize() {
  local dir="$1"
  local job_status="$2"
  local file
  local work
  local line
  local key
  local value
  local secret
  local secrets=()
  local dropped=0
  local redacted=0
  local duplicates=0
  local unknown_keys=0
  local interrupted_run=false
  local seen_keys=$'\n'
  local complete=true
  local tests=unknown
  local result=unknown
  local failed_step=""
  local bytes
  local published
  local app_segment
  local key_pattern

  # A stale or partial publication must never survive a failed finalize.
  [[ -n "$dir" ]] || fail_usage 'report directory is required'
  published="$dir/$PUBLISHED_FILE_NAME"
  if [[ -e "$published" || -L "$published" ]]; then
    rm -f -- "$published"
  fi
  ensure_report "$dir"
  file="$(report_path "$dir")"
  work="$dir/.report.finalize.$$"
  FINALIZE_WORK="$work"
  trap 'rm -f -- "$FINALIZE_WORK"' EXIT
  job_status="$(checked "$job_status" '^(success|failure|cancelled)$' 10)"

  while IFS= read -r secret; do
    secrets+=("$secret")
  done < <(scrub_values)
  key_pattern="$(staging_key_pattern)"

  : > "$work"
  while IFS= read -r line || [[ -n "$line" ]]; do
    key="${line%%=*}"
    value="${line#*=}"
    if [[ "$line" != *=* || "${#line}" -gt "$MAX_LINE_BYTES" || ! "$key" =~ $KEY_PATTERN ]] ||
      ! valid_value "$value"; then
      dropped=$((dropped + 1))
      continue
    fi
    # Only the fixed staging vocabulary is published; anything else is
    # dropped unread and makes the report incomplete.
    if [[ ! "$key" =~ $key_pattern ]]; then
      unknown_keys=$((unknown_keys + 1))
      continue
    fi
    # A collision with a credential or local path value replaces the value,
    # never exposes it, and makes the report incomplete. Keys are fixed
    # vocabulary except an output-derived ExUnit app name, whose collision
    # drops the whole line.
    app_segment=""
    if [[ "$key" =~ ^step\.[0-9]+\.app\.([a-z0-9_]+)\. ]]; then
      app_segment="${BASH_REMATCH[1]}"
    fi
    for secret in ${secrets[@]+"${secrets[@]}"}; do
      if [[ -n "$app_segment" && "$app_segment" == *"$secret"* ]]; then
        redacted=$((redacted + 1))
        continue 2
      fi
      if [[ "$value" == *"$secret"* ]]; then
        redacted=$((redacted + 1))
        value=redacted
        line="$key=$value"
        break
      fi
    done
    if [[ "$seen_keys" == *$'\n'"$key"$'\n'* ]]; then
      duplicates=$((duplicates + 1))
      continue
    fi
    seen_keys="$seen_keys$key"$'\n'
    printf '%s\n' "$line" >> "$work"
  done < "$file"

  metadata_complete "$work" || complete=false
  [[ "$dropped" -eq 0 && "$redacted" -eq 0 && "$duplicates" -eq 0 && "$unknown_keys" -eq 0 ]] ||
    complete=false

  evaluate_run "$work"
  tests="$TESTS"
  failed_step="$FIRST_FAILED"
  [[ "$RUN_FACTS_COMPLETE" == true ]] || complete=false

  # tests.result and tests.first_failed_step keep the recorded command facts.
  # An interrupted run or a cancelled job is incomplete and never an overall
  # failure or success: report.result is then unknown.
  case "$(report_value "$work" run.end_reason)" in
    signal_*) interrupted_run=true ;;
  esac
  if [[ "$interrupted_run" == true || "$job_status" == cancelled ]]; then
    complete=false
  elif [[ "$tests" == failure ]]; then
    result=failure
  elif [[ "$tests" == success && "$complete" == true && "$job_status" == success ]]; then
    result=success
  fi

  {
    printf 'report.dropped_lines=%s\n' "$dropped"
    printf 'report.redacted_lines=%s\n' "$redacted"
    printf 'report.duplicate_keys=%s\n' "$duplicates"
    printf 'report.unknown_keys=%s\n' "$unknown_keys"
    printf 'report.complete=%s\n' "$complete"
    printf 'job.status_at_finalize=%s\n' "$job_status"
    printf 'tests.result=%s\n' "$tests"
    printf 'tests.first_failed_step=%s\n' "${failed_step:-none}"
    printf 'report.result=%s\n' "$result"
  } >> "$work"

  bytes="$(wc -c < "$work" | tr -d ' ')"
  if [[ "$bytes" -gt "$MAX_REPORT_BYTES" ]]; then
    {
      printf 'format=%s\n' "$REPORT_FORMAT"
      printf 'report.complete=false\n'
      printf 'report.oversized=true\n'
      printf 'tests.result=%s\n' "$tests"
      printf 'report.result=%s\n' "$([[ "$result" == failure ]] && printf failure || printf unknown)"
    } > "$work"
  fi
  printf 'report.finalized=true\n' >> "$work"
  mv -f -- "$work" "$published"

  # The upload step trusts only a regular, non-symlink file published here.
  # A symlink is removed; any other unexpected entry is left untouched.
  if [[ -L "$published" || ! -f "$published" ]]; then
    [[ ! -L "$published" ]] || rm -f -- "$published"
    printf "linux-portable-validation-report: published report is not a regular file\n" >&2
    exit 1
  fi
  trap - EXIT
}

[[ "$#" -ge 2 ]] || fail_usage 'usage: linux-portable-validation-report.sh COMMAND DIR [ARGS...]'
command_name="$1"
shift

case "$command_name" in
  start) [[ "$#" -eq 1 ]] || fail_usage 'start takes DIR'; cmd_start "$@" ;;
  source) [[ "$#" -eq 1 ]] || fail_usage 'source takes DIR'; cmd_source "$@" ;;
  tools) [[ "$#" -eq 1 ]] || fail_usage 'tools takes DIR'; cmd_tools "$@" ;;
  runtime) [[ "$#" -eq 1 ]] || fail_usage 'runtime takes DIR'; cmd_runtime "$@" ;;
  postgres) [[ "$#" -eq 1 ]] || fail_usage 'postgres takes DIR'; cmd_postgres "$@" ;;
  lockfiles) [[ "$#" -eq 2 ]] || fail_usage 'lockfiles takes DIR PHASE'; cmd_lockfiles "$@" ;;
  cache) [[ "$#" -eq 5 ]] || fail_usage 'cache takes DIR NAME OUTCOME CACHE_HIT CACHE_KEY'; cmd_cache "$@" ;;
  run-start) [[ "$#" -eq 2 ]] || fail_usage 'run-start takes DIR EXPECTED_STEPS'; cmd_run_start "$@" ;;
  step) [[ "$#" -eq 8 ]] || fail_usage 'step takes DIR INDEX LABEL KIND EXIT ELAPSED_MS CAPTURE CAPTURE_STATUS'; cmd_step "$@" ;;
  run-end) [[ "$#" -eq 4 ]] || fail_usage 'run-end takes DIR EXIT REASON CURRENT_STEP'; cmd_run_end "$@" ;;
  finalize) [[ "$#" -eq 2 ]] || fail_usage 'finalize takes DIR JOB_STATUS'; cmd_finalize "$@" ;;
  *) fail_usage "unknown command: $command_name" ;;
esac
