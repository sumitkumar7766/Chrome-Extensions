#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXTENSION_ID="${1:-}"

echo "=== PingGlass Installer ==="
"${ROOT_DIR}/scripts/build_macos.sh" --install

if [[ -n "$EXTENSION_ID" ]]; then
  "${ROOT_DIR}/macOS/NativeMessagingHost/install_native_host.sh" "$EXTENSION_ID"
else
  cat <<EOF

Next steps to complete Chrome bridge registration:
  1. Open Chrome and navigate to chrome://extensions
  2. Enable "Developer mode" (top right)
  3. Click "Load unpacked" and select:
       ${ROOT_DIR}/chrome-extension
  4. Copy the 32-character Extension ID shown on the PingGlass card
  5. Register the Native Messaging Host by running:
       ${ROOT_DIR}/macOS/NativeMessagingHost/install_native_host.sh <EXTENSION_ID>
  6. Launch PingGlass from ~/Applications/PingGlass.app and grant Accessibility permission in
     System Settings -> Privacy & Security -> Accessibility.
EOF
fi
