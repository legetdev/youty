import Foundation

// Standalone regression harness for CLI options and untrusted MP4 metadata.
// swiftc Sources/{SidxParser,MP4MoofParser,PlatformRouter}.swift CLI/ArgsParser.swift Scripts/test-swift-boundaries.swift -o /tmp/youty-boundaries
@main
enum BoundaryTests {
    /// Runs deterministic input checks without loading the app or contacting platforms.
    static func main() throws {
        let save = ArgsParser.parse(["youty", "save", "--quiet", "--json", "https://youtu.be/example"])
        precondition(save.bools == ["quiet", "json"] && save.positionals == ["https://youtu.be/example"])
        let search = ArgsParser.parse(["youty", "search", "--text", "my query"])
        precondition(search.bool("text") && search.positionals == ["my query"])
        let embed = ArgsParser.parse(["youty", "embed", "--text", "my query", "--query"])
        precondition(embed.value(for: "text") == "my query" && embed.bool("query"))
        let literal = ArgsParser.parse(["youty", "embed", "--", "--help", "--version"])
        precondition(!literal.wantsHelp && !literal.wantsVersion && literal.positionals == ["--help", "--version"])
        let literalCommand = ArgsParser.parse(["youty", "--", "list"])
        precondition(literalCommand.subcommand == "list")
        precondition(ArgsParser.parse(["youty", "save", "--help"]).wantsHelp)
        precondition(PlatformRouter.platform(for: "https://evil.example/youtube.com/watch?v=x") == nil)
        precondition(PlatformRouter.platform(for: "https://youtube.com.evil.example/watch?v=x") == nil)
        precondition(PlatformRouter.platform(for: "https://m.youtube.com/watch?v=x") == .youtube)

        var validSidx = Data([0, 0, 0, 44]) + Data("sidx".utf8)
        validSidx += Data(repeating: 0, count: 20)
        validSidx += Data([0, 0, 0, 1])
        validSidx += be32(100) + be32(1000) + be32(0)
        let segments = try SidxParser.parse(headBytes: validSidx)
        precondition(segments.count == 1 && segments[0].pos == 44 && segments[0].size == 100)
        for count in 0..<validSidx.count {
            expectFailure { _ = try SidxParser.parse(headBytes: Data(validSidx.prefix(count))) }
        }

        let tfhd = box("tfhd", be32(0x020018) + be32(1) + be32(100) + be32(20))
        let trun = box("trun", be32(0x000800) + be32(1) + be32(UInt32.max))
        let moof = box("moof", box("traf", tfhd + trun))
        let samples = try MP4MoofParser.parse(segmentData: moof, segmentStartInFile: 0)
        precondition(samples.count == 1 && samples[0].pts == Int64(UInt32.max))
        for count in 0..<moof.count {
            expectFailure { _ = try MP4MoofParser.parse(segmentData: Data(moof.prefix(count)), segmentStartInFile: 0) }
        }
        let hugeRun = box("trun", be32(0) + be32(UInt32.max))
        expectFailure { _ = try MP4MoofParser.parse(segmentData: box("moof", box("traf", tfhd + hugeRun)), segmentStartInFile: 0) }

        // Deterministic malformed inputs exercise bounds checks and integer conversions.
        var seed: UInt64 = 42
        for iteration in 0..<10_000 {
            var bytes = Data()
            for _ in 0..<(iteration % 128) {
                seed = seed &* 6364136223846793005 &+ 1
                bytes.append(UInt8(truncatingIfNeeded: seed >> 32))
            }
            _ = try? SidxParser.parse(headBytes: bytes)
            _ = try? MP4MoofParser.parse(segmentData: bytes, segmentStartInFile: 0)
        }
        print("SWIFT_BOUNDARIES_OK CLI, URL hosts, SIDX, MOOF, 10000 malformed inputs")
    }

    /// Requires malformed metadata to fail cleanly instead of being accepted.
    static func expectFailure(_ operation: () throws -> Void) {
        do {
            try operation()
            preconditionFailure("Malformed input was accepted")
        } catch {}
    }

    /// Encodes one network-order integer for binary fixtures.
    static func be32(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
              UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    /// Wraps a payload in a standard MP4 box header.
    static func box(_ type: String, _ payload: Data) -> Data {
        be32(UInt32(payload.count + 8)) + Data(type.utf8) + payload
    }
}
