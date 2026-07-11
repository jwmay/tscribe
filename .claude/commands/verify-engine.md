---
description: Verify vendored engine artifacts and that the local model matches ModelSpec
allowed-tools: Bash(ls *), Bash(shasum *), Bash(grep *), Read
---

Verify the engine artifacts are in place and consistent:

1. Confirm the vendored artifacts exist and are non-empty:
   - `engine/whisper-cli` (executable, ~3 MB)
   - `engine/ggml-silero-v5.1.2.bin` (~0.9 MB)
2. Speaker diarization (optional — bundled in both editions when present; the app hides
   "Identify Speakers" if any are missing). Report present/absent for each:
   - `engine/sherpa-onnx-offline-speaker-diarization` (executable, ~15-25 MB)
   - `engine/diarize-segmentation.onnx` (pyannote segmentation-3.0, ~7 MB)
   - `engine/diarize-embedding.onnx` (WeSpeaker VoxCeleb, ~26 MB)
   If present, confirm `engine/sherpa-onnx-offline-speaker-diarization --help` runs.
3. Read the pinned SHA-256 from `Sources/Core/ModelInstaller.swift` (`ModelSpec.sha256`).
4. If `~/Developer/whisper.cpp/models/ggml-large-v3.bin` exists, `shasum -a 256` it and compare to the
   pinned SHA. Report MATCH / MISMATCH. If it's missing, note that the Complete edition and the Standard
   drift-guard both need it locally.
5. Confirm `engine/whisper-cli --help` runs (the bundled binary executes).

Summarize the results as a short checklist (✓/✗). Don't modify anything.
