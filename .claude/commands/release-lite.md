---
description: Build and package the Lite edition DMG (tiny; model downloaded on first launch)
allowed-tools: Bash(scripts/package-lite.sh), Bash(scripts/package.sh *)
---

Package the **Lite** edition (downloads the model on first launch) by running:

```sh
scripts/package-lite.sh
```

This regenerates the project, builds `ReleaseLite` (defines the `LITE` flag → downloader +
onboarding compiled in), bundles only `whisper-cli` + Silero VAD (skips the big model), runs the
**drift-guard** (the local model's SHA-256 must match `ModelSpec.sha256` in
`Sources/Core/ModelInstaller.swift`), ad-hoc signs, and writes `dist/Tscribe-Lite.dmg`.

After it succeeds, report the app + DMG sizes. This is the DMG that CI attaches to a GitHub Release
on a `v*` tag; it's small enough to fit GitHub's 2 GiB asset limit.

If the drift-guard fails, the pinned `ModelSpec` no longer matches the local model — investigate
before shipping (use `/update-model-spec` only if the model was intentionally changed).
