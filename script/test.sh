#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
mkdir -p build/tests
SOURCES=(MLXGateway/Models/ModelRegistry.swift MLXGateway/Support/JSONSupport.swift
  MLXGateway/Support/HTTPTypes.swift MLXGateway/Support/ResponsesAdapter.swift
  MLXGateway/Support/ResponsesFiles.swift MLXGateway/Support/BackendStream.swift MLXGateway/Support/ResponsesStream.swift
  MLXGateway/Support/ResponsesStore.swift MLXGateway/Support/RequestMetricsStore.swift
  MLXGateway/Support/MediaGatewayConfig.swift MLXGateway/Support/MediaBackendManager.swift
  MLXGateway/Support/AudioTranscriptionProxy.swift MLXGateway/Support/ImageGenerationService.swift
  MLXGateway/Services/BackendManager.swift MLXGateway/Services/GatewayServer.swift)
case "${1:-}" in
  '')
    export MLX_GATEWAY_PYTHON="${MLX_GATEWAY_TEST_PYTHON:-/usr/bin/python3}"
    xcrun swiftc -module-cache-path build/ModuleCache -swift-version 6 -target arm64-apple-macos26.0 "${SOURCES[@]}" Tests/main.swift -o build/tests/MLXGatewayTests
    build/tests/MLXGatewayTests
    xcrun swiftc -module-cache-path build/ModuleCache -swift-version 6 -target arm64-apple-macos26.0 "${SOURCES[@]}" MLXGateway/Services/AudioServiceController.swift Tests/AudioServiceMain.swift -o build/tests/AudioServiceTests
    build/tests/AudioServiceTests
    cp Tests/ImageServiceMain.swift build/tests/main.swift
    xcrun swiftc -module-cache-path build/ModuleCache -swift-version 6 -target arm64-apple-macos26.0 "${SOURCES[@]}" build/tests/main.swift -o build/tests/ImageServiceTests
    build/tests/ImageServiceTests
    ;;
  --live)
    xcrun swiftc -module-cache-path build/ModuleCache -swift-version 6 -target arm64-apple-macos26.0 "${SOURCES[@]}" Tests/LiveModelHost.swift -o build/tests/LiveModelHost
    "${MLX_GATEWAY_PYTHON:-${MLX_GATEWAY_RUNTIME:-$HOME/MLX}/.venv/bin/python}" script/live_smoke.py
    ;;
  *) echo "用法: $0 [--live]" >&2; exit 2 ;;
esac
