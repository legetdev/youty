import Foundation

// Standalone regression harness: compile with FFmpegURLSessionIO.swift and DebugLog.swift.
// A watchdog makes a missed wakeup fail the test instead of hanging the test process.
private final class RangeStub: URLProtocol {
    static let prefetchFinished = DispatchSemaphore(value: 0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let scenario = request.url!.lastPathComponent
        let later = request.value(forHTTPHeaderField: "Range")!.hasPrefix("bytes=1000000-")
        var status = 206
        var headers = ["Content-Range": "bytes 0-15/16"]
        var body = Data(repeating: 42, count: 16)
        switch scenario {
        case "forbidden": status = 403; headers = [:]; body = Data()
        case "empty": body = Data()
        case "truncated": body = Data([42])
        case "ignored": status = 200; headers = ["Content-Length": "16"]
        case "wrong-offset": headers = ["Content-Range": "bytes 1-16/17"]
        case "prefetch":
            if later { status = 403; headers = [:]; body = Data() }
            else { headers = ["Content-Range": "bytes 0-999999/2000000"]; body = Data(repeating: 42, count: 1_000_000) }
        default: break
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
        if scenario == "prefetch" && later { Self.prefetchFinished.signal() }
    }
}

@main private struct FrameRangeRegression {
    // Exercises valid data/EOF plus error responses both before and during demand reads.
    static func main() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            fputs("FAIL: range read hung\n", stderr); exit(1)
        }
        for scenario in ["valid", "forbidden", "empty", "truncated", "ignored", "wrong-offset", "prefetch"] {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [RangeStub.self]
            let io = FFmpegURLSessionIO(url: URL(string: "https://range.test/\(scenario)")!, userAgent: "test", configuration: config)
            var bytes = [UInt8](repeating: 0, count: 32)
            let result = bytes.withUnsafeMutableBufferPointer { io.read(buffer: $0.baseAddress!, size: $0.count) }
            if scenario == "valid" {
                precondition(result == 16 && bytes.prefix(16).allSatisfy { $0 == 42 })
                precondition(io.seek(offset: 0, whence: 0x10000) == 16)
                precondition(bytes.withUnsafeMutableBufferPointer { io.read(buffer: $0.baseAddress!, size: 32) } == 0)
            } else if scenario == "prefetch" {
                precondition(result == 32)
                precondition(RangeStub.prefetchFinished.wait(timeout: .now() + 2) == .success)
                // Allow the queued completion to precede the demand read, reproducing the lost wakeup.
                Thread.sleep(forTimeInterval: 0.05)
                precondition(io.seek(offset: 1_000_000, whence: 0) == 1_000_000)
                precondition(bytes.withUnsafeMutableBufferPointer { io.read(buffer: $0.baseAddress!, size: 32) } < 0)
            } else {
                precondition(result < 0)
                precondition(bytes.withUnsafeMutableBufferPointer { io.read(buffer: $0.baseAddress!, size: 32) } < 0)
            }
            print("PASS: \(scenario)")
        }
    }
}
