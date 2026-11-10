#!/usr/bin/env python3
"""Capture the native target-built text result, not system-library goldens."""
import ctypes as c
import hashlib
import json
from pathlib import Path
import sys

if len(sys.argv) != 4:
    raise SystemExit("usage: native.py LIBRARY FONT OUTPUT_DIRECTORY")
lib = c.CDLL(str(Path(sys.argv[1]).resolve()))
for name in ("font_input", "font_capacity", "result_ptr", "result_len", "raster_ptr", "raster_len", "error_ptr", "error_len"):
    function = getattr(lib, name)
    function.restype = c.c_size_t
    function.argtypes = []
lib.run.restype = c.c_uint32
lib.run.argtypes = [c.c_uint32]
lib.jump_probe.restype = c.c_uint32
lib.jump_probe.argtypes = []
if lib.jump_probe() != 1:
    raise RuntimeError("native C nonlocal jumps failed")
font = Path(sys.argv[2]).read_bytes()
if not 0 < len(font) <= lib.font_capacity():
    raise ValueError("font outside canary input capacity")
c.memmove(lib.font_input(), font, len(font))
if lib.run(len(font)) != 1:
    raise RuntimeError(c.string_at(lib.error_ptr(), lib.error_len()).decode())
report = json.loads(c.string_at(lib.result_ptr(), lib.result_len()))
pixels = c.string_at(lib.raster_ptr(), lib.raster_len())
if not pixels or not any(pixels) or c.string_at(lib.font_input(), len(font)) != b"\xa5" * len(font):
    raise RuntimeError("native proof did not rasterize from independently owned font bytes")
output = Path(sys.argv[3])
output.mkdir(parents=True, exist_ok=True)
reference = {"report": report, "mask_sha256": hashlib.sha256(pixels).hexdigest()}
(output / "expected.json").write_text(json.dumps(reference, separators=(",", ":")) + "\n")
(output / "masks.bin").write_bytes(pixels)
print(json.dumps({"native_text": "pass", "glyphs": len(report["glyphs"]), "mask_bytes": len(pixels), "sha256": reference["mask_sha256"]}))
