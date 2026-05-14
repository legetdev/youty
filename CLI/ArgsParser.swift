import Foundation

// Tiny hand-rolled argv parser. We don't pull in swift-argument-parser
// because the global rules forbid third-party Swift Packages. The CLI's
// surface is small (4 subcommands, a handful of flags) so this is fine.

struct ParsedArgs {
    /// First positional argument that doesn't start with `-`. For
    /// subcommand dispatch we treat the first non-flag token as the
    /// subcommand name.
    let subcommand: String?

    /// All remaining positional arguments after the subcommand.
    let positionals: [String]

    /// Long flags: `--name value` → "name": "value", or `--name` →
    /// "name": "" for bare boolean-style flags.
    let flags: [String: String]

    /// Bare bool flags like `--quiet`, `--json`. Distinguished from
    /// value-bearing flags by absence of a following value.
    let bools: Set<String>

    /// Whether `--help` or `-h` was present anywhere on the command line.
    let wantsHelp: Bool

    /// Whether `--version` or `-v` was present.
    let wantsVersion: Bool

    func value(for key: String) -> String? {
        return flags[key]
    }

    func intValue(for key: String) -> Int? {
        guard let raw = flags[key] else { return nil }
        return Int(raw)
    }

    func doubleValue(for key: String) -> Double? {
        guard let raw = flags[key] else { return nil }
        return Double(raw)
    }

    func bool(_ key: String) -> Bool {
        return bools.contains(key)
    }
}

enum ArgsParser {

    /// Parse a vector of raw argv tokens, skipping `argv[0]` (the binary
    /// path). The parser is forgiving: unknown flags don't error, they
    /// just land in `flags` for the subcommand to inspect or ignore.
    ///
    /// Recognises:
    ///   • `--key=value` and `--key value` for long flags
    ///   • `--key` (bare) as a boolean flag
    ///   • `-h`, `--help`, `-v`, `--version` short-circuits
    ///   • `--` ends flag parsing (everything after is positional)
    static func parse(_ argv: [String]) -> ParsedArgs {
        var args = Array(argv.dropFirst())

        var wantsHelp = false
        var wantsVersion = false
        var flags: [String: String] = [:]
        var bools: Set<String> = []
        var positionals: [String] = []
        var subcommand: String?

        // Pre-pass: pull out --help / --version so they short-circuit
        // even if mixed with subcommand syntax.
        args.removeAll { token in
            switch token {
            case "-h", "--help":    wantsHelp = true;    return true
            case "-v", "--version": wantsVersion = true; return true
            default:                                     return false
            }
        }

        var afterDoubleDash = false
        var i = 0
        while i < args.count {
            let token = args[i]
            if afterDoubleDash {
                positionals.append(token)
                i += 1
                continue
            }
            if token == "--" {
                afterDoubleDash = true
                i += 1
                continue
            }
            if token.hasPrefix("--") {
                let body = String(token.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    let key = String(body[..<eq])
                    let value = String(body[body.index(after: eq)...])
                    flags[key] = value
                    i += 1
                    continue
                }
                // Look ahead for a value. If the next token starts with `-`
                // or isn't present, this is a bool flag.
                if i + 1 < args.count, !args[i + 1].hasPrefix("-") {
                    flags[body] = args[i + 1]
                    i += 2
                } else {
                    bools.insert(body)
                    i += 1
                }
                continue
            }
            if token.hasPrefix("-") && token.count > 1 {
                // Short flags. We support `-q` (quiet), `-j` (json) as
                // aliases the subcommand layers can map. Treat as bools.
                let key = String(token.dropFirst())
                bools.insert(key)
                i += 1
                continue
            }
            // Positional. First positional is the subcommand.
            if subcommand == nil {
                subcommand = token
            } else {
                positionals.append(token)
            }
            i += 1
        }

        return ParsedArgs(
            subcommand: subcommand,
            positionals: positionals,
            flags: flags,
            bools: bools,
            wantsHelp: wantsHelp,
            wantsVersion: wantsVersion
        )
    }
}
