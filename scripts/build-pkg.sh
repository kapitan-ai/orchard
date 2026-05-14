#!/bin/bash
#
# Build Orchard PKG installer
# Usage: ./scripts/build-pkg.sh [--allow-dirty] [--clean] [--stage-only] [output_dir]
#
# Options:
#   --allow-dirty    Allow building with uncommitted changes (marks PKG as -dirty)
#   --clean          Deep clean: removes _build/ and deps/ before building
#   --stage-only     Stop after staging, venv closure verification, and optional payload signing
#   output_dir       Destination directory (default: ./artifacts/pkg-builds/YYYY-MM-DD)
#
# Outputs: unsigned generic Orchard-<app_version>-<YYYYMMDD>-<git_sha7>.pkg
#
# Signing and notarization are intentionally separate. Set
# ORCHARD_PAYLOAD_SIGNING_IDENTITY before this build to sign nested Mach-O
# payloads, then use scripts/sign-pkg.sh with an explicit Developer ID Installer
# identity and notarytool profile.
#
# Examples:
#   ./scripts/build-pkg.sh                                    # Standard build
#   ./scripts/build-pkg.sh --clean                          # Clean build
#   ./scripts/build-pkg.sh --stage-only /tmp/stage-output   # Stage and preserve payload tree
#   ./scripts/build-pkg.sh --allow-dirty /tmp               # Build with uncommitted changes
#   ./scripts/build-pkg.sh /path/to/output                  # Custom output directory
#

set -euo pipefail

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
STAGE_ONLY=false
OUTPUT_DIR=""

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
        --stage-only)
            STAGE_ONLY=true
            shift
            ;;
        -*)
            log_error "Unknown option: $1"
            echo "Usage: $0 [--allow-dirty] [--clean] [--stage-only] [output_dir]"
            exit 1
            ;;
        *)
            OUTPUT_DIR="$1"
            shift
            ;;
    esac
done

# Configuration
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$REPO_ROOT/artifacts/pkg-builds/$(date +%Y-%m-%d)"
fi
if [[ -n "${ORCHARD_PKG_STAGING_BASE:-}" ]]; then
    case "$ORCHARD_PKG_STAGING_BASE" in
        /*) STAGING_BASE="$ORCHARD_PKG_STAGING_BASE" ;;
        *) STAGING_BASE="$REPO_ROOT/$ORCHARD_PKG_STAGING_BASE" ;;
    esac
else
    STAGING_BASE="/tmp/orchard-pkg-build-$$"
fi
PAYLOAD_ROOT_REL="Library/Application Support/Orchard"
EXPECTED_STAGING_ROOT="$STAGING_BASE/$PAYLOAD_ROOT_REL"
KNOWN_BAD_ROOT="$STAGING_BASE/Library Application Support"
STAGING_CREATED=false

# Enhanced error trap
trap 'log_error "Build failed at line $LINENO"' ERR

cleanup() {
    if [[ "$STAGE_ONLY" == "true" ]]; then
        return
    fi

    if [[ -n "${SIGNING_MANIFEST_TMP:-}" ]]; then
        rm -f "$SIGNING_MANIFEST_TMP"
    fi

    if [[ "$STAGING_CREATED" == "true" && -d "$STAGING_BASE" ]]; then
        log_info "Cleaning up staging directory..."
        rm -rf "$STAGING_BASE"
    fi
}
trap cleanup EXIT

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
                if [[ -n "$attrs" ]]; then
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
            if [[ -n "$attrs" ]]; then
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

validate_packaging_source_provenance() {
    assert_clean_provenance "packaging wrappers" "$REPO_ROOT/packaging/pkg/bin"
    assert_clean_provenance "launchd plists" "$REPO_ROOT/packaging/launchd"
    assert_clean_provenance "package scripts" "$REPO_ROOT/packaging/pkg/scripts"
    assert_clean_provenance "payload entitlements" "$REPO_ROOT/packaging/pkg/entitlements"
}

copy_file_without_metadata() {
    COPYFILE_DISABLE=1 cp -X "$1" "$2"
}

copy_tree_without_metadata() {
    COPYFILE_DISABLE=1 cp -X -R "$1" "$2"
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
            [[ -z "$attrs" ]] && continue
            if ! xattr -c -s "$path"; then
                log_error "Failed to scrub symlink extended attributes for: $path"
                status=1
            fi
            continue
        fi

        if ! attrs="$(xattr "$path" 2>&1)"; then
            log_error "Failed to inspect extended attributes for: $path"
            printf '%s\n' "$attrs" >&2
            status=1
            continue
        fi
        [[ -z "$attrs" ]] && continue

        mode="$(stat -f '%Lp' "$path" 2>/dev/null || true)"
        if [[ -n "$mode" && ! -w "$path" ]]; then
            printf '%s\t%s\n' "$mode" "$path" >>"$restore_file"
            if ! chmod u+w "$path"; then
                log_error "Failed to make staged path temporarily writable for xattr scrub: $path"
                status=1
                continue
            fi
        fi

        if ! xattr -c "$path"; then
            log_error "Failed to scrub extended attributes for: $path"
            status=1
        fi
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

validate_staging_layout() {
    local required_paths=(
        "share/bin/orchardctl"
        "share/bin/orchard-controller"
        "share/bin/orchard-node-agent"
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

validate_expanded_pkg_provenance() {
    local pkg_path="$1"
    local label="$2"
    local expanded_parent
    local expanded_dir

    expanded_parent="$(mktemp -d "${TMPDIR:-/tmp}/orchard-expanded-pkg.XXXXXX")"
    expanded_dir="$expanded_parent/expanded"
    if ! pkgutil --expand-full "$pkg_path" "$expanded_dir"; then
        rm -rf "$expanded_parent"
        log_error "Failed to expand PKG for provenance inspection: $pkg_path"
        return 1
    fi

    if ! assert_clean_provenance "$label expanded package" "$expanded_dir"; then
        rm -rf "$expanded_parent"
        return 1
    fi

    rm -rf "$expanded_parent"
}

run_pkgbuild_scratch_preflight() {
    local scratch_dir
    local scratch_root
    local scratch_pkg
    local scratch_file

    scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/orchard-pkgbuild-preflight.XXXXXX")"
    scratch_root="$scratch_dir/root"
    scratch_pkg="$scratch_dir/scratch.pkg"
    scratch_file="$scratch_root/$PAYLOAD_ROOT_REL/support/.pkgbuild-provenance-preflight"

    mkdir -p "$(dirname "$scratch_file")"
    printf 'Orchard pkgbuild provenance preflight\n' >"$scratch_file"

    if ! assert_clean_provenance "scratch pkgbuild input" "$scratch_root"; then
        rm -rf "$scratch_dir"
        log_error "Scratch pkgbuild provenance preflight failed"
        return 1
    fi

    if ! COPYFILE_DISABLE=1 pkgbuild \
        --root "$scratch_root" \
        --scripts "$REPO_ROOT/packaging/pkg/scripts" \
        --identifier com.orchard.pkg.preflight \
        --version "$APP_VERSION" \
        --install-location / \
        "$scratch_pkg"; then
        rm -rf "$scratch_dir"
        log_error "Scratch pkgbuild provenance preflight failed"
        return 1
    fi

    if ! validate_expanded_pkg_provenance "$scratch_pkg" "scratch pkgbuild preflight"; then
        rm -rf "$scratch_dir"
        log_error "Scratch pkgbuild provenance preflight failed"
        return 1
    fi

    rm -rf "$scratch_dir"
}

validate_pkg_payload() {
    local pkg_path="$1"
    local payload_files
    local required_entries=(
        "./Library/Application Support/Orchard/share/bin/orchardctl"
        "./Library/Application Support/Orchard/share/bin/orchard-controller"
        "./Library/Application Support/Orchard/share/bin/orchard-node-agent"
        "./Library/Application Support/Orchard/share/launchd/com.orchard.controller.plist"
        "./Library/Application Support/Orchard/share/launchd/com.orchard.node-agent.plist"
        "./Library/Application Support/Orchard/releases/orchard_cli/bin/orchard_cli"
        "./Library/Application Support/Orchard/releases/orchard_controller/bin/orchard_controller"
        "./Library/Application Support/Orchard/releases/orchard_node_agent/bin/orchard_node_agent"
    )
    local entry

    payload_files="$(pkgutil --payload-files "$pkg_path")"

    if grep -Fq "Library Application Support/" <<<"$payload_files"; then
        log_error "Malformed payload root detected in PKG: Library Application Support/"
        return 1
    fi

    if grep -Eq '(^|/)\._[^/]*$|(^|/)\.DS_Store$' <<<"$payload_files"; then
        log_error "macOS metadata sidecar files detected in PKG payload"
        grep -E '(^|/)\._[^/]*$|(^|/)\.DS_Store$' <<<"$payload_files" >&2
        return 1
    fi

    for entry in "${required_entries[@]}"; do
        if ! grep -Fqx "$entry" <<<"$payload_files"; then
            log_error "Missing payload entry in PKG: $entry"
            return 1
        fi
    done

    validate_expanded_pkg_provenance "$pkg_path" "unsigned PKG"
}


cd "$REPO_ROOT"

export MIX_ENV=prod

if [[ -z "${ORCHARD_BUILD_CHANNEL+x}" ]]; then
    ORCHARD_BUILD_CHANNEL="trial"
else
    ORCHARD_BUILD_CHANNEL="$(printf '%s' "$ORCHARD_BUILD_CHANNEL" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
fi

if [[ -z "$ORCHARD_BUILD_CHANNEL" ]]; then
    log_error "Distributed PKG builds require ORCHARD_BUILD_CHANNEL to be non-empty"
    log_error "Allowed values: internal, trial, pilot, release"
    log_error "Unset ORCHARD_BUILD_CHANNEL to use the default channel: trial"
    exit 1
fi

case "$ORCHARD_BUILD_CHANNEL" in
    internal|trial|pilot|release)
        export ORCHARD_BUILD_CHANNEL
        ;;
    dev)
        log_error "Distributed PKG builds do not support ORCHARD_BUILD_CHANNEL=dev"
        log_error "Allowed values: internal, trial, pilot, release"
        exit 1
        ;;
    *)
        log_error "Invalid ORCHARD_BUILD_CHANNEL: $ORCHARD_BUILD_CHANNEL"
        log_error "Allowed values: internal, trial, pilot, release"
        exit 1
        ;;
esac

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

GIT_SHA=$(git rev-parse --short HEAD)
BUILD_DATE=$(date +%Y%m%d)
PKG_NAME="Orchard-${APP_VERSION}-${BUILD_DATE}-${GIT_SHA}.pkg"

log_info "Building Orchard PKG"
log_info "  App version: $APP_VERSION"
log_info "  Git SHA: $GIT_SHA"
log_info "  Build date: $BUILD_DATE"
log_info "  Build channel: $ORCHARD_BUILD_CHANNEL"
log_info "  Output: $OUTPUT_DIR/$PKG_NAME"
if [[ "$STAGE_ONLY" == "true" ]]; then
    log_info "  Stage only: true"
fi

if [[ -e "$STAGING_BASE" || -L "$STAGING_BASE" ]]; then
    log_error "Selected staging path already exists: $STAGING_BASE"
    log_error "Remove it or choose a different ORCHARD_PKG_STAGING_BASE."
    exit 1
fi

# Ensure output directory exists early (fail fast)
if ! mkdir -p "$OUTPUT_DIR"; then
    log_error "Failed to create output directory: $OUTPUT_DIR"
    exit 1
fi

# Verify clean git state (fail by default)
if ! git diff-index --quiet HEAD --; then
    if [[ "$ALLOW_DIRTY" == "true" ]]; then
        log_warn "Uncommitted changes detected — continuing with --allow-dirty"
        GIT_SHA="${GIT_SHA}-dirty"
        PKG_NAME="Orchard-${APP_VERSION}-${BUILD_DATE}-${GIT_SHA}.pkg"
        log_warn "Marked as dirty: $PKG_NAME"
    else
        log_error "Uncommitted changes detected in repository"
        log_error "Commit changes first, or use --allow-dirty to override"
        exit 1
    fi
fi

log_info "Validating packaging source provenance..."
validate_packaging_source_provenance

log_info "Running scratch pkgbuild provenance preflight..."
run_pkgbuild_scratch_preflight

# Clean build artifacts if requested
if [[ "$DO_CLEAN" == "true" ]]; then
    log_info "Deep clean requested — removing _build and deps..."
    rm -rf "$REPO_ROOT/_build" "$REPO_ROOT/deps"
fi

# Pre-build: Setup Python venvs
log_info "Setting up Python venvs..."
cd "$REPO_ROOT/native/orchard_tokenizer"
uv sync

cd "$REPO_ROOT/native/orchard_worker_mlx"
uv sync --extra mlx

# Verify native executables exist and are executable (fail if missing)
log_info "Verifying native executables..."
NATIVE_BINS=(
    "$REPO_ROOT/native/orchard_tokenizer/bin/orchard-tokenizer"
    "$REPO_ROOT/native/orchard_worker_mlx/bin/orchard-worker-mlx"
)
for native_bin in "${NATIVE_BINS[@]}"; do
    if [[ ! -f "$native_bin" ]]; then
        log_error "Missing native executable: $native_bin"
        log_error "Ensure 'uv sync' completed successfully in native directories"
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

  # Fetch deps and build assets
  log_info "Fetching Elixir dependencies..."
  mix deps.get
  
  log_info "Building assets (controller app)..."
  cd "$REPO_ROOT/apps/orchard_controller"
  MIX_ENV=prod mix assets.deploy
  cd "$REPO_ROOT"
  
  # Build releases
log_info "Building Elixir releases..."

log_info "  → orchard_controller"
mix release orchard_controller

log_info "  → orchard_node_agent"
mix release orchard_node_agent

log_info "  → orchard_cli"
mix release orchard_cli

# Create staging directory
log_info "Creating PKG staging..."
STAGING="$EXPECTED_STAGING_ROOT"
mkdir -p "$STAGING"/{releases,native,share/{bin,launchd},config,logs,support}
STAGING_CREATED=true

# Copy releases
log_info "Copying releases to staging..."
copy_tree_without_metadata "$REPO_ROOT/_build/prod/rel/orchard_controller" "$STAGING/releases/"
copy_tree_without_metadata "$REPO_ROOT/_build/prod/rel/orchard_node_agent" "$STAGING/releases/"
copy_tree_without_metadata "$REPO_ROOT/_build/prod/rel/orchard_cli" "$STAGING/releases/"

# Copy native components
log_info "Copying native components..."
copy_tree_without_metadata "$REPO_ROOT/native/orchard_tokenizer" "$STAGING/native/"
copy_tree_without_metadata "$REPO_ROOT/native/orchard_worker_mlx" "$STAGING/native/"

log_info "Materializing staged Python venv interpreters..."
if ! COPYFILE_DISABLE=1 "$REPO_ROOT/scripts/materialize-staged-venv-interpreters.sh" "$STAGING/native"; then
    log_error "Failed to materialize staged Python venv interpreters"
    exit 1
fi
if ! "$REPO_ROOT/scripts/verify-staged-venv-closure.sh" "$STAGING_BASE"; then
    log_error "Staged Python venv closure verification failed"
    exit 1
fi

# Copy wrapper scripts (explicit whitelist - exclude managed-postgres until ready)
log_info "Copying wrapper scripts..."
WRAPPER_SCRIPTS=(
    "orchard-controller"
    "orchard-node-agent"
    "orchardctl"
)
for script in "${WRAPPER_SCRIPTS[@]}"; do
    script_path="$REPO_ROOT/packaging/pkg/bin/$script"
    if [[ -f "$script_path" ]]; then
        copy_file_without_metadata "$script_path" "$STAGING/share/bin/"
    else
        log_error "Missing wrapper script: $script"
        exit 1
    fi
done

# Copy launchd plists (explicit whitelist - exclude managed-postgres until ready)
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
# Note: com.orchard.postgres.plist is excluded (managed postgres not yet supported)

log_info "Scrubbing macOS metadata from staging payload..."
scrub_macos_metadata "$STAGING_BASE"

log_info "Validating staging layout..."
validate_staging_layout

SIGNING_MANIFEST_TMP=""
PAYLOAD_SIGNING_IDENTITY="$(printf '%s' "${ORCHARD_PAYLOAD_SIGNING_IDENTITY:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if [[ -n "$PAYLOAD_SIGNING_IDENTITY" ]]; then
    log_info "Signing nested Mach-O payload binaries..."
    if [[ "$STAGE_ONLY" != "true" ]]; then
        SIGNING_MANIFEST_TMP="$OUTPUT_DIR/.${PKG_NAME}.signing-manifest.tmp"
        rm -f "$SIGNING_MANIFEST_TMP"
        ORCHARD_PAYLOAD_SIGNING_IDENTITY="$PAYLOAD_SIGNING_IDENTITY" \
            "$REPO_ROOT/scripts/sign-payload.sh" --manifest-output "$SIGNING_MANIFEST_TMP" "$STAGING_BASE"
    else
        ORCHARD_PAYLOAD_SIGNING_IDENTITY="$PAYLOAD_SIGNING_IDENTITY" \
            "$REPO_ROOT/scripts/sign-payload.sh" "$STAGING_BASE"
    fi
else
    log_warn "ORCHARD_PAYLOAD_SIGNING_IDENTITY not set — payload Mach-O binaries will be unsigned. The resulting PKG cannot be notarized."
fi

log_info "Scrubbing macOS metadata after payload signing window..."
scrub_macos_metadata "$STAGING_BASE"

if [[ -n "$PAYLOAD_SIGNING_IDENTITY" ]]; then
    log_info "Verifying payload signatures after metadata scrub..."
    if ! "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$PAYLOAD_SIGNING_IDENTITY" "$STAGING_BASE"; then
        log_error "Payload signature verification failed after metadata scrub"
        exit 1
    fi
fi

if [[ "$STAGE_ONLY" == "true" ]]; then
    printf 'STAGING_BASE=%s\n' "$STAGING_BASE"
    log_info "Stage-only build complete; preserved staging directory: $STAGING_BASE"
    exit 0
fi

# Set permissions in staging
log_info "Setting staging permissions..."
find "$STAGING_BASE" -type d -exec chmod 755 {} \;
find "$STAGING/share/launchd" -type f -exec chmod 644 {} \;
find "$STAGING/share/bin" -type f -exec chmod 755 {} \;

# Build the PKG
log_info "Building PKG..."
mkdir -p "$OUTPUT_DIR"

COPYFILE_DISABLE=1 pkgbuild \
    --root "$STAGING_BASE" \
    --scripts "$REPO_ROOT/packaging/pkg/scripts" \
    --identifier com.orchard.pkg \
    --version "$APP_VERSION" \
    --install-location / \
    "$OUTPUT_DIR/$PKG_NAME"

# Verify PKG
if [[ -f "$OUTPUT_DIR/$PKG_NAME" ]]; then
    log_info "Validating PKG payload layout..."
    if ! validate_pkg_payload "$OUTPUT_DIR/$PKG_NAME"; then
        rm -f "$OUTPUT_DIR/$PKG_NAME"
        log_error "Removed malformed PKG: $OUTPUT_DIR/$PKG_NAME"
        exit 1
    fi

    PKG_SIZE=$(du -h "$OUTPUT_DIR/$PKG_NAME" | cut -f1)
    log_info "Unsigned PKG built successfully: $PKG_NAME ($PKG_SIZE)"
    log_info "   Location: $OUTPUT_DIR/$PKG_NAME"
    
    # Generate checksum
    PKG_SHA256="$(shasum -a 256 "$OUTPUT_DIR/$PKG_NAME" | awk '{print $1}')"
    printf '%s  %s\n' "$PKG_SHA256" "$PKG_NAME" > "$OUTPUT_DIR/$PKG_NAME.sha256"
    log_info "   Unsigned checksum: $OUTPUT_DIR/$PKG_NAME.sha256"
    if [[ -n "$SIGNING_MANIFEST_TMP" && -f "$SIGNING_MANIFEST_TMP" ]]; then
        SIGNING_MANIFEST="$OUTPUT_DIR/$PKG_NAME.signing-manifest.txt"
        mv "$SIGNING_MANIFEST_TMP" "$SIGNING_MANIFEST"
        log_info "   Payload signing manifest: $SIGNING_MANIFEST"
    fi
else
    log_error "PKG build failed!"
    exit 1
fi

log_info "Build complete!"
echo ""
echo "To test the unsigned PKG locally:"
echo "  sudo installer -pkg \"$OUTPUT_DIR/$PKG_NAME\" -target /"
echo "  sudo orchardctl env init"
echo "  sudo orchardctl start"
echo ""
echo "To sign and notarize for distribution:"
echo "  export ORCHARD_PAYLOAD_SIGNING_IDENTITY='<Developer ID Application identity>'"
echo "  ./scripts/build-pkg.sh [options]"
echo "  scripts/sign-pkg.sh --identity '<Developer ID Installer identity>' --notary-profile '<profile>' --input \"$OUTPUT_DIR/$PKG_NAME\" --output \"$OUTPUT_DIR/${PKG_NAME%.pkg}-signed.pkg\""
