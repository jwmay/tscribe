import SwiftUI

struct ContentView: View {
    @ObservedObject var model: TranscriberModel

    var body: some View {
        Group {
            #if SPARKLE_UPDATES
            // The first-run update question is a SCREEN, not a sheet. AppKit ignores
            // NSApp.terminate while a modal sheet is up — it doesn't even call
            // applicationShouldTerminate — so as a sheet this question made the app impossible
            // to quit, update, or use (see UpdateConsentSheet). A question the user never asked
            // for must never be able to trap them in the app.
            if model.showUpdateConsent {
                UpdateConsentSheet(updater: model.updater)
            } else {
                router
            }
            #else
            router
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(UpdateSheets(model: model))
    }

    @ViewBuilder
    private var router: some View {
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
}

/// The Complete edition's "why I can't check for updates" explainer.
///
/// This one stays a sheet, and that's fine: the user opens it themselves from the menu and closes
/// it with a button. The danger is only in a modal the user never asked for and cannot answer —
/// which is what the consent question was.
private struct UpdateSheets: ViewModifier {
    @ObservedObject var model: TranscriberModel

    func body(content: Content) -> some View {
        #if SPARKLE_UPDATES
        content
        #else
        content.sheet(isPresented: $model.showOfflineUpdateInfo) {
            OfflineUpdateSheet()
        }
        #endif
    }
}

#Preview {
    ContentView(model: TranscriberModel())
}
