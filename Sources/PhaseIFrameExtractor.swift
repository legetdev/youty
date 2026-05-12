import Foundation
import AppKit
import CoreMedia
import CoreVideo
import VideoToolbox
import CoreImage

// Phase I — sample-precise byte fetch + stateless VTDecompressionSession.
//
// Architecture (per implementation.md Phase I):
//   1. In parallel: fetch codec metadata (one FFmpeg open, no seek loop) and
//      the sidx segment index (one ~16 KB HTTP Range request).
//   2. Map each requested timestamp to its containing DASH segment.
//      Dedupe segments and group their targets.
//   3. Per segment, in parallel (concurrency cap protects against
//      googlevideo's per-URL rate limit):
//        a. Range-fetch the segment's first 32 KB (covers the moof box).
//        b. Parse the moof to obtain per-sample byte offsets, sizes, DTS/PTS
//           and the sync-sample flag.
//        c. Locate each target's sample by PTS, determine the highest
//           sample index touched.
//        d. If the bytes for samples [0 .. last_touched] extend past 32 KB,
//           Range-fetch the remainder and stitch.
//        e. Feed samples [0 .. last_touched] into a fresh VTDecompressionSession.
//           The async output callback collects CVPixelBuffers keyed by
//           sample index.
//        f. Map collected buffers back to target PTSes.
//   4. Parallel CVPixelBuffer → CGImage conversion (reuses the F.2-proven
//      CIContext + concurrent DispatchQueue pattern).
//   5. Return per-target NSImages in the caller's original input order.
//
// On any error this extractor throws — callers fall back to the F.1 path
// in FFmpegFrameExtractor.extract.

enum PhaseIError: LocalizedError {
    case metadataFailed(Error)
    case sidxFailed(Error)
    case noSegments
    case unsupportedCodec(UInt32)  // VP9, AV1, etc. — fall back to F.1
    case noFormatDescription(OSStatus)
    case noTargetSample(TimeInterval)
    case rangeFetchFailed(Int)
    case moofParseFailed(Error)
    case multiTrunNotSupported     // multiple trun boxes in one traf — uncommon
    case decompressionSessionFailed(OSStatus)
    case missingDecodedFrame(at: TimeInterval)
    case imageConversionFailed(at: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .metadataFailed(let e):      return "Phase I metadata fetch failed: \(e.localizedDescription)"
        case .sidxFailed(let e):          return "Phase I sidx fetch failed: \(e.localizedDescription)"
        case .noSegments:                 return "Phase I: stream has no DASH segments (likely progressive MP4)."
        case .unsupportedCodec(let id):   return "Phase I: codec id \(id) not supported by VT (only H.264/HEVC)."
        case .noFormatDescription(let s): return "Phase I: CMFormatDescription creation failed (\(s))."
        case .noTargetSample(let t):      return "Phase I: no sample at or after \(String(format: "%.1f", t))s in containing segment."
        case .rangeFetchFailed(let s):    return "Phase I: HTTP Range request returned status \(s)."
        case .moofParseFailed(let e):     return "Phase I: moof parse failed: \(e.localizedDescription)"
        case .multiTrunNotSupported:      return "Phase I: multi-trun segment not supported."
        case .decompressionSessionFailed(let s): return "Phase I: VTDecompressionSessionCreate failed (\(s))."
        case .missingDecodedFrame(let t): return "Phase I: VT did not return a frame for \(String(format: "%.1f", t))s."
        case .imageConversionFailed(let t): return "Phase I: CVPixelBuffer→CGImage failed at \(String(format: "%.1f", t))s."
        }
    }
}

enum PhaseIFrameExtractor {

    // Tunables.
    private static let segmentConcurrencyCap = 8      // segments fetched/decoded in parallel
    private static let moofPrefetchBytes: Int64 = 32_768   // first chunk per segment

    // MARK: - Public entry point

    static func extract(
        url: URL,
        userAgent: String,
        timestamps: [TimeInterval],
        maxLongEdge: Int32 = 1920,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [(timestamp: TimeInterval, image: NSImage)] {

        let started = Date()

        // 1. Metadata + sidx in parallel.
        async let metaTask: StreamMetadata = {
            try await Task.detached(priority: .userInitiated) {
                try FFmpegSampleTable.openForMetadata(url: url, userAgent: userAgent)
            }.value
        }()
        async let sidxTask: [SidxSegment] = {
            do { return try await SidxParser.fetch(url: url, userAgent: userAgent) }
            catch { throw PhaseIError.sidxFailed(error) }
        }()

        let metadata: StreamMetadata
        let segments: [SidxSegment]
        do {
            metadata = try await metaTask
        } catch let phaseErr as PhaseIError {
            throw phaseErr
        } catch {
            throw PhaseIError.metadataFailed(error)
        }
        do {
            segments = try await sidxTask
        } catch let phaseErr as PhaseIError {
            throw phaseErr
        } catch {
            throw PhaseIError.sidxFailed(error)
        }
        guard !segments.isEmpty else { throw PhaseIError.noSegments }

        // Codec gate: only H.264 + HEVC have working extradata wiring here.
        // VP9 / AV1 streams need their own format descriptions and aren't
        // wired in Phase I; fall back to F.1 (FFmpeg handles all codecs).
        guard metadata.codecID == AV_CODEC_ID_H264 || metadata.codecID == AV_CODEC_ID_HEVC else {
            throw PhaseIError.unsupportedCodec(metadata.codecID.rawValue)
        }

        DebugLog.log("phase-I: meta+sidx ready in \(Int(Date().timeIntervalSince(started)*1000))ms (segments=\(segments.count) codec=\(metadata.codecID.rawValue) \(metadata.width)x\(metadata.height) tb=\(metadata.timeBaseNum)/\(metadata.timeBaseDen))")

        // Build a single shared CMVideoFormatDescription from the avcC/hvcC
        // payload. VTDecompressionSession is per-segment but CMFormatDescription
        // can be reused.
        let fmtDesc = try makeFormatDescription(metadata: metadata)

        // 2. Map timestamps → segments. Each entry knows its input index so
        //    we can reassemble the output array in the caller's order.
        struct TargetMapping {
            let inputIndex: Int
            let timestamp: TimeInterval
            let targetPts: Int64
            let segmentIndex: Int
        }
        let toPTS = { (sec: TimeInterval) -> Int64 in
            Int64(sec * Double(metadata.timeBaseDen) / Double(metadata.timeBaseNum))
        }
        var mappings: [TargetMapping] = []
        mappings.reserveCapacity(timestamps.count)
        let sortedSegPts = segments.map { $0.pts }   // monotonically increasing
        for (i, ts) in timestamps.enumerated() {
            let pts = toPTS(ts)
            // Greatest segment.pts ≤ target.pts (binary search).
            var lo = 0, hi = sortedSegPts.count - 1, best = 0
            while lo <= hi {
                let mid = (lo + hi) / 2
                if sortedSegPts[mid] <= pts { best = mid; lo = mid + 1 }
                else { hi = mid - 1 }
            }
            mappings.append(TargetMapping(inputIndex: i, timestamp: ts,
                                           targetPts: pts, segmentIndex: best))
        }

        // 3. Group by segment.
        var jobTargetsBySegment: [Int: [PhaseISegmentTarget]] = [:]
        for m in mappings {
            let target = PhaseISegmentTarget(inputIndex: m.inputIndex,
                                              ts: m.timestamp, pts: m.targetPts)
            jobTargetsBySegment[m.segmentIndex, default: []].append(target)
        }
        let jobs: [PhaseISegmentJob] = jobTargetsBySegment
            .map { (segIdx, targets) in
                PhaseISegmentJob(segmentIndex: segIdx,
                                  segment: segments[segIdx],
                                  targets: targets)
            }
            .sorted { $0.segmentIndex < $1.segmentIndex }
        DebugLog.log("phase-I: \(timestamps.count) targets across \(jobs.count) unique segments")

        // Shared URLSession for segment fetches.
        let session: URLSession = {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 20
            cfg.timeoutIntervalForResource = 90
            cfg.httpMaximumConnectionsPerHost = 8
            return URLSession(configuration: cfg)
        }()

        // 4. Parallel segment processing with K worker pool. Each worker owns
        //    a single VTDecompressionSession reused across its assigned
        //    segments — fresh-session overhead (~30 ms × N segments) was
        //    measurable per-extract. Jobs are statically round-robin'd into
        //    K chunks; segments are uniform enough that static partitioning
        //    matches dynamic scheduling in practice and keeps the code small.
        let results = ResultBox(slotCount: timestamps.count)
        let progressBox = ProgressBox(total: timestamps.count, callback: progress)
        let workerCount = min(segmentConcurrencyCap, max(1, jobs.count))
        var workerChunks: [[PhaseISegmentJob]] = Array(repeating: [], count: workerCount)
        for (i, job) in jobs.enumerated() {
            workerChunks[i % workerCount].append(job)
        }
        let fmtDescBox = SendableFormatDescription(fmtDesc)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for chunk in workerChunks where !chunk.isEmpty {
                group.addTask {
                    let payload = SampleDecodeBox()
                    let sessionBox = try makeReusableSession(fmtDesc: fmtDescBox.value,
                                                              payload: payload)
                    defer { VTDecompressionSessionInvalidate(sessionBox.session) }
                    for job in chunk {
                        try await processSegment(job: job,
                                                  url: url, userAgent: userAgent,
                                                  session: session,
                                                  vtSession: sessionBox.session,
                                                  vtPayload: payload,
                                                  fmtDesc: fmtDescBox.value,
                                                  results: results,
                                                  progressBox: progressBox)
                    }
                }
            }
            try await group.waitForAll()
        }

        // 5. Sanity-check completeness.
        let captures = results.takeAll()
        for (i, c) in captures.enumerated() {
            if c == nil {
                throw PhaseIError.missingDecodedFrame(at: timestamps[i])
            }
        }
        DebugLog.log("phase-I: decode complete in \(Int(Date().timeIntervalSince(started)*1000))ms; converting buffers")

        // 6. Parallel CVPixelBuffer → CGImage → NSImage with optional scaling.
        // CIContext is thread-safe but not Sendable in Swift's eyes; wrap in
        // an @unchecked Sendable box so the task group accepts it.
        let ciBox = SendableCIContext(CIContext(options: [.useSoftwareRenderer: false]))
        let conversions = await withTaskGroup(of: (Int, NSImage?).self) { group -> [Int: NSImage] in
            for (i, capOpt) in captures.enumerated() {
                guard let pb = capOpt else { continue }
                let ts = timestamps[i]
                let edge = maxLongEdge
                let pbBox = SendablePixelBuffer(pb)
                let ctx = ciBox
                group.addTask {
                    let img = renderToNSImage(pixelBuffer: pbBox.value,
                                               maxLongEdge: edge,
                                               ciContext: ctx.value,
                                               at: ts)
                    return (i, img)
                }
            }
            var out: [Int: NSImage] = [:]
            for await (i, img) in group {
                if let img { out[i] = img }
            }
            return out
        }

        var final: [(TimeInterval, NSImage)] = []
        final.reserveCapacity(timestamps.count)
        for i in 0..<timestamps.count {
            guard let img = conversions[i] else {
                throw PhaseIError.imageConversionFailed(at: timestamps[i])
            }
            final.append((timestamps[i], img))
        }
        DebugLog.log("phase-I: total \(Int(Date().timeIntervalSince(started)*1000))ms (\(final.count) frames)")
        return final
    }

    // MARK: - Per-segment work

    private static func processSegment(
        job: PhaseISegmentJob,
        url: URL,
        userAgent: String,
        session: URLSession,
        vtSession: VTDecompressionSession,
        vtPayload: SampleDecodeBox,
        fmtDesc: CMVideoFormatDescription,
        results: ResultBox,
        progressBox: ProgressBox
    ) async throws {

        // 4a. Fetch the segment's first chunk (covers the moof).
        let segStart = job.segment.pos
        let segSize = job.segment.size
        let firstChunkEnd = min(segStart + moofPrefetchBytes - 1, segStart + segSize - 1)
        let firstChunk = try await rangeFetch(url: url, userAgent: userAgent,
                                                session: session,
                                                from: segStart, to: firstChunkEnd)

        // 4b. Parse the moof.
        let samples: [MP4Sample]
        do {
            samples = try MP4MoofParser.parse(segmentData: firstChunk,
                                               segmentStartInFile: segStart)
        } catch {
            throw PhaseIError.moofParseFailed(error)
        }
        guard !samples.isEmpty else {
            throw PhaseIError.moofParseFailed(MP4MoofError.noTrun)
        }

        // 4c. For each target in this segment, locate its sample by PTS.
        struct ChosenSample { let inputIndex: Int; let ts: TimeInterval; let sampleIdx: Int }
        var segTargets: [ChosenSample] = []
        for t in job.targets {
            // Prefer the first sample with pts >= target; if none, last sample.
            var chosen = samples.count - 1
            for (i, s) in samples.enumerated() {
                if s.pts >= t.pts { chosen = i; break }
            }
            segTargets.append(ChosenSample(inputIndex: t.inputIndex, ts: t.ts, sampleIdx: chosen))
        }
        let highestSampleIdx = segTargets.map { $0.sampleIdx }.max() ?? 0

        // 4d. Ensure we have bytes for samples [0 .. highestSampleIdx].
        let lastSample = samples[highestSampleIdx]
        let lastByteNeeded = lastSample.offset + Int64(lastSample.size) - 1
        let bytesEndInChunk = segStart + Int64(firstChunk.count) - 1
        let segmentData: Data
        if lastByteNeeded <= bytesEndInChunk {
            // First chunk already covers everything we need.
            segmentData = firstChunk
        } else {
            // Fetch the remainder.
            let remainderStart = bytesEndInChunk + 1
            let remainder = try await rangeFetch(url: url, userAgent: userAgent,
                                                  session: session,
                                                  from: remainderStart,
                                                  to: lastByteNeeded)
            var combined = firstChunk
            combined.append(remainder)
            segmentData = combined
        }

        // 4e. Decode samples [0 .. highestSampleIdx] via the worker's reused
        //     VTDecompressionSession. Each segment starts with an IDR, so
        //     the session can be safely reused across unrelated segments.
        let pixelBuffers = try decodeSampleRun(
            segmentData: segmentData,
            segmentStartInFile: segStart,
            samples: samples,
            lastSampleIdx: highestSampleIdx,
            session: vtSession,
            payload: vtPayload,
            fmtDesc: fmtDesc
        )

        // 4f. Emit per-target frames into the shared results array.
        for st in segTargets {
            guard let pb = pixelBuffers[st.sampleIdx] else {
                throw PhaseIError.missingDecodedFrame(at: st.ts)
            }
            results.set(slot: st.inputIndex, pixelBuffer: pb)
            progressBox.tick()
        }
    }

    // MARK: - VT decode of a sample run

    /// Decodes samples[0...lastSampleIdx] in decode order via a worker-owned
    /// VTDecompressionSession. Clears any leftover output from the previous
    /// segment before feeding, since the session is reused. Returns a
    /// dictionary keyed by sample index; B-frame reordering doesn't affect
    /// the key (we tag inputs via sourceFrameRefCon).
    private static func decodeSampleRun(
        segmentData: Data,
        segmentStartInFile: Int64,
        samples: [MP4Sample],
        lastSampleIdx: Int,
        session: VTDecompressionSession,
        payload: SampleDecodeBox,
        fmtDesc: CMVideoFormatDescription
    ) throws -> [Int: CVPixelBuffer] {

        // Clear leftover state from any prior segment on this session. The
        // payload's dict accumulates; this segment's frames are tagged via
        // sourceFrameRefCon, but mixing across segments could cause stale
        // keys. Reset everything between segments.
        payload.lock.lock()
        payload.frames.removeAll(keepingCapacity: true)
        payload.errors.removeAll(keepingCapacity: true)
        payload.lock.unlock()

        // Feed each sample in decode order (== array order).
        for i in 0...lastSampleIdx {
            let s = samples[i]
            let bytesOffsetInSegment = Int(s.offset - segmentStartInFile)
            guard bytesOffsetInSegment >= 0,
                  bytesOffsetInSegment + s.size <= segmentData.count else {
                continue   // shouldn't happen — earlier code ensures coverage
            }
            // Wrap the sample bytes (AVCC NAL units) in a CMBlockBuffer that
            // borrows from `segmentData`. kCFAllocatorNull means CMBlockBuffer
            // does not own the memory; `segmentData` must outlive the
            // VTDecompressionSessionWaitForAsynchronousFrames call below.
            var blockBuf: CMBlockBuffer?
            let blockStatus = segmentData.withUnsafeBytes { rawPtr -> OSStatus in
                let base = UnsafeMutableRawPointer(
                    mutating: rawPtr.baseAddress!.advanced(by: bytesOffsetInSegment))
                return CMBlockBufferCreateWithMemoryBlock(
                    allocator: kCFAllocatorDefault,
                    memoryBlock: base,
                    blockLength: s.size,
                    blockAllocator: kCFAllocatorNull,
                    customBlockSource: nil,
                    offsetToData: 0,
                    dataLength: s.size,
                    flags: 0,
                    blockBufferOut: &blockBuf
                )
            }
            guard blockStatus == noErr, let block = blockBuf else { continue }

            var sampleBuf: CMSampleBuffer?
            var sampleSize = s.size
            let sampleStatus = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: block,
                formatDescription: fmtDesc,
                sampleCount: 1,
                sampleTimingEntryCount: 0,
                sampleTimingArray: nil,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuf
            )
            guard sampleStatus == noErr, let sample = sampleBuf else { continue }

            // sourceFrameRefCon = i+1 so we can tag with bitPattern; the
            // callback subtracts 1. (Index 0 → bitPattern nil → conflated
            // with "no refcon".)
            let refCon = UnsafeMutableRawPointer(bitPattern: i + 1)
            _ = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sample,
                flags: [],
                frameRefcon: refCon,
                infoFlagsOut: nil
            )
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)

        payload.lock.lock()
        let result = payload.frames
        let errs = payload.errors
        payload.lock.unlock()
        if !errs.isEmpty {
            DebugLog.log("phase-I VT errors in segment: \(errs.count) sample(s) failed (first: \(errs.first!))")
        }
        return result
    }

    // MARK: - HTTP Range fetch

    private static func rangeFetch(url: URL,
                                     userAgent: String,
                                     session: URLSession,
                                     from: Int64, to: Int64) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 && status != 206 {
            throw PhaseIError.rangeFetchFailed(status)
        }
        return data
    }

    // MARK: - Format description

    private static func makeFormatDescription(metadata: StreamMetadata) throws -> CMVideoFormatDescription {
        let extKey = kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String
        let atomKey = (metadata.codecID == AV_CODEC_ID_HEVC) ? "hvcC" : "avcC"
        let extensions: [CFString: Any] = [
            extKey as CFString: [atomKey: metadata.extradata] as CFDictionary
        ]
        let codecType: CMVideoCodecType = (metadata.codecID == AV_CODEC_ID_HEVC)
            ? kCMVideoCodecType_HEVC
            : kCMVideoCodecType_H264
        var fmtDescOut: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: metadata.width, height: metadata.height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &fmtDescOut
        )
        guard status == noErr, let fmt = fmtDescOut else {
            throw PhaseIError.noFormatDescription(status)
        }
        return fmt
    }

    // MARK: - CVPixelBuffer → NSImage with optional downscale

    private static func renderToNSImage(pixelBuffer: CVPixelBuffer,
                                          maxLongEdge: Int32,
                                          ciContext: CIContext,
                                          at ts: TimeInterval) -> NSImage? {
        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        let srcMax = max(srcW, srcH)
        let outW: Int
        let outH: Int
        let ci: CIImage
        if maxLongEdge > 0 && srcMax > Int(maxLongEdge) {
            let scale = Double(maxLongEdge) / Double(srcMax)
            outW = Int((Double(srcW) * scale).rounded())
            outH = Int((Double(srcH) * scale).rounded())
            ci = CIImage(cvPixelBuffer: pixelBuffer)
                .transformed(by: .init(scaleX: CGFloat(scale), y: CGFloat(scale)))
        } else {
            outW = srcW
            outH = srcH
            ci = CIImage(cvPixelBuffer: pixelBuffer)
        }
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: outW, height: outH))
    }
}

// MARK: - Mutable result containers crossing actor boundaries

// Job descriptor for one segment's work, surfaced as a top-level type so it
// can be carried across actor boundaries in our TaskGroup.
private struct PhaseISegmentJob: Sendable {
    let segmentIndex: Int
    let segment: SidxSegment
    let targets: [PhaseISegmentTarget]
}
private struct PhaseISegmentTarget: Sendable {
    let inputIndex: Int
    let ts: TimeInterval
    let pts: Int64
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [CVPixelBuffer?]
    init(slotCount: Int) {
        buffers = Array(repeating: nil, count: slotCount)
    }
    func set(slot: Int, pixelBuffer: CVPixelBuffer) {
        lock.lock(); buffers[slot] = pixelBuffer; lock.unlock()
    }
    func takeAll() -> [CVPixelBuffer?] {
        lock.lock(); defer { lock.unlock() }
        return buffers
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done: Int = 0
    private let total: Int
    private let callback: @Sendable (Double) -> Void
    init(total: Int, callback: @escaping @Sendable (Double) -> Void) {
        self.total = total
        self.callback = callback
    }
    func tick() {
        lock.lock(); done += 1; let d = done; lock.unlock()
        callback(Double(d) / Double(max(total, 1)))
    }
}

private final class SampleDecodeBox: @unchecked Sendable {
    let lock = NSLock()
    var frames: [Int: CVPixelBuffer] = [:]
    var errors: [Int: OSStatus] = [:]
}

private final class SendableCIContext: @unchecked Sendable {
    let value: CIContext
    init(_ v: CIContext) { value = v }
}
private final class SendablePixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
    init(_ v: CVPixelBuffer) { value = v }
}

private final class SendableFormatDescription: @unchecked Sendable {
    let value: CMVideoFormatDescription
    init(_ v: CMVideoFormatDescription) { value = v }
}

// One worker-owned VTDecompressionSession. The session and its callback
// share `payload`; mutating the payload's frames dict happens inside the
// callback under the payload's lock.
private final class WorkerVTSession: @unchecked Sendable {
    let session: VTDecompressionSession
    init(session: VTDecompressionSession) { self.session = session }
}

private func makeReusableSession(fmtDesc: CMVideoFormatDescription,
                                  payload: SampleDecodeBox) throws -> WorkerVTSession {
    let outputSettings: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey: true,
    ]
    var record = VTDecompressionOutputCallbackRecord(
        decompressionOutputCallback: { refCon, sourceRefCon, status, _, imageBuffer, _, _ in
            guard let sourceRefCon else { return }
            let idx = Int(bitPattern: sourceRefCon) - 1
            let box = Unmanaged<SampleDecodeBox>.fromOpaque(refCon!).takeUnretainedValue()
            box.lock.lock()
            if status == noErr, let imageBuffer {
                box.frames[idx] = imageBuffer
            } else {
                box.errors[idx] = status
            }
            box.lock.unlock()
        },
        decompressionOutputRefCon: Unmanaged.passUnretained(payload).toOpaque()
    )
    var sessionOut: VTDecompressionSession?
    let createStatus = VTDecompressionSessionCreate(
        allocator: kCFAllocatorDefault,
        formatDescription: fmtDesc,
        decoderSpecification: nil,
        imageBufferAttributes: outputSettings as CFDictionary,
        outputCallback: &record,
        decompressionSessionOut: &sessionOut
    )
    guard createStatus == noErr, let session = sessionOut else {
        throw PhaseIError.decompressionSessionFailed(createStatus)
    }
    return WorkerVTSession(session: session)
}
