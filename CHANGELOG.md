# Changelog

All notable changes to Tscribe. Both editions (Standard and Complete) share a
version line. Format follows [Keep a Changelog](https://keepachangelog.com);
versioning is app-marketing semver.

## [2.0.0] — 2026-07-11

The "transcript workbench" release: Tscribe now identifies **who** said what,
shows **when it actually happened**, and makes everything **findable** — still
100% on-device.

### Added
- **Speaker identification** — on-demand diarization via a bundled sherpa-onnx
  engine (pyannote segmentation-3.0 + WeSpeaker embeddings, both local; no
  network, no Python). Asks for the speaker count up front (with auto-detect),
  renders the transcript as grouped dialogue turns with per-speaker colors, and
  lets you name each speaker (roster strip or click a turn header).
- **Speaker reassignment** — right-click any line (or a turn header, or a
  multi-line selection) to move it to another speaker, a **New Speaker**, or
  clear it. Fully undoable (⌘Z / ⇧⌘Z). Also enables manual speaker labeling on
  recordings that were never auto-diarized.
- **Multi-line selection** — ⌘-click to toggle lines, ⇧-click for ranges
  (Finder semantics, operates on the filtered view), selection bar with bulk
  assign + Clear, **Select All Matches** button in the search bar, Esc clears.
- **Actual Time** — anchor transcript timestamps to the video's burned-in
  clock. Reads the clock off the current frame with on-device OCR (Vision),
  you confirm or correct it, and the transcript + document exports (TXT/RTF/
  DOCX/PDF) show the recording's real time. SRT/VTT cue timings intentionally
  stay media-relative so subtitles remain playable. Wraps correctly past
  midnight; removable at any time.
- **Search & filter** — ⌘F search over the transcript text and speaker names,
  a speaker dropdown filter, and two result modes: **Filter** (only matching
  lines) or **In context** (full transcript with highlighted matches and
  Return / ⌘G / ⇧⌘G stepping). Matched words highlight; match counter shows
  position.
- **Library-wide search** — a search field on the drop screen scans every
  saved transcript and shows per-file results with timecoded snippets; opening
  a result lands in that transcript with the query pre-loaded.
- **Speaker labels in every export** — dialogue-style speaker names in TXT,
  SRT (`Name:`), VTT (`<v Name>`), RTF, DOCX, and PDF.
- **Player polish** — click anywhere on the video to toggle play/pause
  (QuickTime-style); clicking a word or timestamp now preserves the play/pause
  state instead of force-starting playback.
- Third-party attribution: `THIRD_PARTY_NOTICES.md` and a Credits panel in the
  About box (pyannote MIT, WeSpeaker CC-BY-4.0, sherpa-onnx Apache-2.0, ONNX
  Runtime MIT).

### Fixed
- **Main-thread hangs during rapid transcript interaction** (fast ⌘-clicks,
  search typing, playback): transcript rows are now value views compared by
  equality — an update re-renders only the rows whose state changed instead
  of re-laying-out the whole list — and the filtered/grouped transcript is
  cached instead of being recomputed on every UI update (~1000× fewer
  filter evaluations on long transcripts).
- **Multi-track courtroom recordings** (FTR/JAVS-style, one track per
  microphone): audio extraction now mixes **all** audio tracks and
  peak-normalizes quiet recordings. Previously only the first (often nearly
  silent) track was transcribed, which caused compressed/desynced timestamps
  and Whisper repetition loops — especially with the silence-reduction (VAD)
  option enabled.
- Search-match stepping and playhead auto-scroll now reliably reach lines that
  weren't yet rendered (two-phase scroll through the lazy list).
- The transcript sidebar opens wide enough for all controls (and the search
  field can no longer collapse to zero width).

### Changed
- Saved-document format is now v3 (adds speakers and the Actual Time anchor).
  Older `.tscribe` files load fine. Files saved by 2.0 open in 1.x, but 1.x
  will not preserve the new fields if it re-saves them.
- Standard-edition DMG grew from a few MB to ~41 MB — it now bundles the
  speaker-identification engine (~56 MB uncompressed) in both editions. The
  2.9 GB speech model is unchanged (Standard downloads it once; Complete
  bundles it).
- Minimum window width is now 920 pt (wider transcript pane).
- CI release builds fetch and verify the diarization engine (cached between
  runs) and refuse to publish without it.

## [1.1.0] — 2026-07-04

### Added
- **Two editions from one codebase**: **Standard** (small DMG; downloads the
  speech model once on first launch, with resumable, checksum-verified
  onboarding) and **Complete** (model bundled; provably zero network access).
- Styled installer DMG (background art, icon layout, volume icon) built
  headlessly — including on macOS 26, via a Finder-authored `.DS_Store`
  template.
- CI release workflow: tagging `v*` builds and attaches the Standard DMG.

### Changed
- Editions renamed: "Lite" became **Standard** (the primary distribution);
  the bundled-model edition became **Complete**.
- Development fallbacks (local whisper.cpp checkout) are compiled only into
  Debug builds, so packaged builds behave identically on any Mac.

## [1.0.0] — 2026-06-30

Initial release.

- 100% local transcription of video/audio (whisper.cpp large-v3, Metal) with
  word-level timestamps and per-word confidence coloring.
- Side-by-side player + transcript: click a word to jump the video; the
  transcript follows playback.
- Inline editing with debounced auto-save to a `.tscribe` library
  (`~/Documents/Tscribe`) and a Recents list.
- Seven export formats: DOCX, PDF, TXT (plain + timestamped), RTF, SRT, VTT —
  each with an evidentiary draft disclaimer.
- Optional Silero-VAD "reduce false text in silence" mode and auto language
  detection.
- Ad-hoc signed, drag-to-Applications DMG (no Apple Developer account
  required).
