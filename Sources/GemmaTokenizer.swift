import Foundation

/// Native Gemma BPE tokenizer with byte-fallback. Reproduces HuggingFace's
/// tokenizer bit-for-bit so on-device EmbeddingGemma embeddings match the
/// reference path. Pure Foundation — no third-party dependency.
///
/// Loads the compact artifact built by Scripts/build-gemma-tokenizer-artifact.py
/// (vocab.bin + merges.bin + added_tokens.bin) instead of the 32 MB tokenizer.json,
/// so a one-shot `youty save` pays only a small one-time load.
///
/// Correctness notes:
///   - Initial-symbol lookup is keyed by Unicode SCALAR VALUE, never by `String`.
///     Swift `String` uses canonical equivalence, which folds distinct vocab
///     tokens (e.g. ';' U+003B and ';' U+037E) onto one another — HF keys by raw
///     bytes, so we must too.
///   - Added/special token strings in the input are split out and emitted as their
///     ids directly (a literal "<bos>" -> 2), matching HF.
final class GemmaTokenizer {

    static let bos = 2
    static let eos = 1
    static let pad = 0

    /// Single-Unicode-scalar token -> id. Scalar-value keyed (byte-exact).
    private let scalarToId: [UInt32: Int]
    /// byteId[b] = id of the "<0xBB>" byte-fallback token.
    private let byteId: [Int]
    /// (a_id << 32 | b_id) -> (rank, merged_id).
    private let pairRank: [Int64: (rank: Int, merged: Int)]
    /// Added/special token content -> id (ASCII; `String` keys are safe here).
    private let added: [String: Int]
    private let addedFirst: Set<UInt32>
    private let addedMaxScalars: Int

    enum TokError: Error { case badArtifact(String) }

    init(directory: URL) throws {
        // ---- vocab.bin: u32 count, then per id: u32 len + UTF-8 ----
        let vb = [UInt8](try Data(contentsOf: directory.appendingPathComponent("vocab.bin")))
        var v = 0
        func vU32() -> Int { defer { v += 4 }; return Int(vb[v]) | Int(vb[v+1])<<8 | Int(vb[v+2])<<16 | Int(vb[v+3])<<24 }
        let n = vU32()
        var s2i = [UInt32: Int]()
        var bytes = [Int](repeating: -1, count: 256)
        for id in 0..<n {
            let len = vU32()
            let s = String(decoding: vb[v..<v+len], as: UTF8.self)
            v += len
            var it = s.unicodeScalars.makeIterator()
            if let first = it.next(), it.next() == nil {
                s2i[first.value] = id                              // single scalar
            } else if s.utf8.count == 6, s.hasPrefix("<0x"), s.hasSuffix(">"),
                      let b = UInt8(s.dropFirst(3).dropLast(), radix: 16) {
                bytes[Int(b)] = id                                 // <0xNN> byte token
            }
        }
        self.scalarToId = s2i
        if bytes.contains(-1) { throw TokError.badArtifact("missing byte-fallback tokens") }
        self.byteId = bytes

        // ---- merges.bin: u32 count, then per merge: i32 a, i32 b, i32 merged ----
        let mb = [UInt8](try Data(contentsOf: directory.appendingPathComponent("merges.bin")))
        var m = 0
        func mI32() -> Int { defer { m += 4 }; return Int(Int32(bitPattern: UInt32(mb[m]) | UInt32(mb[m+1])<<8 | UInt32(mb[m+2])<<16 | UInt32(mb[m+3])<<24)) }
        let mcount = mI32()
        var pr = [Int64: (rank: Int, merged: Int)](minimumCapacity: mcount)
        for r in 0..<mcount { let a = mI32(), b = mI32(), merged = mI32(); pr[(Int64(a)<<32)|Int64(b)] = (r, merged) }
        self.pairRank = pr

        // ---- added_tokens.bin: u32 count, then per: u32 id + u32 len + UTF-8 ----
        let ab = [UInt8](try Data(contentsOf: directory.appendingPathComponent("added_tokens.bin")))
        var a = 0
        func aU32() -> Int { defer { a += 4 }; return Int(ab[a]) | Int(ab[a+1])<<8 | Int(ab[a+2])<<16 | Int(ab[a+3])<<24 }
        let acount = aU32()
        var addedMap = [String: Int](minimumCapacity: acount)
        var firsts = Set<UInt32>()
        var maxLen = 0
        for _ in 0..<acount {
            let id = aU32()
            let len = aU32()
            let content = String(decoding: ab[a..<a+len], as: UTF8.self)
            a += len
            addedMap[content] = id
            if let f = content.unicodeScalars.first { firsts.insert(f.value) }
            maxLen = max(maxLen, content.unicodeScalars.count)
        }
        self.added = addedMap
        self.addedFirst = firsts
        self.addedMaxScalars = maxLen
    }

    /// Full HF-equivalent encoding: [bos] + (added-token-split + BPE) + [eos].
    func encode(_ text: String) -> [Int] {
        var out = [Self.bos]
        let scalars = Array(text.unicodeScalars)
        var segment = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            if addedFirst.contains(scalars[i].value),
               let (id, len) = matchAdded(scalars, at: i) {
                if !segment.isEmpty { out.append(contentsOf: bpe(normalize(String(segment)))); segment = .init() }
                out.append(id)
                i += len
            } else {
                segment.append(scalars[i])
                i += 1
            }
        }
        if !segment.isEmpty { out.append(contentsOf: bpe(normalize(String(segment)))) }
        out.append(Self.eos)
        return out
    }

    /// Longest added-token match starting at scalar index `i`, or nil.
    private func matchAdded(_ scalars: [Unicode.Scalar], at i: Int) -> (id: Int, len: Int)? {
        let maxL = min(addedMaxScalars, scalars.count - i)
        var L = maxL
        while L >= 1 {
            let candidate = String(String.UnicodeScalarView(scalars[i..<i+L]))
            if let id = added[candidate] { return (id, L) }
            L -= 1
        }
        return nil
    }

    /// Gemma normalizer: replace every U+0020 space with the ▁ (U+2581) marker.
    private func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: " ", with: "\u{2581}")
    }

    /// BPE over the id sequence: per-scalar vocab ids with byte-fallback, then
    /// merge the lowest-rank adjacent pair (leftmost on ties) until stable.
    private func bpe(_ s: String) -> [Int] {
        var ids = [Int]()
        ids.reserveCapacity(s.unicodeScalars.count)
        for scalar in s.unicodeScalars {
            if let id = scalarToId[scalar.value] {
                ids.append(id)
            } else {
                for byte in String(scalar).utf8 { ids.append(byteId[Int(byte)]) }
            }
        }
        if ids.count < 2 { return ids }
        while true {
            var bestRank = Int.max, bestPos = -1, bestMerged = -1
            var i = 0
            while i < ids.count - 1 {
                if let mrg = pairRank[(Int64(ids[i])<<32)|Int64(ids[i+1])], mrg.rank < bestRank {
                    bestRank = mrg.rank; bestPos = i; bestMerged = mrg.merged
                }
                i += 1
            }
            if bestPos < 0 { break }
            ids[bestPos] = bestMerged
            ids.remove(at: bestPos + 1)
        }
        return ids
    }
}
