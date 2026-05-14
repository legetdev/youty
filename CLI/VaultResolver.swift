import Foundation

// Resolve the vault path the CLI should operate against.
//
// Lookup order:
//   1. `--vault <path>` flag on the current invocation
//   2. CLI's persisted config (`~/Library/Application Support/Youty/cli-config.json`)
//   3. The Mac app's saved vault bookmark (UserDefaults under `dev.leget.youty`).
//      Means: if the user installed the Mac app first and picked a vault
//      in Settings, the CLI sees it automatically — no extra config.
//
// On `save`, after resolving we persist the chosen vault path to the CLI
// config so subsequent invocations don't need the flag.

enum VaultResolver {

    enum Source { case flag, cliConfig, appBookmark }

    struct Resolution {
        let url: URL
        let source: Source
    }

    /// Resolve the vault URL the CLI should use. Returns nil if no source
    /// produced a usable path. `persist: true` writes the resolved path
    /// back to the CLI config (used by `save` so future invocations work
    /// with no flags).
    @discardableResult
    static func resolve(flagValue: String?, persist: Bool = false) -> Resolution? {
        if let raw = flagValue, !raw.isEmpty {
            let url = expand(raw)
            if persist {
                var cfg = CLIConfigStore.read()
                cfg.vaultPath = url.path
                CLIConfigStore.write(cfg)
            }
            return Resolution(url: url, source: .flag)
        }
        let cfg = CLIConfigStore.read()
        if let raw = cfg.vaultPath, !raw.isEmpty {
            return Resolution(url: expand(raw), source: .cliConfig)
        }
        if let url = resolveFromMacApp() {
            // Cache the resolved path in the CLI config so we don't pay the
            // bookmark resolution cost again next time.
            if persist {
                var cfg = CLIConfigStore.read()
                cfg.vaultPath = url.path
                CLIConfigStore.write(cfg)
            }
            return Resolution(url: url, source: .appBookmark)
        }
        return nil
    }

    /// Friendly error message when no vault is resolvable.
    static let noVaultMessage = """
    error: no vault configured.

    Pass --vault PATH on the command line, or pick a vault in the Mac
    app's Settings → Vault. The CLI will remember it on the next save.
    """

    // MARK: - Internals

    /// Read the security-scoped bookmark the Mac app stores under the
    /// `vaultBookmark` key. The bookmark data is just a serialised URL
    /// reference — resolving it gives us the path. We don't start the
    /// security scope because the CLI binary isn't sandboxed.
    ///
    /// The Mac app is sandboxed, so its UserDefaults plist lives in its
    /// container, not at the system-wide
    /// `~/Library/Preferences/dev.leget.youty.plist` path. We therefore
    /// look in three places, in order:
    ///   1. `~/Library/Containers/dev.leget.youty/Data/Library/Preferences/dev.leget.youty.plist`
    ///      — where every sandboxed Mac-app build of Youty actually stores it.
    ///   2. `UserDefaults(suiteName: "dev.leget.youty")` — covers any future
    ///      unsandboxed build that uses the system-wide preferences domain.
    ///   3. `~/Library/Preferences/dev.leget.youty.plist` — same idea, in
    ///      case macOS's CFPreferences ever surfaces it that way.
    private static func resolveFromMacApp() -> URL? {
        let candidates: [() -> Data?] = [
            { Self.bookmarkFromSandboxPlist() },
            { UserDefaults(suiteName: "dev.leget.youty")?.data(forKey: "vaultBookmark") },
            { Self.bookmarkFromSystemPlist() },
        ]
        for source in candidates {
            guard let data = source() else { continue }
            // Try plain bookmark first. The Mac app's bookmark was created
            // with `.withSecurityScope`, but security-scoped resolution
            // requires matching code-signing identity — and the CLI's
            // bundle id (dev.leget.youty.cli) differs from the app's
            // (dev.leget.youty), so the scoped resolve refuses. The CLI
            // is unsandboxed, so it doesn't actually need the scope to
            // read the underlying URL — plain resolution lifts the path
            // out of the bookmark just fine.
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return url
            }
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return url
            }
        }
        return nil
    }

    /// The sandboxed-Mac-app plist path. NSHomeDirectory() returns the
    /// real user home here because the CLI itself isn't sandboxed.
    private static func bookmarkFromSandboxPlist() -> Data? {
        let path = "\(NSHomeDirectory())/Library/Containers/dev.leget.youty/Data/Library/Preferences/dev.leget.youty.plist"
        return readBookmark(atPath: path)
    }

    private static func bookmarkFromSystemPlist() -> Data? {
        let path = "\(NSHomeDirectory())/Library/Preferences/dev.leget.youty.plist"
        return readBookmark(atPath: path)
    }

    private static func readBookmark(atPath path: String) -> Data? {
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let plist = try? PropertyListSerialization.propertyList(
                  from: raw, format: nil
              ) as? [String: Any] else {
            return nil
        }
        return plist["vaultBookmark"] as? Data
    }

    private static func expand(_ raw: String) -> URL {
        let nsString = raw as NSString
        let expanded = nsString.expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }
}
