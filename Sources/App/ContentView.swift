import SwiftUI

struct ContentView: View {
    @ObservedObject var model: TranscriberModel

    var body: some View {
        Group {
            switch model.stage {
            case .idle, .failed:
                DropView(model: model)
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
