# Tscribe

A native macOS app that transcribes video and audio **entirely on-device** — nothing is ever uploaded — with accurate word-level timestamps. Built for private, evidentiary-sensitive work (e.g. legal recordings).

## Editions

Tscribe ships in two editions built from **one codebase**, distinguished by the `LITE`
compile flag (see [CLAUDE.md](CLAUDE.md)):

| | **Full** (`Release`) | **Lite** (`ReleaseLite`) |
|---|---|---|
| Speech model | bundled inside the `.app` | downloaded once on first launch |
| DMG size | ~2.7 GB | a few MB |
| First launch | works immediately, fully offline | one-time ~2.9 GB model download, then offline |
| Network | never | only the one-time model download (from Hugging Face) |
| Distribution | manual (too big for GitHub) → Drive | GitHub Release (CI-built) |

In both editions the user's **recordings and transcripts never leave the Mac** — the Lite
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
local + CI builds; the 2.9 GB `ggml-large-v3.bin` model is never committed (Full bundles it at
package time; Lite downloads it at first launch).

## Releasing

```sh
scripts/package-full.sh    # ~2.7 GB DMG, model bundled (manual distribution)
scripts/package-lite.sh    # tiny DMG, model downloaded on first launch
```

The Lite DMG is also built and attached to a GitHub Release automatically on `v*` tag push
(`.github/workflows/release.yml`). See [CLAUDE.md](CLAUDE.md) for the full workflow.

## Status
v1.1.0 — Full + Lite editions.
