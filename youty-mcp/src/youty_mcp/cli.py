"""Console-script entry for `youty-mcp`.

Bare `youty-mcp` (what MCP clients launch via `uvx youty-mcp@latest`) runs the
stdio server. The human-facing subcommands below route to the installer instead.
Anything not recognized falls through to the server, so an MCP client that passes
an unexpected flag is never misrouted into the installer.
"""

from __future__ import annotations

import sys

# Recognized human subcommands. Everything else → run the server.
_SUBCOMMANDS = {
    "install", "uninstall", "list", "--list",
    "help", "--help", "-h", "version", "--version", "-v",
}


def main() -> None:
    args = sys.argv[1:]
    if args and args[0] in _SUBCOMMANDS:
        from . import install
        install.dispatch(args)
        return
    # Default: the stdio MCP server (the entry MCP clients launch).
    from .server import main as server_main
    server_main()
