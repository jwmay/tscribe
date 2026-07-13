#if !SPARKLE_UPDATES
import SwiftUI
import AppKit

/// The **Complete edition**'s answer to "am I out of date?".
///
/// Complete's whole promise is that it never makes a network connection — so it cannot
/// check, and we don't pretend otherwise. Instead:
///
///  * It knows its own build date (`TscribeBuildDate`, stamped into Info.plist by
///    package.sh) and, once that date is genuinely old, says so on the start screen.
///    That is a **local date comparison** — no connection, nothing sent.
///  * "Check for Updates…" in the Tscribe menu explains the situation and offers to open
///    the Tscribe page in the user's **browser**. Tscribe itself still connects to
///    nothing; the browser does, and only because the user clicked.
///
/// Everything here is compiled out of the Standard edition, which uses Sparkle instead.
enum OfflineUpdateInfo {
    /// Where a newer Complete edition is published. Only ever handed to NSWorkspace — this
    /// string is never fetched by Tscribe, and the offline audit accounts for it.
    static let tscribePage = URL(string: "https://docmayscience.com/tscribe/")!

    /// After this long, a build is old enough that it's worth mentioning.
    static let stalenessThreshold: TimeInterval = 180 * 24 * 60 * 60   // ~6 months

    /// The date this copy was packaged, stamped into Info.plist at package time.
    /// Absent in unpackaged dev builds, in which case there is nothing to say.
    static var buildDate: Date? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "TscribeBuildDate") as? String
        else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }

    static var isStale: Bool {
        guard let buildDate else { return false }
        return Date().timeIntervalSince(buildDate) > stalenessThreshold
    }

    static var buildDateText: String {
        guard let buildDate else { return "an unknown date" }
        return buildDate.formatted(.dateTime.month(.wide).year())
    }

    static func openTscribePage() {
        NSWorkspace.shared.open(tscribePage)
    }
}

/// Shown by "Check for Updates…" in the Complete edition.
struct OfflineUpdateSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)

            Text("Tscribe can't check for updates")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text("This is the **Complete edition**. It never makes a network connection of any kind — that's the point of it — so it has no way to ask whether a newer version exists.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)

            Text("This copy is from **\(OfflineUpdateInfo.buildDateText)**.")
                .font(.callout)
                .multilineTextAlignment(.center)

            Button("Open the Tscribe Page in Your Browser") {
                OfflineUpdateInfo.openTscribePage()
                dismiss()
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            Text("This opens your web browser. Tscribe still connects to nothing.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Button("Done") { dismiss() }
                .controlSize(.small)
                .buttonStyle(.link)
        }
        .padding(32)
        .frame(width: 460)
    }
}
#endif
