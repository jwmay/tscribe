#!/bin/bash
set -euo pipefail

# Packages Tscribe into a self-contained, ad-hoc-signed .dmg.
# Free (no Apple Developer account). First launch on another Mac:
# right-click the app → Open → Open (one-time Gatekeeper bypass).
#
# Usage: package.sh [--edition standard|complete]
#
#   standard  (default)  Bundles whisper-cli + Silero VAD only (a few-MB DMG). The
#                        2.9 GB large-v3 model is downloaded once on first launch.
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
if [ "$EDITION" = "complete" ]; then
  echo "    + bundling large-v3 model (2.9 GB)"
  cp "$MODEL" "$RES/ggml-large-v3.bin"
else
  echo "    (skipping large-v3 model — downloaded on first launch)"
fi

# Complete offline-audit: the "no network at all" claim should be auditable — the
# Hugging Face URL only exists behind #if DOWNLOAD_MODEL, so it must be absent here.
if [ "$EDITION" = "complete" ]; then
  echo "==> Offline audit: confirming no download URL in the Complete binary"
  if strings -a "$APP/Contents/MacOS/$APP_NAME" | grep -q "huggingface.co"; then
    echo "   FAIL: found a Hugging Face URL in the Complete build — networking code leaked in."
    exit 1
  fi
  echo "   OK: no download URL present"
fi

echo "==> Ad-hoc signing (inner binary first, then the app)"
codesign --force --sign - --timestamp=none "$RES/whisper-cli"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP" || echo "   (verify note above is expected for ad-hoc)"

echo "==> Sanity: bundled whisper-cli runs from its bundled location"
"$RES/whisper-cli" --help >/dev/null 2>&1 && echo "   OK: bundled whisper-cli executes"

echo "==> Creating styled .dmg"
mkdir -p "$DIST_DIR"
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

echo "==> Done"
echo "    Edition:   $EDITION"
echo "    App size:  $(du -sh "$APP" | cut -f1)"
echo "    DMG:       $DIST_DIR/$DMG_NAME  ($(du -sh "$DIST_DIR/$DMG_NAME" | cut -f1))"
