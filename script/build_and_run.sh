#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
APP_NAME="MLXGateway"
BUNDLE_ID="dev.kamisato-yuna.MLXGateway"
PROJECT="MLXGateway.xcodeproj"
SCHEME="MLXGateway"
CONFIGURATION="Debug"
GATEWAY_URL="${MLX_GATEWAY_URL:-http://127.0.0.1:44110}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"

cd "$ROOT_DIR"

usage() {
  echo "usage: $0 [run|--build|--verify|--logs|--clean]" >&2
}

stop_app() {
  if pgrep -x "$APP_NAME" >/dev/null; then
    pkill -TERM -x "$APP_NAME"
    for _ in {1..40}; do
      if ! pgrep -x "$APP_NAME" >/dev/null; then return 0; fi
      sleep 0.25
    done
    echo "应用尚未退出；请检查服务停止状态。" >&2
    return 1
  fi
}

build_app() {
  local signing_settings=(ARCHS=arm64 ONLY_ACTIVE_ARCH=YES)
  if [[ -n "${MLX_GATEWAY_TEAM:-}" ]]; then signing_settings+=("DEVELOPMENT_TEAM=$MLX_GATEWAY_TEAM"); fi
  if [[ -n "${MLX_GATEWAY_SIGN_IDENTITY:-}" ]]; then signing_settings+=("CODE_SIGN_IDENTITY=$MLX_GATEWAY_SIGN_IDENTITY"); fi
  xcodebuild -version
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -destination "platform=macOS,arch=arm64" \
    "${signing_settings[@]}" \
    build
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

verify_codesign() {
  codesign --verify --strict --verbose=2 "$APP_BUNDLE"
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
  --build|build)
    build_app
    ;;
  run)
    stop_app
    build_app
    open_app
    ;;
  --verify|verify)
    stop_app
    build_app
    verify_codesign
    test "$(lipo -archs "$APP_BUNDLE/Contents/MacOS/$APP_NAME")" = "arm64"
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
