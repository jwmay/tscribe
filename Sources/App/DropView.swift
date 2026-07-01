import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DropView: View {
    @ObservedObject var model: TranscriberModel
    @State private var targeted = false

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

                HStack(spacing: 18) {
                    Toggle("Auto-detect language", isOn: $model.autoDetectLanguage)
                    Toggle("Reduce false text in silence", isOn: $model.reduceSilenceHallucinations)
                        .help("Uses voice-activity detection to skip silent stretches, reducing invented words. Recommended for recordings with long pauses.")
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

                if !model.recents.isEmpty {
                    recentsSection
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.refreshRecents() }
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.vertical, 6)

            HStack {
                Text("Recent transcripts").font(.headline)
                Spacer()
                Button("Open…") { openSaved() }
                    .controlSize(.small)
            }

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
        .frame(maxWidth: 470)
        .padding(.top, 4)
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
