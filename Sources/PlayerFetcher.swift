import WebKit
import Foundation
import AppKit

// Fallback player API client for restricted videos.
//
// Issues the ANDROID_VR InnerTube call from inside a WKWebView so YouTube session
// cookies (consent, age confirmation, region acknowledgement) are attached. Used
// when StreamFetcher's URLSession-based call returns playabilityStatus != "OK".

@MainActor
final class PlayerFetcher: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {

    private var webView: WKWebView!
    private var resultContinuation: CheckedContinuation<Data, Error>?
    private var isReady = false

    override init() {
        super.init()
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(self, name: "youtyPlayerResult")
        config.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    }

    func attach(to window: NSWindow) {
        guard webView.superview == nil, let cv = window.contentView else { return }
        webView.frame = CGRect(x: -3000, y: 0, width: 100, height: 100)
        cv.addSubview(webView)
        webView.load(URLRequest(url: URL(string: "https://www.youtube.com/")!))
    }

    func fetchFormats(videoID: String) async throws -> [[String: Any]] {
        let data = try await fetchRawPlayerData(videoID: videoID)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StreamFetchError.parseError
        }
        let playability = (json["playabilityStatus"] as? [String: Any])?["status"] as? String ?? ""
        guard playability == "OK" else { throw StreamFetchError.restrictedVideo }
        return (json["streamingData"] as? [String: Any])?["adaptiveFormats"] as? [[String: Any]] ?? []
    }

    private func fetchRawPlayerData(videoID: String) async throws -> Data {
        if !isReady { try await waitForReady() }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            resultContinuation = cont
            let body = "{\"context\":{\"client\":{\"clientName\":\"ANDROID_VR\",\"clientVersion\":\"1.65.10\",\"androidSdkVersion\":32,\"deviceMake\":\"Oculus\",\"deviceModel\":\"Quest 3\",\"osName\":\"Android\",\"osVersion\":\"12L\",\"hl\":\"en\",\"gl\":\"US\"}},\"videoId\":\"\(videoID)\",\"racyCheckOk\":true,\"contentCheckOk\":true}"
            let js = """
            (function() {
                fetch('https://www.youtube.com/youtubei/v1/player?prettyPrint=false', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                        'X-YouTube-Client-Name': '28',
                        'X-YouTube-Client-Version': '1.65.10'
                    },
                    body: '\(body.replacingOccurrences(of: "'", with: "\\'"))'
                })
                .then(r => r.json())
                .then(d => window.webkit.messageHandlers.youtyPlayerResult.postMessage(JSON.stringify(d)))
                .catch(e => window.webkit.messageHandlers.youtyPlayerResult.postMessage(JSON.stringify({error: e.message})));
            })();
            """
            webView.evaluateJavaScript(js) { _, error in
                if let error = error {
                    self.resultContinuation?.resume(throwing: error)
                    self.resultContinuation = nil
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, self.resultContinuation != nil else { return }
                self.resultContinuation?.resume(throwing: StreamFetchError.networkError(0))
                self.resultContinuation = nil
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { isReady = true }

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "youtyPlayerResult",
              let jsonStr = message.body as? String,
              let data = jsonStr.data(using: .utf8) else {
            resultContinuation?.resume(throwing: StreamFetchError.parseError)
            resultContinuation = nil
            return
        }
        resultContinuation?.resume(returning: data)
        resultContinuation = nil
    }

    private func waitForReady() async throws {
        for _ in 0..<30 {
            if isReady { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        isReady = true  // proceed anyway; the fetch will surface the real error if not ready
    }
}
