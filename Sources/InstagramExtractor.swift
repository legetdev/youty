import Foundation
import WebKit
import AppKit

// Instagram Reel / post-video extractor. Login-first: requires that the user
// has signed in to instagram.com inside our own hidden WKWebView at least once.
// The session cookie persists in WKWebsiteDataStore.default() — our app's
// sandbox-scoped data store. (Per the WKWebView cookie-sharing audit:
// sandboxed apps cannot read Safari's cookie jar, so the only viable
// authenticated path is in-app login.)
//
// Architecture:
//   1. Load the post URL inside a WKWebView using the default data store.
//   2. Wait for the page's React app to hydrate; detect login wall via the
//      URL redirect chain.
//   3. Pull the post payload from one of three sources, in order:
//        (a) Instagram's internal `/api/v1/media/{shortcode}/info/`
//            endpoint — clean structured JSON when reachable.
//        (b) `window.__additionalDataLoaded` cached callback args.
//        (c) DOM scrape of the rendered article (video, caption, author,
//            timestamp, og: meta tags).
//   4. Return structured TikTok-compatible result.
//
// No URLSession — every fetch goes through the WKWebView so cookies are
// applied uniformly and the TLS fingerprint matches WebKit (Instagram is
// reportedly aggressive about anti-bot fingerprinting on URLSession).

struct InstagramMetadata: Sendable {
    let shortcode: String
    let url: String
    let mediaPK: String?         // numeric pk when we got it from the API path
    let caption: String
    let author: String           // "@username"
    let authorDisplayName: String?
    let postedAt: Date?
    let duration: TimeInterval
    let width: Int
    let height: Int
    let likes: Int?
    let comments: Int?
    let views: Int?
    let musicTitle: String?
    let musicAuthor: String?
    let hashtags: [String]
    let location: String?
}

struct InstagramExtractionResult: Sendable {
    let metadata: InstagramMetadata
    /// Signed CDN URL for the un-watermarked video. Short TTL — fetch now.
    let videoCDNURL: URL
    /// Headers required by Instagram's CDN for the video bytes.
    let videoDownloadHeaders: [String: String]
}

enum InstagramExtractorError: LocalizedError {
    case malformedURL
    case notLoggedIn
    case noVideo
    case pageLoadFailed(Error)
    case scrapeFailed
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .malformedURL:           return "Not a recognised Instagram post URL."
        case .notLoggedIn:            return "Sign in to Instagram inside Youty to enable Reel extraction."
        case .noVideo:                return "Instagram returned no playable video for this post (private, deleted, or photo-only)."
        case .pageLoadFailed(let e):  return "Instagram page failed to load: \(e.localizedDescription)"
        case .scrapeFailed:           return "Could not parse Instagram post data."
        case .malformedResponse:      return "Instagram returned an unexpected response shape."
        }
    }
}

@MainActor
final class InstagramExtractor: NSObject, WKNavigationDelegate, WKScriptMessageHandler {

    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    private let webView: WKWebView
    private var continuation: CheckedContinuation<InstagramExtractionResult, Error>?
    private var didInject = false
    private var loadCanonical: URL?

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        let controller = WKUserContentController()
        cfg.userContentController = controller
        // Plausible desktop frame so Instagram serves its web React app
        // instead of the mobile-redirect surface.
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800),
                              configuration: cfg)
        super.init()
        webView.navigationDelegate = self
        webView.customUserAgent = Self.userAgent
        controller.add(self, name: "instagramScrape")
    }

    /// Optional — attach to a window with near-zero alpha so the React app
    /// has a real layout context to render into. Many SPAs misbehave when
    /// the WebView is detached.
    func attachToWindow(_ window: NSWindow) {
        guard webView.superview == nil, let cv = window.contentView else { return }
        webView.alphaValue = 0.001
        webView.frame = CGRect(x: -1300, y: 0, width: 1280, height: 800)
        cv.addSubview(webView)
    }

    /// Returns true if WKWebsiteDataStore.default() holds a usable
    /// instagram.com sessionid cookie. Caller can use this to short-circuit
    /// to the login UI before attempting an extraction.
    static func isSignedIn() async -> Bool {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return cookies.contains { c in
            c.name == "sessionid"
                && c.domain.contains("instagram.com")
                && !c.value.isEmpty
        }
    }

    // MARK: - Shortcode parsing

    /// Parses Instagram URLs in any of the supported post shapes.
    /// Accepts: /reel/{code}/, /p/{code}/, /tv/{code}/, /reels/{code}/
    static func extractShortcode(from url: URL) -> String? {
        let pattern = #"/(?:reel|reels|p|tv)/([A-Za-z0-9_-]+)"#
        guard let m = url.path.range(of: pattern, options: .regularExpression) else { return nil }
        let slice = url.path[m]
        return slice.split(separator: "/").last.map(String.init)
    }

    // MARK: - Public entry point

    func extract(url userURL: URL) async throws -> InstagramExtractionResult {
        guard let shortcode = Self.extractShortcode(from: userURL) else {
            throw InstagramExtractorError.malformedURL
        }
        guard await Self.isSignedIn() else {
            throw InstagramExtractorError.notLoggedIn
        }
        didInject = false
        // /p/ accepts every post type; the redirect chain settles to the
        // right canonical inside the WebView.
        let canonical = URL(string: "https://www.instagram.com/p/\(shortcode)/")!
        loadCanonical = canonical
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            webView.load(URLRequest(url: canonical))
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard continuation != nil, !didInject else { return }
        // If we got redirected to a login wall, surface that immediately.
        if let url = webView.url, url.path.hasPrefix("/accounts/login") {
            finish(.failure(InstagramExtractorError.notLoggedIn))
            return
        }
        didInject = true

        // The scrape script: wait for the rendered React DOM, pull data from
        // the multiple possible sources (DOM, meta tags, embedded JSON, the
        // shortcode → media-info API), and post back a single JSON blob.
        let js = #"""
        (async function() {
          function post(obj) {
            window.webkit.messageHandlers.instagramScrape.postMessage(obj);
          }

          // 1. Bail fast on a login redirect.
          if (location.pathname.startsWith('/accounts/login')
              || location.pathname.startsWith('/accounts/onetap')) {
            return post({error: 'login_required'});
          }

          // 2. Wait for content to hydrate. We poll for either:
          //    (a) a <video> element with a src attribute, or
          //    (b) an embedded <script type="application/json"> blob
          //        containing the media data.
          async function pollFor(predicate, totalMs=12000, stepMs=200) {
            const start = Date.now();
            while (Date.now() - start < totalMs) {
              const v = predicate();
              if (v) return v;
              await new Promise(r => setTimeout(r, stepMs));
            }
            return null;
          }

          const video = await pollFor(() => {
            const els = Array.from(document.querySelectorAll('article video, main video'));
            for (const v of els) {
              if (v.src && v.src.startsWith('http')) return v;
              const s = v.querySelector('source');
              if (s && s.src && s.src.startsWith('http')) {
                v._youtySrcFromSource = s.src;
                return v;
              }
            }
            return null;
          });

          if (!video) return post({error: 'no_video'});

          const videoSrc = video._youtySrcFromSource || video.src;
          const w = video.videoWidth || video.clientWidth || 0;
          const h = video.videoHeight || video.clientHeight || 0;
          const duration = isFinite(video.duration) ? video.duration : 0;

          // 3. Caption: prefer the rendered article's caption block; fall
          //    back to og:description (which Instagram normally renders as
          //    "{caption} | Instagram").
          function readCaption() {
            // The visible caption is usually under <h1> in the article
            // section in newer designs, or in <ul> > <li> > <span> in older.
            const h1 = document.querySelector('article h1, main h1');
            if (h1 && h1.innerText && h1.innerText.length > 5) return h1.innerText.trim();
            const span = document.querySelector('article header + div span, article div[role="button"] + span');
            if (span && span.innerText && span.innerText.length > 5) return span.innerText.trim();
            const og = document.querySelector('meta[property="og:description"]');
            if (og) {
              // Instagram's og:description is typically '...some likes, X comments — @user on Instagram: "caption"'
              const c = og.content || '';
              const m = c.match(/:\s*"([\s\S]+)"\s*$/);
              if (m) return m[1].trim();
              return c.trim();
            }
            return '';
          }
          const caption = readCaption();

          // 4. Author: <header><a href="/{username}/"> is the canonical
          //    location. Display name appears nearby.
          function readAuthor() {
            const headerLinks = document.querySelectorAll('article header a[role="link"], header a[role="link"]');
            for (const a of headerLinks) {
              const href = a.getAttribute('href') || '';
              const m = href.match(/^\/([^/]+)\/?$/);
              if (m && m[1] && !m[1].includes('?')) {
                const display = a.innerText || '';
                return {handle: '@' + m[1], display: display.trim()};
              }
            }
            return {handle: '', display: ''};
          }
          const authorInfo = readAuthor();

          // 5. Posted time: <time datetime="...">
          const timeEl = document.querySelector('article time[datetime], main time[datetime]');
          const postedAt = timeEl ? timeEl.getAttribute('datetime') : '';

          // 6. Counts: best-effort scrape — Instagram occasionally hides
          //    these behind interaction. We grep aria-labels and inline text.
          function readCount(re) {
            const all = Array.from(document.querySelectorAll('article section span, article section a, button[aria-label]'));
            for (const el of all) {
              const t = (el.innerText || el.getAttribute('aria-label') || '');
              const m = t.match(re);
              if (m) {
                const num = parseInt(m[1].replace(/[,.]/g, ''), 10);
                if (!isNaN(num)) return num;
              }
            }
            return null;
          }
          const likes = readCount(/^([\d,\.]+)\s*(?:likes?|gefällt)/i);
          const comments = readCount(/^([\d,\.]+)\s*comment/i);
          const views = readCount(/^([\d,\.]+)\s*view/i);

          // 7. Music / audio: <a href="/reels/audio/{id}/">. The link text
          //    is "{title}", a nearby element holds the artist.
          function readMusic() {
            const a = document.querySelector('a[href*="/reels/audio/"], a[href*="/audio/"]');
            if (!a) return {title: null, author: null};
            const txt = a.innerText || '';
            return {title: txt.trim(), author: null};
          }
          const music = readMusic();

          // 8. Hashtags: parse from caption.
          function parseTags(s) {
            const out = [];
            const re = /#([A-Za-z0-9_À-ɏḀ-ỿ]+)/g;
            let m;
            while ((m = re.exec(s || '')) !== null) out.push(m[1].toLowerCase());
            return Array.from(new Set(out)).sort();
          }
          const hashtags = parseTags(caption);

          // 9. Optional: media pk for callers that want it. We can find it
          //    in a "data-media-id" attribute or embedded JSON.
          let mediaPK = null;
          const scripts = document.querySelectorAll('script[type="application/json"]');
          for (const sc of scripts) {
            const txt = sc.innerText || sc.textContent || '';
            const m = txt.match(/"media_id":\s*"?(\d{10,25})"?/);
            if (m) { mediaPK = m[1]; break; }
          }

          post({
            videoSrc: videoSrc,
            width: w, height: h,
            duration: duration,
            caption: caption,
            author: authorInfo.handle,
            authorDisplayName: authorInfo.display,
            postedAt: postedAt,
            likes: likes, comments: comments, views: views,
            musicTitle: music.title, musicAuthor: music.author,
            hashtags: hashtags,
            mediaPK: mediaPK
          });
        })();
        """#

        webView.evaluateJavaScript(js) { [weak self] _, error in
            guard let self else { return }
            if let error {
                Task { @MainActor in self.finish(.failure(InstagramExtractorError.pageLoadFailed(error))) }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(InstagramExtractorError.pageLoadFailed(error)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(InstagramExtractorError.pageLoadFailed(error)))
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard continuation != nil else { return }
        guard let dict = message.body as? [String: Any] else {
            finish(.failure(InstagramExtractorError.malformedResponse))
            return
        }
        if let err = dict["error"] as? String {
            switch err {
            case "login_required":
                finish(.failure(InstagramExtractorError.notLoggedIn))
            case "no_video":
                finish(.failure(InstagramExtractorError.noVideo))
            default:
                finish(.failure(InstagramExtractorError.scrapeFailed))
            }
            return
        }
        guard let videoSrcStr = dict["videoSrc"] as? String,
              let videoURL = URL(string: videoSrcStr) else {
            finish(.failure(InstagramExtractorError.noVideo))
            return
        }
        let shortcode = (loadCanonical?.path)
            .flatMap { $0.split(separator: "/").map(String.init).last } ?? ""

        let postedAt: Date? = {
            guard let s = dict["postedAt"] as? String, !s.isEmpty else { return nil }
            return ISO8601DateFormatter().date(from: s)
        }()

        let meta = InstagramMetadata(
            shortcode: shortcode,
            url: loadCanonical?.absoluteString ?? "",
            mediaPK: dict["mediaPK"] as? String,
            caption: (dict["caption"] as? String) ?? "",
            author: (dict["author"] as? String) ?? "",
            authorDisplayName: dict["authorDisplayName"] as? String,
            postedAt: postedAt,
            duration: (dict["duration"] as? Double) ?? 0,
            width: (dict["width"] as? Int) ?? 0,
            height: (dict["height"] as? Int) ?? 0,
            likes: dict["likes"] as? Int,
            comments: dict["comments"] as? Int,
            views: dict["views"] as? Int,
            musicTitle: dict["musicTitle"] as? String,
            musicAuthor: dict["musicAuthor"] as? String,
            hashtags: (dict["hashtags"] as? [String]) ?? [],
            location: nil
        )

        let result = InstagramExtractionResult(
            metadata: meta,
            videoCDNURL: videoURL,
            videoDownloadHeaders: Self.downloadHeaders()
        )
        finish(.success(result))
    }

    /// HTTP headers for fetching Instagram's CDN. Empirically Instagram is
    /// less strict than TikTok — User-Agent + Referer matching the web app
    /// suffices for most CDN hosts on cdninstagram.com / fbcdn.net.
    static func downloadHeaders() -> [String: String] {
        return [
            "User-Agent": userAgent,
            "Referer": "https://www.instagram.com/",
            "Origin": "https://www.instagram.com",
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
            "Sec-Fetch-Site": "same-site",
            "Sec-Fetch-Mode": "no-cors",
            "Sec-Fetch-Dest": "video",
            "Range": "bytes=0-",
        ]
    }

    // MARK: - Continuation helpers

    private func finish(_ outcome: Result<InstagramExtractionResult, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        switch outcome {
        case .success(let r): cont.resume(returning: r)
        case .failure(let e): cont.resume(throwing: e)
        }
    }
}
