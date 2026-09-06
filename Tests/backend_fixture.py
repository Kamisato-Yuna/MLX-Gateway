#!/usr/bin/env python3
"""Local HTTP fixture for lifecycle/protocol tests. Does not load any MLX model."""
import argparse
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socketserver import TCPServer

parser = argparse.ArgumentParser()
parser.add_argument('--host')
parser.add_argument('--port', type=int)
parser.add_argument('--model')
args, _ = parser.parse_known_args()
print('fixture model loading', flush=True)

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/exit':
            os._exit(7)
        body = b'{"status":"ok"}'
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert self.path == '/v1/chat/completions'
        assert body['model'] == args.model, 'must use the launched local model path'
        text = body['messages'][-1]['content']
        if text == 'slow':
            time.sleep(4)
        if text == 'backend-error':
            data = json.dumps({'error': {'message': args.model}}).encode()
            self.send_response(500)
        else:
            data = json.dumps({'choices': [{'message': {'role': 'assistant', 'content': 'fixture: ' + text},
                                            'finish_reason': 'stop'}],
                               'usage': {'prompt_tokens': 7, 'completion_tokens': 3}}).encode()
            self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        print('fixture request completed', flush=True)

class LocalFixtureServer(ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer normally calls getfqdn(), which can block on reverse DNS in CI.
        # This fixture uses a numeric loopback address and has no need for a DNS name.
        TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]

server = LocalFixtureServer((args.host, args.port), Handler)
print('fixture listening', flush=True)
server.serve_forever()
