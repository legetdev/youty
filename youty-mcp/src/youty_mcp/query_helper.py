"""Runs the query model on demand in a helper process (see `query_worker`).

The helper starts with the first search (well under a second: it loads only
Core ML's native runtime, and the model itself loads in about 50 ms), answers
every search after that in tens of milliseconds, and is stopped after
`idle_s` seconds without one. A stopped process gives all of its memory back,
which a model released inside this long-running server would not. Without an
installed Youty app or CLI, the model is downloaded once in the background
first; searches use keywords only until it is ready.
"""
from __future__ import annotations

import base64
import json
import logging
import select
import subprocess
import sys
import tempfile
import threading
from typing import Callable

import numpy as np

from . import models

_log = logging.getLogger(__name__)


def _models_ready() -> bool:
    try:
        models.locate(prepare=False)
        return True
    except models.NotReady:
        return False


class QueryHelper:
    def __init__(self, idle_s: float = 60, timeout_s: float = 30,
                 command: list[str] | None = None,
                 models_ready: Callable[[], bool] = _models_ready,
                 prepare_models: Callable[[], object] = models.locate) -> None:
        self.idle_s = idle_s
        self.timeout_s = timeout_s
        # Isolated mode (-I) so a module in the client's working directory, or
        # PYTHONPATH, can never stand in for the worker; it also starts from a
        # neutral directory.
        self.command = command or [sys.executable, "-I", "-m", "youty_mcp.query_worker"]
        self._models_ready = models_ready
        self._prepare_models = prepare_models
        self._ready = False
        self._preparing: threading.Thread | None = None
        self._lock = threading.Lock()
        self._proc: subprocess.Popen[bytes] | None = None
        self._timer: threading.Timer | None = None

    @property
    def running(self) -> bool:
        with self._lock:
            return self._proc is not None and self._proc.poll() is None

    def embed(self, query: str) -> np.ndarray:
        """L2-normalized 768-d float32 vector for `query`. Raises on failure."""
        with self._lock:
            proc = self._start_locked()
            try:
                assert proc.stdin is not None and proc.stdout is not None
                proc.stdin.write((json.dumps({"q": query}) + "\n").encode("utf-8"))
                proc.stdin.flush()
                ready, _, _ = select.select([proc.stdout], [], [], self.timeout_s)
                line = proc.stdout.readline() if ready else b""
                if not line:
                    raise RuntimeError("the search model helper stopped responding")
            except Exception:
                self._stop_locked()
                raise
            self._schedule_stop_locked()
        reply = json.loads(line)
        if "error" in reply:
            raise RuntimeError(reply["error"])
        return np.frombuffer(base64.b64decode(reply["v"]), dtype="<f4").copy()

    def stop(self) -> None:
        with self._lock:
            self._stop_locked()

    def _start_locked(self) -> subprocess.Popen[bytes]:
        if self._proc is not None and self._proc.poll() is None:
            return self._proc
        self._ensure_models_locked()
        self._proc = subprocess.Popen(
            self.command,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            close_fds=True, cwd=tempfile.gettempdir(),
        )
        _log.info("search model helper started (pid %d)", self._proc.pid)
        return self._proc

    def _ensure_models_locked(self) -> None:
        """The first search without an installed Youty app or CLI downloads the
        model (several hundred MB). That runs once in the background, outside
        any search's deadline; until it finishes, searches use keywords only."""
        if self._ready or self._models_ready():
            self._ready = True
            return
        if self._preparing is None or not self._preparing.is_alive():
            def prepare() -> None:
                try:
                    self._prepare_models()
                except Exception as exc:  # noqa: BLE001
                    _log.warning("could not prepare the search model (next search retries): %s", exc)

            self._preparing = threading.Thread(target=prepare, name="search-model-download", daemon=True)
            self._preparing.start()
        raise RuntimeError("the search model is still downloading")

    def _schedule_stop_locked(self) -> None:
        if self._timer is not None:
            self._timer.cancel()
        timer = threading.Timer(self.idle_s, self._idle_stop)
        timer.daemon = True
        self._timer = timer
        timer.start()

    def _idle_stop(self) -> None:
        with self._lock:
            # A search that arrived meanwhile replaced this timer; leave it running.
            if self._timer is not None and self._timer is not threading.current_thread():
                return
            self._timer = None
            if self._proc is not None:
                _log.info("search model helper stopped after %ds idle", int(self.idle_s))
            self._stop_locked()

    def _stop_locked(self) -> None:
        if self._timer is not None and self._timer is not threading.current_thread():
            self._timer.cancel()
        self._timer = None
        proc, self._proc = self._proc, None
        if proc is None:
            return
        try:
            if proc.stdin is not None:
                proc.stdin.close()   # the helper exits on end of input
            proc.wait(timeout=2)
        except Exception:  # noqa: BLE001
            proc.kill()
            proc.wait()
        finally:
            if proc.stdout is not None:
                proc.stdout.close()
