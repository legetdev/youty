import Foundation

// Bridges FFmpeg's AVIOContext to URLSession so libavformat reads remote
// streams via HTTP Range requests (fast on googlevideo) instead of
// libavformat's built-in HTTP (throttled by googlevideo to ~250 KB/s
// on single-stream GETs).
//
// Strategy: parallel-prefetched chunk cache.
//   - When FFmpeg asks for byte X, we serve from a per-chunk LRU cache.
//   - On a cache miss we issue the requested chunk *plus* the next
//     `prefetchAhead` chunks as parallel Range requests, so the cumulative
//     HTTP RTT cost across a sparse-seek scan is bounded by
//     ceil(N / prefetchAhead) round-trips instead of N.
//   - Chunks are 1 MB — roughly one 1080p H.264 keyframe — so each fetch
//     pulls useful bytes with minimal waste.
//   - LRU eviction keeps memory bounded even on very long videos.

final class FFmpegURLSessionIO {

    // Range chunk size. ~1 keyframe at 1080p H.264.
    private let chunkSize: Int = 1_000_000

    // Number of chunks to issue in parallel on a cache miss (current + N-1
    // prefetch). 2 — empirically the sweet spot:
    //   • Higher (4+) regresses on high-bitrate 1080p because all parallel
    //     requests share one TCP connection's bandwidth, so total wall time
    //     is roughly unchanged but extra chunks add overhead.
    //   • Lower (1, i.e. no prefetch) loses on sparse-seek long videos
    //     because cumulative RTTs aren't masked.
    //   • 2 overlaps the next chunk's RTT with the current chunk's decode
    //     without saturating the link with redundant lookahead.
    private let prefetchAhead: Int = 2

    // LRU cap. At 1 MB chunks that's up to 256 MB resident, but typical
    // sessions stay well under this — only as many chunks as the demuxer
    // revisits within an extraction.
    private let cacheMaxChunks: Int = 256

    private let url: URL
    private let userAgent: String
    private var totalLength: Int64 = 0
    private var cursor: Int64 = 0

    // LRU chunk cache. Key = chunk-aligned start offset.
    private var chunks: [Int64: Data] = [:]
    private var accessOrder: [Int64] = []

    // Outstanding fetches keyed by their chunk-aligned start offset.
    private var inflight: [Int64: InflightChunk] = [:]
    // Reverse lookup: dataTask.taskIdentifier → chunk offset.
    private var taskToOffset: [Int: Int64] = [:]

    // Single condition covering both LRU and in-flight state. Each delegate
    // callback updates state under .lock() then .broadcast()s; readers wait.
    private let condition = NSCondition()

    private let session: URLSession
    private let delegate: ChunkSessionDelegate

    init(url: URL, userAgent: String) {
        self.url = url
        self.userAgent = userAgent
        self.delegate = ChunkSessionDelegate()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 120
        // Allow several concurrent requests per host; we self-limit via
        // prefetchAhead so this just removes a hidden artificial cap.
        cfg.httpMaximumConnectionsPerHost = 8
        self.session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        delegate.owner = self
    }

    deinit {
        cancelAllInflight()
        session.invalidateAndCancel()
    }

    // MARK: - FFmpeg-facing entry points

    /// FFmpeg asks for `size` bytes at the current cursor position.
    /// Returns the number actually read (≤ size), 0 at EOF, negative on error.
    func read(buffer: UnsafeMutablePointer<UInt8>, size: Int) -> Int {
        if totalLength == 0 {
            if let _ = ensureChunkContaining(offset: 0) { return -1 }
        }
        if cursor >= totalLength { return 0 }

        let chunkKey = alignedStart(for: cursor)
        if let _ = ensureChunkContaining(offset: cursor) { return -1 }
        guard let chunk = chunks[chunkKey] else { return -1 }
        touch(chunkKey)

        let inBuf = Int(cursor - chunkKey)
        let available = chunk.count - inBuf
        let toCopy = min(size, available, Int(totalLength - cursor))
        if toCopy <= 0 { return 0 }
        chunk.withUnsafeBytes { rawPtr in
            let src = rawPtr.baseAddress!.advanced(by: inBuf).assumingMemoryBound(to: UInt8.self)
            buffer.initialize(from: src, count: toCopy)
        }
        cursor += Int64(toCopy)
        return toCopy
    }

    /// FFmpeg requests a seek. AVSEEK_SIZE returns total length.
    func seek(offset: Int64, whence: Int32) -> Int64 {
        let AVSEEK_SIZE: Int32 = 0x10000
        let SEEK_SET: Int32 = 0
        let SEEK_CUR: Int32 = 1
        let SEEK_END: Int32 = 2

        if (whence & AVSEEK_SIZE) != 0 {
            if totalLength == 0 {
                _ = ensureChunkContaining(offset: 0)
            }
            return totalLength
        }
        let pure = whence & ~AVSEEK_SIZE
        let newPos: Int64
        switch pure {
        case SEEK_SET: newPos = offset
        case SEEK_CUR: newPos = cursor + offset
        case SEEK_END: newPos = totalLength + offset
        default:       return -1
        }
        if newPos < 0 { return -1 }
        cursor = newPos
        return newPos
    }

    // MARK: - Chunk fetching (parallel-prefetch)

    /// Block until the chunk containing `offset` is cached. May trigger up
    /// to `prefetchAhead` parallel Range requests on a cache miss.
    private func ensureChunkContaining(offset: Int64) -> Error? {
        let target = alignedStart(for: offset)

        condition.lock()
        defer { condition.unlock() }

        while chunks[target] == nil {
            if inflight[target] == nil {
                // Cache miss with no fetch in flight — kick off this chunk
                // plus a prefetch window of subsequent chunks.
                launchFetchesLocked(startingAt: target, count: prefetchAhead)
            }
            // Wait for any delegate completion; loop and re-check.
            condition.wait()
            if let err = inflight[target]?.error {
                inflight.removeValue(forKey: target)
                return err
            }
        }
        return nil
    }

    private func launchFetchesLocked(startingAt start: Int64, count: Int) {
        for i in 0..<count {
            let key = start + Int64(i * chunkSize)
            // Don't fetch past EOF once we know totalLength.
            if totalLength > 0 && key >= totalLength { break }
            if chunks[key] != nil || inflight[key] != nil { continue }
            let upperBound = (totalLength > 0)
                ? min(key + Int64(chunkSize) - 1, totalLength - 1)
                : (key + Int64(chunkSize) - 1)

            var req = URLRequest(url: url)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("bytes=\(key)-\(upperBound)", forHTTPHeaderField: "Range")
            let task = session.dataTask(with: req)
            let inf = InflightChunk(offset: key)
            inf.dataTask = task
            inflight[key] = inf
            taskToOffset[task.taskIdentifier] = key
            task.resume()
        }
    }

    private func cancelAllInflight() {
        condition.lock()
        for (_, inf) in inflight {
            inf.dataTask?.cancel()
        }
        inflight.removeAll()
        taskToOffset.removeAll()
        condition.broadcast()
        condition.unlock()
    }

    // MARK: - LRU helpers

    private func alignedStart(for offset: Int64) -> Int64 {
        (offset / Int64(chunkSize)) * Int64(chunkSize)
    }

    private func touch(_ key: Int64) {
        if let idx = accessOrder.firstIndex(of: key) { accessOrder.remove(at: idx) }
        accessOrder.append(key)
    }

    private func insertCachedLocked(_ data: Data, at key: Int64) {
        chunks[key] = data
        touch(key)
        while accessOrder.count > cacheMaxChunks {
            let evict = accessOrder.removeFirst()
            chunks.removeValue(forKey: evict)
        }
    }

    // MARK: - URLSession delegate hand-offs (URLSession's queue)

    fileprivate func sessionReceived(response: URLResponse, for dataTask: URLSessionDataTask) {
        condition.lock()
        defer { condition.unlock() }
        if let http = response as? HTTPURLResponse {
            if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
               let slash = contentRange.firstIndex(of: "/"),
               let total = Int64(contentRange[contentRange.index(after: slash)...]) {
                totalLength = total
            } else if let len = http.value(forHTTPHeaderField: "Content-Length"),
                      let bytes = Int64(len), totalLength == 0 {
                totalLength = bytes
            }
        }
    }

    fileprivate func sessionReceived(data: Data, for dataTask: URLSessionDataTask) {
        condition.lock()
        defer { condition.unlock() }
        guard let offset = taskToOffset[dataTask.taskIdentifier],
              let inf = inflight[offset] else { return }
        inf.buffer.append(data)
    }

    fileprivate func sessionCompleted(task: URLSessionTask, error: Error?) {
        condition.lock()
        defer { condition.unlock() }
        guard let offset = taskToOffset[task.taskIdentifier] else { return }
        taskToOffset.removeValue(forKey: task.taskIdentifier)
        guard let inf = inflight[offset] else { return }
        if let error {
            inf.error = error
            // Keep inflight entry so the waiter can see the error and clear it.
        } else if !inf.buffer.isEmpty {
            insertCachedLocked(inf.buffer, at: offset)
            inflight.removeValue(forKey: offset)
        } else {
            inflight.removeValue(forKey: offset)
        }
        condition.broadcast()
    }
}

// One outstanding Range request keyed by its chunk-aligned offset.
private final class InflightChunk {
    let offset: Int64
    weak var dataTask: URLSessionDataTask?
    var buffer: Data = Data()
    var error: Error? = nil
    init(offset: Int64) { self.offset = offset }
}

// URLSession delegate that funnels events back into the owner under its lock.
private final class ChunkSessionDelegate: NSObject, URLSessionDataDelegate {
    weak var owner: FFmpegURLSessionIO?

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        owner?.sessionReceived(response: response, for: dataTask)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        owner?.sessionReceived(data: data, for: dataTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        owner?.sessionCompleted(task: task, error: error)
    }
}
