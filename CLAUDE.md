# Tscribe — project guide for Claude Code

Tscribe is a native macOS (SwiftUI, macOS 14+) app that transcribes video/audio **100%
locally** with word-level timestamps, built for privileged/evidentiary legal work. It shells
out to a bundled `whisper-cli` (whisper.cpp `large-v3`, Metal) and parses its JSON output.
Target user is non-technical, so install/first-run must be dead simple.

## Two editions, one codebase

The app ships in **two editions built from the same sources**, selected at build time by the
`DOWNLOAD_MODEL` Swift compilation condition:

Both editions are the **complete app** — they differ only in how the speech model arrives.

| | **Standard** (primary) | **Complete** |
|---|---|---|
| Config | `ReleaseStandard` (defines `DOWNLOAD_MODEL`) | `Release` (`DOWNLOAD_MODEL` undefined) |
| large-v3 model (2.9 GB) | downloaded on first launch → Application Support | bundled in `Contents/Resources` |
| DMG | `dist/Tscribe.dmg` (a few MB) | `dist/Tscribe-Complete.dmg` (~2.7 GB) |
| Network | one-time model download only | **none, ever** (auditable) |
| Ships via | GitHub Release, built by CI | manual → Google Drive (too big for GitHub) |

Same identity for both: bundle id `com.jwmay.tscribe`, name `Tscribe`, shared version line.
Standard is the primary distribution; Complete is the offline variant. A Mac has one Tscribe.

**Mechanism:** `DOWNLOAD_MODEL` decides *whether the build knows how to download*; the **filesystem**
decides *whether the model is present yet*. All networking/onboarding code is wrapped in
`#if DOWNLOAD_MODEL`, so the Complete binary contains **no** download URL or `URLSession` path — the
offline claim is verifiable (and enforced by the packaging offline-audit). In the Complete build the
onboarding code doesn't exist and the `.onboarding` stage is never reached.

## Key files

- `project.yml` — XcodeGen manifest (**source of truth**; `tscribe.xcodeproj` is generated +
  gitignored — never edit the pbxproj). Defines the `Debug`/`Release`/`ReleaseStandard` configs and
  the version. `xcodegen generate` regenerates the project.
- `Sources/Core/EngineLocator.swift` — resolves `whisperCLI` / `model` / `vadModel`. Model
  precedence: **downloaded → bundled → dev-fallback (`~/Developer/whisper.cpp`)**. `isModelBundled`
  distinguishes Complete (true) from Standard (false) at runtime.
- `Sources/Core/ModelInstaller.swift` — **`#if DOWNLOAD_MODEL`**. The downloader: `ModelSpec` (URL / bytes /
  SHA-256), `URLSessionDownloadTask` streaming to disk, disk precheck, streamed SHA-256 verify,
  **atomic** install to Application Support, resume/cancel, error mapping, and a
  "choose an already-downloaded file" escape hatch.
- `Sources/App/TranscriberModel.swift` — app state machine (`Stage`). Owns the Standard `installer`,
  the launch gate (`init` → `.onboarding` if `EngineLocator.model == nil`), `pendingMediaURL`, and
  `open`/`load`/`reset` routing that sends users to onboarding instead of throwing `engineMissing`.
- `Sources/App/OnboardingView.swift` — **`#if DOWNLOAD_MODEL`**. Full-window onboarding (intro → downloading →
  verifying → installing → failed), mirroring `MissingMediaView` + `WorkingView` patterns.
- `Sources/App/ContentView.swift` — the `switch model.stage` window router (has the `.onboarding` case).
- `scripts/package.sh` — `--edition standard|complete`; bundles engine, ad-hoc signs, builds a **styled DMG**
  (custom background, positioned app icon + Applications drop target, 128px icons, volume icon; volume
  name "Tscribe Installer"). Standard runs a **drift-guard** (local model SHA must match `ModelSpec.sha256`);
  Complete runs an **offline-audit** (fails if the Hugging Face URL leaked into the binary).
- **DMG styling — how it works (macOS 26 gotcha).** The installer window layout lives in a committed
  `.DS_Store` template (`assets/dmg/DS_Store`). package.sh injects it into the mounted DMG headlessly
  (no Finder, no dmgbuild) — so it works in background shells and CI. This is required because on
  **macOS 26, Finder only resolves a background reference that Finder itself authored** — dmgbuild's
  `mac_alias`-synthesized alias renders blank. So:
  - `assets/dmg/DS_Store` — the Finder-authored template (icon positions, window, background ref).
    **Regenerate it** whenever the app name, window layout, or background path changes:
    `DS_STORE_OUT=$PWD/assets/dmg/DS_Store scripts/style-dmg.sh <ReleaseStandard app> "Tscribe Installer" assets/dmg/background.png /tmp/throwaway.dmg <AppIcon.icns>`,
    then (if the capture races) grab `.DS_Store` from the built DMG. **Must be regenerated on a Mac
    whose Finder version ≥ the oldest target OS.**
  - `scripts/style-dmg.sh` — builds a styled DMG *via Finder/AppleScript* (needs a GUI session). Used
    only to author/regenerate the template, not in the normal build path.
  - `scripts/DMGBackgroundGen.swift` + `assets/dmg/background.png` — the background image (charcoal +
    teal spotlights under each icon for label legibility, wordmark, tagline, drag arrow), rendered
    dependency-free via AppKit like `IconGen.swift`. It's the **2× (1280×800) PNG** (a plain PNG, not a
    `tiffutil` HiDPI TIFF — Finder won't render those). Regenerate:
    `swiftc -O scripts/DMGBackgroundGen.swift -o /tmp/dmgbg && /tmp/dmgbg /tmp && cp /tmp/background@2x.png assets/dmg/background.png`.
    Icon coordinates in the generator must match the positions baked into the DS_Store template.
- `.github/workflows/release.yml` — builds + attaches the **Standard** DMG (`Tscribe.dmg`) to a GitHub Release on `v*` tags.
- `engine/` — vendored small artifacts (`whisper-cli` ~3 MB, `ggml-silero-v5.1.2.bin` ~0.9 MB) so
  local + CI builds are hermetic. The 2.9 GB model is **never** committed.

## Model spec (single source of truth: `ModelSpec` in `ModelInstaller.swift`)

- URL: `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin`
- Size: `3095033483` bytes · SHA-256: `64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2`
- To change the model: update `ModelSpec` (use `/update-model-spec`) and re-run `/release-standard`; the
  drift-guard fails the build if the pin and the canonical local model disagree.

## Common tasks (slash commands in `.claude/commands/`)

- `/build` — `xcodegen generate` + a Debug build (uses the `~/Developer/whisper.cpp` fallback).
- `/release-complete` — build + package the ~2.7 GB Complete DMG.
- `/release-standard` — build + package the tiny Standard DMG (drift-guarded).
- `/bump-version` — bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`.
- `/verify-engine` — assert `engine/` artifacts exist and the local model matches `ModelSpec.sha256`.
- `/update-model-spec` — recompute size + SHA-256 for a model file and update `ModelSpec`.

## Build / dev workflow

```sh
xcodegen generate
xcodebuild -project tscribe.xcodeproj -scheme tscribe -configuration Debug build      # Complete-style dev build
xcodebuild -project tscribe.xcodeproj -scheme tscribe -configuration ReleaseStandard build # exercise DOWNLOAD_MODEL paths
```

To test the Standard onboarding without pulling 2.9 GB each time: build `ReleaseStandard`, ensure no model
is present (`rm -rf ~/Library/Application\ Support/Tscribe/models`), and launch — or pre-seed that
directory with a copy of the model. For fast iteration, temporarily point `ModelSpec.url` at a tiny
model (e.g. `ggml-tiny.bin`) behind `#if DEBUG`.

Sample recordings for manual testing live in the gitignored `test-media/` directory (not tracked —
they're large; keep your own local copies there).

## Versioning

Both editions share the version. Bump the two values in `project.yml`
(`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`), regenerate, then tag `vX.Y.Z` (the tag triggers
the Standard CI release). No checked-in Info.plist (`GENERATE_INFOPLIST_FILE: YES`).

## Gotchas

- **SwiftUI `VideoPlayer` SIGABRTs on macOS 26** in `_AVKit_SwiftUI` — use the `AVPlayerView`
  `NSViewRepresentable` (`PlayerView` in `TranscriptView.swift`) instead.
- **Ad-hoc signing** (no Apple Developer account): users do a one-time right-click → Open. The
  downloaded model is *data* (not executed) and lives outside the signed bundle, so it neither
  triggers Gatekeeper nor breaks the app signature.
- The **2.9 GB model is never committed**; Complete bundles it from `~/Developer/whisper.cpp` at package
  time, Standard downloads it. Keep them byte-identical (enforced by the Standard drift-guard).
- Don't edit `tscribe.xcodeproj` — it's regenerated from `project.yml`.
