import Foundation

// Sequential HTTP Range downloader for googlevideo signed URLs.
//
// Why sequential, not parallel:
//   googlevideo refuses parallel Range requests on a single signed URL.
//   ANDROID_VR URLs are designed for single-consumer streaming. We verified
//   this empirically — 8 concurrent Range requests against the same URL all
//   completed TLS handshake but never received body bytes.
//
// Why 8 MB chunks:
//   Large enough to amortise TLS round-trip overhead, small enough to give
//   responsive progress updates and let us fail fast on a single chunk.

enum DownloadError: LocalizedError {
    case httpError(Int)
    case firstChunkTimeout         // fast-path failure — likely signature broken
    case chunkTimeout(offsetMB: Int)
    case zeroBytes
    case cancelled

    var errorDescription: String? {
        switch self {
        case .httpError(let c):       return "HTTP \(c) from googlevideo"
        case .firstChunkTimeout:      return "Stream URL unreachable (first chunk timeout)"
        case .chunkTimeout(let mb):   return "Download stalled at \(mb) MB"
        case .zeroBytes:              return "googlevideo returned zero bytes"
        case .cancelled:              return "Cancelled"
        }
    }
}

enum Downloader {

    static let chunkBytes = 8_000_000
    static let firstChunkTimeout: TimeInterval = 10    // fast fail on broken signature
    static let chunkTimeout: TimeInterval = 30         // generous for slow links

    // Downloads the full file to `dest`. Existing file is overwritten.
    // Progress callback receives 0..1.
    static func download(stream: VideoStream,
                         to dest: URL,
                         progress: @Sendable @escaping (Double) -> Void) async throws {

        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
        fm.createFile(atPath: dest.path, contents: nil)

        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }

        // contentLength may be 0 for progressive streams. We then download in
        // chunks until the server returns a short chunk (signalling EOF).
        let hasKnownTotal = stream.contentLength > 0
        let total = stream.contentLength
        var offset = 0
        var chunkIndex = 0

        let session: URLSession = {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = chunkTimeout
            config.timeoutIntervalForResource = chunkTimeout
            config.httpMaximumConnectionsPerHost = 1
            return URLSession(configuration: config)
        }()

        let dlStart = Date()

        while hasKnownTotal ? (offset < total) : true {
            try Task.checkCancellation()

            let end = hasKnownTotal
                ? min(offset + chunkBytes - 1, total - 1)
                : (offset + chunkBytes - 1)
            let req = makeChunkRequest(url: stream.url, offset: offset, end: end)

            let timeoutForThisChunk = chunkIndex == 0 ? firstChunkTimeout : chunkTimeout
            let chunkStart = Date()

            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await withTimeout(seconds: timeoutForThisChunk) {
                    try await session.data(for: req)
                }
            } catch is TimeoutError {
                if chunkIndex == 0 { throw DownloadError.firstChunkTimeout }
                throw DownloadError.chunkTimeout(offsetMB: offset / 1_000_000)
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 416 Range Not Satisfiable on an unknown-length stream = EOF.
            if status == 416, !hasKnownTotal { break }
            guard status == 206 || status == 200 else {
                throw DownloadError.httpError(status)
            }
            if data.isEmpty {
                if !hasKnownTotal { break }
                throw DownloadError.zeroBytes
            }

            try handle.write(contentsOf: data)
            offset += data.count
            chunkIndex += 1
            if hasKnownTotal {
                progress(min(1.0, Double(offset) / Double(total)))
            } else {
                // No total known — fake monotonic progress capped at 0.95.
                progress(min(0.95, Double(offset) / 50_000_000.0))
            }

            if chunkIndex == 1 {
                let ms = Int(Date().timeIntervalSince(chunkStart) * 1000)
                DebugLog.log("fast: first chunk \(data.count / 1_000_000)MB in \(ms)ms — signature OK")
            }

            // Short chunk on unknown-length stream = EOF.
            if !hasKnownTotal && data.count < chunkBytes { break }
        }
        progress(1.0)

        let elapsed = Date().timeIntervalSince(dlStart)
        let bytes = offset
        let mbps = (Double(bytes) * 8.0 / 1_000_000.0) / max(elapsed, 0.001)
        DebugLog.log("fast: download complete \(bytes / 1_000_000)MB in \(Int(elapsed * 1000))ms (\(String(format: "%.1f", mbps)) Mbps)")
    }

    // Pulled out so the result is an immutable `let` — withTimeout's @Sendable
    // closure refuses to capture a mutable URLRequest.
    private static func makeChunkRequest(url: URL, offset: Int, end: Int) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        req.setValue(StreamFetcher.androidVRUA, forHTTPHeaderField: "User-Agent")
        return req
    }
}
