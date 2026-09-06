#!/usr/bin/env bash
set -euo pipefail
# Compatibility entry for maintainers. All validation and installation live in the signed client.
[[ "${1:-}" == "--install" && $# -eq 9 ]] || { echo "用法: $0 --install ARCHIVE TARGET_APP BUNDLE_ID CURRENT_VERSION VERSION TEAM_ID PID FAILURE_LOG" >&2; exit 2; }
TARGET_APP="$3"
EXECUTABLE_NAME="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$TARGET_APP/Contents/Info.plist")"
[[ -n "$EXECUTABLE_NAME" && "$EXECUTABLE_NAME" != */* ]] || { echo "客户端可执行文件无效" >&2; exit 1; }
exec "$TARGET_APP/Contents/MacOS/$EXECUTABLE_NAME" --mlx-gateway-update-helper "$@"
