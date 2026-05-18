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
        case .malformedURL:
            return "That URL doesn't look like an Instagram post. Use a /reel/, /reels/, /p/, or /tv/ link."
        case .notLoggedIn:
            return "Sign in to Instagram inside Youty to save Reels. Paste any Reel URL and the sign-in window will appear."
        case .noVideo:
            return "Instagram returned no video for this post. It may be private, deleted, or a photo-only post."
        case .pageLoadFailed(let e):
            return "Couldn't load the Instagram page. Check your internet connection and try again. (\(e.localizedDescription))"
        case .scrapeFailed:
            return "Youty couldn't read this Instagram post. Try a different post."
        case .malformedResponse:
            return "Instagram returned an unexpected response. Try the save again — this usually clears on retry."
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

        // Scraping strategy (revised per current Instagram, May 2026):
        //   The rendered <video> element carries a `blob:` MediaSource URL,
        //   NOT the real CDN MP4. The actual media URL lives inside one of
        //   the page's <script type="application/json" data-sjs> blocks, in
        //   either REST shape (`xdt_api__v1__media__shortcode__web_info`)
        //   or GraphQL shape (`xdt_shortcode_media`). React class hashes
        //   churn every few weeks, so the JSON payload is the only durable
        //   path.
        //
        //   The outer wrapper returns undefined synchronously because
        //   WKWebView.evaluateJavaScript can't bridge Promise returns
        //   ("JavaScript execution returned a result of an unsupported
        //   type"). The inner IIFE posts results via messageHandlers.
        let js = #"""
        (function outer() {
          (async function() {
          function post(obj) {
            try { window.webkit.messageHandlers.instagramScrape.postMessage(obj); }
            catch (_) { /* nothing to do */ }
          }

          // 1. Login wall check.
          if (location.pathname.startsWith('/accounts/login')
              || location.pathname.startsWith('/accounts/onetap')) {
            return post({error: 'login_required'});
          }

          // 2. Poll for the embedded JSON. Instagram hydrates SSR JSON
          //    early on the page; usually present within a few hundred ms
          //    but we tolerate slow connections.
          function deepFind(o, predicate, depth) {
            if (!o || typeof o !== 'object' || depth > 60) return null;
            if (predicate(o)) return o;
            // Arrays + plain objects both iterate via Object.values.
            try {
              for (const v of Object.values(o)) {
                const r = deepFind(v, predicate, depth + 1);
                if (r) return r;
              }
            } catch (_) {}
            return null;
          }

          function findPayloadInScripts() {
            const scripts = document.querySelectorAll('script[type="application/json"]');
            for (const sc of scripts) {
              const txt = sc.textContent || '';
              // Pre-filter: cheap substring check before JSON.parse.
              if (!txt.includes('xdt_api__v1__media__shortcode__web_info')
                  && !txt.includes('xdt_shortcode_media')
                  && !txt.includes('video_versions')) continue;
              let obj = null;
              try { obj = JSON.parse(txt); } catch (_) { continue; }
              // REST shape: deep-search for the web_info key.
              const rest = deepFind(obj, o =>
                'xdt_api__v1__media__shortcode__web_info' in o, 0);
              if (rest) {
                const items = rest.xdt_api__v1__media__shortcode__web_info?.items;
                if (Array.isArray(items) && items.length) {
                  return { shape: 'rest', item: items[0] };
                }
              }
              // GraphQL fallback.
              const gql = deepFind(obj, o => 'xdt_shortcode_media' in o, 0);
              if (gql && gql.xdt_shortcode_media) {
                return { shape: 'gql', item: gql.xdt_shortcode_media };
              }
              // Direct video_versions fallback (some pages dump the item
              // at top level under different keys).
              const videoBearing = deepFind(obj, o =>
                Array.isArray(o.video_versions) && o.video_versions.length, 0);
              if (videoBearing) {
                return { shape: 'rest', item: videoBearing };
              }
            }
            return null;
          }

          let found = null;
          const start = Date.now();
          while (Date.now() - start < 12000) {
            found = findPayloadInScripts();
            if (found) break;
            await new Promise(r => setTimeout(r, 200));
          }
          if (!found) {
            // Detailed diagnostic — surface how many script tags we saw so
            // we can tell "no payload" from "page didn't hydrate".
            const total = document.querySelectorAll('script[type="application/json"]').length;
            const titleEl = document.querySelector('title');

            // Heuristic: session expired / not authenticated. Instagram
            // sometimes serves a "log in to view" stub *without* redirecting
            // to /accounts/login. Look for any visible "Log in" button or
            // a stale-session-style heading.
            const bodyText = (document.body && document.body.innerText) || '';
            const looksLikeAuthWall =
                /\b(log in|sign up|please sign in|log into instagram)\b/i.test(bodyText)
                || !!document.querySelector('a[href^="/accounts/login"], button[type="submit"][name="username"]');
            if (looksLikeAuthWall) {
              return post({error: 'login_required'});
            }

            return post({
              error: 'no_json_payload',
              detail: 'scripts=' + total + ' title=' + (titleEl?.textContent || '?') +
                      ' path=' + location.pathname
            });
          }

          // 3. Pull fields from whichever shape we got.
          const item = found.item;
          let videoSrc = null;
          let w = 0, h = 0, duration = 0;
          let caption = '';
          let author = '';
          let authorDisplayName = '';
          let postedAtSec = 0;
          let likes = null, comments = null, views = null;
          let musicTitle = null, musicAuthor = null;
          let mediaPK = null;
          let hashtagArr = [];

          if (found.shape === 'rest') {
            // REST shape (current default): video_versions[] sorted highest-bitrate-first.
            const vv = Array.isArray(item.video_versions) ? item.video_versions : [];
            if (vv.length) {
              const best = vv.find(v => v.url && v.url.startsWith('http')) || vv[0];
              videoSrc = best.url;
              w = best.width || 0;
              h = best.height || 0;
            }
            // Duration field name varies — try every variant we've seen.
            duration = item.video_duration
                    || (item.video_dash_manifest_duration_ms ? item.video_dash_manifest_duration_ms / 1000 : 0)
                    || item.media_duration
                    || (Array.isArray(item.video_versions) && item.video_versions[0]?.duration) || 0;
            caption = item.caption?.text || '';
            author = item.user?.username ? '@' + item.user.username : '';
            authorDisplayName = item.user?.full_name || '';
            postedAtSec = item.taken_at || 0;
            likes    = (typeof item.like_count === 'number') ? item.like_count : null;
            comments = (typeof item.comment_count === 'number') ? item.comment_count : null;
            views    = (typeof item.play_count === 'number') ? item.play_count :
                       (typeof item.view_count === 'number') ? item.view_count : null;
            const mi = item.clips_metadata?.music_info?.music_asset_info;
            if (mi) {
              musicTitle = mi.title || null;
              musicAuthor = mi.display_artist || null;
            } else if (item.clips_metadata?.original_sound_info) {
              musicTitle = 'Original audio';
              musicAuthor = item.clips_metadata.original_sound_info.ig_artist?.username || null;
            }
            mediaPK = item.pk || item.id?.split('_')?.[0] || null;
          } else {
            // GraphQL shape (legacy fallback).
            videoSrc = item.video_url || null;
            w = item.dimensions?.width || 0;
            h = item.dimensions?.height || 0;
            duration = item.video_duration || 0;
            caption = item.edge_media_to_caption?.edges?.[0]?.node?.text || '';
            author = item.owner?.username ? '@' + item.owner.username : '';
            authorDisplayName = item.owner?.full_name || '';
            postedAtSec = item.taken_at_timestamp || 0;
            likes    = item.edge_media_preview_like?.count
                    ?? item.edge_liked_by?.count ?? null;
            comments = item.edge_media_to_parent_comment?.count
                    ?? item.edge_media_to_comment?.count ?? null;
            views    = item.video_view_count ?? null;
            musicTitle = item.clips_music_attribution_info?.song_name || null;
            musicAuthor = item.clips_music_attribution_info?.artist_name || null;
            mediaPK = item.id || null;
          }

          // 4. Hashtags: parse from caption text. Instagram doesn't always
          //    expose them as separate fields.
          function parseTags(s) {
            const out = [];
            const re = /#([A-Za-z0-9_À-ɏḀ-ỿ]+)/g;
            let m;
            while ((m = re.exec(s || '')) !== null) out.push(m[1].toLowerCase());
            return Array.from(new Set(out)).sort();
          }
          hashtagArr = parseTags(caption);

          if (!videoSrc) {
            return post({
              error: 'no_video',
              detail: 'shape=' + found.shape + ' item_keys=' + Object.keys(item).slice(0, 10).join(',')
            });
          }

          post({
            videoSrc: videoSrc,
            width: w, height: h,
            duration: duration,
            caption: caption,
            author: author,
            authorDisplayName: authorDisplayName,
            postedAt: postedAtSec ? new Date(postedAtSec * 1000).toISOString() : '',
            likes: likes, comments: comments, views: views,
            musicTitle: musicTitle, musicAuthor: musicAuthor,
            hashtags: hashtagArr,
            mediaPK: mediaPK ? String(mediaPK) : null
          });
          })().catch(function(e) {
            try {
              window.webkit.messageHandlers.instagramScrape.postMessage(
                { error: 'js_threw', detail: String(e && e.stack || e) }
              );
            } catch (_) {}
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
            let detail = (dict["detail"] as? String) ?? ""
            DebugLog.log("instagram: scrape error=\(err) detail=\(detail.prefix(500))")
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
        // Scheme-validate the page-extracted media URL before passing it to
        // any HTTP client. A compromised page could otherwise hand us
        // `javascript:` or `file://` here.
        guard let videoSrcStr = dict["videoSrc"] as? String,
              let videoURL = URL(string: videoSrcStr),
              videoURL.scheme?.lowercased() == "https" else {
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
