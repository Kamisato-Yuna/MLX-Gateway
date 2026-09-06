"""Isolated HTTP fixture: no model, external API, GUI, or persistent credentials."""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def reply(self, code, value, content_type='application/json'):
        data = value.encode() if isinstance(value, str) else json.dumps(value, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        self.wfile.flush()

    def response(self, status='completed'):
        return {'id': 'resp_fixture', 'object': 'response', 'status': status,
                'output': [{'type': 'message', 'content': [{'type': 'output_text', 'text': '你好'}]}],
                'usage': {'input_tokens': 4, 'output_tokens': 2, 'total_tokens': 6}}

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        if self.path.endswith('/cancel'):
            self.reply(200, self.response('in_progress' if 'unconfirmed' in self.path else 'cancelled'))
            return
        scenario = body.get('fixture', 'json')
        if scenario == 'headers-slow':
            time.sleep(2)
        if scenario == 'error':
            self.reply(422, {'error': {'code': 'unsupported_feature', 'message': '不支持 audio'}})
        elif scenario == 'redirect':
            self.send_response(307)
            self.send_header('Location', '/unexpected-redirect')
            self.send_header('Content-Length', '0')
            self.end_headers()
        elif scenario == 'echo':
            self.reply(200, {'received': body, 'auth_present': self.headers.get('Authorization') == 'Bearer fixture-memory-key'})
        elif scenario in ('stream', 'cancel', 'partial', 'failed', 'unknown'):
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream; charset=utf-8')
            self.send_header('Connection', 'close')
            self.end_headers()
            self.close_connection = True
            try:
                def event(name, value):
                    data = ('event: ' + name + '\r\ndata: ' + json.dumps(value, ensure_ascii=False) + '\r\n\r\n').encode()
                    # Split every UTF-8 sequence to exercise real byte framing.
                    for byte in data:
                        self.wfile.write(bytes([byte]))
                    self.wfile.flush()
                event('response.created', {'type': 'response.created', 'response': {'id': 'resp_fixture', 'status': 'in_progress'}})
                event('response.output_text.delta', {'type': 'response.output_text.delta', 'delta': '你好'})
                if scenario == 'cancel':
                    time.sleep(2)
                else:
                    time.sleep(.3)
                if scenario == 'partial':
                    self.wfile.write(b'event: response.completed\ndata: {"type":"response.completed"}')
                    self.wfile.flush()
                    return
                if scenario == 'unknown':
                    event('vendor.extension', {'type': 'vendor.extension', 'future': {'nested': [1, 2]}})
                response = self.response('failed' if scenario == 'failed' else 'completed')
                if scenario == 'failed':
                    response['error'] = {'code': 'backend_failed', 'message': 'fixture failure'}
                event('response.failed' if scenario == 'failed' else 'response.completed', {'type': 'response.failed' if scenario == 'failed' else 'response.completed', 'response': response})
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            try:
                self.reply(200, self.response())
            except (BrokenPipeError, ConnectionResetError):
                pass

    def do_GET(self):
        if '/input_items' in self.path:
            self.reply(200, {'object': 'list', 'data': [], 'last_id': None, 'has_more': False, 'path': self.path})
        else:
            self.reply(200, self.response())

    def do_DELETE(self):
        self.reply(200, {'id': 'resp_fixture', 'object': 'response.deleted', 'deleted': True})


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
