import Foundation
import SwiftUI
import AppKit

// Single source of truth for "a URL just arrived from somewhere — go save it."
//
// Phase L surfaces (Share Sheet, Services menu, AppIntents, menu bar paste,
// youty:// URL scheme) all call `IngestionFunnel.shared.ingest(...)`, which
// dispatches the URL to ContentView via `@Published var inboxURL`.
//
// Cross-process surfaces (the Share Extension) reach us via the youty://
// URL scheme — the URL appears in the query string and is delivered by
// macOS LaunchServices to YoutyApp's `.onOpenURL` handler, which calls
// `ingest(...)`. No shared file system or App Group is required: the
// URL-scheme delivery is atomic and durable through app cold starts.
//
// Internal queueing: we serialize multiple inbound URLs through a small
// in-memory FIFO. WKWebView and the YouTube fetcher don't survive
// concurrent attaches, so we only let one URL go through fetch+save at a
// time. Extras land in the queue and resume as each finishes.

@MainActor
final class IngestionFunnel: ObservableObject {

    /// The URL ContentView should currently be fetching + saving. Cleared
    /// by `didFinishSave()` once that save settles.
    @Published var inboxURL: URL?

    /// Monotonic marker — ContentView watches this to detect a fresh
    /// dispatch even when the same URL arrives twice in a row.
    @Published var dispatchID: Int = 0

    /// Source of the most recent dispatch — used by ContentView to show a
    /// small "from Share Sheet" / "from Shortcuts" pill.
    @Published private(set) var lastSource: String = ""

    static let shared = IngestionFunnel()

    private struct Pending: Equatable {
        let url: URL
        let source: String
    }

    private var queue: [Pending] = []
    private var processing = false

    /// Enqueue a URL and (if idle) immediately dispatch it. Called by every
    /// Phase L surface that lives inside the main app, plus the URL-scheme
    /// handler that fields youty:// opens from the Share Extension and
    /// AppIntent.
    func ingest(urlString: String, source: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return }
        // Idempotent against rapid duplicates — Share-then-also-paste, or a
        // double-click on a Shortcut.
        if queue.contains(where: { $0.url == url }) { return }
        if let current = inboxURL, current == url { return }
        NSLog("[youty] ingest source=%@ url=%@", source, trimmed)
        // Sentinel for the headless E2E test (`--phase-l-e2e-check`). A
        // tiny dictionary in UserDefaults proves the URL-scheme / Services
        // / Share Extension / AppIntent surface actually reached the
        // funnel after the system delivered an event. Harmless in
        // production — UserDefaults writes are cheap.
        UserDefaults.standard.set([
            "url": trimmed,
            "source": source,
            "at": ISO8601DateFormatter().string(from: Date()),
        ], forKey: "phaseLProbe.lastIngest")
        queue.append(Pending(url: url, source: source))
        // Activate the main app so the save UI is visible — except for the
        // menu bar surface, where the user explicitly wants the save to
        // run silently in the background without losing their current
        // focus context. The save still runs in the existing main-app
        // pipeline; nothing is skipped, just no window steal.
        if source != "menubar" {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        pump()
    }

    /// Called by ContentView after a save attempt settles (successfully or
    /// not). Lets the next queued URL start.
    func didFinishSave() {
        processing = false
        inboxURL = nil
        pump()
    }

    // MARK: - Internal pump

    private func pump() {
        guard !processing, let next = queue.first else { return }
        queue.removeFirst()
        processing = true
        lastSource = next.source
        dispatchID &+= 1
        inboxURL = next.url
    }

    // MARK: - For tests / harness

    /// Returns whether the funnel has an active save in flight or items
    /// waiting. Used by `--phase-l-probe` in DebugRunner.
    var hasWork: Bool { processing || !queue.isEmpty }
}
