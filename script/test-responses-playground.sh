#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
cd "$(dirname "$0")/.."
work=$(mktemp -d /tmp/responses-playground-test.XXXXXX)
fixture_pid=''
cleanup() {
    if [[ -n "$fixture_pid" ]]; then
        kill "$fixture_pid" 2>/dev/null || true
        wait "$fixture_pid" 2>/dev/null || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.0 -module-cache-path "$work/modules" \
    -parse-as-library -typecheck MLXGateway/Models/ResponsesTest*.swift \
    MLXGateway/Support/ResponsesClient*.swift MLXGateway/Services/ResponsesPlayground*.swift \
    MLXGateway/Views/ResponsesPlaygroundView.swift
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.0 -module-cache-path "$work/modules" \
    -parse-as-library MLXGateway/Models/ResponsesTest*.swift MLXGateway/Support/ResponsesClient*.swift \
    MLXGateway/Services/ResponsesPlayground*.swift Tests/ResponsesPlaygroundTests.swift -o "$work/tests"
python3 Tests/responses_playground_fixture.py "$work/port" &
fixture_pid=$!
for _ in {1..100}; do
    [[ -s "$work/port" ]] && break
    sleep 0.05
done
[[ -s "$work/port" ]] || { echo 'fixture failed to start' >&2; exit 1; }
"$work/tests" "http://127.0.0.1:$(cat "$work/port")/v1"
