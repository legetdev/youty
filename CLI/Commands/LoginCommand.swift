import Foundation
import AppKit
import WebKit

// `youty login <platform>` — one-time sign-in flow for platforms whose
// extractors need authenticated session cookies. Currently only
// Instagram needs this; TikTok + YouTube work anonymously.
//
// Why this exists: WKWebView cookies live in WKWebsiteDataStore.default(),
// keyed by the binary's bundle identifier. The Mac app and the CLI are
// separate binaries with separate stores — Mac-app cookies don't transfer
// to the CLI. We can't share via App Groups (those need a paid Apple
// Developer team for signing; we explicitly chose not to require one).
//
// So the CLI has its own login flow: open a visible WKWebView window
// pointed at the platform's login page, the user signs in, the cookies
// land in the CLI's WKWebsiteDataStore.default() — which is persistent
// across invocations of the CLI binary. Subsequent `youty save <ig-url>`
// just works.

enum LoginCommand {

    static func run(_ args: ParsedArgs) -> Never {
        guard let platform = args.positionals.first, !platform.isEmpty else {
            cliStderr("""
                error: missing platform.
                usage: youty login <platform>

                Supported platforms: instagram

                """)
            exit(64)
        }
        switch platform.lowercased() {
        case "instagram", "ig":
            runInstagram()
        default:
            cliStderr("""
                error: unsupported platform '\(platform)'.

                Only Instagram needs a CLI-side login — YouTube and TikTok
                work anonymously.

                """)
            exit(64)
        }
    }

    // MARK: - Instagram

    private static func runInstagram() -> Never {
        // LoginSession is @MainActor-isolated. We're already on the main
        // thread (DebugRunner / main.swift), so use assumeIsolated to call
        // it synchronously. Task + sem.wait would deadlock since the
        // MainActor executor IS this thread.
        let result = MainActor.assumeIsolated { () -> LoginResult in
            LoginSession.run(
                platformName: "Instagram",
                startURL: URL(string: "https://www.instagram.com/accounts/login/")!,
                userAgent:
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                isLoggedIn: { url in
                    guard url.host?.contains("instagram.com") == true else { return false }
                    let path = url.path
                    if path.hasPrefix("/accounts/login") { return false }
                    if path.hasPrefix("/accounts/onetap") { return false }
                    if path.hasPrefix("/challenge") { return false }
                    if path.hasPrefix("/accounts/two_factor") { return false }
                    // "/" or "/feed/" or "/{username}/" — all post-login.
                    return true
                }
            )
        }
        switch result {
        case .success:
            print("✓ Signed in to Instagram. `youty save https://www.instagram.com/reel/…` now works.")
            exit(0)
        case .cancelled:
            cliStderr("Sign-in cancelled.\n")
            exit(1)
        }
    }
}

// MARK: - Login session controller

enum LoginResult {
    case success
    case cancelled
}

/// Runs an NSApp-attached, visible login window with a WKWebView and
/// blocks until the user either succeeds (URL passes `isLoggedIn`) or
/// closes the window. Cookies persist into WKWebsiteDataStore.default()
/// so subsequent CLI invocations see the authenticated session.
@MainActor
final class LoginSession: NSObject, WKNavigationDelegate, NSWindowDelegate {

    private let platformName: String
    private let startURL: URL
    private let userAgent: String
    private let isLoggedIn: @Sendable (URL) -> Bool

    private var window: NSWindow?
    private var webView: WKWebView?
    private var statusField: NSTextField?
    private var result: LoginResult = .cancelled
    private var finished = false

    private init(platformName: String,
                 startURL: URL,
                 userAgent: String,
                 isLoggedIn: @escaping @Sendable (URL) -> Bool) {
        self.platformName = platformName
        self.startURL = startURL
        self.userAgent = userAgent
        self.isLoggedIn = isLoggedIn
    }

    /// Entry point. Blocks until the user signs in or cancels.
    static func run(platformName: String,
                    startURL: URL,
                    userAgent: String,
                    isLoggedIn: @escaping @Sendable (URL) -> Bool) -> LoginResult {
        let session = LoginSession(platformName: platformName,
                                    startURL: startURL,
                                    userAgent: userAgent,
                                    isLoggedIn: isLoggedIn)
        return session.runInternal()
    }

    private func runInternal() -> LoginResult {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        // Window: titled, closable, resizable. Centered, 720×860 — wide
        // enough for IG's full login layout, tall enough that 2FA fits
        // without scrolling.
        let frame = NSRect(x: 0, y: 0, width: 720, height: 860)
        let win = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Sign in to \(platformName) — youty"
        win.center()
        win.delegate = self
        win.isReleasedWhenClosed = false

        // Status bar at the top so the user understands what's happening.
        let statusContainer = NSView(frame: NSRect(x: 0, y: frame.height - 32, width: frame.width, height: 32))
        statusContainer.autoresizingMask = [.width, .minYMargin]
        let status = NSTextField(labelWithString: "Sign in below. youty closes this window automatically once you're authenticated.")
        status.frame = NSRect(x: 12, y: 8, width: frame.width - 24, height: 18)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.autoresizingMask = [.width]
        statusContainer.addSubview(status)
        statusField = status

        let webContainer = NSView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height - 32))
        webContainer.autoresizingMask = [.width, .height]

        let webCfg = WKWebViewConfiguration()
        webCfg.websiteDataStore = .default()   // persistent cookies
        let web = WKWebView(frame: webContainer.bounds, configuration: webCfg)
        web.autoresizingMask = [.width, .height]
        web.customUserAgent = userAgent
        web.navigationDelegate = self
        web.allowsBackForwardNavigationGestures = true
        webContainer.addSubview(web)

        win.contentView?.addSubview(webContainer)
        win.contentView?.addSubview(statusContainer)

        self.window = win
        self.webView = web

        web.load(URLRequest(url: startURL))
        win.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        app.run()   // pumps until finish(...) calls NSApp.stop
        return result
    }

    private func finish(_ outcome: LoginResult) {
        guard !finished else { return }
        finished = true
        result = outcome
        webView?.removeFromSuperview()
        window?.close()
        NSApplication.shared.stop(nil)
        // Phantom event so run() returns immediately instead of waiting
        // on the next user input.
        if let evt = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        ) {
            NSApplication.shared.postEvent(evt, atStart: false)
        }
    }

    private func updateStatus(_ text: String) {
        statusField?.stringValue = text
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        if isLoggedIn(url) {
            updateStatus("Signed in — finishing up…")
            // Brief delay so any final post-login cookies persist before
            // we tear down the WebView and its data store handle.
            let me = self
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                me.finish(.success)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        updateStatus("Load failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        updateStatus("Load failed: \(error.localizedDescription)")
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if !finished {
            finish(.cancelled)
        }
    }
}
