#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACOS_DIR="${ROOT_DIR}/macOS"
BUILD_OUT_DIR="${ROOT_DIR}/build"
APP_BUNDLE="${BUILD_OUT_DIR}/PingGlass.app"
INSTALL_TO_USER_APPS="${1:-}"

echo "Building PingGlass macOS helper (release)..."
swift build --package-path "$MACOS_DIR" -c release

BIN_DIR="$(swift build --package-path "$MACOS_DIR" -c release --show-bin-path)"
BUILT_BIN="${BIN_DIR}/PingGlass"

if [[ ! -f "$BUILT_BIN" ]]; then
  echo "Error: Built executable not found at $BUILT_BIN" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"

cp "$BUILT_BIN" "${APP_BUNDLE}/Contents/MacOS/PingGlass"
cp "${MACOS_DIR}/PingGlassApp/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
chmod 755 "${APP_BUNDLE}/Contents/MacOS/PingGlass"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

echo "Packaged macOS app bundle: $APP_BUNDLE"

if [[ "$INSTALL_TO_USER_APPS" == "--install" ]]; then
  mkdir -p "${HOME}/Applications"
  rm -rf "${HOME}/Applications/PingGlass.app"
  cp -R "$APP_BUNDLE" "${HOME}/Applications/PingGlass.app"
  echo "Installed to: ${HOME}/Applications/PingGlass.app"
fi
