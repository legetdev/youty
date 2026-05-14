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
    @StateObject private var vault = VaultManager()
    @StateObject private var videoExtractor = VideoExtractor()
    @StateObject private var playerFetcher = PlayerFetcher()
    @StateObject private var shortForm: ShortFormPipelineHolder = ShortFormPipelineHolder()
    @StateObject private var settings = SettingsStore()
    @ObservedObject private var funnel = IngestionFunnel.shared
    @State private var urlInput = ""
    @State private var state: AppState = .idle
    @State private var lastResult: FetchResult?
    @State private var shortFormPreview: ShortFormPreview?
    @State private var showInstagramLogin = false
    @State private var pendingInstagramURL: URL?
    @State private var showSettings = false
    @State private var vaultSaved = false
    @State private var vaultError: String?
    @State private var frameProgress: Double = 0
    @State private var downloadProgress: Double = 0
    @State private var showCopied = false
    @State private var fastFailure: FastFailure?
    @State private var autoSavePending = false
    @State private var ingestionBanner: String?
    @State private var ingestionBannerTimer: DispatchWorkItem?
    @FocusState private var inputFocused: Bool

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
            }
            .padding(.bottom, 16)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            checkClipboard()
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
                        } else {
                            await fetch()
                        }
                    }
                } else if autoSavePending {
                    // User canceled login during an auto-ingest. Let the funnel
                    // move on to the next queued URL.
                    finishExternalIngest()
                }
                pendingInstagramURL = nil
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings,
                          vault: vault,
                          onDismiss: { showSettings = false })
        }
    }

    // MARK: - Header

    private var header: some View {
        Image("HeaderLogo")
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
            .frame(width: 96, height: 96)
            .accessibilityLabel("youty")
    }

    // MARK: - Input

    private var inputSection: some View {
        VStack(spacing: 12) {
            if let banner = ingestionBanner {
                HStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(banner)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    TextField("Paste a YouTube, TikTok or Instagram URL…", text: $urlInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($inputFocused)
                        .onSubmit { if isValidURL { Task { await fetch() } } }

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
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                )

                settingsPill
            }

            fetchButton
        }
    }

    /// Small liquid-glass pill that opens the Settings sheet. Uses the same
    /// vertical-padding scheme as the URL bar so both align perfectly in the
    /// HStack (the URL bar's intrinsic height drives the row height; the
    /// pill matches by sharing identical padding + line-height).
    private var settingsPill: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help("Settings")
    }

    private var fetchButton: some View {
        Button {
            Task { await fetch() }
        } label: {
            HStack(spacing: 8) {
                if case .loading = state {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "waveform.and.magnifyingglass")
                }
                Text(buttonLabel)
                    .font(.system(size: 14, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                isValidURL ? Color.accentColor : Color.secondary.opacity(0.25),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .foregroundStyle(isValidURL ? .white : .secondary)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.white.opacity(isValidURL ? 0.2 : 0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isValidURL || { if case .loading = state { return true }; return false }())
        .animation(.easeInOut(duration: 0.15), value: isValidURL)
    }

    private var buttonLabel: String {
        if case .loading = state { return "Fetching…" }
        switch detectedPlatform {
        case .tiktok:    return "Load TikTok"
        case .instagram: return "Load Reel"
        case .youtube:   return "Get Transcript"
        }
    }

    // MARK: - Result

    @ViewBuilder
    private var resultSection: some View {
        switch state {
        case .idle, .loading:
            EmptyView()

        case .error(let msg):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                Text(msg).font(.system(size: 13)).foregroundStyle(.primary)
                Spacer()
                Button {
                    withAnimation { state = .idle }
                } label: {
                    Image(systemName: "xmark").foregroundStyle(.tertiary).font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.red.opacity(0.3), lineWidth: 1))
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))

        case .success(let title, let markdown):
            VStack(spacing: 12) {
                ScrollView {
                    Text(markdown)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .frame(height: 280)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12), lineWidth: 1))

                HStack(spacing: 10) {
                    actionButton(icon: showCopied ? "checkmark" : "doc.on.doc",
                                 label: showCopied ? "Copied" : "Copy",
                                 color: .secondary) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(markdown, forType: .string)
                        withAnimation { showCopied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { showCopied = false }
                        }
                    }
                    actionButton(icon: "arrow.down.circle", label: "Save Markdown", color: .secondary) {
                        saveMarkdown(markdown, title: title)
                    }
                    actionButton(icon: vaultSaved ? "checkmark" : "square.and.arrow.down.on.square",
                                 label: vaultSaved ? "Saved ✓" : "Save to Vault",
                                 color: .accentColor) {
                        saveToVault()
                    }
                }

                // Vault setup prompt
                if vault.vaultURL == nil {
                    HStack(spacing: 5) {
                        Text("No vault set —")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Button("Choose folder") { vault.chooseVault() }
                            .font(.system(size: 12))
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    }
                }

                // Vault error banner
                if let err = vaultError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                        Text(err).font(.system(size: 12)).foregroundStyle(.primary)
                        Spacer()
                        Button { vaultError = nil } label: {
                            Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.red.opacity(0.3), lineWidth: 1))
                }

                // Fast-path failure banner + fallback button
                if let failure = fastFailure {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.system(size: 11))
                            Text("Fast extraction failed — \(failure.reason)")
                                .font(.system(size: 11))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                        }
                        Button {
                            fastFailure = nil
                            Task {
                                await runCanvasFallback(videoID: failure.videoID,
                                                        folderURL: failure.folderURL)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "tortoise.fill").font(.system(size: 11))
                                Text("Use fallback approach (slower)")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(Color.accentColor)
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.red.opacity(0.35), lineWidth: 1))
                    .transition(.opacity)
                }

                // Background frame progress
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
                        Text("Extracting frames \(Int(frameProgress * 100))%")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                case .done(let count):
                    frameStatusRow(text: "\(count) frames saved ✓", showSpinner: false)
                case .failed(let msg):
                    Text("Frames failed: \(msg)").font(.system(size: 11)).foregroundStyle(.red)
                default:
                    EmptyView()
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func actionButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(label).font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(color)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func fetch() async {
        withAnimation(.spring(duration: 0.3)) { state = .loading }
        // Reset cross-platform state on every new fetch.
        shortFormPreview = nil
        lastResult = nil
        switch detectedPlatform {
        case .youtube:
            do {
                let result = try await loader.fetch(urlString: urlInput)
                lastResult = result
                withAnimation(.spring(duration: 0.4)) {
                    state = .success(title: result.title, markdown: result.markdown)
                }
            } catch {
                withAnimation(.spring(duration: 0.3)) {
                    state = .error(error.localizedDescription)
                }
            }
        case .tiktok, .instagram:
            guard let url = URL(string: urlInput) else {
                state = .error("Invalid URL.")
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
        await fetch()
        // Instagram login in progress — sheet handler will re-call us.
        if showInstagramLogin { return }
        // Fetch failed (no preview, no result) → tell the funnel we're done.
        if lastResult == nil && shortFormPreview == nil {
            finishExternalIngest()
            return
        }
        saveToVault()
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

    private func saveToVault() {
        vaultError = nil

        // No vault configured — prompt the user to choose one first
        if vault.vaultURL == nil {
            vault.chooseVault()
            guard vault.vaultURL != nil else { return }
        }

        // Short-form (Instagram / TikTok) path.
        if let preview = shortFormPreview {
            withAnimation { vaultSaved = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { self.vaultSaved = false }
            }
            Task { @MainActor in
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
                                 folderURL: outcome.folder)
                    triggerIndexer(bundleFolder: outcome.folder)
                } catch {
                    vaultError = error.localizedDescription
                    finishExternalIngest()
                }
            }
            return
        }

        // YouTube path (unchanged).
        guard let result = lastResult else {
            vaultError = "No transcript loaded."
            finishExternalIngest()
            return
        }
        let metadata = MetadataEnricher.enrich(from: result)
        do {
            let folderURL = try vault.saveNote(result: result, metadata: metadata)
            withAnimation { vaultSaved = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { self.vaultSaved = false }
            }
            let videoID = result.videoID
            Task {
                await runFramePipeline(videoID: videoID, folderURL: folderURL)
            }
        } catch {
            vaultError = error.localizedDescription
            finishExternalIngest()
        }
    }

    @ViewBuilder
    private func frameStatusRow(text: String, showSpinner: Bool) -> some View {
        HStack(spacing: 6) {
            if showSpinner { ProgressView().controlSize(.mini) }
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func runFramePipeline(videoID: String, folderURL: URL) async {
        frameProgress = 0
        downloadProgress = 0
        fastFailure = nil

        let pipeline: any FramePipeline = FastFramePipeline(
            playerFetcher: playerFetcher,
            vault: vault,
            settings: settings
        )
        let outcome = await pipeline.extract(videoID: videoID, folderURL: folderURL) { stage in
            applyStage(stage)
        }
        applyOutcome(outcome, videoID: videoID, folderURL: folderURL)
        if case .success = outcome {
            triggerIndexer(bundleFolder: folderURL)
        }
    }

    /// Best-effort, non-blocking Phase B index. Skipped when the user has
    /// disabled it in Settings, or when no vault is configured. Failures
    /// (no API key, network) are logged only — the save itself is already
    /// complete and the user shouldn't see a UI banner for an optional
    /// background step. The user can always re-run via Settings → Re-index.
    private func triggerIndexer(bundleFolder: URL) {
        guard settings.indexerEnabled else { return }
        guard let vaultURL = vault.vaultURL else { return }
        let videoMd = bundleFolder.appendingPathComponent("video.md")
        Task.detached(priority: .background) {
            let acquired = vaultURL.startAccessingSecurityScopedResource()
            defer { if acquired { vaultURL.stopAccessingSecurityScopedResource() } }
            do {
                try await Indexer.indexBundle(videoMdURL: videoMd, vaultRoot: vaultURL)
            } catch {
                NSLog("[youty] indexer skipped/failed: \(error.localizedDescription)")
            }
            do {
                try await Indexer.indexFrames(videoMdURL: videoMd, vaultRoot: vaultURL)
            } catch {
                NSLog("[youty] frame indexer skipped/failed: \(error.localizedDescription)")
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
                              folderURL: URL) {
        switch outcome {
        case .success(let count, let ms, let mode):
            NSLog("[youty] \(mode): \(count) frames in \(ms)ms")
            withAnimation { vault.frameState = .done(count) }
            SpotlightIndexer.indexBundle(at: folderURL, vault: vault)
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
            try? content.write(to: url, atomically: true, encoding: .utf8)
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

