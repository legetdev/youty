import Foundation

// File-backed debug log. NSLog isn't reliably surfacing in the unified log for
// this sandboxed app, so we write to a file we can `tail -f` directly.
//
// Path: ~/Library/Logs/youty-debug.log (sandbox-allowed)

enum DebugLog {

    private static let queue = DispatchQueue(label: "dev.leget.youty.debuglog")
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("youty-debug.log")
    }()

    static func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        queue.async {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                try? handle.seekToEnd()
                if let data = line.data(using: .utf8) { try? handle.write(contentsOf: data) }
                try? handle.close()
            }
        }
    }
}
