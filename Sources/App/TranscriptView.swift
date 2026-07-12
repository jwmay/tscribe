import SwiftUI
import AVKit

/// Wraps AppKit's AVPlayerView. Used instead of SwiftUI's `VideoPlayer`, which
/// crashes in `_AVKit_SwiftUI` generic-metadata instantiation on macOS 26.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        // Click anywhere on the picture to toggle play/pause (QuickTime-style).
        // A plain mouseDown-overriding view on `contentOverlayView` (which sits
        // between the video surface and the control bar, so the controls keep
        // their clicks). Deliberately NOT a gesture recognizer: recognizers
        // join AppKit's gesture-disambiguation machinery alongside AVKit's own,
        // which can hold/route events; a raw mouseDown cannot wait on anything.
        if let overlay = view.contentOverlayView {
            let toggler = ClickToToggleView(frame: overlay.bounds)
            toggler.autoresizingMask = [.width, .height]
            toggler.onClick = { [weak view] in
                guard let player = view?.player else { return }
                if player.timeControlStatus == .playing { player.pause() } else { player.play() }
            }
            overlay.addSubview(toggler)
        }
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }

    /// Fills the video's content-overlay area; toggles on plain left-click.
    final class ClickToToggleView: NSView {
        var onClick: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onClick?() }
    }
}

/// Shown in a reopened transcript whose original recording can't be located.
private struct MissingMediaView: View {
    @ObservedObject var model: TranscriberModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Original recording not found")
                .font(.headline)
            Text("The transcript is here and fully editable. To play along and click a word to jump to it, point Tscribe back to the recording.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Locate Recording…") { model.locateMedia() }
                .controlSize(.large)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct TranscriptView: View {
    @ObservedObject var model: TranscriberModel
    @State private var showSpeakerSheet = false
    @State private var showClockSheet = false
    @State private var pendingFollowScroll: DispatchWorkItem?
    @State private var lastFollowedSegment: UUID?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                Group {
                    if model.mediaMissing {
                        MissingMediaView(model: model)
                    } else {
                        PlayerView(player: model.player)
                    }
                }
                .frame(minWidth: 320, idealWidth: 560)
                .layoutPriority(1)   // extra window width goes to the video

                // Opens at its minimum width, which is sized so the full search
                // row (field, Filter/In-context, match nav, speaker picker,
                // counter) fits even while a search is active.
                transcriptPane
                    .frame(minWidth: 730, idealWidth: 730)
            }
        }
        .frame(minWidth: 1060, minHeight: 520)
        .sheet(isPresented: $showSpeakerSheet) {
            SpeakerCountSheet { count in model.identifySpeakers(numSpeakers: count) }
        }
        .sheet(isPresented: $showClockSheet) {
            ClockSyncSheet(model: model)
        }
        .alert("Couldn’t identify speakers",
               isPresented: Binding(get: { model.diarizeError != nil },
                                    set: { if !$0 { model.diarizeError = nil } })) {
            Button("OK", role: .cancel) { model.diarizeError = nil }
        } message: {
            Text(model.diarizeError ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button { model.reset() } label: { Label("New File", systemImage: "plus") }
            if let name = model.mediaURL?.lastPathComponent {
                Text(name).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 220, alignment: .leading)
            }
            saveIndicator
            Spacer()
            actualTimeButton
            identifySpeakersButton
            Toggle(isOn: $model.isEditing) { Label("Edit", systemImage: "pencil") }
                .toggleStyle(.button)
            exportMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Anchor transcript timestamps to the video's burned-in clock. Needs the
    /// recording (for the frame), so hidden when the media is missing.
    @ViewBuilder private var actualTimeButton: some View {
        if model.transcript != nil && model.mediaURL != nil && !model.mediaMissing {
            Button { showClockSheet = true } label: {
                Label("Actual Time",
                      systemImage: model.hasClockOffset ? "clock.badge.checkmark" : "clock")
            }
            .help(model.hasClockOffset
                  ? "Timestamps show the recording's actual time — click to adjust or remove"
                  : "Show the recording's actual time (from its on-screen clock) instead of time from the start of the file")
        }
    }

    /// Hidden entirely when the diarization engine isn't bundled (e.g. a Debug build
    /// with no artifacts yet) so the feature never dead-ends.
    @ViewBuilder private var identifySpeakersButton: some View {
        if EngineLocator.isDiarizationAvailable {
            Button {
                if model.mediaMissing { model.locateMedia() }
                else { showSpeakerSheet = true }
            } label: {
                Label(model.isDiarized ? "Speakers" : "Identify Speakers",
                      systemImage: "person.2.wave.2")
            }
            .disabled(model.isDiarizing || model.transcript == nil)
            .help(model.isDiarized
                  ? "Re-identify speakers (e.g. with a different count)"
                  : "Label who is speaking, then name each person")
        }
    }

    private var saveIndicator: some View {
        HStack(spacing: 4) {
            if model.isSaving {
                ProgressView().controlSize(.small)
                Text("Saving…")
            } else if model.lastSaved != nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Saved")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help("Auto-saved to your Documents ▸ Tscribe folder. Click to show it in Finder.")
        .onTapGesture { model.revealInFinder() }
    }

    private var exportMenu: some View {
        Menu {
            Button("Word document (.docx)") { model.export(.docx) }
            Button("PDF document (.pdf)") { model.export(.pdf) }
            Button("Plain text (.txt)") { model.export(.txt) }
            Button("Text with timestamps (.txt)") { model.export(.txtTimestamped) }
            Button("Rich Text (.rtf)") { model.export(.rtf) }
            Divider()
            Button("Subtitles (.srt)") { model.export(.srt) }
            Button("Web subtitles (.vtt)") { model.export(.vtt) }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var transcriptPane: some View {
        VStack(spacing: 0) {
            if model.isDiarized {
                SpeakerRosterBar(model: model)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            } else {
                ConfidenceLegend()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            searchFilterBar
            if !model.selectedSegmentIDs.isEmpty {
                selectionBar
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    // Eager, not lazy — deliberately. Every main-thread livelock
                    // this app ever produced lived inside LazyVStack's
                    // placement/estimation/phase machinery. Rows are cheap to
                    // keep resident (value views, equatable-skipped, playhead
                    // isolated), so we pay one full layout at document-open and
                    // the entire lazy apparatus ceases to exist.
                    VStack(alignment: .leading, spacing: 10) {
                        if model.turnGroups.isEmpty && model.isFiltering {
                            Text("No matches\(model.searchText.isEmpty ? "" : " for “\(model.searchText)”").")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.top, 24)
                                .frame(maxWidth: .infinity)
                        }
                        // Rows are plain value views compared by Equatable — a
                        // playhead tick or ⌘-click re-renders only the turns
                        // whose inputs changed, not the whole lazy list.
                        let shared = listState
                        ForEach(model.turnGroups) { group in
                            TurnBlock(
                                group: group,
                                displayName: group.speaker.flatMap { model.transcript?.displayName(forSpeaker: $0) },
                                clockOffset: shared.clockOffset,
                                isEditing: shared.isEditing,
                                activeMatchID: shared.activeMatchID.map { id in
                                    group.segments.contains { $0.id == id } ? id : nil
                                } ?? nil,
                                selectedIDs: shared.selected.isEmpty
                                    ? [] : shared.selected.intersection(group.segments.map(\.id)),
                                contextMatchIDs: shared.contextHighlight
                                    ? Set(group.segments.filter { model.matchesSearch($0) }.map(\.id)) : [],
                                searchToken: shared.searchToken,
                                model: model,
                                clock: model.clock)
                                .equatable()
                                .id(group.id)
                        }
                        Text(Disclaimer.long)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 14)
                            .padding(.horizontal, 10)
                    }
                    .padding(16)
                }
                .onReceive(model.clock.$time) { _ in
                    // Follow the playhead ONLY during passive playback: never
                    // while paused, never right after the user clicked a word
                    // (they're looking at what they clicked — don't scroll it
                    // away), never while stepping matches, never to filtered-out
                    // rows. Coalesced so at most one follow is in flight.
                    // (onReceive is an action — reading the clock here does NOT
                    // subscribe this view's body to the 10 Hz tick.)
                    let id = model.currentSegmentID
                    guard id != lastFollowedSegment else { return }
                    lastFollowedSegment = id
                    pendingFollowScroll?.cancel()
                    guard model.isPlaying,
                          Date().timeIntervalSince(model.lastUserSeekAt) > 1.0,
                          model.activeMatchID == nil,
                          let id, model.visibleSegments.contains(where: { $0.id == id }) else { return }
                    let work = DispatchWorkItem {
                        scrollToSegment(id, proxy: proxy)
                    }
                    pendingFollowScroll = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
                }
                .onChange(of: model.activeMatchID) { _, id in
                    guard let id else { return }
                    scrollToSegment(id, proxy: proxy)
                }
            }
        }
        .overlay { if model.isDiarizing { DiarizingOverlay(progress: model.diarizeProgress) } }
        // Invisible shortcut targets: ⌘F focuses search, ⌘G / ⇧⌘G step matches,
        // Esc clears the line selection when one exists.
        .background(
            Group {
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                Button("") { model.stepMatch(1) }
                    .keyboardShortcut("g", modifiers: .command)
                Button("") { model.stepMatch(-1) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                if !model.selectedSegmentIDs.isEmpty {
                    Button("") { model.clearSelection() }
                        .keyboardShortcut(.escape, modifiers: [])
                }
            }
            .opacity(0)
            .accessibilityHidden(true)
        )
    }

    /// Shown while lines are selected: count, bulk-assign menu, clear.
    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(model.selectedSegmentIDs.count) line\(model.selectedSegmentIDs.count == 1 ? "" : "s") selected")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            SpeakerAssignMenu(model: model,
                              title: "Assign to Speaker",
                              segmentIDs: Array(model.selectedSegmentIDs),
                              current: nil)
                .menuStyle(.borderlessButton)
                .fixedSize()
            Button("Clear") { model.clearSelection() }
                .controlSize(.small)
            Spacer()
            Text("⌘-click to add · ⇧-click for a range")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// Search text + speaker filter, combined with AND. Esc clears; Return / ⌘G
    /// step through matches (wrapping); "In context" keeps all rows visible.
    private var searchFilterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search transcript (⌘F)", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { model.stepMatch(1) }
                    .onExitCommand {
                        model.searchText = ""
                        searchFocused = false
                    }
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .frame(minWidth: 170, maxWidth: 320)   // never collapses out of view

            if !model.searchText.isEmpty {
                Picker("", selection: $model.searchMode) {
                    ForEach(TranscriberModel.SearchMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Filter: show only matching lines. In context: show everything and step between matches.")

                HStack(spacing: 2) {
                    Button { model.stepMatch(-1) } label: { Image(systemName: "chevron.up") }
                        .help("Previous match (⇧⌘G)")
                    Button { model.stepMatch(1) } label: { Image(systemName: "chevron.down") }
                        .help("Next match (⌘G or Return)")
                    Button { model.selectAllMatches() } label: { Image(systemName: "checklist.checked") }
                        .help("Select all matching lines — then assign them to a speaker in one step")
                }
                .buttonStyle(.borderless)
                .disabled(model.matchingSegmentIDs.isEmpty)
            }

            if model.isDiarized {
                Picker("Speaker", selection: $model.speakerFilter) {
                    Text("All speakers").tag(String?.none)
                    ForEach(model.transcript?.speakers ?? []) { sp in
                        Text(sp.displayName).tag(String?.some(sp.key))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }

            matchCounter
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var matchCounter: some View {
        if model.isSearchActive {
            let n = model.matchingSegmentIDs.count
            Text(model.activeMatchOrdinal.map { "\($0) of \(n)" }
                 ?? "\(n) match\(n == 1 ? "" : "es")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } else if model.speakerFilter != nil {
            Text("\(model.visibleSegments.count) of \(model.transcript?.segments.count ?? 0)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// Scroll to a segment — always INSTANT, never animated (overlapping scroll
    /// animations were a hang factory under rapid input), and always a single
    /// direct call: with an eager list every row's id resolves immediately.
    private func scrollToSegment(_ id: UUID, proxy: ScrollViewProxy) {
        proxy.scrollTo(id, anchor: .center)
    }

    /// Everything the row views need from the model, gathered once per update
    /// and handed down as plain values (rows do not observe the model).
    private struct ListState {
        var isEditing: Bool
        var activeMatchID: UUID?
        var selected: Set<UUID>
        var searchToken: String?      // single-word query, for word highlighting
        var contextHighlight: Bool    // context mode with an active query
        var clockOffset: TimeInterval?
    }

    private var listState: ListState {
        let q = model.appliedSearchText.trimmingCharacters(in: .whitespaces)
        return ListState(
            isEditing: model.isEditing,
            activeMatchID: model.activeMatchID,
            selected: model.selectedSegmentIDs,
            searchToken: (!q.isEmpty && !q.contains(" ")) ? q : nil,
            contextHighlight: model.searchMode == .context && model.isSearchActive,
            clockOffset: model.transcript?.clockOffset
        )
    }
}

/// One dialogue turn. A plain value view that does NOT observe the model: all
/// display state arrives as Equatable inputs, so SwiftUI skips unchanged turns
/// entirely. This is what keeps rapid interactions (10 Hz playhead ticks,
/// ⌘-clicks, search stepping) from re-laying-out the whole lazy list — the
/// cause of the main-thread hangs in LazyLayout placement.
private struct TurnBlock: View, Equatable {
    let group: TurnGroup
    let displayName: String?
    let clockOffset: TimeInterval?
    let isEditing: Bool
    let activeMatchID: UUID?
    let selectedIDs: Set<UUID>
    let contextMatchIDs: Set<UUID>
    let searchToken: String?
    let model: TranscriberModel      // actions only — deliberately not @ObservedObject
    let clock: PlaybackClock         // rows subscribe individually — not observed here

    static func == (a: TurnBlock, b: TurnBlock) -> Bool {
        a.group == b.group
            && a.displayName == b.displayName
            && a.clockOffset == b.clockOffset
            && a.isEditing == b.isEditing
            && a.activeMatchID == b.activeMatchID
            && a.selectedIDs == b.selectedIDs
            && a.contextMatchIDs == b.contextMatchIDs
            && a.searchToken == b.searchToken
    }

    static func timecode(_ t: TimeInterval, offset: TimeInterval?) -> String {
        offset.map { Timecode.wall(t + $0) } ?? Timecode.hms(t)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let key = group.speaker {
                SpeakerHeader(key: key,
                              displayName: displayName ?? "Speaker \(key)",
                              start: group.start,
                              timecode: Self.timecode(group.start, offset: clockOffset),
                              turnSegmentIDs: group.segments.map(\.id),
                              model: model)
            }
            ForEach(group.segments) { seg in
                SegmentRow(segment: seg,
                           showTimestamp: group.speaker == nil,
                           clockOffset: clockOffset,
                           isEditing: isEditing,
                           isSelected: selectedIDs.contains(seg.id),
                           isActiveMatch: seg.id == activeMatchID,
                           isContextMatch: contextMatchIDs.contains(seg.id),
                           searchToken: searchToken,
                           model: model,
                           clock: clock)
                    .equatable()
                    .id(seg.id)
            }
        }
    }
}

/// Menu items to reassign segments to another speaker. Used on a single
/// segment row, a turn header (whole turn), and the multi-select action bar.
/// All actions register with the window's undo manager (⌘Z / ⇧⌘Z).
private struct SpeakerAssignMenu: View {
    @ObservedObject var model: TranscriberModel
    @Environment(\.undoManager) private var undoManager
    var title = "Assign to Speaker"
    let segmentIDs: [UUID]
    let current: String?

    var body: some View {
        Menu(title) {
            ForEach(model.transcript?.speakers ?? []) { sp in
                Button {
                    model.assignSpeaker(sp.key, toSegments: segmentIDs, undoManager: undoManager)
                } label: {
                    if sp.key == current {
                        Label(sp.displayName, systemImage: "checkmark")
                    } else {
                        Text(sp.displayName)
                    }
                }
            }
            Button("New Speaker") {
                model.assignToNewSpeaker(segments: segmentIDs, undoManager: undoManager)
            }
            if current != nil {
                Divider()
                Button("No Speaker") { model.assignSpeaker(nil, toSegments: segmentIDs, undoManager: undoManager) }
            }
        }
    }
}

/// The clickable, renamable speaker label above a dialogue turn.
/// Right-click reassigns the whole turn to a different speaker.
/// Value view (not observing) — display state comes in as plain inputs.
private struct SpeakerHeader: View, Equatable {
    let key: String
    let displayName: String
    let start: TimeInterval
    let timecode: String
    let turnSegmentIDs: [UUID]
    let model: TranscriberModel      // actions only — not observed
    @State private var renaming = false

    static func == (a: SpeakerHeader, b: SpeakerHeader) -> Bool {
        a.key == b.key && a.displayName == b.displayName
            && a.start == b.start && a.timecode == b.timecode
            && a.turnSegmentIDs == b.turnSegmentIDs
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(SpeakerPalette.color(for: key)).frame(width: 10, height: 10)
            Button { renaming = true } label: {
                Text(displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SpeakerPalette.color(for: key))
            }
            .buttonStyle(.plain)
            .help("Click to name this speaker — right-click to reassign this turn")
            .popover(isPresented: $renaming, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Name this speaker").font(.caption).foregroundStyle(.secondary)
                    TextField("e.g. Ann Miller", text: model.speakerNameBinding(key))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onSubmit { renaming = false }
                }
                .padding(12)
            }
            Button { model.seek(to: start) } label: {
                Text(timecode).font(.caption.monospacedDigit())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 6)
        .contextMenu {
            SpeakerAssignMenu(model: model, title: "Assign Turn to Speaker",
                              segmentIDs: turnSegmentIDs, current: key)
        }
    }
}

/// The "define each person" strip at the top of the transcript once diarized.
private struct SpeakerRosterBar: View {
    @ObservedObject var model: TranscriberModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                Text("Speakers:").font(.caption).foregroundStyle(.secondary)
                ForEach(model.transcript?.speakers ?? []) { sp in
                    HStack(spacing: 6) {
                        Circle().fill(SpeakerPalette.color(for: sp.key)).frame(width: 9, height: 9)
                        TextField("Speaker \(sp.key)", text: model.speakerNameBinding(sp.key))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)
                            .font(.caption)
                    }
                }
            }
        }
    }
}

/// Dimming HUD while diarization runs (keeps the transcript visible behind it).
private struct DiarizingOverlay: View {
    let progress: Double?

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).opacity(0.6)
            VStack(spacing: 10) {
                if let p = progress {
                    ProgressView(value: p).frame(width: 180)
                } else {
                    ProgressView().controlSize(.large)
                }
                Text("Identifying speakers…").font(.callout).foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .ignoresSafeArea()
    }
}

/// One transcript line. Value view (not observing the model): everything that
/// affects rendering is an Equatable input, so unchanged rows are skipped.
private struct SegmentRow: View, Equatable {
    let segment: Segment
    let showTimestamp: Bool
    let clockOffset: TimeInterval?
    let isEditing: Bool
    let isSelected: Bool
    let isActiveMatch: Bool
    let isContextMatch: Bool
    let searchToken: String?
    let model: TranscriberModel      // actions only — not observed
    let clock: PlaybackClock         // subscribed below; NOT @ObservedObject

    // Playhead state, local to this row. Updated from the clock via onReceive
    // with compare-before-set: for the ~299 rows not under the playhead the
    // write is a no-op and SwiftUI invalidates nothing — a tick re-renders
    // only the single active row.
    @State private var isActive = false
    @State private var activeWordID: UUID?

    static func == (a: SegmentRow, b: SegmentRow) -> Bool {
        a.segment == b.segment
            && a.showTimestamp == b.showTimestamp
            && a.clockOffset == b.clockOffset
            && a.isEditing == b.isEditing
            && a.isSelected == b.isSelected
            && a.isActiveMatch == b.isActiveMatch
            && a.isContextMatch == b.isContextMatch
            && a.searchToken == b.searchToken
    }

    /// Highlight words containing a single-word search query (phrase queries
    /// span chips, so those highlight at the segment level via filtering only).
    private func isSearchMatch(_ word: Word) -> Bool {
        guard let token = searchToken else { return false }
        return word.text.localizedCaseInsensitiveContains(token)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showTimestamp {
                Button { model.seek(to: segment.start) } label: {
                    Text(TurnBlock.timecode(segment.start, offset: clockOffset))
                        .font(.caption.monospacedDigit())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if isEditing {
                TextEditor(text: model.binding(for: segment.id))
                    .font(.body)
                    .frame(minHeight: 46)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(6)
            } else {
                FlowLayout(spacing: 4, lineSpacing: 6) {
                    ForEach(segment.words) { word in
                        WordChip(word: word,
                                 isCurrent: word.id == activeWordID,
                                 isMatch: isSearchMatch(word))
                            .onTapGesture { model.seek(to: word.start) }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, showTimestamp ? 10 : 4)
        .background(rowBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(0.75), lineWidth: isSelected ? 1.5 : 0)
        )
        // ⌘-click toggles a line in/out of the selection; ⇧-click extends a range.
        // High-priority so they beat word-chip seek taps; plain clicks unaffected.
        .highPriorityGesture(TapGesture().modifiers(.shift)
            .onEnded { model.extendSelection(to: segment.id) })
        .highPriorityGesture(TapGesture().modifiers(.command)
            .onEnded { model.toggleSelection(segment.id) })
        .contextMenu {
            // Right-clicking a selected line acts on the whole selection.
            // (Menu content is only built when the menu opens, so reading the
            // live model here costs nothing during normal rendering.)
            if isSelected && model.selectedSegmentIDs.count > 1 {
                SpeakerAssignMenu(model: model,
                                  title: "Assign \(model.selectedSegmentIDs.count) Lines to Speaker",
                                  segmentIDs: Array(model.selectedSegmentIDs),
                                  current: nil)
            } else {
                SpeakerAssignMenu(model: model, segmentIDs: [segment.id], current: segment.speaker)
            }
        }
        .onReceive(clock.$time) { t in
            let nowActive = t >= segment.start && t < segment.end
            if nowActive != isActive { isActive = nowActive }
            let nowWord = nowActive
                ? segment.words.first(where: { t >= $0.start && t < $0.end })?.id
                : nil
            if nowWord != activeWordID { activeWordID = nowWord }
        }
    }

    /// Selection wins; then playhead; then the stepped-to search match; then a
    /// faint wash on matching rows in context mode.
    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.16) }
        if isActive { return Color.accentColor.opacity(0.10) }
        if isActiveMatch { return Color.yellow.opacity(0.22) }
        if isContextMatch { return Color.yellow.opacity(0.07) }
        return .clear
    }
}

private struct WordChip: View {
    let word: Word
    let isCurrent: Bool
    var isMatch: Bool = false

    // No per-chip tooltips: `.help` installs an AppKit tracking area per chip,
    // and thousands of tracking areas churning while rows rebuild mid-hover is
    // a classic main-thread wedge. The confidence legend explains the colors.
    var body: some View {
        Text(word.text)
            .foregroundColor(color)
            .underline(word.confidence < 0.5, color: .red)
            .padding(.horizontal, 2)
            .background(chipBackground, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
    }

    private var chipBackground: Color {
        if isCurrent { return Color.accentColor.opacity(0.35) }   // playhead beats search
        if isMatch { return Color.yellow.opacity(0.30) }
        return Color.clear
    }

    private var color: Color {
        switch word.confidence {
        case ..<0.5: return .red
        case ..<0.7: return .orange
        default:     return .primary
        }
    }
}

private struct ConfidenceLegend: View {
    var body: some View {
        HStack(spacing: 16) {
            Text("Word confidence:").foregroundStyle(.secondary)
            swatch(color: .primary, label: "confident")
            swatch(color: .orange, label: "uncertain")
            swatch(color: .red, label: "low — verify", underline: true)
            Spacer()
        }
        .font(.caption)
    }

    private func swatch(color: Color, label: String, underline: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text("Aa").foregroundColor(color).underline(underline, color: .red)
            Text(label).foregroundStyle(.secondary)
        }
    }
}

/// Distinct, theme-aware colors per speaker key (A→0, B→1, …).
enum SpeakerPalette {
    static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .red, .indigo]

    static func color(for key: String) -> Color {
        let idx: Int
        if key.count == 1, let a = key.unicodeScalars.first?.value, (65...90).contains(a) {
            idx = Int(a - 65)
        } else {
            idx = abs(key.hashValue)
        }
        return colors[idx % colors.count]
    }
}
