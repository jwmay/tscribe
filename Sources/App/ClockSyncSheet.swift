import SwiftUI

/// "Actual Time" — anchors the transcript's timestamps to the recording's
/// burned-in on-screen clock. Shows the frame at the current playback position,
/// OCRs its clock as a suggestion, and lets the user confirm or correct it.
/// offset = (time on screen) − (media time of this frame).
struct ClockSyncSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: TranscriberModel

    @State private var frame: CGImage?
    @State private var timeText = ""
    @State private var ocrNote: String?
    @State private var loading = true
    /// Captured once when the sheet opens, so scrubbing behind the sheet can't skew the anchor.
    @State private var anchorMediaTime: TimeInterval = 0

    private var parsedSeconds: TimeInterval? { ClockOCR.parseTime(timeText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Show Actual Time")
                .font(.headline)

            Text("Transcript timestamps will show the recording's real time instead of "
                 + "time from the start of the file. Enter the time shown on the recording "
                 + "at this frame — pause the video on any frame where the clock is readable, "
                 + "then reopen this window to use that frame.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                if let frame {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 240)
                        .cornerRadius(6)
                } else if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }.frame(height: 160)
                } else {
                    Text("Couldn't load a frame from the recording.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 100)
                }
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                Text("Time on recording:")
                TextField("e.g. 10:47:30 or 2:15:05 PM", text: $timeText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                if !timeText.isEmpty && parsedSeconds == nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Enter a time like 10:47:30")
                }
            }
            if let ocrNote {
                Label(ocrNote, systemImage: "text.viewfinder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if model.hasClockOffset {
                    Button("Remove Actual Time", role: .destructive) {
                        model.clearClockOffset()
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use This Time") {
                    if let secs = parsedSeconds {
                        model.setClockOffset(wallSeconds: secs, atMediaTime: anchorMediaTime)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(parsedSeconds == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await loadFrame() }
    }

    private func loadFrame() async {
        anchorMediaTime = model.currentTime
        guard let media = model.mediaURL else { loading = false; return }
        do {
            let reading = try await ClockOCR.read(media: media, at: anchorMediaTime)
            frame = reading.frame
            if let secs = reading.detectedSeconds, let raw = reading.detectedText {
                timeText = Timecode.wall(secs)
                ocrNote = "Read “\(raw.trimmingCharacters(in: .whitespaces))” from the frame — confirm it matches the clock."
            } else {
                ocrNote = "No clock detected automatically — type the time shown on the frame."
            }
        } catch {
            ocrNote = "Couldn't read the frame (\(error.localizedDescription)). Type the time shown on the recording."
        }
        loading = false
    }
}
