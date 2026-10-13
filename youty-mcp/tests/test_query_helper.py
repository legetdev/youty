"""The search model runs in a helper process that starts on demand and exits
after the idle period, so the server never keeps the model in memory."""
import sys
import textwrap
import time

import numpy as np
import pytest

from youty_mcp.query_helper import QueryHelper

# Stands in for the real worker: answers with a vector derived from the query,
# fails on request, or exits mid-answer.
FAKE_WORKER = textwrap.dedent("""
    import base64, json, sys
    import numpy as np
    for line in sys.stdin:
        q = json.loads(line)["q"]
        if q == "crash":
            sys.exit(1)
        if q == "fail":
            print(json.dumps({"error": "model missing"}), flush=True)
            continue
        v = np.full(768, len(q), dtype="<f4")
        print(json.dumps({"v": base64.b64encode(v.tobytes()).decode()}), flush=True)
""")


@pytest.fixture()
def helper():
    h = QueryHelper(idle_s=1.0, timeout_s=10, command=[sys.executable, "-c", FAKE_WORKER])
    yield h
    h.stop()


def stops_within(helper, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if not helper.running:
            return True
        time.sleep(0.05)
    return False


def test_starts_on_first_search_and_stops_after_idle(helper):
    assert not helper.running
    assert helper.embed("abc")[0] == 3
    assert helper.running
    pid = helper._proc.pid
    helper.embed("abcd")
    assert helper._proc.pid == pid  # reused while searches keep coming
    assert stops_within(helper, 5)  # stopped after the idle period
    assert helper.embed("ab")[0] == 2  # and starts again on demand


def test_each_search_restarts_the_idle_period(helper):
    started = time.monotonic()
    for _ in range(5):
        helper.embed("x")
        time.sleep(0.4)
    # Still running 2 s after the first search, because each search restarted the 1 s idle period.
    assert time.monotonic() - started >= 2 and helper.running
    assert stops_within(helper, 5)


def test_errors_are_raised_and_a_crashed_helper_is_replaced(helper):
    with pytest.raises(RuntimeError, match="model missing"):
        helper.embed("fail")
    with pytest.raises(RuntimeError):
        helper.embed("crash")
    assert not helper.running
    assert helper.embed("again")[0] == 5


def test_real_model_matches_in_process_encoder():
    """The helper's vectors equal the encoder's own (skipped without models)."""
    from youty_mcp import models
    from youty_mcp.query_encoder import QueryEncoder

    try:
        models.locate()
    except Exception:  # noqa: BLE001
        pytest.skip("EmbeddingGemma 2 model files not installed")
    real = QueryHelper(idle_s=5)
    try:
        vector = real.embed("how do I build an app")
    finally:
        real.stop()
    expected = QueryEncoder().embed("how do I build an app")
    assert vector.shape == (768,)
    assert float(np.dot(vector, expected)) > 0.9999
