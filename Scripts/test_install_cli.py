"""Verify failed model preparation leaves an existing CLI installation intact."""

import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


class InstallCLITests(unittest.TestCase):
    """Exercise the real installer with tiny assets and stubbed Apple tools."""

    def check_compile_failure(self, failed_model):
        """Run one failing compiler stage against an isolated existing install."""
        with tempfile.TemporaryDirectory(prefix="youty-install-test-") as directory:
            root = Path(directory)
            scripts = root / "Scripts"
            scripts.mkdir()
            resources = root / "resources"
            resources.mkdir()
            install_dir = root / "bin"
            install_dir.mkdir()
            tools = root / "tools"
            tools.mkdir()

            def executable(path, body):
                """Write an executable fixture, never a real installed tool."""
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("#!/bin/bash\n" + body)
                path.chmod(0o755)

            executable(scripts / "fetch-models.sh", "exit 0\n")
            executable(tools / "xcodebuild", 'printf "%s\\n" "$@" > "$YOUTY_FIXTURE_ARGS"\n')
            executable(tools / "xcrun", """
case "$3" in
  *SigLIP*) name=SigLIP-Base-224_image; kind=image ;;
  *) name=EmbeddingGemma-300m_text; kind=text ;;
esac
if [ "$kind" = "$YOUTY_FIXTURE_FAILURE" ]; then exit 1; fi
if [ "$YOUTY_FIXTURE_FAILURE" != missing-output ]; then mkdir -p "$4/$name.mlmodelc"; fi
""")
            executable(root / "build/release/Build/Products/Release/youty", "exit 0\n")
            for name in ("SigLIP-Base-224_image", "EmbeddingGemma-300m_text"):
                model = resources / (name + ".mlmodelc")
                model.mkdir()
                (model / "original").write_text("original model")
            for relative in ("Sources/IndexSchema.sql", "Vendor/embeddinggemma/tokenizer/vocab.bin",
                             "Vendor/embeddinggemma/tokenizer/merges.bin",
                             "Vendor/embeddinggemma/tokenizer/added_tokens.bin"):
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("new asset")
            for relative in ("Vendor/siglip/models/SigLIP-Base-224_image.mlpackage",
                             "Vendor/embeddinggemma/models/EmbeddingGemma-300m_text.mlpackage"):
                (root / relative).mkdir(parents=True)
            for name in ("IndexSchema.sql", "vocab.bin", "merges.bin", "added_tokens.bin"):
                (resources / name).write_text("original asset")
            (install_dir / "youty").write_text("original executable")
            before = {str(p): p.read_bytes() for p in root.rglob("*")
                      if p.is_file() and (resources in p.parents or install_dir in p.parents)}
            source = Path(__file__).with_name("install-cli.sh").read_text()
            destination = 'RES_DIR="$HOME/Library/Application Support/Youty/resources"'
            self.assertEqual(source.count(destination), 1)
            (scripts / "install-cli.sh").write_text(
                source.replace(destination, "RES_DIR=" + shlex.quote(str(resources))))
            args_file = root / "build-args"
            result = subprocess.run(["bash", str(scripts / "install-cli.sh")],
                                    env={**os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"],
                                         "YOUTY_INSTALL_DIR": str(install_dir),
                                         "YOUTY_FIXTURE_ARGS": str(args_file),
                                         "YOUTY_FIXTURE_FAILURE": failed_model},
                                    text=True, capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("existing installation is unchanged", result.stderr)
            self.assertIn("ARCHS=arm64", args_file.read_text().splitlines())
            for path, content in before.items():
                self.assertEqual(Path(path).read_bytes(), content)

    def test_image_compilation_failure(self):
        """The first compilation failure cannot remove installed resources."""
        self.check_compile_failure("image")

    def test_text_compilation_failure(self):
        """A successful image compile followed by text failure remains harmless."""
        self.check_compile_failure("text")

    def test_missing_compiler_output(self):
        """Even a zero compiler exit must provide both expected model directories."""
        self.check_compile_failure("missing-output")


if __name__ == "__main__":
    unittest.main()
