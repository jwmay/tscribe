#if LITE
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// First-launch screen for the Lite edition: a one-time download of the speech
/// model. Mirrors the app's other full-window screens (`MissingMediaView` for the
/// icon + text + button layout, `WorkingView` for the progress readout).
struct OnboardingView: View {
    @ObservedObject var model: TranscriberModel
    @ObservedObject var installer: ModelInstaller

    var body: some View {
        VStack(spacing: 18) {
            switch installer.phase {
            case .idle:
                intro
            case .downloading(let fraction, let received, let total, let rate):
                downloading(fraction: fraction, received: received, total: total, rate: rate)
            case .verifying:
                busy("Verifying…")
            case .installing:
                busy("Finishing setup…")
            case .done:
                busy("Ready.")
            case .failed(let error):
                failed(error)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Intro

    private var intro: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.secondary)

            Text("One quick setup step")
                .font(.largeTitle.weight(.semibold))

            Text("Tscribe needs to download its speech model once (about \(ModelSpec.displayBytes)). This keeps the app itself small. It's a one-time download — after this, everything works offline.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)

            VStack(spacing: 10) {
                Button(installer.canResume ? "Resume Download" : "Download Speech Model") {
                    installer.canResume ? installer.resume() : installer.start()
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Button("Choose an already-downloaded model…") { chooseModelFile() }
                    .controlSize(.small)
                    .buttonStyle(.link)
            }
            .padding(.top, 4)

            privacyNote
        }
    }

    // MARK: Downloading

    private func downloading(fraction: Double, received: Int64, total: Int64, rate: Double) -> some View {
        VStack(spacing: 20) {
            Text("Downloading speech model…")
                .font(.title2.weight(.medium))

            ProgressView(value: fraction)
                .frame(width: 360)

            Text("\(Int(fraction * 100))%  •  \(byteString(received)) of \(byteString(total))\(rate > 0 ? "  •  \(byteString(Int64(rate)))/s" : "")")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Button("Cancel") { installer.cancel() }
                .controlSize(.large)

            Text("You can quit and come back — the download will resume where it left off.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
    }

    // MARK: Verifying / Installing

    private func busy(_ title: String) -> some View {
        VStack(spacing: 20) {
            ProgressView().controlSize(.large)
            Text(title)
                .font(.title2.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Failed

    private func failed(_ error: InstallError) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)

            Text("Setup didn't finish")
                .font(.title2.weight(.semibold))

            Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .labelStyle(.titleOnly)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 470)

            VStack(spacing: 10) {
                Button(installer.canResume ? "Resume Download" : "Try Again") {
                    installer.canResume ? installer.resume() : installer.start()
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Button("Choose an already-downloaded model…") { chooseModelFile() }
                    .controlSize(.small)
                    .buttonStyle(.link)
            }
            .padding(.top, 4)
        }
    }

    // MARK: Shared

    private var privacyNote: some View {
        Text("Only the speech model is downloaded, from Hugging Face. Your recordings and transcripts never leave this Mac.")
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 470)
            .padding(.top, 6)
    }

    private func byteString(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    private func chooseModelFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a ggml-large-v3.bin file you've already downloaded."
        if let binType = UTType(filenameExtension: "bin") {
            panel.allowedContentTypes = [binType, .data]
        }
        if panel.runModal() == .OK, let url = panel.url {
            installer.installFromFile(url)
        }
    }
}
#endif
