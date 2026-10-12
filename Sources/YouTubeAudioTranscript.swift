import Foundation

/// On-device transcript for YouTube videos whose captions are missing or whose
/// transcript panel can't be read: fetches the smallest audio-only stream
/// through the same player client the frame pipeline uses and transcribes it
/// with Apple's SpeechAnalyzer. Nothing leaves the Mac besides the stream
/// download itself.
enum YouTubeAudioTranscript {

    enum Failure: LocalizedError {
        case noAudioStream, downloadFailed
        var errorDescription: String? {
            switch self {
            case .noAudioStream, .downloadFailed:
                return "This YouTube video has no captions, and its audio couldn't be downloaded for on-device transcription. Try again later."
            }
        }
    }

    /// Bytes requested per range call; YouTube throttles very large single reads.
    private static let rangeSize = 8 << 20
    /// Longest audio this fallback downloads (about 12 h of 48 kbps AAC).
    private static let maxBytes = 260 << 20

    static func transcribe(videoID: String, locale: Locale) async throws -> [TranscriptSegment] {
        let formats = try await fetchFormats(videoID: videoID)
        guard let audio = smallestAudio(in: formats.formats) else { throw Failure.noAudioStream }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("youty-audio-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: file) }
        try await download(audio.url, length: audio.length, userAgent: formats.userAgent, to: file)
        return try await SpeechTranscriptionPipeline.transcribe(audioURL: file, locale: locale)
            .map { TranscriptSegment(text: $0.text, timestamp: $0.timestamp) }
    }

    private static func fetchFormats(videoID: String) async throws -> StreamFetcher.FormatList {
        do {
            return try await StreamFetcher.fetchFormats(videoID: videoID,
                                                        visitorData: try await StreamFetcher.getVisitorData())
        } catch StreamFetchError.visitorDataInvalid {
            StreamFetcher.invalidateVisitorData()
            return try await StreamFetcher.fetchFormats(videoID: videoID,
                                                        visitorData: try await StreamFetcher.getVisitorData())
        }
    }

    /// The lowest-bitrate AAC (`audio/mp4`) stream with a direct URL and size.
    static func smallestAudio(in formats: [[String: Any]]) -> (url: URL, length: Int)? {
        formats.compactMap { format -> (url: URL, length: Int, bitrate: Int)? in
            guard (format["mimeType"] as? String)?.hasPrefix("audio/mp4") == true,
                  let raw = format["url"] as? String, let url = URL(string: raw),
                  let length = Int(format["contentLength"] as? String ?? ""),
                  length > 0, length <= maxBytes else { return nil }
            return (url, length, format["bitrate"] as? Int ?? .max)
        }
        .min { $0.bitrate < $1.bitrate }
        .map { ($0.url, $0.length) }
    }

    private static func download(_ url: URL, length: Int, userAgent: String, to file: URL) async throws {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var offset = 0
        while offset < length {
            let end = min(offset + rangeSize, length) - 1
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let complete = (status == 206 && data.count == end - offset + 1)
                || (status == 200 && offset == 0 && data.count == length)
            guard complete else { throw Failure.downloadFailed }
            try handle.write(contentsOf: data)
            offset += data.count
        }
    }
}
