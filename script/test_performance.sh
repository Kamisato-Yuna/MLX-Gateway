#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
cd "$(dirname "$0")/.."
mkdir -p build/tests
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.0 -module-cache-path build/ModuleCache \
  MLXGateway/Support/RequestMetricsStore.swift MLXGateway/Support/ProcessResourceSampler.swift \
  MLXGateway/Services/PerformanceMonitor.swift \
  Tests/PerformanceTests.swift -o build/tests/PerformanceTests
build/tests/PerformanceTests
