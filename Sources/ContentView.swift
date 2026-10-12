import SwiftUI
import AppKit

enum AppState {
    case idle
    case loading
    case success(title: String, markdown: String)
    case error(String)
}

struct ContentView: View {
    @StateObject private var loader = TranscriptLoader()
    @EnvironmentObject private var vault: VaultManager
    @StateObject private var videoExtractor = VideoExtractor()
    @StateObject private var playerFetcher = PlayerFetcher()
    @StateObject private var shortForm: ShortFormPipelineHolder = ShortFormPipelineHolder()
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var funnel = IngestionFunnel.shared
    @Environment(\.openWindow) private var openWindow
    @State private var urlInput = ""
    @State private var state: AppState = .idle
    @State private var lastResult: FetchResult?
    @State private var shortFormPreview: ShortFormPreview?
    @State private var showInstagramLogin = false
    @State private var pendingInstagramURL: URL?
    @State private var vaultSaved = false
    @State private var vaultError: String?
    @State private var frameProgress: Double = 0
    @State private var downloadProgress: Double = 0
    @State private var showCopied = false
    @State private var fastFailure: FastFailure?
    @State private var autoSavePending = false
    @State private var ingestionBanner: String?
    @State private var ingestionBannerTimer: DispatchWorkItem?
    @State private var lastIndexedFolder: URL?
    @State private var showOnboarding = false
    @State private var upgradeDoneNote: String?
    @State private var savePending = false
    @State private var saveAfterLogin = false
    @State private var recents: [VaultLocalSearch.Match] = []
    @State private var framePrefetch: FramePrefetch?
    @State private var justSaved: URL?
    @ObservedObject private var indexStatus = IndexStatusStore.shared
    @FocusState private var inputFocused: Bool

    /// Frames captured while the transcript is still loading (YouTube saves).
    private struct FramePrefetch {
        let videoID: String
        let pipeline: FastFramePipeline
        let task: Task<[FrameExtractor.Frame], Error>
    }

    private struct FastFailure: Equatable {
        let reason: String
        let videoID: String
        let folderURL: URL
    }

    private var isValidURL: Bool {
        if TranscriptFetcher.extractVideoID(from: urlInput) != nil { return true }
        return PlatformRouter.platform(for: urlInput) != nil
    }

    private var detectedPlatform: Platform {
        if let p = PlatformRouter.platform(for: urlInput) { return p }
        return .youtube   // safe default when string isn't classifiable yet
    }

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.top, 14)
                    .padding(.bottom, 14)

                inputSection
                    .padding(.horizontal, 24)

                resultSection

                Spacer(minLength: 8)
            }
            .padding(.bottom, 16)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: vault.vaultURL) {
            refreshRecents()
            maintainIndexOnLaunch()   // a vault picked during onboarding gets indexed now
        }
        .onAppear {
            checkClipboard()
            refreshRecents()
            DispatchQueue.main.async {
                if let window = NSApp.windows.first(where: { $0.isVisible }) {
                    window.isOpaque = false
                    window.backgroundColor = .clear
                    loader.attachToWindow(window)
                    videoExtractor.attach(to: window)
                    playerFetcher.attach(to: window)
                    shortForm.pipeline(vault: vault, settings: settings).attach(to: window)
                    // Intercept the red-X so closing the window only hides
                    // it. Keeps ContentView + the WKWebView pipelines alive
                    // so background saves from menu bar / Share Sheet /
                    // Services / AppIntent keep working all session.
                    MainWindowKeeper.shared.attach(to: window)
                }
            }
            // First-launch onboarding (R.2). Skipped silently on every
            // launch after the user marks it complete; reachable any time
            // via Settings → Onboarding.
            if !settings.onboardingComplete {
                showOnboarding = true
            }
            // One-time, fully-automatic OCR backfill (V.1): quietly add on-screen
            // text to videos saved before the feature shipped. Background + silent
            // + resumable; no user action, no card.
            Task { await maybeBackfillOnScreenText() }
            // Upgrade an index built with an older model, otherwise heal any
            // saved-but-unindexed bundle (e.g. a save whose background index was
            // killed when the app quit too soon). Runs once per launch.
            maintainIndexOnLaunch()
        }
        .onChange(of: funnel.dispatchID) { _, _ in
            guard let url = funnel.inboxURL else { return }
            startExternalIngest(url: url, source: funnel.lastSource)
        }
        .sheet(isPresented: $showInstagramLogin) {
            AuthLoginView(config: .instagram) { result in
                showInstagramLogin = false
                if case .success = result, let url = pendingInstagramURL {
                    urlInput = url.absoluteString
                    Task {
                        if autoSavePending {
                            await runAutoIngest()
                        } else if saveAfterLogin {
                            saveAfterLogin = false
                            await primaryAction()
                        } else {
                            await fetch()
                        }
                    }
                } else {
                    saveAfterLogin = false
                    // User canceled login during an auto-ingest. Let the funnel
                    // move on to the next queued URL.
                    if autoSavePending { finishExternalIngest() }
                }
                pendingInstagramURL = nil
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(settings: settings,
                           vault: vault,
                           onDismiss: { showOnboarding = false })
        }
    }

    // MARK: - Header

    private var header: some View {
        LogoView()
    }

    // MARK: - Search upgrade

    /// Shown while the one-time search upgrade re-embeds saved videos, then
    /// briefly confirms the result. Non-blocking: saving and keyword search
    /// keep working throughout.
    @ViewBuilder
    private var upgradeBanner: some View {
        if let upgrade = indexStatus.upgrade {
            VStack(alignment: .leading, spacing: 6) {
                Text("Upgrading search for your saved videos…")
                    .font(.system(size: 12, weight: .medium))
                ProgressView(value: Double(upgrade.done), total: Double(max(upgrade.total, 1)))
                    .tint(.accentColor)
                    .accessibilityLabel("Search upgrade progress")
                Text("Your AI can already search everything by keyword while this runs.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            .transition(.opacity)
        } else if let note = upgradeDoneNote {
            Label(note, systemImage: "checkmark.seal.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .transition(.opacity)
        }
    }

    /// The OCR-backfill feature version. Bump when a future change should
    /// re-sweep existing vaults (e.g. a materially better OCR pass).
    private static let ocrBackfillTargetVersion = 1

    /// Guards the once-per-launch index reconcile (onAppear can fire repeatedly).
    private static var didMaintainThisLaunch = false

    /// Fully-automatic, one-time background backfill of on-screen text for
    /// videos saved before V.1. Reuses `Indexer.backfillOnScreenText`, which
    /// only touches bundles missing the OCR section — so this is silent,
    /// resumable across launches, and a no-op once complete. The flag is set
    /// only on success, so an interrupted/failed run simply retries next launch.
    @MainActor
    private func maybeBackfillOnScreenText() async {
        guard settings.onboardingComplete, !showOnboarding,
              settings.indexerEnabled, settings.ocrIndexingEnabled,
              settings.ocrBackfillVersion < Self.ocrBackfillTargetVersion,
              let vaultURL = vault.vaultURL else { return }
        Task.detached(priority: .background) {
            let acquired = vaultURL.startAccessingSecurityScopedResource()
            defer { if acquired { vaultURL.stopAccessingSecurityScopedResource() } }
            do {
                _ = try await Indexer.backfillOnScreenText(vaultRoot: vaultURL)
                await MainActor.run { settings.ocrBackfillVersion = Self.ocrBackfillTargetVersion }
            } catch {
                // Leave the flag unset → retried next launch (resumable).
            }
        }
    }

    /// Runs once per launch. An index built with an older embedding model is
    /// upgraded automatically (resumable, text first, then frames); otherwise
    /// any saved-but-unindexed bundle is healed. The text model is prepared
    /// first so its one-time Neural Engine compilation never delays a save.
    @MainActor
    private func maintainIndexOnLaunch() {
        guard settings.indexerEnabled, let vaultURL = vault.vaultURL,
              !Self.didMaintainThisLaunch else { return }
        Self.didMaintainThisLaunch = true
        Task.detached(priority: .utility) {
            let acquired = vaultURL.startAccessingSecurityScopedResource()
            defer { if acquired { vaultURL.stopAccessingSecurityScopedResource() } }
            // Refresh manifest.json so it reflects the notes as this version reads them.
            VaultManager.writeManifest(in: vaultURL)
            await MainActor.run { refreshRecents() }
            try? EmbeddingGemma2.shared().warmUp()
            let model = EmbeddingGemma2.modelIdentifier
            guard (try? await IndexStore.shared.needsModelMigration(activeModel: model)) == true else {
                _ = try? await Indexer.reconcileMissing(vaultRoot: vaultURL)
                return
            }
            await MainActor.run {
                withAnimation { IndexStatusStore.shared.upgrade = .init(done: 0, total: 1) }
            }
            let summary = try? await Indexer.migrateToCurrentModel(vaultRoot: vaultURL) { done, total in
                Task { @MainActor in
                    guard IndexStatusStore.shared.upgrade != nil else { return }
                    IndexStatusStore.shared.upgrade = .init(done: done, total: total)
                }
            }
            await MainActor.run {
                withAnimation {
                    IndexStatusStore.shared.upgrade = nil
                    if let summary, summary.failures.isEmpty {
                        upgradeDoneNote = "Search upgraded for \(summary.videosIndexed) saved video\(summary.videosIndexed == 1 ? "" : "s")."
                    } else {
                        upgradeDoneNote = "Search upgrade will finish next time Youty opens."
                    }
                }
                let work = DispatchWorkItem { withAnimation { upgradeDoneNote = nil } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
            }
        }
    }

    // MARK: - Input

    private var inputSection: some View {
        VStack(spacing: 12) {
            if let banner = ingestionBanner {
                Label(banner, systemImage: "tray.and.arrow.down.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
            upgradeBanner
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: isValidURL ? Self.platformSymbol(detectedPlatform.rawValue) : "link")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isValidURL ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: isValidURL)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    TextField("Paste a YouTube, Instagram, or TikTok link…", text: $urlInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($inputFocused)
                        .onSubmit { if isValidURL && !isBusy { Task { await primaryAction() } } }
                        .accessibilityLabel("Video link")
                        .accessibilityHint("Paste a YouTube, Instagram, or TikTok link, then press Return")

                    if !urlInput.isEmpty {
                        Button {
                            urlInput = ""
                            state = .idle
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                        .accessibilityLabel("Clear link")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .glassEffect(isValidURL ? .regular.tint(Color.accentColor.opacity(0.12)).interactive()
                                        : .regular.interactive(), in: .rect(cornerRadius: 12))
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isValidURL)

                Button {
                    openWindow(id: "settings")
                } label: {
                    HoverSpinGear()
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .help("Settings")
                .accessibilityLabel("Settings")
                .accessibilityHint("Pick a vault, connect your AI, and adjust capture options")
            }

            primaryButton
        }
    }

    private var isBusy: Bool {
        if case .loading = state { return true }
        return savePending
    }

    /// Saving is the main job: with a vault, one click fetches the transcript,
    /// writes the bundle, captures frames, and indexes it for search. Without
    /// one, the button falls back to showing the transcript.
    private var primaryButton: some View {
        Button {
            Task { await primaryAction() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: primarySymbol)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, options: .repeating, isActive: isBusy)
                Text(primaryLabel)
                    .font(.system(size: 13, weight: .medium))
                    .contentTransition(.interpolate)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .animation(.snappy, value: primaryLabel)
        }
        .buttonStyle(.glassProminent)
        .hoverLift()
        .controlSize(.large)
        .disabled(!isValidURL || isBusy)
        .animation(.easeInOut(duration: 0.15), value: isValidURL)
        .accessibilityLabel(primaryLabel)
        .accessibilityHint(vault.vaultURL == nil
                           ? "Shows the transcript. Pick a vault in Settings to save videos."
                           : "Saves the transcript and frames to your vault and makes them searchable by your AI")
    }

    private var primaryLabel: String {
        guard isBusy else { return vault.vaultURL == nil ? "Get Transcript" : "Save to Vault" }
        if vault.vaultURL == nil { return "Fetching…" }
        if case .loading = state { return "Reading the transcript…" }
        switch vault.frameState {
        case .capturingStream, .downloading, .extracting: return "Capturing frames…"
        default: return "Saving…"
        }
    }

    private var primarySymbol: String {
        guard isBusy else {
            return vault.vaultURL == nil ? "waveform.and.magnifyingglass" : "square.and.arrow.down.on.square"
        }
        if case .loading = state { return "text.page" }
        return "photo.stack"
    }

    /// Fetch, then save straight away when a vault is set.
    private func primaryAction() async {
        guard vault.vaultURL != nil else { await fetch(); return }
        savePending = true
        defer { savePending = false }
        let requested = urlInput
        startFramePrefetch()
        await fetch()
        // Another link (Share Sheet, menu bar, AI) replaced this one meanwhile.
        guard urlInput == requested else {
            dropFramePrefetch()
            return
        }
        // Instagram sign-in in progress: the login sheet continues the save.
        if showInstagramLogin { saveAfterLogin = true; return }
        guard lastResult != nil || shortFormPreview != nil else {
            dropFramePrefetch()
            return
        }
        // Keep the button busy until frames are captured and indexing starts, so
        // a second click can't run a competing save into the same bundle.
        await saveToVault(allowVaultPrompt: false, for: requested)?.value
    }

    // MARK: - Result

    @ViewBuilder
    private var resultSection: some View {
        switch state {
        case .idle:
            recentSection
        case .loading:
            EmptyView()

        case .error(let msg):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                Text(msg).font(.system(size: 13)).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    withAnimation { state = .idle }
                } label: {
                    Image(systemName: "xmark").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss error")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular.tint(.red.opacity(0.15)), in: .rect(cornerRadius: 12))
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))

        case .success(let title, let markdown):
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    ScrollView {
                        Text(markdown)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 150)
                }
                .padding(14)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))

                HStack(spacing: 10) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(markdown, forType: .string)
                        withAnimation { showCopied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { showCopied = false }
                        }
                    } label: {
                        Label(showCopied ? "Copied" : "Copy", systemImage: showCopied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    Button {
                        saveMarkdown(markdown, title: title)
                    } label: {
                        Label("Save Markdown", systemImage: "arrow.down.doc").frame(maxWidth: .infinity)
                    }
                    if let folder = lastIndexedFolder {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([folder])
                        } label: {
                            Label("Show in Finder", systemImage: "folder").frame(maxWidth: .infinity)
                        }
                    } else if vault.vaultURL != nil, !savePending {
                        Button {
                            saveToVault()
                        } label: {
                            Label(vaultSaved ? "Saved" : "Save to Vault",
                                  systemImage: vaultSaved ? "checkmark" : "square.and.arrow.down.on.square")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .buttonStyle(.glass)
                .font(.system(size: 13))

                if vault.vaultURL == nil {
                    HStack(spacing: 5) {
                        Text("To save videos and search them with your AI,")
                            .foregroundStyle(.secondary)
                        Button("choose a vault folder") { vault.chooseVault() }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    }
                    .font(.system(size: 11))
                }

                if let err = vaultError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                        Text(err).font(.system(size: 11)).foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button { vaultError = nil } label: {
                            Image(systemName: "xmark").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss error")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .glassEffect(.regular.tint(.red.opacity(0.15)), in: .rect(cornerRadius: 10))
                }

                if let failure = fastFailure {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Couldn't capture frames automatically.", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                        Button {
                            fastFailure = nil
                            Task {
                                await runCanvasFallback(videoID: failure.videoID,
                                                        folderURL: failure.folderURL)
                            }
                        } label: {
                            Label("Capture frames anyway", systemImage: "tortoise.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }
                    .padding(10)
                    .glassEffect(.regular.tint(.red.opacity(0.12)), in: .rect(cornerRadius: 10))
                    .transition(.opacity)
                }

                frameStatus
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Frame capture and indexing progress for the video just saved.
    @ViewBuilder
    private var frameStatus: some View {
        switch vault.frameState {
        case .capturingStream:
            frameStatusRow(text: "Reaching YouTube…", showSpinner: true)
        case .downloading(let p):
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: p).tint(.accentColor)
                Text("Downloading video \(Int(p * 100))%")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .extracting:
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: frameProgress).tint(.accentColor)
                Text("Capturing frames \(Int(frameProgress * 100))%")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .done(let count):
            HStack(spacing: 8) {
                frameStatusRow(text: "Saved with \(count) frames", showSpinner: false)
                if let folder = lastIndexedFolder, let state = indexStatus.state(for: folder) {
                    IndexBadgeView(state: state)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: lastIndexedFolder.flatMap { indexStatus.state(for: $0) })
        case .failed:
            Text("Couldn't capture frames — the transcript is still saved.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    // MARK: - Recently saved

    /// The last few saves, so it's always visible what the AI can search — and,
    /// for a fresh save, when the AI will be able to find it.
    @ViewBuilder
    private var recentSection: some View {
        if recents.isEmpty {
            if vault.vaultURL != nil {
                EmptyLibraryView()
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .transition(.opacity)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recently saved")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                VStack(spacing: 2) {
                    ForEach(recents, id: \.folder) { item in
                        RecentRow(item: item,
                                  symbol: Self.platformSymbol(item.platform),
                                  state: indexStatus.state(for: item.folder),
                                  highlighted: item.folder == justSaved)
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                    removal: .opacity))
                    }
                }
                .padding(4)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .animation(.spring(response: 0.45, dampingFraction: 0.8), value: recents.map(\.folder))
                footerHint
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: anyLearning)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .transition(.opacity)
        }
    }

    private var anyLearning: Bool {
        recents.contains { indexStatus.state(for: $0.folder) == .indexing }
    }

    private var footerHint: Text {
        if anyLearning { return Text("Your AI can ask about it as soon as it says “Ready to ask”.") }
        return Text(settings.onboardingMCPDone
                    ? "Ask your AI about anything here — “what did they say about …?”"
                    : "Connect your AI in Settings to ask it about anything you save.")
    }

    private static func platformSymbol(_ platform: String) -> String {
        switch platform {
        case "instagram": return "camera"
        case "tiktok":    return "music.note"
        default:          return "play.rectangle"
        }
    }

    private func refreshRecents() {
        recents = VaultLocalSearch.recents(limit: 5)
    }

    // MARK: - Actions

    private func fetch() async {
        withAnimation(.spring(duration: 0.3)) { state = .loading }
        // Reset cross-platform state on every new fetch, including any save
        // status carried over from a previously loaded video (frame count,
        // saved/error banners, index target) so the new video starts clean.
        shortFormPreview = nil
        lastResult = nil
        vaultSaved = false
        vaultError = nil
        fastFailure = nil
        lastIndexedFolder = nil
        vault.frameState = .idle
        switch detectedPlatform {
        case .youtube:
            do {
                let result = try await loader.fetch(urlString: urlInput)
                lastResult = result
                withAnimation(.spring(duration: 0.4)) {
                    state = .success(title: result.title, markdown: result.markdown)
                }
            } catch is CancellationError {
                // Superseded by a newer link; that fetch owns the screen now.
            } catch {
                withAnimation(.spring(duration: 0.3)) {
                    state = .error(error.localizedDescription)
                }
            }
        case .tiktok, .instagram:
            guard let url = URL(string: urlInput) else {
                state = .error("That doesn't look like a valid post URL.")
                return
            }
            do {
                let pipeline = shortForm.pipeline(vault: vault, settings: settings)
                let preview = try await pipeline.preview(url: url)
                shortFormPreview = preview
                withAnimation(.spring(duration: 0.4)) {
                    state = .success(title: preview.title,
                                      markdown: ShortFormMarkdownPreview.build(preview))
                }
            } catch let e as InstagramExtractorError where e.errorDescription?.contains("Sign in") == true {
                // Not logged in → present in-app login. Re-fetch on success.
                pendingInstagramURL = url
                showInstagramLogin = true
                withAnimation { state = .idle }
            } catch {
                withAnimation(.spring(duration: 0.3)) {
                    state = .error(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - External ingestion (Share Sheet / Services / AppIntents / menu bar / scheme)

    /// Called when IngestionFunnel publishes a new URL. Fetches + auto-saves
    /// using the same paths as a manual paste. Auto-save only triggers when
    /// `autoSavePending` is true; users typing into the URL field are
    /// unaffected.
    private func startExternalIngest(url: URL, source: String) {
        autoSavePending = true
        showIngestionBanner(source: source)
        urlInput = url.absoluteString
        Task { await runAutoIngest() }
    }

    /// Drive a single fetch+save cycle. Re-entrant: the Instagram login
    /// flow may re-invoke this after the user signs in.
    private func runAutoIngest() async {
        let requested = urlInput
        startFramePrefetch()
        await fetch()
        // Instagram login in progress — sheet handler will re-call us.
        if showInstagramLogin { return }
        // Fetch failed (no preview, no result) → tell the funnel we're done.
        if lastResult == nil && shortFormPreview == nil {
            dropFramePrefetch()
            finishExternalIngest()
            return
        }
        saveToVault(allowVaultPrompt: false, for: requested)
        // applyOutcome / save error handlers call finishExternalIngest()
        // once the save settles. We don't await here so the UI updates as
        // the frame pipeline progresses.
    }

    /// Signals IngestionFunnel that this URL is done so the next queue
    /// item (if any) gets dispatched. Safe to call repeatedly.
    fileprivate func finishExternalIngest() {
        guard autoSavePending else { return }
        autoSavePending = false
        IngestionFunnel.shared.didFinishSave()
    }

    /// Briefly show a "Received from {source}" pill so users see the URL
    /// didn't appear by magic. Auto-clears after 2 s.
    private func showIngestionBanner(source: String) {
        let label: String? = {
            switch source {
            case "share":     return "From Share Sheet"
            case "services":  return "From Services menu"
            case "intent":    return "From Shortcuts"
            case "menubar":   return "From menu bar"
            case "scheme":    return "From URL"
            default:          return nil
            }
        }()
        ingestionBannerTimer?.cancel()
        withAnimation { ingestionBanner = label }
        let work = DispatchWorkItem { [self] in
            withAnimation { ingestionBanner = nil }
        }
        ingestionBannerTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
    }

    /// Returns the background save (frames + indexing) for callers that wait on it.
    @discardableResult
    private func saveToVault(allowVaultPrompt: Bool = true, for link: String? = nil) -> Task<Void, Never>? {
        vaultError = nil
        // The link this save belongs to (captured by the caller before any
        // waiting), so finishing never clears a newer one.
        let savedURL = link ?? urlInput

        // No vault configured. For a user-initiated save, prompt them to pick a
        // folder. For a BACKGROUND ingest (Share / Services / Shortcuts / menu
        // bar), never pop a modal folder picker the user didn't initiate — show
        // the non-blocking error banner and release the funnel instead
        // (blocking dialogs are reserved for destructive actions only).
        if vault.vaultURL == nil {
            if allowVaultPrompt {
                vault.chooseVault()
                guard vault.vaultURL != nil else { dropFramePrefetch(); return nil }
            } else {
                dropFramePrefetch()
                vaultError = VaultError.noVault.localizedDescription
                finishExternalIngest()
                return nil
            }
        }

        // Short-form (Instagram / TikTok) path.
        if let preview = shortFormPreview {
            withAnimation { vaultSaved = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { self.vaultSaved = false }
            }
            return Task { @MainActor in
                let pipeline = shortForm.pipeline(vault: vault, settings: settings)
                do {
                    let stageHandler: @Sendable (FrameStage) -> Void = { stage in
                        Task { @MainActor in self.applyStage(stage) }
                    }
                    let outcome = try await pipeline.save(preview: preview, stage: stageHandler)
                    applyOutcome(.success(framesWritten: outcome.framesWritten,
                                            durationMs: outcome.totalMs,
                                            mode: preview.platform.rawValue),
                                 videoID: preview.tikTokMetadata?.videoID
                                       ?? preview.instagramMetadata?.shortcode
                                       ?? "post",
                                 folderURL: outcome.folder,
                                 savedURL: savedURL)
                    triggerIndexer(bundleFolder: outcome.folder)
                } catch {
                    vaultError = error.localizedDescription
                    finishExternalIngest()
                }
            }
        }

        // YouTube path.
        guard let result = lastResult else {
            dropFramePrefetch()
            vaultError = "Nothing to save yet. Load a video first."
            finishExternalIngest()
            return nil
        }
        let metadata = MetadataEnricher.enrich(from: result)
        do {
            let folderURL = try vault.saveNote(result: result, metadata: metadata)
            lastIndexedFolder = folderURL
            withAnimation { vaultSaved = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { self.vaultSaved = false }
            }
            let videoID = result.videoID
            return Task {
                await runFramePipeline(videoID: videoID, folderURL: folderURL, savedURL: savedURL)
            }
        } catch {
            dropFramePrefetch()
            vaultError = error.localizedDescription
            finishExternalIngest()
            return nil
        }
    }

    @ViewBuilder
    private func frameStatusRow(text: String, showSpinner: Bool) -> some View {
        HStack(spacing: 6) {
            if showSpinner { ProgressView().controlSize(.mini) }
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    /// Starts capturing a YouTube video's frames as soon as Save is pressed, so
    /// they're ready by the time the transcript arrives.
    private func startFramePrefetch() {
        framePrefetch?.task.cancel()
        framePrefetch = nil
        guard vault.vaultURL != nil, detectedPlatform == .youtube,
              let id = TranscriptFetcher.extractVideoID(from: urlInput) else { return }
        let pipeline = FastFramePipeline(playerFetcher: playerFetcher, vault: vault, settings: settings)
        framePrefetch = FramePrefetch(videoID: id, pipeline: pipeline, task: pipeline.prefetch(videoID: id))
    }

    private func dropFramePrefetch() {
        framePrefetch?.task.cancel()
        framePrefetch = nil
    }

    private func runFramePipeline(videoID: String, folderURL: URL, savedURL: String) async {
        frameProgress = 0
        downloadProgress = 0
        fastFailure = nil

        let prefetch = framePrefetch?.videoID == videoID ? framePrefetch : nil
        if prefetch == nil { framePrefetch?.task.cancel() }
        framePrefetch = nil
        let pipeline = prefetch?.pipeline
            ?? FastFramePipeline(playerFetcher: playerFetcher, vault: vault, settings: settings)
        let outcome = await pipeline.extract(videoID: videoID, folderURL: folderURL,
                                             prefetched: prefetch?.task) { stage in
            applyStage(stage)
        }
        applyOutcome(outcome, videoID: videoID, folderURL: folderURL, savedURL: savedURL)
        if case .success = outcome {
            triggerIndexer(bundleFolder: folderURL)
        }
    }

    /// Best-effort, non-blocking Phase B index. Skipped when the user has
    /// disabled it in Settings, or when no vault is configured. Failures
    /// (no API key, network) are logged only — the save itself is already
    /// complete and the user shouldn't see a UI banner for an optional
    /// background step. The user can always re-run via Settings → Re-index.
    ///
    /// Publishes state transitions to `IndexStatusStore` so the in-app
    /// saved-video row + menu bar item can show an Indexing… / Indexed
    /// badge to the user.
    private func triggerIndexer(bundleFolder: URL) {
        guard settings.indexerEnabled else { return }
        guard let vaultURL = vault.vaultURL else { return }
        let videoMd = bundleFolder.appendingPathComponent("video.md")
        lastIndexedFolder = bundleFolder
        IndexStatusStore.shared.begin(folder: bundleFolder)
        // .utility (not .background): a fresh save must index promptly. Under
        // .background QoS macOS heavily defers this, so quitting the app shortly
        // after a save could kill it before it ran. The launch reconcile is the
        // durable safety net; this keeps in-session indexing reliable too.
        Task.detached(priority: .utility) {
            let acquired = vaultURL.startAccessingSecurityScopedResource()
            defer { if acquired { vaultURL.stopAccessingSecurityScopedResource() } }
            // Text and frames index side by side (different chips). The video is
            // "ready to ask" as soon as its transcript is searchable; frames
            // join visual search moments later.
            async let frames: String? = {
                do { try await Indexer.indexFrames(videoMdURL: videoMd, vaultRoot: vaultURL); return nil }
                catch { NSLog("[youty] frame indexer skipped/failed: \(error.localizedDescription)"); return error.localizedDescription }
            }()
            var textError: String?
            do {
                try await Indexer.indexBundle(videoMdURL: videoMd, vaultRoot: vaultURL)
                await MainActor.run { IndexStatusStore.shared.markIndexed(folder: bundleFolder) }
            } catch {
                NSLog("[youty] indexer skipped/failed: \(error.localizedDescription)")
                textError = error.localizedDescription
            }
            let frameError = await frames
            guard let textError else { return }
            await MainActor.run {
                if frameError == nil {
                    IndexStatusStore.shared.markIndexed(folder: bundleFolder)
                } else {
                    IndexStatusStore.shared.markFailed(folder: bundleFolder, reason: textError)
                }
            }
        }
    }

    private func runCanvasFallback(videoID: String, folderURL: URL) async {
        frameProgress = 0
        withAnimation { vault.frameState = .capturingStream }
        let pipeline: any FramePipeline = CanvasFramePipeline(
            canvasExtractor: videoExtractor,
            vault: vault
        )
        let outcome = await pipeline.extract(videoID: videoID, folderURL: folderURL) { stage in
            applyStage(stage)
        }
        applyOutcome(outcome, videoID: videoID, folderURL: folderURL)
    }

    private func applyStage(_ stage: FrameStage) {
        switch stage {
        case .loading:
            withAnimation { self.vault.frameState = .capturingStream }
            self.frameProgress = 0
        case .downloading(let p):
            self.downloadProgress = p
            withAnimation { self.vault.frameState = .downloading(p) }
        case .extracting(let p):
            withAnimation { self.vault.frameState = .extracting }
            self.frameProgress = p
        case .writing:
            withAnimation { self.vault.frameState = .extracting }
            self.frameProgress = 1.0
        }
    }

    private func applyOutcome(_ outcome: FramePipelineOutcome,
                              videoID: String,
                              folderURL: URL,
                              savedURL: String? = nil) {
        switch outcome {
        case .success(let count, let ms, let mode):
            NSLog("[youty] \(mode): \(count) frames in \(ms)ms")
            withAnimation { vault.frameState = .done(count) }
            if vault.vaultURL != nil {
                // Saved: back to the library, new video on top, ready for the
                // next link — unless the user already pasted that next link.
                justSaved = folderURL
                if let savedURL, urlInput == savedURL || urlInput.isEmpty {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                        state = .idle
                        urlInput = ""
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    if justSaved == folderURL { withAnimation(.easeOut(duration: 0.6)) { justSaved = nil } }
                }
            }
        case .failed(let reason, let canFallback):
            if canFallback {
                withAnimation {
                    vault.frameState = .idle
                    fastFailure = FastFailure(reason: reason, videoID: videoID, folderURL: folderURL)
                }
            } else {
                withAnimation { vault.frameState = .failed(reason) }
            }
        }
        refreshRecents()
        // External-ingestion completion: settle the funnel so the next
        // queued URL (if any) gets picked up.
        finishExternalIngest()
    }

    private func saveMarkdown(_ content: String, title: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let safeName = title.components(separatedBy: .init(charactersIn: "/\\:*?\"<>|")).joined(separator: "-")
        panel.nameFieldStringValue = "\(safeName).md"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                vaultError = "Couldn't save the Markdown file. Choose a writable folder and try again."
            }
        }
    }

    private func checkClipboard() {
        guard let clip = NSPasteboard.general.string(forType: .string),
              TranscriptFetcher.extractVideoID(from: clip) != nil else { return }
        urlInput = clip
    }
}

// MARK: - Visual Effect

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
