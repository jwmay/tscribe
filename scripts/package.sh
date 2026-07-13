#!/bin/bash
set -euo pipefail

# Packages Tscribe into a self-contained .dmg.
#
# Signing (controlled by two env vars; both default off → the free ad-hoc path):
#   default              Ad-hoc signed (no Apple Developer account). First launch on
#                        another Mac needs the one-time right-click → Open → Open.
#   SIGN_ID=...          A Developer ID Application identity → a Gatekeeper-friendly
#                        signed build (hardened runtime + secure timestamp). Find it
#                        with `security find-identity -v -p codesigning`, e.g.
#                        SIGN_ID="Developer ID Application: Jane Doe (ABCDE12345)".
#   + NOTARY_PROFILE=... A `notarytool store-credentials` profile name → also notarize
#                        + staple the app AND the dmg, so both open on a normal
#                        double-click and validate fully offline. Requires SIGN_ID.
#   Example:
#     SIGN_ID="Developer ID Application: Jane Doe (ABCDE12345)" \
#     NOTARY_PROFILE=tscribe-notary scripts/package.sh --edition standard
#
# Usage: package.sh [--edition standard|complete]
#
#   standard  (default)  Bundles whisper-cli + Silero VAD + (when vendored) the small
#                        speaker-diarization engine (~50-MB DMG). The 2.9 GB large-v3
#                        model is downloaded once on first launch.
#                        Built with the DOWNLOAD_MODEL flag (ReleaseStandard config)
#                        so the downloader + onboarding are compiled in. The primary
#                        distribution → Tscribe.dmg.
#
#   complete             Bundles whisper-cli + Silero VAD + the 2.9 GB large-v3 model.
#                        Transcribes 100% offline from first launch. ~2.7 GB DMG,
#                        distributed manually (too big for GitHub's 2 GiB limit).
#                        → Tscribe-Complete.dmg.

EDITION="standard"
while [ $# -gt 0 ]; do
  case "$1" in
    --edition) EDITION="${2:-}"; shift 2 ;;
    --edition=*) EDITION="${1#*=}"; shift ;;
    *) echo "Unknown argument: $1"; exit 2 ;;
  esac
done
case "$EDITION" in standard|complete) ;; *) echo "Invalid edition: $EDITION (expected standard|complete)"; exit 2 ;; esac

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE_DIR="$PROJECT_DIR/engine"
WHISPER_DIR="$HOME/Developer/whisper.cpp"
BUILD_DIR="$PROJECT_DIR/build"
DIST_DIR="$PROJECT_DIR/dist"
APP_NAME="Tscribe"

# Small artifacts are vendored (hermetic + CI-friendly); the big model is not committed.
CLI="$ENGINE_DIR/whisper-cli"
VAD="$ENGINE_DIR/ggml-silero-v5.1.2.bin"
MODEL="$WHISPER_DIR/models/ggml-large-v3.bin"

# Speaker diarization (optional, small, no network) — bundled in BOTH editions when
# vendored. Absence just hides the "Identify Speakers" feature at runtime.
DIAR_CLI="$ENGINE_DIR/sherpa-onnx-offline-speaker-diarization"
DIAR_SEG="$ENGINE_DIR/diarize-segmentation.onnx"
DIAR_EMB="$ENGINE_DIR/diarize-embedding.onnx"

if [ "$EDITION" = "complete" ]; then
  CONFIG="Release"
  DMG_NAME="Tscribe-Complete.dmg"
else
  CONFIG="ReleaseStandard"
  DMG_NAME="Tscribe.dmg"
fi

echo "==> Edition: $EDITION  (config: $CONFIG)"

echo "==> Checking engine artifacts"
for f in "$CLI" "$VAD"; do
  [ -f "$f" ] || { echo "   MISSING: $f"; exit 1; }
done
if [ "$EDITION" = "complete" ]; then
  [ -f "$MODEL" ] || { echo "   MISSING: $MODEL (required for the Complete edition)"; exit 1; }
fi

# Standard drift-guard: the model the Standard app will download must be the exact
# bytes the Complete edition bundles. Verify the pinned SHA in ModelInstaller.swift
# against the canonical local model when it's available (skipped on CI, no model).
if [ "$EDITION" = "standard" ]; then
  EXPECTED_SHA="$(grep -Eo 'sha256 = "[0-9a-f]{64}"' "$PROJECT_DIR/Sources/Core/ModelInstaller.swift" | grep -Eo '[0-9a-f]{64}' | head -1)"
  [ -n "$EXPECTED_SHA" ] || { echo "   Could not read pinned model SHA from ModelInstaller.swift"; exit 1; }
  if [ -f "$MODEL" ]; then
    echo "==> Drift-guard: verifying local model matches pinned SHA"
    ACTUAL_SHA="$(shasum -a 256 "$MODEL" | cut -d' ' -f1)"
    if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
      echo "   SHA MISMATCH:"
      echo "     pinned (ModelSpec):  $EXPECTED_SHA"
      echo "     local model:         $ACTUAL_SHA"
      echo "   Update ModelSpec (and re-verify the Complete bundle) before shipping."
      exit 1
    fi
    echo "   OK: model matches pinned SHA ($EXPECTED_SHA)"
  else
    echo "==> Drift-guard skipped (no local model to verify; pinned SHA: $EXPECTED_SHA)"
  fi
fi

echo "==> Building $CONFIG"
cd "$PROJECT_DIR"
xcodegen generate >/dev/null
# SPM clones dependencies (Sparkle) as *bare* git repos. A developer whose global git
# config sets `safe.bareRepository = explicit` (a reasonable hardening choice) makes git
# refuse to operate in them, and package resolution dies with "Couldn't get the list of
# tags". Scope the exemption to this build's git subprocesses rather than asking anyone to
# weaken their global config. Harmless where the setting isn't used (e.g. CI).
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all \
xcodebuild -project tscribe.xcodeproj -scheme tscribe -configuration "$CONFIG" \
  -derivedDataPath "$BUILD_DIR" CODE_SIGNING_ALLOWED=NO build >/dev/null

APP="$BUILD_DIR/Build/Products/$CONFIG/$APP_NAME.app"
[ -d "$APP" ] || { echo "   Build did not produce $APP"; exit 1; }

echo "==> Bundling engine into $APP_NAME.app/Contents/Resources"
RES="$APP/Contents/Resources"
mkdir -p "$RES"
cp "$CLI" "$RES/whisper-cli"
cp "$VAD" "$RES/ggml-silero-v5.1.2.bin"
chmod +x "$RES/whisper-cli"

# Speaker diarization: bundle in both editions when the artifacts are present.
DIAR_BUNDLED=0
if [ -f "$DIAR_CLI" ] && [ -f "$DIAR_SEG" ] && [ -f "$DIAR_EMB" ]; then
  echo "    + bundling speaker diarization (sherpa-onnx CLI + 2 ONNX models)"
  cp "$DIAR_CLI" "$RES/sherpa-onnx-offline-speaker-diarization"
  cp "$DIAR_SEG" "$RES/diarize-segmentation.onnx"
  cp "$DIAR_EMB" "$RES/diarize-embedding.onnx"
  chmod +x "$RES/sherpa-onnx-offline-speaker-diarization"
  DIAR_BUNDLED=1
else
  echo "    note: speaker-diarization artifacts not in engine/ — 'Identify Speakers' will be hidden"
fi

if [ "$EDITION" = "complete" ]; then
  echo "    + bundling large-v3 model (2.9 GB)"
  cp "$MODEL" "$RES/ggml-large-v3.bin"
else
  echo "    (skipping large-v3 model — downloaded on first launch)"
fi

# Credits.html is auto-loaded by the standard macOS About panel (third-party
# attribution incl. the CC-BY-4.0 speaker-embedding model).
CREDITS="$PROJECT_DIR/assets/Credits.html"
[ -f "$CREDITS" ] && cp "$CREDITS" "$RES/Credits.html"

BIN="$APP/Contents/MacOS/$APP_NAME"
PLIST="$APP/Contents/Info.plist"
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"

# The appcast host, read from the ONE place it is defined, so this audit can never drift
# out of sync with what the app actually ships (change the feed URL and the audit follows).
FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$PROJECT_DIR/assets/Info-Sparkle.plist" 2>/dev/null || true)"
FEED_HOST="$(printf '%s' "$FEED_URL" | sed -E 's#^https?://([^/]+).*#\1#')"
[ -n "$FEED_HOST" ] || { echo "   Could not read SUFeedURL from assets/Info-Sparkle.plist"; exit 1; }

# Sparkle: an SPM dependency links into EVERY config, so Xcode embeds the framework even in
# the Complete build. Complete references zero Sparkle symbols and is linked with
# -dead_strip_dylibs, so it carries no load command for it — which makes the embedded copy
# dead weight that we can (and must) delete. The audit below then PROVES it's gone.
if [ "$EDITION" = "complete" ]; then
  if [ -d "$SPARKLE_FW" ]; then
    echo "    - removing embedded Sparkle.framework (Complete makes no network connections)"
    rm -rf "$SPARKLE_FW"
    rmdir "$APP/Contents/Frameworks" 2>/dev/null || true
  fi
else
  [ -d "$SPARKLE_FW" ] || { echo "   MISSING: $SPARKLE_FW — the Standard build must embed Sparkle"; exit 1; }
  echo "    + Sparkle.framework embedded (auto-updates)"
fi

# Stamp the packaging date. The Complete edition can never ask whether it's out of date, so
# it instead compares this against today, entirely offline, and says so once it's genuinely
# old. Must happen BEFORE signing — editing Info.plist afterwards would break the seal.
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
/usr/libexec/PlistBuddy -c "Add :TscribeBuildDate string $BUILD_DATE" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :TscribeBuildDate $BUILD_DATE" "$PLIST"

# ── Complete offline-audit ───────────────────────────────────────────────────────────────
# The "no network, ever" claim is only worth something if it's checked. The Complete build
# must contain no way to reach the network on its own: no model-download URL, and (since
# 2.1) no updater either — no appcast URL, no Sparkle framework, no Sparkle load command,
# no Sparkle Info.plist keys. All of it is behind #if DOWNLOAD_MODEL / #if SPARKLE_UPDATES,
# so if any of it shows up here, a guard has been dropped and the edition is a lie.
#
# The one URL that legitimately remains is the Tscribe page (OfflineUpdateInfo), which is
# only ever handed to NSWorkspace to open the user's *browser*. Tscribe still fetches
# nothing. That's why we grep for the appcast host specifically, not for "any URL".
if [ "$EDITION" = "complete" ]; then
  echo "==> Offline audit (Complete): proving this build cannot phone home"
  FAILED=0

  if strings -a "$BIN" | grep -q "huggingface.co"; then
    echo "   FAIL: Hugging Face model-download URL is in the binary — #if DOWNLOAD_MODEL leaked."
    FAILED=1
  else
    echo "   OK: no model-download URL"
  fi

  if strings -a "$BIN" | grep -qiE "$FEED_HOST|appcast"; then
    echo "   FAIL: appcast URL/reference is in the binary — #if SPARKLE_UPDATES leaked."
    strings -a "$BIN" | grep -iE "$FEED_HOST|appcast" | head -5 | sed 's/^/         /'
    FAILED=1
  else
    echo "   OK: no appcast URL ($FEED_HOST)"
  fi

  # A string can hide in a resource; a *load command* cannot. If the binary still links
  # Sparkle, the framework isn't dead code and removing it above would crash the app at
  # launch — so this check is both an audit and a safety net.
  if otool -L "$BIN" | grep -qi sparkle; then
    echo "   FAIL: the binary still links Sparkle.framework — it is NOT dead-stripped."
    FAILED=1
  else
    echo "   OK: binary has no Sparkle load command (dead-stripped)"
  fi

  if [ -e "$SPARKLE_FW" ]; then
    echo "   FAIL: Sparkle.framework is still embedded in the bundle."
    FAILED=1
  else
    echo "   OK: no Sparkle.framework in the bundle"
  fi

  if /usr/libexec/PlistBuddy -c 'Print' "$PLIST" | grep -qE '^ *SU[A-Za-z]+ ='; then
    echo "   FAIL: Sparkle SU* keys are in Info.plist."
    FAILED=1
  else
    echo "   OK: no Sparkle keys in Info.plist"
  fi

  # Belt and braces: the feed host must not appear ANYWHERE in the bundle — not in a
  # binary, not in a plist, not in a stray resource that got copied in.
  if grep -rql "$FEED_HOST" "$APP" 2>/dev/null; then
    echo "   FAIL: the appcast host appears somewhere in the bundle:"
    grep -rql "$FEED_HOST" "$APP" 2>/dev/null | head -5 | sed 's/^/         /'
    FAILED=1
  else
    echo "   OK: appcast host absent from the entire bundle"
  fi

  [ "$FAILED" = 0 ] || { echo "   Offline audit FAILED — refusing to package a Complete build that can reach the network."; exit 1; }
  echo "   Offline audit passed."
fi

# Signing: ad-hoc by default (free path); Developer ID when SIGN_ID is set. Either way
# we sign inner-out (nested binaries before the enclosing app), which codesign requires.
SIGN_ID="${SIGN_ID:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
ENTITLEMENTS="$PROJECT_DIR/assets/tscribe.entitlements"

# Sparkle is not one binary — it's a framework containing four more pieces of code (an
# updater .app, a relauncher, and two XPC services). Every one is nested code that must
# carry our Developer ID, hardened runtime and secure timestamp, or notarization rejects
# the bundle. They are signed individually, deepest first.
#
# Deliberately NOT `codesign --deep`: Sparkle's own docs warn against it (the Downloader
# service may carry entitlements the others must not inherit), and Apple treats --deep as a
# repair tool, not a signing strategy. --deep IS used to *verify*, below.
SPARKLE_INNER=()
if [ -d "$SPARKLE_FW" ]; then
  V="$SPARKLE_FW/Versions/B"
  SPARKLE_INNER=(
    "$V/XPCServices/Installer.xpc"
    "$V/XPCServices/Downloader.xpc"
    "$V/Autoupdate"
    "$V/Updater.app"
    "$SPARKLE_FW"
  )
  for p in "${SPARKLE_INNER[@]}"; do
    [ -e "$p" ] || { echo "   MISSING Sparkle component: $p"; exit 1; }
  done
fi

INNER_BINS=( "$RES/whisper-cli" )
[ "$DIAR_BUNDLED" = 1 ] && INNER_BINS+=( "$RES/sherpa-onnx-offline-speaker-diarization" )

if [ "$SIGN_ID" = "-" ]; then
  echo "==> Ad-hoc signing (nested code first, then the app)"
  # `${arr[@]+"${arr[@]}"}` — expanding an empty array trips `set -u` on macOS's bash 3.2,
  # and SPARKLE_INNER is empty for the Complete edition.
  for p in ${SPARKLE_INNER[@]+"${SPARKLE_INNER[@]}"}; do
    codesign --force --sign - --timestamp=none "$p"
  done
  for b in "${INNER_BINS[@]}"; do
    codesign --force --sign - --timestamp=none "$b"
  done
  codesign --force --sign - --timestamp=none "$APP"
  codesign --verify --verbose=2 "$APP" || echo "   (verify note above is expected for ad-hoc)"
else
  echo "==> Developer ID signing: $SIGN_ID"
  echo "    (hardened runtime + secure timestamp; nested code first, then the app)"
  if [ ${#SPARKLE_INNER[@]} -gt 0 ]; then
    echo "    signing Sparkle's nested code (2 XPC services, Autoupdate, Updater.app, framework)"
    for p in "${SPARKLE_INNER[@]}"; do
      codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$p"
    done
  fi
  for b in "${INNER_BINS[@]}"; do
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$b"
  done
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  echo "   OK: signed with Developer ID and verified"
fi

echo "==> Sanity: bundled whisper-cli runs from its bundled location"
"$RES/whisper-cli" --help >/dev/null 2>&1 && echo "   OK: bundled whisper-cli executes"
if [ "$DIAR_BUNDLED" = 1 ]; then
  if "$RES/sherpa-onnx-offline-speaker-diarization" --help >/dev/null 2>&1; then
    echo "   OK: bundled diarizer executes"
  else
    echo "   note: diarizer --help returned nonzero (some builds print usage to stderr)"
  fi
fi

# Notarize + staple the .app BEFORE packaging, so the app the user drags out of the
# dmg carries its own ticket and validates with no first-launch network check — the
# right default for Tscribe's offline audience. Skipped unless a notary profile is set.
if [ "$SIGN_ID" != "-" ] && [ -n "$NOTARY_PROFILE" ]; then
  echo "==> Notarizing the app (uploads $APP_NAME.app to Apple's notary service)"
  APP_ZIP="$(mktemp -u).zip"
  ditto -c -k --keepParent "$APP" "$APP_ZIP"
  xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$APP_ZIP"
  xcrun stapler staple "$APP"
  echo "   OK: notarized + stapled $APP_NAME.app"
elif [ "$SIGN_ID" != "-" ]; then
  echo "==> Skipping notarization (SIGN_ID set but NOTARY_PROFILE is empty)"
  echo "    The app is signed but NOT notarized — it will still warn on first launch."
fi

mkdir -p "$DIST_DIR"

# The Sparkle enclosure (Standard only). A zip, not the dmg: it's what Sparkle's docs
# prescribe, it's a smaller download on the update path, and it keeps auto-updates
# independent of the DMG-styling machinery (which already has one macOS-version landmine in
# it — see CLAUDE.md). Zipped AFTER notarize+staple so the ticket travels inside the bundle
# and the extracted app validates with no Gatekeeper network call.
if [ "$EDITION" = "standard" ]; then
  echo "==> Creating $APP_NAME.zip (Sparkle update enclosure)"
  rm -f "$DIST_DIR/$APP_NAME.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST_DIR/$APP_NAME.zip"
  echo "   OK: $DIST_DIR/$APP_NAME.zip ($(du -sh "$DIST_DIR/$APP_NAME.zip" | cut -f1))"
fi

echo "==> Creating styled .dmg"
rm -f "$DIST_DIR/$DMG_NAME"
VOL="Tscribe Installer"
BG_SRC="$PROJECT_DIR/assets/dmg/background.png"
DS_TMPL="$PROJECT_DIR/assets/dmg/DS_Store"
ICON_SRC="$APP/Contents/Resources/AppIcon.icns"

# Detach any stale volume of this name so the mount below is unambiguous.
for stale in "/Volumes/$VOL" "/Volumes/$VOL "*; do
  [ -d "$stale" ] && hdiutil detach "$stale" -force >/dev/null 2>&1 || true
done

# Stage the app + Applications drop target (+ background if we have a template).
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
STYLED=0
if [ -f "$BG_SRC" ] && [ -f "$DS_TMPL" ]; then
  mkdir "$STAGE/.background"
  cp "$BG_SRC" "$STAGE/.background/background.png"
  STYLED=1
else
  echo "   note: missing background/DS_Store template — building a plain DMG"
fi

# Read-write DMG sized to contents + proportional headroom (the 2.9 GB Complete app
# needs real slack, not a flat pad).
STAGE_MB=$(du -sm "$STAGE" | cut -f1)
SIZE_MB=$(( STAGE_MB + STAGE_MB / 5 + 100 ))
RW="$(mktemp -u).dmg"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size "${SIZE_MB}m" "$RW" >/dev/null

if [ "$STYLED" = 1 ]; then
  # Inject the macOS-26 Finder-authored layout (icon positions, window, and the
  # background reference) + volume icon. dmgbuild/mac_alias-synthesized background
  # aliases do NOT render on macOS 26 — only a Finder-authored DS_Store does — but
  # injecting that captured template needs no Finder, so it works headless (CI).
  # Regenerate the template with scripts/style-dmg.sh if the layout/app name changes.
  ATTACH="$(hdiutil attach -readwrite -noverify -noautoopen "$RW")"
  DEV="$(printf '%s\n' "$ATTACH" | awk '/^\/dev\//{d=$1} END{print d}')"
  MNT="/Volumes/$VOL"   # deterministic: we set -volname and detached stale mounts above
  cp "$DS_TMPL" "$MNT/.DS_Store"
  if cp "$ICON_SRC" "$MNT/.VolumeIcon.icns" 2>/dev/null; then
    SetFile -a C "$MNT" 2>/dev/null || true
  fi
  sync; sync
  hdiutil detach "$DEV" >/dev/null 2>&1 || hdiutil detach "$MNT" -force >/dev/null 2>&1 || true
  echo "   OK: styled installer window (DS_Store template, volume '$VOL')"
fi

hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DIST_DIR/$DMG_NAME" >/dev/null
rm -f "$RW"; rm -rf "$STAGE"

# Sign + notarize + staple the dmg too, so the download itself opens without a
# Gatekeeper warning (belt-and-suspenders with the already-stapled app inside).
if [ "$SIGN_ID" != "-" ]; then
  echo "==> Signing the dmg"
  codesign --force --timestamp --sign "$SIGN_ID" "$DIST_DIR/$DMG_NAME"
  if [ -n "$NOTARY_PROFILE" ]; then
    echo "==> Notarizing the dmg"
    xcrun notarytool submit "$DIST_DIR/$DMG_NAME" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DIST_DIR/$DMG_NAME"
    echo "   OK: notarized + stapled $DMG_NAME"
  fi
fi

echo "==> Done"
echo "    Edition:   $EDITION"
echo "    App size:  $(du -sh "$APP" | cut -f1)"
echo "    DMG:       $DIST_DIR/$DMG_NAME  ($(du -sh "$DIST_DIR/$DMG_NAME" | cut -f1))"
