import Foundation
import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

enum ExportFormat { case docx, pdf, txt, txtTimestamped, srt, vtt, rtf }

/// A dialogue turn: one or more consecutive visible segments from the same speaker.
struct TurnGroup: Identifiable, Equatable {
    let id: UUID           // first segment's id (stable scroll anchor)
    let speaker: String?
    var segments: [Segment]
    var start: TimeInterval { segments.first?.start ?? 0 }
}

/// The 10 Hz playhead, deliberately isolated from TranscriberModel: publishing
/// the tick on the main model invalidated the entire transcript view graph ten
/// times a second, and on long documents the re-measure passes couldn't drain
/// faster than ticks arrived — an unrecoverable beachball whenever the video
/// was playing. Rows subscribe to this clock individually with change-gated
/// local state, so a tick re-renders only the row under the playhead.
final class PlaybackClock: ObservableObject {
    @Published var time: TimeInterval = 0
}

/// Drives the whole flow: import → extract → transcribe → review/edit/export,
/// plus auto-save and reopening saved transcripts.
@MainActor
final class TranscriberModel: ObservableObject {
    enum Stage: Equatable {
        case idle
        case onboarding             // Standard edition only: one-time model download (never set in Complete builds)
        case extracting
        case transcribing(Double)   // 0...1
        case ready
        case failed(String)
    }

    @Published var stage: Stage = .idle
    @Published var mediaURL: URL?
    @Published var transcript: Transcript? { didSet { invalidateDerived() } }
    @Published var isEditing = false

    /// Playhead ticks live on a separate object — see `PlaybackClock`.
    let clock = PlaybackClock()
    var currentTime: TimeInterval { clock.time }
    @Published private(set) var player: AVPlayer?

    // Speaker diarization ("Identify Speakers") — runs on demand after transcription.
    @Published private(set) var isDiarizing = false
    @Published var diarizeProgress: Double? = nil      // nil = indeterminate
    @Published var diarizeError: String? = nil

    // Transcript search / speaker filter (view state, not persisted).

    /// How search results are presented: `filter` shows only matching segments;
    /// `context` keeps the full transcript visible, highlights matches, and
    /// steps between them (Return / ⌘G).
    enum SearchMode: String, CaseIterable, Identifiable {
        case filter, context
        var id: String { rawValue }
        var label: String { self == .filter ? "Filter" : "In context" }
    }

    /// What the search field shows (updates on every keystroke).
    @Published var searchText = "" {
        didSet { if oldValue != searchText { scheduleFilterApply() } }
    }
    /// What the transcript list is actually filtered by. Debounced from
    /// `searchText`: rebuilding the row set is the expensive part (hundreds of
    /// rows enter/leave the lazy list), so it happens once per typing pause
    /// instead of once per keystroke. Clearing applies immediately.
    @Published private(set) var appliedSearchText = "" {
        didSet { if oldValue != appliedSearchText { activeMatchID = nil; invalidateDerived() } }
    }
    private var filterApplyWork: DispatchWorkItem?

    @Published var speakerFilter: String? = nil { didSet { if oldValue != speakerFilter { activeMatchID = nil; invalidateDerived() } } }
    @Published var searchMode: SearchMode = .filter { didSet { if oldValue != searchMode { activeMatchID = nil; invalidateDerived() } } }
    /// The match currently stepped-to in context mode (strong highlight + scroll target).
    @Published var activeMatchID: UUID? = nil

    private func scheduleFilterApply() {
        filterApplyWork?.cancel()
        // Apply a cleared field immediately — no lag getting the transcript back.
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            filterApplyWork = nil
            appliedSearchText = searchText
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.flushSearchFilter() }
        }
        filterApplyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Apply any pending search text right now (used before match stepping /
    /// select-all so those always act on what the user sees in the field).
    func flushSearchFilter() {
        filterApplyWork?.cancel()
        filterApplyWork = nil
        if appliedSearchText != searchText { appliedSearchText = searchText }
    }

    /// True when a text query is in effect (on the applied, debounced query).
    var isSearchActive: Bool { !appliedSearchText.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: Derived view state (cached)
    //
    // `visibleSegments` / `matchingSegmentIDs` / `turnGroups` are read many
    // times per SwiftUI update. Recomputing the O(n) text filtering on every
    // body evaluation caused main-thread hangs on long transcripts during
    // rapid interaction — so they're recomputed at most once per change to
    // the transcript, search text, speaker filter, or search mode.

    private var derivedDirty = true
    private var cachedVisible: [Segment] = []
    private var cachedMatchIDs: [UUID] = []
    private var cachedGroups: [TurnGroup] = []

    private func invalidateDerived() { derivedDirty = true }

    private func refreshDerivedIfNeeded() {
        guard derivedDirty else { return }
        derivedDirty = false
        guard let t = transcript else {
            cachedVisible = []; cachedMatchIDs = []; cachedGroups = []
            return
        }
        switch searchMode {
        case .filter:  cachedVisible = t.filteredSegments(query: appliedSearchText, speaker: speakerFilter)
        case .context: cachedVisible = t.filteredSegments(query: "", speaker: speakerFilter)
        }
        cachedMatchIDs = isSearchActive
            ? t.filteredSegments(query: appliedSearchText, speaker: speakerFilter).map(\.id)
            : []
        // Group consecutive same-speaker segments into dialogue turns. When not
        // diarized (speaker == nil), every segment is its own group.
        var groups: [TurnGroup] = []
        for seg in cachedVisible {
            if let spk = seg.speaker, groups.last?.speaker == spk {
                groups[groups.count - 1].segments.append(seg)
            } else {
                groups.append(TurnGroup(id: seg.id, speaker: seg.speaker, segments: [seg]))
            }
        }
        cachedGroups = groups
    }

    /// Segments currently visible in the transcript pane. Context mode keeps all
    /// rows (so matches are seen in context); the speaker filter narrows in both modes.
    var visibleSegments: [Segment] {
        refreshDerivedIfNeeded()
        return cachedVisible
    }

    /// IDs of segments matching the current query (+ speaker filter), in transcript order.
    var matchingSegmentIDs: [UUID] {
        refreshDerivedIfNeeded()
        return cachedMatchIDs
    }

    /// The visible segments grouped into dialogue turns.
    var turnGroups: [TurnGroup] {
        refreshDerivedIfNeeded()
        return cachedGroups
    }

    /// O(1) per-row match test (used for context-mode row highlighting).
    func matchesSearch(_ seg: Segment) -> Bool {
        guard isSearchActive, let t = transcript else { return false }
        let q = appliedSearchText.trimmingCharacters(in: .whitespaces)
        if seg.text.localizedCaseInsensitiveContains(q) { return true }
        if let name = t.displayName(forSpeaker: seg.speaker),
           name.localizedCaseInsensitiveContains(q) { return true }
        return false
    }

    /// Step to the next (+1) / previous (-1) match, wrapping at the ends.
    func stepMatch(_ delta: Int) {
        flushSearchFilter()
        let ids = matchingSegmentIDs
        guard !ids.isEmpty else { activeMatchID = nil; return }
        if let cur = activeMatchID, let i = ids.firstIndex(of: cur) {
            activeMatchID = ids[(i + delta + ids.count) % ids.count]
        } else {
            activeMatchID = delta >= 0 ? ids.first : ids.last
        }
    }

    /// 1-based position of the active match, for the "2 of 17" counter.
    var activeMatchOrdinal: Int? {
        guard let id = activeMatchID, let i = matchingSegmentIDs.firstIndex(of: id) else { return nil }
        return i + 1
    }

    /// True when a search or speaker filter is narrowing the visible rows.
    var isFiltering: Bool {
        (searchMode == .filter && isSearchActive) || speakerFilter != nil
    }

    // User-facing options (set on the import screen before a run).
    @Published var autoDetectLanguage = false
    @Published var reduceSilenceHallucinations = false

    // Library / persistence.
    @Published var recents: [TranscriptStore.RecentItem] = []
    @Published var mediaMissing = false
    @Published private(set) var isSaving = false
    @Published private(set) var lastSaved: Date?

    private let service = TranscriptionService()
    private let diarizer = DiarizationService()
    private var timeObserver: Any?
    private var currentDocURL: URL?
    private var saveWork: DispatchWorkItem?

    #if DOWNLOAD_MODEL
    /// Standard edition: downloads the large-v3 model on first launch.
    let installer = ModelInstaller()
    /// A file opened before the model is installed — transcribed once setup finishes.
    private var pendingMediaURL: URL?
    #endif

    init() {
        refreshRecents()
        #if DOWNLOAD_MODEL
        installer.onInstalled = { [weak self] in self?.finishOnboarding() }
        #endif
        stage = defaultStage
    }

    /// The screen shown at launch and after `reset()`. In the Standard edition this is
    /// the onboarding screen until the model is installed; otherwise the drop screen.
    private var defaultStage: Stage {
        #if DOWNLOAD_MODEL
        return EngineLocator.model == nil ? .onboarding : .idle
        #else
        return .idle
        #endif
    }

    private func makeOptions() -> TranscriptionOptions {
        var o = TranscriptionOptions()
        o.language = autoDetectLanguage ? "auto" : "en"
        o.useVAD = reduceSilenceHallucinations
        return o
    }

    /// Segment currently under the playhead (for highlight + auto-scroll).
    var currentSegmentID: UUID? {
        transcript?.segments.first(where: { currentTime >= $0.start && currentTime < $0.end })?.id
    }

    // MARK: Open routing

    /// A saved .tscribe reopens instantly; anything else is media to transcribe.
    func open(_ url: URL) {
        if url.pathExtension.lowercased() == TranscriptStore.fileExtension {
            openDocument(url)
        } else {
            load(url: url)
        }
    }

    // MARK: Transcribe pipeline

    func load(url: URL) {
        #if DOWNLOAD_MODEL
        // In the Standard edition, hold the file and run onboarding if the model
        // isn't installed yet, rather than failing with `engineMissing`.
        if EngineLocator.model == nil {
            pendingMediaURL = url
            stage = .onboarding
            return
        }
        #endif
        reset(keepIdle: false)
        mediaURL = url
        setupPlayer(url: url)
        stage = .extracting

        Task {
            do {
                let wav = FileManager.default.temporaryDirectory
                    .appendingPathComponent("tscribe-\(UUID().uuidString).wav")
                // Run extraction off the main actor.
                try await Task.detached(priority: .userInitiated) {
                    try await AudioExtractor.extractWAV(from: url, to: wav)
                }.value

                stage = .transcribing(0)
                let result = try await service.transcribe(wav: wav, options: makeOptions()) { frac in
                    Task { @MainActor in
                        if case .transcribing = self.stage { self.stage = .transcribing(frac) }
                    }
                }
                try? FileManager.default.removeItem(at: wav)

                transcript = result
                stage = .ready
                persist()                 // auto-save so it's reopenable
                refreshRecents()
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }

    func reset(keepIdle: Bool = true) {
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        timeObserver = nil
        player?.pause()
        player = nil
        transcript = nil
        mediaURL = nil
        clock.time = 0
        isEditing = false
        currentDocURL = nil
        mediaMissing = false
        lastSaved = nil
        isSaving = false
        isDiarizing = false
        diarizeProgress = nil
        diarizeError = nil
        searchText = ""
        speakerFilter = nil
        searchMode = .filter
        activeMatchID = nil
        clearSelection()
        if keepIdle {
            stage = defaultStage
            refreshRecents()
        }
    }

    #if DOWNLOAD_MODEL
    /// Called by `ModelInstaller` once the model is verified and installed.
    /// Transcribes a file the user dropped during setup, or returns to the drop screen.
    private func finishOnboarding() {
        if let url = pendingMediaURL {
            pendingMediaURL = nil
            load(url: url)
        } else {
            stage = .idle
        }
    }
    #endif

    // MARK: Reopen a saved document

    func openDocument(_ url: URL) {
        do {
            let doc = try TranscriptStore.load(from: url)
            reset(keepIdle: false)
            currentDocURL = url
            transcript = doc.transcript
            if let media = resolveMedia(doc) {
                mediaURL = media
                setupPlayer(url: media)
                mediaMissing = false
            } else {
                mediaURL = URL(fileURLWithPath: doc.mediaPath)   // name display only
                mediaMissing = true
            }
            stage = .ready
        } catch {
            stage = .failed("Could not open this transcript. \(error.localizedDescription)")
        }
    }

    private func resolveMedia(_ doc: TranscriptDocument) -> URL? {
        if let bookmark = doc.mediaBookmark {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: u.path) {
                return u
            }
        }
        let p = URL(fileURLWithPath: doc.mediaPath)
        return FileManager.default.fileExists(atPath: p.path) ? p : nil
    }

    /// Re-attach the original recording when a reopened transcript can't find it.
    func locateMedia() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audiovisualContent, .audio, .movie]
        if panel.runModal() == .OK, let url = panel.url {
            mediaURL = url
            setupPlayer(url: url)
            mediaMissing = false
            persist()
        }
    }

    // MARK: Playback

    private func setupPlayer(url: URL) {
        let p = AVPlayer(url: url)
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.clock.time = time.seconds }
        }
        player = p
    }

    /// When the user last seeked by clicking a word/timestamp. Playhead
    /// auto-follow stands down briefly after a user seek — the user is looking
    /// at what they clicked; scrolling it away is both wrong and wasted work.
    private(set) var lastUserSeekAt: Date = .distantPast

    /// Jump the playhead without changing play/pause state: while paused,
    /// clicking a word just moves the playhead (playback stays paused);
    /// while playing, playback continues from the new position.
    func seek(to seconds: TimeInterval) {
        lastUserSeekAt = Date()
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// True while the video is actually playing (read at event time; not for rendering).
    var isPlaying: Bool { player?.timeControlStatus == .playing }

    /// Toggle play/pause (spacebar, and clicking the video picture).
    func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    // MARK: Editing

    func binding(for segmentID: UUID) -> Binding<String> {
        Binding(
            get: { self.transcript?.segments.first(where: { $0.id == segmentID })?.text ?? "" },
            set: { newValue in
                guard let idx = self.transcript?.segments.firstIndex(where: { $0.id == segmentID }) else { return }
                self.transcript?.segments[idx].text = newValue
                self.scheduleSave()          // auto-save edits (debounced)
            }
        )
    }

    // MARK: Speaker diarization ("Identify Speakers")

    /// True when the feature can run: the engine is bundled, we have a transcript,
    /// and the original recording is reachable (diarization needs the audio).
    var canIdentifySpeakers: Bool {
        EngineLocator.isDiarizationAvailable && transcript != nil && mediaURL != nil && !mediaMissing
    }

    /// True once the current transcript has been diarized.
    var isDiarized: Bool { !(transcript?.speakers.isEmpty ?? true) }

    /// Re-extract the audio, run the diarizer, and merge speaker turns onto the
    /// existing word timestamps. `numSpeakers == nil` lets the engine auto-detect.
    func identifySpeakers(numSpeakers: Int?) {
        guard canIdentifySpeakers, let media = mediaURL else { return }
        isDiarizing = true
        diarizeProgress = nil
        diarizeError = nil

        Task {
            do {
                let wav = FileManager.default.temporaryDirectory
                    .appendingPathComponent("tscribe-diar-\(UUID().uuidString).wav")
                try await Task.detached(priority: .userInitiated) {
                    try await AudioExtractor.extractWAV(from: media, to: wav)
                }.value

                let turns = try await diarizer.diarize(wav: wav, numSpeakers: numSpeakers) { frac in
                    Task { @MainActor in self.diarizeProgress = frac }
                }
                try? FileManager.default.removeItem(at: wav)

                // Merge onto the latest transcript (picks up any edits made meanwhile).
                if let latest = transcript {
                    transcript = SpeakerMerge.assign(latest, turns: turns)
                    scheduleSave()
                }
                isDiarizing = false
            } catch {
                isDiarizing = false
                diarizeError = error.localizedDescription
            }
        }
    }

    /// Rename a speaker everywhere (keyed by roster key), debounced-saved.
    func renameSpeaker(key: String, to name: String) {
        guard let idx = transcript?.speakers.firstIndex(where: { $0.key == key }) else { return }
        transcript?.speakers[idx].name = name
        scheduleSave()
    }

    /// Two-way binding for a speaker's editable name (used by rename fields).
    func speakerNameBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { self.transcript?.speakers.first(where: { $0.key == key })?.name ?? "" },
            set: { self.renameSpeaker(key: key, to: $0) }
        )
    }

    // MARK: Multi-line selection (bulk speaker reassignment)

    @Published var selectedSegmentIDs: Set<UUID> = []
    private var selectionAnchorID: UUID?

    #if DEBUG
    /// Debug-only staging harness (see `AppDelegate.applyStagingIfRequested`):
    /// forces the Actual Time sheet open for a deterministic screenshot.
    @Published var stageClockSheet = false
    #endif

    /// ⌘-click: toggle one line in/out of the selection. The range anchor is
    /// always the last-clicked line (Finder semantics), even on a deselect.
    func toggleSelection(_ id: UUID) {
        if selectedSegmentIDs.contains(id) {
            selectedSegmentIDs.remove(id)
        } else {
            selectedSegmentIDs.insert(id)
        }
        selectionAnchorID = selectedSegmentIDs.isEmpty ? nil : id
    }

    /// ⇧-click: select the visible range from the last-clicked line to this one.
    func extendSelection(to id: UUID) {
        let visible = visibleSegments
        guard let anchor = selectionAnchorID,
              let a = visible.firstIndex(where: { $0.id == anchor }),
              let b = visible.firstIndex(where: { $0.id == id }) else {
            toggleSelection(id)
            return
        }
        for seg in visible[min(a, b)...max(a, b)] { selectedSegmentIDs.insert(seg.id) }
    }

    func clearSelection() {
        selectedSegmentIDs = []
        selectionAnchorID = nil
    }

    /// Select every line matching the current search (replaces any selection) —
    /// e.g. filter to a phrase, select all, reassign the lot in one action.
    func selectAllMatches() {
        flushSearchFilter()
        let ids = matchingSegmentIDs
        guard !ids.isEmpty else { return }
        selectedSegmentIDs = Set(ids)
        selectionAnchorID = ids.last
    }

    /// Reassign segments to a speaker (nil clears the attribution). Corrects
    /// diarization mistakes; consecutive same-speaker turns re-merge in the view.
    /// Undoable via the window's undo manager (⌘Z / ⇧⌘Z).
    func assignSpeaker(_ key: String?, toSegments ids: [UUID], undoManager: UndoManager?) {
        guard let t = transcript else { return }
        var roster = t.speakers
        if let key, !roster.contains(where: { $0.key == key }) {
            roster.append(Speaker(key: key))         // safety: roster stays consistent
        }
        applySpeakerState(ids.map { ($0, key) }, roster: roster, undoManager: undoManager)
        clearSelection()
    }

    /// Create a new (unnamed) speaker and assign the segments to it, as one
    /// undoable action — undo removes the roster entry again. Also works on a
    /// never-diarized transcript, for manual attribution.
    func assignToNewSpeaker(segments ids: [UUID], undoManager: UndoManager?) {
        guard let t = transcript else { return }
        let existing = Set(t.speakers.map(\.key))
        var n = existing.count
        var key = SpeakerMerge.keyForOrdinal(n)
        while existing.contains(key) { n += 1; key = SpeakerMerge.keyForOrdinal(n) }
        applySpeakerState(ids.map { ($0, key) },
                          roster: t.speakers + [Speaker(key: key)],
                          undoManager: undoManager)
        clearSelection()
    }

    /// Apply a speaker assignment + roster, registering the exact inverse with
    /// the undo manager. Undo re-registers through the same path, which is what
    /// makes redo work. Only the touched segments' speakers and the roster are
    /// restored — never text, so an undo can't clobber unrelated edits.
    private func applySpeakerState(_ assignment: [(UUID, String?)],
                                   roster: [Speaker],
                                   undoManager: UndoManager?) {
        guard var t = transcript else { return }
        let idSet = Set(assignment.map(\.0))
        let inverse = t.segments.filter { idSet.contains($0.id) }.map { ($0.id, $0.speaker) }
        let inverseRoster = t.speakers

        for (id, key) in assignment {
            if let i = t.segments.firstIndex(where: { $0.id == id }) {
                t.segments[i].speaker = key
            }
        }
        t.speakers = roster
        transcript = t
        scheduleSave()

        undoManager?.registerUndo(withTarget: self) { [weak undoManager] target in
            MainActor.assumeIsolated {
                target.applySpeakerState(inverse, roster: inverseRoster, undoManager: undoManager)
            }
        }
        undoManager?.setActionName("Assign Speaker")
    }

    // MARK: Actual Time (the video's burned-in clock)

    /// True when transcript timestamps are being shown as the recording's actual time.
    var hasClockOffset: Bool { transcript?.clockOffset != nil }

    /// The timestamp to display for a media time (actual time when anchored).
    func displayTimecode(_ t: TimeInterval) -> String {
        transcript?.timecode(t) ?? Timecode.hms(t)
    }

    /// Anchor the recording's clock: the on-screen clock reads `wallSeconds`
    /// (seconds since midnight) at media time `mediaTime`.
    func setClockOffset(wallSeconds: TimeInterval, atMediaTime mediaTime: TimeInterval) {
        transcript?.clockOffset = wallSeconds - mediaTime
        scheduleSave()
    }

    /// Back to media-relative timestamps.
    func clearClockOffset() {
        transcript?.clockOffset = nil
        scheduleSave()
    }

    // MARK: Persistence

    func refreshRecents() { recents = TranscriptStore.recents() }

    /// Force an immediate save (the app also auto-saves after transcription and edits).
    func saveNow() {
        persist()
        refreshRecents()
    }

    /// Reveal the saved .tscribe file (or the library folder) in Finder.
    func revealInFinder() {
        if let url = currentDocURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(TranscriptStore.libraryURL)
        }
    }

    private func persist() {
        guard let t = transcript, let media = mediaURL else { return }
        let doc = TranscriptDocument(
            mediaFileName: media.lastPathComponent,
            mediaPath: media.path,
            mediaBookmark: try? media.bookmarkData(),
            createdAt: Date(),
            transcript: t
        )
        let url = currentDocURL
            ?? TranscriptStore.autosaveURL(forMediaNamed: media.deletingPathExtension().lastPathComponent)
        currentDocURL = url
        do {
            try TranscriptStore.save(doc, to: url)
            lastSaved = Date()
        } catch { }
        isSaving = false
    }

    private func scheduleSave() {
        isSaving = true
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.persist()
            self?.refreshRecents()
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: Export

    func export(_ format: ExportFormat) {
        guard let t = transcript else { return }
        let data: Data
        let ext: String
        switch format {
        case .docx:           data = Exporter.docx(t); ext = "docx"
        case .pdf:            data = PDFExporter.pdf(t); ext = "pdf"
        case .txt:            data = Data(Exporter.plainText(t, timestamps: false).utf8); ext = "txt"
        case .txtTimestamped: data = Data(Exporter.plainText(t, timestamps: true).utf8);  ext = "txt"
        case .srt:            data = Data(Exporter.srt(t).utf8); ext = "srt"
        case .vtt:            data = Data(Exporter.vtt(t).utf8); ext = "vtt"
        case .rtf:            data = Exporter.rtf(t); ext = "rtf"
        }
        let panel = NSSavePanel()
        let base = mediaURL?.deletingPathExtension().lastPathComponent ?? "transcript"
        panel.nameFieldStringValue = "\(base).\(ext)"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }
}
