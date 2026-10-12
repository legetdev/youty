"""Keep published dependency requirements above the remediated security floors."""
from importlib.metadata import requires, version

from packaging.requirements import Requirement
from packaging.version import Version


def test_security_floors_and_lean_dependencies():
    """Check installed versions and the requirements embedded in the wheel."""
    dependencies = {item.name: item for item in map(Requirement, requires("youty-mcp"))}
    assert Version(version("mcp")) >= Version("2.3.0")
    assert "1.28.0" not in dependencies["mcp"].specifier
    assert Version(version("cryptography")) >= Version("50.0.0")  # via MCP's JWT support
    assert Version(version("pyjwt")) >= Version("2.15.0")  # via MCP's JWT support
    assert Version(version("anyio")) >= Version("4.14.2")
    for removed in ("transformers", "torch", "sentencepiece", "huggingface-hub", "httpx"):
        assert removed not in dependencies
