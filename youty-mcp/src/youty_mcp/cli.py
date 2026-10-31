"""Console-script entry for `youty-mcp`.

Bare `youty-mcp` (what MCP clients launch via `uvx youty-mcp@latest`) runs the
stdio server. The human-facing subcommands below route to the installer instead.
Anything not recognized falls through to the server, so an MCP client that passes
an unexpected flag is never misrouted into the installer.
"""

from __future__ import annotations

import os
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
    _relaunch_on_supported_python()
    from .server import main as server_main
    server_main()


def _relaunch_on_supported_python() -> None:
    """Restart the server on a supported Python when uvx picked another one.

    Entries written before 2.0.6 run `uvx youty-mcp@latest`, and uvx ignores
    Requires-Python when choosing an interpreter: on a Python without
    coremltools wheels search silently falls back to keywords. Nothing has
    been written to stdout yet, so replacing the process keeps the client's
    connection. Runs at most once, and stays put when uv can't be found."""
    from .clients import PYTHON_RANGE, SUPPORTED_PYTHON

    low, high = SUPPORTED_PYTHON
    running = _python_version()
    if low <= running < high or sys.platform != "darwin" or os.environ.get("YOUTY_RELAUNCHED"):
        return
    from . import __version__

    package = f"youty-mcp=={__version__}" if __version__ != "0.0.0" else "youty-mcp@latest"
    uv = os.environ.get("UV")  # uvx and uv tool run point their child at themselves
    uvx = None if uv else _which("uvx")
    if not (uv or uvx):
        return
    command = [uv, "tool", "run"] if uv else [uvx]
    print(f"youty-mcp: Python {running[0]}.{running[1]} is not supported; "
          f"restarting on Python {PYTHON_RANGE}", file=sys.stderr)
    try:
        os.execve(command[0], [*command, "--python", PYTHON_RANGE, package, *sys.argv[1:]],
                  {**os.environ, "YOUTY_RELAUNCHED": "1"})
    except OSError as exc:
        print(f"youty-mcp: couldn't restart ({exc}); continuing", file=sys.stderr)


def _python_version() -> tuple[int, int]:
    return sys.version_info[:2]


def _which(name: str) -> str | None:
    import shutil

    return shutil.which(name)
