# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Raw loopback peer used by host smoke checks.

The peer binds an ephemeral loopback port and records request bytes before
returning a separately configured response.  It never contacts an external
service.
"""

from __future__ import annotations

import argparse
import json
import socket
import time
import threading
from dataclasses import dataclass, field
from http import HTTPStatus
from typing import Iterable


@dataclass(frozen=True)
class PeerAction:
    kind: str = "AcceptAndRespond"
    status: int = 200
    headers: tuple[tuple[str, bytes], ...] = ()
    body: bytes = b""
    release: threading.Event | None = None
    close_after: int | None = None


@dataclass(frozen=True)
class RequestRecord:
    method: str
    target: str
    headers: tuple[tuple[str, bytes], ...]
    body: bytes
    complete: bool


class ControlledPeer:
    def __init__(self, action: PeerAction = PeerAction(), *, backlog: int = 8) -> None:
        self.action = action
        self._server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._server.bind(("127.0.0.1", 0))
        self._server.listen(backlog)
        self._address = self._server.getsockname()
        self._server.settimeout(0.2)
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._records: list[RequestRecord] = []
        self._lock = threading.Lock()

    @property
    def address(self) -> tuple[str, int]:
        host, port = self._address
        return str(host), int(port)

    @property
    def url(self) -> str:
        host, port = self.address
        return f"http://{host}:{port}/"

    @property
    def records(self) -> tuple[RequestRecord, ...]:
        with self._lock:
            return tuple(self._records)

    @property
    def request_count(self) -> int:
        return len(self.records)

    def start(self) -> "ControlledPeer":
        if self.action.kind == "RefuseConnection":
            self._server.close()
            return self
        if self._thread is None:
            self._thread = threading.Thread(target=self._serve, name="controlled-peer", daemon=True)
            self._thread.start()
        return self

    def release(self) -> None:
        if self.action.release is not None:
            self.action.release.set()

    def wait_for_request(self, count: int = 1, timeout: float = 2.0) -> bool:
        stop_at = time.monotonic() + timeout
        while time.monotonic() < stop_at:
            if self.request_count >= count:
                return True
            time.sleep(0.01)
        return self.request_count >= count

    def close(self) -> None:
        self._stop.set()
        try:
            self._server.close()
        finally:
            if self._thread is not None:
                self._thread.join(timeout=1.0)

    def __enter__(self) -> "ControlledPeer":
        return self.start()

    def __exit__(self, *_: object) -> None:
        self.close()

    def _serve(self) -> None:
        while not self._stop.is_set():
            try:
                client, _ = self._server.accept()
            except (socket.timeout, OSError):
                continue
            if self.action.kind == "ResetOnAccept":
                try:
                    import struct

                    client.setsockopt(
                        socket.SOL_SOCKET,
                        socket.SO_LINGER,
                        struct.pack("ii", 1, 0),
                    )
                finally:
                    client.close()
                return
            with client:
                client.settimeout(2.0)
                self._serve_client(client)
            if self.action.kind in {"CloseBeforeHeaders", "CloseBeforeBody", "MalformedResponse", "PartialWriteClose"}:
                return

    @staticmethod
    def _read_request(client: socket.socket) -> RequestRecord:
        data = bytearray()
        while b"\r\n\r\n" not in data and len(data) <= 1 << 20:
            block = client.recv(4096)
            if not block:
                break
            data.extend(block)
        head, _, body = bytes(data).partition(b"\r\n\r\n")
        lines = head.split(b"\r\n")
        first = lines[0].decode("ascii", "replace").split(" ", 2)
        method = first[0] if first else ""
        target = first[1] if len(first) > 1 else ""
        headers: list[tuple[str, bytes]] = []
        length = 0
        for line in lines[1:]:
            name, sep, value = line.partition(b":")
            if not sep:
                continue
            decoded = value.lstrip(b" \t")
            headers.append((name.decode("ascii", "replace"), decoded))
            if name.lower() == b"content-length":
                try:
                    length = int(decoded)
                except ValueError:
                    length = 0
        complete = len(body) >= length
        while len(body) < length:
            block = client.recv(min(4096, length - len(body)))
            if not block:
                complete = False
                break
            body += block
        return RequestRecord(method, target, tuple(headers), body[:length], complete)

    def _serve_client(self, client: socket.socket) -> None:
        if self.action.kind == "RefuseConnection":
            return
        record = self._read_request(client)
        with self._lock:
            self._records.append(record)
        if self.action.kind == "CloseBeforeHeaders":
            return
        if self.action.kind == "DelayUntilRelease" and self.action.release is not None:
            self.action.release.wait(2.0)
        if self.action.kind == "CloseBeforeBody":
            response = self._response_head()
            client.sendall(response)
            return
        if self.action.kind == "MalformedResponse":
            client.sendall(b"HTTP/1.1 malformed\r\n\r\n")
            return
        response = self._response_head()
        body = self.action.body
        if self.action.kind == "ReturnOversizedBody":
            body = body or b"x" * 4096
        if self.action.kind == "PartialWriteClose":
            cutoff = self.action.close_after if self.action.close_after is not None else max(1, len(response) // 2)
            client.sendall(response[:cutoff])
            return
        client.sendall(response + body)

    def _response_head(self) -> bytes:
        status = self.action.status
        reason = HTTPStatus(status).phrase if status in HTTPStatus._value2member_map_ else "Unknown"
        headers = list(self.action.headers)
        if not any(name.lower() == "content-length" for name, _ in headers):
            headers.append(("Content-Length", str(len(self.action.body)).encode("ascii")))
        return (
            f"HTTP/1.1 {status} {reason}\r\n".encode("ascii")
            + b"".join(name.encode("ascii") + b": " + value + b"\r\n" for name, value in headers)
            + b"\r\n"
        )


def serve_once(timeout: float = 5.0) -> dict[str, object]:
    with ControlledPeer().start() as peer:
        result = {"host": peer.address[0], "port": peer.address[1], "url": peer.url}
        print(json.dumps(result, sort_keys=True), flush=True)
        peer.wait_for_request(timeout=timeout)
        result["requestCount"] = peer.request_count
        return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--serve-once", action="store_true")
    args = parser.parse_args()
    if args.serve_once:
        serve_once()
        return 0
    parser.error("use --serve-once")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())


__all__ = ["ControlledPeer", "PeerAction", "RequestRecord", "serve_once"]
