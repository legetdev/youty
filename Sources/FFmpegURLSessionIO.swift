import Foundation

// Bridges FFmpeg's AVIOContext to URLSession so libavformat reads the
// remote stream via HTTP Range requests (fast on googlevideo) instead of
// libavformat's built-in HTTP (throttled by googlevideo to ~250 KB/s on
// single-stream GETs).
//
// Strategy: chunked prefetch. We issue Range requests in fixed-size blocks
// ahead of FFmpeg's read cursor and stream the bytes into a contiguous
// in-memory buffer. Reads block on the prefetch reaching the requested
// offset. Seeks cancel outstanding prefetches and restart from the new
// position.
//
// In-memory only. No disk writes. Buffer is reaped as soon as the parent
// FFmpegFrameExtractor.extract() call returns.

final class FFmpegURLSessionIO {

    private let url: URL
    private let userAgent: String
    private let chunkSize: Int = 8_000_000          // 8 MB Range chunks
    private let cacheMaxChunks: Int = 32            // LRU cap → up to 256 MB cache (DASH MP4 moov + recent reads)

    // Total content length (filled in by the first Range response).
    private var totalLength: Int64 = 0

    // LRU chunk cache. Key = chunk-aligned start offset; value = chunk data.
    // Insertion order maintained via a separate access-order list.
    private var chunks: [Int64: Data] = [:]
    private var accessOrder: [Int64] = []

    private var cursor: Int64 = 0

    // Active inflight fetch info.
    private let condition = NSCondition()
    private var inflightTask: URLSessionDataTask?
    private var inflightOffset: Int64 = 0
    private var inflightBuffer: Data = Data()
    private var inflightDone: Bool = false
    private var inflightError: Error?
    private let session: URLSession
    private let delegate: FFmpegSessionDelegate

    init(url: URL, userAgent: String) {
        self.url = url
        self.userAgent = userAgent
        self.delegate = FFmpegSessionDelegate()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 120
        cfg.httpMaximumConnectionsPerHost = 4
        self.session = URLSession(configuration: cfg,
                                  delegate: delegate,
                                  delegateQueue: OperationQueue())
        delegate.owner = self
    }

    deinit {
        cancelInflight()
        session.invalidateAndCancel()
    }

    // MARK: - Public callbacks from FFmpeg

    /// FFmpeg asks for `size` bytes at the current cursor position.
    /// Returns the number actually read (≤ size), 0 at EOF, negative on error.
    func read(buffer: UnsafeMutablePointer<UInt8>, size: Int) -> Int {
        if totalLength == 0 {
            if let _ = ensureChunkContaining(offset: 0) { return -1 }
        }
        if cursor >= totalLength { return 0 }

        let chunkKey = alignedStart(for: cursor)
        var chunk: Data
        if let cached = chunks[chunkKey] {
            chunk = cached
            touch(chunkKey)
        } else {
            if let _ = ensureChunkContaining(offset: cursor) { return -1 }
            chunk = chunks[chunkKey] ?? Data()
            if chunk.isEmpty { return -1 }
        }

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

    // MARK: - Cache helpers

    private func alignedStart(for offset: Int64) -> Int64 {
        (offset / Int64(chunkSize)) * Int64(chunkSize)
    }

    private func touch(_ key: Int64) {
        if let idx = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: idx)
        }
        accessOrder.append(key)
    }

    private func insertCached(_ data: Data, at key: Int64) {
        chunks[key] = data
        touch(key)
        while accessOrder.count > cacheMaxChunks {
            let evict = accessOrder.removeFirst()
            chunks.removeValue(forKey: evict)
        }
    }

    /// FFmpeg requests a seek. Returns the new position, or negative on error.
    /// AVSEEK_SIZE (0x10000) means "return total length".
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

    // MARK: - Chunk fetching

    /// Blocks until the chunk containing `position` is fetched and cached.
    /// Returns nil on success, an error on failure.
    private func ensureChunkContaining(offset: Int64) -> Error? {
        let chunkStart = alignedStart(for: offset)
        if chunks[chunkStart] != nil {
            touch(chunkStart)
            return nil
        }
        let chunkEnd = chunkStart + Int64(chunkSize) - 1

        condition.lock()
        cancelInflightLocked()
        inflightOffset = chunkStart
        inflightBuffer = Data()
        inflightDone = false
        inflightError = nil
        condition.unlock()

        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("bytes=\(chunkStart)-\(chunkEnd)", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: req)
        condition.lock()
        inflightTask = task
        condition.unlock()
        task.resume()

        condition.lock()
        while !inflightDone { condition.wait() }
        let err = inflightError
        let data = inflightBuffer
        condition.unlock()
        if err == nil && !data.isEmpty {
            insertCached(data, at: chunkStart)
        }
        return err
    }

    private func cancelInflight() {
        condition.lock()
        cancelInflightLocked()
        condition.unlock()
    }

    private func cancelInflightLocked() {
        inflightTask?.cancel()
        inflightTask = nil
        inflightDone = true
        condition.broadcast()
    }

    // MARK: - URLSession delegate hand-offs (called on URLSession's queue)

    fileprivate func sessionDidReceive(response: URLResponse) {
        condition.lock()
        defer { condition.unlock() }
        if let http = response as? HTTPURLResponse {
            // Content-Range: bytes 0-3999999/26455880 — capture total length.
            if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
               let slash = contentRange.firstIndex(of: "/"),
               let total = Int64(contentRange[contentRange.index(after: slash)...]) {
                totalLength = total
            } else if let len = http.value(forHTTPHeaderField: "Content-Length"),
                      let bytes = Int64(len) {
                // Single-shot response: assume that's the whole file.
                if totalLength == 0 { totalLength = bytes }
            }
        }
    }

    fileprivate func sessionDidReceive(data: Data) {
        condition.lock()
        inflightBuffer.append(data)
        condition.unlock()
    }

    fileprivate func sessionDidComplete(error: Error?) {
        condition.lock()
        inflightDone = true
        inflightError = error
        condition.broadcast()
        condition.unlock()
    }
}

// URLSession delegate that forwards events back to the owning FFmpegURLSessionIO.
private final class FFmpegSessionDelegate: NSObject, URLSessionDataDelegate {

    weak var owner: FFmpegURLSessionIO?

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        owner?.sessionDidReceive(response: response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        owner?.sessionDidReceive(data: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        owner?.sessionDidComplete(error: error)
    }
}
