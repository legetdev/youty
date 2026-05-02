import SwiftUI
import AppKit
import WebKit

enum AppState {
    case idle
    case loading
    case success(title: String, markdown: String)
    case error(String)
}

struct ContentView: View {
    @StateObject private var loader = TranscriptLoader()
    @State private var urlInput = ""
    @State private var state: AppState = .idle
    @State private var showCopied = false
    @FocusState private var inputFocused: Bool

    private var isValidURL: Bool {
        TranscriptFetcher.extractVideoID(from: urlInput) != nil
    }

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            // Hidden WKWebView — must be in hierarchy for JS execution
            WebViewContainer(webView: loader.webView)
                .frame(width: 1, height: 1)
                .opacity(0)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                header
                    .padding(.top, 32)
                    .padding(.bottom, 28)

                inputSection
                    .padding(.horizontal, 24)

                resultSection
                    .padding(.horizontal, 24)
                    .padding(.top, 20)

                Spacer(minLength: 0)
            }
            .padding(.bottom, 24)
        }
        .frame(width: 520)
        .onAppear { checkClipboard() }
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
                    actionButton(icon: "arrow.down.circle", label: "Save as Markdown", color: .accentColor) {
                        saveMarkdown(markdown, title: title)
                    }
                }
            }
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
            let (title, markdown) = try await loader.fetch(urlString: urlInput)
            withAnimation(.spring(duration: 0.4)) {
                state = .success(title: title, markdown: markdown)
            }
        } catch {
            withAnimation(.spring(duration: 0.3)) {
                state = .error(error.localizedDescription)
            }
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

// MARK: - WebView Container

struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
