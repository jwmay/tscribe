import SwiftUI

struct ContentView: View {
    @ObservedObject var model: TranscriberModel

    var body: some View {
        Group {
            switch model.stage {
            case .idle, .failed:
                DropView(model: model)
            case .onboarding:
                #if LITE
                OnboardingView(model: model, installer: model.installer)
                #else
                DropView(model: model)   // unreachable in Full; keeps the switch exhaustive
                #endif
            case .extracting, .transcribing:
                WorkingView(model: model)
            case .ready:
                TranscriptView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView(model: TranscriberModel())
}
