#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
mkdir -p build/tests
xcrun swiftc -module-cache-path build/ModuleCache -swift-version 6 -target arm64-apple-macos26.0 \
  MLXGateway/Models/AppUpdateModels.swift \
  MLXGateway/Support/AppUpdateVersion.swift \
  MLXGateway/Support/AppUpdateValidation.swift \
  MLXGateway/Support/AppUpdateArchive.swift \
  MLXGateway/Support/AppUpdateHelper.swift \
  MLXGateway/Services/AppUpdateSources.swift \
  MLXGateway/Services/AppUpdateDownloader.swift \
  MLXGateway/Support/AppUpdateInstaller.swift \
  MLXGateway/Services/AppUpdateController.swift \
  Tests/AppUpdateTests.swift \
  -o build/tests/AppUpdateTests \
  -framework AppKit -framework Security -framework Combine
build/tests/AppUpdateTests

echo "test_updates.sh: PASS (isolated update tests)"
