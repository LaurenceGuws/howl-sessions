#!/usr/bin/env python3
"""Disposable PTY fixture: input is echoed as text and never executed."""
import sys

print("HOWL_WEB_ECHO_READY", flush=True)
for line in sys.stdin:
    print("ACK_FROM_PTY: " + line.rstrip("\r\n"), flush=True)
