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

/// Which embedder turns transcript text into vectors for AI search.
///
/// `.local` runs Core ML EmbeddingGemma entirely on-device — no API key,
/// nothing leaves the Mac — and is the default (Phase S). `.gemini` is the
/// opt-in cloud path (a small accuracy gain) and needs a Gemini API key.
///
/// The raw value persists under `@AppStorage("embeddingProvider")`. The
/// background `Indexer` is not `@MainActor`, so it reads the choice through
/// `EmbeddingProvider.current` — a plain, thread-safe UserDefaults lookup.
enum EmbeddingProvider: String, CaseIterable, Sendable {
    case local
    case gemini

    /// The string written to `chunks.model_version` and
    /// `index_meta.current_text_model`, so the MCP query side can match the
    /// embedding space the documents were written in.
    var modelIdentifier: String {
        switch self {
        case .local:  return "embeddinggemma-300m@768"
        case .gemini: return "gemini-embedding-001@768"
        }
    }

    /// UserDefaults / @AppStorage key — one source of truth for SwiftUI + Indexer.
    static let defaultsKey = "embeddingProvider"

    /// The persisted choice, readable off the main actor. Defaults to
    /// `.local` (the key-free path) when unset or hand-edited to garbage.
    static var current: EmbeddingProvider {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? local.rawValue
        return EmbeddingProvider(rawValue: raw) ?? .local
    }
}

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

    /// Which embedder indexes transcript text. Default `.local` (on-device,
    /// no key). Stored as the raw `EmbeddingProvider` value; the validated
    /// `embeddingProvider` accessor below clamps stray values back to `.local`.
    @AppStorage(EmbeddingProvider.defaultsKey) var embeddingProviderRaw: String = EmbeddingProvider.local.rawValue

    var embeddingProvider: EmbeddingProvider {
        get { EmbeddingProvider(rawValue: embeddingProviderRaw) ?? .local }
        set { embeddingProviderRaw = newValue.rawValue }
    }

    // MARK: - Menu bar (Phase L)

    /// When true, Youty installs a small NSStatusBar icon. Click it for a
    /// popover with a paste field + recent saves. Default off — power-user
    /// surface only.
    @AppStorage("menuBarEnabled") var menuBarEnabled: Bool = false

    // MARK: - Onboarding (R.2)

    /// First-launch flag. When false, the OnboardingView appears as a
    /// sheet over ContentView so the user can pick a vault and (optionally)
    /// hook up the Gemini key, the CLI, and the MCP server. The four cards
    /// stay reachable any time from Settings → Onboarding.
    @AppStorage("onboardingComplete") var onboardingComplete: Bool = false

    /// Set when the user presses the "Copy + open Terminal" button on the
    /// CLI onboarding card. We can't directly observe whether they pasted
    /// + ran the command, so this is a "user-acknowledged" flag, not a
    /// "definitely installed" one — enough to stop nagging without
    /// pretending we know more than we do.
    @AppStorage("onboardingCLIDone") var onboardingCLIDone: Bool = false

    /// Same shape as `onboardingCLIDone` for the MCP server card.
    @AppStorage("onboardingMCPDone") var onboardingMCPDone: Bool = false

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

    static let embeddingProviderOptions: [Option<String>] = [
        Option(label: "On-device", value: EmbeddingProvider.local.rawValue),
        Option(label: "Gemini",    value: EmbeddingProvider.gemini.rawValue),
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
