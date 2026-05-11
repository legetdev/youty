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
    private var attachedWindow: NSWindow?

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
        attachedWindow = window
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

    // Loads a remote video URL directly via a minimal HTML page in WKWebView.
    // No local download required — WebKit's <video> element issues HTTP Range
    // requests internally as we seek, fetching only the bytes needed for
    // each requested frame.
    // Loads a remote video URL directly via a hidden <video> element. Used
    // by the parallel-canvas fallback when FFmpeg can't reach a video (e.g.
    // PoToken-gated content). WebKit's media engine handles seeking via HTTP
    // Range. takeSnapshot is used for capture to avoid canvas-tainting on
    // cross-origin sources.
    func loadRemoteVideo(streamURL: URL, userAgent: String) async throws {
        webView.customUserAgent = userAgent
        let safeURL = streamURL.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
        let html = """
        <!doctype html><html><body style="margin:0;background:#000">
        <video id="v" autoplay muted playsinline preload="auto"
               width="1280" height="720"
               src="\(safeURL)"></video>
        </body></html>
        """
        // Write HTML to a sandbox-allowed temp file and loadFileURL it.
        // file:// origin gives the <video> element broader cross-origin
        // privileges than a data: URL.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("youty-remote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let htmlURL = dir.appendingPathComponent("player.html")
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.loadContinuation = cont
            webView.loadFileURL(htmlURL, allowingReadAccessTo: dir)
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self, self.loadContinuation != nil else { return }
                self.loadContinuation?.resume(throwing: VideoError.streamTimeout)
                self.loadContinuation = nil
            }
        }
        try? FileManager.default.removeItem(at: dir)
    }

    // Loads a local MP4 file via a minimal HTML page in WKWebView. WebKit's
    // decoder handles YouTube's DASH-fragmented streams that AVFoundation
    // mishandles, and local file access makes each seek near-instant.
    func loadLocalVideo(localURL: URL) async throws {
        let dir = localURL.deletingLastPathComponent()
        let htmlURL = dir.appendingPathComponent("player.html")
        let html = """
        <!doctype html><html><body style="margin:0;background:#000">
        <video id="v" autoplay muted playsinline crossorigin="anonymous"
               width="1280" height="720"
               src="\(localURL.lastPathComponent)"></video>
        </body></html>
        """
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.loadContinuation = cont
            webView.loadFileURL(htmlURL, allowingReadAccessTo: dir)
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
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
        try await captureFrames(timestamps: timestamps,
                                isLocalFile: false,
                                progress: progress)
    }

    // isLocalFile=true tunes timings and disables blank-detection.
    func captureFrames(timestamps: [TimeInterval],
                       isLocalFile: Bool,
                       progress: @escaping (Double) -> Void) async throws -> [(TimeInterval, NSImage)] {
        try await captureFrames(timestamps: timestamps,
                                isLocalFile: isLocalFile,
                                slotIndex: 0,
                                slotCount: 1,
                                progress: progress)
    }

    // slotIndex/slotCount let multiple VideoExtractors run side-by-side
    // without their WebKit render surfaces overlapping. The WebView is moved
    // to a distinct 1280×800 slot of an off-screen grid before capture.
    func captureFrames(timestamps: [TimeInterval],
                       isLocalFile: Bool,
                       slotIndex: Int,
                       slotCount: Int,
                       progress: @escaping (Double) -> Void) async throws -> [(TimeInterval, NSImage)] {
        guard !timestamps.isEmpty else { return [] }

        bringOnScreen(slotIndex: slotIndex, slotCount: slotCount)
        defer { sendOffScreen() }

        if !isLocalFile {
            await forceQuality()
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        await injectSeekListener()

        var frames: [(TimeInterval, NSImage)] = []
        let total = timestamps.count

        for (i, ts) in timestamps.enumerated() {
            await seekAndPlay(to: ts)
            await awaitSeeked(timeout: isLocalFile ? 3 : 5)
            await waitForFrameData(timeout: isLocalFile ? 5 : 10,
                                    pollNanos: isLocalFile ? 50_000_000 : 250_000_000)
            try await Task.sleep(nanoseconds: 80_000_000)

            if let image = await captureCanvas(blankDetect: !isLocalFile) {
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
            const v=document.querySelector('video');
            let lastErr='';
            if(v){
              v.addEventListener('error',function(){
                lastErr='media_error code='+(v.error&&v.error.code)+' msg='+(v.error&&v.error.message);
              });
              v.addEventListener('stalled',function(){lastErr='stalled';});
              v.addEventListener('suspend',function(){lastErr='suspend';});
              v.addEventListener('abort',function(){lastErr='abort';});
              try{
                const p=document.getElementById('movie_player');
                if(p&&p.playVideo)p.playVideo();
                else v.play().catch(function(e){lastErr='play_rejected:'+e.message;});
              }catch(e){lastErr='play_throw:'+e.message;}
            }
            let vv=null;
            for(let i=0;i<60;i++){
              vv=document.querySelector('video');
              if(vv&&vv.duration>0)break;
              await new Promise(r=>setTimeout(r,200));
            }
            const ns=vv?vv.networkState:-1;
            const rs=vv?vv.readyState:-1;
            const dur=vv?vv.duration:-1;
            post(vv&&vv.duration>0
                 ?{ready:true,dur:dur,ns:ns,rs:rs}
                 :{error:lastErr||'timeout',ns:ns,rs:rs,dur:dur});
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
                DebugLog.log("VideoExtractor: ready dur=\(dict["dur"] ?? "?") ns=\(dict["ns"] ?? "?") rs=\(dict["rs"] ?? "?")")
                loadContinuation?.resume()
            } else {
                DebugLog.log("VideoExtractor: load FAILED err=\(dict["error"] ?? "?") ns=\(dict["ns"] ?? "?") rs=\(dict["rs"] ?? "?") dur=\(dict["dur"] ?? "?")")
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

    // Single-slot variant kept for backward-compat callers.
    private func bringOnScreen() {
        bringOnScreen(slotIndex: 0, slotCount: 1)
    }

    // slotIndex/slotCount place the WebView in a non-overlapping grid cell so
    // multiple parallel extractors each get their own render surface. The
    // grid extends to the right of the visible window; alphaValue 0.001 keeps
    // it invisible to the user while WebKit treats it as active.
    private func bringOnScreen(slotIndex: Int, slotCount: Int) {
        let cols = max(1, Int(Double(slotCount).squareRoot().rounded(.up)))
        let row = slotIndex / cols
        let col = slotIndex % cols
        webView.frame = CGRect(x: col * 1280, y: row * 800,
                               width: 1280, height: 800)
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

    // Polls video.readyState via evaluateJavaScript. readyState >= 2 means
    // the current frame's pixel data is available. pollNanos is tunable so
    // local-file extraction can use much tighter polling than network-bound
    // YouTube extraction.
    private func waitForFrameData(timeout: TimeInterval = 20,
                                   pollNanos: UInt64 = 250_000_000) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let readyState = await withCheckedContinuation { (cont: CheckedContinuation<Int, Never>) in
                webView.evaluateJavaScript("document.querySelector('video')?.readyState??0") { r, _ in
                    cont.resume(returning: (r as? Int) ?? 0)
                }
            }
            if readyState >= 2 { return }
            try? await Task.sleep(nanoseconds: pollNanos)
        }
    }

    // WebView snapshot capture.
    //
    // Why takeSnapshot and not canvas.toDataURL: when <video src=...> points
    // to a cross-origin URL (which it does whenever we play a remote
    // googlevideo URL), drawing the video to a canvas TAINTS the canvas —
    // any subsequent getImageData / toDataURL throws SecurityError. WebKit's
    // takeSnapshot is an OS-level screenshot of the rendered web content,
    // immune to that restriction.
    //
    // We snapshot the entire WKWebView, cropped to the <video> rect. Since we
    // size the video to 1280×720 in the HTML, the result is a 1280×720 NSImage
    // of the actual rendered frame.
    private func captureCanvas(blankDetect: Bool = true) async -> NSImage? {
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: 1280, height: 720)
        return await withCheckedContinuation { (cont: CheckedContinuation<NSImage?, Never>) in
            webView.takeSnapshot(with: config) { image, error in
                guard let image else {
                    cont.resume(returning: nil)
                    return
                }
                // Optional blank-detect: sample 5 pixels, drop if all near-black.
                if blankDetect, let bitmap = NSBitmapImageRep(data: image.tiffRepresentation ?? Data()) {
                    let pts: [(Int, Int)] = [(320, 180), (640, 360), (960, 540), (320, 540), (960, 180)]
                    let allBlank = pts.allSatisfy { x, y in
                        guard let c = bitmap.colorAt(x: x, y: y) else { return false }
                        return c.redComponent < 0.03 && c.greenComponent < 0.03 && c.blueComponent < 0.03
                    }
                    if allBlank { cont.resume(returning: nil); return }
                }
                cont.resume(returning: image)
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
