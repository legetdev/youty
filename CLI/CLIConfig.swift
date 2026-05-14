import Foundation

// Tiny JSON-backed config for the standalone CLI. Stored at
// `~/Library/Application Support/Youty/cli-config.json`. The only field
// we persist is the vault path — everything else is per-invocation
// flags. Created on first save, never overwrites anything the user
// passes via --vault.
//
// The spec called for TOML at `~/.config/youty/config.toml`; we use JSON
// instead because Swift has built-in JSON and we can't pull in a TOML
// parser (no third-party packages rule).

struct CLIConfig: Codable {
    var vaultPath: String?
}

enum CLIConfigStore {

    static func read() -> CLIConfig {
        guard let url = configURL(),
              let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(CLIConfig.self, from: data) else {
            return CLIConfig(vaultPath: nil)
        }
        return cfg
    }

    @discardableResult
    static func write(_ cfg: CLIConfig) -> Bool {
        guard let url = configURL() else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(cfg).write(to: url, options: .atomic)
            return true
        } catch {
            FileHandle.standardError.write(
                "warning: failed to write CLI config: \(error.localizedDescription)\n"
                    .data(using: .utf8)!
            )
            return false
        }
    }

    private static func configURL() -> URL? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return nil }
        return appSupport
            .appendingPathComponent("Youty", isDirectory: true)
            .appendingPathComponent("cli-config.json")
    }
}
