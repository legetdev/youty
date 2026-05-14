import AppKit

// A hidden, off-screen NSWindow used as the WKWebView host for the
// extraction pipelines (TranscriptLoader, PlayerFetcher, VideoExtractor,
// InstagramExtractor). The Mac app gets this for free from its SwiftUI
// scene; the CLI has to provide it explicitly.
//
// The window is borderless, 1x1, parked at (-10000, -10000) and never
// ordered front — so the user never sees a flash. NSApplication's
// servicing of the run loop is what we get from `NSApp.run()` inside
// the CLI's command dispatch.

@MainActor
enum CLIHostWindow {

    private static var window: NSWindow?

    /// Build (or return) the hidden window. Idempotent.
    ///
    /// Sizing matters: WKWebView's content process throttles or skips work
    /// when the host window/view is zero-area or transparent (energy
    /// optimization). We give the window a real 1280×800 layout area so
    /// YouTube's JS hydrates exactly like in the Mac app, then park the
    /// window off-screen so the user never sees it.
    @discardableResult
    static func create() -> NSWindow {
        if let existing = window { return existing }
        let w = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.isReleasedWhenClosed = false
        w.isOpaque = true
        w.backgroundColor = .black
        w.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        w.alphaValue = 1
        // The window has to actually be in the screen list for WebKit to
        // service it. orderBack puts it behind everything (off-screen
        // anyway) without stealing focus.
        w.orderBack(nil)
        window = w
        return w
    }
}
