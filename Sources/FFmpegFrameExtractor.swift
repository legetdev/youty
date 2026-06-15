import Foundation
import AppKit
import CoreGraphics
import VideoToolbox
import CoreVideo
import CoreImage

// Sendable mutable box for hop-out-of-async-context patterns.
private final class SendableBox<T>: @unchecked Sendable {
    var value: T! = nil
}

// FFmpeg get_format callback for VideoToolbox: select AV_PIX_FMT_VIDEOTOOLBOX
// when offered so frames come back as CVPixelBuffers in data[3].
private let ffmpeg_get_format_videotoolbox:
    @convention(c) (UnsafeMutablePointer<AVCodecContext>?,
                    UnsafePointer<AVPixelFormat>?) -> AVPixelFormat = { _, fmts in
    guard let fmts else { return AV_PIX_FMT_NONE }
    var i = 0
    while fmts[i] != AV_PIX_FMT_NONE {
        if fmts[i] == AV_PIX_FMT_VIDEOTOOLBOX { return AV_PIX_FMT_VIDEOTOOLBOX }
        i += 1
    }
    return fmts[0]
}

// Internal: a captured frame that is either already a software NSImage or
// still a GPU-resident CVPixelBuffer awaiting conversion. The seek loop
// produces these; the parallel post-loop stage converts CVPixelBuffers to
// NSImages so all GPU → CPU readbacks run concurrently across cores.
private enum CapturedFrame {
    case software(NSImage)
    case hardware(CVPixelBuffer)
}


// Frame extraction via FFmpeg's libavformat + libavcodec, statically linked.
//
// This is the production path: bytes flow googlevideo → FFmpeg HTTP I/O →
// libavcodec decoder → BGRA pixel buffer → CGImage → JPEG. No video file is
// written to disk at any point; FFmpeg fetches only the keyframe byte ranges
// it needs to satisfy the requested timestamps.
//
// Sandbox-compatible: pure C-library calls via the bridging header. No
// subprocess, no shell, no private APIs. App-Store-compliant under LGPL.

enum FFmpegError: LocalizedError {
    case openInputFailed(Int32)
    case streamInfoFailed(Int32)
    case noVideoStream
    case codecNotFound
    case codecOpenFailed(Int32)
    case seekFailed(at: TimeInterval, code: Int32)
    case decodeFailed(Int32)
    case swsInitFailed
    case noFrameAtTimestamp(TimeInterval)
    case incompleteFrames(got: Int, expected: Int)
    case allocationFailed

    var errorDescription: String? {
        switch self {
        case .openInputFailed, .streamInfoFailed, .codecOpenFailed:
            return "Couldn't open the video for decoding. Try a different video."
        case .noVideoStream:
            return "This source has no video track."
        case .codecNotFound:
            return "This video uses a codec Youty can't decode."
        case .seekFailed:
            return "Couldn't seek inside the video. Try a different video."
        case .decodeFailed:
            return "Video decoding failed mid-stream. Try a different video."
        case .swsInitFailed:
            return "Couldn't initialize the image converter. Try restarting Youty."
        case .noFrameAtTimestamp:
            return "No decodable frame near one of the requested timestamps."
        case .incompleteFrames(let got, let expected):
            return "Saved \(got) of \(expected) frames. Some couldn't be decoded — try the alternative extractor."
        case .allocationFailed:
            return "Ran out of memory while preparing the video decoder. Close some apps and try again."
        }
    }
}

enum FFmpegFrameExtractor {

    // Extracts frames at the given timestamps from a remote URL. Bytes flow
    // through FFmpeg's HTTP I/O (HTTPS + Range requests), only fetching the
    // chunks containing the keyframes around each requested timestamp.
    //
    // - userAgent must match the client that produced the URL (ANDROID_VR).
    // - maxLongEdge caps the long edge of returned frames (preserves aspect).
    //   Pass 1920 for "≤ 1080p", 1280 for "≤ 720p", 0 for source-native.
    // - Returns NSImage values in input order (same order as `timestamps`).
    static func extract(
        url: URL,
        userAgent: String,
        timestamps: [TimeInterval],
        maxLongEdge: Int32 = 1920,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [(timestamp: TimeInterval, image: NSImage)] {
        // Production path: per-target seek loop with prefetch. Earlier
        // alternative extraction paths were tried, regressed, and removed.
        return try await Task.detached(priority: .userInitiated) {
            try doExtract(url: url, userAgent: userAgent,
                          timestamps: timestamps,
                          maxLongEdge: maxLongEdge,
                          progress: progress)
        }.value
    }

    // MARK: - Implementation

    private static func doExtract(
        url: URL,
        userAgent: String,
        timestamps: [TimeInterval],
        maxLongEdge: Int32,
        progress: @Sendable (Double) -> Void
    ) throws -> [(timestamp: TimeInterval, image: NSImage)] {

        // ---- Custom AVIO via URLSession (HTTP Range, fast on googlevideo) ----
        let io = FFmpegURLSessionIO(url: url, userAgent: userAgent)
        let ioUnmanaged = Unmanaged.passRetained(io)
        let bufSize = 64 * 1024
        // av_malloc returns NULL on allocation failure — guard rather than
        // force-unwrap so a memory-pressure scenario throws cleanly instead of
        // trapping the app.
        guard let ioBufferRaw = av_malloc(bufSize) else {
            ioUnmanaged.release()
            throw FFmpegError.allocationFailed
        }
        let ioBuffer = ioBufferRaw.assumingMemoryBound(to: UInt8.self)

        let readCB: @convention(c) (UnsafeMutableRawPointer?,
                                    UnsafeMutablePointer<UInt8>?,
                                    Int32) -> Int32 = { opaque, buf, size in
            guard let opaque, let buf else { return -1 }
            let io = Unmanaged<FFmpegURLSessionIO>.fromOpaque(opaque).takeUnretainedValue()
            let n = io.read(buffer: buf, size: Int(size))
            // AVERROR_EOF = -('E'|'O'<<8|'F'<<16|' '<<24) = -0x20464F45. Signals a
            // CLEAN end-of-stream to libavformat. A negative read is a real error
            // and is propagated as-is (distinct from EOF) so a truncated fetch
            // can't masquerade as a normal end and yield a silently short decode.
            if n == 0 { return -541478725 }   // AVERROR_EOF
            if n < 0  { return Int32(clamping: n) }
            return Int32(n)
        }
        let seekCB: @convention(c) (UnsafeMutableRawPointer?,
                                    Int64,
                                    Int32) -> Int64 = { opaque, offset, whence in
            guard let opaque else { return -1 }
            let io = Unmanaged<FFmpegURLSessionIO>.fromOpaque(opaque).takeUnretainedValue()
            return io.seek(offset: offset, whence: whence)
        }

        let avioCtx = avio_alloc_context(
            ioBuffer, Int32(bufSize),
            0,                                 // write_flag = 0 (read-only)
            ioUnmanaged.toOpaque(),
            readCB, nil, seekCB
        )
        defer {
            if let avioCtx {
                av_freep(UnsafeMutableRawPointer(mutating: avioCtx))
            }
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

        var openOpts: OpaquePointer? = nil
        defer { av_dict_free(&openOpts) }

        // URL is nil — we feed bytes via the custom AVIOContext.
        let openResult = avformat_open_input(&fmtCtxOpt, nil, nil, &openOpts)
        guard openResult == 0, let fmtCtx = fmtCtxOpt else {
            throw FFmpegError.openInputFailed(openResult)
        }

        let streamInfoResult = avformat_find_stream_info(fmtCtx, nil)
        guard streamInfoResult >= 0 else {
            throw FFmpegError.streamInfoFailed(streamInfoResult)
        }

        // ---- Find video stream ----
        var videoStreamIndex: Int32 = -1
        var codecParPtr: UnsafeMutablePointer<AVCodecParameters>? = nil
        let nbStreams = Int(fmtCtx.pointee.nb_streams)
        guard let streamsPtr = fmtCtx.pointee.streams else { throw FFmpegError.noVideoStream }
        for i in 0..<nbStreams {
            guard let s = streamsPtr[i], let par = s.pointee.codecpar else { continue }
            if par.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                videoStreamIndex = Int32(i)
                codecParPtr = par
                break
            }
        }
        guard videoStreamIndex >= 0, let codecPar = codecParPtr else {
            throw FFmpegError.noVideoStream
        }

        guard let videoStream = streamsPtr[Int(videoStreamIndex)] else {
            throw FFmpegError.noVideoStream
        }
        let timeBase = videoStream.pointee.time_base

        // ---- Open codec ----
        guard let codec = avcodec_find_decoder(codecPar.pointee.codec_id) else {
            throw FFmpegError.codecNotFound
        }
        guard let codecCtx = avcodec_alloc_context3(codec) else {
            throw FFmpegError.codecNotFound
        }
        defer {
            var mutable: UnsafeMutablePointer<AVCodecContext>? = codecCtx
            avcodec_free_context(&mutable)
        }
        guard avcodec_parameters_to_context(codecCtx, codecPar) == 0 else {
            throw FFmpegError.codecNotFound
        }
        // Enable multi-thread decode.
        codecCtx.pointee.thread_count = 0   // auto
        codecCtx.pointee.thread_type = Int32(FF_THREAD_FRAME | FF_THREAD_SLICE)

        // ---- F.2 hardware decode: empirically slower for our access pattern ----
        //
        // Wiring VideoToolbox HW decode via hw_device_ctx + get_format works
        // correctly (verified: frames come back as CVPixelBuffers, deferred
        // parallel conversion takes only 452 ms for 100 frames). But the HW
        // path's *per-seek* cost is ~250 ms vs ~60 ms on the software path
        // (VideoToolbox session reset + keyframe lookup per av_seek_frame).
        //
        // For 100 sparse seeks that's 30+ s of decode-loop overhead — net
        // worse than software for the access pattern our pipeline uses.
        // HW decode would only pay off for *linear* playback at 1000+ fps,
        // which is bandwidth-bound for long videos anyway.
        //
        // Path forward to actually unlock HW: ditch the per-target seek loop
        // and parse the MP4 sample table (stss/stco/stsz) ourselves to fetch
        // *exact* keyframe byte ranges, then feed them to a stateless
        // VTDecompressionSession decode per frame. That bypasses FFmpeg's
        // seek path entirely. Substantial work — left for Phase G.

        let openCodec = avcodec_open2(codecCtx, codec, nil)
        guard openCodec == 0 else { throw FFmpegError.codecOpenFailed(openCodec) }

        let srcW = codecCtx.pointee.width
        let srcH = codecCtx.pointee.height
        let srcPixFmt = codecCtx.pointee.pix_fmt

        // ---- Output sizing: cap long edge to maxLongEdge, preserve aspect ----
        let outW: Int32
        let outH: Int32
        if maxLongEdge <= 0 || (srcW <= maxLongEdge && srcH <= maxLongEdge) {
            outW = srcW
            outH = srcH
        } else {
            let scale = Double(maxLongEdge) / Double(max(srcW, srcH))
            outW = Int32((Double(srcW) * scale).rounded()) & ~1
            outH = Int32((Double(srcH) * scale).rounded()) & ~1
        }

        // ---- Build sws context: source pix_fmt → BGRA, scaled ----
        guard let swsCtx = sws_getContext(
            srcW, srcH, srcPixFmt,
            outW, outH, AV_PIX_FMT_BGRA,
            SWS_BILINEAR, nil, nil, nil
        ) else { throw FFmpegError.swsInitFailed }
        defer { sws_freeContext(swsCtx) }

        // ---- Allocate AVFrame + AVPacket ----
        guard let avFrame = av_frame_alloc() else { throw FFmpegError.decodeFailed(-1) }
        defer {
            var mutable: UnsafeMutablePointer<AVFrame>? = avFrame
            av_frame_free(&mutable)
        }
        guard let packet = av_packet_alloc() else { throw FFmpegError.decodeFailed(-1) }
        defer {
            var mutable: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&mutable)
        }

        // ---- Adaptive extraction mode ----
        //
        // For closely-spaced targets (e.g. a 213 s video with frames every
        // 2 s) a single continuous linear read is fastest — decode amortises
        // over one pass and we capture each target as the cursor walks by.
        //
        // For sparse targets (e.g. a 60-min video with frames every 38 s)
        // linear read wastes ~99 % of decode work. Per-target seek + decode-
        // the-next-keyframe is dramatically faster; URLSession Range I/O
        // makes seeks ~50 ms each.
        //
        // Threshold: average target interval > 5 s → per-target seek mode.
        let total = timestamps.count
        let sorted = timestamps.enumerated().sorted { $0.element < $1.element }
        let sortedPtsList: [Int64] = sorted.map {
            Int64($0.element * Double(timeBase.den) / Double(timeBase.num))
        }
        // First pass: per-target seek loop captures CapturedFrames. HW path
        // produces .hardware(CVPixelBuffer) (no GPU readback yet); software
        // path produces .software(NSImage) (already converted by sws_scale).
        var captures: [CapturedFrame?] = Array(repeating: nil, count: total)

        for (cursor, item) in sorted.enumerated() {
            let inputIndex = item.offset
            let ts = item.element
            let pts = sortedPtsList[cursor]
            let seekResult = av_seek_frame(fmtCtx, videoStreamIndex, pts, AVSEEK_FLAG_BACKWARD)
            if seekResult < 0 { throw FFmpegError.seekFailed(at: ts, code: seekResult) }
            avcodec_flush_buffers(codecCtx)

            var captured: CapturedFrame? = nil
            seekLoop: while true {
                av_packet_unref(packet)
                let readResult = av_read_frame(fmtCtx, packet)
                if readResult < 0 { break }
                if packet.pointee.stream_index != videoStreamIndex { continue }

                let sendResult = avcodec_send_packet(codecCtx, packet)
                if sendResult < 0 && sendResult != EAGAIN_FFM { continue }

                while true {
                    let receiveResult = avcodec_receive_frame(codecCtx, avFrame)
                    if receiveResult == EAGAIN_FFM || receiveResult == AVERROR_EOF_FFM { break }
                    if receiveResult < 0 { throw FFmpegError.decodeFailed(receiveResult) }
                    let framePts = avFrame.pointee.best_effort_timestamp
                    if framePts == AV_NOPTS_VALUE_FFM || framePts >= pts {
                        if let cap = captureFrame(from: avFrame, sws: swsCtx,
                                                  outW: outW, outH: outH) {
                            captured = cap
                            av_frame_unref(avFrame)
                            break seekLoop
                        }
                    }
                    av_frame_unref(avFrame)
                }
            }
            guard let cap = captured else { throw FFmpegError.noFrameAtTimestamp(ts) }
            captures[inputIndex] = cap
            progress(Double(cursor + 1) / Double(total))
        }

        // Convert (no-op pass-through for software captures).
        let sortedTuples = sorted.map { (offset: $0.offset, element: $0.element) }
        return try convertCaptures(captures, sorted: sortedTuples)
    }

    // MARK: - Frame capture (called from the per-target loop)

    private static func captureFrame(
        from avFrame: UnsafeMutablePointer<AVFrame>,
        sws: OpaquePointer,
        outW: Int32, outH: Int32
    ) -> CapturedFrame? {
        if avFrame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue,
           let opaque = avFrame.pointee.data.3 {
            // data[3] holds a CVPixelBufferRef owned by the AVFrame. We bridge
            // to a Swift-managed reference here; Swift's CFType ARC adds a
            // retain so the buffer survives the av_frame_unref() call that
            // releases FFmpeg's reference moments later.
            let pb: CVPixelBuffer = Unmanaged.fromOpaque(UnsafeRawPointer(opaque))
                .takeUnretainedValue()
            // Force an extra CFRetain — Swift CF bridging on takeUnretainedValue
            // doesn't always bump the count synchronously; this guarantees
            // survival across av_frame_unref.
            _ = Unmanaged.passRetained(pb)
            return .hardware(pb)
        }
        if let img = renderViaSws(from: avFrame, sws: sws, outW: outW, outH: outH) {
            return .software(img)
        }
        return nil
    }

    // MARK: - Parallel CVPixelBuffer → NSImage conversion

    private static func convertCaptures(_ captures: [CapturedFrame?],
                                         sorted: [(offset: Int, element: TimeInterval)])
        throws -> [(TimeInterval, NSImage)] {
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])

        // Map slot → timestamp.
        var slotToTs: [Int: TimeInterval] = [:]
        for entry in sorted { slotToTs[entry.offset] = entry.element }

        var out: [(TimeInterval, NSImage)?] = Array(repeating: nil, count: captures.count)
        var hwTasks: [(slot: Int, ts: TimeInterval, pb: CVPixelBuffer)] = []

        for (i, cap) in captures.enumerated() {
            guard let cap else { continue }
            let ts = slotToTs[i] ?? 0
            switch cap {
            case .software(let img):
                out[i] = (ts, img)
            case .hardware(let pb):
                hwTasks.append((i, ts, pb))
            }
        }

        if !hwTasks.isEmpty {
            // CIContext is thread-safe for concurrent createCGImage. We run
            // each readback on a concurrent dispatch queue; on Apple Silicon's
            // unified memory architecture eight in-flight GPU dispatches +
            // readbacks complete in roughly the same wall time as one would
            // sequentially.
            let queue = DispatchQueue(label: "ffmpeg.gpu-pull", attributes: .concurrent)
            let group = DispatchGroup()
            let lock = NSLock()
            var converted: [Int: NSImage] = [:]
            for task in hwTasks {
                group.enter()
                queue.async {
                    let ci = CIImage(cvPixelBuffer: task.pb)
                    let cg = ciContext.createCGImage(ci, from: ci.extent)
                    // Release the extra CFRetain we added in captureFrame.
                    _ = Unmanaged.passUnretained(task.pb).release()
                    if let cg {
                        let ns = NSImage(cgImage: cg,
                                         size: NSSize(width: cg.width, height: cg.height))
                        lock.lock(); converted[task.slot] = ns; lock.unlock()
                    }
                    group.leave()
                }
            }
            group.wait()
            for (slot, img) in converted {
                let ts = slotToTs[slot] ?? 0
                out[slot] = (ts, img)
            }
        }

        var final: [(TimeInterval, NSImage)] = []
        final.reserveCapacity(out.count)
        for entry in out {
            guard let e = entry else {
                throw FFmpegError.incompleteFrames(got: final.count, expected: out.count)
            }
            final.append(e)
        }
        return final
    }

    // Software path: sws_scale → BGRA → CGImage → NSImage.
    private static func renderViaSws(
        from avFrame: UnsafeMutablePointer<AVFrame>,
        sws: OpaquePointer,
        outW: Int32, outH: Int32
    ) -> NSImage? {
        let stride = Int(outW) * 4
        let byteCount = stride * Int(outH)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)

        var dst = [buffer, nil, nil, nil] as [UnsafeMutablePointer<UInt8>?]
        var dstStride = [Int32(stride), 0, 0, 0]

        let scaled = withUnsafePointer(to: &avFrame.pointee.data) { srcDataPtr -> Int32 in
            srcDataPtr.withMemoryRebound(to: UnsafePointer<UInt8>?.self,
                                          capacity: 8) { srcData in
                withUnsafePointer(to: &avFrame.pointee.linesize) { lsPtr in
                    lsPtr.withMemoryRebound(to: Int32.self, capacity: 8) { ls in
                        dst.withUnsafeMutableBufferPointer { dstBuf in
                            dstStride.withUnsafeMutableBufferPointer { strideBuf in
                                sws_scale(sws,
                                          srcData, ls,
                                          0, avFrame.pointee.height,
                                          dstBuf.baseAddress, strideBuf.baseAddress)
                            }
                        }
                    }
                }
            }
        }
        guard scaled > 0 else {
            buffer.deallocate()
            return nil
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        let info: CGBitmapInfo = [.byteOrder32Little,
                                  CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)]
        let provider = CGDataProvider(
            dataInfo: nil,
            data: buffer,
            size: byteCount,
            releaseData: { _, ptr, _ in
                UnsafeMutableRawPointer(mutating: ptr).deallocate()
            }
        )
        guard let prov = provider else {
            buffer.deallocate()
            return nil
        }
        guard let cg = CGImage(
            width: Int(outW), height: Int(outH),
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: stride,
            space: cs, bitmapInfo: info,
            provider: prov, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: Int(outW), height: Int(outH)))
    }
}

// FFmpeg error constants that aren't exposed to Swift directly.
private let EAGAIN_FFM: Int32 = -35              // FFERRTAG('E','A','G','N') = AVERROR(EAGAIN) on macOS
private let AVERROR_EOF_FFM: Int32 = -0x20464F45 // FFERRTAG('E','O','F',' ')
private let AV_NOPTS_VALUE_FFM: Int64 = Int64.min
