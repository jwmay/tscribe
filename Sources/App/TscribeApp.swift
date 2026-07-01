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

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let model {
            model.open(url)
        } else {
            pendingURL = url   // opened before the window/model was ready
        }
    }
}
