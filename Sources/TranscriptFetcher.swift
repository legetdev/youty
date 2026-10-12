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
    enum TranscriptSource: Sendable { case captions, onDeviceSpeech }

    let videoID: String
    let title: String
    let markdown: String
    let segments: [TranscriptSegment]
    let videoDetails: VideoDetails
    var transcriptSource: TranscriptSource = .captions
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
    private var currentVideoID: String?
    private var stepTimer: Timer?
    private var currentURL: URL?
    private var currentNavigation: WKNavigation?
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
        controller.addUserScript(WKUserScript(source: Self.scrapeScript, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true))
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
        retriedNoResponse = false
        currentVideoID = videoID
        let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)")!
        currentURL = url
        return try await withCheckedThrowingContinuation { cont in
            // A newer request supersedes any in-flight one: end that one first.
            self.continuation?.resume(throwing: CancellationError())
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
        currentNavigation = webView.load(URLRequest(url: url))
        // Drive the page script's steps from a native timer (WebKit throttles a
        // hidden page's own timers to almost nothing).
        stepTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.fetchGen == gen, self.continuation != nil else { return }
                self.webView.evaluateJavaScript("window.__youtyStep && window.__youtyStep()", completionHandler: nil)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        stepTimer = timer
        // Outlasts the page script's own bounded waits (≈32 s) even when YouTube
        // reloads the page mid-fetch, so the script — not this timer — decides,
        // and an empty transcript panel reaches the on-device fallback.
        DispatchQueue.main.asyncAfter(deadline: .now() + 55) { [weak self] in
            guard let self, self.fetchGen == gen, self.continuation != nil else { return }
            self.finish(throwing: FetchError.parseError)
        }
    }

    // MARK: - WKNavigationDelegate

    /// Reads the transcript from a watch page. Installed as a user script so it
    /// starts as soon as the page's data exists (not after every image and ad
    /// finishes) and runs again if YouTube reloads the page mid-fetch.
    static let scrapeScript = """
        (function() {
          if (location.pathname !== '/watch' || window.__youtyStep) return;
          // A step machine instead of timer loops: WebKit throttles a hidden
          // page's own timers to almost nothing, so the app calls
          // window.__youtyStep() from a native timer and every wait is bounded
          // by the clock. YouTube may reload the page; the new page starts over.
          const st = { phase: 'ipr', start: Date.now(), phaseStart: Date.now(), done: false, details: null, btn: null };
          function post(obj) {
            st.done = true;
            window.webkit.messageHandlers.youtyTranscript.postMessage(obj);
          }
          function next(phase) { st.phase = phase; st.phaseStart = Date.now(); }
          function waited() { return Date.now() - st.phaseStart; }
          function extractTimestamp(el) {
            const sels = ['.segment-timestamp', '[class*="timestamp"]', '[class*="Timestamp"]', 'button[aria-label]'];
            for (const s of sels) {
              const node = el.querySelector(s);
              if (node) {
                const t = (node.textContent || '').trim();
                if (/^\\d+:\\d+(:\\d+)?$/.test(t)) return t;
              }
            }
            const m = (el.textContent || '').match(/(\\d+:\\d+(?::\\d+)?)/);
            return m ? m[1] : '';
          }
          function segments() {
            const segs = [];
            document.querySelectorAll('ytd-transcript-segment-renderer').forEach(el => {
              const text = ((el.querySelector('yt-formatted-string.segment-text') || {}).textContent || '').trim();
              if (text.length > 0) segs.push({ text, ts: extractTimestamp(el) });
            });
            if (segs.length) return segs;
            document.querySelectorAll('transcript-segment-view-model').forEach(el => {
              const text = ((el.querySelector('span.ytAttributedStringHost') || {}).textContent || '').trim();
              if (text.length > 0) segs.push({ text, ts: extractTimestamp(el) });
            });
            return segs;
          }
          function summary(ipr) {
            try {
              for (const panel of (ipr.engagementPanels || [])) {
                const content = panel.engagementPanelSectionListRenderer && panel.engagementPanelSectionListRenderer.content;
                const structured = content && content.structuredDescriptionContentRenderer;
                for (const item of ((structured && structured.items) || [])) {
                  const runs = item.videoDescriptionHeaderRenderer && item.videoDescriptionHeaderRenderer.description
                               && item.videoDescriptionHeaderRenderer.description.runs;
                  if (runs) return runs.map(r => r.text || '').join('');
                }
              }
            } catch (e) {}
            return '';
          }
          window.__youtyStep = function() {
            if (st.done) return;
            try {
              const ipr = window.ytInitialPlayerResponse;
              if (st.phase === 'ipr') {
                const ready = ipr && ((ipr.playabilityStatus && ipr.playabilityStatus.status
                                       && ipr.playabilityStatus.status !== 'OK')
                                      || (ipr.videoDetails && ipr.videoDetails.title));
                if (!ready) { if (waited() > 12000) post({error: 'no_response'}); return; }
                const playability = ipr.playabilityStatus || {};
                if (playability.status && playability.status !== 'OK') {
                  const reason = String(playability.reason || '').toLowerCase();
                  const requiresSignIn = playability.status === 'LOGIN_REQUIRED' || reason.includes('sign in')
                    || reason.includes('age verification') || reason.includes('confirm your age');
                  return post({error: requiresSignIn ? 'restricted_video' : 'unavailable_video'});
                }
                const vd = ipr.videoDetails;
                st.details = {
                  videoID: vd.videoId || '', title: vd.title || '', author: vd.author || '',
                  lengthSeconds: parseInt(vd.lengthSeconds || '0', 10), keywords: vd.keywords || [],
                  shortDescription: (vd.shortDescription || '').slice(0, 2000), youtubeSummary: ''
                };
                const tracks = (ipr.captions && ipr.captions.playerCaptionsTracklistRenderer
                                && ipr.captions.playerCaptionsTracklistRenderer.captionTracks) || [];
                if (!tracks.length) return post({error: 'no_captions', videoDetails: st.details});
                next('btn');
              }
              if (st.phase === 'btn') {
                const all = Array.from(document.querySelectorAll('button, tp-yt-paper-button'));
                const btn = all.find(b => b.getAttribute('aria-label') === 'Show transcript')
                         || all.find(b => /^show transcript$/i.test((b.textContent || '').trim()))
                         || all.find(b => /show transcript/i.test(b.getAttribute('aria-label') || ''))
                         || all.find(b => /^transcript$/i.test((b.textContent || '').trim()));
                if (!btn) { if (waited() > 12000) post({error: 'no_btn', videoDetails: st.details}); return; }
                btn.click();
                next('segs');
                return;
              }
              if (st.phase === 'segs') {
                const segs = segments();
                if (!segs.length) {
                  // Some videos only load their transcript for YouTube's own
                  // player; an empty panel falls back to on-device transcription.
                  if (waited() > 8000) post({error: 'panel_empty', videoDetails: st.details});
                  return;
                }
                const vd = ipr.videoDetails;
                post({ title: vd.title || '', videoID: vd.videoId || '', segments: segs,
                       videoDetails: Object.assign({}, st.details, {youtubeSummary: summary(ipr).slice(0, 3000)}) });
              }
            } catch (e) {
              post({error: 'panel_empty', videoDetails: st.details || undefined});
            }
          };
          window.__youtyStep();
        })();
        """

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard Self.isActiveNavigation(navigation, active: currentNavigation) else { return }
        finish(throwing: FetchError.networkError)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard Self.isActiveNavigation(navigation, active: currentNavigation) else { return }
        finish(throwing: FetchError.networkError)
    }

    /// Filters late warm-up and previous-attempt callbacks from the active fetch.
    nonisolated static func isActiveNavigation(_ navigation: WKNavigation?, active: WKNavigation?) -> Bool {
        guard let active else { return false }
        return navigation === active
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "youtyTranscript", continuation != nil else { return }
        guard let dict = message.body as? [String: Any] else {
            finish(throwing: FetchError.parseError)
            return
        }
        // A page from an earlier request (or the home-page warm-up) can still
        // report in; only the requested video may complete this fetch.
        let reported = (dict["videoID"] as? String)
            ?? ((dict["videoDetails"] as? [String: Any])?["videoID"] as? String)
        if let reported, !reported.isEmpty, reported != currentVideoID { return }

        if let errKey = dict["error"] as? String {
            switch errKey {
            case "restricted_video":
                finish(throwing: FetchError.restrictedVideo)
            case "unavailable_video":
                finish(throwing: FetchError.unavailableVideo)
            case "no_captions", "no_btn", "panel_empty":
                // Missing captions, or a transcript panel YouTube changed: fall
                // back to on-device transcription of the audio instead of failing.
                guard let details = (dict["videoDetails"] as? [String: Any]).flatMap(Self.videoDetails),
                      !details.videoID.isEmpty else {
                    finish(throwing: FetchError.noTranscript)
                    return
                }
                NSLog("[youty] %@ — transcribing audio on-device", errKey)
                transcribeAudio(details: details)
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

        guard let videoDetails = Self.videoDetails(vdRaw) else {
            finish(throwing: FetchError.parseError)
            return
        }

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

    nonisolated static func videoDetails(_ raw: [String: Any]) -> VideoDetails? {
        guard let videoID = raw["videoID"] as? String, let title = raw["title"] as? String,
              !title.isEmpty else { return nil }
        return VideoDetails(
            videoID:          videoID,
            title:            title,
            author:           raw["author"]           as? String   ?? "",
            lengthSeconds:    raw["lengthSeconds"]    as? Int      ?? 0,
            keywords:         raw["keywords"]         as? [String] ?? [],
            shortDescription: raw["shortDescription"] as? String   ?? "",
            youtubeSummary:   raw["youtubeSummary"]   as? String   ?? ""
        )
    }

    /// Completes the pending fetch with an on-device transcript of the audio.
    private func transcribeAudio(details: VideoDetails) {
        fetchGen += 1   // the page's watchdog no longer applies; transcription takes longer
        let gen = fetchGen
        let locale = SettingsStore.transcriptionLocale(hint: "\(details.title)\n\(details.shortDescription)")
        Task {
            do {
                let segments = try await YouTubeAudioTranscript.transcribe(videoID: details.videoID, locale: locale)
                // A newer fetch replaced this one while transcribing: never answer it with this video.
                guard fetchGen == gen else { return }
                guard !segments.isEmpty else { throw FetchError.noTranscript }
                finish(returning: FetchResult(
                    videoID: details.videoID,
                    title: details.title,
                    markdown: TranscriptFetcher.formatMarkdown(title: details.title, segments: segments.map(\.text)),
                    segments: segments,
                    videoDetails: details,
                    transcriptSource: .onDeviceSpeech))
            } catch {
                NSLog("[youty] on-device transcription failed: %@", error.localizedDescription)
                guard fetchGen == gen else { return }
                finish(throwing: FetchError.noTranscript)
            }
        }
    }

    private func finish(returning value: FetchResult) {
        stepTimer?.invalidate(); stepTimer = nil
        continuation?.resume(returning: value); continuation = nil
    }
    private func finish(throwing error: Error) {
        stepTimer?.invalidate(); stepTimer = nil
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
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        guard PlatformRouter.platform(for: s) == .youtube,
              let url = URL(string: s) else { return nil }
        let host = url.host?.lowercased() ?? ""
        let path = url.pathComponents
        let id: String?
        if host == "youtu.be" {
            id = path.dropFirst().first
        } else if path.count >= 3, ["shorts", "embed", "live"].contains(path[1]) {
            id = path[2]
        } else if url.path == "/watch" {
            id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "v" })?.value
        } else {
            id = nil
        }
        guard let id, !id.isEmpty, id.count <= 64,
              id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        return id
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
    case invalidURL, networkError, parseError, noTranscript, restrictedVideo, unavailableVideo
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "That URL doesn't look like a YouTube video. Make sure you copied the full link."
        case .networkError:
            return "Couldn't reach YouTube. Check your internet connection and try again."
        case .parseError:
            return "Youty couldn't read this YouTube page. The video may be private, deleted, or YouTube may have changed something. Try a different video."
        case .noTranscript:
            return "This YouTube video has no captions, and on-device transcription of its audio didn't work. Try again later, or pick a different transcription language in Settings."
        case .restrictedVideo:
            return "YouTube requires sign-in or age verification for this video. Youty can't fetch its transcript from the current session."
        case .unavailableVideo:
            return "YouTube couldn't make this video available in the current session. It may be private, deleted, or region-restricted."
        }
    }
}
