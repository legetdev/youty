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
    @State private var urlInput = ""
    @State private var state: AppState = .idle
    @State private var lastResult: FetchResult?
    @State private var vaultSaved = false
    @State private var vaultError: String?
    @State private var frameProgress: Double = 0
    @State private var showCopied = false
    @FocusState private var inputFocused: Bool

    private var isValidURL: Bool {
        TranscriptFetcher.extractVideoID(from: urlInput) != nil
    }

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.top, 32)
                    .padding(.bottom, 28)

                inputSection
                    .padding(.horizontal, 24)

                resultSection
            }
            .padding(.bottom, 24)
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
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Text("youty")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Text("Paste a YouTube link. Get the transcript.")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Input

    private var inputSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                TextField("https://youtube.com/watch?v=...", text: $urlInput)
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

            fetchButton
        }
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
        return "Get Transcript"
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

                // Background frame progress
                switch vault.frameState {
                case .capturingStream:
                    frameStatusRow(text: "Loading video…", showSpinner: true)
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
    }

    private func saveToVault() {
        guard let result = lastResult else {
            vaultError = "No transcript loaded."
            return
        }
        vaultError = nil

        // No vault configured — prompt the user to choose one first
        if vault.vaultURL == nil {
            vault.chooseVault()
            guard vault.vaultURL != nil else { return }
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
        do {
            // WKWebView canvas: the only approach that gives 100 correct frames for ALL videos.
            // The download + AVFoundation approach only works for videos with H.264 720p — many
            // videos only have H.264 480p which YouTube truncates to the first 50% of content.
            withAnimation { vault.frameState = .capturingStream }
            try await videoExtractor.loadVideo(videoID: videoID)
            let duration = await videoExtractor.getVideoDuration()
            guard duration > 0 else {
                throw NSError(domain: "youty", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not determine video duration."])
            }
            let timestamps = FrameExtractor.frameTimes(duration: duration)
            withAnimation { vault.frameState = .extracting }
            let captured = try await videoExtractor.captureFrames(timestamps: timestamps) { p in
                Task { @MainActor in self.frameProgress = p }
            }
            let frames = captured.map { FrameExtractor.Frame(timestamp: $0.0, image: $0.1) }

            guard !frames.isEmpty else {
                throw NSError(domain: "youty", code: -1, userInfo: [NSLocalizedDescriptionKey: "Frame extraction produced 0 frames."])
            }
            try vault.writeFrames(frames, to: folderURL)
            withAnimation { vault.frameState = .done(frames.count) }

        } catch {
            withAnimation { vault.frameState = .failed(error.localizedDescription) }
        }
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

