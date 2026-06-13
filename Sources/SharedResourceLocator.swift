import Foundation

/// Locates bundled resources (the SigLIP image encoder, the SQLite index
/// schema) for execution contexts where `Bundle.main` can't find them —
/// chiefly the standalone `youty` CLI binary, which is a bare Mach-O tool
/// with no `Resources/` of its own.
///
/// The Mac app always resolves these from its own bundle first; this is the
/// shared fallback both surfaces consult, so the CLI gains the *exact same*
/// indexing behaviour as the app. `Scripts/install-cli.sh` populates the
/// shared directory at install time.
enum SharedResourceLocator {

    /// Stable per-user location the CLI installer drops resources into:
    /// `~/Library/Application Support/Youty/resources/`. Matches the
    /// directory the CLI already uses for `cli-config.json`.
    static var sharedResourcesDir: URL? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) else { return nil }
        return appSupport.appendingPathComponent("Youty/resources", isDirectory: true)
    }

    /// Directories searched, in priority order:
    ///   1. the CLI installer's per-user drop (`install-cli.sh`);
    ///   2. a `share/youty/` dir next to the binary — the standard Unix
    ///      layout a Homebrew formula installs into (`<prefix>/bin/youty`
    ///      + `<prefix>/share/youty/…`);
    ///   3. a co-installed Mac app's bundled `Resources/` (so a user who
    ///      has both never needs a duplicate copy).
    private static var searchDirs: [URL] {
        var dirs: [URL] = []
        if let shared = sharedResourcesDir { dirs.append(shared) }
        if let exe = Bundle.main.executableURL {
            dirs.append(exe.deletingLastPathComponent()   // bin/
                           .deletingLastPathComponent()   // <prefix>/
                           .appendingPathComponent("share/youty", isDirectory: true))
        }
        dirs.append(URL(fileURLWithPath: "/Applications/youty.app/Contents/Resources"))
        return dirs
    }

    /// First existing `name.ext` across the search dirs (extensions tried in
    /// the given order), or `nil` if none is present.
    static func url(named name: String, extensions: [String]) -> URL? {
        for dir in searchDirs {
            for ext in extensions {
                let candidate = dir.appendingPathComponent("\(name).\(ext)")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }
}
