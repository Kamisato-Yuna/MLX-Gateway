<p align="center"><img src="docs/images/app-icon.png" width="144" alt="MLX Gateway"></p>

# MLX Gateway

[Website](https://kamisato-yuna.github.io/MLX-Gateway/) · [简体中文](README.md) · [MIT](LICENSE) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)

A native macOS Liquid Glass app that connects local MLX models to an **OpenAI Responses** endpoint. Built with **Swift 6**, for **Apple Silicon and macOS 26+**.

Choose your MLX runtime, Python interpreter and model directory. The app discovers models from `config.json`, runs one model at a time, shows logs, and explicitly stops the previous process when switching. API calls never start or switch models.

## Getting started

1. Download the arm64 ZIP from [GitHub Releases](https://github.com/Kamisato-Yuna/MLX-Gateway/releases/latest), extract it, and move `MLXGateway.app` to Applications. Release notes state signing, notarization and verification results.
2. To build from source, use Xcode 27 and your own Apple Development team, or set `MLX_GATEWAY_TEAM` and `MLX_GATEWAY_SIGN_IDENTITY` with `./script/build_and_run.sh --verify`.
3. Open Settings (⌘,) and select your MLX runtime directory. Defaults are `.venv/bin/python` and `models/` beneath it; both can be overridden.
4. Save and scan, select a model, then start it (⌘R). Copy the model ID and base URL to your client. Stop with ⌘.

Model discovery supports nested directories up to five levels and a single model directory. Hidden directories and directory symlinks are skipped. Invalid configs are reported. Discovery does not guarantee that the installed MLX backend supports the model architecture or that the weights are complete.

Install `mlx-lm` and `mlx-vlm` in your own Python environment and supply compatible model weights. No models are bundled or downloaded. Model licenses are separate from this project's MIT license.

## API scope

Default gateway: `http://127.0.0.1:44110/v1`. Default internal MLX port: `44100`. Both addresses are configurable. Keep these local: there is no application-level authentication.

- `GET /health`, `GET /status`, `GET /v1/models`
- `POST /v1/responses`: text, progressive SSE, function calls/results, optional in-memory response storage and background execution
- `GET` / `DELETE /v1/responses/{id}`, `GET /v1/responses/{id}/input_items`, `POST /v1/responses/{id}/cancel`
- VLM supports image inputs, inline PDFs and constrained JSON Schema output; both backends accept inline UTF-8 text files
- Public Chat Completions and Anthropic routes return 404
- Strict function schemas, audio, cloud-hosted tools, uploaded file IDs/URLs and unimplemented parameters return explicit errors
- Capabilities depend on the installed backend and model. Stored responses are local to the gateway process and disappear after restart; `previous_response_id` does not inherit previous instructions

```python
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:44110/v1", api_key="local")
response = client.responses.create(
    model="my-text-model",  # Copy the actual model ID from the app
    input="Say hello", max_output_tokens=128, store=False,
)
print(response.output_text)
```

The app includes searchable, highlighted logs with a clear action; a Responses playground with presets, custom JSON projects, raw SSE inspection and manual tool-result submission; and a performance panel with CPU/memory sampling, request timings, token usage and repeated tests. API keys for custom endpoints remain in memory. Automatic updates support GitHub Release or a Pages manifest and validate downloaded apps before installation.

Disabling log following pauses automatic scrolling, not updates. Logs stay at `~/Library/Logs/MLXGateway/backend.log`; redact before sharing.

## Development

```bash
./script/build_and_run.sh --build
./script/test.sh
./script/test-responses-playground.sh
./script/test_performance.sh
./script/test_updates.sh
```

Tests use temporary model directories and an isolated HTTP fixture. They do not prove real inference. The opt-in `MLX_GATEWAY_RUNTIME="$HOME/MLX" ./script/test.sh --live` requires the OpenAI Python SDK and loads **all discovered models sequentially**. GitHub CI uses the official `xcode-27` preview runner to run Swift 6 tests and compile the app and Icon Composer assets.

The project is in early development. Distribution artifacts and their validation are documented per release; CI never publishes an unsigned app. See the [Chinese guide](README.md) for detailed build, settings and protocol documentation.
