#!/usr/bin/env bash
# Push an updated FontForge cask to the Homebrew tap after a release.
#
# Usage:
#   bump-homebrew-cask.sh <tap-repo> <version> <sha256>
#
#   tap-repo   GitHub repo slug, e.g. jimscard/homebrew-fontforge
#   version    CalVer string matching the release tag (without leading 'v'), e.g. 20251009
#   sha256     SHA-256 hex digest of the release DMG
#
# Environment:
#   HOMEBREW_TAP_GITHUB_TOKEN  Personal access token with 'contents:write' on tap-repo.
#                              When absent the script exits 0 (skip without error).

set -e -o pipefail

TAP_REPO="$1"
VERSION="$2"
SHA256="$3"

if [[ -z "$TAP_REPO" || -z "$VERSION" || -z "$SHA256" ]]; then
    echo "Usage: $(basename "$0") <tap-repo> <version> <sha256>" >&2
    exit 1
fi

if [[ -z "$HOMEBREW_TAP_GITHUB_TOKEN" ]]; then
    echo "HOMEBREW_TAP_GITHUB_TOKEN not set — skipping Homebrew tap update."
    exit 0
fi

SOURCE_REPO="jimscard/fontforge"
DMG_URL="https://github.com/${SOURCE_REPO}/releases/download/v${VERSION}/FontForge-${VERSION}-arm64.dmg"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> Cloning tap: https://github.com/${TAP_REPO} ..."
git clone \
    "https://x-access-token:${HOMEBREW_TAP_GITHUB_TOKEN}@github.com/${TAP_REPO}.git" \
    "$WORK_DIR/tap"

mkdir -p "$WORK_DIR/tap/Casks"

cat > "$WORK_DIR/tap/Casks/fontforge.rb" <<CASK
# This file is auto-updated by the FontForge release workflow.
# Manual edits will be overwritten on the next release.
# Source: https://github.com/${SOURCE_REPO}

cask "fontforge" do
  version "${VERSION}"
  sha256 "${SHA256}"

  url "${DMG_URL}"

  name "FontForge"
  desc "Font editor for outline and bitmap fonts"
  homepage "https://fontforge.org"

  depends_on macos: ">= :monterey"
  depends_on arch: :arm64

  app "FontForge.app"

  zap trash: [
    "~/.config/fontforge",
    "~/.FontForge",
  ]
end
CASK

cd "$WORK_DIR/tap"

git config user.name  "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

git add Casks/fontforge.rb

if git diff --cached --quiet; then
    echo "Cask is already up to date — nothing to commit."
    exit 0
fi

git commit -m "chore: bump fontforge to ${VERSION}"
git push origin HEAD

echo "✓ Homebrew tap updated: ${TAP_REPO} → ${VERSION}"
