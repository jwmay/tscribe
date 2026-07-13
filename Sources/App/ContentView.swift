import SwiftUI

struct ContentView: View {
    @ObservedObject var model: TranscriberModel

    var body: some View {
        Group {
            switch model.stage {
            case .idle, .failed:
                DropView(model: model)
            case .onboarding:
                #if DOWNLOAD_MODEL
                OnboardingView(model: model, installer: model.installer)
                #else
                DropView(model: model)   // unreachable in Complete builds; keeps the switch exhaustive
                #endif
            case .extracting, .transcribing:
                WorkingView(model: model)
            case .ready:
                TranscriptView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(UpdateSheets(model: model))
    }
}

/// The edition-specific update sheet, factored out so `ContentView.body` stays a plain
/// router. Standard gets the first-run consent question; Complete gets the explainer for
/// why it can't check at all.
private struct UpdateSheets: ViewModifier {
    @ObservedObject var model: TranscriberModel

    func body(content: Content) -> some View {
        #if SPARKLE_UPDATES
        content.sheet(isPresented: consentBinding) {
            UpdateConsentSheet(updater: model.updater)
                .interactiveDismissDisabled()   // it's a yes/no question; make them answer
        }
        #else
        content.sheet(isPresented: $model.showOfflineUpdateInfo) {
            OfflineUpdateSheet()
        }
        #endif
    }

    #if SPARKLE_UPDATES
    /// Ask once, on the first launch that reaches a normal screen. Deliberately NOT during
    /// onboarding — a first-time user is already mid-download of a 2.9 GB model and doesn't
    /// need a second question stacked on top of it. Someone upgrading from a pre-Sparkle
    /// version skips onboarding entirely and gets asked immediately, which is the point:
    /// consent can't live inside a flow that only new users see.
    ///
    /// Read-only: the sheet closes because `answerConsent` flips `consentAnswered`, not
    /// because something dismissed it.
    private var consentBinding: Binding<Bool> {
        Binding(
            get: { !model.updater.consentAnswered && model.stage != .onboarding },
            set: { _ in }
        )
    }
    #endif
}

#Preview {
    ContentView(model: TranscriberModel())
}
