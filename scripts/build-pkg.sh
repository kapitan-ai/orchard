#!/bin/bash
#
# Build Orchard PKG installer
# Usage: ./scripts/build-pkg.sh [--allow-dirty] [--clean] [--stage-only] [output_dir]
#
# Options:
#   --allow-dirty    Allow building with uncommitted changes (marks PKG filename as -dirty)
#   --clean          Deep clean: removes _build/ and deps/ before building
#   --stage-only     Stop after staging, venv closure verification, and optional payload signing
#   output_dir       Destination directory (default: ./artifacts/pkg-builds/YYYY-MM-DD)
#
# Outputs: unsigned generic Orchard-<app_version>-<YYYYMMDD>-<git_sha7>.pkg
#
# Signing and notarization are intentionally separate. Set
# ORCHARD_PAYLOAD_SIGNING_IDENTITY before this build to sign nested Mach-O
# payloads. Optionally set ORCHARD_BUILD_KEYCHAIN and ORCHARD_KEYCHAIN_PASSWORD
# to prepare a dedicated build keychain for unattended payload signing. Then use
# scripts/sign-pkg.sh with an explicit Developer ID Installer identity and
# notarytool profile.
#
# Examples:
#   ./scripts/build-pkg.sh                                    # Standard build
#   ./scripts/build-pkg.sh --clean                          # Clean build
#   ./scripts/build-pkg.sh --stage-only /tmp/stage-output   # Stage and preserve payload tree
#   ./scripts/build-pkg.sh --allow-dirty /tmp               # Build with uncommitted changes
#   ./scripts/build-pkg.sh /path/to/output                  # Custom output directory
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
BUILD_SUCCEEDED=false

# Enhanced error trap
trap 'log_error "Build failed at line $LINENO"' ERR

cleanup_packaging_venvs() {
    rm -rf \
        "$REPO_ROOT/native/orchard_tokenizer/.venv-pkg" \
        "$REPO_ROOT/native/orchard_worker_mlx/.venv-pkg"
}

cleanup() {
    if [[ "$BUILD_SUCCEEDED" == "true" ]]; then
        cleanup_packaging_venvs
    fi

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

cleanup_pkg_outputs() {
    local pkg_path="$1"
    local manifest_path="${pkg_path}.signing-manifest.txt"
    local tmp_manifest_path
    tmp_manifest_path="$(dirname "$pkg_path")/.${pkg_path##*/}.signing-manifest.tmp"

    rm -f "$pkg_path" "${pkg_path}.sha256" "$manifest_path" "$tmp_manifest_path"
}

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
    assert_no_source_sidecars "packaging wrappers" "$REPO_ROOT/packaging/pkg/bin" || return 1
    assert_no_source_sidecars "launchd plists" "$REPO_ROOT/packaging/launchd" || return 1
    assert_no_source_sidecars "package scripts" "$REPO_ROOT/packaging/pkg/scripts" || return 1
    assert_no_source_sidecars "payload entitlements" "$REPO_ROOT/packaging/pkg/entitlements" || return 1
}

require_packaging_runtime_tools() {
    if ! command -v perl >/dev/null 2>&1; then
        log_error "perl is required for PKG payload metadata repair and validation"
        return 69
    fi
    if ! perl -e 'exit 0' >/dev/null 2>&1; then
        log_error "perl failed a basic execution check"
        return 69
    fi
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

pkgbuild_without_metadata() {
    COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 pkgbuild --ownership recommended "$@"
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

    if ! "$REPO_ROOT/scripts/verify-staged-venv-closure.sh" --forbid-path "$REPO_ROOT" "$expanded_dir"; then
        rm -rf "$expanded_parent"
        log_error "Mach-O dependency closure failed for $label expanded package"
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

    if ! scrub_macos_metadata "$scratch_root"; then
        rm -rf "$scratch_dir"
        log_error "Scratch pkgbuild provenance preflight failed"
        return 1
    fi

    if ! assert_clean_provenance "scratch pkgbuild input" "$scratch_root"; then
        rm -rf "$scratch_dir"
        log_error "Scratch pkgbuild provenance preflight failed"
        return 1
    fi

    if ! pkgbuild_without_metadata \
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

pkg_payload_metadata_sidecar() {
    local entry="$1"
    local normalized
    local basename

    normalized="${entry#./}"
    normalized="${normalized%/}"
    basename="${normalized##*/}"

    [[ "$basename" == ".DS_Store" || "$basename" == ._* ]]
}

collect_pkg_payload_metadata_sidecars() {
    local pkg_path="$1"
    local output_file="$2"
    local entries_file
    local entry

    entries_file="$(mktemp "${TMPDIR:-/tmp}/orchard-payload-entries.XXXXXX")"
    if ! pkgutil --payload-files "$pkg_path" >"$entries_file"; then
        rm -f "$entries_file"
        return 1
    fi

    : >"$output_file"
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        if pkg_payload_metadata_sidecar "$entry"; then
            printf '%s\n' "$entry" >>"$output_file"
        fi
    done <"$entries_file"
    rm -f "$entries_file"
}

filter_payload_archive_preserving_headers() {
    local source_payload="$1"
    local skip_file="$2"
    local repaired_payload="$3"
    local repaired_raw

    repaired_raw="$(mktemp "${TMPDIR:-/tmp}/orchard-payload-repaired.XXXXXX")"

    if ! perl - "$skip_file" "$source_payload" "$repaired_raw" <<'PERL'
use strict;
use warnings;

my ($skip_file, $payload, $out_path) = @ARGV;
my %skip;
open my $skip_fh, '<', $skip_file or die "open skip list: $!\n";
while (my $entry = <$skip_fh>) {
    chomp $entry;
    next if $entry eq '';
    $entry =~ s{^\./}{};
    $entry =~ s{/\z}{};
    $skip{$entry} = 1;
    $skip{"./$entry"} = 1;
}
close $skip_fh or die "close skip list: $!\n";

sub read_exact {
    my ($fh, $length) = @_;
    return '' if $length == 0;
    my $buffer = '';
    while (length($buffer) < $length) {
        my $chunk = '';
        my $read = sysread($fh, $chunk, $length - length($buffer));
        die "read payload: $!\n" unless defined $read;
        return undef if $read == 0 && length($buffer) == 0;
        die "truncated cpio payload\n" if $read == 0;
        $buffer .= $chunk;
    }
    return $buffer;
}

sub should_skip {
    my ($name) = @_;
    my $normalized = $name;
    $normalized =~ s{^\./}{};
    $normalized =~ s{/\z}{};
    return 1 if $skip{$name} || $skip{$normalized} || $skip{"./$normalized"};
    my ($base) = $normalized =~ m{([^/]+)\z};
    return 0 unless defined $base;
    return $base eq '.DS_Store' || $base =~ /^\._/;
}

sub octal_value {
    my ($value) = @_;
    $value =~ s/\0//g;
    $value =~ s/\s+//g;
    die "invalid odc numeric field\n" unless $value =~ /^[0-7]+\z/;
    return oct($value);
}

sub hex_value {
    my ($value) = @_;
    die "invalid newc numeric field\n" unless $value =~ /^[0-9A-Fa-f]{8}\z/;
    return hex($value);
}

open my $in, '-|', 'gzip', '-dc', $payload or die "gzip -dc $payload: $!\n";
open my $out, '>', $out_path or die "open repaired payload: $!\n";
my $removed = 0;
my $records = 0;
my $saw_trailer = 0;

while (1) {
    my $magic = read_exact($in, 6);
    last unless defined $magic;
    my ($record, $name);

    if ($magic eq '070707') {
        my $rest = read_exact($in, 70);
        die "truncated odc header\n" unless defined $rest;
        my $header = $magic . $rest;
        my $name_size = octal_value(substr($header, 59, 6));
        my $file_size = octal_value(substr($header, 65, 11));
        my $name_block = read_exact($in, $name_size);
        die "truncated odc name\n" unless defined $name_block;
        $name = $name_block;
        $name =~ s/\0\z//;
        my $data = read_exact($in, $file_size);
        die "truncated odc data\n" unless defined $data;
        $record = $header . $name_block . $data;
    } elsif ($magic eq '070701' || $magic eq '070702') {
        my $rest = read_exact($in, 104);
        die "truncated newc header\n" unless defined $rest;
        my $header = $magic . $rest;
        my $file_size = hex_value(substr($header, 54, 8));
        my $name_size = hex_value(substr($header, 94, 8));
        my $name_block = read_exact($in, $name_size);
        die "truncated newc name\n" unless defined $name_block;
        $name = $name_block;
        $name =~ s/\0\z//;
        my $name_pad_size = (4 - ((110 + $name_size) % 4)) % 4;
        my $name_pad = read_exact($in, $name_pad_size);
        die "truncated newc name padding\n" unless defined $name_pad;
        my $data = read_exact($in, $file_size);
        die "truncated newc data\n" unless defined $data;
        my $data_pad_size = (4 - ($file_size % 4)) % 4;
        my $data_pad = read_exact($in, $data_pad_size);
        die "truncated newc data padding\n" unless defined $data_pad;
        $record = $header . $name_block . $name_pad . $data . $data_pad;
    } else {
        die "unsupported cpio payload format magic: $magic\n";
    }

    $records++;
    if (should_skip($name)) {
        $removed++;
    } else {
        print {$out} $record or die "write repaired payload: $!\n";
    }
    if ($name eq 'TRAILER!!!') {
        $saw_trailer = 1;
        last;
    }
}

close $out or die "close repaired payload: $!\n";
close $in or die "close gzip reader failed\n";
die "cpio payload contained no records\n" if $records == 0;
die "cpio payload missing TRAILER!!! record\n" unless $saw_trailer;
die "no metadata sidecar records were removed from payload\n" if keys(%skip) && $removed == 0;
PERL
    then
        rm -f "$repaired_raw"
        log_error "Failed to filter PKG Payload while preserving archive metadata"
        return 1
    fi

    if ! gzip -n -c "$repaired_raw" >"$repaired_payload"; then
        rm -f "$repaired_raw"
        log_error "Failed to recompress repaired PKG Payload"
        return 1
    fi
    rm -f "$repaired_raw"
}

filter_bom_preserving_metadata() {
    local source_bom="$1"
    local skip_file="$2"
    local repaired_bom="$3"
    local bom_listing
    local filtered_listing

    bom_listing="$(mktemp "${TMPDIR:-/tmp}/orchard-bom-listing.XXXXXX")"
    filtered_listing="$(mktemp "${TMPDIR:-/tmp}/orchard-bom-filtered.XXXXXX")"

    if ! lsbom "$source_bom" >"$bom_listing"; then
        rm -f "$bom_listing" "$filtered_listing"
        log_error "Failed to list original PKG Bom metadata"
        return 1
    fi

    if ! perl - "$skip_file" "$bom_listing" "$filtered_listing" <<'PERL'
use strict;
use warnings;
my ($skip_file, $listing, $out_path) = @ARGV;
my %skip;
open my $skip_fh, '<', $skip_file or die "open skip list: $!\n";
while (my $entry = <$skip_fh>) {
    chomp $entry;
    next if $entry eq '';
    $entry =~ s{^\./}{};
    $entry =~ s{/\z}{};
    $skip{$entry} = 1;
    $skip{"./$entry"} = 1;
}
close $skip_fh or die "close skip list: $!\n";
open my $in, '<', $listing or die "open bom listing: $!\n";
open my $out, '>', $out_path or die "open filtered bom listing: $!\n";
my $removed = 0;
while (my $line = <$in>) {
    my ($path) = split /\t/, $line, 2;
    chomp $path if defined $path;
    my $normalized = defined($path) ? $path : '';
    $normalized =~ s{^\./}{};
    $normalized =~ s{/\z}{};
    my ($base) = $normalized =~ m{([^/]+)\z};
    if ($skip{$path // ''} || $skip{$normalized} || $skip{"./$normalized"} ||
        (defined($base) && ($base eq '.DS_Store' || $base =~ /^\._/))) {
        $removed++;
        next;
    }
    print {$out} $line or die "write filtered bom listing: $!\n";
}
close $out or die "close filtered bom listing: $!\n";
close $in or die "close bom listing: $!\n";
die "no metadata sidecar records were removed from Bom\n" if keys(%skip) && $removed == 0;
PERL
    then
        rm -f "$bom_listing" "$filtered_listing"
        log_error "Failed to filter original PKG Bom metadata"
        return 1
    fi

    if ! mkbom -i "$filtered_listing" "$repaired_bom"; then
        rm -f "$bom_listing" "$filtered_listing"
        log_error "Failed to rebuild PKG Bom from filtered original metadata"
        return 1
    fi

    rm -f "$bom_listing" "$filtered_listing"
}

package_info_payload_values() {
    local package_info="$1"

    perl -0ne '
        if (/<payload\b([^>]*)>/s) {
            my $attrs = $1;
            my ($files) = $attrs =~ /\bnumberOfFiles="([^"]*)"/;
            my ($kb) = $attrs =~ /\binstallKBytes="([^"]*)"/;
            exit 3 unless defined $files && defined $kb;
            print "$files\t$kb\n";
            exit 0;
        }
        exit 2;
    ' "$package_info"
}

rewrite_package_info_payload_attrs() {
    local package_info="$1"
    local number_of_files="$2"
    local install_kbytes="$3"

    if ! perl -0pi -e '
        BEGIN { ($files, $kb) = @ARGV; @ARGV = @ARGV[2..$#ARGV]; }
        die "PackageInfo has no payload element\n" unless /<payload\b[^>]*>/s;
        die "PackageInfo payload has no numberOfFiles\n" unless /<payload\b[^>]*\bnumberOfFiles="[^"]*"/s;
        die "PackageInfo payload has no installKBytes\n" unless /<payload\b[^>]*\binstallKBytes="[^"]*"/s;
        s/(<payload\b[^>]*\bnumberOfFiles=")[^"]*(")/$1$files$2/s;
        s/(<payload\b[^>]*\binstallKBytes=")[^"]*(")/$1$kb$2/s;
    ' "$number_of_files" "$install_kbytes" "$package_info"; then
        log_error "Failed to rewrite PackageInfo payload metadata"
        return 1
    fi
}

compute_expanded_payload_install_kbytes() {
    local pkg_path="$1"
    local expanded_parent
    local expanded_dir
    local install_kbytes

    expanded_parent="$(mktemp -d "${TMPDIR:-/tmp}/orchard-pkg-size.XXXXXX")"
    expanded_dir="$expanded_parent/expanded-full"

    if ! pkgutil --expand-full "$pkg_path" "$expanded_dir"; then
        rm -rf "$expanded_parent"
        log_error "Failed to expand PKG while computing PackageInfo installKBytes"
        return 1
    fi
    if [[ ! -d "$expanded_dir/Payload" ]]; then
        rm -rf "$expanded_parent"
        log_error "Expanded PKG is missing Payload directory for installKBytes validation"
        return 1
    fi

    install_kbytes="$(du -sk "$expanded_dir/Payload" | awk '{print $1}')"
    rm -rf "$expanded_parent"
    printf '%s\n' "$install_kbytes"
}

update_package_info_from_pkg_payload() {
    local expanded_dir="$1"
    local candidate_pkg="$2"
    local number_of_files
    local install_kbytes

    number_of_files="$(pkgutil --payload-files "$candidate_pkg" | sed '/^[[:space:]]*$/d' | wc -l | tr -d '[:space:]')"
    if ! install_kbytes="$(compute_expanded_payload_install_kbytes "$candidate_pkg")"; then
        return 1
    fi
    rewrite_package_info_payload_attrs "$expanded_dir/PackageInfo" "$number_of_files" "$install_kbytes"
}

repair_pkg_payload_metadata() {
    local pkg_path="$1"
    local repair_parent
    local expanded_dir
    local repaired_pkg
    local candidate_pkg
    local sidecars_file
    local sidecar_count
    local repaired_bom
    local repaired_payload

    repair_parent="$(mktemp -d "${TMPDIR:-/tmp}/orchard-pkg-repair.XXXXXX")"
    expanded_dir="$repair_parent/expanded"
    repaired_pkg="$repair_parent/repaired.pkg"
    candidate_pkg="$repair_parent/candidate.pkg"
    sidecars_file="$repair_parent/payload-sidecars.txt"
    repaired_bom="$expanded_dir/Bom.repaired"
    repaired_payload="$expanded_dir/Payload.repaired"

    if ! collect_pkg_payload_metadata_sidecars "$pkg_path" "$sidecars_file"; then
        rm -rf "$repair_parent"
        log_error "Failed to inspect PKG payload entries for metadata sidecars: $pkg_path"
        return 1
    fi
    sidecar_count="$(wc -l <"$sidecars_file" | tr -d '[:space:]')"
    if [[ "${sidecar_count:-0}" -eq 0 ]]; then
        rm -rf "$repair_parent"
        log_info "PKG payload metadata repair not needed"
        return 0
    fi

    log_warn "Repairing PKG by filtering $sidecar_count macOS metadata sidecar payload entries"
    if ! pkgutil --expand "$pkg_path" "$expanded_dir"; then
        rm -rf "$repair_parent"
        log_error "Failed to expand PKG for payload metadata repair: $pkg_path"
        return 1
    fi

    if [[ ! -f "$expanded_dir/Bom" || ! -f "$expanded_dir/Payload" || ! -f "$expanded_dir/PackageInfo" ]]; then
        rm -rf "$repair_parent"
        log_error "Expanded PKG is missing Bom, Payload, or PackageInfo for metadata repair"
        return 1
    fi

    if ! filter_bom_preserving_metadata "$expanded_dir/Bom" "$sidecars_file" "$repaired_bom"; then
        rm -rf "$repair_parent"
        return 1
    fi
    if ! mv "$repaired_bom" "$expanded_dir/Bom"; then
        rm -rf "$repair_parent"
        log_error "Failed to replace repaired PKG Bom: $pkg_path"
        return 1
    fi

    if ! filter_payload_archive_preserving_headers "$expanded_dir/Payload" "$sidecars_file" "$repaired_payload"; then
        rm -rf "$repair_parent"
        return 1
    fi
    if ! mv "$repaired_payload" "$expanded_dir/Payload"; then
        rm -rf "$repair_parent"
        log_error "Failed to replace repaired PKG Payload: $pkg_path"
        return 1
    fi

    if ! pkgutil --flatten "$expanded_dir" "$candidate_pkg"; then
        rm -rf "$repair_parent"
        log_error "Failed to flatten candidate repaired PKG: $pkg_path"
        return 1
    fi

    if ! update_package_info_from_pkg_payload "$expanded_dir" "$candidate_pkg"; then
        rm -rf "$repair_parent"
        return 1
    fi

    if ! pkgutil --flatten "$expanded_dir" "$repaired_pkg"; then
        rm -rf "$repair_parent"
        log_error "Failed to flatten repaired PKG: $pkg_path"
        return 1
    fi

    if ! mv "$repaired_pkg" "$pkg_path"; then
        rm -rf "$repair_parent"
        log_error "Failed to replace repaired PKG: $pkg_path"
        return 1
    fi
    rm -rf "$repair_parent"
}

validate_pkg_bom_metadata_invariants() {
    local expanded_dir="$1"
    local bom_listing
    local bad_owner_listing

    if [[ ! -f "$expanded_dir/Bom" ]]; then
        log_error "Expanded PKG is missing Bom for metadata validation"
        return 1
    fi

    bom_listing="$(mktemp "${TMPDIR:-/tmp}/orchard-bom-validate.XXXXXX")"
    bad_owner_listing="$(mktemp "${TMPDIR:-/tmp}/orchard-bom-owners.XXXXXX")"

    if ! lsbom "$expanded_dir/Bom" >"$bom_listing"; then
        rm -f "$bom_listing" "$bad_owner_listing"
        log_error "Failed to list PKG Bom for metadata validation"
        return 1
    fi

    if grep -Eq '(^|/)\._[^/]*([[:space:]]|$)|(^|/)\.DS_Store([[:space:]]|$)' "$bom_listing"; then
        log_error "macOS metadata sidecar files detected in PKG Bom"
        grep -E '(^|/)\._[^/]*([[:space:]]|$)|(^|/)\.DS_Store([[:space:]]|$)' "$bom_listing" >&2
        rm -f "$bom_listing" "$bad_owner_listing"
        return 1
    fi

    if ! awk -F '\t' '
        $1 ~ /^\.\/Library\/Application Support\/Orchard(\/|$)/ {
            split($3, owner, "/")
            if (!((owner[1] == "0" && owner[2] == "0") || ($3 == "root/wheel"))) {
                print
            }
        }
    ' "$bom_listing" >"$bad_owner_listing"; then
        rm -f "$bom_listing" "$bad_owner_listing"
        log_error "Failed to inspect PKG Bom ownership metadata"
        return 1
    fi

    if [[ -s "$bad_owner_listing" ]]; then
        log_error "PKG Bom ownership invariant failed; Orchard payload entries must be root:wheel"
        cat "$bad_owner_listing" >&2
        rm -f "$bom_listing" "$bad_owner_listing"
        return 1
    fi

    rm -f "$bom_listing" "$bad_owner_listing"
}

validate_pkg_payload_archive_ownership() {
    local expanded_dir="$1"
    local bad_owner_listing

    if [[ ! -f "$expanded_dir/Payload" ]]; then
        log_error "Expanded PKG is missing Payload archive for metadata validation"
        return 1
    fi

    bad_owner_listing="$(mktemp "${TMPDIR:-/tmp}/orchard-payload-owners.XXXXXX")"
    if ! perl - "$expanded_dir/Payload" >"$bad_owner_listing" <<'PERL'
use strict;
use warnings;

my ($payload) = @ARGV;

sub read_exact {
    my ($fh, $length) = @_;
    return '' if $length == 0;
    my $buffer = '';
    while (length($buffer) < $length) {
        my $chunk = '';
        my $read = sysread($fh, $chunk, $length - length($buffer));
        die "read payload: $!\n" unless defined $read;
        return undef if $read == 0 && length($buffer) == 0;
        die "truncated cpio payload\n" if $read == 0;
        $buffer .= $chunk;
    }
    return $buffer;
}

sub octal_value {
    my ($value) = @_;
    $value =~ s/\0//g;
    $value =~ s/\s+//g;
    die "invalid odc numeric field\n" unless $value =~ /^[0-7]+\z/;
    return oct($value);
}

sub hex_value {
    my ($value) = @_;
    die "invalid newc numeric field\n" unless $value =~ /^[0-9A-Fa-f]{8}\z/;
    return hex($value);
}

sub orchard_payload_entry {
    my ($name) = @_;
    my $normalized = $name;
    $normalized =~ s{^\./}{};
    $normalized =~ s{/\z}{};
    return $normalized =~ m{\ALibrary/Application Support/Orchard(?:/|\z)};
}

open my $in, '-|', 'gzip', '-dc', $payload or die "gzip -dc $payload: $!\n";
my $records = 0;
my $saw_trailer = 0;

while (1) {
    my $magic = read_exact($in, 6);
    last unless defined $magic;
    my ($name, $uid, $gid, $file_size);

    if ($magic eq '070707') {
        my $rest = read_exact($in, 70);
        die "truncated odc header\n" unless defined $rest;
        my $header = $magic . $rest;
        $uid = octal_value(substr($header, 24, 6));
        $gid = octal_value(substr($header, 30, 6));
        my $name_size = octal_value(substr($header, 59, 6));
        $file_size = octal_value(substr($header, 65, 11));
        my $name_block = read_exact($in, $name_size);
        die "truncated odc name\n" unless defined $name_block;
        $name = $name_block;
        $name =~ s/\0\z//;
        my $data = read_exact($in, $file_size);
        die "truncated odc data\n" unless defined $data;
    } elsif ($magic eq '070701' || $magic eq '070702') {
        my $rest = read_exact($in, 104);
        die "truncated newc header\n" unless defined $rest;
        my $header = $magic . $rest;
        $uid = hex_value(substr($header, 22, 8));
        $gid = hex_value(substr($header, 30, 8));
        $file_size = hex_value(substr($header, 54, 8));
        my $name_size = hex_value(substr($header, 94, 8));
        my $name_block = read_exact($in, $name_size);
        die "truncated newc name\n" unless defined $name_block;
        $name = $name_block;
        $name =~ s/\0\z//;
        my $name_pad_size = (4 - ((110 + $name_size) % 4)) % 4;
        my $name_pad = read_exact($in, $name_pad_size);
        die "truncated newc name padding\n" unless defined $name_pad;
        my $data = read_exact($in, $file_size);
        die "truncated newc data\n" unless defined $data;
        my $data_pad_size = (4 - ($file_size % 4)) % 4;
        my $data_pad = read_exact($in, $data_pad_size);
        die "truncated newc data padding\n" unless defined $data_pad;
    } else {
        die "unsupported cpio payload format magic: $magic\n";
    }

    $records++;
    if ($name eq 'TRAILER!!!') {
        $saw_trailer = 1;
        last;
    }
    if (orchard_payload_entry($name) && !($uid == 0 && $gid == 0)) {
        print "$name\t$uid/$gid\n";
    }
}

close $in or die "close gzip reader failed\n";
die "cpio payload contained no records\n" if $records == 0;
die "cpio payload missing TRAILER!!! record\n" unless $saw_trailer;
PERL
    then
        rm -f "$bad_owner_listing"
        log_error "Failed to inspect PKG Payload archive ownership metadata"
        return 1
    fi

    if [[ -s "$bad_owner_listing" ]]; then
        log_error "PKG Payload ownership invariant failed; Orchard payload archive entries must be root:wheel"
        cat "$bad_owner_listing" >&2
        rm -f "$bad_owner_listing"
        return 1
    fi

    rm -f "$bad_owner_listing"
}

validate_package_info_payload_consistency() {
    local pkg_path="$1"
    local expanded_dir="$2"
    local actual_number_of_files
    local actual_install_kbytes
    local package_info_values
    local package_info_number_of_files
    local package_info_install_kbytes

    if [[ ! -f "$expanded_dir/PackageInfo" ]]; then
        log_error "Expanded PKG is missing PackageInfo for metadata validation"
        return 1
    fi

    actual_number_of_files="$(pkgutil --payload-files "$pkg_path" | sed '/^[[:space:]]*$/d' | wc -l | tr -d '[:space:]')"
    if ! actual_install_kbytes="$(compute_expanded_payload_install_kbytes "$pkg_path")"; then
        return 1
    fi
    if ! package_info_values="$(package_info_payload_values "$expanded_dir/PackageInfo")"; then
        log_error "PackageInfo payload metadata is missing numberOfFiles or installKBytes"
        return 1
    fi
    IFS=$'\t' read -r package_info_number_of_files package_info_install_kbytes <<<"$package_info_values"

    if [[ "$package_info_number_of_files" != "$actual_number_of_files" ]]; then
        log_error "PackageInfo payload numberOfFiles is stale: PackageInfo=$package_info_number_of_files actual=$actual_number_of_files"
        return 1
    fi

    if [[ "$package_info_install_kbytes" != "$actual_install_kbytes" ]]; then
        log_error "PackageInfo payload installKBytes is stale: PackageInfo=$package_info_install_kbytes actual=$actual_install_kbytes"
        return 1
    fi
}

validate_pkg_metadata_invariants() {
    local pkg_path="$1"
    local label="$2"
    local expanded_parent
    local expanded_dir

    expanded_parent="$(mktemp -d "${TMPDIR:-/tmp}/orchard-pkg-metadata.XXXXXX")"
    expanded_dir="$expanded_parent/expanded"

    if ! pkgutil --expand "$pkg_path" "$expanded_dir"; then
        rm -rf "$expanded_parent"
        log_error "Failed to expand PKG for metadata validation: $pkg_path"
        return 1
    fi

    if ! validate_pkg_bom_metadata_invariants "$expanded_dir"; then
        rm -rf "$expanded_parent"
        return 1
    fi

    if ! validate_pkg_payload_archive_ownership "$expanded_dir"; then
        rm -rf "$expanded_parent"
        return 1
    fi

    if ! validate_package_info_payload_consistency "$pkg_path" "$expanded_dir"; then
        rm -rf "$expanded_parent"
        return 1
    fi

    rm -rf "$expanded_parent"
    log_info "PKG metadata invariants validated for $label"
}

validate_pkg_payload() {
    local pkg_path="$1"
    local payload_files
    local required_entries=(
        "./Library/Application Support/Orchard/share/bin/orchardctl"
        "./Library/Application Support/Orchard/share/bin/orchard-controller"
        "./Library/Application Support/Orchard/share/bin/orchard-node-agent"
        "./Library/Application Support/Orchard/share/bin/orchard-managed-postgres"
        "./Library/Application Support/Orchard/share/launchd/com.orchard.controller.plist"
        "./Library/Application Support/Orchard/share/launchd/com.orchard.node-agent.plist"
        "./Library/Application Support/Orchard/releases/orchard_cli/bin/orchard_cli"
        "./Library/Application Support/Orchard/releases/orchard_controller/bin/orchard_controller"
        "./Library/Application Support/Orchard/releases/orchard_node_agent/bin/orchard_node_agent"
        "./Library/Application Support/Orchard/native/orchard_tokenizer/.venv/bin/orchard-tokenizer"
        "./Library/Application Support/Orchard/native/orchard_worker_mlx/.venv/bin/orchard-worker-mlx"
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

    if ! validate_pkg_metadata_invariants "$pkg_path" "unsigned PKG"; then
        return 1
    fi

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

if ! FULL_GIT_SHA="$(git rev-parse HEAD)"; then
    log_error "Failed to resolve the Git HEAD for packaged build provenance"
    exit 1
fi

if [[ ! "$FULL_GIT_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    log_error "Packaged build provenance must be a 40-character lowercase Git SHA"
    exit 1
fi

export ORCHARD_BUILD_SHA="$FULL_GIT_SHA"
SHORT_GIT_SHA="${FULL_GIT_SHA:0:7}"
PKG_FILENAME_REF="$SHORT_GIT_SHA"

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

BUILD_DATE=$(date +%Y%m%d)
PKG_NAME="Orchard-${APP_VERSION}-${BUILD_DATE}-${PKG_FILENAME_REF}.pkg"

log_info "Building Orchard PKG"
log_info "  App version: $APP_VERSION"
log_info "  Build SHA: $ORCHARD_BUILD_SHA"
log_info "  PKG filename ref: $PKG_FILENAME_REF"
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
        PKG_FILENAME_REF="${SHORT_GIT_SHA}-dirty"
        PKG_NAME="Orchard-${APP_VERSION}-${BUILD_DATE}-${PKG_FILENAME_REF}.pkg"
        log_warn "Marked PKG filename as dirty: $PKG_NAME"
    else
        log_error "Uncommitted changes detected in repository"
        log_error "Commit changes first, or use --allow-dirty to override"
        exit 1
    fi
fi

log_info "Validating packaging source provenance..."
validate_packaging_source_provenance

log_info "Checking packaging runtime tools..."
require_packaging_runtime_tools

log_info "Running scratch pkgbuild provenance preflight..."
run_pkgbuild_scratch_preflight

# Clean build artifacts if requested
if [[ "$DO_CLEAN" == "true" ]]; then
    log_info "Deep clean requested — removing _build and deps..."
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

log_info "Remediating OTP OpenSSL Mach-O closure..."
OPENSSL_PROVENANCE="$OUTPUT_DIR/$PKG_NAME.openssl-provenance.txt"
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
    script_path="$REPO_ROOT/packaging/pkg/bin/$script"
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

if [[ "$STAGE_ONLY" != "true" ]]; then
    mkdir -p "$OUTPUT_DIR"
    cleanup_pkg_outputs "$OUTPUT_DIR/$PKG_NAME"
fi

SIGNING_MANIFEST_TMP=""
PAYLOAD_SIGNING_IDENTITY="$(printf '%s' "${ORCHARD_PAYLOAD_SIGNING_IDENTITY:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if [[ -n "$PAYLOAD_SIGNING_IDENTITY" ]]; then
    log_info "Signing nested Mach-O payload binaries..."
    discard_payload_keychain_env
    if [[ "$STAGE_ONLY" != "true" ]]; then
        SIGNING_MANIFEST_TMP="$OUTPUT_DIR/.${PKG_NAME}.signing-manifest.tmp"
        rm -f "$SIGNING_MANIFEST_TMP"
        run_payload_signer --manifest-output "$SIGNING_MANIFEST_TMP" "$STAGING_BASE"
    else
        run_payload_signer "$STAGING_BASE"
    fi
else
    log_warn "ORCHARD_PAYLOAD_SIGNING_IDENTITY not set — payload Mach-O binaries will be unsigned. The resulting PKG cannot be notarized."
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

if [[ "$STAGE_ONLY" == "true" ]]; then
    printf 'STAGING_BASE=%s\n' "$STAGING_BASE"
    log_info "Stage-only build complete; preserved staging directory: $STAGING_BASE"
    BUILD_SUCCEEDED=true
    exit 0
fi

# Set permissions in staging
log_info "Setting staging permissions..."
find "$STAGING_BASE" -type d -exec chmod 755 {} \;
find "$STAGING/share/launchd" -type f -exec chmod 644 {} \;
find "$STAGING/share/bin" -type f -exec chmod 755 {} \;

log_info "Validating pre-pkgbuild metadata state..."
assert_clean_provenance "pre-pkgbuild" "$STAGING_BASE"

# Build the PKG
log_info "Building PKG..."
mkdir -p "$OUTPUT_DIR"

if ! pkgbuild_without_metadata \
    --root "$STAGING_BASE" \
    --scripts "$REPO_ROOT/packaging/pkg/scripts" \
    --identifier com.orchard.pkg \
    --version "$APP_VERSION" \
    --install-location / \
    "$OUTPUT_DIR/$PKG_NAME"; then
    cleanup_pkg_outputs "$OUTPUT_DIR/$PKG_NAME"
    log_error "PKG build failed!"
    exit 1
fi

# Verify PKG
if [[ -f "$OUTPUT_DIR/$PKG_NAME" ]]; then
    log_info "Repairing PKG payload metadata..."
    if ! repair_pkg_payload_metadata "$OUTPUT_DIR/$PKG_NAME"; then
        cleanup_pkg_outputs "$OUTPUT_DIR/$PKG_NAME"
        log_error "Removed unrepaired PKG outputs: $OUTPUT_DIR/$PKG_NAME"
        exit 1
    fi

    log_info "Validating PKG payload layout..."
    if ! validate_pkg_payload "$OUTPUT_DIR/$PKG_NAME"; then
        cleanup_pkg_outputs "$OUTPUT_DIR/$PKG_NAME"
        log_error "Removed malformed PKG outputs: $OUTPUT_DIR/$PKG_NAME"
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

BUILD_SUCCEEDED=true
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
