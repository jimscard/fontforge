#!/usr/bin/env bash
# Sign a FontForge.app bundle and notarize its DMG for direct (non-App Store) distribution.
#
# Usage:
#   ffsign-notarize.sh <FontForge.app> <FontForge.dmg>
#
# Required environment variables:
#   FF_SIGN_IDENTITY          Codesign identity string, e.g.:
#                               "Developer ID Application: Your Name (TEAMID)"
#   FF_NOTARIZE_APPLE_ID      Apple ID email used for notarization
#   FF_NOTARIZE_PASSWORD      App-specific password (or "@keychain:<label>" for local keychain)
#   FF_NOTARIZE_TEAM_ID       10-character Apple Team ID
#
# Optional (CI only — skipped when not set):
#   FF_CERT_P12_B64           Base64-encoded Developer ID .p12 certificate
#   FF_CERT_P12_PASSWORD      Password for the .p12 file
#
# On success the DMG is stapled in-place and ready for distribution.

set -e -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ENTITLEMENTS="$REPO_ROOT/osx/entitlements.plist"

APPDIR="$(realpath "$1")"
DMG="$(realpath "$2")"

if [[ -z "$APPDIR" || -z "$DMG" ]]; then
    echo "Usage: $(basename "$0") <FontForge.app> <FontForge.dmg>" >&2
    exit 1
fi
if [[ ! -d "$APPDIR" ]]; then echo "ERROR: Not a directory: $APPDIR" >&2; exit 1; fi
if [[ ! -f "$DMG"    ]]; then echo "ERROR: DMG not found: $DMG"     >&2; exit 1; fi

for var in FF_SIGN_IDENTITY FF_NOTARIZE_APPLE_ID FF_NOTARIZE_PASSWORD FF_NOTARIZE_TEAM_ID; do
    if [[ -z "${!var}" ]]; then
        echo "ERROR: Required environment variable $var is not set." >&2
        exit 1
    fi
done

# ── Optional: import certificate from base64 P12 (CI path) ───────────────────
KEYCHAIN_NAME="ff-build-$(date +%s).keychain"
KEYCHAIN_CREATED=0

if [[ -n "$FF_CERT_P12_B64" ]]; then
    echo "==> Importing Developer ID certificate into temporary keychain..."
    KEYCHAIN_PATH="$TMPDIR/$KEYCHAIN_NAME"
    P12_PATH="$TMPDIR/ff-cert-$$.p12"

    security create-keychain -p "" "$KEYCHAIN_PATH"
    security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
    security unlock-keychain -p "" "$KEYCHAIN_PATH"

    echo "$FF_CERT_P12_B64" | base64 --decode -o "$P12_PATH"
    security import "$P12_PATH" \
        -k "$KEYCHAIN_PATH" \
        -P "${FF_CERT_P12_PASSWORD:-}" \
        -T /usr/bin/codesign \
        -T /usr/bin/security
    security set-key-partition-list \
        -S apple-tool:,apple:,codesign: \
        -s -k "" "$KEYCHAIN_PATH"

    # Prepend our keychain so codesign finds the cert.
    # Word-splitting $EXISTING_KEYCHAINS is intentional — each path is a separate arg.
    # shellcheck disable=SC2086
    EXISTING_KEYCHAINS=$(security list-keychains -d user | sed 's/"//g' | tr -d '\n' | xargs)
    security list-keychains -d user -s "$KEYCHAIN_PATH" $EXISTING_KEYCHAINS  # SC2086 intentional
    KEYCHAIN_CREATED=1

    rm -f "$P12_PATH"
fi

cleanup() {
    if [[ $KEYCHAIN_CREATED -eq 1 ]]; then
        echo "==> Removing temporary keychain..."
        security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ── Sign the app bundle ───────────────────────────────────────────────────────
# Signing order: deepest-first to shallowest.
#
# Rules:
#  - Individual dylibs/.so: --timestamp only (no --options runtime, no --entitlements)
#  - Mach-O executables in bin/ dirs: --timestamp --options runtime
#  - Python.app bundle (nested inside Python.framework): --timestamp --options runtime
#  - Python.framework/Versions/X.Y: --timestamp --options runtime — creates the
#    CodeResources framework seal AND re-signs the Python main binary with
#    hardened runtime. WITHOUT --deep so codesign seals the framework contents
#    without re-signing individual .so files.
#  - FontForge.app bundle: --timestamp --options runtime --entitlements

# 0. Remove Python test fixtures BEFORE any signing so they are not referenced
#    by the framework seal. Apple's notarization tool cannot unpack the sparse
#    zip64 .part files used by Python's zipimport tests, causing "Invalid".
echo "==> Removing Python test fixtures..."
find "$APPDIR/Contents/Frameworks" \
    -name "test" -path "*/python*/test" -prune \
    -exec rm -rf {} \; 2>/dev/null || true

echo "==> Signing all dylibs and .so files inside $APPDIR ..."

# 1. Sign ALL .dylib and .so files in the entire bundle (deepest-first by path length).
#    --timestamp ensures Apple's notarytool accepts the signatures.
while IFS= read -r lib; do
    codesign --force --timestamp --sign "$FF_SIGN_IDENTITY" "$lib"
done < <(find "$APPDIR" \( -name "*.dylib" -o -name "*.so" \) \
    | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

# 2. Sign Mach-O executables in bin/ directories with hardened runtime.
#    This covers opt/local/bin/* (fontforge utilities) and
#    Python.framework/.../bin/python* — Apple requires hardened runtime on
#    all executables for notarization.
echo "==> Signing Mach-O executables in bin/ directories..."
while IFS= read -r exe; do
    if file "$exe" 2>/dev/null | grep -qE "Mach-O.*executable"; then
        codesign --force --timestamp --options runtime \
            --sign "$FF_SIGN_IDENTITY" "$exe"
    fi
done < <(find "$APPDIR" -path "*/bin/*" -type f \
    ! -name "*.dylib" ! -name "*.so" \
    | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

# 3. Sign Python.app bundle inside the framework.
while IFS= read -r pyapp; do
    echo "==> Signing nested Python.app: $pyapp"
    codesign --force --timestamp \
        --options runtime \
        --sign "$FF_SIGN_IDENTITY" \
        "$pyapp"
done < <(find "$APPDIR/Contents/Frameworks" -name "Python.app" -type d)

# 4. Seal Python.framework/Versions/X.Y as a framework bundle (no --deep).
#    This creates _CodeSignature/CodeResources so that when FontForge.app is
#    signed, codesign can resolve the Versions/Current symlink correctly.
#    Without --deep, codesign signs only the main framework binary (Python)
#    and builds the resource seal from already-signed content; individual .so
#    files are NOT re-signed. --options runtime ensures the Python binary itself
#    satisfies notarization's hardened-runtime requirement.
while IFS= read -r fw_ver; do
    echo "==> Sealing Python.framework version directory: $fw_ver"
    codesign --force --timestamp \
        --options runtime \
        --sign "$FF_SIGN_IDENTITY" \
        "$fw_ver"
    # Spot-check: confirm a .so file still has our Developer ID (not re-signed).
    SAMPLE_SO=$(find "$fw_ver" -name "*.so" -type f | head -1)
    if [[ -n "$SAMPLE_SO" ]]; then
        echo "==> Post-seal .so signature spot-check: $SAMPLE_SO"
        codesign -dv "$SAMPLE_SO" 2>&1 | grep -E "TeamIdentifier|Timestamp|Authority" || true
    fi
done < <(find "$APPDIR/Contents/Frameworks" \
    -maxdepth 3 -path "*/Python.framework/Versions/[0-9]*" -type d)

# 5. Sign the main app bundle last — applies entitlements at the app level only.
echo "==> Signing $APPDIR ..."
codesign --force --timestamp \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$FF_SIGN_IDENTITY" \
    "$APPDIR"

codesign --verify --deep --strict --verbose=2 "$APPDIR"
echo "✓ App bundle signature verified."

# ── Recreate DMG from the signed app ─────────────────────────────────────────
# The DMG passed in was created by ffosxbuild.sh *before* signing; it contains
# unsigned binaries. We must recreate it so Apple's notarization tool sees the
# signed content.
echo "==> Recreating DMG from signed app (overwriting unsigned copy)..."
hdiutil create \
    -size   800m       \
    -volname FontForge \
    -srcfolder "$APPDIR" \
    -ov              \
    -format UDBZ     \
    "$DMG"
echo "✓ DMG recreated: $DMG"

# ── Sign the DMG ──────────────────────────────────────────────────────────────
echo "==> Signing DMG: $DMG ..."
codesign --force \
    --timestamp \
    --sign "$FF_SIGN_IDENTITY" \
    "$DMG"

# ── Notarize ──────────────────────────────────────────────────────────────────
echo "==> Submitting DMG for notarization (this may take a few minutes)..."
NOTARY_OUTPUT=$(xcrun notarytool submit "$DMG" \
    --apple-id  "$FF_NOTARIZE_APPLE_ID" \
    --password  "$FF_NOTARIZE_PASSWORD" \
    --team-id   "$FF_NOTARIZE_TEAM_ID"  \
    --wait \
    --timeout 30m \
    --output-format json 2>&1) || true

echo "$NOTARY_OUTPUT"

NOTARY_ID=$(echo "$NOTARY_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || true)
NOTARY_STATUS=$(echo "$NOTARY_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null || true)

if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    echo "ERROR: Notarization failed with status: $NOTARY_STATUS" >&2
    if [[ -n "$NOTARY_ID" ]]; then
        echo "==> Fetching Apple notarization log for submission $NOTARY_ID ..." >&2
        xcrun notarytool log "$NOTARY_ID" \
            --apple-id "$FF_NOTARIZE_APPLE_ID" \
            --password "$FF_NOTARIZE_PASSWORD" \
            --team-id  "$FF_NOTARIZE_TEAM_ID" >&2 || true
    fi
    exit 1
fi

# ── Staple ────────────────────────────────────────────────────────────────────
echo "==> Stapling notarization ticket to DMG..."
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo ""
echo "✓ Done. Signed, notarized, and stapled:"
echo "  $DMG"
