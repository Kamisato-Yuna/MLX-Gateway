"""Exercise supervisor recovery against an isolated local HTTP fixture."""
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import socket
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.request import Request, urlopen
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "script"))
from whisper_supervisor import Configuration, Supervisor


class SupervisorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            self.port = reservation.getsockname()[1]
        self.launcher = self.root / "backend.sh"
        fixture = Path(__file__).with_name("whisper_backend_fixture.py")
        self.launcher.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " " + shlex.quote(str(fixture)) + f" {self.port}\n")
        self.launcher.chmod(0o700)
        self.config = self.root / "gateway.json"
        self.raw = {"baseURL": f"http://127.0.0.1:{self.port}/v1",
                    "model": "test-whisper", "launchScript": str(self.launcher), "timeout": 5}
        self.config.write_text(json.dumps(self.raw))
        self.output = self.root / "supervisor.log"
        self.handle = self.output.open("w")
        self.process = None

    def tearDown(self):
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=8)
        self.handle.close()
        self.temporary.cleanup()

    def events(self):
        return [json.loads(line) for line in self.output.read_text().splitlines() if line.startswith("{")]

    def wait(self, predicate):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.05)
        self.fail(self.output.read_text())

    def state(self, **changes):
        request = Request(f"http://127.0.0.1:{self.port}/_state",
                          data=json.dumps(changes).encode() if changes else None)
        with urlopen(request, timeout=2) as response:
            return json.load(response)

    def launch(self, interval="0.1"):
        self.process = subprocess.Popen([sys.executable, str(Path(__file__).resolve().parents[1] / "script/whisper_supervisor.py"),
                                         "--config", str(self.config), "--check-interval", interval],
                                        stdout=self.handle, stderr=subprocess.STDOUT, start_new_session=True)

    def start(self):
        self.launch()
        self.wait(lambda: any(row["event"] == "ready" for row in self.events()))
        return next(row["pid"] for row in self.events() if row["event"] == "backend_started")

    def test_model_preload_and_reload(self):
        self.start()
        self.assertEqual(self.state()["loads"], 1)
        self.state(loaded=False)
        self.wait(lambda: self.state()["loads"] == 2)
        self.assertTrue(self.state()["loaded"])

    def test_backend_crash_returns_failure_for_launchd(self):
        child = self.start()
        os.kill(child, signal.SIGKILL)
        self.assertEqual(self.process.wait(timeout=5), 1)
        self.assertTrue(any(row["event"] == "backend_exited" and row["exit_code"] == -9 for row in self.events()))

    def test_stop_reaps_owned_backend(self):
        child = self.start()
        self.process.terminate()
        self.assertEqual(self.process.wait(timeout=5), 0)
        with self.assertRaises(ProcessLookupError):
            os.kill(child, 0)

    def test_unresponsive_service_restarts_instead_of_staying_running(self):
        child = self.start()
        self.state(fail=True)
        self.assertEqual(self.process.wait(timeout=6), 1)
        with self.assertRaises(ProcessLookupError):
            os.kill(child, 0)
        self.assertEqual(len([row for row in self.events() if row["event"] == "health_check_failed"]), 3)

    def test_ready_old_backend_is_not_reused_during_handoff(self):
        requests = []

        class OldBackend(BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append("GET")
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{"data":[{"id":"test-whisper"}]}')

            def do_POST(self):
                requests.append("POST")
                self.send_response(200)
                self.end_headers()

            def log_message(self, *_):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", self.port), OldBackend)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            self.launch(interval="30")
            self.wait(lambda: any(row["event"] == "waiting_for_port" for row in self.events()))
            time.sleep(.3)
            self.assertFalse(any(row["event"] in ("ready", "backend_started") for row in self.events()))
            self.assertEqual(requests, [])
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
        released = time.monotonic()
        self.wait(lambda: any(row["event"] == "ready" for row in self.events()))
        self.assertLess(time.monotonic() - released, 5)
        self.assertEqual(self.state()["loads"], 1)

    def test_foreign_listener_after_spawn_is_not_queried(self):
        supervisor = Supervisor(Configuration.read(self.config))
        supervisor.child = Mock(pid=123)
        supervisor.child.poll.return_value = None
        with patch("whisper_supervisor.listener_pids", return_value={456}), patch.object(supervisor, "request") as request:
            with self.assertRaises(RuntimeError):
                supervisor.ensure_loaded()
            request.assert_not_called()

    def test_listener_change_during_model_probe_is_not_ready(self):
        supervisor = Supervisor(Configuration.read(self.config))
        supervisor.child = Mock(pid=123)
        supervisor.child.poll.return_value = None
        with patch("whisper_supervisor.listener_pids", side_effect=[{123}, {456}]), patch.object(supervisor, "request", return_value={"data": [{"id": "test-whisper"}]}):
            with self.assertRaises(RuntimeError):
                supervisor.loaded()

    def test_stop_while_waiting_does_not_touch_existing_listener(self):
        supervisor = Supervisor(Configuration.read(self.config))
        def stop_during_probe(_):
            supervisor.stop(signal.SIGTERM, None)
            return {456}
        with patch("whisper_supervisor.listener_pids", side_effect=stop_during_probe), patch("whisper_supervisor.subprocess.Popen") as launch:
            self.assertEqual(supervisor.run(), 0)
            launch.assert_not_called()

    def test_remote_or_credentialed_backend_is_rejected(self):
        for base in ("http://192.0.2.1:44120/v1", "http://user:secret@127.0.0.1:44120/v1"):
            self.config.write_text(json.dumps({**self.raw, "baseURL": base}))
            with self.assertRaises(ValueError):
                Configuration.read(self.config)


if __name__ == "__main__":
    unittest.main()
