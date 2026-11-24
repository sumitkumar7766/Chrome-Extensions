#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_NAME="com.pingglass.bridge"

echo "=== Uninstalling PingGlass ==="

# 1. Stop running helper gracefully if present
if pgrep -x "PingGlass" >/dev/null 2>&1; then
  osascript -e 'tell application "PingGlass" to quit' >/dev/null 2>&1 || true
  sleep 0.6
  pkill -x "PingGlass" >/dev/null 2>&1 || true
  echo "Stopped PingGlass helper process."
fi

# 2. Remove Native Messaging Host manifests
for browser_dir in \
  "${HOME}/Library/Application Support/Google/Chrome/NativeMessagingHosts" \
  "${HOME}/Library/Application Support/Google/Chrome Canary/NativeMessagingHosts" \
  "${HOME}/Library/Application Support/Chromium/NativeMessagingHosts"
do
  manifest_path="${browser_dir}/${HOST_NAME}.json"
  if [[ -f "$manifest_path" ]]; then
    rm -f "$manifest_path"
    echo "Removed native host manifest: $manifest_path"
  fi
done

# 3. Remove IPC socket directory and built app bundles
if [[ -d "${HOME}/.pingglass" ]]; then
  rm -rf "${HOME}/.pingglass"
  echo "Removed local IPC directory: ${HOME}/.pingglass"
fi

for app_path in \
  "${HOME}/Applications/PingGlass.app" \
  "${ROOT_DIR}/build/PingGlass.app"
do
  if [[ -d "$app_path" ]]; then
    rm -rf "$app_path"
    echo "Removed app bundle: $app_path"
  fi
done

if [[ -d "/Applications/PingGlass.app" && -w "/Applications/PingGlass.app" ]]; then
  rm -rf "/Applications/PingGlass.app"
  echo "Removed /Applications/PingGlass.app"
fi

# 4. Clear non-sensitive helper configuration defaults
defaults delete com.pingglass.app >/dev/null 2>&1 || true

cat <<EOF

PingGlass macOS helper and Chrome native bridge have been removed.
Optional manual cleanup:
  - Open chrome://extensions and remove the PingGlass extension.
  - Open System Settings -> Privacy & Security -> Accessibility and remove PingGlass if listed.
EOF
