# Tscribe — project guide for Claude Code

Tscribe is a native macOS (SwiftUI, macOS 14+) app that transcribes video/audio **100%
locally** with word-level timestamps, built for privileged/evidentiary legal work. It shells
out to a bundled `whisper-cli` (whisper.cpp `large-v3`, Metal) and parses its JSON output.
Target user is non-technical, so install/first-run must be dead simple.

## Two editions, one codebase

The app ships in **two editions built from the same sources**, selected at build time by the
`LITE` Swift compilation condition:

| | **Full** | **Lite** |
|---|---|---|
| Config | `Release` (`LITE` undefined) | `ReleaseLite` (defines `LITE`) |
| large-v3 model (2.9 GB) | bundled in `Contents/Resources` | downloaded on first launch → Application Support |
| DMG | `dist/Tscribe.dmg` (~2.7 GB) | `dist/Tscribe-Lite.dmg` (a few MB) |
| Network | **none, ever** (auditable) | one-time model download only |
| Ships via | manual → Google Drive (too big for GitHub) | GitHub Release, built by CI |

Same identity for both: bundle id `com.jwmay.tscribe`, name `Tscribe`, shared version line.
Lite is the primary distribution; Full is the offline/fallback download. A Mac has one Tscribe.

**Mechanism:** `LITE` decides *whether the build knows how to download*; the **filesystem**
decides *whether the model is present yet*. All networking/onboarding code is wrapped in
`#if LITE`, so the Full binary contains **no** download URL or `URLSession` path — the offline
claim is verifiable (and enforced by the packaging offline-audit). In the Full build the
onboarding code doesn't exist and the `.onboarding` stage is never reached.

## Key files

- `project.yml` — XcodeGen manifest (**source of truth**; `tscribe.xcodeproj` is generated +
  gitignored — never edit the pbxproj). Defines the `Debug`/`Release`/`ReleaseLite` configs and
  the version. `xcodegen generate` regenerates the project.
- `Sources/Core/EngineLocator.swift` — resolves `whisperCLI` / `model` / `vadModel`. Model
  precedence: **downloaded → bundled → dev-fallback (`~/Developer/whisper.cpp`)**. `isModelBundled`
  distinguishes Full (true) from Lite (false) at runtime.
- `Sources/Core/ModelInstaller.swift` — **`#if LITE`**. The downloader: `ModelSpec` (URL / bytes /
  SHA-256), `URLSessionDownloadTask` streaming to disk, disk precheck, streamed SHA-256 verify,
  **atomic** install to Application Support, resume/cancel, error mapping, and a
  "choose an already-downloaded file" escape hatch.
- `Sources/App/TranscriberModel.swift` — app state machine (`Stage`). Owns the Lite `installer`,
  the launch gate (`init` → `.onboarding` if `EngineLocator.model == nil`), `pendingMediaURL`, and
  `open`/`load`/`reset` routing that sends users to onboarding instead of throwing `engineMissing`.
- `Sources/App/OnboardingView.swift` — **`#if LITE`**. Full-window onboarding (intro → downloading →
  verifying → installing → failed), mirroring `MissingMediaView` + `WorkingView` patterns.
- `Sources/App/ContentView.swift` — the `switch model.stage` window router (has the `.onboarding` case).
- `scripts/package.sh` — `--edition full|lite`; bundles engine, ad-hoc signs, builds a **styled DMG**
  (custom background, positioned app icon + Applications drop target, 128px icons, volume icon). Lite
  runs a **drift-guard** (local model SHA must match `ModelSpec.sha256`); Full runs an **offline-audit**
  (fails if the Hugging Face URL leaked into the binary).
- `scripts/dmg_settings.py` — `dmgbuild` config that writes the installer window layout **directly**
  (no Finder/AppleScript), so it works headless (background shells, CI). **Build dependency:**
  `python3 -m pip install --user dmgbuild` (package.sh best-effort installs it; CI installs it
  explicitly). Without it, package.sh falls back to a plain DMG.
- `scripts/DMGBackgroundGen.swift` + `assets/dmg/background.tiff` — the installer window background
  (charcoal + teal glow, wordmark, tagline, drag arrow), rendered dependency-free via AppKit like
  `IconGen.swift`. Regenerate after design changes: `swiftc -O scripts/DMGBackgroundGen.swift -o /tmp/dmgbg && /tmp/dmgbg /tmp && tiffutil -cathidpicheck /tmp/background.png /tmp/background@2x.png -out assets/dmg/background.tiff`. Icon coordinates in the generator must match `icon_locations` in `scripts/dmg_settings.py`.
- `.github/workflows/release.yml` — builds + attaches the **Lite** DMG to a GitHub Release on `v*` tags.
- `engine/` — vendored small artifacts (`whisper-cli` ~3 MB, `ggml-silero-v5.1.2.bin` ~0.9 MB) so
  local + CI builds are hermetic. The 2.9 GB model is **never** committed.

## Model spec (single source of truth: `ModelSpec` in `ModelInstaller.swift`)

- URL: `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin`
- Size: `3095033483` bytes · SHA-256: `64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2`
- To change the model: update `ModelSpec` (use `/update-model-spec`) and re-run `/release-lite`; the
  drift-guard fails the build if the pin and the canonical local model disagree.

## Common tasks (slash commands in `.claude/commands/`)

- `/build` — `xcodegen generate` + a Debug build (uses the `~/Developer/whisper.cpp` fallback).
- `/release-full` — build + package the ~2.7 GB Full DMG.
- `/release-lite` — build + package the tiny Lite DMG (drift-guarded).
- `/bump-version` — bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`.
- `/verify-engine` — assert `engine/` artifacts exist and the local model matches `ModelSpec.sha256`.
- `/update-model-spec` — recompute size + SHA-256 for a model file and update `ModelSpec`.

## Build / dev workflow

```sh
xcodegen generate
xcodebuild -project tscribe.xcodeproj -scheme tscribe -configuration Debug build      # Full-style dev build
xcodebuild -project tscribe.xcodeproj -scheme tscribe -configuration ReleaseLite build # exercise LITE paths
```

To test the Lite onboarding without pulling 2.9 GB each time: build `ReleaseLite`, ensure no model
is present (`rm -rf ~/Library/Application\ Support/Tscribe/models`), and launch — or pre-seed that
directory with a copy of the model. For fast iteration, temporarily point `ModelSpec.url` at a tiny
model (e.g. `ggml-tiny.bin`) behind `#if DEBUG`.

Sample recordings for manual testing live in the gitignored `test-media/` directory (not tracked —
they're large; keep your own local copies there).

## Versioning

Both editions share the version. Bump the two values in `project.yml`
(`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`), regenerate, then tag `vX.Y.Z` (the tag triggers
the Lite CI release). No checked-in Info.plist (`GENERATE_INFOPLIST_FILE: YES`).

## Gotchas

- **SwiftUI `VideoPlayer` SIGABRTs on macOS 26** in `_AVKit_SwiftUI` — use the `AVPlayerView`
  `NSViewRepresentable` (`PlayerView` in `TranscriptView.swift`) instead.
- **Ad-hoc signing** (no Apple Developer account): users do a one-time right-click → Open. The
  downloaded model is *data* (not executed) and lives outside the signed bundle, so it neither
  triggers Gatekeeper nor breaks the app signature.
- The **2.9 GB model is never committed**; Full bundles it from `~/Developer/whisper.cpp` at package
  time, Lite downloads it. Keep them byte-identical (enforced by the Lite drift-guard).
- Don't edit `tscribe.xcodeproj` — it's regenerated from `project.yml`.
