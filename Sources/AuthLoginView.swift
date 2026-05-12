import SwiftUI
import WebKit
import AppKit

// Generic in-app sign-in surface. Hosts a WKWebView pointed at the platform's
// login URL; cookies persist in WKWebsiteDataStore.default() (our app's
// sandbox-scoped data store). Used by Instagram (always — login-first) and
// TikTok (rarely, when anonymous fails).
//
// Once the WebView reaches a "logged-in" URL (matching the supplied
// `successHostPredicate`), the sheet auto-dismisses and `onComplete(.success)`
// fires.
//
// Liquid-glass aesthetic: HUD-style window with translucent material, sized
// for a clean inline login. No app branding inside the sheet — users see
// instagram.com / tiktok.com as they expect.

struct AuthLoginConfig {
    /// The page to load first.
    let startURL: URL
    /// Display name, e.g. "Instagram" or "TikTok".
    let platformName: String
    /// Returns true when the supplied navigated URL indicates a successful
    /// authenticated session (e.g. redirect from /accounts/login/ to /).
    let isLoggedInURL: @Sendable (URL) -> Bool
}

enum AuthLoginResult {
    case success
    case cancelled
}

struct AuthLoginView: View {

    let config: AuthLoginConfig
    let onComplete: (AuthLoginResult) -> Void

    @State private var currentURL: String = ""
    @State private var isLoading: Bool = true

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().opacity(0.4)
                WebViewContainer(
                    config: config,
                    onURLChange: { currentURL = $0 },
                    onLoading: { isLoading = $0 },
                    onSuccess: { onComplete(.success) }
                )
            }
        }
        .frame(minWidth: 520, minHeight: 640)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Sign in to \(config.platformName)")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 12, height: 12)
            }
            Button {
                onComplete(.cancelled)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.regularMaterial)
    }
}

// MARK: - WebView wrapping

private struct WebViewContainer: NSViewRepresentable {

    let config: AuthLoginConfig
    let onURLChange: (String) -> Void
    let onLoading: (Bool) -> Void
    let onSuccess: () -> Void

    func makeNSView(context: Context) -> WKWebView {
        // Use the default store so cookies persist across launches.
        let webCfg = WKWebViewConfiguration()
        webCfg.websiteDataStore = .default()
        // Modern desktop UA so the platform serves its full login UI (not the
        // mobile / app-redirect surface).
        webCfg.applicationNameForUserAgent =
            "Version/26.0 Safari/605.1.15"
        let web = WKWebView(frame: .zero, configuration: webCfg)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.load(URLRequest(url: config.startURL))
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: WebViewContainer
        init(parent: WebViewContainer) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.onLoading(true)
            if let url = webView.url?.absoluteString { parent.onURLChange(url) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onLoading(false)
            if let url = webView.url {
                parent.onURLChange(url.absoluteString)
                if parent.config.isLoggedInURL(url) {
                    // Brief delay so the post-login redirect can settle and
                    // any final cookies get persisted before we tear down.
                    let p = parent
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        p.onSuccess()
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onLoading(false)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.onLoading(false)
        }
    }
}

// Reused from ContentView — declared there as a SwiftUI/AppKit material
// bridge. Re-stating the type signature here so AuthLoginView compiles
// independently if ContentView is restructured later.
//
// (No body — the actual struct lives elsewhere in the project.)

// MARK: - Convenience config builders

extension AuthLoginConfig {
    /// Default Instagram login surface. Success = redirected away from
    /// `/accounts/login`.
    static let instagram = AuthLoginConfig(
        startURL: URL(string: "https://www.instagram.com/accounts/login/")!,
        platformName: "Instagram",
        isLoggedInURL: { url in
            guard url.host?.contains("instagram.com") == true else { return false }
            let path = url.path
            // After login, Instagram redirects to "/" or "/{username}/" or
            // sometimes to a 2FA challenge page. Consider any non-login,
            // non-challenge path on instagram.com a success.
            if path.hasPrefix("/accounts/login") { return false }
            if path.hasPrefix("/accounts/onetap") { return false }
            if path.hasPrefix("/challenge") { return false }
            if path.hasPrefix("/accounts/two_factor") { return false }
            // "/" or "/feed/" or "/{username}/" are all logged-in states.
            return true
        }
    )

    /// Default TikTok login surface. Used as a fallback only — most TikTok
    /// extractions don't require auth.
    static let tiktok = AuthLoginConfig(
        startURL: URL(string: "https://www.tiktok.com/login")!,
        platformName: "TikTok",
        isLoggedInURL: { url in
            guard url.host?.contains("tiktok.com") == true else { return false }
            // TikTok redirects to / or /foryou after login.
            let path = url.path
            if path.hasPrefix("/login") { return false }
            if path.hasPrefix("/passport") { return false }
            return true
        }
    )
}
