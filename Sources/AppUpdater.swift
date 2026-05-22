import Foundation
import Sparkle

// Single owner of the Sparkle updater. Living in one place keeps the
// `import Sparkle` footprint small and lets both the application-menu
// "Check for Updates…" command and the Settings → About button share
// the same controller instance (so cadence + state stay coherent).
//
// EdDSA verification is mandatory — every released DMG is signed with
// the private key kept in the author's macOS Keychain. The matching
// public key (SUPublicEDKey in Info.plist) is the only thing the
// shipped binary trusts.
@MainActor
final class AppUpdater {
    static let shared = AppUpdater()

    let controller: SPUStandardUpdaterController

    private init() {
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil)
    }

    /// Triggers the standard Sparkle "Check for Updates…" UI flow.
    /// Same call the application-menu command issues — exposed here so
    /// the Settings → About panel can offer the action too.
    static func checkForUpdates() {
        Self.shared.controller.checkForUpdates(nil)
    }
}
