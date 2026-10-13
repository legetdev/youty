"""Youty MCP server — search, read, watch, and save videos in a local Youty vault."""


def __getattr__(name: str) -> str:
    # Resolved on first use: the search helper process imports this package
    # too, and reading package metadata would add ~60 ms to every search
    # that has to start it.
    if name == "__version__":
        from importlib.metadata import PackageNotFoundError, version

        try:
            return version("youty-mcp")
        except PackageNotFoundError:  # running from a source tree without installation
            return "0.0.0"
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
