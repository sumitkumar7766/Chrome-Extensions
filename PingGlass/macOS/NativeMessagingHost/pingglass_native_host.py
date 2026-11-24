#!/usr/bin/env python3
"""
PingGlass Chrome Native Messaging Host

Bridges Chrome's length-prefixed stdin/stdout Native Messaging protocol
to the PingGlass macOS Swift helper over a user-private Unix domain socket.

Security & Privacy guarantees:
- stdout is strictly reserved for 4-byte length-prefixed UTF-8 JSON frames.
- Diagnostics go only to stderr and NEVER include WhatsApp message content.
- Socket connections verify UID ownership (`os.getuid()`).
- Zero network sockets or external HTTP requests.
"""

from __future__ import annotations

import json
import os
import socket
import stat
import struct
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

MAX_PAYLOAD_BYTES = 1_048_576  # 1 MiB Chrome Native Messaging ceiling
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
    "pause_notifications",
    "launch_helper",
}

ALLOWED_OUTBOUND_FROM_HELPER = {
    "connection_status",
    "monitoring_status",
    "incoming_message",
    "clear_all_notifications",
    "dismiss_notification",
    "pong",
    "error",
}


def utc_iso_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def default_socket_path() -> Path:
    return Path.home() / ".pingglass" / "bridge.sock"


def log_err(message: str) -> None:
    """Write non-sensitive diagnostic text to stderr only."""
    sys.stderr.write(f"[pingglass-native-host] {message}\n")
    sys.stderr.flush()


def read_exact_stream(stream: Any, size: int) -> bytes | None:
    """Read exactly `size` bytes from a blocking binary stream, handling partial reads."""
    chunks = bytearray()
    while len(chunks) < size:
        chunk = stream.read(size - len(chunks))
        if not chunk:
            return None if not chunks else None
        chunks.extend(chunk)
    return bytes(chunks)


def read_exact_socket(sock: socket.socket, size: int) -> bytes | None:
    """Read exactly `size` bytes from a blocking socket, handling partial reads."""
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
        raise ValueError(f"Payload exceeds maximum allowed size ({len(encoded)} bytes).")
    return HEADER_STRUCT.pack(len(encoded)) + encoded


def verify_socket_ownership(sock_path: Path) -> bool:
    """Ensure the Unix socket directory and file belong to the current local user."""
    try:
        uid = os.getuid()
        parent_stat = os.stat(sock_path.parent)
        if parent_stat.st_uid != uid:
            log_err("Socket parent directory UID mismatch; refusing connection.")
            return False
        sock_stat = os.stat(sock_path)
        if sock_stat.st_uid != uid or not stat.S_ISSOCK(sock_stat.st_mode):
            log_err("Socket file UID or type mismatch; refusing connection.")
            return False
        return True
    except FileNotFoundError:
        return False
    except OSError as exc:
        log_err(f"Socket stat error: {exc}")
        return False


def locate_pingglass_app() -> Path | None:
    """Locate PingGlass.app only in trusted local installation paths."""
    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parent.parent
    candidates = [
        Path("/Applications/PingGlass.app"),
        Path.home() / "Applications" / "PingGlass.app",
        repo_root / "build" / "PingGlass.app",
        repo_root / "macOS" / "build" / "PingGlass.app",
    ]
    for candidate in candidates:
        if candidate.is_dir() and (candidate / "Contents" / "MacOS" / "PingGlass").is_file():
            return candidate
    return None


class NativeMessagingBridge:
    def __init__(self, socket_path: Path | None = None) -> None:
        self.socket_path = socket_path or default_socket_path()
        self.stdout_lock = threading.Lock()
        self.socket_lock = threading.Lock()
        self.helper_socket: socket.socket | None = None
        self.stop_event = threading.Event()
        self.last_reported_helper_state: bool | None = None

    def send_to_chrome(self, payload: dict[str, Any]) -> None:
        try:
            frame = encode_frame(payload)
        except ValueError as exc:
            log_err(f"Dropping oversized outbound frame: {exc}")
            return

        with self.stdout_lock:
            try:
                sys.stdout.buffer.write(frame)
                sys.stdout.buffer.flush()
            except OSError as exc:
                log_err(f"Failed writing to Chrome stdout: {exc}")
                self.stop_event.set()

    def send_to_helper(self, payload: dict[str, Any]) -> bool:
        try:
            frame = encode_frame(payload)
        except ValueError as exc:
            log_err(f"Dropping oversized inbound frame: {exc}")
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
        """Maintain connection to the macOS helper Unix socket and forward frames to Chrome."""
        while not self.stop_event.is_set():
            if not verify_socket_ownership(self.socket_path):
                self.notify_helper_disconnected("PingGlass macOS helper is not running.")
                self.stop_event.wait(RECONNECT_INTERVAL_SECONDS)
                continue

            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                sock.settimeout(5.0)
                sock.connect(str(self.socket_path))
                sock.settimeout(None)
            except OSError:
                try:
                    sock.close()
                except OSError:
                    pass
                self.notify_helper_disconnected("Unable to connect to PingGlass macOS helper.")
                self.stop_event.wait(RECONNECT_INTERVAL_SECONDS)
                continue

            with self.socket_lock:
                self._close_helper_socket_locked()
                self.helper_socket = sock

            self.last_reported_helper_state = True
            log_err("Connected to PingGlass macOS helper socket.")
            self.send_to_helper({"type": "request_status", "timestamp": utc_iso_now()})

            # Read loop from Swift helper socket
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
                    log_err("Received malformed JSON from helper.")
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
                self.notify_helper_disconnected("PingGlass macOS helper disconnected.")
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
            app_path = locate_pingglass_app()
            if app_path is None:
                self.send_to_chrome(
                    {
                        "type": "error",
                        "error": "PingGlass.app was not found. Build it with scripts/build_macos.sh first.",
                        "timestamp": utc_iso_now(),
                    }
                )
                return
            try:
                subprocess.Popen(
                    ["open", str(app_path)],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            except OSError as exc:
                self.send_to_chrome(
                    {
                        "type": "error",
                        "error": f"Failed to launch PingGlass.app: {exc}",
                        "timestamp": utc_iso_now(),
                    }
                )
            return

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
                        "error": "PingGlass macOS helper is not running.",
                        "timestamp": utc_iso_now(),
                    }
                )

    def run(self) -> int:
        socket_thread = threading.Thread(target=self.socket_worker_loop, daemon=True)
        socket_thread.start()

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
            socket_thread.join(timeout=1.0)

        return 0


def main() -> int:
    bridge = NativeMessagingBridge()
    return bridge.run()


if __name__ == "__main__":
    raise SystemExit(main())
