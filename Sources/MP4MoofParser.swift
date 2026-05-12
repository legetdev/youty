import Foundation

// Fragmented MP4 segment parser. Walks moof → traf → tfhd / tfdt / trun
// to compute per-sample byte offsets, sizes, DTS/PTS, and sync-sample flags
// inside one DASH segment. This is the per-sample addressing Phase I needs
// to fetch and decode arbitrary frames within a segment (not just the
// segment's leading keyframe).
//
// Spec: ISO/IEC 14496-12 §8.8 (movie fragments).
//
// Conventions:
//   • All multi-byte ints in MP4 are big-endian.
//   • This parser assumes CMAF / DASH usage: exactly one traf per moof,
//     default_base_is_moof typically set, samples encoded as AVCC (4-byte
//     length-prefixed NAL units) in the following mdat.
//   • Sample byte offsets returned are absolute in the *file* (not the
//     segment) — the caller passes the segment's start-in-file when calling
//     parse(), and trun.data_offset is added on top of moof-start-in-file.

struct MP4Sample {
    /// File-absolute byte offset of this sample's first byte (in mdat).
    let offset: Int64
    /// Sample size in bytes.
    let size: Int
    /// Decode timestamp in the media timescale.
    let dts: Int64
    /// Presentation timestamp (dts + cts_offset).
    let pts: Int64
    /// Sample duration in the media timescale.
    let duration: Int64
    /// True iff this is a sync sample (keyframe).
    let isSync: Bool
}

enum MP4MoofError: LocalizedError {
    case noMoof
    case noTraf
    case noTfhd
    case noTrun
    case multiTrunUnsupported
    case truncated
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .noMoof:                return "No moof box in segment data."
        case .noTraf:                return "moof has no traf child."
        case .noTfhd:                return "traf has no tfhd."
        case .noTrun:                return "traf has no trun."
        case .multiTrunUnsupported:  return "Multi-trun traf isn't supported by the Phase I bytes-fetched math."
        case .truncated:             return "Segment data is truncated before all referenced bytes."
        case .malformed(let m):      return "Malformed box: \(m)"
        }
    }
}

enum MP4MoofParser {

    /// Parses a single segment's moof box and returns the per-sample table.
    /// - Parameters:
    ///   - segmentData: bytes starting at or before the moof. May contain
    ///     leading boxes (styp, sidx) that are skipped.
    ///   - segmentStartInFile: file-absolute byte offset of segmentData[0].
    /// - Returns: samples in trun decode order.
    static func parse(segmentData: Data, segmentStartInFile: Int64) throws -> [MP4Sample] {
        return try segmentData.withUnsafeBytes { rawBuf in
            let base = rawBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let total = rawBuf.count

            // 1. Find the moof box at top level.
            guard let moofRange = findTopLevelBox(base: base, total: total, type: "moof") else {
                throw MP4MoofError.noMoof
            }
            let moofStart = moofRange.start
            let moofEnd = moofRange.end                       // exclusive
            let moofStartInFile = segmentStartInFile + Int64(moofStart)

            // 2. Find traf inside moof. Skip moof's full-box-style header bytes
            //    (moof itself is a plain box, not a fullbox — payload begins
            //    immediately after the 8-byte header).
            let moofPayloadStart = moofStart + moofRange.headerLen
            guard let trafRange = findChildBox(base: base,
                                                payloadStart: moofPayloadStart,
                                                payloadEnd: moofEnd,
                                                type: "traf") else {
                throw MP4MoofError.noTraf
            }

            // 3. Inside traf: tfhd (required), tfdt (optional), trun (≥1).
            let trafPayloadStart = trafRange.start + trafRange.headerLen
            let trafEnd = trafRange.end

            guard let tfhdRange = findChildBox(base: base,
                                                payloadStart: trafPayloadStart,
                                                payloadEnd: trafEnd,
                                                type: "tfhd") else {
                throw MP4MoofError.noTfhd
            }
            let tfhd = try parseTfhd(base: base,
                                     payloadStart: tfhdRange.start + tfhdRange.headerLen,
                                     payloadEnd: tfhdRange.end)

            // tfdt is optional; default base media decode time = 0 if absent.
            var baseDecodeTime: Int64 = 0
            if let tfdtRange = findChildBox(base: base,
                                              payloadStart: trafPayloadStart,
                                              payloadEnd: trafEnd,
                                              type: "tfdt") {
                baseDecodeTime = try parseTfdt(base: base,
                                                 payloadStart: tfdtRange.start + tfdtRange.headerLen,
                                                 payloadEnd: tfdtRange.end)
            }

            // 4. Iterate every trun in this traf. Multi-trun per traf is
            //    legal in the spec but rare in CMAF / DASH. We surface the
            //    multi-trun case so the caller can fall back rather than
            //    risk wrong bytes-fetched math (trun #2's mdat region may
            //    not be contiguous with trun #1's).
            var samples: [MP4Sample] = []
            var dts = baseDecodeTime
            var trunCount = 0
            var cursor = trafPayloadStart
            while cursor + 8 <= trafEnd {
                let box = try readBoxHeader(base: base, at: cursor, end: trafEnd)
                if box.type == "trun" {
                    trunCount += 1
                    if trunCount > 1 {
                        throw MP4MoofError.multiTrunUnsupported
                    }
                    let (runSamples, lastDts) = try parseTrun(
                        base: base,
                        payloadStart: cursor + box.headerLen,
                        payloadEnd: cursor + box.totalSize,
                        moofStartInFile: moofStartInFile,
                        tfhd: tfhd,
                        startDts: dts
                    )
                    samples.append(contentsOf: runSamples)
                    dts = lastDts
                }
                cursor += box.totalSize
            }

            if samples.isEmpty { throw MP4MoofError.noTrun }
            return samples
        }
    }

    // MARK: - tfhd

    private struct TfhdInfo {
        let defaultSampleDuration: UInt32   // 0 if absent
        let defaultSampleSize: UInt32       // 0 if absent
        let defaultSampleFlags: UInt32      // 0 if absent
        let baseDataOffset: Int64?          // file-absolute, if present
        let defaultBaseIsMoof: Bool
    }

    private static func parseTfhd(base: UnsafePointer<UInt8>,
                                   payloadStart: Int,
                                   payloadEnd: Int) throws -> TfhdInfo {
        guard payloadStart + 4 <= payloadEnd else { throw MP4MoofError.malformed("tfhd header") }
        let flags = UInt32(base[payloadStart + 1]) << 16
                  | UInt32(base[payloadStart + 2]) << 8
                  | UInt32(base[payloadStart + 3])
        var p = payloadStart + 4
        p += 4   // track_ID (skip)

        var baseDataOffset: Int64? = nil
        if (flags & 0x000001) != 0 {
            guard p + 8 <= payloadEnd else { throw MP4MoofError.malformed("tfhd base_data_offset") }
            baseDataOffset = readInt64BE(base, p); p += 8
        }
        if (flags & 0x000002) != 0 {
            p += 4   // sample_description_index (skip)
        }
        var defDur: UInt32 = 0
        if (flags & 0x000008) != 0 {
            guard p + 4 <= payloadEnd else { throw MP4MoofError.malformed("tfhd default_sample_duration") }
            defDur = readUInt32BE(base, p); p += 4
        }
        var defSize: UInt32 = 0
        if (flags & 0x000010) != 0 {
            guard p + 4 <= payloadEnd else { throw MP4MoofError.malformed("tfhd default_sample_size") }
            defSize = readUInt32BE(base, p); p += 4
        }
        var defFlags: UInt32 = 0
        if (flags & 0x000020) != 0 {
            guard p + 4 <= payloadEnd else { throw MP4MoofError.malformed("tfhd default_sample_flags") }
            defFlags = readUInt32BE(base, p); p += 4
        }
        let defaultBaseIsMoof = (flags & 0x020000) != 0
        return TfhdInfo(defaultSampleDuration: defDur,
                         defaultSampleSize: defSize,
                         defaultSampleFlags: defFlags,
                         baseDataOffset: baseDataOffset,
                         defaultBaseIsMoof: defaultBaseIsMoof)
    }

    // MARK: - tfdt

    private static func parseTfdt(base: UnsafePointer<UInt8>,
                                   payloadStart: Int,
                                   payloadEnd: Int) throws -> Int64 {
        guard payloadStart + 4 <= payloadEnd else { throw MP4MoofError.malformed("tfdt header") }
        let version = base[payloadStart]
        let p = payloadStart + 4
        if version == 0 {
            guard p + 4 <= payloadEnd else { throw MP4MoofError.malformed("tfdt v0 body") }
            return Int64(readUInt32BE(base, p))
        } else {
            guard p + 8 <= payloadEnd else { throw MP4MoofError.malformed("tfdt v1 body") }
            return readInt64BE(base, p)
        }
    }

    // MARK: - trun

    private static func parseTrun(base: UnsafePointer<UInt8>,
                                   payloadStart: Int,
                                   payloadEnd: Int,
                                   moofStartInFile: Int64,
                                   tfhd: TfhdInfo,
                                   startDts: Int64) throws -> (samples: [MP4Sample], nextDts: Int64) {
        guard payloadStart + 4 <= payloadEnd else { throw MP4MoofError.malformed("trun header") }
        let version = base[payloadStart]
        let flags = UInt32(base[payloadStart + 1]) << 16
                  | UInt32(base[payloadStart + 2]) << 8
                  | UInt32(base[payloadStart + 3])
        var p = payloadStart + 4

        guard p + 4 <= payloadEnd else { throw MP4MoofError.malformed("trun sample_count") }
        let sampleCount = Int(readUInt32BE(base, p)); p += 4

        var dataOffset: Int32 = 0
        if (flags & 0x000001) != 0 {
            guard p + 4 <= payloadEnd else { throw MP4MoofError.malformed("trun data_offset") }
            dataOffset = Int32(bitPattern: readUInt32BE(base, p)); p += 4
        }
        var firstSampleFlags: UInt32 = 0
        let hasFirstSampleFlags = (flags & 0x000004) != 0
        if hasFirstSampleFlags {
            guard p + 4 <= payloadEnd else { throw MP4MoofError.malformed("trun first_sample_flags") }
            firstSampleFlags = readUInt32BE(base, p); p += 4
        }

        let perSampleDuration = (flags & 0x000100) != 0
        let perSampleSize     = (flags & 0x000200) != 0
        let perSampleFlags    = (flags & 0x000400) != 0
        let perSampleCts      = (flags & 0x000800) != 0

        // CMAF / DASH: default_base_is_moof set, base_data_offset absent →
        // sample data starts at moof_start + data_offset.
        // Pre-spec fallback: if base_data_offset is present, use it.
        let dataStart: Int64
        if let bdo = tfhd.baseDataOffset {
            dataStart = bdo + Int64(dataOffset)
        } else if tfhd.defaultBaseIsMoof {
            dataStart = moofStartInFile + Int64(dataOffset)
        } else {
            // Legacy fallback: relative to moof start anyway (CMAF assumes it).
            dataStart = moofStartInFile + Int64(dataOffset)
        }

        var samples: [MP4Sample] = []
        samples.reserveCapacity(sampleCount)
        var cursorBytes: Int64 = dataStart
        var dts = startDts

        for i in 0..<sampleCount {
            var dur: UInt32 = tfhd.defaultSampleDuration
            if perSampleDuration {
                guard p + 4 <= payloadEnd else { throw MP4MoofError.malformed("trun per-sample duration") }
                dur = readUInt32BE(base, p); p += 4
            }
            var size: UInt32 = tfhd.defaultSampleSize
            if perSampleSize {
                guard p + 4 <= payloadEnd else { throw MP4MoofError.malformed("trun per-sample size") }
                size = readUInt32BE(base, p); p += 4
            }
            var sFlags: UInt32
            if perSampleFlags {
                guard p + 4 <= payloadEnd else { throw MP4MoofError.malformed("trun per-sample flags") }
                sFlags = readUInt32BE(base, p); p += 4
            } else if i == 0 && hasFirstSampleFlags {
                sFlags = firstSampleFlags
            } else {
                sFlags = tfhd.defaultSampleFlags
            }
            var cts: Int32 = 0
            if perSampleCts {
                guard p + 4 <= payloadEnd else { throw MP4MoofError.malformed("trun per-sample cts") }
                if version == 0 {
                    cts = Int32(bitPattern: readUInt32BE(base, p))  // legacy: stored unsigned, treat as positive
                } else {
                    cts = Int32(bitPattern: readUInt32BE(base, p))  // signed
                }
                p += 4
            }

            // Decode sync flag. ISO/IEC 14496-12 §8.8.3.1 sample_flags layout.
            let dependsOn  = (sFlags >> 24) & 0x3
            let isNonSync  = (sFlags >> 16) & 0x1
            let isSync = (dependsOn == 2) || (isNonSync == 0 && dependsOn != 1)

            samples.append(MP4Sample(
                offset: cursorBytes,
                size: Int(size),
                dts: dts,
                pts: dts + Int64(cts),
                duration: Int64(dur),
                isSync: isSync
            ))
            cursorBytes += Int64(size)
            dts += Int64(dur)
        }

        return (samples, dts)
    }

    // MARK: - Box walking primitives

    private struct BoxHeader {
        let start: Int          // byte offset of first byte (size field)
        let end: Int            // byte offset just past the last payload byte
        let headerLen: Int      // 8 (standard) or 16 (largesize)
        let totalSize: Int      // end - start
        let type: String
    }

    /// Reads the standard ISO box header at `at`. Handles the size=1 (64-bit
    /// largesize) case. Returns nil if there aren't 8 bytes left.
    private static func readBoxHeader(base: UnsafePointer<UInt8>,
                                       at offset: Int,
                                       end: Int) throws -> BoxHeader {
        guard offset + 8 <= end else { throw MP4MoofError.truncated }
        let rawSize = Int64(readUInt32BE(base, offset))
        // Type as 4-char ASCII.
        var type = ""
        for i in 0..<4 {
            let b = base[offset + 4 + i]
            type.append(Character(UnicodeScalar(b)))
        }
        let totalSize: Int
        let headerLen: Int
        if rawSize == 1 {
            guard offset + 16 <= end else { throw MP4MoofError.truncated }
            // largesize stored in next 8 bytes.
            let large = readInt64BE(base, offset + 8)
            totalSize = Int(large)
            headerLen = 16
        } else if rawSize == 0 {
            // Size 0 means "to end of container". Cap at end.
            totalSize = end - offset
            headerLen = 8
        } else {
            totalSize = Int(rawSize)
            headerLen = 8
        }
        guard totalSize >= headerLen, offset + totalSize <= end else {
            throw MP4MoofError.malformed("box \(type) size \(totalSize) at \(offset) exceeds container end \(end)")
        }
        return BoxHeader(start: offset,
                          end: offset + totalSize,
                          headerLen: headerLen,
                          totalSize: totalSize,
                          type: type)
    }

    /// Walks top-level boxes from byte 0 looking for the first occurrence of
    /// `type`. Returns nil if not found.
    private static func findTopLevelBox(base: UnsafePointer<UInt8>,
                                          total: Int,
                                          type: String) -> BoxHeader? {
        var cursor = 0
        while cursor + 8 <= total {
            guard let header = try? readBoxHeader(base: base, at: cursor, end: total) else { return nil }
            if header.type == type { return header }
            cursor += header.totalSize
            if header.totalSize <= 0 { return nil }
        }
        return nil
    }

    /// Walks immediate children of a container box, returning the first child
    /// matching `type`. Returns nil if no such child exists.
    private static func findChildBox(base: UnsafePointer<UInt8>,
                                       payloadStart: Int,
                                       payloadEnd: Int,
                                       type: String) -> BoxHeader? {
        var cursor = payloadStart
        while cursor + 8 <= payloadEnd {
            guard let header = try? readBoxHeader(base: base, at: cursor, end: payloadEnd) else { return nil }
            if header.type == type { return header }
            cursor += header.totalSize
            if header.totalSize <= 0 { return nil }
        }
        return nil
    }

    // MARK: - Big-endian byte readers

    private static func readUInt32BE(_ base: UnsafePointer<UInt8>, _ idx: Int) -> UInt32 {
        UInt32(base[idx])     << 24 |
        UInt32(base[idx + 1]) << 16 |
        UInt32(base[idx + 2]) << 8  |
        UInt32(base[idx + 3])
    }

    private static func readInt64BE(_ base: UnsafePointer<UInt8>, _ idx: Int) -> Int64 {
        var v: Int64 = 0
        for i in 0..<8 { v = (v << 8) | Int64(base[idx + i]) }
        return v
    }
}
