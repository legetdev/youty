import Foundation
import Combine

// Process-wide, observable index-state store.
//
// Tracks which saved bundles are currently being indexed in the background
// (transcript embed on-device + frame embed via SigLIP) and which have
// finished. The in-app saved-video row and the menu bar item both observe
// this store so the user always knows whether a freshly-saved video is
// fully searchable yet.
//
// Indexing runs as a fire-and-forget Task.detached after the bundle lands
// on disk — keyed by the bundle folder URL so we can support several saves
// queued up in parallel without confusion.

@MainActor
final class IndexStatusStore: ObservableObject {

    static let shared = IndexStatusStore()

    enum State: Equatable {
        case indexing
        case indexed
        case failed(String)
    }

    struct Entry: Identifiable, Equatable {
        let id: String           // folder.path — stable across the bundle lifetime
        let folder: URL
        var state: State
        var finishedAt: Date?
    }

    @Published private(set) var entries: [String: Entry] = [:]

    // True while any bundle is currently mid-index. The menu bar button
    // reads this to decide whether to overlay its progress dot.
    var isAnyIndexing: Bool {
        entries.values.contains { $0.state == .indexing }
    }

    // Begin tracking a bundle. Called from triggerIndexer right before the
    // background task launches, so the badge appears the moment indexing
    // starts (not after the first round-trip lands).
    func begin(folder: URL) {
        let key = folder.path
        entries[key] = Entry(id: key, folder: folder, state: .indexing, finishedAt: nil)
    }

    func markIndexed(folder: URL) {
        let key = folder.path
        guard var entry = entries[key] else { return }
        entry.state = .indexed
        entry.finishedAt = Date()
        entries[key] = entry
    }

    func markFailed(folder: URL, reason: String) {
        let key = folder.path
        guard var entry = entries[key] else { return }
        entry.state = .failed(reason)
        entry.finishedAt = Date()
        entries[key] = entry
    }

    func state(for folder: URL) -> State? {
        entries[folder.path]?.state
    }
}
