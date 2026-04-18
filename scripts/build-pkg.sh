#!/bin/bash
#
# Build Orchard PKG installer
# Usage: ./scripts/build-pkg.sh [--allow-dirty] [--clean] [output_dir]
#
# Options:
#   --allow-dirty    Allow building with uncommitted changes (marks PKG as -dirty)
#   --clean          Deep clean: removes _build/ and deps/ before building
#   output_dir       Destination directory (default: ./artifacts/pkg-builds/YYYY-MM-DD)
#
# Outputs: Orchard-<app_version>-<YYYYMMDD>-<git_sha7>.pkg
#
# Examples:
#   ./scripts/build-pkg.sh                                    # Standard build
#   ./scripts/build-pkg.sh --clean                          # Clean build
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
        -*)
            log_error "Unknown option: $1"
            echo "Usage: $0 [--allow-dirty] [--clean] [output_dir]"
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
STAGING_BASE="/tmp/orchard-pkg-build-$$"

# Enhanced error trap
trap 'log_error "Build failed at line $LINENO"' ERR

cleanup() {
    if [[ -d "$STAGING_BASE" ]]; then
        log_info "Cleaning up staging directory..."
        rm -rf "$STAGING_BASE"
    fi
}
trap cleanup EXIT

cd "$REPO_ROOT"

# Preflight: Check for port conflicts (warn only)
if lsof -ti :4000 >/dev/null 2>&1 || lsof -ti :50071 >/dev/null 2>&1; then
    log_warn "Dev server ports (4000 or 50071) appear to be in use"
    log_warn "This may indicate a running 'bin/dev' instance"
    log_warn "Port conflicts can cause silent hangs in mix tasks"
    log_warn "Consider stopping dev server before continuing"
    sleep 2
fi

# Get version info using Mix (reliable extraction)
APP_VERSION=$(mix run -e 'IO.puts(Mix.Project.config()[:version])' 2>/dev/null | tail -1)
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
log_info "  Output: $OUTPUT_DIR/$PKG_NAME"

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
rm -rf _build/prod/rel/orchard_{controller,node_agent,cli}

  # Fetch deps and build assets
  log_info "Fetching Elixir dependencies..."
  mix deps.get
  
  log_info "Building assets (controller app)..."
  cd "$REPO_ROOT/apps/orchard_controller"
  MIX_ENV=prod mix assets.deploy
  cd "$REPO_ROOT"
  
  # Build releases
log_info "Building Elixir releases..."
export MIX_ENV=prod

log_info "  → orchard_controller"
mix release orchard_controller

log_info "  → orchard_node_agent"
mix release orchard_node_agent

log_info "  → orchard_cli"
mix release orchard_cli

# Create staging directory
log_info "Creating PKG staging..."
STAGING="$STAGING_BASE/Library Application Support/Orchard"
mkdir -p "$STAGING"/{releases,native,share/{bin,launchd},config,logs,support}

# Copy releases
log_info "Copying releases to staging..."
cp -R "$REPO_ROOT/_build/prod/rel/orchard_controller" "$STAGING/releases/"
cp -R "$REPO_ROOT/_build/prod/rel/orchard_node_agent" "$STAGING/releases/"
cp -R "$REPO_ROOT/_build/prod/rel/orchard_cli" "$STAGING/releases/"

# Copy native components
log_info "Copying native components..."
cp -R "$REPO_ROOT/native/orchard_tokenizer" "$STAGING/native/"
cp -R "$REPO_ROOT/native/orchard_worker_mlx" "$STAGING/native/"

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
        cp "$script_path" "$STAGING/share/bin/"
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
        cp "$plist_path" "$STAGING/share/launchd/"
    else
        log_error "Missing launchd plist: $plist"
        exit 1
    fi
done
# Note: com.orchard.postgres.plist is excluded (managed postgres not yet supported)

# Set permissions in staging
log_info "Setting staging permissions..."
find "$STAGING_BASE" -type d -exec chmod 755 {} \;
find "$STAGING/share/launchd" -type f -exec chmod 644 {} \;
find "$STAGING/share/bin" -type f -exec chmod 755 {} \;

# Build the PKG
log_info "Building PKG..."
mkdir -p "$OUTPUT_DIR"

pkgbuild \
    --root "$STAGING_BASE" \
    --scripts "$REPO_ROOT/packaging/pkg/scripts" \
    --identifier com.orchard.pkg \
    --version "$APP_VERSION" \
    --install-location / \
    "$OUTPUT_DIR/$PKG_NAME"

# Verify PKG
if [[ -f "$OUTPUT_DIR/$PKG_NAME" ]]; then
    PKG_SIZE=$(du -h "$OUTPUT_DIR/$PKG_NAME" | cut -f1)
    log_info "✅ PKG built successfully: $PKG_NAME ($PKG_SIZE)"
    log_info "   Location: $OUTPUT_DIR/$PKG_NAME"
    
    # Generate checksum
    shasum -a 256 "$OUTPUT_DIR/$PKG_NAME" > "$OUTPUT_DIR/$PKG_NAME.sha256"
    log_info "   Checksum: $OUTPUT_DIR/$PKG_NAME.sha256"
else
    log_error "PKG build failed!"
    exit 1
fi

log_info "Build complete!"
echo ""
echo "To test the PKG:"
echo "  sudo installer -pkg \"$OUTPUT_DIR/$PKG_NAME\" -target /"
echo "  sudo orchardctl env init"
echo "  sudo orchardctl start"
