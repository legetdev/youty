import AppKit

// Keep the main app window alive across the user clicking the red close
// button. SwiftUI's WindowGroup tears down ContentView and all its
// @StateObject pipelines when the underlying NSWindow closes — that
// orphans the WKWebViews that the YouTube/Instagram/TikTok extractors
// rely on, and breaks any save fired from the menu bar / Share Sheet /
// Services / AppIntent later in the session.
//
// We intercept windowShouldClose, hide the window (orderOut) instead of
// closing it, and forward every other delegate method back to SwiftUI's
// own NSHostingWindowDelegate so the scene's lifecycle still ticks. The
// Dock-icon click is then handled by AppDelegate.applicationShouldHandleReopen,
// which brings the same window back. From the user's perspective: red-X
// looks like a normal close, but ContentView never goes away.

@MainActor
final class MainWindowKeeper: NSObject {

    static let shared = MainWindowKeeper()

    private(set) weak var managedWindow: NSWindow?
    private var originalDelegate: NSWindowDelegate?

    /// Take over the window's delegate. Idempotent — calling twice on the
    /// same window is a no-op.
    func attach(to window: NSWindow) {
        if managedWindow === window { return }
        managedWindow = window
        originalDelegate = window.delegate
        window.delegate = self
        // Without this, AppKit auto-releases the NSWindow when it closes,
        // which would also tear down ContentView even though our delegate
        // returns false. We want the AppKit window itself to persist.
        window.isReleasedWhenClosed = false
    }

    /// Bring the window back when the user clicks the Dock icon or chooses
    /// Window → youty from the menu.
    func reveal() {
        guard let window = managedWindow else { return }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

extension MainWindowKeeper: NSWindowDelegate {

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Hide instead of closing. ContentView + its WKWebView pipelines
        // stay alive so the menu bar / Share Sheet / Services / AppIntent
        // surfaces can keep saving in the background.
        sender.orderOut(nil)
        return false
    }

    // MARK: - Forwarding to SwiftUI's NSHostingWindowDelegate

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return originalDelegate?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original = originalDelegate, original.responds(to: aSelector) {
            return original
        }
        return nil
    }
}
