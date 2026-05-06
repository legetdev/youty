import Foundation
import AppKit

@MainActor
final class VaultManager: NSObject, ObservableObject {

    enum FrameState: Equatable {
        case idle
        case downloading(Double)
        case extracting
        case done
        case failed(String)
    }

    private let bookmarkKey = "vaultBookmark"

    @Published var vaultURL: URL?
    @Published var frameState: FrameState = .idle

    override init() {
        super.init()
        loadBookmark()
    }

    func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder for Youty notes"
        panel.prompt = "Select"
        if panel.runModal() == .OK {
            vaultURL = panel.url
            saveBookmark()
        }
    }

    // Writes the .md note instantly. Returns the vault URL for background frame use.
    @discardableResult
    func saveNote(result: FetchResult, metadata: VideoMetadata) throws -> URL {
        guard let vault = vaultURL else { throw VaultError.noVault }
        guard vault.startAccessingSecurityScopedResource() else { throw VaultError.accessDenied }
        defer { vault.stopAccessingSecurityScopedResource() }

        let noteURL = vault.appendingPathComponent(noteFilename(metadata: metadata))
        try composeNote(metadata: metadata, segments: result.segments)
            .write(to: noteURL, atomically: true, encoding: .utf8)
        return vault
    }

    // Fires after saveNote. Downloads video, extracts frames, writes to vault. Fully background.
    func extractFramesInBackground(videoID: String, streamURL: URL) {
        frameState = .downloading(0)
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            do {
                let tempVideo = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(videoID).mp4")

                try await self.downloadFile(from: streamURL, to: tempVideo) { p in
                    Task { @MainActor in self.frameState = .downloading(p) }
                }

                await MainActor.run { self.frameState = .extracting }
                let frames = try await FrameExtractor.extract(from: tempVideo)

                guard let vault = await self.vaultURL else { return }
                guard vault.startAccessingSecurityScopedResource() else { return }
                defer { vault.stopAccessingSecurityScopedResource() }

                let framesDir = vault.appendingPathComponent(videoID)
                try FileManager.default.createDirectory(at: framesDir,
                                                        withIntermediateDirectories: true)
                for frame in frames {
                    let name = String(format: "%04d.jpg", Int(frame.timestamp))
                    if let data = frame.image.jpegData(compressionQuality: 0.82) {
                        try? data.write(to: framesDir.appendingPathComponent(name))
                    }
                }

                try? FileManager.default.removeItem(at: tempVideo)
                await MainActor.run { self.frameState = .done }

            } catch {
                let msg = error.localizedDescription
                await MainActor.run { self.frameState = .failed(msg) }
            }
        }
    }

    // MARK: - Filename

    private func noteFilename(metadata: VideoMetadata) -> String {
        let channel = sanitize(metadata.channel)
        let title   = sanitize(metadata.title)
        let name    = channel.isEmpty ? title : "\(channel) - \(title)"
        return name.isEmpty ? "\(metadata.videoID).md" : "\(name).md"
    }

    // Strip filesystem-unsafe characters, collapse whitespace, truncate to 80 chars.
    private func sanitize(_ s: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = s.unicodeScalars
            .filter { !forbidden.contains($0) }
            .map { Character($0) }
        let collapsed = String(cleaned)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(collapsed.prefix(80)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Note composition

    private func composeNote(metadata: VideoMetadata, segments: [TranscriptSegment]) -> String {
        let tags = metadata.tags.map { "\"\($0)\"" }.joined(separator: ", ")

        var lines: [String] = [
            "---",
            "title: \"\(metadata.title)\"",
            "video_id: \(metadata.videoID)",
            "url: https://www.youtube.com/watch?v=\(metadata.videoID)",
            "channel: \"\(metadata.channel)\"",
            "duration: \"\(formatDuration(metadata.durationSeconds))\"",
            "date_saved: \(metadata.dateSaved)",
            "tags: [\(tags)]",
            "frames_dir: \(metadata.videoID)/",
            "---", ""
        ]

        if !metadata.shortDescription.isEmpty {
            lines += ["## Description", "", metadata.shortDescription, ""]
        }

        if !metadata.youtubeSummary.isEmpty {
            lines += ["## Summary", "", metadata.youtubeSummary, ""]
        }

        lines += ["## Transcript", ""]
        for seg in segments {
            lines.append("[\(seg.timestamp)] \(seg.text)")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Helpers

    private func formatDuration(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }

    private func downloadFile(from url: URL, to dest: URL,
                              progress: @escaping (Double) -> Void) async throws {
        let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)
        let total = response.expectedContentLength
        var received: Int64 = 0
        var buffer = Data()

        for try await byte in asyncBytes {
            buffer.append(byte)
            received += 1
            if buffer.count >= 65536 {
                try buffer.write(to: dest, options: .atomic)
                buffer.removeAll(keepingCapacity: true)
            }
            if total > 0 { progress(Double(received) / Double(total)) }
        }
        if !buffer.isEmpty { try buffer.write(to: dest, options: .atomic) }
    }

    private func saveBookmark() {
        guard let url = vaultURL,
              let data = try? url.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) else { return }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    private func loadBookmark() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        vaultURL = try? URL(resolvingBookmarkData: data,
                            options: .withSecurityScope,
                            relativeTo: nil,
                            bookmarkDataIsStale: &stale)
    }
}

enum VaultError: LocalizedError {
    case noVault, accessDenied
    var errorDescription: String? {
        switch self {
        case .noVault:      return "No vault folder selected."
        case .accessDenied: return "Could not access the selected folder."
        }
    }
}
