#!/usr/bin/env python3
"""Small local mlx-serve fixture for image gateway lifecycle tests."""
import argparse
import base64
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/8ioAAAAASUVORK5CYII=")
MODEL = "qwen-image-uc-mlx-serve"

parser = argparse.ArgumentParser()
parser.add_argument("--model")
parser.add_argument("--serve", action="store_true")
parser.add_argument("--host", default="127.0.0.1")
parser.add_argument("--port", type=int, required=True)
args, _ = parser.parse_known_args()
loaded = False

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass
    def send_json(self, code, obj):
        payload = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload))); self.end_headers(); self.wfile.write(payload)
    def do_GET(self):
        if self.path == "/health": self.send_json(200, {"ok": True})
        elif self.path == "/v1/models": self.send_json(200, {"data": [{"id": MODEL, "loaded": loaded, "state": "ready" if loaded else "unloaded"}]})
        else: self.send_json(404, {"error": "not found"})
    def do_POST(self):
        global loaded
        size = int(self.headers.get("Content-Length", "0")); body = json.loads(self.rfile.read(size) or b"{}")
        if self.path == "/v1/load-model":
            loaded = body.get("model") == MODEL
            self.send_json(200 if loaded else 404, {"model": {"id": MODEL, "loaded": loaded, "state": "ready" if loaded else "unloaded"}})
        elif self.path == "/v1/images/generations":
            if body.get("prompt") == "slow": time.sleep(10)
            if body.get("prompt") == "failure": self.send_json(500, {"error": "failed at /private/internal/model"}); return
            if body.get("prompt") == "corrupt": self.send_json(200, {"data": [{"b64_json": base64.b64encode(b"not png").decode()}]}); return
            if not loaded: self.send_json(503, {"error": "unloaded"}); return
            self.send_json(200, {"data": [{"b64_json": base64.b64encode(PNG).decode()}]})
        else: self.send_json(404, {"error": "not found"})

ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()
