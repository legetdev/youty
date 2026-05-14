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
    /// `vaultBookmark` key in its UserDefaults domain. The bookmark
    /// data is just a serialized URL reference — resolving it gives us
    /// the path. We don't need to start/stop the security scope because
    /// the CLI binary isn't sandboxed.
    private static func resolveFromMacApp() -> URL? {
        // The Mac app's defaults live at ~/Library/Preferences/dev.leget.youty.plist
        // (or in CFPreferences storage). Open that domain explicitly so we
        // see it from our different bundle ID.
        guard let defaults = UserDefaults(suiteName: "dev.leget.youty"),
              let data = defaults.data(forKey: "vaultBookmark") else {
            return nil
        }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return nil
        }
        return url
    }

    private static func expand(_ raw: String) -> URL {
        let nsString = raw as NSString
        let expanded = nsString.expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }
}
