#!/bin/bash
#
# Build the shared Orchard application payload.
# Usage: scripts/build-payload.sh [--allow-dirty] [--clean] [output_dir]
#
# The output directory receives a versioned payload staging tree. The script
# prints PAYLOAD_ROOT=<path> after all closure and optional signing checks pass.
#

set -euo pipefail

PAYLOAD_BUILD_KEYCHAIN=""
PAYLOAD_BUILD_KEYCHAIN_CONFIGURED=false
PAYLOAD_KEYCHAIN_PASSWORD=""
PAYLOAD_KEYCHAIN_PASSWORD_CONFIGURED=false
_payload_keychain_restore_xtrace=0
case "$-" in
    *x*)
        _payload_keychain_restore_xtrace=1
        set +x
        ;;
esac
if [[ -n "${ORCHARD_BUILD_KEYCHAIN:-}" ]]; then
    PAYLOAD_BUILD_KEYCHAIN="$ORCHARD_BUILD_KEYCHAIN"
    PAYLOAD_BUILD_KEYCHAIN_CONFIGURED=true
    if [[ -n "${ORCHARD_KEYCHAIN_PASSWORD:-}" ]]; then
        PAYLOAD_KEYCHAIN_PASSWORD="$ORCHARD_KEYCHAIN_PASSWORD"
        PAYLOAD_KEYCHAIN_PASSWORD_CONFIGURED=true
    fi
fi
unset ORCHARD_KEYCHAIN_PASSWORD
unset ORCHARD_BUILD_KEYCHAIN
if [[ "$_payload_keychain_restore_xtrace" -eq 1 ]]; then
    set -x
fi
unset _payload_keychain_restore_xtrace

# Logging utilities (must be defined before use in argument parsing)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Parse arguments
ALLOW_DIRTY=false
DO_CLEAN=false
OUTPUT_DIR=""

usage() {
    cat <<'EOF'
Usage: scripts/build-payload.sh [--allow-dirty] [--clean] [output_dir]

Builds the distribution-neutral Orchard payload used by Orchard.app and DMG.
On success, prints PAYLOAD_ROOT=<path> for scripts/build-app.sh.

Options:
  --allow-dirty  Allow uncommitted build inputs for development payloads
  --clean        Remove _build and deps before building
  --help         Show this usage and exit
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --allow-dirty)
            ALLOW_DIRTY=true
            shift
            ;;
        --clean)
            DO_CLEAN=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            usage >&2
            exit 64
            ;;
        *)
            if [[ -n "$OUTPUT_DIR" ]]; then
                log_error "Only one output directory may be supplied"
                usage >&2
                exit 64
            fi
            OUTPUT_DIR="$1"
            shift
            ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$REPO_ROOT/artifacts/payload-builds/$(date +%Y-%m-%d)"
elif [[ "$OUTPUT_DIR" != /* ]]; then
    OUTPUT_DIR="$REPO_ROOT/$OUTPUT_DIR"
fi
PAYLOAD_ROOT_REL="Library/Application Support/Orchard"
STAGING_BASE=""
EXPECTED_STAGING_ROOT=""
KNOWN_BAD_ROOT=""
STAGING_CREATED=false
BUILD_SUCCEEDED=false

trap 'log_error "Build failed at line $LINENO"' ERR

cleanup_packaging_venvs() {
    rm -rf \
        "$REPO_ROOT/native/orchard_tokenizer/.venv-pkg" \
        "$REPO_ROOT/native/orchard_worker_mlx/.venv-pkg"
}

cleanup() {
    cleanup_packaging_venvs
    if [[ "$BUILD_SUCCEEDED" != "true" && "$STAGING_CREATED" == "true" && -d "$STAGING_BASE" ]]; then
        log_info "Cleaning up incomplete payload staging directory..."
        rm -rf "$STAGING_BASE"
    fi
}
trap cleanup EXIT

discard_payload_keychain_env() {
    local restore_xtrace=0
    case "$-" in
        *x*)
            restore_xtrace=1
            set +x
            ;;
    esac

    unset ORCHARD_KEYCHAIN_PASSWORD
    unset ORCHARD_BUILD_KEYCHAIN

    if [[ "$restore_xtrace" -eq 1 ]]; then
        set -x
    fi
}

run_payload_signer() {
    local env_args=()
    local restore_xtrace=0
    local status=0
    case "$-" in
        *x*)
            restore_xtrace=1
            set +x
            ;;
    esac

    set +e
    env_args+=("ORCHARD_PAYLOAD_SIGNING_IDENTITY=$PAYLOAD_SIGNING_IDENTITY")
    if [[ "$PAYLOAD_BUILD_KEYCHAIN_CONFIGURED" == "true" ]]; then
        env_args+=("ORCHARD_BUILD_KEYCHAIN=$PAYLOAD_BUILD_KEYCHAIN")
        if [[ "$PAYLOAD_KEYCHAIN_PASSWORD_CONFIGURED" == "true" ]]; then
            env_args+=("ORCHARD_KEYCHAIN_PASSWORD=$PAYLOAD_KEYCHAIN_PASSWORD")
        fi
    fi
    env "${env_args[@]}" "$REPO_ROOT/scripts/sign-payload.sh" "$@"
    status=$?
    set -e

    if [[ "$restore_xtrace" -eq 1 ]]; then
        set -x
    fi
    return "$status"
}

run_payload_verifier() {
    local env_args=()
    local restore_xtrace=0
    local status=0
    case "$-" in
        *x*)
            restore_xtrace=1
            set +x
            ;;
    esac

    set +e
    if [[ "$PAYLOAD_BUILD_KEYCHAIN_CONFIGURED" == "true" ]]; then
        env_args+=("ORCHARD_BUILD_KEYCHAIN=$PAYLOAD_BUILD_KEYCHAIN")
        if [[ "$PAYLOAD_KEYCHAIN_PASSWORD_CONFIGURED" == "true" ]]; then
            env_args+=("ORCHARD_KEYCHAIN_PASSWORD=$PAYLOAD_KEYCHAIN_PASSWORD")
        fi
    fi
    env "${env_args[@]}" "$REPO_ROOT/scripts/verify-payload-signing.sh" "$@"
    status=$?
    set -e

    if [[ "$restore_xtrace" -eq 1 ]]; then
        set -x
    fi
    return "$status"
}

find_metadata_sidecars() {
    local root="$1"
    local sidecars_file
    local find_err_file

    if [[ ! -d "$root" || -L "$root" ]]; then
        log_error "Invalid macOS metadata sidecar root: $root" >&2
        return 1
    fi

    sidecars_file="$(mktemp "${TMPDIR:-/tmp}/orchard-sidecars.XXXXXX")"
    find_err_file="$(mktemp "${TMPDIR:-/tmp}/orchard-sidecar-find-errors.XXXXXX")"

    if ! find -P "$root" \( -name '._*' -o -name '.DS_Store' \) -print >"$sidecars_file" 2>"$find_err_file"; then
        log_error "Failed to traverse macOS metadata sidecars under: $root" >&2
        cat "$find_err_file" >&2
        rm -f "$sidecars_file" "$find_err_file"
        return 1
    fi

    cat "$sidecars_file"
    rm -f "$sidecars_file" "$find_err_file"
}

blocking_xattrs() {
    local attrs="$1"
    local attr

    while IFS= read -r attr; do
        [[ -n "$attr" ]] || continue
        [[ "$attr" == "com.apple.provenance" ]] && continue
        printf '%s\n' "$attr"
    done <<<"$attrs"
}

has_blocking_xattrs() {
    local attrs="$1"

    [[ -n "$(blocking_xattrs "$attrs")" ]]
}

collect_xattr_nodes() {
    local root="$1"
    local output_file="$2"
    local paths_file
    local find_err_file
    local path
    local attrs
    local status=0

    : >"$output_file"

    if ! command -v xattr >/dev/null 2>&1; then
        log_error "xattr is required to inventory macOS provenance metadata"
        return 1
    fi

    if [[ ! -d "$root" || -L "$root" ]]; then
        log_error "Invalid provenance root: $root"
        return 1
    fi

    paths_file="$(mktemp "${TMPDIR:-/tmp}/orchard-xattr-paths.XXXXXX")"
    find_err_file="$(mktemp "${TMPDIR:-/tmp}/orchard-xattr-find-errors.XXXXXX")"

    if ! find -P "$root" -print0 >"$paths_file" 2>"$find_err_file"; then
        log_error "Failed to traverse provenance root: $root"
        cat "$find_err_file" >&2
        rm -f "$paths_file" "$find_err_file"
        return 1
    fi

    while IFS= read -r -d '' path; do
        if [[ -L "$path" ]]; then
            if attrs="$(xattr -s "$path" 2>&1)"; then
                if has_blocking_xattrs "$attrs"; then
                    printf '%s\n' "$path" >>"$output_file"
                fi
            else
                log_error "Failed to inspect symlink extended attributes for: $path"
                printf '%s\n' "$attrs" >&2
                status=1
            fi
            continue
        fi

        if attrs="$(xattr "$path" 2>&1)"; then
            if has_blocking_xattrs "$attrs"; then
                printf '%s\n' "$path" >>"$output_file"
            fi
        else
            log_error "Failed to inspect extended attributes for: $path"
            printf '%s\n' "$attrs" >&2
            status=1
        fi
    done <"$paths_file"

    rm -f "$paths_file" "$find_err_file"
    return "$status"
}

log_provenance_inventory() {
    local label="$1"
    local root="$2"
    local xattr_nodes_file
    local sidecars_file
    local xattr_count
    local sidecar_count
    local status=0

    xattr_nodes_file="$(mktemp "${TMPDIR:-/tmp}/orchard-xattr-nodes.XXXXXX")"
    sidecars_file="$(mktemp "${TMPDIR:-/tmp}/orchard-sidecars.XXXXXX")"

    if ! collect_xattr_nodes "$root" "$xattr_nodes_file"; then
        status=1
    fi
    if ! find_metadata_sidecars "$root" >"$sidecars_file"; then
        status=1
    fi

    xattr_count="$(wc -l <"$xattr_nodes_file" | tr -d '[:space:]')"
    sidecar_count="$(wc -l <"$sidecars_file" | tr -d '[:space:]')"
    PROVENANCE_XATTR_NODE_COUNT="${xattr_count:-0}"
    PROVENANCE_SIDECAR_COUNT="${sidecar_count:-0}"

    log_info "Provenance inventory: $label xattr_node_count=$PROVENANCE_XATTR_NODE_COUNT payload_sidecar_count=$PROVENANCE_SIDECAR_COUNT root=$root"

    if [[ "$PROVENANCE_XATTR_NODE_COUNT" -gt 0 ]]; then
        log_error "Extended-attribute-bearing nodes for $label:"
        cat "$xattr_nodes_file" >&2
    fi

    if [[ "$PROVENANCE_SIDECAR_COUNT" -gt 0 ]]; then
        log_error "macOS metadata sidecar files for $label:"
        cat "$sidecars_file" >&2
    fi

    rm -f "$xattr_nodes_file" "$sidecars_file"
    return "$status"
}

assert_clean_provenance() {
    local label="$1"
    local root="$2"

    if ! log_provenance_inventory "$label" "$root"; then
        log_error "Provenance gate failed for $label"
        return 1
    fi

    if [[ "$PROVENANCE_XATTR_NODE_COUNT" -ne 0 || "$PROVENANCE_SIDECAR_COUNT" -ne 0 ]]; then
        log_error "Provenance gate failed for $label"
        return 1
    fi
}

assert_no_source_sidecars() {
    local label="$1"
    local root="$2"
    local sidecars_file
    local sidecar_count

    sidecars_file="$(mktemp "${TMPDIR:-/tmp}/orchard-source-sidecars.XXXXXX")"

    if ! find_metadata_sidecars "$root" >"$sidecars_file"; then
        rm -f "$sidecars_file"
        log_error "Source metadata gate failed for $label"
        return 1
    fi

    sidecar_count="$(wc -l <"$sidecars_file" | tr -d '[:space:]')"
    log_info "Source metadata inventory: $label payload_sidecar_count=${sidecar_count:-0} root=$root"

    if [[ "${sidecar_count:-0}" -gt 0 ]]; then
        log_error "macOS metadata sidecar files for $label:"
        cat "$sidecars_file" >&2
        rm -f "$sidecars_file"
        log_error "Source metadata gate failed for $label"
        return 1
    fi

    rm -f "$sidecars_file"
}

validate_packaging_source_provenance() {
    # Source xattrs such as com.apple.provenance can be immutable on some hosts;
    # payload safety is enforced after metadata-suppressed copy into staging.
    # Source trees must still be free of visible AppleDouble/.DS_Store files.
    assert_no_source_sidecars "packaging wrappers" "$REPO_ROOT/packaging/payload/bin" || return 1
    assert_no_source_sidecars "launchd plists" "$REPO_ROOT/packaging/launchd" || return 1
    assert_no_source_sidecars "payload entitlements" "$REPO_ROOT/packaging/payload/entitlements" || return 1
}

copy_file_without_metadata() {
    COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 cp -X "$1" "$2"
}

copy_tree_without_metadata() {
    COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 cp -X -R "$1" "$2"
}

copy_packaging_venv_only() {
    local src="$1"
    local dest_parent="$2"
    local helper_name
    helper_name="$(basename "$src")"
    local dest="$dest_parent/$helper_name"

    rm -rf "$dest"
    mkdir -p "$dest"

    if [[ ! -d "$src/.venv-pkg" ]]; then
        log_error "Missing packaging venv for native helper: $src/.venv-pkg"
        return 1
    fi

    copy_tree_without_metadata "$src/.venv-pkg" "$dest/"
}

remove_metadata_sidecars() {
    local root="$1"
    local sidecars

    if ! sidecars="$(find_metadata_sidecars "$root")"; then
        return 1
    fi
    if [[ -z "$sidecars" ]]; then
        return 0
    fi

    log_warn "Removing macOS metadata sidecar files from staging payload"
    printf '%s\n' "$sidecars" >&2
    while IFS= read -r sidecar; do
        [[ -n "$sidecar" ]] && rm -f "$sidecar"
    done <<<"$sidecars"
}

scrub_xattrs_preserving_modes() {
    local root="$1"
    local restore_file
    local paths_file
    local find_err_file
    local path
    local mode
    local attrs
    local blocking_attrs
    local attr
    local status=0

    restore_file="$(mktemp "${TMPDIR:-/tmp}/orchard-xattr-modes.XXXXXX")"
    paths_file="$(mktemp "${TMPDIR:-/tmp}/orchard-xattr-scrub-paths.XXXXXX")"
    find_err_file="$(mktemp "${TMPDIR:-/tmp}/orchard-xattr-scrub-find-errors.XXXXXX")"

    if ! find -P "$root" -print0 >"$paths_file" 2>"$find_err_file"; then
        log_error "Failed to traverse provenance root: $root"
        cat "$find_err_file" >&2
        rm -f "$restore_file" "$paths_file" "$find_err_file"
        return 1
    fi

    while IFS= read -r -d '' path; do
        if [[ -L "$path" ]]; then
            if ! attrs="$(xattr -s "$path" 2>&1)"; then
                log_error "Failed to inspect symlink extended attributes for: $path"
                printf '%s\n' "$attrs" >&2
                status=1
                continue
            fi
            blocking_attrs="$(blocking_xattrs "$attrs")"
            if [[ -z "$blocking_attrs" ]]; then
                continue
            fi
            while IFS= read -r attr; do
                [[ -n "$attr" ]] || continue
                if ! xattr -d -s "$attr" "$path"; then
                    log_error "Failed to scrub symlink extended attribute $attr for: $path"
                    status=1
                fi
            done <<<"$blocking_attrs"
            continue
        fi

        if ! attrs="$(xattr "$path" 2>&1)"; then
            log_error "Failed to inspect extended attributes for: $path"
            printf '%s\n' "$attrs" >&2
            status=1
            continue
        fi
        blocking_attrs="$(blocking_xattrs "$attrs")"
        if [[ -z "$blocking_attrs" ]]; then
            continue
        fi

        mode="$(stat -f '%Lp' "$path" 2>/dev/null || true)"
        if [[ -n "$mode" && ! -w "$path" ]]; then
            printf '%s\t%s\n' "$mode" "$path" >>"$restore_file"
            if ! chmod u+w "$path"; then
                log_error "Failed to make staged path temporarily writable for xattr scrub: $path"
                status=1
                continue
            fi
        fi

        while IFS= read -r attr; do
            [[ -n "$attr" ]] || continue
            if ! xattr -d "$attr" "$path"; then
                log_error "Failed to scrub extended attribute $attr for: $path"
                status=1
            fi
        done <<<"$blocking_attrs"
    done <"$paths_file"

    while IFS=$'\t' read -r mode path; do
        if [[ -n "$mode" && -n "$path" ]] && ! chmod "$mode" "$path"; then
            log_error "Failed to restore staged path mode after xattr scrub: $path"
            status=1
        fi
    done <"$restore_file"
    rm -f "$restore_file" "$paths_file" "$find_err_file"

    return "$status"
}

scrub_macos_metadata() {
    local root="$1"

    if ! remove_metadata_sidecars "$root"; then
        return 1
    fi

    if command -v xattr >/dev/null 2>&1; then
        if ! scrub_xattrs_preserving_modes "$root"; then
            log_error "Failed to scrub macOS extended attributes from staging payload"
            return 1
        fi
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        log_error "xattr is required to scrub macOS metadata on Darwin"
        return 1
    else
        log_warn "xattr not found; skipping extended-attribute scrub on non-Darwin host"
    fi

    if ! remove_metadata_sidecars "$root"; then
        return 1
    fi
    assert_clean_provenance "post-scrub staging" "$root"
}

validate_controller_release_independence() {
    local release_root="$REPO_ROOT/_build/prod/rel/orchard_controller"
    local rel_file
    local cli_library
    local cli_beam
    local required_beam

    rel_file="$(find "$release_root/releases" -name 'orchard_controller.rel' -type f -print -quit 2>/dev/null || true)"
    if [[ -z "$rel_file" ]]; then
        log_error "Assembled Controller release is missing orchard_controller.rel"
        return 1
    fi

    if grep -Eq '\{orchard_cli,' "$rel_file"; then
        log_error "Assembled Controller release still contains the orchard_cli application"
        return 1
    fi

    cli_library="$(find "$release_root/lib" -maxdepth 1 -name 'orchard_cli-*' -print -quit 2>/dev/null || true)"
    if [[ -n "$cli_library" ]]; then
        log_error "Assembled Controller release still contains an orchard_cli library: $cli_library"
        return 1
    fi

    cli_beam="$(find "$release_root/lib" \
        \( -name 'Elixir.OrchardCLI.beam' -o -name 'Elixir.OrchardCLI.*.beam' \) \
        -print -quit 2>/dev/null || true)"
    if [[ -n "$cli_beam" ]]; then
        log_error "Assembled Controller release still contains an OrchardCLI module: $cli_beam"
        return 1
    fi

    for required_beam in \
        'Elixir.Orchard.PackagedNodeCommand.beam' \
        'Elixir.Orchard.PackagedNodeCommandRuntime.beam' \
        'Elixir.Orchard.PackagedNodeCommandRPC.beam'; do
        if ! find "$release_root/lib" -type f -name "$required_beam" -print -quit | grep -q .; then
            log_error "Assembled Controller release is missing $required_beam"
            return 1
        fi
    done
}

validate_staging_layout() {
    local required_paths=(
        "share/bin/orchardctl"
        "share/bin/orchard-controller"
        "share/bin/orchard-node-agent"
        "share/bin/orchard-managed-postgres"
        "share/launchd/com.orchard.controller.plist"
        "share/launchd/com.orchard.node-agent.plist"
        "releases/orchard_cli/bin/orchard_cli"
        "releases/orchard_controller/bin/orchard_controller"
        "releases/orchard_node_agent/bin/orchard_node_agent"
    )
    local rel_path

    if [[ ! -d "$EXPECTED_STAGING_ROOT" ]]; then
        log_error "Expected staging root missing: $EXPECTED_STAGING_ROOT"
        return 1
    fi

    if [[ -e "$KNOWN_BAD_ROOT" ]]; then
        log_error "Malformed staging root detected: $KNOWN_BAD_ROOT"
        return 1
    fi

    assert_clean_provenance "staging layout" "$STAGING_BASE"

    for rel_path in "${required_paths[@]}"; do
        if [[ ! -e "$EXPECTED_STAGING_ROOT/$rel_path" ]]; then
            log_error "Missing staged payload path: $EXPECTED_STAGING_ROOT/$rel_path"
            return 1
        fi
    done
}

source_status() {
    git status --porcelain=v1 --untracked-files=all -- \
        . \
        ":(exclude,literal)apps/orchard_controller/priv/static/images/orchard-mark.svg.gz"
}

validate_captured_source_identity() {
    local current_sha
    local current_status

    if ! current_sha="$(git rev-parse HEAD)"; then
        log_error "Failed to revalidate Git HEAD during payload construction"
        return 1
    fi

    if [[ ! "$current_sha" =~ ^[0-9a-f]{40}$ ]]; then
        log_error "Revalidated payload source must be a 40-character lowercase Git SHA"
        return 1
    fi

    if [[ "$current_sha" != "$FULL_GIT_SHA" ]]; then
        log_error "Source HEAD changed during payload construction"
        log_error "Captured: $FULL_GIT_SHA"
        log_error "Current:  $current_sha"
        return 1
    fi

    if [[ "$ALLOW_DIRTY" != "true" ]]; then
        if ! current_status="$(source_status)"; then
            log_error "Failed to revalidate payload source cleanliness"
            return 1
        fi

        if [[ -n "$current_status" ]]; then
            log_error "Build inputs changed during payload construction"
            printf '%s\n' "$current_status" >&2
            return 1
        fi
    fi
}

cd "$REPO_ROOT"

export MIX_ENV=prod

if [[ -z "${ORCHARD_BUILD_CHANNEL+x}" ]]; then
    ORCHARD_BUILD_CHANNEL="trial"
else
    ORCHARD_BUILD_CHANNEL="$(printf '%s' "$ORCHARD_BUILD_CHANNEL" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
fi

if [[ -z "$ORCHARD_BUILD_CHANNEL" ]]; then
    log_error "Distributed payload builds require ORCHARD_BUILD_CHANNEL to be non-empty"
    log_error "Allowed values: internal, trial, pilot, release"
    log_error "Unset ORCHARD_BUILD_CHANNEL to use the default channel: trial"
    exit 1
fi

case "$ORCHARD_BUILD_CHANNEL" in
    internal|trial|pilot|release)
        export ORCHARD_BUILD_CHANNEL
        ;;
    dev)
        log_error "Distributed payload builds do not support ORCHARD_BUILD_CHANNEL=dev"
        log_error "Allowed values: internal, trial, pilot, release"
        exit 1
        ;;
    *)
        log_error "Invalid ORCHARD_BUILD_CHANNEL: $ORCHARD_BUILD_CHANNEL"
        log_error "Allowed values: internal, trial, pilot, release"
        exit 1
        ;;
esac

if ! FULL_GIT_SHA="$(git rev-parse HEAD)"; then
    log_error "Failed to resolve the Git HEAD for payload build provenance"
    exit 1
fi

if [[ ! "$FULL_GIT_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    log_error "Packaged build provenance must be a 40-character lowercase Git SHA"
    exit 1
fi

export ORCHARD_BUILD_SHA="$FULL_GIT_SHA"
SHORT_GIT_SHA="${FULL_GIT_SHA:0:7}"
PAYLOAD_BUILD_REF="$SHORT_GIT_SHA"

if ! INITIAL_SOURCE_STATUS="$(source_status)"; then
    log_error "Failed to inspect tracked, staged, and untracked payload inputs"
    exit 1
fi

if [[ -n "$INITIAL_SOURCE_STATUS" ]]; then
    if [[ "$ALLOW_DIRTY" == "true" ]]; then
        log_warn "Uncommitted or untracked build inputs detected - continuing with --allow-dirty"
        PAYLOAD_BUILD_REF="${SHORT_GIT_SHA}-dirty"
    else
        log_error "Uncommitted or untracked build inputs detected"
        printf '%s\n' "$INITIAL_SOURCE_STATUS" >&2
        log_error "Commit changes first, or use --allow-dirty for a development build"
        exit 1
    fi
fi
unset INITIAL_SOURCE_STATUS

# Preflight: Check for port conflicts (warn only)
if lsof -ti :4000 >/dev/null 2>&1 || lsof -ti :50071 >/dev/null 2>&1; then
    log_warn "Dev server ports (4000 or 50071) appear to be in use"
    log_warn "This may indicate a running 'bin/dev' instance"
    log_warn "Port conflicts can cause silent hangs in mix tasks"
    log_warn "Consider stopping dev server before continuing"
    sleep 2
fi

# Get version info using Mix (reliable extraction)
APP_VERSION=$(mix run --no-start -e 'IO.puts(Mix.Project.config()[:version])' 2>/dev/null | tail -1)
if [[ -z "$APP_VERSION" ]] || [[ "$APP_VERSION" == *" "* ]]; then
    log_error "Failed to extract version from mix.exs"
    log_error "Ensure mix is available and project compiles"
    exit 1
fi

validate_captured_source_identity

BUILD_DATE=$(date +%Y%m%d)
PAYLOAD_NAME="Orchard-${APP_VERSION}-${BUILD_DATE}-${PAYLOAD_BUILD_REF}"
STAGING_BASE="$OUTPUT_DIR/$PAYLOAD_NAME"
EXPECTED_STAGING_ROOT="$STAGING_BASE/$PAYLOAD_ROOT_REL"
KNOWN_BAD_ROOT="$STAGING_BASE/Library Application Support"

log_info "Building Orchard payload"
log_info "  App version: $APP_VERSION"
log_info "  Build SHA: $ORCHARD_BUILD_SHA"
log_info "  Payload build ref: $PAYLOAD_BUILD_REF"
log_info "  Build date: $BUILD_DATE"
log_info "  Build channel: $ORCHARD_BUILD_CHANNEL"
log_info "  Output parent: $OUTPUT_DIR"
if [[ -e "$STAGING_BASE" || -L "$STAGING_BASE" ]]; then
    log_error "Selected staging path already exists: $STAGING_BASE"
    log_error "Remove it or choose a different output directory."
    exit 1
fi

# Ensure output directory exists early (fail fast)
if ! mkdir -p "$OUTPUT_DIR"; then
    log_error "Failed to create output directory: $OUTPUT_DIR"
    exit 1
fi

log_info "Validating packaging source provenance..."
validate_packaging_source_provenance

# Clean build artifacts if requested
if [[ "$DO_CLEAN" == "true" ]]; then
    log_info "Deep clean requested - removing _build and deps..."
    rm -rf "$REPO_ROOT/_build" "$REPO_ROOT/deps"
fi

sync_packaging_venv() {
    local helper_dir="$1"
    shift

    cd "$REPO_ROOT/native/$helper_dir"
    rm -rf .venv-pkg
    if ! UV_PROJECT_ENVIRONMENT=".venv-pkg" uv sync --locked --no-editable "$@"; then
        log_error "uv sync --locked failed for native/$helper_dir; refresh uv.lock with 'cd native/$helper_dir && uv lock' if your branch touched dependencies, then rerun."
        exit 1
    fi
}

# Pre-build: Setup Python venvs
log_info "Setting up packaging Python venvs..."
sync_packaging_venv "orchard_tokenizer"
sync_packaging_venv "orchard_worker_mlx" --extra mlx

# Verify native executables exist and are executable (fail if missing)
log_info "Verifying native executables..."
NATIVE_BINS=(
    "$REPO_ROOT/native/orchard_tokenizer/bin/orchard-tokenizer"
    "$REPO_ROOT/native/orchard_worker_mlx/bin/orchard-worker-mlx"
    "$REPO_ROOT/native/orchard_tokenizer/.venv-pkg/bin/orchard-tokenizer"
    "$REPO_ROOT/native/orchard_worker_mlx/.venv-pkg/bin/orchard-worker-mlx"
)
for native_bin in "${NATIVE_BINS[@]}"; do
    if [[ ! -f "$native_bin" ]]; then
        log_error "Missing native executable: $native_bin"
        log_error "Ensure packaging uv sync completed successfully in native directories"
        exit 1
    fi
    if [[ ! -x "$native_bin" ]]; then
        log_warn "Fixing permissions on $native_bin (was not executable)"
        chmod 755 "$native_bin"
    fi
done

# Clean previous release builds
log_info "Cleaning previous release builds..."
cd "$REPO_ROOT"
rm -rf _build/prod/rel/orchard_{controller,node_agent,cli} _build/prod/lib/orchard_shared

log_info "Fetching Elixir dependencies..."
mix deps.get

log_info "Installing pinned asset dependencies..."
cd "$REPO_ROOT/apps/orchard_controller"
MIX_ENV=prod mix assets.setup

log_info "Building assets (controller app)..."
MIX_ENV=prod mix assets.deploy
cd "$REPO_ROOT"

# Build releases
log_info "Building Elixir releases..."

log_info "Building macOS native helpers for orchard_cli"
"$REPO_ROOT/scripts/build-macos-native-helpers.sh" \
    --output "$REPO_ROOT/_build/prod/lib/orchard_cli/priv"

log_info "  → orchard_controller"
mix release orchard_controller
validate_controller_release_independence

log_info "  → orchard_node_agent"
mix release orchard_node_agent

log_info "  → orchard_cli"
mix release orchard_cli

validate_captured_source_identity

# Create staging directory
log_info "Creating payload staging..."
STAGING="$EXPECTED_STAGING_ROOT"
mkdir -p "$STAGING"/{releases,native,share/{bin,launchd},config,logs,support/openssl}
STAGING_CREATED=true

# Copy releases
log_info "Copying releases to staging..."
copy_tree_without_metadata "$REPO_ROOT/_build/prod/rel/orchard_controller" "$STAGING/releases/"
copy_tree_without_metadata "$REPO_ROOT/_build/prod/rel/orchard_node_agent" "$STAGING/releases/"
copy_tree_without_metadata "$REPO_ROOT/_build/prod/rel/orchard_cli" "$STAGING/releases/"

log_info "Excluding debug-symbol bundles from staged runtime releases..."
find -P "$STAGING/releases" -type d -name '*.dSYM' -prune -exec rm -rf {} +

log_info "Remediating OTP OpenSSL Mach-O closure..."
OPENSSL_PROVENANCE="$STAGING_BASE.openssl-provenance.txt"
if ! "$REPO_ROOT/scripts/remediate-otp-openssl-closure.sh" --provenance-output "$OPENSSL_PROVENANCE" "$STAGING"; then
    log_error "OTP OpenSSL closure remediation failed"
    exit 1
fi
if [[ -f "$OPENSSL_PROVENANCE" ]]; then
    log_info "   OpenSSL provenance: $OPENSSL_PROVENANCE"
fi

stage_packaging_venv() {
    local helper_dir="$1"
    local staged_helper="$STAGING/native/$helper_dir"
    local entrypoint

    rm -rf "$staged_helper/.venv"
    if [[ ! -d "$staged_helper/.venv-pkg" ]]; then
        log_error "Missing staged packaging venv: $staged_helper/.venv-pkg"
        exit 1
    fi
    mv "$staged_helper/.venv-pkg" "$staged_helper/.venv"

    case "$helper_dir" in
        orchard_tokenizer) entrypoint="$staged_helper/.venv/bin/orchard-tokenizer" ;;
        orchard_worker_mlx) entrypoint="$staged_helper/.venv/bin/orchard-worker-mlx" ;;
        *)
            log_error "Unknown native helper for staged entrypoint validation: $helper_dir"
            exit 1
            ;;
    esac

    if [[ ! -x "$entrypoint" ]]; then
        log_error "Missing executable staged native entrypoint: $entrypoint"
        exit 1
    fi
}

assert_no_staged_native_sources() {
    local disallowed_paths=(
        "native/orchard_tokenizer/src"
        "native/orchard_tokenizer/tests"
        "native/orchard_worker_mlx/src"
        "native/orchard_worker_mlx/tests"
        "native/orchard_worker_mlx/proto"
    )
    local rel_path
    local status=0

    for rel_path in "${disallowed_paths[@]}"; do
        if [[ -e "$STAGING/$rel_path" ]]; then
            log_error "Duplicate native helper source path staged: $rel_path"
            status=1
        fi
    done

    return "$status"
}

# Copy native components
log_info "Copying native components..."
copy_packaging_venv_only "$REPO_ROOT/native/orchard_tokenizer" "$STAGING/native"
stage_packaging_venv "orchard_tokenizer"
copy_packaging_venv_only "$REPO_ROOT/native/orchard_worker_mlx" "$STAGING/native"
stage_packaging_venv "orchard_worker_mlx"
if ! assert_no_staged_native_sources; then
    log_error "Native helper source deterrence guard failed"
    exit 1
fi

log_info "Materializing staged Python venv interpreters..."
if ! COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 "$REPO_ROOT/scripts/materialize-staged-venv-interpreters.sh" "$STAGING/native"; then
    log_error "Failed to materialize staged Python venv interpreters"
    exit 1
fi
if ! "$REPO_ROOT/scripts/verify-staged-venv-closure.sh" --forbid-path "$REPO_ROOT" "$STAGING_BASE"; then
    log_error "Staged native payload closure verification failed"
    exit 1
fi

# Copy wrapper scripts. The managed Postgres wrapper is an operator-safe guard;
# the managed Postgres LaunchDaemon remains excluded until Managed Database Mode
# ships.
log_info "Copying wrapper scripts..."
WRAPPER_SCRIPTS=(
    "orchard-controller"
    "orchard-node-agent"
    "orchardctl"
    "orchard-managed-postgres"
)
for script in "${WRAPPER_SCRIPTS[@]}"; do
    script_path="$REPO_ROOT/packaging/payload/bin/$script"
    if [[ -f "$script_path" ]]; then
        copy_file_without_metadata "$script_path" "$STAGING/share/bin/"
    else
        log_error "Missing wrapper script: $script"
        exit 1
    fi
done

# Copy launchd plists (explicit whitelist; exclude managed Postgres service
# until Managed Database Mode ships)
log_info "Copying launchd plists..."
PLIST_FILES=(
    "com.orchard.controller.plist"
    "com.orchard.node-agent.plist"
)
for plist in "${PLIST_FILES[@]}"; do
    plist_path="$REPO_ROOT/packaging/launchd/$plist"
    if [[ -f "$plist_path" ]]; then
        copy_file_without_metadata "$plist_path" "$STAGING/share/launchd/"
    else
        log_error "Missing launchd plist: $plist"
        exit 1
    fi
done
# Note: com.orchard.postgres.plist is excluded (managed Postgres is not
# available in this build)

log_info "Scrubbing macOS metadata from staging payload..."
scrub_macos_metadata "$STAGING_BASE"

log_info "Validating staging layout..."
validate_staging_layout

SIGNING_MANIFEST_TMP=""
PAYLOAD_SIGNING_IDENTITY="$(printf '%s' "${ORCHARD_PAYLOAD_SIGNING_IDENTITY:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if [[ -n "$PAYLOAD_SIGNING_IDENTITY" ]]; then
    log_info "Signing nested Mach-O payload binaries..."
    discard_payload_keychain_env
    SIGNING_MANIFEST_TMP="$STAGING_BASE.signing-manifest.txt"
    run_payload_signer --manifest-output "$SIGNING_MANIFEST_TMP" "$STAGING_BASE"
else
    log_warn "ORCHARD_PAYLOAD_SIGNING_IDENTITY not set - payload Mach-O binaries will remain unsigned."
fi

log_info "Scrubbing macOS metadata after payload signing window..."
scrub_macos_metadata "$STAGING_BASE"

log_info "Verifying whole-payload Mach-O dependency closure..."
if ! "$REPO_ROOT/scripts/verify-staged-venv-closure.sh" --no-smoke --forbid-path "$REPO_ROOT" "$STAGING_BASE"; then
    log_error "Whole-payload Mach-O dependency closure verification failed"
    exit 1
fi

if [[ -n "$PAYLOAD_SIGNING_IDENTITY" ]]; then
    log_info "Verifying payload signatures after metadata scrub..."
    if ! run_payload_verifier --identity "$PAYLOAD_SIGNING_IDENTITY" "$STAGING_BASE"; then
        log_error "Payload signature verification failed after metadata scrub"
        exit 1
    fi
    PAYLOAD_KEYCHAIN_PASSWORD=""
    PAYLOAD_KEYCHAIN_PASSWORD_CONFIGURED=false
fi

find "$STAGING_BASE" -type d -exec chmod 755 {} \;
find "$STAGING/share/launchd" -type f -exec chmod 644 {} \;
find "$STAGING/share/bin" -type f -exec chmod 755 {} \;

if ! validate_captured_source_identity; then
    rm -rf "$STAGING_BASE"
    STAGING_CREATED=false
    log_error "Removed staged payload after source identity changed"
    exit 1
fi

printf 'PAYLOAD_ROOT=%s\n' "$EXPECTED_STAGING_ROOT"
log_info "Payload build complete; preserved staging directory: $STAGING_BASE"
BUILD_SUCCEEDED=true
exit 0
