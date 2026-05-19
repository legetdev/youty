import SwiftUI
import AppKit

// Settings sheet. Hosts the user-visible preferences that affect saved
// bundles: vault location, frame-density caps, transcription language.
//
// Liquid-glass aesthetic — translucent HUD-style window with the same
// material treatment as the rest of the app.

struct SettingsView: View {

    @ObservedObject var settings: SettingsStore
    @ObservedObject var vault: VaultManager
    let onDismiss: () -> Void

    @StateObject private var indexerProgress = IndexerProgress()
    @State private var apiKeyInput: String = ""
    @State private var apiKeyStored: Bool = KeychainHelper.exists(account: "youty", service: "gemini-api")
    @State private var apiKeyMessage: String?

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                header

                vaultSection
                Divider().opacity(0.35)

                resolutionSection
                Divider().opacity(0.35)

                frameSection
                Divider().opacity(0.35)

                languageSection
                Divider().opacity(0.35)

                indexerSection
                Divider().opacity(0.35)

                integrationsSection
                Divider().opacity(0.35)

                aboutSection
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close settings")
        }
    }

    // MARK: - Vault

    private var vaultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Vault")
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                if let url = vault.vaultURL {
                    Text(url.lastPathComponent)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No vault yet — pick a folder to start saving.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(vault.vaultURL == nil ? "Choose…" : "Change…") {
                    vault.chooseVault()
                }
                .controlSize(.regular)
                .accessibilityLabel(vault.vaultURL == nil ? "Choose vault folder" : "Change vault folder")
                .accessibilityHint("Pick the folder where saved videos will be stored")
            }
            if let url = vault.vaultURL {
                Text(url.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Every saved video lands in this folder. Pick anywhere — Documents, iCloud Drive, an external drive, whatever you like.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Resolution

    private var resolutionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Resolution")
            Picker("", selection: $settings.targetResolutionStored) {
                ForEach(SettingsStore.resolutionOptions, id: \.value) { opt in
                    Text(opt.label).tag(opt.value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Source resolution")
            .accessibilityHint("Pick the highest resolution Youty should try to fetch")

            Text(resolutionHint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var resolutionHint: String {
        let r = settings.targetResolution
        return "Saves at \(r)p when the source offers it. Otherwise the highest available below \(r)p — never upscaled."
    }

    // MARK: - Frame density

    private var frameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Frame density")
            HStack(spacing: 16) {
                pickerColumn("Frames per save",
                              selection: $settings.frameCountCap,
                              options: SettingsStore.frameCountOptions)
                pickerColumn("Max frames / second",
                              selection: $settings.fpsCapStored,
                              options: SettingsStore.fpsOptions)
            }
            Text(densityHint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Inline preview of what the current pair will produce on a "typical"
    /// 30-second short and a 10-minute talk — gives the user immediate
    /// feedback on how the two caps interact.
    private var densityHint: String {
        let cap = settings.frameCountCap
        let fps = settings.fpsCap
        func framesFor(_ s: Double) -> Int {
            min(cap, max(1, Int(floor(s * fps))))
        }
        let short = framesFor(30)
        let medium = framesFor(600)
        return "Examples: a 30-second clip → \(short) frames, a 10-minute video → \(medium) frames."
    }

    // MARK: - Language

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Transcription language")
            Picker("", selection: $settings.transcriptionLocaleIdentifier) {
                ForEach(SettingsStore.localeOptions, id: \.value) { opt in
                    Text(opt.label).tag(opt.value)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Transcription language")
            .accessibilityHint("Language Apple's on-device speech model uses for Instagram and TikTok transcripts")

            Text("Used by Instagram and TikTok. YouTube transcripts are scraped directly from the platform.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - AI search index (Phase B)

    private var indexerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("AI search index")

            Text("Optional. Lets Claude / Cursor / any MCP-compatible AI search your saved videos by meaning, not just keyword. Your vault stays local — only the transcript text is sent to Gemini, and only with the API key you provide below. Re-indexing also rebuilds the on-device frame vectors used for visual search.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $settings.indexerEnabled) {
                Text("Index new saves automatically")
                    .font(.system(size: 13))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityHint("When on, every saved video is embedded into the local search index so AI tools can find it by meaning")

            // API key field. Reads + writes Keychain at account=youty,
            // service=gemini-api so the value is never serialised to disk
            // outside the system keychain.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: apiKeyStored ? "checkmark.seal.fill" : "key.fill")
                        .foregroundStyle(apiKeyStored ? .green : .secondary)
                        .font(.system(size: 12))
                    Text(apiKeyStored ? "Gemini API key stored in Keychain" : "Add a Gemini API key to enable search")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                HStack(spacing: 8) {
                    SecureField(apiKeyStored ? "Enter a new key to replace…" : "Paste your Gemini API key",
                                 text: $apiKeyInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                        )
                        .accessibilityLabel("Gemini API key")
                        .accessibilityHint("Paste your key from aistudio.google.com — stored only on this Mac")
                    Button("Save") { saveAPIKey() }
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        .controlSize(.small)
                        .accessibilityLabel("Save API key")
                }
                if let msg = apiKeyMessage {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text("Free tier covers a few thousand videos.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Link("Get a key →", destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                        .font(.system(size: 11))
                }
            }

            // Model picker — only one option for now, but the surface is in
            // place so swapping in Voyage / on-device BGE stays one line.
            VStack(alignment: .leading, spacing: 6) {
                Text("Embedding model")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Picker("", selection: $settings.embeddingModelID) {
                    Text("Gemini Embedding 001 (768d)").tag("gemini-embedding-001@768")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel("Embedding model")
            }

            // Re-index action.
            HStack(spacing: 10) {
                Button {
                    runReindex()
                } label: {
                    HStack(spacing: 6) {
                        if indexerProgress.isRunning {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(indexerProgress.isRunning ? "Indexing…" : "Re-index entire vault")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .controlSize(.regular)
                .disabled(indexerProgress.isRunning || vault.vaultURL == nil)
                .accessibilityLabel(indexerProgress.isRunning ? "Indexing in progress" : "Re-index entire vault")
                .accessibilityHint("Re-embeds every saved video into the local search index")

                Spacer()
            }

            if let status = indexerProgress.lastStatus {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            indexStatsBlock

            Text("The index lives outside your vault. You can rebuild it any time without losing saved videos.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { indexerProgress.refreshStats() }
    }

    /// Read-only status block at the bottom of the AI search index section.
    /// Mirrors the count breakdown shown by the headless `--reindex` probe,
    /// so a glance here tells the user exactly what their AI sees.
    @ViewBuilder
    private var indexStatsBlock: some View {
        if let s = indexerProgress.stats {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("\(s.videoCount) videos · \(s.chunkCount) chunks" +
                         (s.frameCount > 0 ? " · \(s.frameCount) frame vectors" : "") +
                         "  ·  \(formatBytes(s.dbBytes)) on disk")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let lastMs = s.lastRebuildMs {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text("Last full reindex: \(formatRelativeTime(unixMs: lastMs))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                if let model = s.textModelID {
                    HStack(spacing: 6) {
                        Image(systemName: "cpu")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text("Text model: \(model)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private func saveAPIKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try KeychainHelper.write(trimmed, account: "youty", service: "gemini-api")
            apiKeyInput = ""
            apiKeyStored = true
            apiKeyMessage = "Key saved. New saves will be indexed automatically."
        } catch {
            apiKeyMessage = "Couldn't save key. \(error.localizedDescription)"
        }
    }

    private func runReindex() {
        guard let vaultURL = vault.vaultURL else { return }
        indexerProgress.isRunning = true
        indexerProgress.lastStatus = "Starting…"
        Task.detached {
            let acquired = vaultURL.startAccessingSecurityScopedResource()
            defer { if acquired { vaultURL.stopAccessingSecurityScopedResource() } }
            do {
                let summary = try await Indexer.reindexVault(vaultRoot: vaultURL) { line in
                    Task { @MainActor in
                        self.indexerProgress.lastStatus = line
                    }
                }
                let line = "Indexed \(summary.videosIndexed) video(s), \(summary.chunksWritten) chunks in \(summary.totalMs)ms" +
                           (summary.framesKept > 0 ? " · \(summary.framesKept) frames" : "") +
                           (summary.videosDeleted > 0 ? " · \(summary.videosDeleted) removed" : "") +
                           (summary.failures.isEmpty ? "" : " — \(summary.failures.count) failed")
                await MainActor.run {
                    self.indexerProgress.lastStatus = line
                    self.indexerProgress.isRunning = false
                    self.indexerProgress.refreshStats()
                }
            } catch {
                await MainActor.run {
                    self.indexerProgress.lastStatus = "Failed: \(error.localizedDescription)"
                    self.indexerProgress.isRunning = false
                }
            }
        }
    }

    // MARK: - Integrations (Phase L)

    /// macOS-native surface multipliers — toggles for the optional ones.
    /// Share Sheet + Services + AppIntents are always on (they surface
    /// automatically once the app is launched, and they aren't intrusive).
    /// The menu bar item is the only one that adds a visible element to
    /// the system UI, so it's opt-in.
    private var integrationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Integrations")

            Toggle(isOn: $settings.menuBarEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show in menu bar")
                        .font(.system(size: 13))
                    Text("Adds a tray icon for paste-and-save without bringing the main window forward.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel("Show in menu bar")
            .accessibilityHint("When on, a small tray icon lets you save URLs without opening the main window")

            Text("Youty also surfaces automatically in Share menus, the Services menu, and Shortcuts — no setup needed.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - About (Open source notices)

    /// Lists every third-party component Youty bundles or builds against,
    /// surfaces the LGPL §1 attribution for FFmpeg, and exposes the bundled
    /// license texts via "Show license" buttons. Read-only block — its only
    /// purpose is fulfilling the open-source disclosure obligations.
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("About")

            HStack(spacing: 8) {
                Text("Youty \(Self.shortVersion)")
                    .font(.system(size: 13, weight: .medium))
                Text("(\(Self.buildVersion))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Open source components")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Group {
                    aboutRow("FFmpeg 7.1.1", license: "LGPL-2.1+", note: "statically linked")
                    aboutRow("sqlite-vec", license: "Apache-2.0", note: nil)
                    aboutRow("SQLite", license: "public domain", note: nil)
                    aboutRow("SigLIP-Base-Patch16-224 (CoreML)", license: "Apache-2.0", note: "bundled in app")
                    aboutRow("CLIP tokenizer (OpenAI)", license: "MIT", note: "downloaded on first use")
                    aboutRow("Apple system frameworks", license: "Apple SDK Agreement", note: nil)
                    aboutRow("Google Gemini API", license: "Google API Terms", note: "your key, your calls")
                }
            }

            HStack(spacing: 12) {
                Button("Show full notices…") {
                    openBundledResource(name: "THIRD_PARTY_LICENSES", ext: "md")
                }
                .controlSize(.small)
                .accessibilityLabel("Show full third-party notices")
                .accessibilityHint("Opens the bundled THIRD_PARTY_LICENSES.md")

                Button("Show FFmpeg license…") {
                    openBundledResource(name: "COPYING.LGPLv2.1", ext: nil)
                }
                .controlSize(.small)
                .accessibilityLabel("Show FFmpeg LGPL-2.1 license")
                .accessibilityHint("Opens the bundled LGPL-2.1 license text")

                Button("Show SigLIP license…") {
                    openBundledResource(name: "LICENSE", ext: nil)
                }
                .controlSize(.small)
                .accessibilityLabel("Show SigLIP Apache-2.0 license")
                .accessibilityHint("Opens the bundled Apache-2.0 license text for SigLIP")

                Spacer()
            }

            Text("To relink Youty against a modified FFmpeg, edit the source from `ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz`, then re-run `Scripts/build-ffmpeg.sh` and `xcodebuild -scheme youty -configuration Release`. To rebuild the SigLIP image encoder, edit and re-run `Scripts/convert-siglip-coreml.py`.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One row in the About → Components list: name + license + optional note.
    private func aboutRow(_ name: String, license: String, note: String?) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text("·")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(license)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            if let note {
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    /// Open a resource bundled inside Youty.app/Contents/Resources/ in the
    /// user's default text viewer. Falls back silently if missing so a
    /// stripped/repackaged bundle can't crash the panel.
    private func openBundledResource(name: String, ext: String?) {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return }
        NSWorkspace.shared.open(url)
    }

    /// `CFBundleShortVersionString` — the human-facing version (e.g. "1.0.0").
    private static var shortVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    /// `CFBundleVersion` — the build number; useful when shipping multiple
    /// builds of the same version during soft launch.
    private static var buildVersion: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }

    // MARK: - Helpers

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    private func formatRelativeTime(unixMs: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixMs) / 1000)
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// Segmented picker bound to a Hashable value. Used twice — once for
    /// frame count, once for fps.
    private func pickerColumn<V: Hashable>(_ label: String,
                                            selection: Binding<V>,
                                            options: [SettingsStore.Option<V>]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Picker("", selection: selection) {
                ForEach(options, id: \.value) { opt in
                    Text(opt.label).tag(opt.value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(label)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Drives the inline status line in the AI search index section. Mutated
/// from the main actor only.
@MainActor
final class IndexerProgress: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var lastStatus: String?
    @Published var stats: IndexStats?

    /// Re-reads the DB and updates `stats`. Cheap (one DB pass), called on
    /// Settings sheet appear and after `runReindex` completes.
    func refreshStats() {
        Task.detached {
            let s = try? await IndexStore.shared.indexStats()
            await MainActor.run { self.stats = s }
        }
    }
}
