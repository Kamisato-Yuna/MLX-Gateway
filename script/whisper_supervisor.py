#!/usr/bin/env python3
"""Keep the configured local STT process and model ready for launchd."""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import json
from pathlib import Path
import signal
import subprocess
import time
from urllib.parse import urlencode, urlsplit
from urllib.request import ProxyHandler, Request, build_opener


def event(name: str, **fields) -> None:
    print(json.dumps({"time": datetime.now(timezone.utc).isoformat(), "event": name, **fields}), flush=True)


def listener_pids(base_url: str) -> set[int]:
    """Read the kernel's listening processes, never infer ownership from HTTP content."""
    url = urlsplit(base_url)
    port = url.port or (443 if url.scheme == "https" else 80)
    result = subprocess.run(["/usr/sbin/lsof", "-nP", "-t", f"-iTCP:{port}", "-sTCP:LISTEN"],
                            capture_output=True, text=True, timeout=3)
    if result.returncode not in (0, 1) or (result.returncode == 1 and result.stderr.strip()):
        raise RuntimeError("Cannot inspect the audio listener")
    return {int(raw) for raw in result.stdout.split()}


def listener_is_child(base_url: str, parent_pid: int) -> bool:
    """For the settings page: an orphan from the previous supervisor is not ready."""
    listeners = listener_pids(base_url)
    if len(listeners) != 1:
        return False
    result = subprocess.run(["/bin/ps", "-p", str(next(iter(listeners))), "-o", "ppid="],
                            capture_output=True, text=True, timeout=3)
    return result.returncode == 0 and result.stdout.strip() == str(parent_pid)


@dataclass(frozen=True)
class Configuration:
    base_url: str
    model: str
    launch_script: str
    timeout: float

    @classmethod
    def read(cls, path: Path) -> Configuration:
        raw = json.loads(path.read_text())
        url = urlsplit(raw["baseURL"])
        script = Path(raw["launchScript"])
        # This supervisor only manages the existing local, uncredentialed service.
        if (url.scheme != "http" or url.hostname not in {"localhost", "127.0.0.1", "::1"}
                or url.username or url.password or url.query or url.fragment
                or not script.is_absolute() or not script.is_file()):
            raise ValueError("Use a local HTTP backend and an existing absolute launch script")
        timeout = float(raw.get("timeout", 180))
        if timeout <= 0 or not timeout < float("inf") or not raw.get("model"):
            raise ValueError("Model and positive timeout are required")
        return cls(raw["baseURL"].rstrip("/"), raw["model"], str(script), timeout)


class Supervisor:
    def __init__(self, configuration: Configuration, interval: float = 30):
        self.config = configuration
        self.interval = interval
        self.child: subprocess.Popen | None = None
        self.stopping = False
        self.http = build_opener(ProxyHandler({}))

    def request(self, method: str, path: str, timeout: float = 5):
        request = Request(self.config.base_url + path, method=method,
                          data=b"" if method == "POST" else None)
        with self.http.open(request, timeout=timeout) as response:
            return json.loads(response.read())

    def loaded(self) -> bool:
        if self.child is None or self.child.poll() is not None or listener_pids(self.config.base_url) != {self.child.pid}:
            raise RuntimeError("The configured port is not owned by the current backend")
        response = self.request("GET", "/models")
        if self.child.poll() is not None or listener_pids(self.config.base_url) != {self.child.pid}:
            raise RuntimeError("Audio listener changed during the model check")
        if not isinstance(response, dict) or not isinstance(response.get("data"), list):
            raise ValueError("Invalid model-list response")
        return any(isinstance(model, dict) and model.get("id") == self.config.model
                   for model in response["data"])

    def ensure_loaded(self) -> None:
        if not self.loaded():
            event("model_load_requested", model=self.config.model)
            self.request("POST", "/models?" + urlencode({"model_name": self.config.model}),
                         timeout=self.config.timeout)
            if not self.loaded():
                raise RuntimeError("Backend did not report the configured model as loaded")
            event("model_loaded", model=self.config.model)

    def stop(self, signum: int, _frame) -> None:
        self.stopping = True
        event("stop_requested", signal=signum)
        if self.child is not None and self.child.poll() is None:
            self.child.terminate()

    def cleanup(self) -> None:
        if self.child is not None and self.child.poll() is None:
            self.child.terminate()
            try:
                self.child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.child.kill()
                self.child.wait()

    def run(self) -> int:
        try:
            deadline = time.monotonic() + self.config.timeout
            waiting = False
            # launchd can start us before the previous process group finishes exiting.
            # Wait for that listener to disappear; do not signal it or reuse its model list.
            while not self.stopping and listener_pids(self.config.base_url):
                if not waiting:
                    event("waiting_for_port")
                    waiting = True
                if time.monotonic() >= deadline:
                    raise RuntimeError("Previous audio listener did not release the configured port")
                time.sleep(0.1)
            if self.stopping:
                return 0
            self.child = subprocess.Popen([self.config.launch_script])
            event("backend_started", pid=self.child.pid, model=self.config.model)
            while not self.stopping:
                if self.child.poll() is not None:
                    raise RuntimeError("Backend exited before readiness")
                try:
                    self.loaded()
                    break
                except Exception:
                    if time.monotonic() >= deadline:
                        raise RuntimeError("Backend readiness timed out")
                    time.sleep(0.25)
            if self.stopping:
                return 0
            self.ensure_loaded()
            event("ready", pid=self.child.pid, model=self.config.model)
            next_check = time.monotonic() + self.interval
            failures = 0
            while not self.stopping:
                try:
                    code = self.child.wait(timeout=min(1, self.interval))
                    event("backend_exited", pid=self.child.pid, exit_code=code)
                    return 0 if self.stopping else 1
                except subprocess.TimeoutExpired:
                    pass
                if time.monotonic() < next_check:
                    continue
                next_check = time.monotonic() + self.interval
                try:
                    self.ensure_loaded()
                    failures = 0
                except Exception as exc:
                    failures += 1
                    event("health_check_failed", count=failures, error_type=type(exc).__name__)
                    if failures >= 3:
                        raise RuntimeError("Backend failed three consecutive health checks")
            return 0
        except Exception as exc:
            if not self.stopping:
                event("restart_required", reason=str(exc))
            return 0 if self.stopping else 1
        finally:
            self.cleanup()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--check-interval", type=float, default=30)
    args = parser.parse_args()
    if args.check_interval <= 0:
        parser.error("check interval must be positive")
    supervisor = Supervisor(Configuration.read(args.config), args.check_interval)
    signal.signal(signal.SIGTERM, supervisor.stop)
    signal.signal(signal.SIGINT, supervisor.stop)
    return supervisor.run()


if __name__ == "__main__":
    raise SystemExit(main())
