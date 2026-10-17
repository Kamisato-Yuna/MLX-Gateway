#!/usr/bin/env python3
"""Test double for the mlx-serve binary used by MediaBackendManager tests.

Spawned with the same style of arguments the gateway passes to the real binary
(most interestingly `--port N`). Serves /health, /v1/3d/generations and
/v1/decisions so the manager's spawn -> health-check -> forward lifecycle can be
exercised end to end without a real MLX model.
"""
import argparse
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socketserver import TCPServer

parser = argparse.ArgumentParser()
parser.add_argument('--serve', action='store_true')
parser.add_argument('--host', default='127.0.0.1')
parser.add_argument('--port', type=int, default=8080)
parser.add_argument('--model-dir', action='append', default=[])
args, _ = parser.parse_known_args()

# 12-byte minimal GLB magic: "glTF" + version 2 + length 12.
GLB = b'glTF' + (2).to_bytes(4, 'little') + (12).to_bytes(4, 'little')


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, content_type='application/json'):
        self.send_response(code)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Content-Type', content_type)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == '/exit':
            os._exit(7)
        if self.path == '/health':
            self._send(200, b'{"status":"ok"}')
        else:
            self._send(404, b'{"error":"not found"}')

    def do_POST(self):
        # consume body so connection closes cleanly
        length = int(self.headers.get('Content-Length', 0))
        if length:
            self.rfile.read(length)
        if self.path == '/v1/3d/generations':
            self._send(200, GLB, content_type='model/gltf-binary')
        elif self.path == '/v1/decisions':
            self._send(200, json.dumps({'decision': 'escalate', 'confidence': 0.8}).encode())
        else:
            self._send(404, b'{"error":"not found"}')


class LocalFixtureServer(ThreadingHTTPServer):
    def server_bind(self):
        TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


server = LocalFixtureServer((args.host, args.port), Handler)
print('media fixture listening', flush=True)
server.serve_forever()
