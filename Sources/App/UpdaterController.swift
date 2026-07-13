#if SPARKLE_UPDATES
import SwiftUI
import Sparkle

/// Sparkle auto-updates — **Standard edition only** (plus Debug, so the flow can be
/// exercised locally). The Complete edition compiles without `SPARKLE_UPDATES`, so this
/// file, the Sparkle framework, and the appcast URL are all absent from it; that is what
/// keeps its "no network, ever" claim auditable. See the offline audit in package.sh,
/// which proves it rather than trusting it.
///
/// Privacy posture, for an audience handling privileged material:
///
///  * **Off until the user says yes.** `SUEnableAutomaticChecks=false` in the plist is
///    both the default *and* (because the key is present) the thing that stops Sparkle
///    showing its own permission prompt. Tscribe asks in its own words instead. With
///    checks off, Sparkle arms no timer and opens no connection: an install whose owner
///    said "no" makes **zero** outbound requests.
///  * **No profiling.** Nothing about this Mac is transmitted, not even anonymously.
///  * **No silent installs.** The user always sees the new version and clicks Install.
///  * **Signed updates only.** An update is installed only if it carries a valid EdDSA
///    signature from our key, so even a compromised appcast host cannot push a malicious
///    Tscribe onto a lawyer's machine.
@MainActor
final class UpdaterController: ObservableObject {
    private static let consentKey = "updateConsentAnswered"

    /// Drives the enabled state of the "Check for Updates…" menu item (Sparkle disables it
    /// while a check is already in flight).
    @Published private(set) var canCheckForUpdates = false

    /// Whether Tscribe checks for updates on its own — the user's consent switch. Writing
    /// it goes through Sparkle, which persists it as a user default that overrides the
    /// `false` baked into Info-Sparkle.plist.
    @Published var automaticallyChecksForUpdates: Bool {
        didSet { updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    /// True once the user has answered the first-run question, *either way*. Tracked
    /// separately from the answer so that "no" is a remembered choice and we never nag.
    @Published private(set) var consentAnswered: Bool

    private let controller: SPUStandardUpdaterController

    init() {
        // `startingUpdater: true` only starts Sparkle's scheduler. Because automatic checks
        // default to off, it schedules nothing and talks to nobody until the user opts in
        // or explicitly picks "Check for Updates…".
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        consentAnswered = UserDefaults.standard.bool(forKey: Self.consentKey)

        // The Info.plist keys are only *defaults*; a user default would override them. Force
        // profiling off unconditionally, so it stays off no matter what is in the domain.
        controller.updater.sendsSystemProfile = false

        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    private var updater: SPUUpdater { controller.updater }

    /// When Tscribe last asked the server anything, or nil if it never has. Shown in
    /// Settings: "no outbound connections" is a claim, and this is the receipt.
    var lastUpdateCheckDate: Date? { updater.lastUpdateCheckDate }

    /// A user-initiated check (the menu item). Always allowed regardless of consent —
    /// clicking it *is* consent for this one check.
    func checkForUpdates() {
        updater.checkForUpdates()
    }

    /// Record the first-run answer. "Yes" also runs an immediate check, which is what the
    /// user just asked for.
    func answerConsent(enabled: Bool) {
        automaticallyChecksForUpdates = enabled
        UserDefaults.standard.set(true, forKey: Self.consentKey)
        consentAnswered = true
        if enabled { updater.checkForUpdates() }
    }
}
#endif
