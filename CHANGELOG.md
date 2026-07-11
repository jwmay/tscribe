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
- **Player polish** — click anywhere on the video (or press **Space**) to
  toggle play/pause, QuickTime-style; Space still types normally in search and
  editing fields. Clicking a word or timestamp now preserves the play/pause
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
  filter evaluations on long transcripts). The word-wrap layout also caches
  chip measurements: SwiftUI probes a layout many times per pass, and
  re-measuring every word's text on each probe was a major hot spot. And
  rapid match-stepping (⌘G held down) no longer queues overlapping animated
  scrolls — match jumps are instant and stale scroll hops are cancelled,
  which previously left the viewport thrashing across the lazy list. Search
  filtering is debounced (~0.2 s): fast typing updates the field instantly
  but rebuilds the row set once per pause instead of once per keystroke,
  and rows enter/leave the list without transition bookkeeping. Playhead
  auto-follow now runs only during passive playback (clicking words no
  longer re-centers the view under your cursor, playing or paused), and all
  programmatic scrolls are instant — overlapping scroll animations were the
  common thread in every hang, so the class is gone, not just the cases.
  The video's click-to-toggle no longer uses a gesture recognizer (avoids
  AppKit/AVKit gesture-disambiguation event holds), and per-word tooltips
  were removed (thousands of churning tracking areas; the confidence legend
  already explains the colors). A captured live sample of the final wedge
  identified a layout-estimation livelock: the word-wrap layout answered
  width-less probes (used by the lazy list to estimate unbuilt rows) with
  "one infinite line", making every estimated row height wildly short — the
  scroll view's offset corrections and lazy re-phasing then fed each other
  forever. It now answers estimates with the last real width, so estimated
  and actual heights agree. Debug builds gain a `--stress` mode that
  storms the UI with the full interaction repertoire under a main-thread
  stall watchdog — the current build survives ~60 events/sec for a minute
  with zero stalls over 500 ms.
- **Multi-track courtroom recordings** (FTR/JAVS-style, one track per
  microphone): audio extraction now mixes **all** audio tracks and
  peak-normalizes quiet recordings. Previously only the first (often nearly
  silent) track was transcribed, which caused compressed/desynced timestamps
  and Whisper repetition loops — especially with the silence-reduction (VAD)
  option enabled.
- Search-match stepping and playhead auto-scroll now reliably reach lines that
  weren't yet rendered (two-phase scroll through the lazy list), and playback
  auto-scroll glides to the active line in one smooth motion instead of
  scrolling and then visibly re-centering.
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
