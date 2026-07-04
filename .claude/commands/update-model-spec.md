---
description: Recompute size + SHA-256 for a model file and update ModelSpec
argument-hint: [path-to-model.bin]
allowed-tools: Bash(shasum *), Bash(stat *), Bash(ls *), Edit, Read
---

Update `ModelSpec` (in `Sources/Core/ModelInstaller.swift`) to match a model file. Use this only
when the model is **intentionally** changing (e.g. a new large-v3 revision or a different model).

1. Determine the model path: use `$1` if given, otherwise
   `~/Developer/whisper.cpp/models/ggml-large-v3.bin`.
2. Compute its byte size (`stat -f%z <path>`) and SHA-256 (`shasum -a 256 <path>`).
3. Update `ModelSpec` in `Sources/Core/ModelInstaller.swift`:
   - `expectedBytes` → the new size
   - `sha256` → the new digest
   - If the download URL is also changing, update `url` too (ask the user for the new URL).
4. Show a diff of the old → new `ModelSpec` values and remind the user to:
   - re-build/re-bundle the **Full** edition so its bundled model matches the new spec, and
   - run `/release-lite` (the drift-guard will confirm the pin matches the local model).

Do not change the model identity without the user's explicit intent — this is what the Lite app
downloads on every fresh install.
