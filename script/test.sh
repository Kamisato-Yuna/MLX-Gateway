#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
mkdir -p build/tests
SOURCES=(MLXGateway/Models/ModelRegistry.swift MLXGateway/Support/JSONSupport.swift
  MLXGateway/Support/HTTPTypes.swift MLXGateway/Support/ResponsesAdapter.swift
  MLXGateway/Services/BackendManager.swift MLXGateway/Services/GatewayServer.swift)
case "${1:-}" in
  '')
    xcrun swiftc -module-cache-path build/ModuleCache -swift-version 6 -target arm64-apple-macos26.0 "${SOURCES[@]}" Tests/main.swift -o build/tests/MLXGatewayTests
    build/tests/MLXGatewayTests
    ;;
  --live)
    xcrun swiftc -module-cache-path build/ModuleCache -swift-version 6 -target arm64-apple-macos26.0 "${SOURCES[@]}" Tests/LiveModelHost.swift -o build/tests/LiveModelHost
    "${MLX_GATEWAY_PYTHON:-${MLX_GATEWAY_RUNTIME:-$HOME/MLX}/.venv/bin/python}" script/live_smoke.py
    ;;
  *) echo "用法: $0 [--live]" >&2; exit 2 ;;
esac
