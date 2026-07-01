# Tscribe

A native macOS app that transcribes video and audio **entirely on-device** — nothing is ever uploaded — with accurate word-level timestamps. Built for private, evidentiary-sensitive work (e.g. legal recordings).

## Stack
- **UI:** SwiftUI (macOS 14+)
- **Transcription:** [whisper.cpp](https://github.com/ggml-org/whisper.cpp) `large-v3`, bundled and run locally (Metal-accelerated)
- **Audio extraction:** AVFoundation (video → 16 kHz mono WAV)
- **Project generation:** [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Building
Requires: Xcode, `brew install xcodegen cmake ffmpeg`, and a local build of whisper.cpp.

```sh
xcodegen generate          # regenerate tscribe.xcodeproj from project.yml
open tscribe.xcodeproj      # or build from CLI:
xcodebuild -project tscribe.xcodeproj -scheme tscribe -configuration Debug build
```

The `whisper-cli` binary and `ggml-large-v3.bin` model are copied into the app bundle at build time (see the transcription pipeline setup).

## Status
Early scaffold. See the task list for progress.
