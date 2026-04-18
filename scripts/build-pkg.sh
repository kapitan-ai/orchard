#!/bin/bash
#
# Build Orchard PKG installer
# Usage: ./scripts/build-pkg.sh [output_dir]
#
# Outputs: Orchard-<app_version>-<YYYYMMDD>-<git_sha7>.pkg
#

set -euo pipefail

# Configuration
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$REPO_ROOT/../orchard-workbench/artifacts/pkg-smoke/$(date +%Y-%m-%d)}"
STAGING_BASE="/tmp/orchard-pkg-build-$$"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

cleanup() {
    if [[ -d "$STAGING_BASE" ]]; then
        log_info "Cleaning up staging directory..."
        rm -rf "$STAGING_BASE"
    fi
}
trap cleanup EXIT

cd "$REPO_ROOT"

# Get version info from mix.exs
APP_VERSION=$(grep -E "version: \"[0-9]+\.[0-9]+\.[0-9]+" mix.exs | head -1 | sed 's/.*version: "\([^"]*\)".*/\1/')
GIT_SHA=$(git rev-parse --short HEAD)
BUILD_DATE=$(date +%Y%m%d)
PKG_NAME="Orchard-${APP_VERSION}-${BUILD_DATE}-${GIT_SHA}.pkg"

log_info "Building Orchard PKG"
log_info "  App version: $APP_VERSION"
log_info "  Git SHA: $GIT_SHA"
log_info "  Build date: $BUILD_DATE"
log_info "  Output: $OUTPUT_DIR/$PKG_NAME"

# Verify clean git state (optional but recommended)
if ! git diff-index --quiet HEAD --; then
    log_warn "Uncommitted changes detected in repository"
    log_warn "Continuing build, but consider committing first for reproducibility"
fi

# Pre-build: Setup Python venvs
log_info "Setting up Python venvs..."
cd "$REPO_ROOT/native/orchard_tokenizer"
uv sync

cd "$REPO_ROOT/native/orchard_worker_mlx"
uv sync --extra mlx

# Clean previous builds
log_info "Cleaning previous release builds..."
cd "$REPO_ROOT"
rm -rf _build/prod/rel/orchard_{controller,node_agent,cli}

# Build releases
log_info "Building Elixir releases..."
export MIX_ENV=prod

log_info "  → orchard_controller"
mix release orchard_controller

log_info "  → orchard_node_agent"
mix release orchard_node_agent

log_info "  → orchard_cli"
mix release orchard_cli

# Verify native executables have correct permissions
log_info "Verifying native executable permissions..."
for native_bin in "$REPO_ROOT/native/orchard_tokenizer/bin/orchard-tokenizer" \
                  "$REPO_ROOT/native/orchard_worker_mlx/bin/orchard-worker-mlx"; do
    if [[ -f "$native_bin" ]]; then
        perms=$(stat -f "%Lp" "$native_bin")
        if [[ "$perms" != "755" ]]; then
            log_warn "Fixing permissions on $native_bin (was $perms)"
            chmod 755 "$native_bin"
        fi
    fi
done

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

# Copy wrapper scripts
log_info "Copying wrapper scripts..."
cp "$REPO_ROOT/packaging/pkg/bin/"* "$STAGING/share/bin/"

# Copy launchd plists
log_info "Copying launchd plists..."
cp "$REPO_ROOT/packaging/launchd/"*.plist "$STAGING/share/launchd/"

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
