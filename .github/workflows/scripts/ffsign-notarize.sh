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
# Python.framework requires special handling: sign the Versions/X.Y bundle
# as a unit (not individual files inside it) so codesign correctly seals the
# Versions/Current symlink and the nested Python.app subcomponent.

echo "==> Signing dylibs inside $APPDIR ..."

# 1. Sign all .dylib/.so files that are NOT inside Python.framework
#    (Python.framework internals are handled by signing the framework bundle below)
find "$APPDIR" \
    \( -name "*.dylib" -o -name "*.so" \) \
    | grep -v '/Python\.framework/' \
    | sort -r \
    | while read -r lib; do
        codesign --force \
            --options runtime \
            --entitlements "$ENTITLEMENTS" \
            --sign "$FF_SIGN_IDENTITY" \
            "$lib"
    done

# 2. Sign .dylib/.so files inside Python.framework (deepest first, before the bundle seal)
find "$APPDIR/Contents/Frameworks/Python.framework" \
    \( -name "*.dylib" -o -name "*.so" \) \
    | sort -r \
    | while read -r lib; do
        codesign --force \
            --options runtime \
            --entitlements "$ENTITLEMENTS" \
            --sign "$FF_SIGN_IDENTITY" \
            "$lib"
    done

# 3. Sign Python.framework/Versions/X.Y as a bundle — this seals the framework
#    including the nested Python.app and the Versions/Current symlink target.
find "$APPDIR/Contents/Frameworks/Python.framework/Versions" \
    -mindepth 1 -maxdepth 1 -type d \
    | while read -r ver; do
        echo "==> Signing Python.framework version bundle: $ver"
        codesign --force \
            --options runtime \
            --entitlements "$ENTITLEMENTS" \
            --sign "$FF_SIGN_IDENTITY" \
            "$ver"
    done

# 4. Sign the main app bundle (must be last)
echo "==> Signing $APPDIR ..."
codesign --force \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$FF_SIGN_IDENTITY" \
    "$APPDIR"

codesign --verify --deep --strict --verbose=2 "$APPDIR"
echo "✓ App bundle signature verified."

# ── Sign the DMG ──────────────────────────────────────────────────────────────
echo "==> Signing DMG: $DMG ..."
codesign --force --verify --verbose=1 \
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
