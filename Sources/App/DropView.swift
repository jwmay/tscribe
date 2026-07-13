import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DropView: View {
    @ObservedObject var model: TranscriberModel
    @State private var targeted = false

    // Library-wide search across all saved transcripts.
    @State private var libraryQuery = ""
    @State private var libraryHits: [TranscriptStore.LibraryHit] = []
    @State private var librarySearchTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "waveform")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(.secondary)

                Text("Tscribe")
                    .font(.largeTitle.weight(.semibold))

                Text("Drag a video or audio file here. It's transcribed privately on this Mac — nothing is ever uploaded.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 470)

                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.5))
                    .frame(height: 170)
                    .overlay(
                        VStack(spacing: 10) {
                            Image(systemName: "arrow.down.doc").font(.system(size: 28))
                                .foregroundStyle(.secondary)
                            Text("Drop a file here").foregroundStyle(.secondary)
                            Text("or").font(.caption).foregroundStyle(.tertiary)
                            Button("Choose File…") { choose() }
                                .controlSize(.large)
                        }
                    )
                    .frame(maxWidth: 550)
                    .padding(.horizontal, 40)
                    .onDrop(of: [.fileURL], isTargeted: $targeted, perform: handleDrop)

                if case .failed(let msg) = model.stage {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 470)
                        .padding(.top, 2)
                }

                // Settings the user can actually see. The update toggle belongs HERE, with its
                // peers — in 2.1.0 it was styled as a tertiary footnote and stranded below the
                // fine print, where nobody found it.
                VStack(spacing: 8) {
                    HStack(spacing: 18) {
                        Toggle("Auto-detect language", isOn: $model.autoDetectLanguage)
                        Toggle("Reduce false text in silence", isOn: $model.reduceSilenceHallucinations)
                            .help("Uses voice-activity detection to skip silent stretches, reducing invented words. Recommended for recordings with long pauses.")
                    }
                    updateControls
                }
                .toggleStyle(.checkbox)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

                Text(Disclaimer.short)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 470)

                // Standard edition only: the model was fetched once at setup. Kept honest
                // and scoped — the privacy promise is about the user's recordings.
                if !EngineLocator.isModelBundled {
                    Text("Speech model downloaded once at setup. Your recordings and transcripts never leave this Mac.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 470)
                }

                if !model.recents.isEmpty {
                    librarySection
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            model.refreshRecents()
            #if DEBUG
            if let q = ProcessInfo.processInfo.environment["TSCRIBE_STAGE_LIBQUERY"], !q.isEmpty {
                libraryQuery = q
            }
            #endif
        }
    }

    /// The user's standing choice about update checks.
    ///
    /// Standard: a toggle, so the first-run answer is never a life sentence either way.
    /// Complete: it cannot check, so there is nothing to toggle — instead, once the build
    /// is genuinely old, say so. That's a local date comparison against a date stamped into
    /// Info.plist at package time; it opens no connection and sends nothing.
    @ViewBuilder
    private var updateControls: some View {
        #if SPARKLE_UPDATES
        AutoUpdateToggle(updater: model.updater)
        #else
        if OfflineUpdateInfo.isStale {
            Button {
                model.showOfflineUpdateInfo = true
            } label: {
                Label("This copy is from \(OfflineUpdateInfo.buildDateText). A newer version may exist.",
                      systemImage: "clock.arrow.circlepath")
                    .font(.footnote)
            }
            .buttonStyle(.link)
            .foregroundStyle(.tertiary)
        }
        #endif
    }

    /// Recents list, with a search field that scans *all* saved transcripts.
    /// Typing swaps the list for per-file results; opening a result carries the
    /// query into the transcript's search field.
    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.vertical, 6)

            HStack {
                Text(searching ? "Search results" : "Recent transcripts").font(.headline)
                Spacer()
                Button("Open…") { openSaved() }
                    .controlSize(.small)
            }

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search all transcripts", text: $libraryQuery)
                    .textFieldStyle(.plain)
                    .onExitCommand { libraryQuery = "" }
                if !libraryQuery.isEmpty {
                    Button { libraryQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .onChange(of: libraryQuery) { _, q in searchLibrary(q) }

            if searching {
                if libraryHits.isEmpty {
                    Text("No transcripts mention “\(libraryQuery)”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(libraryHits) { hit in
                        Button {
                            let query = libraryQuery
                            model.openDocument(hit.url)
                            model.searchText = query   // land in the transcript pre-filtered
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "text.magnifyingglass")
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(hit.name).lineLimit(1)
                                        Text("\(hit.matchCount) match\(hit.matchCount == 1 ? "" : "es")")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    ForEach(hit.snippets, id: \.self) { s in
                                        Text(s)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            } else {
                ForEach(model.recents.prefix(8)) { item in
                    Button { model.openDocument(item.url) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text.fill")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).lineLimit(1)
                                Text(item.date, format: .dateTime.month().day().year().hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .frame(maxWidth: 470)
        .padding(.top, 4)
    }

    private var searching: Bool {
        !libraryQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Debounced, off-main scan of every saved transcript.
    private func searchLibrary(_ query: String) {
        librarySearchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { libraryHits = []; return }
        librarySearchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)   // debounce typing
            guard !Task.isCancelled else { return }
            let hits = await Task.detached(priority: .userInitiated) {
                TranscriptStore.searchLibrary(query: q)
            }.value
            if !Task.isCancelled { libraryHits = hits }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audiovisualContent, .audio, .movie]
        if panel.runModal() == .OK, let url = panel.url {
            model.open(url)
        }
    }

    private func openSaved() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if let type = UTType(filenameExtension: TranscriptStore.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        if panel.runModal() == .OK, let url = panel.url {
            model.openDocument(url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let u = item as? URL { url = u }
            else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            if let url {
                DispatchQueue.main.async { model.open(url) }
            }
        }
        return true
    }
}
