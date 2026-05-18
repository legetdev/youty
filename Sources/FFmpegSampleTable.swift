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
    case formatDescriptionFailed
    case allocationFailed

    var errorDescription: String? {
        switch self {
        case .formatDescriptionFailed:
            return "Couldn't read this video's codec layout. Try a different video."
        case .allocationFailed:
            return "Ran out of memory while reading this video's metadata. Close some apps and try again."
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
        // av_malloc returns NULL on allocation failure — guard rather than
        // force-unwrap so a memory-pressure scenario throws cleanly instead of
        // trapping the app.
        guard let ioBufferRaw = av_malloc(bufSize) else {
            ioUnmanaged.release()
            throw SampleTableError.allocationFailed
        }
        let ioBuffer = ioBufferRaw.assumingMemoryBound(to: UInt8.self)
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

}

