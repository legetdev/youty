import Cocoa
import SwiftUI
import UniformTypeIdentifiers

// macOS Share Extension entry point.
//
// Activation rule (Info.plist): web URL with max count 1 OR text.
// Behavior:
//   1. Extract a URL from the incoming NSExtensionItem(s).
//   2. Reject anything that isn't a YouTube / Instagram / TikTok post URL.
//   3. Open the main app via `youty://save?url=…`. macOS LaunchServices
//      guarantees delivery: the main app launches if not running, gets
//      foregrounded if already running, and `youty://` reaches its
//      `.onOpenURL` handler exactly once.
//   4. Flash a tiny confirmation, then complete the extension request.
//
// The extension never touches the vault directly. It is sandboxed with
// no network / no filesystem entitlements — only the launch of the URL
// scheme via NSWorkspace.

final class ShareViewController: NSViewController {

    private var hostingView: NSHostingView<ShareConfirmationView>?
    private var state: ShareState = .working {
        didSet { rebuildHosting() }
    }

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 140))
        view.wantsLayer = true
        self.view = view
        rebuildHosting()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        processIncomingItems()
    }

    private func rebuildHosting() {
        if let existing = hostingView {
            existing.removeFromSuperview()
        }
        let host = NSHostingView(rootView: ShareConfirmationView(state: state))
        host.frame = view.bounds
        host.autoresizingMask = [.width, .height]
        view.addSubview(host)
        hostingView = host
    }

    private func processIncomingItems() {
        Task { @MainActor in
            do {
                let raw = try await extractURLString()
                guard let urlString = sanitize(raw),
                      let _ = URL(string: urlString),
                      ShareURLClassifier.isSupported(urlString) else {
                    state = .unsupported
                    completeAfterDelay(success: false, delay: 1.4)
                    return
                }
                openMainApp(urlString: urlString)
                state = .saved
                completeAfterDelay(success: true, delay: 0.6)
            } catch {
                state = .failed(error.localizedDescription)
                completeAfterDelay(success: false, delay: 1.6)
            }
        }
    }

    // MARK: - NSExtensionItem extraction

    private func extractURLString() async throws -> String {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            throw ShareError.noInput
        }
        // First pass: URL attachments (Safari, NSItemProvider URLs).
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    if let s = try await loadURL(from: provider) { return s }
                }
            }
        }
        // Second pass: plain text containing a URL.
        for item in items {
            if let text = item.attributedContentText?.string, !text.isEmpty {
                if let s = firstURL(in: text) { return s }
            }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    if let s = try await loadText(from: provider), let url = firstURL(in: s) {
                        return url
                    }
                }
            }
        }
        throw ShareError.noURL
    }

    private func loadURL(from provider: NSItemProvider) async throws -> String? {
        try await withCheckedThrowingContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
                if let error = error { cont.resume(throwing: error); return }
                if let url = item as? URL { cont.resume(returning: url.absoluteString); return }
                if let data = item as? Data, let s = String(data: data, encoding: .utf8) {
                    cont.resume(returning: s); return
                }
                if let s = item as? String { cont.resume(returning: s); return }
                cont.resume(returning: nil)
            }
        }
    }

    private func loadText(from provider: NSItemProvider) async throws -> String? {
        try await withCheckedThrowingContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
                if let error = error { cont.resume(throwing: error); return }
                if let s = item as? String { cont.resume(returning: s); return }
                if let data = item as? Data, let s = String(data: data, encoding: .utf8) {
                    cont.resume(returning: s); return
                }
                cont.resume(returning: nil)
            }
        }
    }

    private func firstURL(in text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        if let match = detector.firstMatch(in: text, range: range), let url = match.url {
            return url.absoluteString
        }
        return nil
    }

    private func sanitize(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Launch

    private func openMainApp(urlString: String) {
        var components = URLComponents()
        components.scheme = "youty"
        components.host = "save"
        components.queryItems = [URLQueryItem(name: "url", value: urlString)]
        if let launchURL = components.url {
            NSWorkspace.shared.open(launchURL)
        }
    }

    private func completeAfterDelay(success: Bool, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            if success {
                self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            } else {
                self.extensionContext?.cancelRequest(withError: ShareError.noURL)
            }
        }
    }
}

// MARK: - URL classifier (duplicated minimal logic so the extension stays
// independent of the main app's PlatformRouter — the extension target
// pulls in zero shared Swift sources to keep its sandbox + binary tiny).

enum ShareURLClassifier {
    static func isSupported(_ urlString: String) -> Bool {
        let s = urlString.lowercased()
        return s.contains("youtube.com/")
            || s.contains("youtu.be/")
            || s.contains("tiktok.com/")
            || s.contains("vm.tiktok.com/")
            || s.contains("instagram.com/reel/")
            || s.contains("instagram.com/p/")
            || s.contains("instagram.com/tv/")
            || s.contains("instagram.com/reels/")
    }
}

// MARK: - Errors

enum ShareError: LocalizedError {
    case noInput
    case noURL

    var errorDescription: String? {
        switch self {
        case .noInput: return "No content was shared."
        case .noURL:   return "No supported URL found."
        }
    }
}

// MARK: - Confirmation view

enum ShareState: Equatable {
    case working
    case saved
    case unsupported
    case failed(String)
}

struct ShareConfirmationView: View {
    let state: ShareState

    var body: some View {
        VStack(spacing: 10) {
            icon
                .font(.system(size: 36, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
            if let detail = detail {
                Text(detail)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .working:           ProgressView().controlSize(.large)
        case .saved:             Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
        case .unsupported:       Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        case .failed:            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var title: String {
        switch state {
        case .working:           return "Sending to Youty…"
        case .saved:             return "Sent to Youty"
        case .unsupported:       return "Not a supported video URL"
        case .failed:            return "Could not send to Youty"
        }
    }

    private var detail: String? {
        switch state {
        case .working:           return nil
        case .saved:             return "Opening the app to save."
        case .unsupported:       return "Youty saves YouTube, Instagram, and TikTok posts."
        case .failed(let msg):   return msg
        }
    }
}
