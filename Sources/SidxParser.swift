import Foundation

// Minimal MP4 box parser focused on the sidx (segment index) box used by
// DASH-fragmented MP4. Lets us extract keyframe byte positions + PTSes for
// every segment of the file without paying the cost of 100 av_seek_frame
// calls just to lazy-populate FFmpeg's internal index.
//
// One sidx box at the start of the file encodes the full segment map for
// the whole video. We fetch the first 8 KB via URLSession (one Range
// request), parse the boxes, and return a flat segment list.

struct SidxSegment {
    let pos: Int64        // byte offset of the segment's first moof box
    let size: Int64       // segment size in bytes (moof + mdat for this fragment)
    let pts: Int64        // PTS (in stream timebase) of the segment's first sample
    let duration: Int64   // duration of the segment in PTS units
}

enum SidxParserError: LocalizedError {
    case headFetchFailed
    case sidxNotFound
    case malformed

    var errorDescription: String? {
        switch self {
        case .headFetchFailed: return "Could not fetch MP4 head bytes."
        case .sidxNotFound:    return "No sidx box — not a DASH-fragmented MP4."
        case .malformed:       return "sidx box appears malformed."
        }
    }
}

enum SidxParser {

    /// Fetch first ~16 KB of the stream and parse the sidx box.
    static func fetch(url: URL, userAgent: String) async throws -> [SidxSegment] {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("bytes=0-16383", forHTTPHeaderField: "Range")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              !data.isEmpty else {
            throw SidxParserError.headFetchFailed
        }
        return try parse(headBytes: data)
    }

    static func parse(headBytes data: Data) throws -> [SidxSegment] {
        var idx = 0
        // Walk top-level boxes until we hit sidx (or run out).
        while idx + 8 <= data.count {
            let size = Int(readUInt32BE(data, idx))
            let type = String(bytes: data[idx + 4 ..< idx + 8], encoding: .ascii) ?? "?"
            if type == "sidx" {
                return try parseSidxBody(data: data, boxStart: idx, boxSize: size)
            }
            if size <= 0 { break }
            idx += size
        }
        throw SidxParserError.sidxNotFound
    }

    private static func parseSidxBody(data: Data, boxStart: Int, boxSize: Int) throws -> [SidxSegment] {
        // sidx layout (ISO/IEC 14496-12):
        //   full box header (8 + 4) = 12 bytes  (size, type, version+flags)
        //   reference_ID (4)
        //   timescale (4)
        //   earliest_presentation_time (4 if v=0, 8 if v=1)
        //   first_offset (4 if v=0, 8 if v=1)
        //   reserved (2)
        //   reference_count (2)
        //   per-reference (12 bytes each):
        //     reference_type|referenced_size (4)
        //     subsegment_duration (4)
        //     SAP flags (4)
        let bodyStart = boxStart + 8
        guard boxSize >= 12, boxStart + boxSize <= data.count,
              bodyStart + 4 <= data.count else { throw SidxParserError.malformed }
        let version = data[bodyStart]
        guard version <= 1,
              boxSize >= (version == 0 ? 32 : 40) else { throw SidxParserError.malformed }
        var p = bodyStart + 4
        guard p + 8 <= data.count else { throw SidxParserError.malformed }
        // reference_ID + timescale
        p += 4   // skip reference_ID
        _ = readUInt32BE(data, p)   // timescale (unused — we use stream timebase)
        p += 4
        let earliestPts: Int64
        let firstOffset: Int64
        if version == 0 {
            earliestPts = Int64(readUInt32BE(data, p)); p += 4
            firstOffset = Int64(readUInt32BE(data, p)); p += 4
        } else {
            earliestPts = readInt64BE(data, p); p += 8
            firstOffset = readInt64BE(data, p); p += 8
        }
        p += 2   // reserved
        let refCount = Int(readUInt16BE(data, p)); p += 2

        guard p + refCount * 12 <= boxStart + boxSize,
              earliestPts >= 0, firstOffset >= 0 else {
            // Not enough bytes — would need a larger head fetch.
            throw SidxParserError.malformed
        }

        // first segment starts after this sidx box + first_offset
        let sidxEnd = Int64(boxStart + boxSize)
        let (firstPos, offsetOverflow) = sidxEnd.addingReportingOverflow(firstOffset)
        guard !offsetOverflow else { throw SidxParserError.malformed }
        var segPos = firstPos
        var segPts = earliestPts
        var segments: [SidxSegment] = []
        segments.reserveCapacity(refCount)
        for _ in 0..<refCount {
            let refSizeAndType = readUInt32BE(data, p); p += 4
            guard refSizeAndType & 0x80000000 == 0 else { throw SidxParserError.malformed }
            let referencedSize = Int64(refSizeAndType & 0x7FFFFFFF)
            // (reference_type bit not relevant for our use)
            let subsegmentDuration = Int64(readUInt32BE(data, p)); p += 4
            p += 4   // skip SAP flags
            segments.append(SidxSegment(pos: segPos, size: referencedSize,
                                         pts: segPts,
                                         duration: subsegmentDuration))
            let (nextPos, positionOverflow) = segPos.addingReportingOverflow(referencedSize)
            let (nextPts, timestampOverflow) = segPts.addingReportingOverflow(subsegmentDuration)
            guard !positionOverflow, !timestampOverflow else { throw SidxParserError.malformed }
            segPos = nextPos
            segPts = nextPts
        }
        return segments
    }

    // MARK: - Big-endian byte readers

    private static func readUInt16BE(_ data: Data, _ idx: Int) -> UInt16 {
        UInt16(data[idx]) << 8 | UInt16(data[idx + 1])
    }
    private static func readUInt32BE(_ data: Data, _ idx: Int) -> UInt32 {
        UInt32(data[idx])     << 24 |
        UInt32(data[idx + 1]) << 16 |
        UInt32(data[idx + 2]) << 8  |
        UInt32(data[idx + 3])
    }
    private static func readInt64BE(_ data: Data, _ idx: Int) -> Int64 {
        var v: Int64 = 0
        for i in 0..<8 { v = (v << 8) | Int64(data[idx + i]) }
        return v
    }
}
