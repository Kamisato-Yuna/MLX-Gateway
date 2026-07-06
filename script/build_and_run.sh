#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="MLXGateway"
BUNDLE_ID="dev.kamisato-yuna.MLXGateway"
PROJECT="MLXGateway.xcodeproj"
SCHEME="MLXGateway"
CONFIGURATION="Debug"
GATEWAY_URL="http://127.0.0.1:44110"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"

cd "$ROOT_DIR"

usage() {
  echo "usage: $0 [run|--verify|--logs|--clean]" >&2
}

stop_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

build_app() {
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -destination "platform=macOS,arch=arm64" \
    build
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

verify_codesign() {
  codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 | grep "Authority=Apple Development" >/dev/null
}

verify_health() {
  for _ in {1..30}; do
    if curl -fsS "$GATEWAY_URL/health" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  curl -fsS "$GATEWAY_URL/health" >/dev/null
}

case "$MODE" in
  run)
    stop_app
    build_app
    open_app
    ;;
  --verify|verify)
    stop_app
    build_app
    verify_codesign
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    verify_health
    ;;
  --logs|logs)
    stop_app
    build_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --clean|clean)
    stop_app
    xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" \
      -derivedDataPath "$DERIVED_DATA" \
      clean
    rm -rf "$BUILD_DIR"
    ;;
  *)
    usage
    exit 2
    ;;
esac
