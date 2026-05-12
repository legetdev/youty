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

    // MARK: - Frame density

    /// Maximum number of frames per save. Capped at the picked value; the
    /// per-second cap below may limit further.
    @AppStorage("frameCountCap") var frameCountCap: Int = 100

    /// Maximum sampling rate in frames per second. Stored as Double so it
    /// can be passed straight into FrameExtractor.frameTimes without casts.
    @AppStorage("fpsCap") var fpsCapStored: Double = 2.0

    /// Wrapper that clamps the stored value to the four supported options
    /// in case UserDefaults got hand-edited or migrated from another version.
    var fpsCap: Double {
        get {
            let allowed = Self.fpsOptions.map(\.value)
            return allowed.contains(fpsCapStored) ? fpsCapStored : 2.0
        }
        set { fpsCapStored = newValue }
    }

    // MARK: - Transcription

    /// "auto" → use Locale.current; otherwise a BCP-47 identifier
    /// (e.g. "en-US", "de-DE"). SpeechTranscriber.supportedLocale(equivalentTo:)
    /// handles fallback when the exact identifier isn't installed.
    @AppStorage("transcriptionLocale") var transcriptionLocaleIdentifier: String = "auto"

    // MARK: - Picker options (single source of truth)

    struct Option<Value: Hashable>: Hashable {
        let label: String
        let value: Value
    }

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
