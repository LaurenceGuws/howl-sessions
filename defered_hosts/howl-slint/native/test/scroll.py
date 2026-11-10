#!/usr/bin/env python3
"""Emit 360 deterministic scrolling lines at 60 Hz; report timing on stderr.

Run in the disposable Server instance. Never skip output: late_frames counts
scheduled deadlines missed by more than one period, not dropped frames.
"""
import json
import sys
import time

start = time.monotonic()
frames = 360
late = 0
sys.stdout.write("\x1b[?25l\x1b[2J\x1b[H")
sys.stdout.flush()
for index in range(frames):
    target = start + index / 60
    time.sleep(max(0, target - time.monotonic()))
    late += time.monotonic() - target > 1 / 60
    line = f"{index:06d} " + ("scroll line " + str(index % 10) + " ") * 8
    sys.stdout.write("\x1b[?2026h" + line + "\r\n\x1b[?2026l")
    sys.stdout.flush()
time.sleep(max(0, start + 6 - time.monotonic()))
print(json.dumps({
    "workload": "scroll",
    "frames": frames,
    "late_frames": late,
    "seconds": time.monotonic() - start,
}), file=sys.stderr)
