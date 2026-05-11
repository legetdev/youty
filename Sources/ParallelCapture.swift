import AppKit

// Parallel frame capture orchestrator.
//
// Spawns N hidden WKWebViews (via N VideoExtractor instances), each playing
// the same remote video URL, and divides the 100 timestamps round-robin
// across them. Each extractor seeks-and-snapshots its slice in parallel.
//
// Theoretical speedup: ~Nx for the capture phase. The load phase is a one-
// shot wait per extractor (all in parallel) so total is bounded by the
// slowest extractor's load time + (frames / N) × per-frame cost.

@MainActor
final class ParallelCapture: ObservableObject {

    let extractors: [VideoExtractor]
    private weak var attachedWindow: NSWindow?

    init(count: Int = 4) {
        self.extractors = (0..<count).map { _ in VideoExtractor() }
    }

    // Attach all child extractors to the host window with distinct frames so
    // WebKit gives each its own render surface. Frames are at alphaValue 0.001
    // — invisible to the user but on-screen as far as WebKit is concerned, so
    // each gets full network + render priority.
    func attach(to window: NSWindow) {
        attachedWindow = window
        for (i, e) in extractors.enumerated() {
            e.attach(to: window)
            // The VideoExtractor frame is laid out by bringOnScreen() at
            // capture time; here we just ensure it's attached as a subview.
            _ = i
        }
    }

    // Loads the same remote URL into every extractor in parallel via
    // unstructured Tasks (avoiding TaskGroup so Swift 6's isolation checker
    // doesn't choke on the non-Sendable VideoExtractor captures).
    func loadAll(streamURL: URL, userAgent: String) async throws {
        let tasks: [Task<Void, Error>] = extractors.map { e in
            Task { @MainActor in
                try await e.loadRemoteVideo(streamURL: streamURL, userAgent: userAgent)
            }
        }
        for t in tasks { try await t.value }
    }

    func loadAllLocal(localURL: URL) async throws {
        let tasks: [Task<Void, Error>] = extractors.map { e in
            Task { @MainActor in
                try await e.loadLocalVideo(localURL: localURL)
            }
        }
        for t in tasks { try await t.value }
    }

    func captureFrames(timestamps: [TimeInterval],
                       isLocalFile: Bool = true,
                       progress: @escaping @Sendable (Double) -> Void)
        async throws -> [(TimeInterval, NSImage)] {

        let n = extractors.count
        let totalCount = timestamps.count
        let counter = ProgressCounter(total: totalCount)

        let tasks: [Task<[(TimeInterval, NSImage)], Error>] = extractors.enumerated().map { (i, e) in
            let mine = timestamps.enumerated()
                .filter { $0.offset % n == i }
                .map { $0.element }
            return Task { @MainActor in
                try await e.captureFrames(timestamps: mine,
                                          isLocalFile: isLocalFile,
                                          slotIndex: i,
                                          slotCount: n) { _ in
                    Task { @MainActor in
                        await counter.increment()
                        let frac = await counter.fraction
                        progress(frac)
                    }
                }
            }
        }
        var collected: [(TimeInterval, NSImage)] = []
        for t in tasks {
            let slice = try await t.value
            collected.append(contentsOf: slice)
        }
        return collected.sorted { $0.0 < $1.0 }
    }
}

private actor ProgressCounter {
    private var done = 0
    private let total: Int
    init(total: Int) { self.total = total }
    func increment() { done += 1 }
    var fraction: Double { Double(done) / Double(total) }
}
