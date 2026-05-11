import Foundation

// Shared types for frame extraction pipelines.
//
// ContentView depends only on this file's protocol + types. Each concrete
// pipeline (CanvasFramePipeline, FastFramePipeline) is a separate file and
// can be swapped in/out independently.

enum FrameStage {
    case loading              // initial setup (page load for canvas, format fetch for fast)
    case downloading(Double)  // fast-path MP4 download (0..1)
    case extracting(Double)   // capturing/streaming frames, progress 0..1
    case writing              // writing JPEGs to vault folder
}

enum FramePipelineOutcome {
    case success(framesWritten: Int, durationMs: Int, mode: String)
    // canFallback=true means UI should offer the canvas fallback button.
    // canFallback=false means we already tried everything and there's no recourse.
    case failed(reason: String, canFallback: Bool)
}

@MainActor
protocol FramePipeline: AnyObject {
    func extract(videoID: String,
                 folderURL: URL,
                 stage: @escaping (FrameStage) -> Void) async -> FramePipelineOutcome
}

// Hard timeout for any throwing async operation.
// Racing two tasks; whichever finishes first wins, the other is cancelled.
func withTimeout<T: Sendable>(seconds: TimeInterval,
                              _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

struct TimeoutError: Error {}
