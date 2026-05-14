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
                    Text("No vault selected")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(vault.vaultURL == nil ? "Choose…" : "Change…") {
                    vault.chooseVault()
                }
                .controlSize(.regular)
            }
            if let url = vault.vaultURL {
                Text(url.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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

            Toggle(isOn: $settings.indexerEnabled) {
                Text("Index new saves automatically")
                    .font(.system(size: 13))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            // API key field. Reads + writes Keychain at account=youty,
            // service=gemini-api so the value is never serialised to disk
            // outside the system keychain.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: apiKeyStored ? "checkmark.seal.fill" : "key.fill")
                        .foregroundStyle(apiKeyStored ? .green : .secondary)
                        .font(.system(size: 12))
                    Text(apiKeyStored ? "Gemini API key stored" : "Gemini API key not configured")
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
                    Button("Save") { saveAPIKey() }
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        .controlSize(.small)
                }
                if let msg = apiKeyMessage {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
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

            Text("Embeds every video.md into a local SQLite index so an MCP-compatible AI can search the vault. The index lives outside your vault and is fully rebuildable.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
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
            apiKeyMessage = "Saved."
        } catch {
            apiKeyMessage = "Could not save key: \(error.localizedDescription)"
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
    /// Share Sheet + Services + AppIntents + Spotlight are always on (they
    /// surface automatically once the app is launched, and they aren't
    /// intrusive). The menu bar item is the only one that adds a visible
    /// element to the system UI, so it's opt-in.
    private var integrationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Integrations")

            Toggle(isOn: $settings.menuBarEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show in menu bar")
                        .font(.system(size: 13))
                    Text("Adds a small menu bar icon for one-click saves.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Text("Youty also appears in Share menus, Services, Shortcuts, and Spotlight.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
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
