#if SPARKLE_UPDATES
import SwiftUI

/// The "Check for Updates…" menu item.
///
/// A view rather than a bare Button because `canCheckForUpdates` lives on the updater, a
/// nested ObservableObject — observing it here is what keeps the item's enabled state
/// truthful while a check is in flight.
struct CheckForUpdatesMenuItem: View {
    @ObservedObject var updater: UpdaterController

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}

/// The standing "check automatically" toggle on the start screen, so the first-run answer
/// is never a life sentence in either direction. Observes the updater directly, for the
/// same reason `CheckForUpdatesMenuItem` does.
struct AutoUpdateToggle: View {
    @ObservedObject var updater: UpdaterController

    var body: some View {
        Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
            .toggleStyle(.checkbox)
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .help("Asks docmayscience.com once a day whether a newer Tscribe exists. This is the only outbound connection Tscribe makes — nothing about you, this Mac, or your recordings is ever sent.")
    }
}

/// The one-time, first-run question: **may Tscribe check for updates?**
///
/// Asked rather than assumed. Tscribe's users handle privileged and evidentiary material,
/// and an app that quietly phones home on their behalf is not something they can vouch for
/// to a court or a client. So the default is off, the question is asked in plain language,
/// and "no" is a real answer that is remembered.
///
/// Shown once, on the first launch that reaches a normal screen — including for someone
/// upgrading from a version that predates auto-updates, who never sees onboarding.
struct UpdateConsentSheet: View {
    @ObservedObject var updater: UpdaterController

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)

            Text("Should Tscribe check for updates?")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text("Tscribe can check once a day for a new version. It's the only way you'll hear about fixes — but it's your call, and it's off until you say otherwise.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)

            VStack(alignment: .leading, spacing: 9) {
                point("checkmark.shield",
                      "This is the **only** outbound connection Tscribe ever makes. There is no analytics, no telemetry, no crash reporting — nothing else, ever.")
                point("lock.doc",
                      "Your recordings and transcripts are never sent anywhere, whichever you choose. Transcription and speaker identification always run entirely on this Mac.")
                point("desktopcomputer",
                      "Nothing about you or this Mac is sent — not even anonymously. A check asks “is there a newer version?” and nothing more.")
                point("hand.raised",
                      "Nothing is ever installed silently. You'll always see what changed and click Install yourself.")
            }
            .frame(maxWidth: 440)
            .padding(.vertical, 4)

            HStack(spacing: 12) {
                Button("Don't Check") { updater.answerConsent(enabled: false) }
                    .controlSize(.large)

                Button("Check for Updates") { updater.answerConsent(enabled: true) }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)

            Text("You can change this at any time on the start screen, and “Check for Updates…” in the Tscribe menu always works on demand. The **Complete edition** never checks at all — it makes no network connection of any kind.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
        }
        .padding(32)
        .frame(width: 520)
    }

    private func point(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
