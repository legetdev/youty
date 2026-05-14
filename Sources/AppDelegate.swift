import AppKit

// macOS-specific glue that SwiftUI doesn't expose directly:
//   1. NSServices provider — handles right-click "Save to Youty Vault" in any app.
//   2. Re-activation policy — let the user reopen the main window from the Dock
//      after closing it (default SwiftUI macOS app exits when last window closes
//      unless WindowGroup is reopened via Dock click, which works on macOS 14+).
//   3. Re-activation re-drain — when the app gains focus, drain the queue in
//      case a Share Extension dropped an item while the URL-scheme open was in
//      flight.
//
// Wired into the SwiftUI app via `@NSApplicationDelegateAdaptor` in YoutyApp.

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register self as the system-wide services provider so the NSServices
        // entry in Info.plist routes to `saveURLToYoutyVault(_:userData:error:)`.
        NSApp.servicesProvider = self
        // Refresh the system service registry so the menu item appears
        // without requiring a restart of every app on disk.
        NSUpdateDynamicServices()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // User clicked the Dock icon (or chose Show in Menu Bar → Open
        // Youty). If our main window was hidden by `MainWindowKeeper`,
        // bring it back.
        if !flag {
            MainWindowKeeper.shared.reveal()
        }
        return true
    }

    // MARK: - Services

    /// Service entry point. Selector matches `NSMessage = "saveURLToYoutyVault"`
    /// in Info.plist. macOS hands us the user's pasteboard selection on the
    /// main thread, so we can safely assume MainActor isolation and call
    /// the funnel synchronously — no Task dispatch (which would also work
    /// in production but would defer through the run loop).
    @objc func saveURLToYoutyVault(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let urlString = readURL(from: pboard)
        guard let urlString, !urlString.isEmpty else {
            error.pointee = "No URL found in selection." as NSString
            return
        }
        MainActor.assumeIsolated {
            IngestionFunnel.shared.ingest(urlString: urlString, source: "services")
        }
    }

    /// Extract a URL from the pasteboard. macOS Services pass URLs either
    /// as the system URL type (Safari address bar, file paths) or as
    /// plain text. We accept either, and if the text contains a URL
    /// substring we pull the first match.
    private func readURL(from pboard: NSPasteboard) -> String? {
        if let urlsRaw = pboard.string(forType: .URL), !urlsRaw.isEmpty {
            return urlsRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let urls = pboard.readObjects(forClasses: [NSURL.self]) as? [NSURL],
           let first = urls.first {
            return first.absoluteString
        }
        if let text = pboard.string(forType: .string) {
            return firstURL(in: text) ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func firstURL(in text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        if let match = detector.firstMatch(in: text, range: range), let url = match.url {
            return url.absoluteString
        }
        return nil
    }
}
