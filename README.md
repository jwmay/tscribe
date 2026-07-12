# Tscribe

A native macOS app that transcribes video and audio **entirely on-device** — nothing is ever
uploaded — with word-level timestamps. Tscribe also identifies **who** said what, anchors
timestamps to a recording's **actual** wall-clock time, and makes everything **findable** — still
100% locally. Built for private, evidentiary-sensitive work (e.g. legal recordings).

## Features

- **Word-level transcription** — whisper.cpp `large-v3`, Metal-accelerated. Every word carries a
  timestamp (click it to jump the video) and a confidence color, so low-certainty words are flagged
  for review.
- **Speaker identification** — on-demand, on-device diarization renders the transcript as grouped
  dialogue turns with per-speaker colors. You give the speaker count up front (or auto-detect) and
  name each person (roster strip or click a turn header); names flow into every export. It's
  **assistive, not authoritative** — good on clean audio, meant to be human-corrected.
- **Speaker reassignment & multi-line selection** — right-click a line, a whole turn, or a
  ⌘/⇧-click selection to move it to another speaker, a new speaker, or none — fully undoable
  (⌘Z / ⇧⌘Z). Also enables manual labeling of recordings that were never auto-diarized.
- **Actual Time** — anchor timestamps to the video's burned-in clock. Tscribe reads the clock off
  the current frame with on-device OCR (Apple's Vision), you confirm or correct it, and the
  transcript and document exports show the recording's real time (subtitle cue timings stay
  media-relative so they keep playing correctly).
- **Search & filter** — ⌘F search across transcript text and speaker names, with **Filter** and
  **In-context** modes, a per-speaker filter, and match stepping. A search field on the start
  screen scans **every** saved transcript and drops you into the right one, pre-filtered.
- **Exports** — Word (`.docx`), PDF, Rich Text, plain text (with or without timestamps), and
  SRT / VTT subtitles — all with speaker labels.
- **100% on-device** — recordings and transcripts never leave the Mac. The Complete edition makes
  no network requests at all (auditable).

## Requirements

- **Apple Silicon Mac (M1 or later)** — required. The transcription engine is Apple-Silicon-native
  and Metal-accelerated; **Intel Macs are not supported** (the app launches but can't transcribe).
- **macOS 14 (Sonoma) or later**
- **8 GB RAM** (16 GB recommended for long recordings)
- **~6 GB free disk** for the Standard first-launch model download (settles to ~3 GB); ~3 GB for the
  Complete edition
- **Internet** once, at first launch (Standard edition only) — never for transcription

## Editions

Both editions are the **complete app** — they differ only in whether the 2.9 GB speech model ships
inside or downloads once. Built from **one codebase**, distinguished by the `DOWNLOAD_MODEL`
compile flag (see [CLAUDE.md](CLAUDE.md)):

| | **Standard** (`ReleaseStandard`) | **Complete** (`Release`) |
|---|---|---|
| Speech model | downloaded once on first launch | bundled inside the `.app` |
| DMG | `Tscribe.dmg` — ~41 MB | `Tscribe-Complete.dmg` — ~2.7 GB |
| First launch | one-time ~2.9 GB model download, then offline | works immediately, fully offline |
| Network | only the one-time model download (from Hugging Face) | never |
| Distribution | **primary** — GitHub Release (CI-built) | offline variant — manual → Drive |

The speaker-identification engine (~56 MB) is **bundled in both editions**, so it never touches the
download path and the Complete edition's zero-network claim still holds. In both editions the user's
**recordings and transcripts never leave the Mac** — the Standard download only fetches the app's
own speech model.

## Stack
- **UI:** SwiftUI (macOS 14+)
- **Transcription:** [whisper.cpp](https://github.com/ggml-org/whisper.cpp) `large-v3`, run locally
  (Metal-accelerated)
- **Speaker diarization:** [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (Apache-2.0),
  offline — pyannote segmentation-3.0 (MIT) + a WeSpeaker VoxCeleb embedding model (CC-BY-4.0),
  invoked as a bundled CLI. No Python.
- **Actual Time OCR:** Apple's [Vision](https://developer.apple.com/documentation/vision) framework
  (fully on-device)
- **Audio extraction:** AVFoundation (mixes all tracks → 16 kHz mono WAV, with peak normalization)
- **Project generation:** [XcodeGen](https://github.com/yonaskolb/XcodeGen)

Third-party attribution: [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) and the About-panel
Credits.

## Building
Requires: Xcode, `brew install xcodegen cmake ffmpeg`, and a local build of whisper.cpp.

```sh
xcodegen generate          # regenerate tscribe.xcodeproj from project.yml
open tscribe.xcodeproj      # or build from CLI:
xcodebuild -project tscribe.xcodeproj -scheme tscribe -configuration Debug build
```

During development the app falls back to the whisper.cpp checkout at `~/Developer/whisper.cpp`.
The small `whisper-cli` binary and Silero VAD model are vendored in `engine/` for hermetic local +
CI builds; the 2.9 GB `ggml-large-v3.bin` model is never committed (Complete bundles it at package
time; Standard downloads it at first launch).

To build **with speaker identification**, fetch its engine once:

```sh
scripts/fetch-diarization-engine.sh   # downloads the 2 ONNX models + builds the sherpa-onnx CLI into engine/
```

These artifacts (~56 MB) are gitignored like the speech model. `package.sh` bundles them when
present and gracefully hides the feature when they're absent, so a Debug build without them still
runs (minus the "Identify Speakers" button).

## Releasing

```sh
scripts/package-standard.sh    # Tscribe.dmg — ~41 MB, model downloaded on first launch (primary)
scripts/package-complete.sh    # Tscribe-Complete.dmg — ~2.7 GB, model bundled (manual distribution)
```

(Both wrap `scripts/package.sh --edition standard|complete`.) The Standard DMG (`Tscribe.dmg`) is
also built and attached to a GitHub Release automatically on `v*` tag push
(`.github/workflows/release.yml`), which **fetches and verifies the diarization engine** (cached
between runs) and refuses to publish without it. See [CLAUDE.md](CLAUDE.md) for the full workflow.

## Status
v2.0.0 — the "transcript workbench": speaker identification, Actual Time, and search & filter, on
top of the Standard + Complete editions.
