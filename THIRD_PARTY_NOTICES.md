# Third-party notices

Tscribe runs entirely on-device and bundles the following third-party components.
Their licenses permit redistribution in this application. Attribution required by
those licenses (e.g. CC-BY-4.0) is provided here and in the app's About box.

## Speech transcription

- **whisper.cpp** — © Georgi Gerganov and the ggml-org / whisper.cpp contributors.
  License: **MIT**. Bundled as `engine/whisper-cli` (and the ggml runtime it embeds).
  https://github.com/ggml-org/whisper.cpp

- **OpenAI Whisper `large-v3` model** (ggml conversion `ggml-large-v3.bin`).
  License: **MIT** (OpenAI Whisper). Bundled in the Complete edition; downloaded on
  first launch in the Standard edition. https://github.com/openai/whisper

- **Silero VAD** (`ggml-silero-v5.1.2.bin`) — © Silero Team. License: **MIT**.
  https://github.com/snakers4/silero-vad

## Speaker diarization ("Identify Speakers")

- **sherpa-onnx** — © k2-fsa / Next-gen Kaldi. License: **Apache-2.0**. Bundled as
  `engine/sherpa-onnx-offline-speaker-diarization`.
  https://github.com/k2-fsa/sherpa-onnx

- **pyannote segmentation-3.0** (ONNX, `diarize-segmentation.onnx`) — © Hervé Bredin
  et al. License: **MIT**. Used for speech/overlap segmentation.
  https://huggingface.co/pyannote/segmentation-3.0

- **WeSpeaker VoxCeleb speaker-embedding model** (ONNX, `diarize-embedding.onnx`) —
  from the WeSpeaker project (wenet-e2e). The model weights are trained on VoxCeleb
  and distributed under **CC-BY-4.0**, which requires attribution:

  > This product uses a speaker-embedding model from the WeSpeaker project, trained
  > on the VoxCeleb dataset, licensed under CC-BY-4.0.

  https://github.com/wenet-e2e/wespeaker · https://creativecommons.org/licenses/by/4.0/

- **ONNX Runtime** — © Microsoft. License: **MIT**. Statically linked inside the
  sherpa-onnx binary. https://github.com/microsoft/onnxruntime

The pyannote and WeSpeaker ONNX models are redistributed via the k2-fsa sherpa-onnx
model releases, which are ungated. Diarization runs 100% offline — no network access,
consistent with the Complete edition's auditable offline guarantee.
