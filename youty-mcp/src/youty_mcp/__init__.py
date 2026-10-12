"""Youty MCP server — search, read, watch, and save videos in a local Youty vault."""

from importlib.metadata import PackageNotFoundError, version

try:
    __version__ = version("youty-mcp")
except PackageNotFoundError:  # running from a source tree without installation
    __version__ = "0.0.0"
