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

    /// Handle `youty://save?url=...` from the Share Extension, AppIntents,
    /// and manual launches.
    private func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "youty",
              url.host?.lowercased() == "save",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let urlParam = components.queryItems?.first(where: { $0.name == "url" })?.value,
              !urlParam.isEmpty
        else { return }
        IngestionFunnel.shared.ingest(urlString: urlParam, source: "scheme")
    }
}
