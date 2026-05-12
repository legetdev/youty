import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox
import CoreVideo

// Phase G: bypass FFmpeg's seek loop entirely.
//
// We open the remote stream just long enough for FFmpeg to parse the moov
// atom (and any moof boxes). After avformat_find_stream_info, FFmpeg has
// populated AVStream.index_entries with one entry per sample, recording
// (PTS, byte offset, size, flags). That table tells us *exactly* where
// every keyframe's bytes are in the file, without decoding anything.
//
// We then:
//   • for each requested timestamp, look up the nearest keyframe entry,
//   • fetch the keyframe's byte range with parallel URLSession requests,
//   • feed each keyframe (AVCC NAL units) into a single VTDecompressionSession,
//   • collect CVPixelBuffers and let the existing parallel converter turn
//     them into NSImages.
//
// This removes the two structural bottlenecks of the F.2 path:
//   (1) FFmpeg's av_seek_frame + flush_buffers tearing down VT per seek
//   (2) chunk-aligned over-fetching (we fetch keyframe-exact byte ranges)

struct SampleTableTarget {
    let timestamp: TimeInterval     // requested timestamp (seconds)
    let pos: Int64                  // byte offset of the keyframe in the file
    let size: Int                   // keyframe size in bytes
    let pts: Int64                  // FFmpeg PTS for the keyframe
}

enum SampleTableError: LocalizedError {
    case noKeyframeIndex
    case formatDescriptionFailed
    case decompressionSessionFailed(OSStatus)
    case decodeFailed(OSStatus, at: TimeInterval)
    case keyframeFetchFailed(at: TimeInterval, underlying: Error?)

    var errorDescription: String? {
        switch self {
        case .noKeyframeIndex: return "No keyframe index in container — not a seekable file."
        case .formatDescriptionFailed: return "Could not build CMVideoFormatDescription from codec extradata."
        case .decompressionSessionFailed(let s): return "VTDecompressionSessionCreate failed (\(s))."
        case .decodeFailed(let s, let t): return "VT decode failed at \(String(format: "%.1f", t))s (\(s))."
        case .keyframeFetchFailed(let t, _): return "HTTP fetch failed for keyframe at \(String(format: "%.1f", t))s."
        }
    }
}

// Stream metadata extracted by the FFmpeg open-without-seek helper.
// Self-contained: no FFmpeg pointers, can outlive the demuxer context.
struct StreamMetadata: Sendable {
    let extradata: Data       // codec extradata (avcC / hvcC payload bytes)
    let codecID: AVCodecID
    let width: Int32
    let height: Int32
    let timeBaseNum: Int32    // stream time_base.num (typically 1)
    let timeBaseDen: Int32    // stream time_base.den (typically 90000 for H.264)
}

enum FFmpegSampleTable {

    /// Open the remote stream just long enough for FFmpeg to fetch moov and
    /// expose codec parameters. No seeks, no decoding — returns within the
    /// time it takes URLSession to fetch ~64 KB of head bytes.
    ///
    /// Phase I uses this to obtain the codec extradata (avcC / hvcC payload),
    /// then closes FFmpeg entirely and proceeds with raw URLSession +
    /// VTDecompressionSession.
    static func openForMetadata(url: URL, userAgent: String) throws -> StreamMetadata {
        let io = FFmpegURLSessionIO(url: url, userAgent: userAgent)
        let ioUnmanaged = Unmanaged.passRetained(io)
        let bufSize = 64 * 1024
        let ioBuffer = av_malloc(bufSize)!.assumingMemoryBound(to: UInt8.self)
        let readCB: @convention(c) (UnsafeMutableRawPointer?,
                                    UnsafeMutablePointer<UInt8>?,
                                    Int32) -> Int32 = { opaque, buf, size in
            guard let opaque, let buf else { return -1 }
            let io = Unmanaged<FFmpegURLSessionIO>.fromOpaque(opaque).takeUnretainedValue()
            return Int32(io.read(buffer: buf, size: Int(size)))
        }
        let seekCB: @convention(c) (UnsafeMutableRawPointer?, Int64, Int32) -> Int64 = { opaque, offset, whence in
            guard let opaque else { return -1 }
            let io = Unmanaged<FFmpegURLSessionIO>.fromOpaque(opaque).takeUnretainedValue()
            return io.seek(offset: offset, whence: whence)
        }
        let avioCtx = avio_alloc_context(ioBuffer, Int32(bufSize), 0,
                                          ioUnmanaged.toOpaque(),
                                          readCB, nil, seekCB)
        defer {
            if let avioCtx { av_freep(UnsafeMutableRawPointer(mutating: avioCtx)) }
            ioUnmanaged.release()
        }

        var fmtCtxOpt: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        defer {
            if let ptr = fmtCtxOpt {
                var mutable: UnsafeMutablePointer<AVFormatContext>? = ptr
                avformat_close_input(&mutable)
            }
        }
        fmtCtxOpt?.pointee.pb = avioCtx

        guard avformat_open_input(&fmtCtxOpt, nil, nil, nil) == 0,
              let fmtCtx = fmtCtxOpt else {
            throw SampleTableError.formatDescriptionFailed
        }
        guard avformat_find_stream_info(fmtCtx, nil) >= 0,
              let streamsPtr = fmtCtx.pointee.streams else {
            throw SampleTableError.formatDescriptionFailed
        }
        var videoStream: UnsafeMutablePointer<AVStream>? = nil
        for i in 0..<Int(fmtCtx.pointee.nb_streams) {
            if let s = streamsPtr[i],
               let par = s.pointee.codecpar,
               par.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                videoStream = s
                break
            }
        }
        guard let stream = videoStream, let codecPar = stream.pointee.codecpar else {
            throw SampleTableError.formatDescriptionFailed
        }
        let extLen = Int(codecPar.pointee.extradata_size)
        guard extLen > 0, let extPtr = codecPar.pointee.extradata else {
            throw SampleTableError.formatDescriptionFailed
        }
        let extData = Data(bytes: extPtr, count: extLen)
        let timeBase = stream.pointee.time_base
        return StreamMetadata(
            extradata: extData,
            codecID: codecPar.pointee.codec_id,
            width: codecPar.pointee.width,
            height: codecPar.pointee.height,
            timeBaseNum: timeBase.num,
            timeBaseDen: timeBase.den
        )
    }

    /// Build a parallel-fetchable target list from FFmpeg's index entries.
    ///
    /// - Parameters:
    ///   - stream: pointer to the video AVStream (already populated by
    ///     avformat_find_stream_info).
    ///   - timestamps: requested timestamps in seconds.
    /// - Returns: one SampleTableTarget per timestamp, in input order. Each
    ///   target points at the nearest keyframe (sync sample) at or before
    ///   the requested instant — exactly the byte range VTDecompressionSession
    ///   needs to render that frame.
    static func buildTargets(stream: UnsafeMutablePointer<AVStream>,
                              timestamps: [TimeInterval]) throws -> [SampleTableTarget] {
        let count = Int(avformat_index_get_entries_count(stream))
        guard count > 0 else { throw SampleTableError.noKeyframeIndex }

        // Collect just the keyframe entries to keep the lookup loop tight.
        struct KFEntry { let pts: Int64; let pos: Int64; let size: Int }
        var keyframes: [KFEntry] = []
        keyframes.reserveCapacity(count / 8)
        for i in 0..<count {
            guard let e = avformat_index_get_entry(stream, Int32(i)) else { continue }
            if (e.pointee.flags & AVINDEX_KEYFRAME) != 0 {
                keyframes.append(KFEntry(pts: e.pointee.timestamp,
                                          pos: e.pointee.pos,
                                          size: Int(e.pointee.size)))
            }
        }
        guard !keyframes.isEmpty else { throw SampleTableError.noKeyframeIndex }

        let timeBase = stream.pointee.time_base
        let toPTS = { (sec: TimeInterval) -> Int64 in
            Int64(sec * Double(timeBase.den) / Double(timeBase.num))
        }
        let firstFew = keyframes.prefix(3).map { "(pts=\($0.pts) pos=\($0.pos) size=\($0.size))" }
        let lastFew = keyframes.suffix(3).map { "(pts=\($0.pts) pos=\($0.pos) size=\($0.size))" }
        DebugLog.log("phase-G keyframes: count=\(keyframes.count) tb=\(timeBase.num)/\(timeBase.den) head=\(firstFew) tail=\(lastFew)")

        return timestamps.map { ts in
            let target = toPTS(ts)
            // Pick the keyframe with PTS ≤ target whose PTS is greatest.
            var lo = 0, hi = keyframes.count - 1, best = 0
            while lo <= hi {
                let mid = (lo + hi) / 2
                if keyframes[mid].pts <= target {
                    best = mid
                    lo = mid + 1
                } else {
                    hi = mid - 1
                }
            }
            let kf = keyframes[best]
            return SampleTableTarget(timestamp: ts, pos: kf.pos, size: kf.size, pts: kf.pts)
        }
    }

    /// Fetches each keyframe's byte range via URLSession Range requests.
    ///
    /// Concurrency strategy: deduplicate first — many targets share a
    /// keyframe in DASH-fragmented MP4s (one IDR per segment, ~3 targets per
    /// segment for a typical 100-frame request). Then issue Range requests
    /// with a low concurrency cap (2) to stay under googlevideo's per-URL
    /// rate limit (8+ parallel triggers HTTP 401).
    static func fetchKeyframes(targets: [SampleTableTarget],
                                url: URL,
                                userAgent: String) async throws -> [Data?] {
        let session: URLSession = {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 15
            cfg.timeoutIntervalForResource = 60
            cfg.httpMaximumConnectionsPerHost = 2
            return URLSession(configuration: cfg)
        }()

        // Deduplicate by (pos, size). Multiple targets sharing a keyframe
        // produce a single fetch and the same Data reference at each index.
        var uniqueOrder: [(pos: Int64, size: Int)] = []
        var keyToFirstIdx: [String: Int] = [:]
        var indexToUnique: [Int] = []   // per target → index into uniqueOrder
        for t in targets {
            let key = "\(t.pos):\(t.size)"
            if let first = keyToFirstIdx[key] {
                indexToUnique.append(first)
            } else {
                let u = uniqueOrder.count
                uniqueOrder.append((pos: t.pos, size: t.size))
                keyToFirstIdx[key] = u
                indexToUnique.append(u)
            }
        }
        DebugLog.log("phase-G keyframe fetch: targets=\(targets.count) unique=\(uniqueOrder.count)")

        // 2-way concurrency over the unique set.
        let uniqueFetched: [Data?] = await withTaskGroup(of: (Int, Data?).self) { group -> [Data?] in
            var inFlight = 0
            var iter = uniqueOrder.enumerated().makeIterator()
            func launchNext() {
                while inFlight < 2, let next = iter.next() {
                    let u = next.offset
                    let kf = next.element
                    let urlCopy = url
                    let uaCopy = userAgent
                    inFlight += 1
                    group.addTask {
                        let synth = SampleTableTarget(timestamp: 0, pos: kf.pos,
                                                       size: kf.size, pts: 0)
                        return (u, await fetchKeyframeWithRetry(
                            url: urlCopy, userAgent: uaCopy, target: synth,
                            session: session, retries: 2))
                    }
                }
            }
            launchNext()
            var out = Array<Data?>(repeating: nil, count: uniqueOrder.count)
            for await (u, d) in group {
                out[u] = d
                inFlight -= 1
                launchNext()
            }
            return out
        }

        // Map back to per-target indices.
        var result = Array<Data?>(repeating: nil, count: targets.count)
        for (i, u) in indexToUnique.enumerated() {
            result[i] = uniqueFetched[u]
        }
        return result
    }

    // Single keyframe fetch with a short retry on empty/short responses.
    // googlevideo occasionally returns empty bodies on a fresh Range request;
    // the second attempt almost always succeeds.
    private static func fetchKeyframeWithRetry(
        url: URL, userAgent: String, target: SampleTableTarget,
        session: URLSession, retries: Int
    ) async -> Data? {
        var attempt = 0
        while attempt <= retries {
            var req = URLRequest(url: url)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("bytes=\(target.pos)-\(target.pos + Int64(target.size) - 1)",
                         forHTTPHeaderField: "Range")
            do {
                let (data, resp) = try await session.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if (status == 200 || status == 206) && data.count >= target.size {
                    return data
                }
                // Log unexpected status / short body and try again.
                DebugLog.log("phase-G fetch attempt \(attempt+1) keyframe @\(target.pos) size=\(target.size) → status=\(status) bytes=\(data.count)")
            } catch {
                DebugLog.log("phase-G fetch attempt \(attempt+1) keyframe @\(target.pos): \(error)")
            }
            attempt += 1
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100 ms before retry
        }
        return nil
    }

    /// Decode a series of H.264 keyframes (AVCC framing) via a shared
    /// VTDecompressionSession. Returns CVPixelBuffers in input order.
    /// - Parameters:
    ///   - keyframes: AVCC-framed NAL bytes for each target (in input order)
    ///   - extradata: codec extradata (avcC box payload from MP4)
    ///   - extradataLen: length of extradata
    ///   - codecID: codec identifier from the stream
    static func decodeKeyframes(keyframes: [Data?],
                                 extradata: UnsafePointer<UInt8>,
                                 extradataLen: Int,
                                 width: Int32,
                                 height: Int32,
                                 codecID: AVCodecID) throws -> [CVPixelBuffer?] {

        // Build a CMVideoFormatDescription from the avcC extradata.
        // CMFormatDescriptionCreateFromH264ParameterSets requires Annex-B SPS/PPS;
        // alternatively, we use CMVideoFormatDescriptionCreate with the avcC
        // payload as extension data, which is the lighter path here.
        var fmtDesc: CMVideoFormatDescription?
        let extKey = kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String
        let extData = Data(bytes: extradata, count: extradataLen)
        let atomKey = (codecID == AV_CODEC_ID_HEVC) ? "hvcC" : "avcC"
        let extensions: [CFString: Any] = [
            extKey as CFString: [atomKey: extData] as CFDictionary
        ]
        let codecType: CMVideoCodecType = (codecID == AV_CODEC_ID_HEVC)
            ? kCMVideoCodecType_HEVC
            : kCMVideoCodecType_H264
        let createStatus = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: width, height: height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &fmtDesc
        )
        guard createStatus == noErr, let fmt = fmtDesc else {
            throw SampleTableError.formatDescriptionFailed
        }

        // Output settings: request BGRA from VT so subsequent CIImage / CGImage
        // conversion has no extra colour-conversion step.
        let outputSettings: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferOpenGLCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]

        var sessionOut: VTDecompressionSession?
        // Output callback collects pixel buffers keyed by the index passed in
        // via sourceFrameRefCon (we encode the array index in the pointer).
        let lock = NSLock()
        var collected: [Int: CVPixelBuffer] = [:]
        let callback: VTDecompressionOutputCallback = { refCon, sourceRefCon, status, _, imageBuffer, _, _ in
            guard let sourceRefCon else { return }
            let index = Int(bitPattern: sourceRefCon) - 1
            let payload = Unmanaged<LockedDict>.fromOpaque(refCon!).takeUnretainedValue()
            payload.lock.lock()
            if status == noErr, let imageBuffer {
                payload.dict[index] = imageBuffer
            } else {
                payload.errors[index] = status
            }
            payload.lock.unlock()
        }
        let payload = LockedDict()
        payload.lock = lock
        // We mutate payload.dict from the callback; the box is held alive via
        // refCon until the session is invalidated below.

        var record = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: callback,
            decompressionOutputRefCon: Unmanaged.passUnretained(payload).toOpaque()
        )
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: fmt,
            decoderSpecification: nil,
            imageBufferAttributes: outputSettings as CFDictionary,
            outputCallback: &record,
            decompressionSessionOut: &sessionOut
        )
        guard sessionStatus == noErr, let session = sessionOut else {
            throw SampleTableError.decompressionSessionFailed(sessionStatus)
        }
        defer { VTDecompressionSessionInvalidate(session) }

        // Decode each keyframe. We pass index+1 via sourceFrameRefCon (0
        // would be NULL and conflated with "no refcon").
        var perFrameDecodeStatus: [Int: OSStatus] = [:]
        for (i, kfOpt) in keyframes.enumerated() {
            guard let kf = kfOpt, !kf.isEmpty else {
                perFrameDecodeStatus[i] = -10001  // missing keyframe data
                continue
            }
            // Wrap the keyframe bytes in a CMBlockBuffer.
            var blockBuf: CMBlockBuffer?
            let blockStatus = kf.withUnsafeBytes { rawPtr -> OSStatus in
                let base = UnsafeMutableRawPointer(mutating: rawPtr.baseAddress!)
                return CMBlockBufferCreateWithMemoryBlock(
                    allocator: kCFAllocatorDefault,
                    memoryBlock: base,
                    blockLength: kf.count,
                    blockAllocator: kCFAllocatorNull,
                    customBlockSource: nil,
                    offsetToData: 0,
                    dataLength: kf.count,
                    flags: 0,
                    blockBufferOut: &blockBuf
                )
            }
            guard blockStatus == noErr, let block = blockBuf else { continue }

            var sampleBuf: CMSampleBuffer?
            var sampleSize: Int = kf.count
            let sampleStatus = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: block,
                formatDescription: fmt,
                sampleCount: 1,
                sampleTimingEntryCount: 0,
                sampleTimingArray: nil,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuf
            )
            guard sampleStatus == noErr, let sample = sampleBuf else { continue }

            let refCon = UnsafeMutableRawPointer(bitPattern: i + 1)
            let decodeStatus = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sample,
                flags: [],
                frameRefcon: refCon,
                infoFlagsOut: nil
            )
            perFrameDecodeStatus[i] = decodeStatus
            kf.withUnsafeBytes { _ in }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)

        // Surface per-frame status if any failed.
        let synchronousFailures = perFrameDecodeStatus.filter { $0.value != noErr }
        if !synchronousFailures.isEmpty {
            let summary = synchronousFailures.prefix(3).map { "[\($0.key)]=\($0.value)" }.joined(separator: " ")
            DebugLog.log("VT decode submit errors: count=\(synchronousFailures.count) sample=\(summary)")
        }
        lock.lock()
        let asyncFailures = payload.errors
        lock.unlock()
        if !asyncFailures.isEmpty {
            let summary = asyncFailures.prefix(3).map { "[\($0.key)]=\($0.value)" }.joined(separator: " ")
            DebugLog.log("VT decode async errors: count=\(asyncFailures.count) sample=\(summary)")
        }

        var out: [CVPixelBuffer?] = Array(repeating: nil, count: keyframes.count)
        lock.lock()
        for (idx, buf) in payload.dict { out[idx] = buf }
        lock.unlock()
        return out
    }
}

// Heap-allocated reference container so the C callback can mutate state
// captured via the refCon opaque pointer.
private final class LockedDict {
    var lock = NSLock()
    var dict: [Int: CVPixelBuffer] = [:]
    var errors: [Int: OSStatus] = [:]
}
