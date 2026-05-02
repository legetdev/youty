import Foundation
import WebKit

// MARK: - Loader

@MainActor
class TranscriptLoader: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {

    let webView: WKWebView
    private var continuation: CheckedContinuation<(title: String, markdown: String), Error>?

    override init() {
        let config = WKWebViewConfiguration()
        // Register message handler BEFORE creating webView
        let controller = WKUserContentController()
        config.userContentController = controller
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
        controller.add(self, name: "youtyTranscript")
    }

    func fetch(urlString: String) async throws -> (title: String, markdown: String) {
        guard let videoID = TranscriptFetcher.extractVideoID(from: urlString) else {
            throw FetchError.invalidURL
        }
        let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)")!
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            webView.load(URLRequest(url: url))
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Inject script that:
        // 1. Waits for ytInitialPlayerResponse
        // 2. Fetches transcript XML (using browser session so ATT headers are added automatically)
        // 3. Parses XML with DOMParser (avoids passing large raw XML to Swift)
        // 4. Posts segments to Swift via messageHandler
        let js = """
        (async function youtyFetch() {
            function post(obj) {
                window.webkit.messageHandlers.youtyTranscript.postMessage(obj);
            }

            // 1. Wait for ytInitialPlayerResponse (title + caption availability check)
            let ipr = null;
            for (let i = 0; i < 60; i++) {
                ipr = window.ytInitialPlayerResponse;
                if (ipr && ipr.videoDetails && ipr.videoDetails.title) break;
                await new Promise(r => setTimeout(r, 150));
            }
            if (!ipr || !ipr.videoDetails) {
                return post({error: 'no_response', url: location.href});
            }
            const title = ipr.videoDetails.title;

            // 2. Check captions exist
            const tracks = ipr.captions?.playerCaptionsTracklistRenderer?.captionTracks || [];
            if (!tracks.length) return post({error: 'no_captions', title});

            // 3. Find the "Show transcript" button (poll in case it renders late)
            let transcriptBtn = null;
            for (let i = 0; i < 30; i++) {
                const allBtns = Array.from(document.querySelectorAll('button, tp-yt-paper-button'));
                transcriptBtn = allBtns.find(b => /transcript/i.test(b.textContent || ''));
                if (transcriptBtn) break;
                await new Promise(r => setTimeout(r, 200));
            }
            if (!transcriptBtn) return post({error: 'no_transcript_button', title});

            // 4. Click it and wait for the panel to populate
            transcriptBtn.click();

            let segments = [];
            for (let i = 0; i < 60; i++) {
                await new Promise(r => setTimeout(r, 200));
                const els = document.querySelectorAll(
                    'ytd-transcript-segment-renderer yt-formatted-string.segment-text'
                );
                if (els.length > 0) {
                    segments = Array.from(els).map(el => (el.textContent || '').trim()).filter(Boolean);
                    break;
                }
            }

            if (!segments.length) return post({error: 'panel_empty', title});
            post({title, segments});
        })();
        """
        // evaluateJavaScript returns an error because the IIFE returns a Promise,
        // which can't be serialized to Obj-C. That error is expected and non-fatal —
        // the actual result arrives via WKScriptMessageHandler once the async work completes.
        webView.evaluateJavaScript(js) { _, error in
            if let err = error as NSError?,
               err.domain == WKErrorDomain,
               err.code == WKError.javaScriptResultTypeIsUnsupported.rawValue {
                // Expected: async IIFE returns a Promise. JS is still running.
            } else if let error = error {
                NSLog("[youty] unexpected JS inject error: \(error)")
            }
        }

        // Safety timeout: if the message handler hasn't fired in 30s, fail cleanly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self = self, self.continuation != nil else { return }
            self.finish(throwing: FetchError.parseError)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(throwing: FetchError.networkError)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(throwing: FetchError.networkError)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        guard message.name == "youtyTranscript",
              let dict = message.body as? [String: Any] else {
            finish(throwing: FetchError.parseError)
            return
        }

        NSLog("[youty] JS message: \(dict)")

        if let errorKey = dict["error"] as? String {
            switch errorKey {
            case "no_captions", "no_transcript_button":
                finish(throwing: FetchError.noTranscript)
            case "no_response":
                finish(throwing: FetchError.parseError)
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
        s
            .replacingOccurrences(of: "&amp;", with: "&")
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
           idx + 1 < path.count {
            return path[idx + 1]
        }
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let v = comps.queryItems?.first(where: { $0.name == "v" })?.value,
           !v.isEmpty {
            return v
        }
        return nil
    }

    static func formatMarkdown(title: String, segments: [String]) -> String {
        let raw = segments.joined(separator: " ")
        return "# \(title)\n\n\(wrapText(raw, lineWidth: 80))\n"
    }

    private static func wrapText(_ text: String, lineWidth: Int) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var lines: [String] = []
        var current = ""
        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word
            if candidate.count > lineWidth && !current.isEmpty {
                lines.append(current); current = word
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Segment (kept for API compatibility)

struct TranscriptSegment {
    let text: String
}

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
