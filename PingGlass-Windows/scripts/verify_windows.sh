#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT_DIR="${ROOT_DIR}/chrome-extension"
HOST_DIR="${ROOT_DIR}/WindowsNativeHost"
WIN_APP_DIR="${ROOT_DIR}/WindowsApp"

echo "=== PingGlass-Windows Verification Suite ==="

echo "[1/4] Checking manifests and Windows project layout..."
python3 - "$EXT_DIR/manifest.json" "$HOST_DIR/host_manifest.json" "$WIN_APP_DIR/PingGlassWindows.csproj" <<'PY'
import json
import sys
from pathlib import Path

ext_manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert ext_manifest["manifest_version"] == 3
assert ext_manifest["name"] == "PingGlass"
assert "nativeMessaging" in ext_manifest["permissions"]

host_manifest = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
assert host_manifest["name"] == "com.pingglass.bridge"
assert host_manifest["path"].endswith(".bat")

csproj = Path(sys.argv[3]).read_text(encoding="utf-8")
assert "<TargetFramework>net8.0-windows</TargetFramework>" in csproj
assert "<UseWPF>true</UseWPF>" in csproj
assert "<UseWindowsForms>true</UseWindowsForms>" in csproj
print("Manifests and Windows csproj OK")
PY

echo "[2/4] Checking Chrome extension JS syntax & safe DOM usage (no innerHTML)..."
for js_file in background.js content.js popup.js options.js; do
  node --check "${EXT_DIR}/${js_file}"
done

if grep -rn "innerHTML" "${EXT_DIR}"/*.js >/dev/null 2>&1; then
  echo "Error: Unsafe innerHTML usage detected in PingGlass-Windows/chrome-extension!" >&2
  exit 1
fi
echo "Windows Chrome extension checks OK"

echo "[3/4] Testing Windows Native Messaging Host framing & token-authenticated loopback TCP bridge..."
python3 -B -m py_compile "${HOST_DIR}/pingglass_native_host.py"
python3 -B - "${HOST_DIR}/pingglass_native_host.py" <<'PY'
import json
import os
import secrets
import socket
import struct
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

host_script = sys.argv[1]

with tempfile.TemporaryDirectory() as tmpdir:
    state_dir = Path(tmpdir) / "PingGlass"
    state_dir.mkdir(parents=True, exist_ok=True)
    token = secrets.token_hex(32)

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    port = srv.getsockname()[1]

    (state_dir / "bridge.port").write_text(str(port), encoding="utf-8")
    (state_dir / "bridge.token").write_text(token, encoding="utf-8")

    received_from_host = []

    def server_worker():
        conn, _ = srv.accept()
        with conn:
            def read_exact(n):
                buf = bytearray()
                while len(buf) < n:
                    chunk = conn.recv(n - len(buf))
                    if not chunk:
                        return None
                    buf.extend(chunk)
                return bytes(buf)

            for _ in range(2):
                hdr = read_exact(4)
                if not hdr:
                    return
                (length,) = struct.unpack("<I", hdr)
                payload = json.loads(read_exact(length).decode("utf-8"))
                received_from_host.append(payload)

            msg = {
                "type": "incoming_message",
                "message": {
                    "id": "win-1",
                    "sender": "Rahul",
                    "chatName": "Rahul",
                    "text": "Ping from Windows UIA!",
                    "timestamp": "15:00",
                    "isTest": False,
                },
            }
            raw = json.dumps(msg).encode("utf-8")
            conn.sendall(struct.pack("<I", len(raw)) + raw)

    t = threading.Thread(target=server_worker, daemon=True)
    t.start()

    env = dict(os.environ)
    env["LOCALAPPDATA"] = tmpdir
    proc = subprocess.Popen(
        [sys.executable, host_script],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )

    def read_chrome_msg():
        hdr = proc.stdout.read(4)
        (n,) = struct.unpack("<I", hdr)
        return json.loads(proc.stdout.read(n).decode("utf-8"))

    forwarded = read_chrome_msg()
    assert forwarded["type"] == "incoming_message"
    assert forwarded["message"]["sender"] == "Rahul"

    proc.stdin.close()
    proc.wait(timeout=5)
    srv.close()

    assert received_from_host[0]["type"] == "auth"
    assert received_from_host[0]["token"] == token
    assert received_from_host[1]["type"] == "request_status"

print("Windows Native Messaging authenticated TCP bridge test OK")
PY

echo "[4/4] Verifying all required Windows C# modules exist..."
required_files=(
  "WindowsApp/App.xaml"
  "WindowsApp/App.xaml.cs"
  "WindowsApp/Models/WhatsAppMessage.cs"
  "WindowsApp/Core/MessageFingerprint.cs"
  "WindowsApp/Core/MessageProcessor.cs"
  "WindowsApp/Core/SessionChatStore.cs"
  "WindowsApp/Core/WhatsAppDetector.cs"
  "WindowsApp/Core/WindowsUiaExtractor.cs"
  "WindowsApp/Core/WindowsUiaMonitor.cs"
  "WindowsApp/Core/LocalIpcServer.cs"
  "WindowsApp/Core/LaunchAtLoginManager.cs"
  "WindowsApp/Core/AppState.cs"
  "WindowsApp/Notifications/DisplayScreenLocator.cs"
  "WindowsApp/Notifications/NotificationStackQueue.cs"
  "WindowsApp/Notifications/Win32GlassHelper.cs"
  "WindowsApp/Notifications/NotificationCardWindow.xaml"
  "WindowsApp/Notifications/NotificationCardWindow.xaml.cs"
  "WindowsApp/Notifications/ClearAllPillWindow.xaml"
  "WindowsApp/Notifications/ClearAllPillWindow.xaml.cs"
  "WindowsApp/Notifications/FloatingChatPopupWindow.xaml"
  "WindowsApp/Notifications/FloatingChatPopupWindow.xaml.cs"
  "WindowsApp/Notifications/GlobalNotificationWindowManager.cs"
  "WindowsApp/Views/TrayControlWindow.xaml"
  "WindowsApp/Views/TrayControlWindow.xaml.cs"
  "PingGlass-Windows.md"
)
for rel in "${required_files[@]}"; do
  if [[ ! -f "${ROOT_DIR}/${rel}" ]]; then
    echo "Missing file: ${rel}" >&2
    exit 1
  fi
done
echo "ALL PINGGLASS-WINDOWS CHECKS PASSED."
