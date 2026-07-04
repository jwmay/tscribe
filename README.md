# Tscribe

A native macOS app that transcribes video and audio **entirely on-device** — nothing is ever uploaded — with accurate word-level timestamps. Built for private, evidentiary-sensitive work (e.g. legal recordings).

## Editions

Both editions are the **complete app** — they differ only in whether the speech model ships
inside or downloads once. Built from **one codebase**, distinguished by the `DOWNLOAD_MODEL`
compile flag (see [CLAUDE.md](CLAUDE.md)):

| | **Standard** (`ReleaseStandard`) | **Complete** (`Release`) |
|---|---|---|
| Speech model | downloaded once on first launch | bundled inside the `.app` |
| DMG | `Tscribe.dmg` — a few MB | `Tscribe-Complete.dmg` — ~2.7 GB |
| First launch | one-time ~2.9 GB model download, then offline | works immediately, fully offline |
| Network | only the one-time model download (from Hugging Face) | never |
| Distribution | **primary** — GitHub Release (CI-built) | offline variant — manual → Drive |

In both editions the user's **recordings and transcripts never leave the Mac** — the Standard
download only fetches the app's own speech model.

## Stack
- **UI:** SwiftUI (macOS 14+)
- **Transcription:** [whisper.cpp](https://github.com/ggml-org/whisper.cpp) `large-v3`, run locally (Metal-accelerated)
- **Audio extraction:** AVFoundation (video → 16 kHz mono WAV)
- **Project generation:** [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Building
Requires: Xcode, `brew install xcodegen cmake ffmpeg`, and a local build of whisper.cpp.

```sh
xcodegen generate          # regenerate tscribe.xcodeproj from project.yml
open tscribe.xcodeproj      # or build from CLI:
xcodebuild -project tscribe.xcodeproj -scheme tscribe -configuration Debug build
```

During development the app falls back to the whisper.cpp checkout at `~/Developer/whisper.cpp`.
The small `whisper-cli` binary and Silero VAD model are vendored in `engine/` for hermetic
local + CI builds; the 2.9 GB `ggml-large-v3.bin` model is never committed (Complete bundles it at
package time; Standard downloads it at first launch).

## Releasing

```sh
scripts/package-standard.sh    # Tscribe.dmg — tiny, model downloaded on first launch (primary)
scripts/package-complete.sh    # Tscribe-Complete.dmg — ~2.7 GB, model bundled (manual distribution)
```

The Standard DMG (`Tscribe.dmg`) is also built and attached to a GitHub Release automatically on
`v*` tag push (`.github/workflows/release.yml`). See [CLAUDE.md](CLAUDE.md) for the full workflow.

## Status
v1.1.0 — Standard + Complete editions.
