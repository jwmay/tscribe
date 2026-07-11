import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct TscribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = TranscriberModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 520)
                .onAppear {
                    appDelegate.model = model
                    if let url = appDelegate.pendingURL {
                        appDelegate.pendingURL = nil
                        model.open(url)
                    }
                }
                .onOpenURL { model.open($0) }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { openFilePanel() }
                    .keyboardShortcut("o", modifiers: .command)

                Menu("Open Recent") {
                    if model.recents.isEmpty {
                        Button("No Recent Transcripts") {}.disabled(true)
                    } else {
                        ForEach(model.recents) { item in
                            Button(item.name) { model.openDocument(item.url) }
                        }
                    }
                }
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.saveNow() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.transcript == nil)

                Menu("Export") {
                    Button("Word Document (.docx)") { model.export(.docx) }
                    Button("PDF Document (.pdf)") { model.export(.pdf) }
                    Button("Plain Text (.txt)") { model.export(.txt) }
                    Button("Text with Timestamps (.txt)") { model.export(.txtTimestamped) }
                    Button("Rich Text (.rtf)") { model.export(.rtf) }
                    Divider()
                    Button("Subtitles (.srt)") { model.export(.srt) }
                    Button("Web Subtitles (.vtt)") { model.export(.vtt) }
                }
                .disabled(model.transcript == nil)

                Button("Reveal Saved Transcript in Finder") { model.revealInFinder() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.transcript == nil)

                Button("Close Transcript") { model.reset() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(model.transcript == nil)
            }
        }
    }

    private func openFilePanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.audiovisualContent, .audio, .movie]
        if let tscribe = UTType(filenameExtension: TranscriptStore.fileExtension) {
            types.append(tscribe)
        }
        panel.allowedContentTypes = types
        if panel.runModal() == .OK, let url = panel.url {
            model.open(url)
        }
    }
}

/// Handles files opened via `open`, double-click, or drag-onto-dock-icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: TranscriberModel?
    var pendingURL: URL?
    private var spaceKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The standard About panel reads applicationIconImage; the asset-catalog
        // app icon isn't loadable as a file, so set it explicitly here.
        if let icon = NSImage(named: "AppIconImage") {
            NSApplication.shared.applicationIconImage = icon
        }
        installSpaceKeyMonitor()
        #if DEBUG
        startStressModeIfRequested()
        #endif
    }

    /// Spacebar toggles play/pause — but never while typing or in a sheet.
    /// A key monitor (rather than a SwiftUI shortcut) so we can check who has
    /// focus: space must still type spaces in the search field, edit mode, and
    /// rename fields, and still activate focused controls in sheets.
    private func installSpaceKeyMonitor() {
        spaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 49,                                   // space
                  !event.isARepeat,                                      // no auto-repeat toggling
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  let window = NSApp.keyWindow,
                  !window.isSheet, window.attachedSheet == nil,          // sheets keep space for their controls
                  !(window.firstResponder is NSText),                    // any text editing (field editors, TextEditor)
                  let model = self?.model,
                  model.stage == .ready, model.player != nil
            else { return event }
            model.togglePlayback()
            return nil   // swallow: don't also scroll the transcript / beep
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let model {
            model.open(url)
        } else {
            pendingURL = url   // opened before the window/model was ready
        }
    }

    #if DEBUG
    // MARK: Stress mode (debug builds only)
    //
    // `Tscribe --stress` with TSCRIBE_STRESS_DOC=<path.tscribe> drives a storm
    // of the interactions that have produced user-reported hangs — rapid seeks
    // (word clicks), play/pause spam, filter typing, match stepping, selection
    // toggles — at 8–25 events/sec, while a watchdog thread logs any main-thread
    // stall. Used with external `sample` capture to diagnose hangs with real
    // symbolized stacks instead of guesswork.

    func startStressModeIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--stress") else { return }
        Self.startMainThreadWatchdog()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let model = self?.model else { NSLog("STRESS: no model"); return }
            if let path = ProcessInfo.processInfo.environment["TSCRIBE_STRESS_DOC"] {
                model.openDocument(URL(fileURLWithPath: path))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                MainActor.assumeIsolated {
                    NSLog("STRESS: storm starting")
                    model.player?.play()
                    Self.runStorm(on: model, remaining: 900)   // ~60-90s of chaos
                }
            }
        }
    }

    @MainActor private static func runStorm(on model: TranscriberModel, remaining: Int) {
        guard remaining > 0 else { NSLog("STRESS: storm done"); return }
        let queries = ["c", "co", "comp", "compli", "compliance", "care", "care plan", "we", ""]
        let duration = model.player?.currentItem?.duration.seconds ?? 60
        switch Int.random(in: 0..<20) {
        case 0...6:     // rapid word-click seeks
            model.seek(to: Double.random(in: 0..<max(1, duration - 1)))
        case 7...9:     // spacebar spam
            model.togglePlayback()
        case 10...12:   // typing in the filter
            model.searchText = queries.randomElement()!
        case 13:        // ⌘G
            model.stepMatch(1)
        case 14:        // ⌘-click selection
            if let seg = model.visibleSegments.randomElement() { model.toggleSelection(seg.id) }
        case 15:        // flip search mode
            model.searchMode = model.searchMode == .filter ? .context : .filter
        case 16:        // edit-mode toggle
            model.isEditing.toggle()
        case 17:        // speaker filter flips
            model.speakerFilter = [nil, "A", "B", "C", "D"].randomElement()!
        case 18:        // bulk reassignment (regroups turns) + undo pressure
            model.selectAllMatches()
            if !model.selectedSegmentIDs.isEmpty {
                model.assignSpeaker(["A", "B", "C", "D"].randomElement()!,
                                    toSegments: Array(model.selectedSegmentIDs), undoManager: nil)
            }
        default:        // window resize thrash (relayout everything)
            if let w = NSApp.windows.first(where: { $0.isVisible }) {
                var f = w.frame
                f.size.width = CGFloat.random(in: 1080...1800)
                f.size.height = CGFloat.random(in: 560...1100)
                w.setFrame(f, display: true)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 0.015...0.06)) {
            MainActor.assumeIsolated { runStorm(on: model, remaining: remaining - 1) }
        }
    }

    /// Logs whenever the main thread takes >0.5s to service an async ping.
    private static func startMainThreadWatchdog() {
        Thread.detachNewThread {
            while true {
                let t0 = Date()
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { sem.signal() }
                if sem.wait(timeout: .now() + 10) == .timedOut {
                    NSLog("STRESS: STALL >10000 ms (main thread wedged)")
                } else {
                    let ms = Date().timeIntervalSince(t0) * 1000
                    if ms > 500 { NSLog("STRESS: STALL %.0f ms", ms) }
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
    }
    #endif
}
