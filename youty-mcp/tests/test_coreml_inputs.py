"""Cover bounded input ownership and an opt-in real-model idle-cleanup check."""
import os
from contextlib import contextmanager
import subprocess
import sys
from types import SimpleNamespace

import numpy as np
import pytest

from youty_mcp import coreml_models


def test_failed_model_stream_removes_partial_archive(tmp_path, monkeypatch):
    """A mid-download disconnect leaves neither an archive nor extracted weights."""
    import httpx

    class InterruptedResponse:
        """Return some bytes before simulating a stalled connection."""

        def raise_for_status(self):
            """The connection succeeds before its body stalls."""

        def iter_bytes(self):
            """Exercise cleanup after actual partial-file writes."""
            yield b"partial archive"
            raise httpx.ReadTimeout("stalled download")

    @contextmanager
    def stream(*args, **kwargs):
        """Require a finite read timeout without contacting the network."""
        assert kwargs["timeout"] == 60
        yield InterruptedResponse()

    monkeypatch.setattr(coreml_models, "_CACHE", tmp_path / "cache")
    monkeypatch.setattr(coreml_models.tempfile, "tempdir", str(tmp_path))
    monkeypatch.setattr(httpx, "stream", stream)
    with pytest.raises(httpx.ReadTimeout):
        coreml_models._download_models()
    assert list(tmp_path.iterdir()) == [tmp_path / "cache"]
    assert not list((tmp_path / "cache").iterdir())


def test_predict_reuses_owned_buffers_and_rejects_shape_changes():
    """Keep input storage stable without retaining every previous query."""
    model = SimpleNamespace(predict=lambda inputs: inputs["ids"].copy())
    original = np.array([[1, 2]], dtype=np.int32)
    assert coreml_models.predict(model, {"ids": original}).tolist() == [[1, 2]]
    buffer = model._youty_input_buffers["ids"]
    assert not np.shares_memory(buffer, original)
    assert coreml_models.predict(model, {"ids": original + 3}).tolist() == [[4, 5]]
    assert model._youty_input_buffers["ids"] is buffer
    with pytest.raises(ValueError, match="remain fixed"):
        coreml_models.predict(model, {"ids": np.zeros((1, 3), dtype=np.int32)})


@pytest.mark.skipif(os.environ.get("YOUTY_COREML_SMOKE") != "1", reason="requires macOS and real Core ML assets")
def test_real_query_encoders_survive_deferred_cleanup():
    """Run repeated and idle predictions in a subprocess so native crashes fail."""
    result = subprocess.run(
        [sys.executable, "-X", "faulthandler", "-u", "-c", """
import time
import numpy as np
from youty_mcp.embeddinggemma_text import EmbeddingGemmaTextEncoder
from youty_mcp.siglip_text import SigLIPTextEncoder
encoders = [(EmbeddingGemmaTextEncoder(), 'embed_query'), (SigLIPTextEncoder(), 'embed_text')]
for encoder, method in encoders:
    reference = None
    for query in ['red car on a mountain road', 'München Straße café 👋', 'ΟΣ ΣΣ İI', 'a<unk>b</s>c', 'word ' * 600, 'red car on a mountain road']:
        vector = getattr(encoder, method)(query)
        assert len(vector) == 768 and np.isfinite(vector).all()
        assert abs(np.linalg.norm(vector) - 1) < 1e-5
        if reference is None:
            reference = vector
        time.sleep(0.5)
    assert np.array_equal(vector, reference)
    print(type(encoder).__name__, 'passed', flush=True)
time.sleep(5)
"""],
        capture_output=True, text=True, timeout=180,
    )
    assert result.returncode == 0, result.stdout + result.stderr
