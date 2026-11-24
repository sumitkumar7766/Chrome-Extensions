#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_SCRIPT="${SCRIPT_DIR}/pingglass_native_host.py"
TEMPLATE_MANIFEST="${SCRIPT_DIR}/host_manifest.json"
HOST_NAME="com.pingglass.bridge"

usage() {
  cat <<EOF
Usage: $(basename "$0") <CHROME_EXTENSION_ID>

Installs the PingGlass Native Messaging Host manifest for Google Chrome on macOS.
Find your 32-character Extension ID at chrome://extensions after loading chrome-extension/.
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

EXTENSION_ID="$1"
if [[ ! "$EXTENSION_ID" =~ ^[a-p]{32}$ ]]; then
  echo "Error: Invalid Chrome Extension ID '$EXTENSION_ID'." >&2
  echo "Expected 32 lowercase characters in range a-p (from chrome://extensions)." >&2
  exit 1
fi

if [[ ! -f "$HOST_SCRIPT" || ! -f "$TEMPLATE_MANIFEST" ]]; then
  echo "Error: Missing native host files in $SCRIPT_DIR" >&2
  exit 1
fi

chmod 755 "$HOST_SCRIPT"

TARGET_DIRS=(
  "${HOME}/Library/Application Support/Google/Chrome/NativeMessagingHosts"
)

# Also register for Google Chrome Canary or Chromium if those directories already exist.
for optional_root in \
  "${HOME}/Library/Application Support/Google/Chrome Canary" \
  "${HOME}/Library/Application Support/Chromium"
do
  if [[ -d "$optional_root" ]]; then
    TARGET_DIRS+=("${optional_root}/NativeMessagingHosts")
  fi
done

for target_dir in "${TARGET_DIRS[@]}"; do
  mkdir -p "$target_dir"
  dest_file="${target_dir}/${HOST_NAME}.json"
  python3 - "$TEMPLATE_MANIFEST" "$dest_file" "$HOST_SCRIPT" "$EXTENSION_ID" <<'PY'
import json
import sys
from pathlib import Path

template_path, dest_path, host_path, ext_id = sys.argv[1:5]
data = json.loads(Path(template_path).read_text(encoding="utf-8"))
data["path"] = host_path
data["allowed_origins"] = [f"chrome-extension://{ext_id}/"]
Path(dest_path).write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
  chmod 644 "$dest_file"
  echo "Installed native host manifest: $dest_file"
done

echo "Done! Restart Chrome (or reload the extension) if Chrome was already running."
