# Tscribe — project guide for Claude Code

Tscribe is a native macOS (SwiftUI, macOS 14+) app that transcribes video/audio **100%
locally** with word-level timestamps, built for privileged/evidentiary legal work. It shells
out to a bundled `whisper-cli` (whisper.cpp `large-v3`, Metal) and parses its JSON output.
Target user is non-technical, so install/first-run must be dead simple.

## Branch workflow

- **`dev`** — active development. New features and fixes are built and committed here.
- **`main`** — production. Only release-ready code; merge `dev` → `main` when shipping.
- Release tags (`vX.Y.Z`) are cut on `main` and trigger the Standard CI release.

## Two editions, one codebase

The app ships in **two editions built from the same sources**, selected at build time by two
Swift compilation conditions, `DOWNLOAD_MODEL` and `SPARKLE_UPDATES`:

Both editions are the **complete app** — they differ only in how the speech model arrives and
whether they can update themselves.

| | **Standard** (primary) | **Complete** |
|---|---|---|
| Config | `ReleaseStandard` (`DOWNLOAD_MODEL` + `SPARKLE_UPDATES`) | `Release` (neither) |
| large-v3 model (2.9 GB) | downloaded on first launch → Application Support | bundled in `Contents/Resources` |
| Auto-update | Sparkle, **opt-in** (see below) | none — no updater code at all |
| DMG | `dist/Tscribe.dmg` (~43 MB) | `dist/Tscribe-Complete.dmg` (~2.7 GB) |
| Network | one-time model download + (if allowed) a daily update check | **none, ever** (auditable) |
| Ships via | GitHub Release, built by CI | manual → Google Drive (too big for GitHub) |

Same identity for both: bundle id `com.jwmay.tscribe`, name `Tscribe`, shared version line.
Standard is the primary distribution; Complete is the offline variant. A Mac has one Tscribe.

**Mechanism:** the compilation conditions decide *whether the build knows how to reach the
network at all*; the **filesystem** decides *whether the model is present yet*. Every network
path is wrapped in `#if DOWNLOAD_MODEL` (model download + onboarding) or `#if SPARKLE_UPDATES`
(the updater), so the Complete binary contains **no** download URL, **no** appcast URL, and
**no** Sparkle framework — the offline claim is verifiable, and the packaging offline-audit
*proves* it on every build rather than trusting it. In the Complete build the onboarding code
doesn't exist and the `.onboarding` stage is never reached.

Two conditions rather than one because they are two different claims ("knows how to fetch a
model" vs "knows how to update itself"), and because **Debug defines `SPARKLE_UPDATES` but not
`DOWNLOAD_MODEL`** — so the update flow can be exercised locally without pretending to be a
Standard build.

## Key files

- `project.yml` — XcodeGen manifest (**source of truth**; `tscribe.xcodeproj` is generated +
  gitignored — never edit the pbxproj). Defines the `Debug`/`Release`/`ReleaseStandard` configs, the
  version, the Sparkle SPM dependency, and the per-config compilation conditions + `INFOPLIST_FILE`.
  `xcodegen generate` regenerates the project.
- `Sources/Core/EngineLocator.swift` — resolves `whisperCLI` / `model` / `vadModel`. Model
  precedence: **downloaded → bundled → dev-fallback (`~/Developer/whisper.cpp`)**. `isModelBundled`
  distinguishes Complete (true) from Standard (false) at runtime.
- `Sources/Core/ModelInstaller.swift` — **`#if DOWNLOAD_MODEL`**. The downloader: `ModelSpec` (URL / bytes /
  SHA-256), `URLSessionDownloadTask` streaming to disk, disk precheck, streamed SHA-256 verify,
  **atomic** install to Application Support, resume/cancel, error mapping, and a
  "choose an already-downloaded file" escape hatch.
- `Sources/App/TranscriberModel.swift` — app state machine (`Stage`). Owns the Standard `installer`,
  the launch gate (`init` → `.onboarding` if `EngineLocator.model == nil`), `pendingMediaURL`, and
  `open`/`load`/`reset` routing that sends users to onboarding instead of throwing `engineMissing`.
- `Sources/App/OnboardingView.swift` — **`#if DOWNLOAD_MODEL`**. Full-window onboarding (intro → downloading →
  verifying → installing → failed), mirroring `MissingMediaView` + `WorkingView` patterns.
- `Sources/App/ContentView.swift` — the `switch model.stage` window router (has the `.onboarding` case).
- `scripts/package.sh` — `--edition standard|complete`; bundles engine, **signs Sparkle's nested code**
  (Standard) or **strips the framework** (Complete), stamps `TscribeBuildDate`, emits `Tscribe.zip`
  (the Sparkle enclosure), signs, builds a **styled DMG**
  (custom background, positioned app icon + Applications drop target, 128px icons, volume icon; volume
  name "Tscribe Installer"). Standard runs a **drift-guard** (local model SHA must match `ModelSpec.sha256`);
  Complete runs an **offline-audit** (fails if the Hugging Face URL leaked into the binary).
  Signing is env-driven — see **Code signing & notarization** below. The offline-audit is described
  under **Auto-updates (Sparkle)**; it now also proves no updater leaked into Complete.
- **DMG styling — how it works (macOS 26 gotcha).** The installer window layout lives in a committed
  `.DS_Store` template (`assets/dmg/DS_Store`). package.sh injects it into the mounted DMG headlessly
  (no Finder, no dmgbuild) — so it works in background shells and CI. This is required because on
  **macOS 26, Finder only resolves a background reference that Finder itself authored** — dmgbuild's
  `mac_alias`-synthesized alias renders blank. So:
  - `assets/dmg/DS_Store` — the Finder-authored template (icon positions, window, background ref).
    **Regenerate it** whenever the app name, window layout, or background path changes:
    `DS_STORE_OUT=$PWD/assets/dmg/DS_Store scripts/style-dmg.sh <ReleaseStandard app> "Tscribe Installer" assets/dmg/background.png /tmp/throwaway.dmg <AppIcon.icns>`,
    then (if the capture races) grab `.DS_Store` from the built DMG. **Must be regenerated on a Mac
    whose Finder version ≥ the oldest target OS.**
  - `scripts/style-dmg.sh` — builds a styled DMG *via Finder/AppleScript* (needs a GUI session). Used
    only to author/regenerate the template, not in the normal build path.
  - `scripts/DMGBackgroundGen.swift` + `assets/dmg/background.png` — the background image (charcoal +
    teal spotlights under each icon for label legibility, wordmark, tagline, drag arrow), rendered
    dependency-free via AppKit like `IconGen.swift`. It's the **2× (1280×800) PNG** (a plain PNG, not a
    `tiffutil` HiDPI TIFF — Finder won't render those). Regenerate:
    `swiftc -O scripts/DMGBackgroundGen.swift -o /tmp/dmgbg && /tmp/dmgbg /tmp && cp /tmp/background@2x.png assets/dmg/background.png`.
    Icon coordinates in the generator must match the positions baked into the DS_Store template.
- `.github/workflows/release.yml` — on `v*` tags: builds + attaches the **Standard** DMG (`Tscribe.dmg`)
  **and `Tscribe.zip`** to a GitHub Release, then (job `publish-appcast`) signs + publishes the appcast
  to GitHub Pages. Refuses to publish anything that isn't `source=Notarized Developer ID`.
- `engine/` — vendored small artifacts (`whisper-cli` ~3 MB, `ggml-silero-v5.1.2.bin` ~0.9 MB) so
  local + CI builds are hermetic. The 2.9 GB model is **never** committed.

## Model spec (single source of truth: `ModelSpec` in `ModelInstaller.swift`)

- URL: `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin`
- Size: `3095033483` bytes · SHA-256: `64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2`
- To change the model: update `ModelSpec` (use `/update-model-spec`) and re-run `/release-standard`; the
  drift-guard fails the build if the pin and the canonical local model disagree.

## Speaker diarization ("Identify Speakers")

Whisper can't tell speakers apart, so a **second local engine** runs alongside it:
**sherpa-onnx** (Apache-2.0) offline diarization, invoked as a bundled CLI exactly like
`whisper-cli`. It uses **pyannote segmentation-3.0** (MIT) + a **WeSpeaker VoxCeleb**
embedding model (CC-BY-4.0). 100% offline, no Python — bundled in **both** editions
(small), so it never touches the download/onboarding path and the Complete offline-audit
still passes (no Hugging Face URL enters the Swift binary).

- **On-demand**, not part of every transcription: the "Identify Speakers" toolbar button
  re-extracts the audio from the retained media reference, runs the diarizer, and merges.
  Asks for the speaker count first (fixing it is the biggest accuracy lever) with an
  auto-detect option. Rendered as a **dialogue view** (grouped speaker turns); speakers are
  renamable (roster strip + click a turn header), and names flow into all 7 exports.
- Diarization is **assistive, not authoritative** (good on clean ≤2-speaker audio, rough on
  crosstalk/many speakers) — presented as human-correctable, per the evidentiary use case.

**Key files:** `Sources/Core/DiarizationService.swift` (shells out to the CLI, parses
`start -- end speaker_NN`), `Sources/Core/SpeakerMerge.swift` (pure whisperX-style overlap
merge + sentence realignment + segment splitting — unit-testable), `Sources/App/SpeakerCountSheet.swift`,
plus `Segment.speaker` / `Transcript.speakers` in `Models.swift` (doc `version` → 2,
back-compat: old files decode with no speakers), the `diarizeCLI`/`segmentationModel`/`embeddingModel`
resolvers in `EngineLocator.swift`, and the dialogue/roster UI in `TranscriptView.swift`.

**Engine artifacts (~56 MB) are fetched/built, not committed** (like the 2.9 GB model):
run `scripts/fetch-diarization-engine.sh` to download the two ONNX models + build the sherpa
CLI into `engine/` (gitignored). `package.sh` bundles + signs them in both editions **when
present**, and gracefully hides the feature when absent. The release workflow fetches them
itself (cached between runs, keyed on the fetch script) and **hard-fails** if they're missing,
so a GitHub release can never silently ship without the feature. Attribution lives in
`THIRD_PARTY_NOTICES.md` + the bundled `assets/Credits.html` (About panel).

## Actual Time (burned-in clock sync)

Evidentiary videos usually carry a burned-in wall-clock; transcripts must show **that** time,
not media-relative time. The "Actual Time" toolbar button opens `ClockSyncSheet`: it grabs the
frame at the current playback position, OCRs its clock via **Vision** (Apple framework, fully
on-device — offline-audit-safe), pre-fills the time for the user to confirm/correct, and stores
`offset = wallTime − mediaTime` as `Transcript.clockOffset` (doc `version` → 3, tolerant decode).
Segment/word times stay **media-relative** (playback/seek unaffected); the offset applies only at
display (`TranscriberModel.displayTimecode`) and in the document exports (TXT/RTF/DOCX/PDF via
`Transcript.timecode`, with 24 h wraparound). **SRT/VTT cue timings deliberately stay
media-relative** — wall-clock cues would break subtitle playback. Key files:
`Sources/Core/ClockOCR.swift` (frame + OCR + `parseTime`), `Sources/App/ClockSyncSheet.swift`.
The `test-media/icty-courtroom-3speakers.mp4` clip has a synthetic 10:47:30 clock for testing.

## Auto-updates (Sparkle) — Standard edition only

The Standard edition can update itself via **Sparkle 2.9.4** (SPM, `project.yml`). The Complete
edition contains **no updater at all** — not the code, not the framework, not the URL — and the
offline-audit proves it on every Complete build.

**Privacy posture** (the users are lawyers holding privileged material):
- **Opt-in, asked in our own words.** `SUEnableAutomaticChecks=false` is both the default *and*
  (because the key is *present*) what stops Sparkle showing its own generic permission prompt.
  `UpdateConsentSheet` asks once instead. With checks off Sparkle arms no timer and opens no
  socket: an install whose owner said "no" makes **zero** outbound connections.
- **No profiling.** ⚠️ `SUEnableSystemProfiling` alone is **not enough** — it only controls whether
  Sparkle's *prompt* offers profiling. The key that gates transmission is **`SUSendProfileInfo`**.
  Both are `false`, and `UpdaterController` also forces `sendsSystemProfile = false` at runtime.
- **No silent installs** (`SUAutomaticallyUpdate=false`): the user always sees what changed.
- **Signed updates only.** Sparkle installs nothing without a valid EdDSA signature from our key,
  so a compromised appcast host or release asset still can't push a malicious Tscribe.

**Key files**
- `assets/Info-Sparkle.plist` — the `INFOPLIST_FILE` for **Debug + ReleaseStandard only** (Xcode
  merges `GENERATE_INFOPLIST_FILE`'s keys on top of it). Holds `SUFeedURL` + `SUPublicEDKey` +
  the privacy defaults. Release (Complete) has **no** `INFOPLIST_FILE`, which is what keeps the
  appcast URL out of its Info.plist. Typed values (real booleans/integers) — `INFOPLIST_KEY_*`
  build settings would inject them as **strings**, which Sparkle silently ignores.
  ⚠️ Same double-hyphen rule as the entitlements. And **PlistBuddy strips comments** — edit by hand.
- `Sources/App/UpdaterController.swift` — `#if SPARKLE_UPDATES`. Wraps `SPUStandardUpdaterController`.
- `Sources/App/UpdateConsentSheet.swift` — `#if SPARKLE_UPDATES`. The first-run question, plus
  `CheckForUpdatesMenuItem` and `AutoUpdateToggle`. These are separate **views** on purpose: the
  updater is a *nested* ObservableObject, so its changes don't republish through `model` and a bare
  `Button(...).disabled(...)` in `.commands` would go stale.
- `Sources/App/OfflineUpdateInfo.swift` — `#if !SPARKLE_UPDATES`. The Complete edition's answer:
  it can't check, so it compares its **stamped build date** (`TscribeBuildDate`, injected into
  Info.plist by package.sh) against today, entirely offline, and offers to open the Tscribe page in
  the user's **browser**. Tscribe itself still connects to nothing.
- `scripts/make-appcast.sh` — signs the zip (`sign_update`) and emits a one-item appcast.
- `scripts/release-notes.py` — lifts the version's CHANGELOG section into the release body *and* the
  appcast `<description>` (embedded, not a `releaseNotesLink`, so Sparkle needn't fetch a 2nd host).

**Consent is asked outside onboarding, deliberately.** A user upgrading from a pre-Sparkle build
never sees onboarding, so consent can't live there or they'd never be asked. It's a sheet on the
first launch that reaches a normal screen (`UpdateSheets` in ContentView).

### How Complete stays clean (the load-bearing trick)

An SPM dependency links into **every** configuration — there is no per-config dependency. So:
1. Complete compiles without `SPARKLE_UPDATES` ⇒ references **zero** Sparkle symbols.
2. Release sets `OTHER_LDFLAGS: -Wl,-dead_strip_dylibs` ⇒ the linker **drops the load command**
   (verified: `otool -L` shows no Sparkle).
3. Because nothing links it, `package.sh` can safely **delete** `Contents/Frameworks/Sparkle.framework`
   (Xcode's embed phase copies it in regardless).
4. The **offline-audit** then proves all of it: no `huggingface.co`, no appcast host *anywhere in the
   bundle*, no Sparkle load command, no `Sparkle.framework`, no `SU*` Info.plist keys.

Steps 2 and 3 are a pair — **if you ever remove `-dead_strip_dylibs`, the Complete app will crash at
launch** (dyld can't find the framework package.sh deleted). The `otool -L` check in the audit is what
catches that, so don't weaken it. The audit has been negative-tested: giving Release the Sparkle
condition makes it fail with 3 errors.

The one URL that legitimately survives in the Complete binary is the Tscribe **page** (docmayscience.com/tscribe/),
which is only ever handed to `NSWorkspace` to open a browser. That's why the audit greps for the
*appcast host* specifically, not for "any URL".

### Signing Sparkle's nested code

Sparkle isn't one binary — the framework contains **four more** pieces of code. `package.sh` signs
them individually, **deepest first**, with Developer ID + hardened runtime + secure timestamp:

```
Sparkle.framework/Versions/B/XPCServices/Installer.xpc
Sparkle.framework/Versions/B/XPCServices/Downloader.xpc
Sparkle.framework/Versions/B/Autoupdate
Sparkle.framework/Versions/B/Updater.app
Sparkle.framework                       ← framework last, then the CLIs, then the app
```

**Never `codesign --deep` to sign** (Sparkle's own docs warn against it; Apple treats it as a repair
tool). `--deep` is fine to *verify*. No entitlements are needed — once everything carries our Team ID,
library validation is satisfied. Verified: Apple's notary service **accepted** the bundle, and all five
components report `Developer ID Application: Joseph May (B5MMX2KMWW)` + `flags=0x10000(runtime)` + a timestamp.

### The update artifact is a ZIP, not the DMG

`package.sh` emits `dist/Tscribe.zip` (`ditto -c -k --sequesterRsrc --keepParent`) **after** the app is
notarized + stapled, so the extracted app carries its ticket and validates with no network check.
Sparkle *can* consume our styled DMG (it skips dotfiles and symlinks), but the zip is smaller on the
update path and keeps auto-updates independent of the DMG-styling machinery.

⚠️ **Sparkle does not enforce notarization** — it gates on the EdDSA signature and a code-signature
match, and will happily install an un-notarized Developer-ID build (observed). So the CI check that
**refuses to publish a zip that isn't `source=Notarized Developer ID`** is the only thing standing
between users and an app that trips Gatekeeper *after* the old version is already gone. Don't remove it.

### Releasing / the appcast

- Feed: **`https://updates.docmayscience.com/appcast.xml`** — GitHub Pages **of this repo**, on a
  subdomain the maintainer owns. No cross-repo token; and because the domain is ours, the feed can
  move off GitHub later without stranding shipped apps. This URL is compiled into every Standard
  build and **can never change**.
- CI (`release.yml`, job `publish-appcast`) generates + signs the appcast and deploys it to Pages
  **after** the release assets are uploaded, so the feed never advertises a 404.
- Enclosure → the `Tscribe.zip` asset on the GitHub Release.
- **EdDSA key**: private key lives in the login keychain (`generate_keys`), never committed. CI reads
  it from the `SPARKLE_PRIVATE_KEY` secret (from `generate_keys -x`) and pipes it to `sign_update` on
  **stdin** — never a file, never an argv, so it can't surface in `ps` or a log.
- ⚠️ **Locally, `sign_update` will hang on a keychain-access prompt** (it's a different binary from the
  `generate_keys` that created the item, so it isn't in the item's ACL). Click Allow, or set
  `SPARKLE_PRIVATE_KEY` and take the same stdin path CI uses.
- Sparkle's `sign_update` / `generate_appcast` come free inside the SPM artifact
  (`build/SourcePackages/artifacts/sparkle/Sparkle/bin/`) — nothing extra to download or pin.

### 🔑 The update-signing key: custody, and why losing it is unrecoverable

The EdDSA private key is the **single most irreplaceable asset in this project** — more than the
Developer ID certificate, which Apple can reissue. This one, nobody can.

It exists in exactly **three** places (as of 2.1.0, 2026-07-13):

1. The maintainer's **login keychain** (service `https://sparkle-project.org`, account `ed25519`).
2. The maintainer's **password manager** ("Tscribe — Sparkle EdDSA update signing key").
3. The **`SPARKLE_PRIVATE_KEY`** GitHub secret (write-only; can't be read back).

**If all copies are lost, every existing install is permanently cut off from updates.** Not
inconvenienced — cut off. The *public* half (`SUPublicEDKey`) is compiled into every shipped copy of
Tscribe, and Sparkle installs nothing that isn't signed by the matching private key. A new key means a
new public key, which only reaches users via a build they'd have to download by hand — which is the
one thing auto-updates exist to avoid. There is no recovery path, only a mass email.

So: **never let the keychain be the only copy.** Re-export any time with
`build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x <file>` (that binary created the
keychain item, so it's in the item's ACL and won't prompt — `sign_update` is not, and will).

Rotating the key deliberately (compromise, say) has the same cost and needs the same plan: ship the
new public key in a build, and accept that everyone on an older build must update manually once.

### Gotcha: the `github-pages` environment is branch-locked by default

Enabling Pages auto-creates a `github-pages` environment whose deployment policy allows **only the
default branch**. The `publish-appcast` job deploys from a **tag** (`v*`), so the first tagged release
was rejected outright — the job failed with **zero steps and no log**, which looks nothing like a
build error and sends you hunting in the wrong place. If you ever see that shape of failure, check the
environment before you read a line of YAML.

Fixed permanently by adding a tag policy; if the environment is ever recreated, re-add it:

```sh
gh api -X POST repos/jwmay/tscribe/environments/github-pages/deployment-branch-policies \
  -f name='v*' -f type=tag
```

### Gotcha: Pages action versions are a matched set

`actions/upload-pages-artifact` and `actions/deploy-pages` must not skew across majors — a mismatch
fails in confusing ways. Keep them in step with the (known-good) Pages deploy in the `docmayscience`
repo; that's the reference implementation.

### Verifying a release from the outside

Don't trust the build to grade its own homework. `scripts/verify-release.py` re-checks a *published*
release the way a user's Mac would: fetches the appcast from the real URL, downloads the enclosure
GitHub actually serves, and verifies the EdDSA signature against the public key read **out of the
shipped app itself** — plus notarization, stapling, the Developer ID on all five Sparkle components,
and that no 2.9 GB model snuck into the bundle.

```sh
python3 scripts/verify-release.py          # after any release
```

⚠️ **Sparkle does not enforce notarization** (it gates on the EdDSA signature and a code-signature
match — an un-notarized Developer ID build installs fine; observed, not assumed). The CI check that
refuses to publish a zip that isn't `source=Notarized Developer ID` is therefore the *only* thing
standing between users and an app that trips Gatekeeper **after** the old version has already been
replaced. Do not remove it.

### Gotcha: `showSettingsWindow:` silently does nothing in SwiftUI

`NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)` **returns `true` and
opens nothing.** SwiftUI wires its `Settings` scene to an internal `menuAction:` handler, so the
old AppKit selector reports success while doing absolutely nothing — a false positive that looks
exactly like "the Settings scene is broken" when it is perfectly fine.

To open Settings programmatically (e.g. the DEBUG `--stage` harness), perform the **real menu
item**, which is what a click does:

```swift
let item = NSApp.mainMenu?.items.first?.submenu?.items.first { $0.title.hasPrefix("Settings") }
NSApp.sendAction(item!.action!, to: item!.target, from: item!)
```

### Where the update preference lives (and why)

Settings (⌘,) is the **canonical** home — reachable from any screen. The start screen also has a
toggle, grouped with the other checkboxes.

2.1.0 got this wrong in a way worth remembering: the toggle existed *only* on the start screen,
styled `.footnote`/`.tertiary` beneath two paragraphs of fine print. It was unfindable, and
unreachable at all with a transcript open — while the consent sheet promised the choice could be
changed "at any time". **A privacy control the user cannot find is not a privacy control**, and for
this audience that's not a cosmetic bug. If you add another standing preference, put it in Settings.

(The two start-screen checkboxes — auto-detect language, reduce false text in silence — are
deliberately *not* in Settings: they're choices about the file you're about to drop, not standing
app preferences, so they belong next to the drop zone.)

### Gotcha: SPM + `safe.bareRepository`

SPM clones dependencies as **bare** git repos. A global `safe.bareRepository = explicit` (reasonable
hardening) makes git refuse to touch them and package resolution dies with *"Couldn't get the list of
tags"*. `package.sh` scopes an exemption to its own `xcodebuild` via `GIT_CONFIG_COUNT/KEY_0/VALUE_0`
rather than asking anyone to weaken their global config.

## Common tasks (slash commands in `.claude/commands/`)

- `/build` — `xcodegen generate` + a Debug build (uses the `~/Developer/whisper.cpp` fallback).
- `/release-complete` — build + package the ~2.7 GB Complete DMG.
- `/release-standard` — build + package the tiny Standard DMG (drift-guarded).
- `/bump-version` — bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`.
- `/verify-engine` — assert `engine/` artifacts exist and the local model matches `ModelSpec.sha256`.
- `/update-model-spec` — recompute size + SHA-256 for a model file and update `ModelSpec`.

## Build / dev workflow

```sh
xcodegen generate
xcodebuild -project tscribe.xcodeproj -scheme tscribe -configuration Debug build      # Complete-style dev build
xcodebuild -project tscribe.xcodeproj -scheme tscribe -configuration ReleaseStandard build # exercise DOWNLOAD_MODEL paths
```

To test the Standard onboarding without pulling 2.9 GB each time: build `ReleaseStandard`, ensure no model
is present (`rm -rf ~/Library/Application\ Support/Tscribe/models`), and launch — or pre-seed that
directory with a copy of the model. For fast iteration, temporarily point `ModelSpec.url` at a tiny
model (e.g. `ggml-tiny.bin`) behind `#if DEBUG`.

Sample recordings for manual testing live in the gitignored `test-media/` directory (not tracked —
they're large; keep your own local copies there).

## Versioning

Both editions share the version. Bump the two values in `project.yml`
(`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`), regenerate, then tag `vX.Y.Z` (the tag triggers
the Standard CI release). No checked-in Info.plist (`GENERATE_INFOPLIST_FILE: YES`).

## Code signing & notarization

Releases are signed with a **Developer ID Application** identity (Team `B5MMX2KMWW`), built with the
**hardened runtime** + a secure timestamp, **notarized** by Apple and **stapled** — so the app opens on
a plain double-click. Since v2.0.1. (Before that it was ad-hoc signed and users had to right-click →
Open, which was miserable for non-technical users.)

`package.sh` signing is **env-driven, and ad-hoc is still the default** — so plain `scripts/package.sh`
and forks/secret-less CI keep building exactly as before:

```sh
SIGN_ID="Developer ID Application: Joseph May (B5MMX2KMWW)" \
NOTARY_PROFILE=tscribe-notary \
scripts/package.sh --edition standard
```

- `SIGN_ID` (default `-` = ad-hoc) — find it with `security find-identity -v -p codesigning`. When set,
  inner binaries are signed **inner-out** (the CLIs before the app) with `--options runtime --timestamp`.
- `NOTARY_PROFILE` — a `notarytool store-credentials` profile. Notarizes + staples **both** the `.app`
  (before it goes into the dmg, so the *extracted* app validates with **no network check** — the right
  default for an offline app) **and** the dmg.
- `assets/tscribe.entitlements` — hardened-runtime exceptions: **intentionally none**. Not sandboxed,
  spawns its CLIs as separate signed processes (not injection), no JIT. ⚠️ **Keep this file free of
  double-hyphens** — they're illegal inside XML comments, AMFI rejects them (`AMFIUnserializeXML: syntax
  error`), and **`plutil -lint` does NOT catch it**. Verify entitlements with `codesign`, never `plutil`.
- **CI** (`release.yml`) imports the cert into a throwaway keychain from 5 repo secrets — `MACOS_CERT_P12`,
  `MACOS_CERT_PASSWORD`, `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD` — and **refuses to publish**
  a dmg that isn't `source=Notarized Developer ID`. Without the secrets it falls back to ad-hoc.
- Verify any build with `spctl -a -vvv -t install <dmg>` → want `source=Notarized Developer ID`.
- **Apple holds a new team's first submission for deep analysis** — ours sat `In Progress` for hours.
  Subsequent ones take <1 min. Don't panic and don't resubmit; the submission lives server-side
  (`xcrun notarytool info <id> --keychain-profile tscribe-notary`).
- Membership is $99/yr, auto-renewing. If it ever lapses, **already-shipped apps keep working** (signatures
  are secure-timestamped and tickets don't expire) — you just can't notarize *new* builds until you renew.

## Gotchas

- **The transcript list is deliberately EAGER (`VStack`, not `LazyVStack`) and
  `FlowLayout` must stay a pure function of (proposal, subviews).** A long
  campaign of main-thread livelocks (see CHANGELOG 2.0.0) all executed inside
  LazyVStack's placement/estimation/phase machinery, fed at various times by:
  per-row `.onAppear`/`.transition` phase registrations, history-dependent
  layout answers, animated programmatic scrolls, and the 10 Hz playhead being
  published on the whole-view model. The survivors of that campaign: eager
  list + equatable value rows (`TurnBlock`/`SegmentRow` don't observe the
  model) + cached derived state (`turnGroups` etc.) + `PlaybackClock` isolated
  from the view graph + instant-only scrolls. Debug builds have a `--stress`
  storm mode (TscribeApp.swift) — run it before touching any of this.
- **Courtroom recorders (FTR/JAVS…) write one audio track per microphone**, and the first
  is often nearly silent. `AudioExtractor` therefore mixes **all** audio tracks
  (`AVAssetReaderAudioMixOutput`) and **peak-normalizes** quiet audio (+30 dB cap). Reading
  only `.first` track caused compressed timestamps ("transcript ahead of video") and Whisper
  repetition loops — especially with `--vad`, which fragments/discards too-quiet audio.

- **SwiftUI `VideoPlayer` SIGABRTs on macOS 26** in `_AVKit_SwiftUI` — use the `AVPlayerView`
  `NSViewRepresentable` (`PlayerView` in `TranscriptView.swift`) instead.
- Releases are **Developer ID signed + notarized** (see below). The downloaded model is *data* (not
  executed) and lives outside the signed bundle, so it neither triggers Gatekeeper nor breaks the
  app signature.
- The **2.9 GB model is never committed**; Complete bundles it from `~/Developer/whisper.cpp` at package
  time, Standard downloads it. Keep them byte-identical (enforced by the Standard drift-guard).
- Don't edit `tscribe.xcodeproj` — it's regenerated from `project.yml`.
