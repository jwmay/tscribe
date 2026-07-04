---
description: Verify vendored engine artifacts and that the local model matches ModelSpec
allowed-tools: Bash(ls *), Bash(shasum *), Bash(grep *), Read
---

Verify the engine artifacts are in place and consistent:

1. Confirm the vendored artifacts exist and are non-empty:
   - `engine/whisper-cli` (executable, ~3 MB)
   - `engine/ggml-silero-v5.1.2.bin` (~0.9 MB)
2. Read the pinned SHA-256 from `Sources/Core/ModelInstaller.swift` (`ModelSpec.sha256`).
3. If `~/Developer/whisper.cpp/models/ggml-large-v3.bin` exists, `shasum -a 256` it and compare to the
   pinned SHA. Report MATCH / MISMATCH. If it's missing, note that the Complete edition and the Standard
   drift-guard both need it locally.
4. Confirm `engine/whisper-cli --help` runs (the bundled binary executes).

Summarize the results as a short checklist (✓/✗). Don't modify anything.
