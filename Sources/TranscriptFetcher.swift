import Foundation
import WebKit

// MARK: - Public API

@MainActor
class TranscriptLoader: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    private var continuation: CheckedContinuation<(title: String, markdown: String), Error>?

    override init() {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        super.init()
        webView.navigationDelegate = self
        // Suppress YouTube's bot-detection for programmatic page loads
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
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
        // Poll for ytInitialPlayerResponse (YouTube populates it after JS runs)
        let js = """
        (async () => {
            let r = null;
            for (let i = 0; i < 60; i++) {
                r = window.ytInitialPlayerResponse;
                if (r && r.videoDetails) break;
                await new Promise(res => setTimeout(res, 150));
            }
            if (!r || !r.videoDetails) return JSON.stringify({error: 'no_response'});

            const title = r.videoDetails.title || 'YouTube Transcript';
            const trackList = r.captions
                && r.captions.playerCaptionsTracklistRenderer
                && r.captions.playerCaptionsTracklistRenderer.captionTracks;
            if (!trackList || !trackList.length) return JSON.stringify({error: 'no_captions'});

            const track = trackList.find(t => t.languageCode === 'en')
                       || trackList.find(t => t.languageCode && t.languageCode.startsWith('en'))
                       || trackList[0];

            try {
                const resp = await fetch(track.baseUrl);
                const xml = await resp.text();
                return JSON.stringify({title, xml});
            } catch (e) {
                return JSON.stringify({error: 'fetch_failed: ' + String(e)});
            }
        })()
        """
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { [weak self] result in
            let mapped: Result<Any?, Error> = result.map { $0 as Any? }
            DispatchQueue.main.async { self?.handleJSResult(mapped) }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(throwing: FetchError.networkError)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(throwing: FetchError.networkError)
    }

    // MARK: - Private

    private func handleJSResult(_ result: Result<Any?, Error>) {
        switch result {
        case .failure:
            finish(throwing: FetchError.parseError)
        case .success(let value):
            guard let json = value as? String,
                  let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                finish(throwing: FetchError.parseError)
                return
            }
            if let errorMsg = dict["error"] {
                finish(throwing: errorMsg.contains("no_captions") ? FetchError.noTranscript : FetchError.parseError)
                return
            }
            guard let title = dict["title"], let xml = dict["xml"] else {
                finish(throwing: FetchError.parseError)
                return
            }
            let segments = TranscriptFetcher.parseXML(xml)
            guard !segments.isEmpty else {
                finish(throwing: FetchError.noTranscript)
                return
            }
            let markdown = TranscriptFetcher.formatMarkdown(title: title, segments: segments)
            finish(returning: (title, markdown))
        }
    }

    private func finish(returning value: (String, String)) {
        continuation?.resume(returning: value)
        continuation = nil
    }

    private func finish(throwing error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

// MARK: - Helpers (reused by loader)

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

    static func parseXML(_ xml: String) -> [TranscriptSegment] {
        let parser = TranscriptXMLParser()
        return parser.parse(xml)
    }

    static func formatMarkdown(title: String, segments: [TranscriptSegment]) -> String {
        let raw = segments.map(\.text).joined(separator: " ")
        let wrapped = wrapText(raw, lineWidth: 80)
        return "# \(title)\n\n\(wrapped)\n"
    }

    private static func wrapText(_ text: String, lineWidth: Int) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var lines: [String] = []
        var current = ""
        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word
            if candidate.count > lineWidth && !current.isEmpty {
                lines.append(current)
                current = word
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Segment

struct TranscriptSegment {
    let text: String
}

// MARK: - XML Parser

private class TranscriptXMLParser: NSObject, XMLParserDelegate {
    private var segments: [TranscriptSegment] = []
    private var currentText = ""
    private var inText = false

    func parse(_ xml: String) -> [TranscriptSegment] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return segments
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "text" { inText = true; currentText = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { currentText += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        if name == "text" {
            inText = false
            let clean = decodeHTMLEntities(currentText).trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { segments.append(TranscriptSegment(text: clean)) }
        }
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

// MARK: - Errors

enum FetchError: LocalizedError {
    case invalidURL, networkError, parseError, noTranscript

    var errorDescription: String? {
        switch self {
        case .invalidURL:    return "That doesn't look like a valid YouTube link."
        case .networkError:  return "Couldn't reach YouTube. Check your connection."
        case .parseError:    return "Couldn't read the video page. YouTube may have changed."
        case .noTranscript:  return "This video has no available transcript."
        }
    }
}
