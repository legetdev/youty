import Foundation

// Hand-written help text. Short, no over-explanation. Mirrors the
// `--help` shape of every well-behaved Unix CLI.

enum HelpCommand {

    static func printRoot() {
        let text = """
        youty — save YouTube, Instagram, and TikTok videos to a local vault.

        USAGE
          youty <command> [options]

        COMMANDS
          save        save a URL to the vault (transcript + frames + index)
          list        list saved videos in the vault
          search      keyword search across saved videos
          transcript  print a saved video's transcript
          reindex     rebuild the search index (e.g. switch to on-device search)
          login       sign in to a platform (required once for Instagram)

        OPTIONS
          --vault PATH     vault folder (overrides config + Mac app's saved choice)
          --help, -h       show help
          --version, -v    show version

        EXAMPLES
          youty save https://www.youtube.com/watch?v=GmM5Sg8RGBA
          youty list --platform youtube
          youty search "ai influencers" --limit 5
          youty transcript https://www.youtube.com/watch?v=GmM5Sg8RGBA

        Run `youty <command> --help` for command-specific help.
        """
        Swift.print(text)
    }

    static func print(for command: String) {
        switch command {
        case "save":       emit(saveHelp)
        case "list":       emit(listHelp)
        case "search":     emit(searchHelp)
        case "transcript": emit(transcriptHelp)
        case "reindex":    emit(reindexHelp)
        case "login":      emit(loginHelp)
        default:
            FileHandle.standardError.write("youty: no help topic '\(command)'\n".data(using: .utf8)!)
            Swift.print("")
            printRoot()
        }
    }

    private static func emit(_ text: String) {
        Swift.print(text)
    }

    // MARK: - Per-command help

    private static let saveHelp = """
    youty save — save a URL to the vault.

    USAGE
      youty save <url> [options]

    OPTIONS
      --vault PATH        vault folder (default: from Mac app, or pass explicitly)
      --count N           max frames per video (default: 100)
      --fps N             max frames per second (default: 1.0)
      --resolution P      source resolution: 720, 1080, 1440, 2160 (default: 1080)
      --json              emit JSON metadata to stdout instead of just the path
      --quiet, -q         suppress progress output to stderr
      --no-index          skip the post-save SQLite index update

    EXAMPLES
      youty save https://www.youtube.com/watch?v=GmM5Sg8RGBA
      youty save https://www.tiktok.com/@user/video/12345 --vault ~/Vault
      youty save URL --count 250 --fps 2 --json
    """

    private static let reindexHelp = """
    youty reindex — rebuild the local search index for the vault.

    USAGE
      youty reindex [options]

    OPTIONS
      --text-only         re-embed transcript text only (frames untouched) —
                          the fast path to refresh an existing index on-device
      --vault PATH        vault folder (default: from Mac app, or pass explicitly)
      --quiet, -q         suppress progress output to stderr

    EXAMPLES
      youty reindex                       # full rebuild (text + frames)
      youty reindex --text-only           # migrate text to on-device, keep frames
    """

    private static let listHelp = """
    youty list — list saved videos.

    USAGE
      youty list [options]

    OPTIONS
      --vault PATH        vault folder
      --platform NAME     filter: youtube, tiktok, or instagram
      --limit N           cap result count (default: no cap)
      --text              human-readable table instead of JSON

    EXAMPLES
      youty list
      youty list --platform youtube --limit 10
      youty list --text
    """

    private static let searchHelp = """
    youty search — keyword search across saved videos.

    USAGE
      youty search <query> [options]

    OPTIONS
      --vault PATH        vault folder
      --limit N           cap result count (default: 10)
      --text              human-readable table instead of JSON

    EXAMPLES
      youty search "ai influencers"
      youty search karpathy --limit 3 --text
    """

    private static let transcriptHelp = """
    youty transcript — print a saved video's transcript.

    USAGE
      youty transcript <url-or-id> [options]

    The argument can be the original post URL or the platform-qualified
    id (e.g. `yt:GmM5Sg8RGBA`, `tt:7234…`, `ig:DEF…`).

    OPTIONS
      --vault PATH        vault folder
      --json              emit {title, text} JSON instead of plain text

    EXAMPLES
      youty transcript https://www.youtube.com/watch?v=GmM5Sg8RGBA
      youty transcript yt:GmM5Sg8RGBA --json
    """

    private static let loginHelp = """
    youty login — sign in to a platform.

    USAGE
      youty login <platform>

    Only Instagram needs this. YouTube and TikTok work anonymously. The CLI's
    web session is separate from the Mac app's; signing in here persists
    cookies on disk so subsequent `youty save` calls authenticate.

    SUPPORTED PLATFORMS
      instagram    opens a native sign-in window pointed at instagram.com.
                   Sign in normally; the window closes automatically when
                   Instagram redirects you off the login page.

    EXAMPLES
      youty login instagram
      # …then…
      youty save https://www.instagram.com/reel/DA5fbWyREMt/
    """
}
