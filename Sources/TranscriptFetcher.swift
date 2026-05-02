import Foundation
import WebKit

// MARK: - Loader

@MainActor
class TranscriptLoader: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {

    let webView: WKWebView
    private var continuation: CheckedContinuation<(title: String, markdown: String), Error>?
    private var jsInjected = false

    override init() {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        config.userContentController = controller
        config.mediaTypesRequiringUserActionForPlayback = .all  // don't autoplay video
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        super.init()
        webView.navigationDelegate = self
        controller.add(self, name: "youtyTranscript")
        // Block images, media, and video CDN — cuts page load time significantly
        let blockRules = """
        [
          {"trigger":{"url-filter":".*","resource-type":["image","media","font"]},"action":{"type":"block"}},
          {"trigger":{"url-filter":".*\\\\.googlevideo\\\\.com"},"action":{"type":"block"}}
        ]
        """
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "youty-block", encodedContentRuleList: blockRules
        ) { [weak self] list, _ in
            if let list = list {
                DispatchQueue.main.async { self?.webView.configuration.userContentController.add(list) }
            }
        }
    }

    func attachToWindow(_ window: NSWindow) {
        guard webView.superview == nil, let cv = window.contentView else { return }
        webView.frame = CGRect(x: -1300, y: 0, width: 1280, height: 800)
        cv.addSubview(webView)
        // Pre-warm session: load YouTube homepage so JS bundles are cached before user requests
        webView.load(URLRequest(url: URL(string: "https://www.youtube.com")!))
    }

    func fetch(urlString: String) async throws -> (title: String, markdown: String) {
        guard let videoID = TranscriptFetcher.extractVideoID(from: urlString) else {
            throw FetchError.invalidURL
        }
        jsInjected = false
        let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)")!
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            webView.load(URLRequest(url: url))
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Only inject when a fetch is pending and this is the right page
        guard continuation != nil else { return }
        guard !jsInjected else { return }
        jsInjected = true

        // IMPORTANT: outer wrapper is a plain sync IIFE (returns undefined, not a Promise).
        // evaluateJavaScript only errors on Promise return values — that error silently
        // kills the async task in some WebKit versions. The sync wrapper prevents this.
        let js = """
        (function() {
          (async function youtyFetch() {
            function post(obj) {
              window.webkit.messageHandlers.youtyTranscript.postMessage(obj);
            }

            // 1. Wait for ytInitialPlayerResponse
            let ipr = null;
            for (let i = 0; i < 80; i++) {
              ipr = window.ytInitialPlayerResponse;
              if (ipr && ipr.videoDetails && ipr.videoDetails.title) break;
              await new Promise(r => setTimeout(r, 150));
            }
            if (!ipr || !ipr.videoDetails) {
              return post({error: 'no_response', url: location.href.slice(0,80)});
            }
            const title = ipr.videoDetails.title;

            // 2. Quick caption availability check
            const tracks = (ipr.captions &&
                            ipr.captions.playerCaptionsTracklistRenderer &&
                            ipr.captions.playerCaptionsTracklistRenderer.captionTracks) || [];
            if (!tracks.length) return post({error: 'no_captions', title});

            // 3. Find the Show Transcript button (poll up to 6 s)
            let btn = null;
            for (let i = 0; i < 30; i++) {
              const all = Array.from(document.querySelectorAll('button, tp-yt-paper-button'));
              btn = all.find(b => /transcript/i.test(b.textContent || ''));
              if (btn) break;
              await new Promise(r => setTimeout(r, 200));
            }
            if (!btn) return post({error: 'no_btn', title,
              btns: Array.from(document.querySelectorAll('button')).slice(0,5).map(b=>b.textContent?.trim()).join('|')
            });

            btn.click();

            // 4. Wait for panel segments (up to 12 s)
            let segs = [];
            for (let i = 0; i < 60; i++) {
              await new Promise(r => setTimeout(r, 200));
              const els = document.querySelectorAll(
                'ytd-transcript-segment-renderer yt-formatted-string.segment-text'
              );
              if (els.length) {
                segs = Array.from(els).map(e => (e.textContent || '').trim()).filter(Boolean);
                break;
              }
            }
            if (!segs.length) return post({error: 'panel_empty', title});
            post({title, segments: segs});
          })();
        })();
        """

        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("[youty] evaluateJavaScript error: %@", error.localizedDescription)
            }
        }

        // 35-second hard timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self] in
            guard let self = self, self.continuation != nil else { return }
            self.finish(throwing: FetchError.parseError)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(throwing: FetchError.networkError)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        finish(throwing: FetchError.networkError)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "youtyTranscript",
              let dict = message.body as? [String: Any] else {
            finish(throwing: FetchError.parseError)
            return
        }

        if let errKey = dict["error"] as? String {
            NSLog("[youty] JS error: %@ — %@", errKey, dict.description)
            switch errKey {
            case "no_captions", "no_btn":
                finish(throwing: FetchError.noTranscript)
            default:
                finish(throwing: FetchError.parseError)
            }
            return
        }

        guard let title = dict["title"] as? String,
              let segments = dict["segments"] as? [String],
              !segments.isEmpty else {
            finish(throwing: FetchError.parseError)
            return
        }

        let cleaned = segments.map { decodeHTMLEntities($0) }
        let markdown = TranscriptFetcher.formatMarkdown(title: title, segments: cleaned)
        finish(returning: (title, markdown))
    }

    // MARK: - Private

    private func finish(returning value: (title: String, markdown: String)) {
        continuation?.resume(returning: value)
        continuation = nil
    }

    private func finish(throwing error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private func decodeHTMLEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
         .replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&#39;", with: "'")
         .replacingOccurrences(of: "&#x27;", with: "'")
         .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}

// MARK: - Helpers

enum TranscriptFetcher {

    static func extractVideoID(from raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if !s.hasPrefix("http") { s = "https://" + s }
        guard let url = URL(string: s) else { return nil }
        let host = url.host ?? ""
        if host.contains("youtu.be") {
            let id = url.pathComponents.dropFirst().first
            return id?.isEmpty == false ? String(id!) : nil
        }
        let path = url.pathComponents
        if let idx = path.firstIndex(where: { $0 == "shorts" || $0 == "embed" }),
           idx + 1 < path.count { return path[idx + 1] }
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let v = comps.queryItems?.first(where: { $0.name == "v" })?.value,
           !v.isEmpty { return v }
        return nil
    }

    static func formatMarkdown(title: String, segments: [String]) -> String {
        let raw = segments.joined(separator: " ")
        return "# \(title)\n\n\(wrapText(raw, lineWidth: 80))\n"
    }

    private static func wrapText(_ text: String, lineWidth: Int) -> String {
        var lines: [String] = []; var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            let candidate = current.isEmpty ? word : current + " " + word
            if candidate.count > lineWidth && !current.isEmpty { lines.append(current); current = word }
            else { current = candidate }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: "\n")
    }
}

struct TranscriptSegment { let text: String }

// MARK: - Errors

enum FetchError: LocalizedError {
    case invalidURL, networkError, parseError, noTranscript
    var errorDescription: String? {
        switch self {
        case .invalidURL:   return "That doesn't look like a valid YouTube link."
        case .networkError: return "Couldn't reach YouTube. Check your connection."
        case .parseError:   return "Couldn't read the video page. YouTube may have changed."
        case .noTranscript: return "This video has no available transcript."
        }
    }
}
