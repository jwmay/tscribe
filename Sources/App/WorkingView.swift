import SwiftUI

struct WorkingView: View {
    @ObservedObject var model: TranscriberModel

    var body: some View {
        VStack(spacing: 20) {
            ProgressView().controlSize(.large)

            Text(title)
                .font(.title2.weight(.medium))

            if case .transcribing(let frac) = model.stage {
                ProgressView(value: frac)
                    .frame(width: 340)
                Text("\(Int(frac * 100))%")
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if let name = model.mediaURL?.lastPathComponent {
                Text(name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 380)
            }

            Text("Everything runs on this Mac. This can take a little while for long recordings.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch model.stage {
        case .extracting:   return "Preparing audio…"
        case .transcribing: return "Transcribing…"
        default:            return "Working…"
        }
    }
}
