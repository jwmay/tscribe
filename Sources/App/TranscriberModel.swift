import Foundation
import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

enum ExportFormat { case docx, pdf, txt, txtTimestamped, srt, vtt, rtf }

/// Drives the whole flow: import → extract → transcribe → review/edit/export,
/// plus auto-save and reopening saved transcripts.
@MainActor
final class TranscriberModel: ObservableObject {
    enum Stage: Equatable {
        case idle
        case extracting
        case transcribing(Double)   // 0...1
        case ready
        case failed(String)
    }

    @Published var stage: Stage = .idle
    @Published var mediaURL: URL?
    @Published var transcript: Transcript?
    @Published var currentTime: TimeInterval = 0
    @Published var isEditing = false
    @Published private(set) var player: AVPlayer?

    // User-facing options (set on the import screen before a run).
    @Published var autoDetectLanguage = false
    @Published var reduceSilenceHallucinations = false

    // Library / persistence.
    @Published var recents: [TranscriptStore.RecentItem] = []
    @Published var mediaMissing = false
    @Published private(set) var isSaving = false
    @Published private(set) var lastSaved: Date?

    private let service = TranscriptionService()
    private var timeObserver: Any?
    private var currentDocURL: URL?
    private var saveWork: DispatchWorkItem?

    init() { refreshRecents() }

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
        currentTime = 0
        isEditing = false
        currentDocURL = nil
        mediaMissing = false
        lastSaved = nil
        isSaving = false
        if keepIdle {
            stage = .idle
            refreshRecents()
        }
    }

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
            MainActor.assumeIsolated { self?.currentTime = time.seconds }
        }
        player = p
    }

    func seek(to seconds: TimeInterval) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        player?.play()
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
