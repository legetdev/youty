import SwiftUI
import AppKit

// Settings sheet. Hosts the user-visible preferences that affect saved
// bundles: vault location, frame-density caps, transcription language.
//
// Liquid-glass aesthetic — translucent HUD-style window with the same
// material treatment as the rest of the app.

// Lightweight wrapper used by the standalone Settings window so callers
// don't have to thread environment objects + dismissal plumbing manually.
struct SettingsHostView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var vault: VaultManager
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        SettingsView(settings: settings,
                     vault: vault,
                     onDismiss: { dismissWindow(id: "settings") })
    }
}

struct SettingsView: View {

    @ObservedObject var settings: SettingsStore
    @ObservedObject var vault: VaultManager
    let onDismiss: () -> Void

    @StateObject private var indexerProgress = IndexerProgress()
    @State private var showOnboarding: Bool = false

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 26)
                    // Title sits on the same y-axis as the traffic-light
                    // buttons (centered, so they don't collide), keeping
                    // the head space tight.
                    .padding(.top, 14)
                    .padding(.bottom, 14)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
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

                        onboardingSection
                        Divider().opacity(0.35)

                        aboutSection
                    }
                    .padding(.horizontal, 26)
                    .padding(.bottom, 22)
                }
            }
        }
        .frame(width: 520, height: 560)
    }

    // MARK: - Header

    private var header: some View {
        ZStack {
            Text("Settings")
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .center)
            HStack {
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

            Text("Lets Claude / Cursor / any MCP-compatible AI search your saved videos by meaning, not just keyword. Runs 100% on-device — no API key, nothing leaves your Mac. Re-indexing rebuilds the on-device text and frame vectors used for search.")
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

            // 100% on-device — no key, nothing leaves the Mac.
            HStack(spacing: 8) {
                Image(systemName: "lock.laptopcomputer")
                    .foregroundStyle(.green)
                    .font(.system(size: 12))
                Text("Runs 100% on-device — no API key needed, nothing leaves your Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            // Migration card (S.4) — appears only when the index was built with
            // an older model than the on-device embedder (e.g. a legacy index).
            // A text-only re-embed (frames untouched), so it's the fast path.
            if let s = indexerProgress.stats,
               let model = s.textModelID,
               model != EmbeddingGemmaEmbedder.modelIdentifier,
               s.chunkCount > 0 {
                migrationCard()
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
                    Text("\(s.videoCount) videos" +
                         (s.frameCount > 0 ? " · \(s.frameCount) frames" : "") +
                         "  ·  \(formatBytes(s.dbBytes)) on disk")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let lastMs = s.lastRebuildMs {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text("Last updated: \(formatRelativeTime(unixMs: lastMs))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 2)
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
                    self.indexerProgress.lastStatus = "Couldn't finish — \(error.localizedDescription)"
                    self.indexerProgress.isRunning = false
                }
            }
        }
    }

    /// Contextual migration card shown when the index's text model is older
    /// than the on-device embedder (e.g. a legacy index). Offers a text-only
    /// re-embed to the on-device model.
    @ViewBuilder
    private func migrationCard() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Update this vault for on-device search")
                        .font(.system(size: 12, weight: .medium))
                    Text("Your index was built with an older model. Re-embed it on-device — keyword search keeps working while it runs.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                runTextReembed()
            } label: {
                HStack(spacing: 6) {
                    if indexerProgress.isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(indexerProgress.isRunning ? "Re-embedding…" : "Re-embed on-device")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .controlSize(.regular)
            .disabled(indexerProgress.isRunning || vault.vaultURL == nil)
            .accessibilityHint("Re-embeds only transcript text on-device; frame search is untouched")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1))
    }

    /// Text-only re-embed (frames untouched) — the S.4 migration path.
    private func runTextReembed() {
        guard let vaultURL = vault.vaultURL else { return }
        indexerProgress.isRunning = true
        indexerProgress.lastStatus = "Re-embedding transcript text…"
        Task.detached {
            let acquired = vaultURL.startAccessingSecurityScopedResource()
            defer { if acquired { vaultURL.stopAccessingSecurityScopedResource() } }
            do {
                let summary = try await Indexer.reindexTextEmbeddings(vaultRoot: vaultURL) { line in
                    Task { @MainActor in self.indexerProgress.lastStatus = line }
                }
                let line = "Re-embedded \(summary.videosIndexed) video(s), \(summary.chunksWritten) chunks in \(summary.totalMs)ms" +
                           (summary.failures.isEmpty ? "" : " — \(summary.failures.count) failed")
                await MainActor.run {
                    self.indexerProgress.lastStatus = line
                    self.indexerProgress.isRunning = false
                    self.indexerProgress.refreshStats()
                }
            } catch {
                await MainActor.run {
                    self.indexerProgress.lastStatus = "Couldn't finish — \(error.localizedDescription)"
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

    // MARK: - Onboarding (R.2 — reopenable from Settings)

    /// Surfaces the same four-card onboarding sheet the user saw on first
    /// launch. Required by R.2 spec — the user must be able to revisit
    /// the cards any time after dismissing the first-run experience.
    private var onboardingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Onboarding")

            Text("Re-open the first-run cards any time — pick a vault, install the CLI, wire up the MCP server.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                showOnboarding = true
            } label: {
                Label("Open onboarding", systemImage: "sparkles")
            }
            .controlSize(.small)
            .accessibilityLabel("Open onboarding")
            .accessibilityHint("Reopens the four-card first-run setup")
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(settings: settings,
                           vault: vault,
                           onDismiss: { showOnboarding = false })
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
                Button("Check for Updates…") {
                    AppUpdater.checkForUpdates()
                }
                .controlSize(.small)
                .accessibilityLabel("Check for Updates")
                .accessibilityHint("Checks for a newer version of Youty and offers to install it")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Open source components")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Group {
                    aboutRow("FFmpeg 7.1.1", license: "LGPL-2.1+", note: "statically linked")
                    aboutRow("Sparkle 2.9.2", license: "MIT", note: "auto-update framework")
                    aboutRow("SigLIP-Base-Patch16-224 (CoreML)", license: "Apache-2.0", note: "bundled, on-device frame search")
                    aboutRow("EmbeddingGemma-300m (CoreML)", license: "Gemma Terms", note: "bundled, on-device text search")
                    aboutRow("SQLite", license: "public domain", note: "system library")
                    aboutRow("Apple system frameworks", license: "Apple SDK Agreement", note: nil)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Licenses & notices")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("All notices") {
                        openBundledResource(name: "THIRD_PARTY_LICENSES", ext: "md")
                    }
                    .accessibilityLabel("Show full third-party notices")
                    .accessibilityHint("Opens the full open-source license notices")

                    Button("FFmpeg") {
                        openBundledResource(name: "COPYING.LGPLv2.1", ext: nil)
                    }
                    .accessibilityLabel("Show FFmpeg LGPL-2.1 license")

                    Button("SigLIP") {
                        openBundledResource(name: "LICENSE", ext: nil)
                    }
                    .accessibilityLabel("Show SigLIP Apache-2.0 license")

                    Button("Gemma") {
                        openBundledResource(name: "EmbeddingGemma-NOTICE", ext: "txt")
                    }
                    .accessibilityLabel("Show EmbeddingGemma Gemma Terms notice")

                    Spacer()
                }
                .controlSize(.small)
            }
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
        // Read as one phrase under VoiceOver instead of "name · license · note"
        // fragments (the "·" separators are visual-only).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(license)" + (note.map { ", \($0)" } ?? ""))
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
