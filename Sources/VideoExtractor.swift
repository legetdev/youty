import WebKit
import Foundation

// Captures decoded video/audio stream URLs from a YouTube page.
// WKWebView loads the page, YouTube's own JS decodes stream URLs,
// and our XHR/fetch interceptor captures the results.
//
// SPIKE: test on 10+ real videos before wiring into the vault flow.
// Success = valid googlevideo.com URL at full download speed.

@MainActor
final class VideoExtractor: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {

    struct StreamURLs {
        let video: URL
        let audio: URL?
    }

    private var webView: WKWebView!
    private var continuation: CheckedContinuation<StreamURLs, Error>?
    private var capturedVideo: String?
    private var capturedAudio: String?

    override init() {
        super.init()
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []  // autoplay triggers stream requests

        let controller = WKUserContentController()
        controller.add(self, name: "youtyStream")
        let script = WKUserScript(source: interceptorJS,
                                  injectionTime: .atDocumentStart,
                                  forMainFrameOnly: true)
        controller.addUserScript(script)
        config.userContentController = controller

        webView = WKWebView(frame: CGRect(x: -2000, y: 0, width: 1280, height: 800),
                            configuration: config)
        webView.navigationDelegate = self
    }

    func attach(to window: NSWindow) {
        guard webView.superview == nil, let cv = window.contentView else { return }
        cv.addSubview(webView)
    }

    func extract(videoID: String) async throws -> StreamURLs {
        capturedVideo = nil
        capturedAudio = nil
        let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)")!
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            webView.load(URLRequest(url: url))
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self, self.continuation != nil else { return }
                self.finish(throwing: VideoError.streamTimeout)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard continuation != nil else { return }
        webView.evaluateJavaScript("""
        (function() {
            var p = document.getElementById('movie_player');
            if (p && p.playVideo) { p.playVideo(); return; }
            var v = document.querySelector('video');
            if (v) { v.play().catch(function(){}); }
        })();
        """, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(throwing: VideoError.networkError)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        finish(throwing: VideoError.networkError)
    }

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "youtyStream",
              let body = message.body as? [String: String],
              let urlString = body["url"],
              let kind = body["kind"] else { return }

        if kind == "video" { capturedVideo = capturedVideo ?? urlString }
        if kind == "audio" { capturedAudio = capturedAudio ?? urlString }

        if let v = capturedVideo, continuation != nil {
            guard let videoURL = URL(string: v) else { finish(throwing: VideoError.invalidURL); return }
            finish(returning: StreamURLs(video: videoURL, audio: capturedAudio.flatMap(URL.init)))
        }
    }

    private func finish(returning v: StreamURLs) { continuation?.resume(returning: v); continuation = nil }
    private func finish(throwing e: Error)        { continuation?.resume(throwing: e);  continuation = nil }

    // Injected at documentStart — overrides XHR/fetch before YouTube's player initialises.
    // Captures first video and audio stream URLs that hit googlevideo.com.
    private var interceptorJS: String { """
        (function() {
            function classify(url) {
                if (!url || typeof url !== 'string') return null;
                if (!url.includes('googlevideo.com') || !url.includes('videoplayback')) return null;
                var mime = decodeURIComponent((url.match(/mime=([^&]+)/) || [])[1] || '');
                return mime.startsWith('audio') ? 'audio' : 'video';
            }
            function report(url) {
                var kind = classify(url);
                if (!kind) return;
                window.webkit.messageHandlers.youtyStream.postMessage({url: url, kind: kind});
            }
            var _open = XMLHttpRequest.prototype.open;
            XMLHttpRequest.prototype.open = function(m, url) {
                report(url);
                return _open.apply(this, arguments);
            };
            var _fetch = window.fetch;
            window.fetch = function(resource, init) {
                report(typeof resource === 'string' ? resource
                      : (resource && resource.url ? resource.url : null));
                return _fetch.apply(window, arguments);
            };
        })();
    """ }
}

enum VideoError: LocalizedError {
    case streamTimeout, networkError, invalidURL
    var errorDescription: String? {
        switch self {
        case .streamTimeout: return "Could not capture video stream."
        case .networkError:  return "Network error loading video."
        case .invalidURL:    return "Invalid stream URL."
        }
    }
}
