import Foundation
import AVFoundation
import Speech
import CoreMedia

// On-device speech transcription for Instagram + TikTok flows.
//
// Wraps Apple's SpeechAnalyzer + SpeechTranscriber (macOS 26+) into a single
// async function: pass an audio file URL, get back [TranscriptSegment] with
// millisecond-precision timestamps formatted as the existing transcript
// contract expects.
//
// Why these APIs (not SFSpeechRecognizer):
//   SFSpeechRecognizer's SFTranscriptionSegment.timestamp is broken on long
//   audio — timestamps reset to 0 mid-file. Apple's new SpeechAnalyzer +
//   SpeechTranscriber emit sample-accurate CMTime ranges per result, which
//   is what we need to anchor transcript lines to frame JPEGs.
//
// On-device guarantee: the entire flow runs locally. Models are system assets
// downloaded once via AssetInventory; audio never leaves the device.
//
// Per-platform timestamp format choice:
//   Returns segments using "[M:SS.mmm]" / "[H:MM:SS.mmm]" precision (the
//   shared cross-platform contract). YouTube continues to use coarser
//   "[M:SS]" since its transcript is scraped from YouTube's already-formatted
//   caption panel.

enum SpeechTranscriptionError: LocalizedError {
    case audioFileOpenFailed(URL, underlying: Error)
    case localeNotSupported(Locale)
    case modelInstallFailed(Error)
    case analysisFailed(Error)

    var errorDescription: String? {
        switch self {
        case .audioFileOpenFailed:
            return "Couldn't open the downloaded audio for transcription. The save will still complete without a transcript."
        case .localeNotSupported(let locale):
            return "Your Mac doesn't have an on-device speech model for \(locale.identifier). Pick a different language in Settings → Transcription language, or wait for macOS to download the model."
        case .modelInstallFailed:
            return "Couldn't download the on-device speech model. Check your internet connection and try again."
        case .analysisFailed:
            return "On-device speech recognition couldn't process this audio. The save will still complete without a transcript."
        }
    }
}

enum SpeechTranscriptionPipeline {

    /// Transcribes a local audio file into a list of timestamped segments.
    ///
    /// - Parameters:
    ///   - audioURL: a sandbox-readable file URL pointing at the audio track
    ///     (any container `AVAudioFile` accepts — `.m4a`, `.mp4`, `.wav`,
    ///     `.aac` etc.).
    ///   - locale: language for transcription. Default `Locale.current`; the
    ///     pipeline falls back to `en-US` if `Locale.current` isn't in
    ///     SpeechTranscriber.supportedLocales (most non-Latin locales on
    ///     macOS 26 are still in rollout).
    ///   - progress: optional callback fired with a `Progress` while a
    ///     first-time model download is in flight. UI can show indeterminate
    ///     spinner that flips to determinate once the Progress sets a total.
    /// - Returns: segments in ascending PTS order. Empty array on silent
    ///   audio (which is legitimate, e.g. music-only Reels).
    static func transcribe(
        audioURL: URL,
        locale: Locale = .current,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> [TranscriptSegment] {

        // 1. Pick the closest supported locale. Many users will be on
        //    de-DE, en-GB etc.; SpeechTranscriber accepts an equivalence
        //    lookup that maps regional variants to the installed model.
        let resolvedLocale = await resolveLocale(preferred: locale)
        guard let resolved = resolvedLocale else {
            throw SpeechTranscriptionError.localeNotSupported(locale)
        }
        DebugLog.log("speech: locale resolved \(locale.identifier) → \(resolved.identifier)")

        // 2. Build the transcriber. We explicitly drop `.volatileResults`
        //    from reporting (we only want final phrases — volatile results
        //    fire cumulatively with range.start = 0, which produces the
        //    "everything-at-0:00" timestamp bug). `.audioTimeRange` in
        //    attribute options preserves the per-phrase `range` CMTimeRange.
        let transcriber = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        // 3. Make sure the model is installed. First call on a fresh Mac
        //    triggers a system asset download — surface progress to the UI.
        if let installer = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            DebugLog.log("speech: model download requested for \(resolved.identifier)")
            progress?(installer.progress)
            do {
                try await installer.downloadAndInstall()
            } catch {
                throw SpeechTranscriptionError.modelInstallFailed(error)
            }
        }

        // 4. Open the audio file. AVAudioFile handles any container the
        //    system understands (m4a / aac / mp4 / wav).
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: audioURL)
        } catch {
            throw SpeechTranscriptionError.audioFileOpenFailed(audioURL, underlying: error)
        }

        // 5. Run the analyzer. `finishAfterFile: true` makes the analyzer
        //    complete cleanly when EOF is hit; we then drain the results
        //    AsyncSequence.
        let analyzer: SpeechAnalyzer
        do {
            analyzer = try await SpeechAnalyzer(
                inputAudioFile: audioFile,
                modules: [transcriber],
                finishAfterFile: true
            )
        } catch {
            throw SpeechTranscriptionError.analysisFailed(error)
        }

        // 6. Collect finalised segments. SpeechTranscriber emits both
        //    volatile (in-progress) and final results; we keep finals only.
        var segments: [TranscriptSegment] = []
        do {
            for try await result in transcriber.results {
                let plain = String(result.text.characters[...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !plain.isEmpty else { continue }
                let stamp = formatTimestamp(seconds: result.range.start.seconds)
                segments.append(TranscriptSegment(text: plain, timestamp: stamp))
            }
        } catch {
            throw SpeechTranscriptionError.analysisFailed(error)
        }

        // Make sure the analyzer's last writes have settled.
        _ = try? await analyzer.finalizeAndFinishThroughEndOfInput()
        DebugLog.log("speech: produced \(segments.count) segments from \(audioURL.lastPathComponent)")
        return segments
    }

    // MARK: - Locale resolution

    private static func resolveLocale(preferred: Locale) async -> Locale? {
        // Exact match first.
        let supported = await SpeechTranscriber.supportedLocales
        if supported.contains(where: { $0.identifier == preferred.identifier }) {
            return preferred
        }
        // Equivalence lookup (e.g. de-AT → de-DE, en-CA → en-US).
        if let equiv = await SpeechTranscriber.supportedLocale(equivalentTo: preferred) {
            return equiv
        }
        // Last-resort fallback: en-US, which Apple ships on every macOS 26 device.
        if supported.contains(where: { $0.identifier == "en-US" }) {
            return Locale(identifier: "en-US")
        }
        return supported.first
    }

    // MARK: - Timestamp formatting

    /// Formats seconds into "[M:SS.mmm]" under one hour, "[H:MM:SS.mmm]" over.
    /// Matches the shared cross-platform timestamp contract.
    static func formatTimestamp(seconds: Double) -> String {
        let safe = max(0, seconds.isFinite ? seconds : 0)
        let totalMs = Int((safe * 1000).rounded())
        let h = totalMs / 3_600_000
        let m = (totalMs / 60_000) % 60
        let s = (totalMs / 1000) % 60
        let ms = totalMs % 1000
        if h > 0 {
            return String(format: "%d:%02d:%02d.%03d", h, m, s, ms)
        } else {
            return String(format: "%d:%02d.%03d", m, s, ms)
        }
    }
}
