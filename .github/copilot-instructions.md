# FontForge Copilot Instructions

## Build

**Standard build (Ninja recommended):**
```bash
mkdir build && cd build
cmake -GNinja ..
ninja
sudo ninja install
```

**Key CMake options:**
| Option | Default | Description |
|--------|---------|-------------|
| `BUILD_SHARED_LIBS` | ON | Build libfontforge as a shared library |
| `ENABLE_GUI` | ON | GTK3 GUI support |
| `ENABLE_NATIVE_SCRIPTING` | ON | Native `.pe` script interpreter |
| `ENABLE_PYTHON_SCRIPTING` | ON | Python scripting (requires Python 3.8+) |
| `ENABLE_PYTHON_EXTENSION` | AUTO | Python extension module (`fontforge.so`) |
| `ENABLE_SANITIZER` | none | `address`, `leak`, `thread`, `undefined`, or `memory` |
| `ENABLE_FREETYPE_DEBUGGER` | `` | Path to FreeType source for TrueType hint debugger |

**No-GUI / Python-only build** (wheel mode):
```bash
cmake -GNinja -DENABLE_GUI=OFF -DENABLE_NATIVE_SCRIPTING=OFF -DENABLE_PYTHON_EXTENSION=ON ..
```

**Apply clang-format:**
```bash
ninja format   # Uses .clang-format in repo root
```

## Testing

**Run all tests** (use `check`, not `test` — it downloads required fonts first):
```bash
ninja check
# or with parallelism:
CTEST_PARALLEL_LEVEL=100 ninja check
```

**Run a single test:**
```bash
ctest -R test001 --output-on-failure        # native scripting test
ctest -R test0001 --output-on-failure       # Python test
ctest -R "_pyhook" --output-on-failure      # all pyhook tests
ctest -N                                    # list all test names without running
```

Tests only register when `ENABLE_NATIVE_SCRIPTING=ON` or `ENABLE_PYTHON_SCRIPTING` is available.

**Test types:**
- `tests/test*.pe` — Native FontForge script tests, run via the `fontforgeexe` binary
- `tests/test*.py` — Python tests, run via the `fontforge` Python extension
- `tests/systestdriver.cpp` — Standalone C++17 test runner that handles missing fonts (skips rather than fails)

Some tests require extra fonts in `tests/fonts/`; two are auto-downloaded (NotoSans, MunhwaGothic).

## Architecture

The build produces these distinct components:

| Component | Source | Output |
|-----------|--------|--------|
| **libfontforge** | `fontforge/` | `libfontforge.so` / `.a` — core library |
| **fontforgeexe** | `fontforgeexe/` | `fontforge` binary — GUI app (needs `ENABLE_GUI`) |
| **gdraw** | `gdraw/` | `libgdraw.a` — GTK3/Cairo/GDK3 drawing abstraction |
| **gutils** | `gutils/` | Object library — image I/O, filesystem, i18n |
| **fontforge_pyhook** | `pyhook/` | `fontforge.so` — Python extension module |
| **psMat_pyhook** | `pyhook/` | `psMat.so` — psMat Python extension |

**Dependency chain:**
```
gutils (OBJECT) → fontforge (SHARED/STATIC) → gdraw (STATIC) → fontforgeexe (EXE)
                                             ↘ pyhook (MODULE .so)
```

**fontforge/ (core library):** ~200 C files. Contains all font parsing (TTF, OTF, CFF, Type1, UFO, SVG, SFD), generation, spline math, OpenType table handling (GSUB/GPOS/AAT), autohinting, and the Python API implementation. Key data structures are in `inc/fontforge.h`: `SplineFont`, `SplineChar`, `SplineSet`, `Spline`, `Layer`.

**fontforgeexe/ (GUI):** ~100 C files, only built with `ENABLE_GUI=ON`. `main.c` is minimal — it calls `fontforge_main()` from the core library. The bulk is UI: `charview.c` (glyph editor), `fontview.c` (font overview), `charinfo.c`, and many dialogs.

**gdraw/ (graphics layer):** Platform-independent widget toolkit on top of GDK3/Cairo. Provides FontForge's own widget set (menus, buttons, lists, dialogs) used by `fontforgeexe/`. Not the system GTK widgets — FontForge draws its own.

**pyhook/ (Python bindings):** Two thin `.c` wrappers (`fontforgepyhook.c`, `psMatpyhook.c`) that call into the core library's `fontforge_python_init()`. On Linux/macOS, `ff_is_pyhook_context()` is a weak symbol overridden to return 1 when running in Python context.

**extern/:** Vendored `cxxopts` (CLI argument parsing for `systestdriver`) and `mINI` (INI config library).

**pycontrib/:** User-facing Python utilities (svg2glyph, FontCompare). Not part of the library build.

## Conventions

**C/C++ standard:** C17 and C++17 (`CMAKE_C_STANDARD 17`, `CMAKE_CXX_STANDARD 17`, both required).

**Coding style** (enforced via `.clang-format`, BasedOnStyle: Google):
- Indent: 4 spaces
- Pointer alignment: `int* foo` (left/type-attached)
- `SortIncludes: false`
- All new code must include `<fontforge-config.h>` as the first include in `.c` files

**Code guidelines** (from CONTRIBUTING.md):
- One statement per line
- Use `stdbool.h` booleans (`true`/`false`), not integers
- `return` statements are indented with the surrounding block, not at the left margin
- For files not following these rules, match the existing style in that file

**Header organization:**
- `inc/` — public/installed headers (exported with the library)
- Private headers live alongside their `.c` files in `fontforge/` or `fontforgeexe/`
- `fontforge-config.h` is CMake-generated from `inc/fontforge-config.h.in`

**CMake conventions:**
- Use `build_option()` (defined in `cmake/BuildUtils.cmake`) instead of plain `option()` — it supports `BOOL`, `AUTO`, `ENUM`, and `PATH` types
- `AUTO` options auto-disable when the dependency is not found
- Use `add_ff_test()` / `add_py_test()` macros (from `cmake/TestUtils.cmake`) to register tests

**Versioning:** CalVer in `YYYYMMDD` format (e.g., `20251009`). For Python wheel packaging, this is normalized to `YYYY.M.D`.

**Python compatibility:** Python 3.8+ required. The library both *extends* Python (Python can import fontforge) and *embeds* Python (FontForge can run Python scripts).

**Wheel builds:** Detected via the `SKBUILD` environment variable. GUI and native scripting are disabled; only the Python extension is built. Managed by `scikit-build-core` (`pyproject.toml`).

## macOS arm64 — Notarized DMG Distribution

### Local build (unsigned)
```bash
./scripts/build-macos-arm64.sh             # installs Homebrew deps, builds, creates DMG
./scripts/build-macos-arm64.sh --skip-deps # skip Homebrew install step
./scripts/build-macos-arm64.sh --build-dir /tmp/ff-build
```
Output: `build-arm64/osx/FontForge-<date>-<hash>.app.dmg`

Key CMake flags added by the script:
- `-DCMAKE_OSX_ARCHITECTURES=arm64`
- `-DCMAKE_OSX_DEPLOYMENT_TARGET=12.0`

### Sign + notarize (local or CI)
```bash
FF_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
FF_NOTARIZE_APPLE_ID="you@example.com" \
FF_NOTARIZE_PASSWORD="@keychain:AC_PASSWORD" \
FF_NOTARIZE_TEAM_ID="XXXXXXXXXX" \
  .github/workflows/scripts/ffsign-notarize.sh \
  build-arm64/osx/FontForge.app \
  build-arm64/osx/FontForge-*.app.dmg
```
The script signs dylibs deepest-first, then the `.app`, then the DMG; submits to `notarytool`; and staples the ticket. Requires a **Developer ID Application** certificate (not App Store).

Entitlements (`osx/entitlements.plist`) enable hardened runtime with:
- `cs.disable-library-validation` — bundled Homebrew dylibs
- `cs.allow-unsigned-executable-memory` — Python ctypes/extensions
- `cs.allow-dyld-environment-variables` — Python startup env vars

### CI workflow (`.github/workflows/macos-arm64-release.yml`)
Triggered on `v*` tags and `workflow_dispatch`. Runs on `macos-14` (Apple Silicon). Signs and notarizes only when secrets are present.

**Required GitHub Actions secrets:**
| Secret | Description |
|--------|-------------|
| `APPLE_DEVELOPER_ID_CERT_P12` | Base64-encoded `.p12` Developer ID Application certificate |
| `APPLE_DEVELOPER_ID_CERT_P12_PASSWORD` | Password for the `.p12` |
| `APPLE_SIGN_IDENTITY` | Full identity string, e.g. `Developer ID Application: Name (TEAMID)` |
| `APPLE_ID` | Apple ID email for `notarytool` |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password (generated at appleid.apple.com) |
| `APPLE_TEAM_ID` | 10-character Team ID |

See [`.github/macos-distribution-setup.md`](.github/macos-distribution-setup.md) for the full certificate export and secret-configuration walkthrough.

## Homebrew Tap (`jimscard/homebrew-fontforge`)

After a successful tag build the release workflow automatically pushes an updated `Casks/fontforge.rb` to the tap repo.

**Install command for users:**
```bash
brew tap jimscard/fontforge
brew install --cask jimscard/fontforge/fontforge
```

**Additional secret required:**
| Secret | Description |
|--------|-------------|
| `HOMEBREW_TAP_GITHUB_TOKEN` | Fine-grained PAT with `contents:write` on `jimscard/homebrew-fontforge` |

The cask bump is skipped (without error) when the secret is absent. Release DMGs are renamed to `FontForge-<version>-arm64.dmg` so the Homebrew URL is stable and predictable.

See [`.github/homebrew-tap-setup.md`](.github/homebrew-tap-setup.md) for first-time tap repository creation and token setup.

