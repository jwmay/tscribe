---
description: Regenerate the Xcode project and do a Debug build
allowed-tools: Bash(xcodegen generate), Bash(xcodebuild *), Read
---

Build Tscribe for development:

1. Run `xcodegen generate` to regenerate `tscribe.xcodeproj` from `project.yml`.
2. Build the Debug configuration:
   `xcodebuild -project tscribe.xcodeproj -scheme tscribe -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build`
3. If the build fails, surface the compiler errors concisely and stop.

Notes:
- Debug builds use the `~/Developer/whisper.cpp` fallback for the engine + model, so no bundling is needed.
- To exercise the Standard download/onboarding code paths, build `-configuration ReleaseStandard` instead
  (this defines the `DOWNLOAD_MODEL` compile flag).
