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
    // Hoisted from ContentView so the standalone Settings window can read
    // + write the same vault state without having to re-derive bookmarks.
    @StateObject private var vault = VaultManager()

    var body: some Scene {
        // Single-instance window. Previously this was a `WindowGroup`, but
        // every `youty://save?url=…` opened by the Share Sheet / AppIntent /
        // URL scheme was spawning a fresh WindowGroup window — and macOS's
        // "Prefer tabs when opening documents" setting was then auto-merging
        // those into tabs, so the user saw a tabbed window instead of the
        // intended single capture surface. `Window` guarantees one (and only
        // one) window for the app's lifetime; `MainWindowKeeper` then keeps
        // it alive across red-X clicks so the menu bar + background save
        // paths still find a host.
        Window("youty", id: "main") {
            ContentView()
                .environmentObject(settings)
                .environmentObject(vault)
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

        // Standalone Settings window. `.hiddenTitleBar` matches the main
        // app's seamless aesthetic — the traffic-light buttons sit
        // directly over the glass header, and the window stays draggable
        // from any non-control area at the top.
        Window("Settings", id: "settings") {
            SettingsHostView()
                .environmentObject(settings)
                .environmentObject(vault)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 560)
    }

    /// Handle `youty://save?url=...` from the Share Extension, AppIntents,
    /// and manual launches.
    private func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "youty",
              url.host?.lowercased() == "save",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let urlParam = components.queryItems?.first(where: { $0.name == "url" })?.value,
              !urlParam.isEmpty
        else { return }
        // Reject anything that isn't `http(s)://` before it reaches the
        // ingestion pipeline. Without this, a caller could craft
        // `youty://save?url=javascript:…` or `youty://save?url=file:///…`
        // and have us hand that string downstream.
        guard let inner = URL(string: urlParam),
              let scheme = inner.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else { return }
        IngestionFunnel.shared.ingest(urlString: urlParam, source: "scheme")
    }
}
