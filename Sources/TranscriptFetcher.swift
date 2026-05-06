import Foundation
import WebKit

// MARK: - Result types

struct TranscriptSegment: Sendable {
    let text: String
    let timestamp: String  // "M:SS" or "H:MM:SS"
}

struct VideoDetails: Sendable {
    let videoID: String
    let title: String
    let author: String
    let lengthSeconds: Int
    let keywords: [String]
    let shortDescription: String
}

struct FetchResult: Sendable {
    let videoID: String
    let title: String
    let markdown: String               // plain prose, for display
    let segments: [TranscriptSegment]  // timestamped, for vault
    let videoDetails: VideoDetails
}

// MARK: - Loader

@MainActor
class TranscriptLoader: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {

    let webView: WKWebView
    private var continuation: CheckedContinuation<FetchResult, Error>?
    private var jsInjected = false

    override init() {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        config.userContentController = controller
        config.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        super.init()
        webView.navigationDelegate = self
        controller.add(self, name: "youtyTranscript")
        // Block images, media, fonts, and video CDN — cuts page load time significantly
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
        webView.load(URLRequest(url: URL(string: "https://www.youtube.com")!))
    }

    func fetch(urlString: String) async throws -> FetchResult {
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
        guard continuation != nil, !jsInjected else { return }
        jsInjected = true

        // Wait for ytInitialPlayerResponse, select the best caption track,
        // and post its URL directly. No DOM scraping, no button clicking.
        // Track priority: manual English > auto English > manual any > auto any.
        let js = """
        (function() {
          (async function youtyFetch() {
            function post(obj) {
              window.webkit.messageHandlers.youtyTranscript.postMessage(obj);
            }

            let ipr = null;
            for (let i = 0; i < 80; i++) {
              ipr = window.ytInitialPlayerResponse;
              if (ipr && ipr.videoDetails && ipr.videoDetails.title) break;
              await new Promise(r => setTimeout(r, 150));
            }
            if (!ipr || !ipr.videoDetails) return post({error: 'no_response'});

            const vd = ipr.videoDetails;
            const tracks = (ipr.captions &&
                            ipr.captions.playerCaptionsTracklistRenderer &&
                            ipr.captions.playerCaptionsTracklistRenderer.captionTracks) || [];
            if (!tracks.length) return post({error: 'no_captions'});

            const isManual  = t => t.kind !== 'asr';
            const isEnglish = t => (t.languageCode || '').startsWith('en');
            const track = tracks.find(t => isManual(t) && isEnglish(t))
                       || tracks.find(t => isEnglish(t))
                       || tracks.find(t => isManual(t))
                       || tracks[0];

            post({
              title:      vd.title || '',
              captionUrl: track.baseUrl,
              videoID:    vd.videoId || '',
              videoDetails: {
                videoID:          vd.videoId || '',
                title:            vd.title || '',
                author:           vd.author || '',
                lengthSeconds:    parseInt(vd.lengthSeconds || '0', 10),
                keywords:         vd.keywords || [],
                shortDescription: (vd.shortDescription || '').slice(0, 2000)
              }
            });
          })();
        })();
        """

        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("[youty] evaluateJavaScript error: %@", error.localizedDescription)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self] in
            guard let self, self.continuation != nil else { return }
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
            NSLog("[youty] JS error: %@", errKey)
            finish(throwing: errKey == "no_captions" ? FetchError.noTranscript : FetchError.parseError)
            return
        }

        guard let title      = dict["title"]      as? String, !title.isEmpty,
              let captionUrl = dict["captionUrl"]  as? String,
              let videoID    = dict["videoID"]     as? String,
              let vdRaw      = dict["videoDetails"] as? [String: Any],
              let url        = URL(string: captionUrl) else {
            finish(throwing: FetchError.parseError)
            return
        }

        let videoDetails = VideoDetails(
            videoID:          videoID,
            title:            title,
            author:           vdRaw["author"]           as? String ?? "",
            lengthSeconds:    vdRaw["lengthSeconds"]    as? Int    ?? 0,
            keywords:         vdRaw["keywords"]         as? [String] ?? [],
            shortDescription: vdRaw["shortDescription"] as? String ?? ""
        )

        // Fetch the caption XML on a background task, then return to MainActor
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let xml = String(data: data, encoding: .utf8) ?? ""
                let parsed = CaptionXMLParser.parse(xml)
                guard !parsed.isEmpty else {
                    self.finish(throwing: FetchError.noTranscript)
                    return
                }
                let segments = parsed.map {
                    TranscriptSegment(text: $0.text, timestamp: $0.formattedTimestamp)
                }
                let markdown = TranscriptFetcher.formatMarkdown(title: title,
                                                                segments: parsed.map(\.text))
                self.finish(returning: FetchResult(
                    videoID:      videoID,
                    title:        title,
                    markdown:     markdown,
                    segments:     segments,
                    videoDetails: videoDetails
                ))
            } catch {
                self.finish(throwing: FetchError.networkError)
            }
        }
    }

    // MARK: - Private

    private func finish(returning value: FetchResult) {
        continuation?.resume(returning: value)
        continuation = nil
    }

    private func finish(throwing error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

// MARK: - Caption XML parser

private final class CaptionXMLParser: NSObject, XMLParserDelegate {

    struct Segment {
        let text: String
        let startSeconds: Double

        var formattedTimestamp: String {
            let total = Int(startSeconds)
            let h = total / 3600
            let m = (total % 3600) / 60
            let s = total % 60
            return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                         : String(format: "%d:%02d", m, s)
        }
    }

    private var segments: [Segment] = []
    private var currentStart: Double = 0
    private var currentText = ""
    private var inText = false

    static func parse(_ xml: String) -> [Segment] {
        let instance = CaptionXMLParser()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = instance
        parser.parse()
        return instance.segments
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attributeDict: [String: String] = [:]) {
        guard elementName == "text" else { return }
        currentStart = Double(attributeDict["start"] ?? "0") ?? 0
        currentText = ""
        inText = true
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inText else { return }
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        guard elementName == "text" else { return }
        inText = false
        let cleaned = decodeEntities(currentText.trimmingCharacters(in: .whitespacesAndNewlines))
        if !cleaned.isEmpty { segments.append(Segment(text: cleaned, startSeconds: currentStart)) }
    }

    private func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;",  with: "&")
         .replacingOccurrences(of: "&lt;",   with: "<")
         .replacingOccurrences(of: "&gt;",   with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&#39;",  with: "'")
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
