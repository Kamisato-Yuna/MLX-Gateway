#!/usr/bin/env python3
"""Opt-in: loads each installed MLX model serially and tests Responses with the OpenAI SDK."""
import json
import subprocess
import time
import urllib.request
from pathlib import Path
from openai import OpenAI

root = Path(__file__).resolve().parents[1]
host = subprocess.Popen([str(root / 'build/tests/LiveModelHost')], stdin=subprocess.PIPE, text=True)
client = OpenAI(base_url='http://127.0.0.1:44319/v1', api_key='local', timeout=120,
                max_retries=0, _strict_response_validation=True)
# Ask the same registry used by the application; never hard-code a local model list.
for _ in range(30):
    try:
        with urllib.request.urlopen('http://127.0.0.1:44319/v1/models', timeout=2) as r:
            models = [entry['id'] for entry in json.load(r)['data']]
        break
    except urllib.error.URLError:
        if host.poll() is not None:
            raise RuntimeError('Live model host exited')
        time.sleep(0.25)
else:
    host.stdin.close()
    host.wait(timeout=15)
    raise RuntimeError('Live model host did not start')

try:
    if not models:
        raise RuntimeError('No models found; configure MLX_GATEWAY_RUNTIME or MLX_GATEWAY_MODELS')
    for index, model in enumerate(models):
        host.stdin.write(model + '\n')
        host.stdin.flush()
        for _ in range(190):
            if host.poll() is not None:
                raise RuntimeError('Live model host exited')
            try:
                with urllib.request.urlopen('http://127.0.0.1:44319/status', timeout=3) as r:
                    status = json.load(r)['backend']
                if status['state'] == 'failed':
                    raise RuntimeError(status)
                if status['ready'] and status['active_model'] == model:
                    break
            except (ConnectionError, urllib.error.URLError):
                pass
            time.sleep(1)
        else:
            raise TimeoutError(model)
        print(f'READY {model} PID={status["pid"]}', flush=True)
        response = client.responses.create(model=model, input='只回复：你好', max_output_tokens=512,
                                           temperature=0, store=False)
        output = root / 'build/verification' / f'live-model-{index + 1}.json'
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(response.model_dump_json(indent=2), encoding='utf-8')
        assert response.output_text, response.model_dump()
        print(json.dumps({'model': model, 'status': response.status, 'output_text': response.output_text,
                          'usage': response.usage.model_dump() if response.usage else None}, ensure_ascii=False), flush=True)
        old_pid = status['pid']
        host.stdin.write('stop\n')
        host.stdin.flush()
        for _ in range(15):
            with urllib.request.urlopen('http://127.0.0.1:44319/status') as r:
                status = json.load(r)['backend']
            if status['state'] == 'stopped':
                break
            time.sleep(0.5)
        assert status['state'] == 'stopped'
        print(f'STOPPED {model} PID={old_pid}', flush=True)
finally:
    host.stdin.close()
    host.wait(timeout=15)
