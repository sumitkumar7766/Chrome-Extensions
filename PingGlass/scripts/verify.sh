#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT_DIR="${ROOT_DIR}/chrome-extension"
HOST_DIR="${ROOT_DIR}/macOS/NativeMessagingHost"

echo "=== PingGlass Verification Suite ==="

echo "[1/5] Validating JSON manifests..."
python3 - "$EXT_DIR/manifest.json" "$HOST_DIR/host_manifest.json" <<'PY'
import json
import sys
from pathlib import Path

ext_manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert ext_manifest["manifest_version"] == 3, "Expected Manifest V3"
assert ext_manifest["name"] == "PingGlass"
assert "nativeMessaging" in ext_manifest["permissions"]

host_manifest = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
assert host_manifest["name"] == "com.pingglass.bridge"
assert host_manifest["type"] == "stdio"
print("JSON manifests OK")
PY

echo "[2/5] Checking JavaScript syntax and safe DOM usage..."
for js_file in background.js content.js popup.js options.js; do
  node --check "${EXT_DIR}/${js_file}"
done

if grep -rn "innerHTML" "$EXT_DIR"/*.js >/dev/null 2>&1; then
  echo "Error: Unsafe innerHTML usage detected in chrome-extension JS!" >&2
  exit 1
fi
echo "Chrome extension JS checks OK"

echo "[3/5] Checking Python Native Messaging host syntax & protocol framing..."
python3 -B -m py_compile "${HOST_DIR}/pingglass_native_host.py"
python3 -B - "${HOST_DIR}/pingglass_native_host.py" <<'PY'
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

host_script = sys.argv[1]

# Isolate HOME so verify.sh remains deterministic even when PingGlass.app is already running live.
with tempfile.TemporaryDirectory() as isolated_home:
    env = dict(os.environ)
    env["HOME"] = isolated_home

    # Test 1: stdio pong when helper socket does not exist
    proc = subprocess.Popen(
        [sys.executable, host_script],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )

    def write_msg(pipe, obj):
        raw = json.dumps(obj).encode("utf-8")
        pipe.write(struct.pack("<I", len(raw)) + raw)
        pipe.flush()

    def read_msg(pipe):
        hdr = pipe.read(4)
        if len(hdr) < 4:
            return None
        (n,) = struct.unpack("<I", hdr)
        body = pipe.read(n)
        return json.loads(body.decode("utf-8"))

    # First message emitted by host when socket missing: connection_status helperConnected=False
    msg1 = read_msg(proc.stdout)
    assert msg1 is not None and msg1["type"] == "connection_status" and msg1["helperConnected"] is False, msg1

    write_msg(proc.stdin, {"type": "ping"})
    msg2 = read_msg(proc.stdout)
    assert msg2 is not None and msg2["type"] == "pong" and msg2["helperConnected"] is False, msg2

    write_msg(proc.stdin, {"type": "invalid_type_xyz"})
    msg3 = read_msg(proc.stdout)
    assert msg3 is not None and msg3["type"] == "error", msg3

    proc.stdin.close()
    rc = proc.wait(timeout=5)
    assert rc == 0, f"Expected clean exit 0, got {rc}"
print("Native Messaging protocol & validation checks OK")
PY

echo "[4/5] Running Swift unit tests..."
swift test --package-path "${ROOT_DIR}/macOS"

echo "[5/5] Building macOS PingGlass.app release bundle..."
"${ROOT_DIR}/scripts/build_macos.sh"

echo "ALL VERIFICATION CHECKS PASSED."
