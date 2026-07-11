import SwiftUI

/// Asked before each diarization run. Setting a known speaker count is the single
/// biggest accuracy lever; "detect automatically" leaves the count to the engine.
struct SpeakerCountSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Called with the chosen count, or nil for auto-detect.
    let onStart: (Int?) -> Void

    @State private var autoDetect = false
    @State private var count = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Identify Speakers")
                .font(.headline)

            Text("Tscribe will label who is speaking and let you name each person. "
                 + "This is an on-device estimate — it works best on clear audio, and you can "
                 + "correct or rename speakers afterward.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Text("Number of speakers")
                Spacer()
                Stepper(value: $count, in: 1...10) {
                    Text("\(count)").monospacedDigit().frame(minWidth: 20)
                }
                .disabled(autoDetect)
            }
            .opacity(autoDetect ? 0.4 : 1)

            Toggle("I'm not sure — detect automatically", isOn: $autoDetect)
                .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Identify") {
                    onStart(autoDetect ? nil : count)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
