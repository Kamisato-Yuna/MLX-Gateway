"""A real child listener for supervisor lifecycle tests; no model dependencies."""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

state = {"loaded": False, "loads": 0, "fail": False}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/_state":
            self.reply(state)
        else:
            self.reply({"data": [{"id": "test-whisper"}] if state["loaded"] else []}, 503 if state["fail"] else 200)

    def do_POST(self):
        if self.path == "/_state":
            state.update(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
        else:
            state["loaded"] = True
            state["loads"] += 1
        self.reply(state)

    def reply(self, value, code=200):
        self.send_response(code)
        self.end_headers()
        self.wfile.write(json.dumps(value).encode())

    def log_message(self, *_):
        pass


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
