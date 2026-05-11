import Foundation
import AppKit
import CoreGraphics

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

    var errorDescription: String? {
        switch self {
        case .openInputFailed(let c):    return "FFmpeg could not open the stream (code \(c))."
        case .streamInfoFailed(let c):   return "FFmpeg could not read stream info (code \(c))."
        case .noVideoStream:             return "No video stream in the source."
        case .codecNotFound:             return "No decoder available for this codec."
        case .codecOpenFailed(let c):    return "FFmpeg could not open the codec (code \(c))."
        case .seekFailed(let t, let c):  return "FFmpeg seek to \(String(format: "%.1f", t))s failed (code \(c))."
        case .decodeFailed(let c):       return "FFmpeg decode failed (code \(c))."
        case .swsInitFailed:             return "FFmpeg scale context init failed."
        case .noFrameAtTimestamp(let t): return "No decodable frame near \(String(format: "%.1f", t))s."
        case .incompleteFrames(let g, let e):
            return "Got \(g) of \(e) frames."
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

        // Hop off the main thread — libavformat does network I/O.
        try await Task.detached(priority: .userInitiated) {
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
        let ioBuffer = av_malloc(bufSize)!.assumingMemoryBound(to: UInt8.self)

        let readCB: @convention(c) (UnsafeMutableRawPointer?,
                                    UnsafeMutablePointer<UInt8>?,
                                    Int32) -> Int32 = { opaque, buf, size in
            guard let opaque, let buf else { return -1 }
            let io = Unmanaged<FFmpegURLSessionIO>.fromOpaque(opaque).takeUnretainedValue()
            let n = io.read(buffer: buf, size: Int(size))
            if n == 0 {
                // AVERROR_EOF — returning 0 also works on FFmpeg 7.x but be explicit.
                return Int32(bitPattern: 0xDEADBEEF) // overwritten below
            }
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
        var out: [(TimeInterval, NSImage)] = Array(repeating: (0, NSImage()), count: total)

        let durationSeconds: Double = {
            if let last = sorted.last?.element { return last }
            return 0
        }()
        let avgInterval = total > 1 ? durationSeconds / Double(total - 1) : 0

        if avgInterval > 5.0 {
            // ---- Per-target seek mode (sparse) ----
            for (cursor, item) in sorted.enumerated() {
                let inputIndex = item.offset
                let ts = item.element
                let pts = sortedPtsList[cursor]
                let seekResult = av_seek_frame(fmtCtx, videoStreamIndex, pts, AVSEEK_FLAG_BACKWARD)
                if seekResult < 0 { throw FFmpegError.seekFailed(at: ts, code: seekResult) }
                avcodec_flush_buffers(codecCtx)

                var captured: NSImage? = nil
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
                            if let image = renderBGRAImage(from: avFrame, sws: swsCtx,
                                                           outW: outW, outH: outH) {
                                captured = image
                                av_frame_unref(avFrame)
                                break seekLoop
                            }
                        }
                        av_frame_unref(avFrame)
                    }
                }
                guard let image = captured else { throw FFmpegError.noFrameAtTimestamp(ts) }
                out[inputIndex] = (ts, image)
                progress(Double(cursor + 1) / Double(total))
            }
        } else {
            // ---- Linear read mode (dense) ----
            var cursor = 0
            let firstTargetTs = sorted.first?.element ?? 0
            if firstTargetTs > 5.0 {
                let firstPts = sortedPtsList[0]
                let seekPts = firstPts - Int64(2.0 * Double(timeBase.den) / Double(timeBase.num))
                _ = av_seek_frame(fmtCtx, videoStreamIndex, max(0, seekPts), AVSEEK_FLAG_BACKWARD)
                avcodec_flush_buffers(codecCtx)
            }

            readLoop: while cursor < total {
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
                    while cursor < total
                          && (framePts == AV_NOPTS_VALUE_FFM
                              || framePts >= sortedPtsList[cursor]) {
                        if let image = renderBGRAImage(from: avFrame, sws: swsCtx,
                                                       outW: outW, outH: outH) {
                            let inputIndex = sorted[cursor].offset
                            let ts = sorted[cursor].element
                            out[inputIndex] = (ts, image)
                            cursor += 1
                            progress(Double(cursor) / Double(total))
                        } else { break }
                    }
                    av_frame_unref(avFrame)
                    if cursor >= total { break readLoop }
                }
            }

            if cursor < total {
                _ = avcodec_send_packet(codecCtx, nil)
                while cursor < total {
                    let receiveResult = avcodec_receive_frame(codecCtx, avFrame)
                    if receiveResult == EAGAIN_FFM || receiveResult == AVERROR_EOF_FFM { break }
                    if receiveResult < 0 { break }
                    let framePts = avFrame.pointee.best_effort_timestamp
                    while cursor < total
                          && (framePts == AV_NOPTS_VALUE_FFM
                              || framePts >= sortedPtsList[cursor]) {
                        if let image = renderBGRAImage(from: avFrame, sws: swsCtx,
                                                       outW: outW, outH: outH) {
                            let inputIndex = sorted[cursor].offset
                            let ts = sorted[cursor].element
                            out[inputIndex] = (ts, image)
                            cursor += 1
                            progress(Double(cursor) / Double(total))
                        } else { break }
                    }
                    av_frame_unref(avFrame)
                }
            }

            if cursor < total {
                throw FFmpegError.incompleteFrames(got: cursor, expected: total)
            }
        }

        return out
    }

    // sws_scale → BGRA buffer → CGImage → NSImage.
    private static func renderBGRAImage(
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
