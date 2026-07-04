---
description: Build and package the Full edition DMG (~2.7 GB, model bundled)
allowed-tools: Bash(scripts/package-full.sh), Bash(scripts/package.sh *)
---

Package the **Full** edition (offline, model bundled) by running:

```sh
scripts/package-full.sh
```

This regenerates the project, builds `Release`, bundles `whisper-cli` + Silero VAD + the 2.9 GB
`ggml-large-v3.bin` model, runs the offline-audit (fails if a download URL leaked into the binary),
ad-hoc signs, and writes `dist/Tscribe.dmg`.

After it succeeds, report the app + DMG sizes it prints. Remind the user that the Full DMG exceeds
GitHub's 2 GiB asset limit and is distributed manually (e.g. Google Drive), unlike the Lite DMG.

Requires the canonical model at `~/Developer/whisper.cpp/models/ggml-large-v3.bin`.
