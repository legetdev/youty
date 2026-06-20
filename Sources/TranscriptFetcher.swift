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
    let youtubeSummary: String
}

struct FetchResult: Sendable {
    let videoID: String
    let title: String
    let markdown: String
    let segments: [TranscriptSegment]
    let videoDetails: VideoDetails
}

// MARK: - Loader

// Fetches transcripts via WKWebView + DOM scraping.
//
// Why WKWebView (not URLSession):
//   YouTube's timedtext caption URLs return empty bodies from URLSession —
//   they require full browser session cookies. WKWebView maintains those cookies.
//
// Why Chrome UA:
//   YouTube omits captionTracks from ytInitialPlayerResponse for default WebKit UA.
//   Chrome UA causes YouTube to include the full response, which lets us verify
//   captions exist before proceeding.
//
// Why DOM scraping (not baseUrl fetch):
//   Fetching track.baseUrl from JS or URLSession returns empty XML regardless.
//   Clicking "Show transcript" triggers YouTube's internal get_transcript API,
//   which renders segments in the DOM. We scrape that rendered DOM.

@MainActor
class TranscriptLoader: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {

    let webView: WKWebView
    private var continuation: CheckedContinuation<FetchResult, Error>?
    private var jsInjected = false
    private var currentURL: URL?
    private var retriedNoResponse = false
    private var fetchGen = 0

    override init() {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        config.userContentController = controller
        config.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        super.init()
        // Chrome UA is REQUIRED: with the default WebKit UA, YouTube can omit
        // captionTracks from ytInitialPlayerResponse (see POSTMORTEM). Every other
        // extractor (PlayerFetcher/VideoExtractor/InstagramExtractor) sets this —
        // TranscriptFetcher was missing it.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
        webView.navigationDelegate = self
        controller.add(self, name: "youtyTranscript")
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
        retriedNoResponse = false
        let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)")!
        currentURL = url
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.startAttempt()
        }
    }

    /// Loads `currentURL` and arms a generation-guarded watchdog. Used for the
    /// first attempt and for the single retry on a transient `no_response`, so a
    /// stale watchdog from attempt 1 can never kill a succeeding attempt 2.
    private func startAttempt() {
        guard let url = currentURL else { return }
        fetchGen += 1
        let gen = fetchGen
        jsInjected = false
        webView.load(URLRequest(url: url))
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self] in
            guard let self, self.fetchGen == gen, self.continuation != nil else { return }
            self.finish(throwing: FetchError.parseError)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard continuation != nil, !jsInjected else { return }
        jsInjected = true

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
            if (!ipr || !ipr.videoDetails) return post({error: 'no_response'});

            const vd = ipr.videoDetails;

            // 2. Verify captions exist
            const tracks = (ipr.captions &&
                            ipr.captions.playerCaptionsTracklistRenderer &&
                            ipr.captions.playerCaptionsTracklistRenderer.captionTracks) || [];
            if (!tracks.length) return post({error: 'no_captions'});

            // 3. Find and click "Show transcript" button
            let btn = null;
            for (let i = 0; i < 30; i++) {
              const all = Array.from(document.querySelectorAll('button, tp-yt-paper-button'));
              btn = all.find(b => b.getAttribute('aria-label') === 'Show transcript')
                 || all.find(b => /^show transcript$/i.test((b.textContent || '').trim()))
                 || all.find(b => /show transcript/i.test(b.getAttribute('aria-label') || ''))
                 || all.find(b => /^transcript$/i.test((b.textContent || '').trim()));
              if (btn) break;
              await new Promise(r => setTimeout(r, 200));
            }
            if (!btn) return post({error: 'no_btn'});
            btn.click();

            // 4. Wait for segments — handles both legacy and modern YouTube UI.
            //    Timestamp extraction uses a multi-selector + regex fallback so
            //    DOM tweaks on YouTube's side don't silently produce empty `ts`.
            function extractTimestamp(el) {
              const sels = [
                '.segment-timestamp',
                '[class*="timestamp"]',
                '[class*="Timestamp"]',
                'button[aria-label]'
              ];
              for (const s of sels) {
                const node = el.querySelector(s);
                if (node) {
                  const t = (node.textContent || '').trim();
                  if (/^\\d+:\\d+(:\\d+)?$/.test(t)) return t;
                }
              }
              // Last-resort: scan full element text for a leading time pattern
              const m = (el.textContent || '').match(/(\\d+:\\d+(?::\\d+)?)/);
              return m ? m[1] : '';
            }

            const segs = [];
            for (let i = 0; i < 60; i++) {
              await new Promise(r => setTimeout(r, 200));

              // Legacy: ytd-transcript-segment-renderer
              const legacyEls = document.querySelectorAll('ytd-transcript-segment-renderer');
              if (legacyEls.length) {
                Array.from(legacyEls).forEach(el => {
                  const text = ((el.querySelector('yt-formatted-string.segment-text') || {}).textContent || '').trim();
                  if (text.length > 0) segs.push({ text, ts: extractTimestamp(el) });
                });
                if (segs.length) break;
              }

              // Modern: transcript-segment-view-model
              const modernEls = document.querySelectorAll('transcript-segment-view-model');
              if (modernEls.length) {
                Array.from(modernEls).forEach(el => {
                  const text = ((el.querySelector('span.ytAttributedStringHost') || {}).textContent || '').trim();
                  if (text.length > 0) segs.push({ text, ts: extractTimestamp(el) });
                });
                if (segs.length) break;
              }
            }
            if (!segs.length) return post({error: 'panel_empty'});

            // 5. Opportunistically extract YouTube's AI summary
            let youtubeSummary = '';
            try {
              for (const panel of (ipr.engagementPanels || [])) {
                const content = panel.engagementPanelSectionListRenderer
                                && panel.engagementPanelSectionListRenderer.content;
                if (!content) continue;
                const structured = content.structuredDescriptionContentRenderer;
                if (!structured) continue;
                for (const item of (structured.items || [])) {
                  const runs = item.videoDescriptionHeaderRenderer
                               && item.videoDescriptionHeaderRenderer.description
                               && item.videoDescriptionHeaderRenderer.description.runs;
                  if (runs) { youtubeSummary = runs.map(r => r.text||'').join(''); break; }
                }
                if (youtubeSummary) break;
              }
            } catch(e) {}

            post({
              title:   vd.title || '',
              videoID: vd.videoId || '',
              segments: segs,
              videoDetails: {
                videoID:          vd.videoId || '',
                title:            vd.title || '',
                author:           vd.author || '',
                lengthSeconds:    parseInt(vd.lengthSeconds || '0', 10),
                keywords:         vd.keywords || [],
                shortDescription: (vd.shortDescription || '').slice(0, 2000),
                youtubeSummary:   youtubeSummary.slice(0, 3000)
              }
            });
          })();
        })();
        """

        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("[youty] JS error: %@", error.localizedDescription)
            }
        }
        // Watchdog is armed per-attempt in startAttempt() (generation-guarded).
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
            switch errKey {
            case "no_captions", "no_btn", "panel_empty":
                finish(throwing: FetchError.noTranscript)
            case "no_response" where !retriedNoResponse:
                // ytInitialPlayerResponse wasn't ready in time — almost always a
                // transient first-load race (e.g. the first fetch right after
                // launch, before the WebView session warms). Reload once before
                // giving up; the generation-guarded watchdog makes this safe.
                retriedNoResponse = true
                NSLog("[youty] no_response — retrying once")
                startAttempt()
            default:
                finish(throwing: FetchError.parseError)
            }
            return
        }

        guard let title    = dict["title"]    as? String, !title.isEmpty,
              let videoID  = dict["videoID"]  as? String,
              let rawSegs  = dict["segments"] as? [[String: Any]],
              let vdRaw    = dict["videoDetails"] as? [String: Any],
              !rawSegs.isEmpty else {
            finish(throwing: FetchError.parseError)
            return
        }

        let videoDetails = VideoDetails(
            videoID:          videoID,
            title:            title,
            author:           vdRaw["author"]           as? String   ?? "",
            lengthSeconds:    vdRaw["lengthSeconds"]    as? Int      ?? 0,
            keywords:         vdRaw["keywords"]         as? [String] ?? [],
            shortDescription: vdRaw["shortDescription"] as? String   ?? "",
            youtubeSummary:   vdRaw["youtubeSummary"]   as? String   ?? ""
        )

        let segments = rawSegs.compactMap { raw -> TranscriptSegment? in
            guard let text = raw["text"] as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let ts = (raw["ts"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return TranscriptSegment(text: decodeHTMLEntities(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                                     timestamp: ts)
        }

        guard !segments.isEmpty else {
            finish(throwing: FetchError.noTranscript)
            return
        }

        let markdown = TranscriptFetcher.formatMarkdown(title: title, segments: segments.map(\.text))
        finish(returning: FetchResult(
            videoID:      videoID,
            title:        title,
            markdown:     markdown,
            segments:     segments,
            videoDetails: videoDetails
        ))
    }

    // MARK: - Private

    private func finish(returning value: FetchResult) {
        continuation?.resume(returning: value); continuation = nil
    }
    private func finish(throwing error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }

    private func decodeHTMLEntities(_ s: String) -> String {
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
        case .invalidURL:
            return "That URL doesn't look like a YouTube video. Make sure you copied the full link."
        case .networkError:
            return "Couldn't reach YouTube. Check your internet connection and try again."
        case .parseError:
            return "Youty couldn't read this YouTube page. The video may be private, deleted, or YouTube may have changed something. Try a different video."
        case .noTranscript:
            return "This YouTube video doesn't have captions, so there's no transcript to save."
        }
    }
}
