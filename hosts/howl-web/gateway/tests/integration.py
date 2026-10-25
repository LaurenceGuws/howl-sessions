#!/usr/bin/env python3
"""Black-box fail-closed Server-attach and post-attach byte-bridge proof."""
from __future__ import annotations
import base64
import hashlib
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

GATEWAY = Path(sys.argv[1]).resolve()
ACCESS = 'test-access-assertion'
KEY = 'dGhlIHNhbXBsZSBub25jZQ=='
MAGIC = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'


def free_port() -> int:
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


SESSION_ID = 7
INSTANCE_ID = 3
SERVER_ID = 0x123456789ABCDEF0
TREE_REVISION = 9


def recv_exact(conn: socket.socket, size: int) -> bytes:
    out = bytearray()
    while len(out) < size:
        chunk = conn.recv(size - len(out))
        if not chunk:
            raise AssertionError('unexpected Server control EOF')
        out += chunk
    return bytes(out)


def server_frame(kind: int, payload: bytes = b'') -> bytes:
    assert len(payload) <= 8 * 1024
    return b'SRVR' + bytes((2, kind, 0, 0)) + struct.pack('!I', len(payload)) + payload


def recv_server_frame(conn: socket.socket) -> tuple[int, bytes]:
    header = recv_exact(conn, 12)
    assert header[:4] == b'SRVR'
    assert header[4] == 2
    assert header[6:8] == b'\0\0'
    size = struct.unpack('!I', header[8:12])[0]
    assert size <= 8 * 1024
    return header[5], recv_exact(conn, size)


def ready_frame(client_id: int) -> bytes:
    return server_frame(12, struct.pack(
        '!QQQQQ', SERVER_ID, SESSION_ID, INSTANCE_ID, TREE_REVISION, client_id))


class AttachedEchoServer:
    """Minimal real server_protocol attach peer, then opaque byte echo."""
    def __init__(self) -> None:
        self.port = free_port()
        self.accepted = 0
        self.server_id = SERVER_ID
        self.attached: list[tuple[int, int]] = []
        self._stop = threading.Event()
        self._listener = socket.socket()
        self._listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._listener.bind(('127.0.0.1', self.port))
        self._listener.listen(8)
        self._listener.settimeout(.1)
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self._thread.start()

    def close(self) -> None:
        self._stop.set()
        self._listener.close()
        self._thread.join(timeout=2)

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                conn, _ = self._listener.accept()
            except (socket.timeout, OSError):
                continue
            self.accepted += 1
            threading.Thread(target=self._serve, args=(conn, self.accepted), daemon=True).start()

    def _serve(self, conn: socket.socket, client_id: int) -> None:
        with conn:
            conn.settimeout(3)
            try:
                kind, payload = recv_server_frame(conn)
                assert kind == 1 and payload == b''  # hello
                status = struct.pack(
                    '!QQHHHH8x',
                    self.server_id,
                    TREE_REVISION,
                    1,
                    1,
                    16,
                    16,
                )
                conn.sendall(server_frame(2, status))  # welcome

                kind, payload = recv_server_frame(conn)
                assert kind == 11 and len(payload) == 16  # attach_instance
                identity = struct.unpack('!QQ', payload)
                assert identity == (SESSION_ID, INSTANCE_ID)
                self.attached.append(identity)
                conn.sendall(server_frame(
                    12,
                    struct.pack('!QQQQQ', self.server_id, SESSION_ID, INSTANCE_ID, TREE_REVISION, client_id),
                ))

                while data := conn.recv(65536):
                    conn.sendall(data)
            except (AssertionError, OSError):
                return


def read_head(sock: socket.socket, chunk_size: int = 4096) -> tuple[int, dict[str, str], bytes]:
    data = b''
    while b'\r\n\r\n' not in data:
        chunk = sock.recv(chunk_size)
        if not chunk: raise AssertionError('HTTP EOF before headers')
        data += chunk
        if len(data) > 65536: raise AssertionError('HTTP headers unexpectedly large')
    head, rest = data.split(b'\r\n\r\n', 1)
    lines = head.decode('latin1').split('\r\n')
    status = int(lines[0].split()[1])
    headers: dict[str, str] = {}
    for line in lines[1:]:
        name, value = line.split(':', 1)
        headers[name.lower()] = value.strip()
    return status, headers, rest


def http_get(port: int, host: str, path: str, access: bool) -> tuple[int, dict[str, str], bytes]:
    with socket.create_connection(('127.0.0.1', port), timeout=2) as sock:
        extra = f'Cf-Access-Jwt-Assertion: {ACCESS}\r\n' if access else ''
        sock.sendall(f'GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n{extra}\r\n'.encode())
        status, headers, rest = read_head(sock)
        length = int(headers.get('content-length', '0'))
        body = bytearray(rest)
        while len(body) < length:
            data = sock.recv(length - len(body))
            if not data: break
            body += data
        return status, headers, bytes(body[:length])


def ws_open(port: int, host: str, origin: str | None, access: bool, key: str = KEY) -> tuple[socket.socket, int, dict[str, str]]:
    sock = socket.create_connection(('127.0.0.1', port), timeout=2)
    origin_header = f'Origin: {origin}\r\n' if origin is not None else ''
    access_header = f'Cf-Access-Jwt-Assertion: {ACCESS}\r\n' if access else ''
    request = (
        f'GET /socket HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\n'
        f'Connection: keep-alive, Upgrade\r\nSec-WebSocket-Version: 13\r\n'
        f'Sec-WebSocket-Key: {key}\r\n{origin_header}{access_header}\r\n'
    )
    sock.sendall(request.encode())
    status, headers, rest = read_head(sock, 1)
    # Read the HTTP preface bytewise so a coalesced first ready message remains
    # on this socket for the WebSocket frame reader.
    if status == 101: assert not rest
    return sock, status, headers


def send_masked(sock: socket.socket, opcode: int, payload: bytes) -> None:
    size = len(payload)
    if size < 126:
        length = bytes([0x80 | size])
    elif size <= 0xffff:
        length = bytes([0x80 | 126]) + struct.pack('!H', size)
    else:
        length = bytes([0x80 | 127]) + struct.pack('!Q', size)
    mask = b'\x11\x22\x33\x44'
    masked = bytes(value ^ mask[i % 4] for i, value in enumerate(payload))
    sock.sendall(bytes([0x80 | opcode]) + length + mask + masked)


def recv_frame(sock: socket.socket) -> tuple[int, bytes]:
    first = sock.recv(2)
    if len(first) != 2: raise AssertionError('short WebSocket header')
    opcode = first[0] & 0x0f
    assert first[0] & 0x80
    assert not first[1] & 0x80
    size = first[1] & 0x7f
    if size == 126: size = struct.unpack('!H', sock.recv(2))[0]
    elif size == 127: size = struct.unpack('!Q', sock.recv(8))[0]
    body = b''
    while len(body) < size:
        body += sock.recv(size - len(body))
    return opcode, body




def recv_binary_bytes(sock: socket.socket, size: int) -> bytes:
    body = bytearray()
    while len(body) < size:
        opcode, chunk = recv_frame(sock)
        assert opcode == 2
        body += chunk
    assert len(body) == size
    return bytes(body)

def wait_ready(port: int) -> None:
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=.1): return
        except OSError: time.sleep(.02)
    raise AssertionError('gateway did not bind')


def main() -> None:
    server = AttachedEchoServer(); server.start()
    listen = free_port()
    host = f'howl.test:{listen}'
    origin = f'http://{host}'
    with tempfile.TemporaryDirectory(prefix='howl-gateway-test-') as raw:
        root = Path(raw)
        (root/'index.html').write_text('gateway-index\n')
        wire = root/'wire.wasm'; wire.write_bytes(b'wire')
        proc = subprocess.Popen([
            str(GATEWAY), str(listen), str(server.port), str(SERVER_ID), str(SESSION_ID), str(INSTANCE_ID),
            host, origin, str(root), str(wire), '--require-access',
        ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            wait_ready(listen)
            assert http_get(listen, host, '/', False)[0] == 403
            status, headers, body = http_get(listen, host, '/', True)
            assert status == 200 and body == b'gateway-index\n'
            assert headers['content-security-policy'].startswith("default-src 'self'")
            (root/'control_queue.mjs').write_text('export const queue = true;\n')
            status, headers, body = http_get(listen, host, '/control_queue.mjs', True)
            assert status == 200 and body == b'export const queue = true;\n'
            assert headers['content-type'].startswith('text/javascript')
            (root/'telemetry.mjs').write_text('export const telemetry = true;\n')
            status, headers, body = http_get(listen, host, '/telemetry.mjs', True)
            assert status == 200 and body == b'export const telemetry = true;\n'
            assert headers['content-type'].startswith('text/javascript')
            (root/'frame_scheduler.mjs').write_text('export const frames = true;\n')
            status, headers, body = http_get(listen, host, '/frame_scheduler.mjs', True)
            assert status == 200 and body == b'export const frames = true;\n'
            assert headers['content-type'].startswith('text/javascript')
            (root/'display_schedule.mjs').write_text('export const displaySchedule = true;\n')
            status, headers, body = http_get(listen, host, '/display_schedule.mjs', True)
            assert status == 200 and body == b'export const displaySchedule = true;\n'
            assert headers['content-type'].startswith('text/javascript')
            (root/'resize_policy.mjs').write_text('export const resizePolicy = true;\n')
            status, headers, body = http_get(listen, host, '/resize_policy.mjs', True)
            assert status == 200 and body == b'export const resizePolicy = true;\n'
            assert headers['content-type'].startswith('text/javascript')
            (root/'lifecycle_policy.mjs').write_text('export const lifecyclePolicy = true;\n')
            status, headers, body = http_get(listen, host, '/lifecycle_policy.mjs', True)
            assert status == 200 and body == b'export const lifecyclePolicy = true;\n'
            assert headers['content-type'].startswith('text/javascript')
            assert http_get(listen, 'wrong.test', '/', True)[0] == 403
            assert server.accepted == 0

            sock, status, _ = ws_open(listen, host, origin, False)
            sock.close(); assert status == 403 and server.accepted == 0
            sock, status, _ = ws_open(listen, host, 'http://wrong.test', True)
            sock.close(); assert status == 403 and server.accepted == 0
            sock, status, _ = ws_open(listen, host, origin, True, 'YQ==')
            sock.close(); assert status == 400 and server.accepted == 0

            one, status, head = ws_open(listen, host, origin, True)
            assert status == 101
            expected = base64.b64encode(hashlib.sha1((KEY + MAGIC).encode()).digest()).decode()
            assert head['sec-websocket-accept'] == expected
            deadline = time.monotonic()+2
            while server.accepted < 1 and time.monotonic() < deadline: time.sleep(.01)
            assert server.accepted == 1
            assert recv_frame(one) == (2, ready_frame(1))
            send_masked(one, 2, b'opaque-howl-bytes')
            assert recv_frame(one) == (2, b'opaque-howl-bytes')

            # A terminal WebSocket is a long-lived stream. Memory safety comes
            # from per-message bounds, fixed-size upstream chunks, and bounded
            # connection admission, not from a cumulative lifetime byte quota.
            stream_chunk = bytes(range(256)) * 128  # 32 KiB, under the 64 KiB message bound.
            stream_total = 0
            while stream_total <= 9 * 1024 * 1024:
                send_masked(one, 2, stream_chunk)
                assert recv_binary_bytes(one, len(stream_chunk)) == stream_chunk
                stream_total += len(stream_chunk)

            peers = []
            for index in range(5):
                peer, status, _ = ws_open(listen, host, origin, True)
                assert status == 101
                assert recv_frame(peer) == (2, ready_frame(index + 2))
                peers.append(peer)
            deadline = time.monotonic()+2
            while server.accepted < 6 and time.monotonic() < deadline: time.sleep(.01)
            assert server.accepted == 6
            deadline = time.monotonic()+2
            while len(server.attached) < 6 and time.monotonic() < deadline: time.sleep(.01)
            assert server.attached == [(SESSION_ID, INSTANCE_ID)] * 6
            seventh, status, _ = ws_open(listen, host, origin, True)
            seventh.close(); assert status == 503 and server.accepted == 6

            send_masked(one, 1, b'text-is-rejected')
            one.settimeout(2)
            assert one.recv(1) == b''
            one.close()
            for peer in peers: peer.close()
            # Retain the selected gateway target while its endpoint now welcomes
            # a different incarnation with exactly the same Session/Instance pair.
            server.server_id += 1
            # Capacity teardown is asynchronous; bounded wait for one free lane.
            deadline = time.monotonic() + 2
            while True:
                stale, status, _ = ws_open(listen, host, origin, True)
                stale.close()
                assert status == 503
                if server.accepted > 6:
                    break
                assert time.monotonic() < deadline
                time.sleep(.01)
            assert len(server.attached) == 6, server.attached
            print(json.dumps({
                'status':'pass', 'access_before_upstream':True, 'host_origin_exact':True,
                'binary_bridge':True, 'streaming_bridge_bytes':stream_total, 'text_rejected':True, 'websocket_capacity':6,
                'static_csp':True, 'server_attach':True, 'stale_incarnation_rejected':True, 'upstream_accepts':server.accepted,
            }))
        finally:
            proc.terminate()
            try: proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill(); proc.wait(timeout=2)
            stderr = proc.stderr.read() if proc.stderr else ''
            if proc.returncode not in (-15, 0):
                raise AssertionError(f'gateway exited {proc.returncode}: {stderr}')
            server.close()

if __name__ == '__main__': main()
