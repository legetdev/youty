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
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 560)
    }
}
