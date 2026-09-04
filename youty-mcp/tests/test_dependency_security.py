"""Keep published dependency requirements above the remediated security floors."""
from importlib.metadata import requires, version

from packaging.requirements import Requirement
from packaging.version import Version


def test_security_floors_and_removed_framework():
    """Check both the installed versions and requirements embedded in the wheel."""
    dependencies = {item.name: item for item in map(Requirement, requires("youty-mcp"))}
    for package, patched, vulnerable in [("mcp", "1.28.1", "1.28.0"), ("cryptography", "50.0.0", "49.0.0")]:
        assert Version(version(package)) >= Version(patched)
        assert patched in dependencies[package].specifier
        assert vulnerable not in dependencies[package].specifier
    assert "transformers" not in dependencies
    assert "0.2.2" not in dependencies["sentencepiece"].specifier
