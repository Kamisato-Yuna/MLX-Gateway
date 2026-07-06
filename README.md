# MLX Gateway

MLX Gateway is a native macOS menu bar app that exposes a local OpenAI-compatible and Anthropic-compatible gateway for MLX model servers.

Default endpoints:

```text
OpenAI base_url:    http://127.0.0.1:44110/v1
Anthropic base_url: http://127.0.0.1:44110
Downstream model:   http://127.0.0.1:44100/v1
```

The first version runs a single active backend. When a request targets a different model, MLX Gateway stops the old `mlx_lm` or `mlx_vlm` server and starts the requested model on the configured downstream host and port.

## Models

The built-in registry includes:

- `Qwen3-Coder-30B-A3B-Instruct-4bit`
- `Qwen3.6-35B-A3B-4bit`
- `Qwen3.6-27B-AEON-Ultimate-Uncensored-BF16-mlx-4Bit`

Public API responses expose model IDs, capabilities, and backend kind only. Local filesystem paths are never included in public protocol responses.

## API Surface

- `GET /health`
- `GET /status`
- `GET /v1/models`
- `POST /v1/chat/completions`
- `POST /v1/responses`
- `POST /v1/messages`

Non-streaming text requests are the first supported protocol target. Streaming, tool calling, tool choice, and unsupported vision inputs return explicit JSON `unsupported_request_error` responses.

Anthropic `/v1/messages` text requests are translated into OpenAI Chat Completions before being sent downstream. Anthropic tools and tool choice are not implemented in this version.

## Build And Run

```bash
./script/build_and_run.sh
./script/build_and_run.sh --verify
./script/build_and_run.sh --logs
./script/build_and_run.sh --clean
```

`--verify` builds the Debug app, checks the Apple Development signature, launches `MLXGateway`, verifies the app process, and checks `GET /health`.

## Smoke Tests

After the app is running:

```bash
curl -fsS http://127.0.0.1:44110/health
curl -fsS http://127.0.0.1:44110/status
curl -fsS http://127.0.0.1:44110/v1/models
curl -fsS http://127.0.0.1:44110/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen3-Coder-30B-A3B-Instruct-4bit","messages":[{"role":"user","content":"hello"}]}'
curl -fsS http://127.0.0.1:44110/v1/responses \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen3-Coder-30B-A3B-Instruct-4bit","input":"hello"}'
curl -fsS http://127.0.0.1:44110/v1/messages \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen3-Coder-30B-A3B-Instruct-4bit","max_tokens":16,"messages":[{"role":"user","content":"hello"}]}'
```

If MLX cannot access Metal in the current execution environment, protocol routes that need the downstream model may return `backend_unavailable` or `downstream_error`; `/health`, `/status`, `/v1/models`, and unsupported-feature errors should still work.
