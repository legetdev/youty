import SwiftUI

// Custom @main so the same binary can run headless for verification
// (--extract <url> ...) without bringing up the SwiftUI window. See
// DebugRunner.swift.
@main
struct AppMain {
    static func main() {
        if DebugRunner.shouldRun() {
            DebugRunner.run()  // calls exit() — never returns
        }
        YoutyApp.main()
    }
}

struct YoutyApp: App {
    // AppKit-side responsibilities (NSServices provider, queue re-drain on
    // activation). The SwiftUI lifecycle doesn't expose these directly.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var menuBar = MenuBarController()
    @StateObject private var settings = SettingsStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .onAppear {
                    menuBar.apply(showing: settings.menuBarEnabled)
                }
                .onChange(of: settings.menuBarEnabled) { _, newValue in
                    menuBar.apply(showing: newValue)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 560)
    }

    /// Handle `youty://save?url=...` (Share Extension, AppIntent, manual)
    /// and `youty://open?folder=...` (Spotlight handoff).
    private func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "youty" else { return }
        let host = url.host?.lowercased() ?? ""
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        switch host {
        case "save":
            if let urlParam = components?.queryItems?.first(where: { $0.name == "url" })?.value,
               !urlParam.isEmpty {
                IngestionFunnel.shared.ingest(urlString: urlParam, source: "scheme")
            }
        case "open":
            // Spotlight click → reveal bundle in Finder. The folder param is
            // relative to the vault root (e.g. "youtube/Channel - Title").
            if let folderParam = components?.queryItems?.first(where: { $0.name == "folder" })?.value {
                SpotlightIndexer.revealBundle(relativePath: folderParam)
            }
        default:
            break
        }
    }
}
