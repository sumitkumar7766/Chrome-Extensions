#!/usr/bin/env python3
"""
PingGlass Windows Chrome Native Messaging Host

Bridges Chromium's 4-byte length-prefixed stdin/stdout Native Messaging protocol
to the PingGlassWindows.exe desktop helper over user-authenticated loopback TCP.

Security & Privacy guarantees:
- stdout is strictly reserved for binary 4-byte LE length-prefixed UTF-8 JSON frames.
- Sets binary stdin/stdout modes via msvcrt on Windows so 0x0A frame lengths never translate.
- Authenticates every TCP session using the per-user token stored in %LOCALAPPDATA%\\PingGlass\\bridge.token.
- Diagnostics write only to stderr and never log WhatsApp message bodies or senders.
"""

from __future__ import annotations

import json
import os
import socket
import struct
import subprocess
import sys
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

if os.name == "nt":
    import msvcrt  # type: ignore

    msvcrt.setmode(sys.stdin.fileno(), os.O_BINARY)
    msvcrt.setmode(sys.stdout.fileno(), os.O_BINARY)

MAX_PAYLOAD_BYTES = 1_048_576
HEADER_STRUCT = struct.Struct("<I")
RECONNECT_INTERVAL_SECONDS = 2.0

ALLOWED_INBOUND_FROM_CHROME = {
    "ping",
    "request_status",
    "start_monitoring",
    "pause_monitoring",
    "settings_update",
    "test_notification",
    "clear_all_notifications",
    "dismiss_notification",
    "open_whatsapp",
    "send_reply",
    "pause_notifications",
    "launch_helper",
}

ALLOWED_OUTBOUND_FROM_HELPER = {
    "connection_status",
    "monitoring_status",
    "incoming_message",
    "reply_result",
    "clear_all_notifications",
    "dismiss_notification",
    "pong",
    "error",
}


def utc_iso_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def default_state_dir() -> Path:
    local_app_data = os.environ.get("LOCALAPPDATA")
    if local_app_data:
        return Path(local_app_data) / "PingGlass"
    return Path.home() / "AppData" / "Local" / "PingGlass"


def log_err(message: str) -> None:
    sys.stderr.write(f"[pingglass-windows-host] {message}\n")
    sys.stderr.flush()


def read_exact_stream(stream: Any, size: int) -> bytes | None:
    chunks = bytearray()
    while len(chunks) < size:
        chunk = stream.read(size - len(chunks))
        if not chunk:
            return None
        chunks.extend(chunk)
    return bytes(chunks)


def read_exact_socket(sock: socket.socket, size: int) -> bytes | None:
    chunks = bytearray()
    while len(chunks) < size:
        try:
            chunk = sock.recv(size - len(chunks))
        except InterruptedError:
            continue
        except OSError:
            return None
        if not chunk:
            return None
        chunks.extend(chunk)
    return bytes(chunks)


def encode_frame(payload: dict[str, Any]) -> bytes:
    encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if len(encoded) > MAX_PAYLOAD_BYTES:
        raise ValueError(f"Payload exceeds ceiling ({len(encoded)} bytes).")
    return HEADER_STRUCT.pack(len(encoded)) + encoded


def read_bridge_endpoint(state_dir: Path) -> tuple[int, str] | None:
    port_file = state_dir / "bridge.port"
    token_file = state_dir / "bridge.token"
    try:
        raw_port = port_file.read_text(encoding="utf-8").strip()
        token = token_file.read_text(encoding="utf-8").strip()
        port = int(raw_port)
        if not (1 <= port <= 65535) or len(token) < 16:
            return None
        return port, token
    except (OSError, ValueError):
        return None


def locate_pingglass_windows_exe() -> Path | None:
    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parent
    local_dir = default_state_dir()
    candidates = [
        local_dir / "App" / "PingGlassWindows.exe",
        repo_root / "build" / "PingGlassWindows.exe",
        repo_root / "WindowsApp" / "bin" / "Release" / "net8.0-windows" / "PingGlassWindows.exe",
        repo_root / "WindowsApp" / "bin" / "Release" / "net8.0-windows" / "win-x64" / "publish" / "PingGlassWindows.exe",
        repo_root / "WindowsApp" / "bin" / "Debug" / "net8.0-windows" / "PingGlassWindows.exe",
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return None


class WindowsNativeMessagingBridge:
    def __init__(self, state_dir: Path | None = None) -> None:
        self.state_dir = state_dir or default_state_dir()
        self.stdout_lock = threading.Lock()
        self.socket_lock = threading.Lock()
        self.helper_socket: socket.socket | None = None
        self.stop_event = threading.Event()
        self.last_reported_helper_state: bool | None = None

    def send_to_chrome(self, payload: dict[str, Any]) -> None:
        try:
            frame = encode_frame(payload)
        except ValueError as exc:
            log_err(f"Dropping oversized frame: {exc}")
            return

        with self.stdout_lock:
            try:
                sys.stdout.buffer.write(frame)
                sys.stdout.buffer.flush()
            except OSError as exc:
                log_err(f"Failed writing Chrome stdout: {exc}")
                self.stop_event.set()

    def send_to_helper(self, payload: dict[str, Any]) -> bool:
        try:
            frame = encode_frame(payload)
        except ValueError as exc:
            log_err(f"Dropping oversized helper payload: {exc}")
            return False

        with self.socket_lock:
            sock = self.helper_socket
            if sock is None:
                return False
            try:
                sock.sendall(frame)
                return True
            except OSError:
                self._close_helper_socket_locked()
                return False

    def _close_helper_socket_locked(self) -> None:
        if self.helper_socket is not None:
            try:
                self.helper_socket.close()
            except OSError:
                pass
            self.helper_socket = None

    def notify_helper_disconnected(self, reason: str) -> None:
        if self.last_reported_helper_state is False:
            return
        self.last_reported_helper_state = False
        self.send_to_chrome(
            {
                "type": "connection_status",
                "helperConnected": False,
                "error": reason,
                "timestamp": utc_iso_now(),
            }
        )

    def socket_worker_loop(self) -> None:
        while not self.stop_event.is_set():
            endpoint = read_bridge_endpoint(self.state_dir)
            if endpoint is None:
                self.notify_helper_disconnected("PingGlass Windows helper is not running.")
                self.stop_event.wait(RECONNECT_INTERVAL_SECONDS)
                continue

            port, token = endpoint
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            try:
                sock.settimeout(5.0)
                sock.connect(("127.0.0.1", port))
                sock.sendall(encode_frame({"type": "auth", "token": token, "timestamp": utc_iso_now()}))
                sock.settimeout(None)
            except OSError:
                try:
                    sock.close()
                except OSError:
                    pass
                self.notify_helper_disconnected("Unable to connect to PingGlass Windows helper.")
                self.stop_event.wait(RECONNECT_INTERVAL_SECONDS)
                continue

            with self.socket_lock:
                self._close_helper_socket_locked()
                self.helper_socket = sock

            self.last_reported_helper_state = True
            log_err("Connected to PingGlass Windows helper IPC.")
            self.send_to_helper({"type": "request_status", "timestamp": utc_iso_now()})

            while not self.stop_event.is_set():
                header = read_exact_socket(sock, 4)
                if header is None:
                    break
                (length,) = HEADER_STRUCT.unpack(header)
                if length == 0 or length > MAX_PAYLOAD_BYTES:
                    log_err(f"Invalid helper frame size: {length}")
                    break

                body = read_exact_socket(sock, length)
                if body is None:
                    break

                try:
                    payload = json.loads(body.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    log_err("Malformed JSON received from Windows helper.")
                    continue

                if not isinstance(payload, dict):
                    continue
                msg_type = payload.get("type")
                if msg_type not in ALLOWED_OUTBOUND_FROM_HELPER:
                    log_err(f"Blocked unknown outbound message type: {msg_type}")
                    continue

                self.send_to_chrome(payload)

            with self.socket_lock:
                self._close_helper_socket_locked()

            if not self.stop_event.is_set():
                self.notify_helper_disconnected("PingGlass Windows helper disconnected.")
                self.stop_event.wait(RECONNECT_INTERVAL_SECONDS)

    def handle_chrome_message(self, payload: dict[str, Any]) -> None:
        msg_type = payload.get("type")
        if not isinstance(msg_type, str) or msg_type not in ALLOWED_INBOUND_FROM_CHROME:
            self.send_to_chrome(
                {
                    "type": "error",
                    "error": f"Unsupported message type: {msg_type}",
                    "timestamp": utc_iso_now(),
                }
            )
            return

        if msg_type == "launch_helper":
            exe_path = locate_pingglass_windows_exe()
            if exe_path is None:
                self.send_to_chrome(
                    {
                        "type": "error",
                        "error": "PingGlassWindows.exe not found. Run scripts\\build_windows.ps1 first.",
                        "timestamp": utc_iso_now(),
                    }
                )
                return
            try:
                subprocess.Popen(
                    [str(exe_path)],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    creationflags=getattr(subprocess, "DETACHED_PROCESS", 0),
                )
            except OSError as exc:
                self.send_to_chrome(
                    {
                        "type": "error",
                        "error": f"Failed to launch PingGlassWindows.exe: {exc}",
                        "timestamp": utc_iso_now(),
                    }
                )
            return

        if "timestamp" not in payload or not payload["timestamp"]:
            payload = dict(payload)
            payload["timestamp"] = utc_iso_now()

        sent = self.send_to_helper(payload)
        if not sent:
            if msg_type == "ping":
                self.send_to_chrome(
                    {
                        "type": "pong",
                        "helperConnected": False,
                        "timestamp": utc_iso_now(),
                    }
                )
            else:
                self.send_to_chrome(
                    {
                        "type": "connection_status",
                        "helperConnected": False,
                        "error": "PingGlass Windows helper is not running.",
                        "timestamp": utc_iso_now(),
                    }
                )

    def run(self) -> int:
        worker = threading.Thread(target=self.socket_worker_loop, daemon=True)
        worker.start()

        stdin = sys.stdin.buffer
        try:
            while not self.stop_event.is_set():
                header = read_exact_stream(stdin, 4)
                if header is None:
                    break
                (length,) = HEADER_STRUCT.unpack(header)
                if length == 0 or length > MAX_PAYLOAD_BYTES:
                    log_err(f"Invalid Chrome frame length: {length}")
                    break

                body = read_exact_stream(stdin, length)
                if body is None:
                    break

                try:
                    payload = json.loads(body.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    log_err("Malformed JSON received from Chrome.")
                    continue

                if isinstance(payload, dict):
                    self.handle_chrome_message(payload)
        finally:
            self.stop_event.set()
            with self.socket_lock:
                self._close_helper_socket_locked()
            worker.join(timeout=1.0)

        return 0


def main() -> int:
    bridge = WindowsNativeMessagingBridge()
    return bridge.run()


if __name__ == "__main__":
    raise SystemExit(main())
