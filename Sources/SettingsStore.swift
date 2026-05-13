import SwiftUI
import Foundation

// User-visible preferences that affect saved-bundle output.
//
// Persisted in NSUserDefaults via @AppStorage so a setting picked in the
// Settings sheet survives app relaunches without any explicit save.
//
// Used by:
//   • FastFramePipeline (YouTube) — passes the density values into
//     FrameExtractor.frameTimes when computing the timestamp array.
//   • ShortFormPipeline (IG / TikTok) — same.
//   • SpeechTranscriptionPipeline — reads transcriptionLocaleIdentifier to
//     decide which language model to use on the audio track.

@MainActor
final class SettingsStore: ObservableObject {

    // MARK: - Resolution

    /// Target source resolution (long-edge short side, in pixels). When the
    /// source offers this exact resolution we use it; otherwise we pick the
    /// highest available ≤ target (never silently jumping to a much-lower
    /// rung), and only fall back to the lowest available > target when
    /// nothing at-or-below the target exists. Saved frames are always at the
    /// picked source's native resolution — never upscaled.
    @AppStorage("targetResolution") var targetResolutionStored: Int = 1080

    /// Validated accessor. Clamps to one of the four supported options in
    /// case UserDefaults got hand-edited or migrated from another version.
    var targetResolution: Int {
        get {
            let allowed = Self.resolutionOptions.map(\.value)
            return allowed.contains(targetResolutionStored) ? targetResolutionStored : 1080
        }
        set { targetResolutionStored = newValue }
    }

    // MARK: - Frame density

    /// Maximum number of frames per save. Capped at the picked value; the
    /// per-second cap below may limit further.
    @AppStorage("frameCountCap") var frameCountCap: Int = 100

    /// Maximum sampling rate in frames per second. Stored as Double so it
    /// can be passed straight into FrameExtractor.frameTimes without casts.
    @AppStorage("fpsCap") var fpsCapStored: Double = 1.0

    /// Wrapper that clamps the stored value to the four supported options
    /// in case UserDefaults got hand-edited or migrated from another version.
    var fpsCap: Double {
        get {
            let allowed = Self.fpsOptions.map(\.value)
            return allowed.contains(fpsCapStored) ? fpsCapStored : 1.0
        }
        set { fpsCapStored = newValue }
    }

    // MARK: - Transcription

    /// "auto" → use Locale.current; otherwise a BCP-47 identifier
    /// (e.g. "en-US", "de-DE"). SpeechTranscriber.supportedLocale(equivalentTo:)
    /// handles fallback when the exact identifier isn't installed.
    @AppStorage("transcriptionLocale") var transcriptionLocaleIdentifier: String = "auto"

    // MARK: - Indexer (Phase B)

    /// Master toggle. When false, the background indexer hook in ContentView
    /// skips entirely — capture stays anonymous + offline.
    @AppStorage("indexerEnabled") var indexerEnabled: Bool = true

    /// Identifier of the embedding model. Mirrors `chunks.model_version`
    /// in the SQLite index so the Python MCP server can match.
    @AppStorage("embeddingModelID") var embeddingModelID: String = "gemini-embedding-001@768"

    // MARK: - Picker options (single source of truth)

    struct Option<Value: Hashable>: Hashable {
        let label: String
        let value: Value
    }

    static let resolutionOptions: [Option<Int>] = [
        Option(label: "720p",  value: 720),
        Option(label: "1080p", value: 1080),
        Option(label: "1440p", value: 1440),
        Option(label: "2160p", value: 2160),
    ]

    static let frameCountOptions: [Option<Int>] = [
        Option(label: "50",  value: 50),
        Option(label: "100", value: 100),
        Option(label: "250", value: 250),
        Option(label: "500", value: 500),
    ]

    static let fpsOptions: [Option<Double>] = [
        Option(label: "1 fps", value: 1.0),
        Option(label: "2 fps", value: 2.0),
        Option(label: "3 fps", value: 3.0),
        Option(label: "5 fps", value: 5.0),
    ]

    /// Locale picker. "auto" reads `Locale.current`; the rest are explicit
    /// BCP-47 identifiers that Apple's on-device SpeechTranscriber supports
    /// on macOS 26 (empirically verified). Excludes Russian, Arabic, Hindi,
    /// Dutch, Turkish, Polish, Swedish — none are in
    /// `SpeechTranscriber.supportedLocales` on macOS 26.2 (Apple has not
    /// shipped on-device models for them yet). Showing them would set the
    /// user up for a confusing "speech model unavailable" error on first
    /// save.
    static let localeOptions: [Option<String>] = [
        Option(label: "Auto (system language)", value: "auto"),
        Option(label: "English (US)",           value: "en-US"),
        Option(label: "English (UK)",           value: "en-GB"),
        Option(label: "German",                  value: "de-DE"),
        Option(label: "Spanish (Spain)",         value: "es-ES"),
        Option(label: "Spanish (Mexico)",        value: "es-MX"),
        Option(label: "French",                  value: "fr-FR"),
        Option(label: "Italian",                 value: "it-IT"),
        Option(label: "Portuguese (Brazil)",     value: "pt-BR"),
        Option(label: "Portuguese (Portugal)",   value: "pt-PT"),
        Option(label: "Japanese",                value: "ja-JP"),
        Option(label: "Korean",                  value: "ko-KR"),
        Option(label: "Chinese (Simplified)",    value: "zh-CN"),
        Option(label: "Chinese (Traditional)",   value: "zh-TW"),
    ]

    // MARK: - Convenience: resolve transcription locale to a Locale value

    /// Returns the Locale the speech pipeline should use. "auto" maps to
    /// `Locale.current`; otherwise the picked identifier.
    func resolvedTranscriptionLocale() -> Locale {
        if transcriptionLocaleIdentifier == "auto" {
            return Locale.current
        }
        return Locale(identifier: transcriptionLocaleIdentifier)
    }
}
