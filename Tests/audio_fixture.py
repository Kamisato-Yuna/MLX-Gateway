#!/usr/bin/env python3
"""Verify multipart bytes, response formats and downstream errors without MLX."""
import sys
import json
import time
import socket
from urllib.parse import urlparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):
    loaded = True
    model_delay = 0
    model_loads = 0
    model_probes = 0
    posts = 0
    redirected = 0
    recover_at = 0
    drop_next = False
    redirect_next = False
    trickle = False
    def do_GET(self):
        if self.path.startswith('/fixture/recover'):
            Handler.loaded = False
            Handler.recover_at = time.monotonic() + 0.8
        if self.path == '/fixture/drop-next-post':
            Handler.drop_next = True
        if self.path == '/fixture/redirect-next-post':
            Handler.redirect_next = True
        if self.path == '/fixture/trickle-on':
            Handler.trickle = True
        if self.path == '/fixture/trickle-off':
            Handler.trickle = False
        if self.path == '/fixture/slow-models-once':
            Handler.model_delay = 4
        if self.path == '/v1/models' and Handler.model_delay:
            delay, Handler.model_delay = Handler.model_delay, 0
            time.sleep(delay)
        if self.path == '/v1/models':
            Handler.model_probes += 1
            if Handler.recover_at and time.monotonic() >= Handler.recover_at:
                Handler.loaded = True
                Handler.recover_at = 0
        self.send_response(503 if self.path == '/v1/models' and Handler.recover_at - time.monotonic() > 0.4 else 200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        if self.path == '/v1/models':
            output = json.dumps({'data': [{'id': 'whisper-1'}] if Handler.loaded else []}).encode()
            if Handler.trickle:
                try:
                    for byte in output:
                        self.wfile.write(bytes([byte])); self.wfile.flush(); time.sleep(.1)
                except (BrokenPipeError, ConnectionResetError):
                    pass
            else:
                self.wfile.write(output)
        elif self.path == '/fixture/state':
            self.wfile.write(json.dumps({'loads': Handler.model_loads, 'probes': Handler.model_probes,
                                        'posts': Handler.posts, 'redirected': Handler.redirected}).encode())

    def do_DELETE(self):
        Handler.loaded = False
        self.send_response(204)
        self.end_headers()

    def do_POST(self):
        if urlparse(self.path).path == '/v1/models':
            Handler.model_loads += 1
            Handler.loaded = True
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"status":"success"}')
            return
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if self.path == '/v1/audio/transcriptions':
            Handler.posts += 1
            if Handler.drop_next:
                Handler.drop_next = False
                self.close_connection = True
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
                return
            if Handler.redirect_next:
                Handler.redirect_next = False
                self.send_response(307)
                self.send_header('Location', '/fixture/redirected-post')
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
        elif self.path == '/fixture/redirected-post':
            Handler.redirected += 1
        valid = (self.path == '/v1/audio/transcriptions'
                 and self.headers.get('Content-Type') == 'multipart/form-data; boundary=fixture-audio'
                 and b'\x00\xff\x80\r\n' in body
                 and self.headers.get('Authorization') is None)
        if not valid:
            status, kind, output = 400, 'application/json', b'{"error":"upload changed"}'
        elif b'name="language"\r\n\r\nrate-limit' in body:
            status, kind, output = 429, 'application/json', b'{"error":{"code":"rate_limit"}}'
        elif b'name="response_format"\r\n\r\nverbose_json' in body:
            status, kind, output = 200, 'application/json', json.dumps({'text': '中文转写成功', 'segments': [{'start': 0.12, 'end': 2.34, 'text': '中文转写成功'}]}).encode()
        elif b'name="response_format"\r\n\r\ntext' in body:
            status, kind, output = 200, 'text/plain; charset=utf-8', '中文转写成功'.encode()
        else:
            status, kind, output = 200, 'application/json', '{"text":"中文转写成功"}'.encode()
        self.send_response(status)
        self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(output)))
        if status == 429:
            self.send_header('Retry-After', '3')
        self.end_headers()
        self.wfile.write(output)

ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), Handler).serve_forever()
