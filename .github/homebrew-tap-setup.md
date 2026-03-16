# Homebrew Tap Setup

This guide sets up `jimscard/homebrew-fontforge` so users can install the
notarized arm64 build of FontForge with a single `brew` command.

## How it works

After every tagged release the
[`macos-arm64-release`](.github/workflows/macos-arm64-release.yml) workflow:

1. Builds and notarizes `FontForge-<version>-arm64.dmg`
2. Creates a GitHub Release and attaches the DMG
3. Pushes an updated `Casks/fontforge.rb` to `jimscard/homebrew-fontforge`
   with the new version and SHA-256 checksum

---

## One-time setup

### 1 — Create the tap repository

Create a **public** repository named exactly `homebrew-fontforge` under your
GitHub account:

```
https://github.com/new  →  Repository name: homebrew-fontforge
```

The repository can start completely empty. The release workflow will create
`Casks/fontforge.rb` on the first run.

### 2 — Create a Personal Access Token

The workflow needs write access to the tap repo to push cask updates.

1. Go to **GitHub → Settings → Developer settings →
   Personal access tokens → Fine-grained tokens → Generate new token**.
2. Set **Resource owner** to your account (`jimscard`).
3. Under **Repository access** choose **Only select repositories** →
   select `homebrew-fontforge`.
4. Under **Permissions → Repository permissions** set **Contents** to
   **Read and write**.
5. Generate and copy the token.

### 3 — Add the token as a secret

In the **fontforge** repository (this repo):

**Settings → Secrets and variables → Actions → New repository secret**

| Secret name | Value |
|-------------|-------|
| `HOMEBREW_TAP_GITHUB_TOKEN` | The fine-grained PAT from Step 2 |

---

## Trigger the first cask publish

Push a version tag to kick off a full release:

```bash
git tag v20251009
git push origin v20251009
```

After the workflow succeeds, `jimscard/homebrew-fontforge/Casks/fontforge.rb`
will contain the correct version and SHA-256 for that release.

---

## Installing FontForge via the tap

Share these two commands with testers:

```bash
brew tap jimscard/fontforge
brew install --cask jimscard/fontforge/fontforge
```

To upgrade after a new release:

```bash
brew upgrade --cask fontforge
```

To uninstall:

```bash
brew uninstall --cask fontforge
brew untap jimscard/fontforge   # optional, removes the tap entirely
```

---

## Manually updating the cask

If you need to push a cask update outside of CI (e.g., to fix a typo):

```bash
# Compute the SHA-256 of the DMG you want to point to
shasum -a 256 FontForge-20251009-arm64.dmg

# Run the bump script directly
HOMEBREW_TAP_GITHUB_TOKEN="ghp_..." \
  .github/workflows/scripts/bump-homebrew-cask.sh \
  jimscard/homebrew-fontforge \
  20251009 \
  <sha256-from-above>
```

---

## Troubleshooting

**`brew install` fails with "sha256 mismatch"**  
The DMG was replaced after the cask was published. Re-run the bump script
with the correct SHA-256, or re-trigger the release workflow.

**Cask not found after `brew tap`**  
Ensure the tap repo is **public** and the file exists at
`Casks/fontforge.rb` (not `Formula/fontforge.rb`).

**Token push rejected**  
Verify the fine-grained PAT has **Contents: Read and write** on
`homebrew-fontforge`, not just on this repository.
