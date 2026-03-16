# macOS ARM64 Distribution Setup

This guide walks through configuring code signing and notarization so the
[`macos-arm64-release`](.github/workflows/macos-arm64-release.yml) workflow
can produce a Gatekeeper-friendly DMG for Apple Silicon Macs.

## Prerequisites

- An active [Apple Developer Program](https://developer.apple.com/programs/) membership
- Xcode command-line tools installed locally (`xcode-select --install`)
- Admin access to this GitHub repository (Settings → Secrets)

---

## Step 1 — Create a Developer ID Application certificate

This is the certificate type for **direct distribution** (outside the Mac App Store).

1. Open **Xcode → Settings → Accounts**, select your Apple ID, click **Manage Certificates**.
2. Click **+** and choose **Developer ID Application**.  
   *(If you already have one, skip to Step 2.)*
3. Xcode creates and installs the certificate into your login keychain automatically.

> You can verify it exists in **Keychain Access → My Certificates**; it will be named  
> `Developer ID Application: Your Name (XXXXXXXXXX)`

---

## Step 2 — Export the certificate as a .p12 file

1. Open **Keychain Access**, select **My Certificates**.
2. Find `Developer ID Application: Your Name (XXXXXXXXXX)`.
3. Right-click → **Export** → save as `developer-id.p12`.
4. Set a strong export password — you will need it in Step 4.

Convert the file to base64 for storage as a GitHub secret:

```bash
base64 -i developer-id.p12 | pbcopy   # copies to clipboard
```

---

## Step 3 — Create an app-specific password

Notarization uses an **app-specific password**, not your Apple ID password.

1. Go to [appleid.apple.com](https://appleid.apple.com) → **Sign-In and Security → App-Specific Passwords**.
2. Click **+**, label it something like `fontforge-notarize`, and copy the generated password.

---

## Step 4 — Find your Team ID

Your Team ID appears in two places:

- [developer.apple.com/account](https://developer.apple.com/account) — shown at the top right of the Membership page as a 10-character alphanumeric string.
- In the certificate name itself: `Developer ID Application: Name (TEAMID)`.

---

## Step 5 — Add secrets to GitHub

Go to **GitHub → Repository → Settings → Secrets and variables → Actions → New repository secret** and add each of the following:

| Secret name | Value |
|-------------|-------|
| `APPLE_DEVELOPER_ID_CERT_P12` | Base64 output from Step 2 (`base64 -i developer-id.p12`) |
| `APPLE_DEVELOPER_ID_CERT_P12_PASSWORD` | Export password you set in Step 2 |
| `APPLE_SIGN_IDENTITY` | Full identity string, e.g. `Developer ID Application: Your Name (XXXXXXXXXX)` |
| `APPLE_ID` | Your Apple ID email address |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password from Step 3 |
| `APPLE_TEAM_ID` | 10-character Team ID from Step 4 |

---

## Step 6 — Trigger a release build

**Via a git tag** (recommended for releases):

```bash
git tag v20251009
git push origin v20251009
```

The workflow runs automatically on any tag matching `v*`.

**Manually** (for testing):

1. Go to **GitHub → Actions → macOS ARM64 Release**.
2. Click **Run workflow** → select branch → **Run workflow**.

The signed, notarized DMG is uploaded as an Actions artifact named `FontForge-macOS-arm64`.

---

## Local signing (without CI)

If you have the certificate in your login keychain, you can sign and notarize
a DMG you built locally:

```bash
# 1. Build (unsigned)
./scripts/build-macos-arm64.sh

# 2. Sign and notarize
FF_SIGN_IDENTITY="Developer ID Application: Your Name (XXXXXXXXXX)" \
FF_NOTARIZE_APPLE_ID="you@example.com" \
FF_NOTARIZE_PASSWORD="@keychain:fontforge-notarize" \
FF_NOTARIZE_TEAM_ID="XXXXXXXXXX" \
  .github/workflows/scripts/ffsign-notarize.sh \
  build-arm64/osx/FontForge.app \
  build-arm64/osx/FontForge-*.app.dmg
```

`@keychain:fontforge-notarize` tells `notarytool` to read the app-specific
password directly from your macOS keychain. To store it there:

```bash
xcrun notarytool store-credentials "fontforge-notarize" \
    --apple-id "you@example.com" \
    --team-id  "XXXXXXXXXX" \
    --password "xxxx-xxxx-xxxx-xxxx"
```

Then use `--keychain-profile "fontforge-notarize"` instead of
`FF_NOTARIZE_PASSWORD="@keychain:..."` if you prefer the notarytool native
profile approach.

---

## Troubleshooting

**`errSecInternalComponent` during import**  
The keychain is locked. The CI script unlocks the temporary keychain automatically; locally, run `security unlock-keychain login.keychain`.

**Notarization rejected — `ITMS-90338`**  
A bundled binary is missing the hardened runtime flag. Check the entitlements
file (`osx/entitlements.plist`) and ensure the signing step ran against the
correct `.app` path.

**`stapler validate` fails**  
Notarization may still be in progress. Wait a few minutes and retry  
`xcrun stapler staple <dmg>`.

**Wrong architecture**  
Run `lipo -info <binary>` to confirm `arm64`. If Homebrew libraries are
`x86_64`, you may have an Intel Homebrew installation at `/usr/local` taking
precedence over the Apple Silicon one at `/opt/homebrew`. Ensure
`/opt/homebrew/bin` appears first in `PATH`.
