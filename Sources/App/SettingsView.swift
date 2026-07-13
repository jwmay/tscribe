import SwiftUI

/// The Settings window (Tscribe ▸ Settings…, ⌘,).
///
/// Added in 2.1.1 because 2.1.0 shipped a promise it didn't keep: the first-run consent sheet
/// said the update choice could be changed "at any time on the start screen", but the toggle
/// was styled as fine print, buried below two paragraphs of actual fine print, and — worse —
/// existed *only* on the start screen, so with a transcript open there was no way to reach it
/// at all. A privacy choice you can't find is not a choice.
///
/// Settings is where a Mac user looks, and it works from any screen. The start screen keeps a
/// visible toggle too (grouped with the other settings, no longer disguised as a footnote).
///
/// Deliberately update-only: the two start-screen checkboxes (auto-detect language, reduce
/// false text in silence) are choices you make about *the file you are about to drop*, not
/// standing app preferences, and they belong next to the drop zone.
struct SettingsView: View {
    @ObservedObject var model: TranscriberModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if SPARKLE_UPDATES
            UpdateSettingsPane(updater: model.updater)
            #else
            OfflineUpdateSettingsPane()
            #endif
        }
        .padding(24)
        .frame(width: 460)
    }
}

#if !SPARKLE_UPDATES
/// The Complete edition has no updater at all, so there is nothing here to switch on or off.
/// Say that plainly rather than showing a dead toggle or an empty window.
struct OfflineUpdateSettingsPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Updates")
                .font(.title3.weight(.semibold))

            Label {
                Text("This is the **Complete edition**. It makes no network connection of any kind, so it cannot check for updates — there is nothing to turn on.")
            } icon: {
                Image(systemName: "wifi.slash")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text("This copy is from **\(OfflineUpdateInfo.buildDateText)**.")
                .font(.callout)

            Divider()

            Button("Open the Tscribe Page in Your Browser") {
                OfflineUpdateInfo.openTscribePage()
            }

            Text("This opens your web browser. Tscribe itself still connects to nothing.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
