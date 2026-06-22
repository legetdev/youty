import Foundation

// Phase M entry point — the `youty` CLI binary.
//
// Single-binary command-line wrapper around the same extractor + vault +
// indexer pipeline the Mac app uses. No GUI surface. Same FFmpeg
// statically linked.
//
// Subcommands:
//   save       — save a URL to the vault (transcript + frames + index)
//   list       — list saved videos
//   search     — keyword search across saved videos
//   transcript — print a saved video's transcript

let version = "1.4.4"

let args = ArgsParser.parse(CommandLine.arguments)

if args.wantsVersion {
    print("youty \(version)")
    exit(0)
}

// `youty` with no subcommand prints help, exits 0.
guard let subcommand = args.subcommand else {
    HelpCommand.printRoot()
    exit(args.wantsHelp ? 0 : 0)
}

if args.wantsHelp {
    HelpCommand.print(for: subcommand)
    exit(0)
}

switch subcommand {
case "save":       SaveCommand.run(args)
case "list":       ListCommand.run(args)
case "search":     SearchCommand.run(args)
case "embed":      EmbedCommand.run(args)
case "transcript": TranscriptCommand.run(args)
case "reindex":    ReindexCommand.run(args)
case "login":      LoginCommand.run(args)
case "help":
    if let topic = args.positionals.first {
        HelpCommand.print(for: topic)
    } else {
        HelpCommand.printRoot()
    }
    exit(0)
default:
    FileHandle.standardError.write("youty: unknown command '\(subcommand)'\n".data(using: .utf8)!)
    FileHandle.standardError.write("Run `youty --help` to see available commands.\n".data(using: .utf8)!)
    exit(64)
}
