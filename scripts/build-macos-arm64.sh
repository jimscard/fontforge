#!/usr/bin/env bash
# Build FontForge for Apple Silicon (arm64) and produce an unsigned DMG.
#
# Usage:
#   ./scripts/build-macos-arm64.sh [--skip-deps] [--build-dir DIR]
#
# Options:
#   --skip-deps    Skip Homebrew dependency installation (useful if already installed)
#   --build-dir    Build directory (default: build-arm64)
#
# After a successful run the DMG is written to:
#   <build-dir>/osx/FontForge-<date>-<hash>.app.dmg
#
# To also sign and notarize the result, pipe it through ffsign-notarize.sh:
#   FF_SIGN_IDENTITY="Developer ID Application: ..." \
#   FF_NOTARIZE_APPLE_ID="you@example.com"            \
#   FF_NOTARIZE_PASSWORD="@keychain:AC_PASSWORD"       \
#   FF_NOTARIZE_TEAM_ID="XXXXXXXXXX"                   \
#     .github/workflows/scripts/ffsign-notarize.sh \
#     <build-dir>/osx/FontForge.app \
#     <build-dir>/osx/FontForge-*.app.dmg

set -e -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BUILD_DIR="$REPO_ROOT/build-arm64"
SKIP_DEPS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-deps)  SKIP_DEPS=1; shift ;;
        --build-dir)  BUILD_DIR="$(realpath "$2")"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Dependencies ──────────────────────────────────────────────────────────────
if [[ $SKIP_DEPS -eq 0 ]]; then
    echo "==> Installing Homebrew dependencies..."
    brew install \
        pkg-config cmake ninja \
        cairo coreutils fontconfig gettext giflib gtk+3 gtkmm3 \
        jpeg libpng libspiro libtiff libtool libuninameslist \
        python@3 wget woff2
fi

# Homebrew on Apple Silicon always lives at /opt/homebrew
BREW_PREFIX="$(brew --prefix)"
export PATH="$BREW_PREFIX/opt/gettext/bin:$BREW_PREFIX/opt/ruby/bin:$PATH"
export PKG_CONFIG_PATH="$BREW_PREFIX/lib/pkgconfig:$BREW_PREFIX/opt/libffi/lib/pkgconfig"

# ── CMake configure ───────────────────────────────────────────────────────────
INSTALL_PREFIX="$BUILD_DIR/target"

echo "==> Configuring (arm64, deployment target 12.0)..."
mkdir -p "$BUILD_DIR"
cmake -S "$REPO_ROOT" -B "$BUILD_DIR" -GNinja \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
    -DCMAKE_FIND_ROOT_PATH="$BREW_PREFIX/opt/gettext" \
    -DENABLE_FONTFORGE_EXTRAS=ON

# ── Build and install ─────────────────────────────────────────────────────────
echo "==> Building..."
ninja -C "$BUILD_DIR" install

# ── App bundle + DMG ─────────────────────────────────────────────────────────
# CI=1 tells ffosxbuild.sh to create the DMG (otherwise it only builds the .app)
echo "==> Creating app bundle and DMG..."
CI=1 ninja -C "$BUILD_DIR" macbundle

DMG=$(find "$BUILD_DIR/osx" -name "FontForge-*.app.dmg" | head -1)
if [[ -z "$DMG" ]]; then
    echo "ERROR: DMG not found under $BUILD_DIR/osx/" >&2
    exit 1
fi

echo ""
echo "✓ Build complete."
echo "  App bundle : $BUILD_DIR/osx/FontForge.app"
echo "  DMG        : $DMG"
echo ""
echo "To sign and notarize:"
echo "  FF_SIGN_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\" \\"
echo "  FF_NOTARIZE_APPLE_ID=\"you@example.com\" \\"
echo "  FF_NOTARIZE_PASSWORD=\"@keychain:AC_PASSWORD\" \\"
echo "  FF_NOTARIZE_TEAM_ID=\"XXXXXXXXXX\" \\"
echo "    .github/workflows/scripts/ffsign-notarize.sh \\"
echo "    \"$BUILD_DIR/osx/FontForge.app\" \\"
echo "    \"$DMG\""
