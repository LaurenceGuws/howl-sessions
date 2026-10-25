#!/usr/bin/env python3
"""CLI help/usage/error presentation must never expose Zig return traces."""

import json
import subprocess
import sys


def invoke(cli, *args):
    return subprocess.run([cli, *args], text=True, capture_output=True, timeout=5)


def main():
    cli = sys.argv[1]
    for args in [
        ("--help",),
        ("help",),
        ("instance", "--help"),
        ("instance", "snapshot", "--help"),
        ("instance", "key", "--help"),
        ("server", "--help"),
        ("server", "run", "--help"),
        ("server", "status", "--help"),
        ("server", "session", "--help"),
        ("server", "instance", "--help"),
    ]:
        result = invoke(cli, *args)
        assert result.returncode == 0, (args, result)
        assert result.stdout and "usage:" in result.stdout, (args, result.stdout)
        if args[:2] == ("instance", "--help") or args[:2] == ("instance", "snapshot"):
            assert "--server SERVER_ENDPOINT SERVER_ID SESSION_ID INSTANCE_ID" in result.stdout, (args, result.stdout)
        assert not result.stderr, (args, result.stderr)

    for args, operation in [
        (("nonsense",), "nonsense"),
        (("instance",), "instance"),
        (("instance", "snapshot"), "instance.snapshot"),
        (("instance", "snapshot", "--server"), "instance.snapshot"),
        (("instance", "snapshot", "--server", "tcp://127.0.0.1:1", "0", "1"), "instance.snapshot"),
        (("instance", "snapshot", "--server", "tcp://127.0.0.1:1", "0", "1", "1"), "instance.snapshot"),
        (("server",), "server"),
        (("server", "run"), "server.run"),
        (("server", "session"), "server.session"),
        (("server", "instance", "create"), "server.instance.create"),
    ]:
        result = invoke(cli, *args)
        assert result.returncode == 64, (args, result)
        assert not result.stdout
        error = json.loads(result.stderr)
        assert error["schema"] == "howl.error/v1"
        assert error["operation"] == operation, (args, error)
        assert error["code"] == "InvalidArguments"
        assert "stack trace" not in result.stderr
        assert "error return context" not in result.stderr

    print("Howl CLI interface: PASS (clean help and structured usage failures)")


if __name__ == "__main__":
    main()
