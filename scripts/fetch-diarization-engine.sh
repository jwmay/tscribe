#!/bin/bash
set -euo pipefail

# Obtains the speaker-diarization engine artifacts into engine/. These are larger
# than the other vendored artifacts (~56 MB total) so, like the 2.9 GB whisper model,
# they are fetched/built rather than committed. Run once on a dev Mac (or in CI before
# packaging) so `package.sh` will bundle "Identify Speakers" into the app.
#
# Produces (arm64, macOS):
#   engine/sherpa-onnx-offline-speaker-diarization   sherpa-onnx CLI (built from source)
#   engine/diarize-segmentation.onnx                 pyannote segmentation-3.0 (MIT)
#   engine/diarize-embedding.onnx                    WeSpeaker VoxCeleb (CC-BY-4.0)
#
# See THIRD_PARTY_NOTICES.md for licenses/attribution.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$PROJECT_DIR/engine"
SRC="${SHERPA_SRC:-$HOME/Developer/sherpa-onnx}"
SEG_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"
EMB_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_resnet34_LM.onnx"

echo "==> [1/3] segmentation model → engine/diarize-segmentation.onnx"
TMP="$(mktemp -d)"
curl -fL --retry 3 -o "$TMP/seg.tar.bz2" "$SEG_URL"
tar xjf "$TMP/seg.tar.bz2" -C "$TMP"
cp -f "$TMP/sherpa-onnx-pyannote-segmentation-3-0/model.onnx" "$ENGINE/diarize-segmentation.onnx"
rm -rf "$TMP"

echo "==> [2/3] embedding model → engine/diarize-embedding.onnx"
curl -fL --retry 3 -o "$ENGINE/diarize-embedding.onnx" "$EMB_URL"

echo "==> [3/3] building sherpa-onnx-offline-speaker-diarization (CLI, static)"
if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 https://github.com/k2-fsa/sherpa-onnx "$SRC"
fi
mkdir -p "$SRC/build"
( cd "$SRC/build"
  cmake -DCMAKE_BUILD_TYPE=Release \
    -DSHERPA_ONNX_ENABLE_PYTHON=OFF -DSHERPA_ONNX_ENABLE_TESTS=OFF \
    -DSHERPA_ONNX_ENABLE_CHECK=OFF -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
    -DSHERPA_ONNX_ENABLE_JNI=OFF -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF \
    -DSHERPA_ONNX_ENABLE_C_API=ON -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_OSX_ARCHITECTURES=arm64 .. >/dev/null
  make -j"$(sysctl -n hw.ncpu)" sherpa-onnx-offline-speaker-diarization >/dev/null )
cp -f "$SRC/build/bin/sherpa-onnx-offline-speaker-diarization" "$ENGINE/"
chmod +x "$ENGINE/sherpa-onnx-offline-speaker-diarization"

echo "==> done. engine/ now has:"
ls -lh "$ENGINE/sherpa-onnx-offline-speaker-diarization" "$ENGINE/diarize-segmentation.onnx" "$ENGINE/diarize-embedding.onnx"
"$ENGINE/sherpa-onnx-offline-speaker-diarization" --help >/dev/null 2>&1 && echo "   OK: diarizer executes" || echo "   note: --help returned nonzero (usage prints to stderr on some builds)"
