#!/usr/bin/env python3
"""Private, bounded process-level Server lifetime proofs; never uses a live endpoint."""
import ctypes
import json
import os
from pathlib import Path
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time

CLI = sys.argv[1]
# Reap only this fixture's orphan descendants after the Server closes its group.
assert ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) == 0


def invoke(*args):
    result = subprocess.run([CLI, *map(str, args)], capture_output=True, text=True, timeout=5)
    assert result.returncode == 0, (args, result.stdout, result.stderr)
    return json.loads(result.stdout)


def frame(kind, payload=b''):
    return b'SRVR' + bytes([2, kind, 0, 0]) + struct.pack('>I', len(payload)) + payload


def exact(peer, count):
    result = b''
    while len(result) < count:
        part = peer.recv(count - len(result))
        assert part, 'unexpected EOF'
        result += part
    return result


def receive(peer):
    header = exact(peer, 12)
    assert header[:5] == b'SRVR\x02' and header[6:8] == bytes(2)
    return header[5], exact(peer, struct.unpack('>I', header[8:])[0])


def connect(endpoint):
    if endpoint.startswith('unix:'):
        peer = socket.socket(socket.AF_UNIX)
        peer.settimeout(2)
        peer.connect(endpoint[5:])
    else:
        peer = socket.create_connection(('127.0.0.1', int(endpoint.rsplit(':', 1)[1])), 2)
    try:
        peer.sendall(frame(1))
        kind, welcome = receive(peer)
        assert kind == 2
        return peer, welcome
    except BaseException:
        peer.close()
        raise


class Server:
    def __init__(self, spec='tcp:0'):
        self.process = subprocess.Popen([CLI, 'server', 'run', spec], stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True)
        try:
            assert select.select([self.process.stdout], [], [], 5)[0], 'startup timeout'
            line = self.process.stdout.readline()
            assert line, self.process.stderr.read()
            self.receipt = json.loads(line)
            self.endpoint = self.receipt['endpoint']
        except BaseException:
            self.close()
            raise

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=2)
        self.process.stdout.close()
        self.process.stderr.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def wait_for(predicate, seconds=3):
    deadline = time.monotonic() + seconds
    while not predicate():
        assert time.monotonic() < deadline, 'fixture timeout'
        time.sleep(.01)


def parked_disconnect():
    with Server() as server:
        before = len(os.listdir(f'/proc/{server.process.pid}/fd'))
        for _ in range(32):  # Twice the bounded control capacity, with no tree changes.
            peer, welcome = connect(server.endpoint)
            with peer:
                revision = welcome[8:16]
                peer.sendall(frame(5, revision) + frame(3))
                # A pipelined status must not overtake the outstanding observation.
                assert not select.select([peer], [], [], .025)[0]
            # Wait only for this client's ordinary FIN reclamation.
            wait_for(lambda: len(os.listdir(f'/proc/{server.process.pid}/fd')) == before)
        with connect(server.endpoint)[0] as peer:
            peer.sendall(frame(3))
            assert receive(peer)[0] == 4
    print('parked TCP disconnect: capacity recovered, serialization preserved')


def unix_ownership(root):
    path = root / 'u'
    spec = 'unix:' + str(path)
    path.write_text('foreign regular file')
    collision = subprocess.run([CLI, 'server', 'run', spec], capture_output=True, timeout=5)
    assert collision.returncode != 0 and path.read_text() == 'foreign regular file'
    path.unlink()
    with Server(spec) as first:
        original = path.stat().st_ino
        collision = subprocess.run([CLI, 'server', 'run', spec], capture_output=True, timeout=5)
        assert collision.returncode != 0 and path.stat().st_ino == original
        with connect(first.endpoint)[0]:
            pass
        # Explicit owner-directed replacement; startup never performs this unlink.
        path.unlink()
        with Server(spec) as successor:
            replacement = path.stat().st_ino
            first.process.terminate()
            assert first.process.wait(timeout=5) == 0
            assert path.stat().st_ino == replacement
            with connect(successor.endpoint)[0]:
                pass
        assert not path.exists()
    print('Unix ownership: regular file, active collision, successor preserved, cleanup')


def create_child(server, root, descendant=False):
    fixture = root / 'child.py'
    pidfile = root / 'leader'
    childfile = root / 'descendant'
    pidfile.unlink(missing_ok=True)
    childfile.unlink(missing_ok=True)
    fixture.write_text('''import os, signal, sys, time
signal.signal(signal.SIGHUP, signal.SIG_IGN)
signal.signal(signal.SIGTERM, signal.SIG_IGN)
open(sys.argv[1], 'w').write(str(os.getpid()))
if len(sys.argv) > 2:
    if os.fork():
        os._exit(0)
    open(sys.argv[2], 'w').write(str(os.getpid()))
time.sleep(30)
''')
    sid = invoke('server', 'session', 'create', server.endpoint, 'lifetime')['session_id']
    command = f'exec /usr/bin/python3 {fixture} {pidfile}'
    if descendant:
        command += f' {childfile}'
    iid = invoke('server', 'instance', 'create', server.endpoint, sid,
                 '--shell', '/bin/sh', '--command', command,
                 '--rows', 2, '--columns', 8, '--history-rows', 2)['instance_id']
    wait_for(lambda: pidfile.exists() and pidfile.read_text() and
             (not descendant or (childfile.exists() and childfile.read_text())))
    return sid, iid


def reap_fixture(root, require_dead):
    # Kill/reap exact fixture PIDs even if an assertion failed; never process-name cleanup.
    for filename in ('leader', 'descendant'):
        path = root / filename
        if not path.exists() or not path.read_text():
            continue
        pid = int(path.read_text())
        proc = Path(f'/proc/{pid}/stat')
        state = proc.read_text().split(')')[1].split()[0] if proc.exists() else None
        if state not in (None, 'Z'):
            os.kill(pid, signal.SIGKILL)
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
        assert not Path(f'/proc/{pid}').exists(), pid
        if require_dead:
            assert state in (None, 'Z'), ('owned child survived shutdown', pid, state)


def shutdown(root, sig):
    path = root / 'u'
    success = False
    with Server('unix:' + str(path)) as server:
        try:
            create_child(server, root)
            server.process.send_signal(sig)
            assert server.process.wait(timeout=5) == 0
            assert not path.exists()
            success = True
        finally:
            server.close()
            reap_fixture(root, success)
    print(f'{sig.name}: ordinary exit, resistant child stopped, Unix path removed')


def repeated_shutdown(root, first_signal, with_child):
    path = root / 'u'
    success = False
    with Server('unix:' + str(path)) as server:
        try:
            if with_child:
                create_child(server, root)
            # No socket work remains; termination must interrupt the dormant wait.
            time.sleep(.15)
            start = time.monotonic()
            sent = 0
            for index in range(8):
                if server.process.poll() is not None:
                    break
                sig = first_signal if index % 2 == 0 else (
                    signal.SIGINT if first_signal == signal.SIGTERM else signal.SIGTERM)
                # A bounded pair exercises repeated intent even when an empty
                # Server can exit before the next 250 ms interval. Popen avoids
                # sending to an already-reaped child; exit ends the sender loop.
                other = signal.SIGINT if sig == signal.SIGTERM else signal.SIGTERM
                for repeated in (sig, other):
                    server.process.send_signal(repeated)
                    sent += 1
                try:
                    server.process.wait(timeout=.25)
                    break
                except subprocess.TimeoutExpired:
                    pass
            assert server.process.wait(timeout=3) == 0
            elapsed = time.monotonic() - start
            # Measured from the FIRST signal, not the last signal or the end of
            # the bounded sender loop. Old retrying poll takes about 2.8 seconds.
            assert elapsed < 1.25, ('signals restarted shutdown wait', elapsed, sent)
            assert not path.exists()
            success = True
            print(f'repeated {first_signal.name}, child={with_child}: '
                  f'{sent} signal attempts, exit {elapsed:.3f}s after first signal')
        finally:
            server.close()
            if with_child:
                reap_fixture(root, success)


def quiet_exit(root):
    success = False
    with Server() as server:
        try:
            sid, iid = create_child(server, root, descendant=True)
            # No attach, input or PTY output to discover the leader's exit.
            time.sleep(1.3)
            tree = invoke('server', 'tree', server.endpoint)
            instance = tree['sessions'][0]['instances'][0]
            assert instance['instance_id'] == iid and instance['state'] == 'exited', tree
            assert int(tree['tree_revision']) == 4, tree
            invoke('server', 'session', 'close', server.endpoint, sid)
            success = True
        finally:
            server.close()
            reap_fixture(root, success)
    print('quiet leader exit: housekeeping publishes exit with descendant holding PTY')


if __name__ == "__main__":
    for sig in (signal.SIGTERM, signal.SIGINT):
        with Server() as empty:
            empty.process.send_signal(sig)
            assert empty.process.wait(timeout=3) == 0
    print('empty Server: bounded SIGTERM and SIGINT shutdown without socket readiness')
    parked_disconnect()
    with tempfile.TemporaryDirectory(prefix='t-', dir=os.environ.get('HOWL_TEST_SCRATCH')) as directory:
        root = Path(directory)
        unix_ownership(root)
        shutdown(root, signal.SIGTERM)
        shutdown(root, signal.SIGINT)
        for first_signal in (signal.SIGTERM, signal.SIGINT):
            repeated_shutdown(root, first_signal, with_child=False)
            repeated_shutdown(root, first_signal, with_child=True)
        quiet_exit(root)
