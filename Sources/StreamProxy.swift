import WebKit
import Foundation

// WKURLSchemeHandler that streams a remote googlevideo URL to WebKit's <video>
// element. Bytes flow googlevideo → URLSession (streaming) → handler → WebKit
// media engine → rendered frame. No file ever written to disk.
//
// Streaming (not buffering) is critical: a buffered fetch of a 50-100 MB Range
// would stall the media engine until the entire chunk arrives. With streaming,
// WebKit gets bytes as they arrive and can start decoding within the first
// hundred milliseconds.
//
// Same-origin "youty-stream://video" URLs also avoid the canvas-tainting
// restriction that blocks frame snapshots on cross-origin remote videos.

final class StreamProxyHandler: NSObject, WKURLSchemeHandler {

    private let upstreamURL: URL
    private let userAgent: String
    private let session: URLSession
    private let delegate: StreamingDelegate

    init(upstreamURL: URL, userAgent: String) {
        self.upstreamURL = upstreamURL
        self.userAgent = userAgent
        self.delegate = StreamingDelegate()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 120
        cfg.httpMaximumConnectionsPerHost = 8
        self.session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        var req = URLRequest(url: upstreamURL)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let range = urlSchemeTask.request.value(forHTTPHeaderField: "Range") {
            req.setValue(range, forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: req)
        delegate.register(task: task, schemeTask: urlSchemeTask)
        task.resume()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        delegate.cancel(schemeTask: urlSchemeTask)
    }
}

// Streams URLSession data events to corresponding WKURLSchemeTasks.
private final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    private let lock = NSLock()
    private var dataTaskToSchemeTask: [Int: WKURLSchemeTask] = [:]
    private var dataTaskById: [Int: URLSessionDataTask] = [:]
    private var cancelledIds: Set<Int> = []

    func register(task: URLSessionDataTask, schemeTask: WKURLSchemeTask) {
        lock.lock(); defer { lock.unlock() }
        dataTaskToSchemeTask[task.taskIdentifier] = schemeTask
        dataTaskById[task.taskIdentifier] = task
    }

    func cancel(schemeTask: WKURLSchemeTask) {
        lock.lock(); defer { lock.unlock() }
        for (id, st) in dataTaskToSchemeTask where st === schemeTask {
            dataTaskById[id]?.cancel()
            cancelledIds.insert(id)
            dataTaskToSchemeTask.removeValue(forKey: id)
            dataTaskById.removeValue(forKey: id)
        }
    }

    private func schemeTask(for id: Int) -> WKURLSchemeTask? {
        lock.lock(); defer { lock.unlock() }
        if cancelledIds.contains(id) { return nil }
        return dataTaskToSchemeTask[id]
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let st = schemeTask(for: dataTask.taskIdentifier) {
            st.didReceive(response)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let st = schemeTask(for: dataTask.taskIdentifier) {
            st.didReceive(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        lock.lock()
        let st = dataTaskToSchemeTask[id]
        dataTaskToSchemeTask.removeValue(forKey: id)
        dataTaskById.removeValue(forKey: id)
        let wasCancelled = cancelledIds.contains(id)
        cancelledIds.remove(id)
        lock.unlock()
        guard !wasCancelled, let st else { return }
        if let error {
            st.didFailWithError(error)
        } else {
            st.didFinish()
        }
    }
}
