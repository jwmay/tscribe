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
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
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
                .frame(minWidth: 320, idealWidth: 460)
                .layoutPriority(1)

                transcriptPane
                    .frame(minWidth: 400)
            }
        }
        .frame(minWidth: 820, minHeight: 520)
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
            Toggle(isOn: $model.isEditing) { Label("Edit", systemImage: "pencil") }
                .toggleStyle(.button)
            exportMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
            ConfidenceLegend()
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.transcript?.segments ?? []) { seg in
                            SegmentRow(segment: seg, model: model)
                                .id(seg.id)
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
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }
}

private struct SegmentRow: View {
    let segment: Segment
    @ObservedObject var model: TranscriberModel

    private var isActive: Bool { model.currentSegmentID == segment.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { model.seek(to: segment.start) } label: {
                Text(Timecode.hms(segment.start))
                    .font(.caption.monospacedDigit())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

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
                                 isCurrent: model.currentTime >= word.start && model.currentTime < word.end)
                            .onTapGesture { model.seek(to: word.start) }
                    }
                }
            }
        }
        .padding(10)
        .background(isActive ? Color.accentColor.opacity(0.10) : Color.clear)
        .cornerRadius(8)
    }
}

private struct WordChip: View {
    let word: Word
    let isCurrent: Bool

    var body: some View {
        Text(word.text)
            .foregroundColor(color)
            .underline(word.confidence < 0.5, color: .red)
            .padding(.horizontal, 2)
            .background(isCurrent ? Color.accentColor.opacity(0.35) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .help(word.confidence < 0.7 ? "Low confidence (\(Int(word.confidence * 100))%) — verify against the audio" : "")
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
