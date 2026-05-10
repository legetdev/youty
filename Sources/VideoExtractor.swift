import WebKit
import Foundation
import AppKit

// Captures genuine 720p video frames from YouTube using canvas.drawImage().
//
// Performance design:
//   ALL timing (sleeps, polls, timeouts) lives in Swift — Task.sleep is never
//   subject to WebKit background-tab timer throttling. JS is only called for
//   instantaneous operations: seek, readyState check, canvas draw.
//
//   WKWebView is moved on-screen (alpha ≈ 0) during capture so WebKit gives it
//   full network and render priority — prevents SABR buffering throttling.

@MainActor
final class VideoExtractor: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {

    private var webView: WKWebView!
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var seekContinuation: CheckedContinuation<Void, Never>?
    private var captureContinuation: CheckedContinuation<NSImage?, Never>?

    override init() {
        super.init()
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []

        let controller = WKUserContentController()
        controller.add(self, name: "youtyLoad")
        controller.add(self, name: "youtySeek")
        controller.add(self, name: "youtyFrame")
        config.userContentController = controller

        webView = WKWebView(frame: CGRect(x: -2000, y: 0, width: 1280, height: 800),
                            configuration: config)
        webView.navigationDelegate = self
    }

    func attach(to window: NSWindow) {
        guard webView.superview == nil, let cv = window.contentView else { return }
        cv.addSubview(webView)
    }

    // MARK: - Public API

    func loadVideo(videoID: String) async throws {
        let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)")!
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.loadContinuation = cont
            webView.load(URLRequest(url: url))
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
                guard let self, self.loadContinuation != nil else { return }
                self.loadContinuation?.resume(throwing: VideoError.streamTimeout)
                self.loadContinuation = nil
            }
        }
    }

    func getVideoDuration() async -> TimeInterval {
        return await withCheckedContinuation { cont in
            webView.evaluateJavaScript("document.querySelector('video')?.duration || 0") { r, _ in
                cont.resume(returning: (r as? Double) ?? 0)
            }
        }
    }

    func captureFrames(timestamps: [TimeInterval],
                       progress: @escaping (Double) -> Void) async throws -> [(TimeInterval, NSImage)] {
        guard !timestamps.isEmpty else { return [] }

        // Bring webview on-screen so WebKit gives it full network + render priority
        bringOnScreen()
        defer { sendOffScreen() }

        // Force 720p once and wait for it to take effect (Swift sleep — not throttled)
        await forceQuality()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Inject persistent seeked listener (fires once per seek)
        await injectSeekListener()

        var frames: [(TimeInterval, NSImage)] = []
        let total = timestamps.count

        for (i, ts) in timestamps.enumerated() {
            // 1. Seek + trigger buffering
            await seekAndPlay(to: ts)

            // 2. Wait for seeked event (Swift timeout — not throttled)
            await awaitSeeked(timeout: 5)

            // 3. Poll readyState in Swift until frame data is available
            await waitForFrameData(timeout: 10)

            // 4. Small render buffer
            try await Task.sleep(nanoseconds: 80_000_000)

            // 5. Canvas capture — drops blank frames (caller absorbs the gap)
            if let image = await captureCanvas() {
                frames.append((ts, image))
            }

            progress(Double(i + 1) / Double(total))
        }

        return frames
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard loadContinuation != nil else { return }
        let js = """
        (function(){
          (async function(){
            function post(o){window.webkit.messageHandlers.youtyLoad.postMessage(o);}
            try{
              const p=document.getElementById('movie_player');
              if(p&&p.playVideo)p.playVideo();
              else{const v=document.querySelector('video');if(v)v.play().catch(()=>{});}
            }catch(e){}
            let v=null;
            for(let i=0;i<60;i++){
              v=document.querySelector('video');
              if(v&&v.duration>0)break;
              await new Promise(r=>setTimeout(r,200));
            }
            post(v&&v.duration>0?{ready:true}:{error:'no_video'});
          })();
        })();
        """
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                self.loadContinuation?.resume(throwing: error)
                self.loadContinuation = nil
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: VideoError.networkError); loadContinuation = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: VideoError.networkError); loadContinuation = nil
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any] else { return }
        switch message.name {
        case "youtyLoad":
            if dict["ready"] != nil {
                loadContinuation?.resume()
            } else {
                loadContinuation?.resume(throwing: VideoError.streamTimeout)
            }
            loadContinuation = nil

        case "youtySeek":
            seekContinuation?.resume()
            seekContinuation = nil

        case "youtyFrame":
            if let base64 = dict["frame"] as? String,
               let data = Data(base64Encoded: base64),
               let image = NSImage(data: data) {
                captureContinuation?.resume(returning: image)
            } else {
                captureContinuation?.resume(returning: nil)
            }
            captureContinuation = nil

        default: break
        }
    }

    // MARK: - Private helpers

    private func bringOnScreen() {
        // Make visible to WebKit so it grants full network + render priority.
        // alphaValue = 0.001 is invisible to the user but active to WebKit.
        webView.frame = CGRect(x: 0, y: 0, width: 1280, height: 800)
        webView.alphaValue = 0.001
    }

    private func sendOffScreen() {
        webView.frame = CGRect(x: -2000, y: 0, width: 1280, height: 800)
        webView.alphaValue = 1.0
    }

    private func forceQuality() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            webView.evaluateJavaScript("""
            (function(){
              try{
                const p=document.getElementById('movie_player');
                if(p&&p.setPlaybackQualityRange)p.setPlaybackQualityRange('hd720','hd720');
                else if(p&&p.setPlaybackQuality)p.setPlaybackQuality('hd720');
              }catch(e){}
            })()
            """) { _, _ in cont.resume() }
        }
    }

    private func injectSeekListener() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            webView.evaluateJavaScript("""
            (function(){
              if(window._youtySeekBound)return;
              window._youtySeekBound=true;
              const v=document.querySelector('video');
              if(v)v.addEventListener('seeked',function(){
                window.webkit.messageHandlers.youtySeek.postMessage({});
              });
            })()
            """) { _, _ in cont.resume() }
        }
    }

    private func seekAndPlay(to ts: TimeInterval) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            webView.evaluateJavaScript("""
            (function(){
              const v=document.querySelector('video');
              if(v){v.currentTime=\(ts);v.play().catch(function(){});}
            })()
            """) { _, _ in cont.resume() }
        }
    }

    // Awaits the seeked message handler. Swift-side timeout so no JS setTimeout needed.
    private func awaitSeeked(timeout: TimeInterval) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.seekContinuation = cont
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.seekContinuation != nil else { return }
                self.seekContinuation?.resume()
                self.seekContinuation = nil
            }
        }
    }

    // Polls video.readyState via evaluateJavaScript every 250ms (Swift sleep — not throttled).
    // readyState >= 2 means the current frame's pixel data is available.
    private func waitForFrameData(timeout: TimeInterval = 20) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let readyState = await withCheckedContinuation { (cont: CheckedContinuation<Int, Never>) in
                webView.evaluateJavaScript("document.querySelector('video')?.readyState??0") { r, _ in
                    cont.resume(returning: (r as? Int) ?? 0)
                }
            }
            if readyState >= 2 { return }
            try? await Task.sleep(nanoseconds: 250_000_000) // 250ms — Swift, not throttled
        }
    }

    // Canvas draw + 5-pixel blank detection. If all sample points read RGB < 8,
    // the frame is treated as blank (unbuffered position) and dropped — the
    // bundle is better with one missing JPEG than a black one.
    private func captureCanvas() async -> NSImage? {
        return await withCheckedContinuation { cont in
            self.captureContinuation = cont
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.captureContinuation != nil else { return }
                self.captureContinuation?.resume(returning: nil)
                self.captureContinuation = nil
            }
            webView.evaluateJavaScript("""
            (function(){
              const video=document.querySelector('video');
              if(!video){window.webkit.messageHandlers.youtyFrame.postMessage({});return;}
              const c=window._youtyCanvas||(function(){
                const cv=document.createElement('canvas');
                cv.width=1280;cv.height=720;
                window._youtyCanvas=cv;return cv;
              })();
              const ctx=c.getContext('2d');
              ctx.clearRect(0,0,1280,720);
              const vw=video.videoWidth||1280,vh=video.videoHeight||720;
              const sc=Math.min(1280/vw,720/vh);
              const dw=Math.round(vw*sc),dh=Math.round(vh*sc);
              const dx=Math.round((1280-dw)/2),dy=Math.round((720-dh)/2);
              ctx.drawImage(video,dx,dy,dw,dh);
              const pts=[[320,180],[640,360],[960,540],[320,540],[960,180]];
              const blank=pts.every(([x,y])=>{
                const d=ctx.getImageData(x,y,1,1).data;
                return d[0]<8&&d[1]<8&&d[2]<8;
              });
              if(blank){window.webkit.messageHandlers.youtyFrame.postMessage({});return;}
              const b64=c.toDataURL('image/jpeg',0.85).split(',')[1];
              window.webkit.messageHandlers.youtyFrame.postMessage({frame:b64});
            })()
            """) { _, error in
                if error != nil {
                    self.captureContinuation?.resume(returning: nil)
                    self.captureContinuation = nil
                }
            }
        }
    }
}

enum VideoError: LocalizedError {
    case streamTimeout, networkError
    var errorDescription: String? {
        switch self {
        case .streamTimeout: return "Video did not load in time."
        case .networkError:  return "Network error loading video."
        }
    }
}
