import SwiftUI
import AVKit

/// Wraps AppKit's AVPlayerView. Used instead of SwiftUI's `VideoPlayer`, which
/// crashes in `_AVKit_SwiftUI` generic-metadata instantiation on macOS 26.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        // Click anywhere on the picture to toggle play/pause (QuickTime-style).
        // The recognizer lives on `contentOverlayView`, which sits between the
        // video surface and the control bar — so the controls keep their clicks.
        if let overlay = view.contentOverlayView {
            overlay.addGestureRecognizer(NSClickGestureRecognizer(
                target: context.coordinator, action: #selector(Coordinator.togglePlayback)))
        }
        context.coordinator.playerView = view
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
        context.coordinator.playerView = nsView
    }

    final class Coordinator: NSObject {
        weak var playerView: AVPlayerView?

        @objc func togglePlayback() {
            guard let player = playerView?.player else { return }
            if player.timeControlStatus == .playing {
                player.pause()
            } else {
                player.play()
            }
        }
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
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if turnGroups.isEmpty && model.isFiltering {
                            Text("No matches\(model.searchText.isEmpty ? "" : " for “\(model.searchText)”").")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.top, 24)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(turnGroups) { group in
                            TurnBlock(group: group, model: model)
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
                .onChange(of: model.currentSegmentID) { _, id in
                    // Don't fight the user: only follow the playhead to segments
                    // that are actually visible under the current filter, and
                    // never while they're stepping through search matches.
                    guard model.activeMatchID == nil,
                          let id, model.visibleSegments.contains(where: { $0.id == id }) else { return }
                    scrollToSegment(id, proxy: proxy)
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

            if model.isSearchActive {
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

    /// Scroll to a segment wherever it lives. Segment rows are nested inside
    /// lazy turn blocks, and `scrollTo` can't reach ids that haven't rendered —
    /// so scroll to the enclosing turn block first (its id is a direct child of
    /// the lazy list and always resolves), then re-center on the exact segment
    /// once it exists.
    private func scrollToSegment(_ id: UUID, proxy: ScrollViewProxy) {
        let outer = turnGroups.first(where: { g in g.segments.contains(where: { $0.id == id }) })?.id ?? id
        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(outer, anchor: .center) }
        if outer != id {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    /// Group consecutive segments that share a speaker into one dialogue turn.
    /// Runs over the *filtered* segments, so search results keep their speaker
    /// headers. When not diarized (speaker == nil), every segment is its own
    /// group, which reproduces the original one-block-per-segment layout.
    private var turnGroups: [TurnGroup] {
        var groups: [TurnGroup] = []
        for seg in model.visibleSegments {
            if let last = groups.last, let spk = seg.speaker, last.speaker == spk {
                groups[groups.count - 1].segments.append(seg)
            } else {
                groups.append(TurnGroup(id: seg.id, speaker: seg.speaker, segments: [seg]))
            }
        }
        return groups
    }
}

/// A dialogue turn: one or more consecutive segments from the same speaker.
private struct TurnGroup: Identifiable {
    let id: UUID           // first segment's id (stable anchor for scroll)
    let speaker: String?
    var segments: [Segment]
    var start: TimeInterval { segments.first?.start ?? 0 }
}

private struct TurnBlock: View {
    let group: TurnGroup
    @ObservedObject var model: TranscriberModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let key = group.speaker {
                SpeakerHeader(key: key, start: group.start,
                              turnSegmentIDs: group.segments.map(\.id), model: model)
            }
            ForEach(group.segments) { seg in
                SegmentRow(segment: seg, model: model, showTimestamp: group.speaker == nil)
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
private struct SpeakerHeader: View {
    let key: String
    let start: TimeInterval
    let turnSegmentIDs: [UUID]
    @ObservedObject var model: TranscriberModel
    @State private var renaming = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(SpeakerPalette.color(for: key)).frame(width: 10, height: 10)
            Button { renaming = true } label: {
                Text(model.transcript?.displayName(forSpeaker: key) ?? "Speaker \(key)")
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
                Text(model.displayTimecode(start)).font(.caption.monospacedDigit())
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

private struct SegmentRow: View {
    let segment: Segment
    @ObservedObject var model: TranscriberModel
    var showTimestamp: Bool = true

    private var isActive: Bool { model.currentSegmentID == segment.id }

    /// Highlight words containing a single-word search query (phrase queries
    /// span chips, so those highlight at the segment level via filtering only).
    private func isSearchMatch(_ word: Word) -> Bool {
        let q = model.searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !q.contains(" ") else { return false }
        return word.text.localizedCaseInsensitiveContains(q)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showTimestamp {
                Button { model.seek(to: segment.start) } label: {
                    Text(model.displayTimecode(segment.start))
                        .font(.caption.monospacedDigit())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if model.isEditing {
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
                                 isCurrent: model.currentTime >= word.start && model.currentTime < word.end,
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
            if isSelected && model.selectedSegmentIDs.count > 1 {
                SpeakerAssignMenu(model: model,
                                  title: "Assign \(model.selectedSegmentIDs.count) Lines to Speaker",
                                  segmentIDs: Array(model.selectedSegmentIDs),
                                  current: nil)
            } else {
                SpeakerAssignMenu(model: model, segmentIDs: [segment.id], current: segment.speaker)
            }
        }
    }

    private var isSelected: Bool { model.selectedSegmentIDs.contains(segment.id) }

    /// Selection wins; then playhead; then the stepped-to search match; then a
    /// faint wash on matching rows in context mode.
    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.16) }
        if isActive { return Color.accentColor.opacity(0.10) }
        if model.activeMatchID == segment.id { return Color.yellow.opacity(0.22) }
        if model.searchMode == .context && model.matchesSearch(segment) { return Color.yellow.opacity(0.07) }
        return .clear
    }
}

private struct WordChip: View {
    let word: Word
    let isCurrent: Bool
    var isMatch: Bool = false

    var body: some View {
        Text(word.text)
            .foregroundColor(color)
            .underline(word.confidence < 0.5, color: .red)
            .padding(.horizontal, 2)
            .background(chipBackground, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .help(word.confidence < 0.7 ? "Low confidence (\(Int(word.confidence * 100))%) — verify against the audio" : "")
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
