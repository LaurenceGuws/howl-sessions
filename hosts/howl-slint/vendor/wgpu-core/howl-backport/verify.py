#!/usr/bin/env python3
"""Verify the vendored tree and, optionally, the pristine published archive."""
import hashlib
import json
from pathlib import Path
import sys
import tarfile

root = Path(__file__).resolve().parent.parent
record = json.loads((root / "howl-backport/checksums.json").read_text())
def sha(data):
    return hashlib.sha256(data).hexdigest()

assert sha((root / "howl-backport/upstream-fix.patch").read_bytes()) == record["patch_sha256"]
actual = {str(p.relative_to(root)) for p in root.rglob("*")
          if p.is_file() and "howl-backport" not in p.relative_to(root).parts}
assert actual == set(record["files"]), "Published file set changed"
for name, hashes in record["files"].items():
    assert sha((root / name).read_bytes()) == hashes["patched"], name
if len(sys.argv) > 1:
    archive = Path(sys.argv[1])
    assert sha(archive.read_bytes()) == record["crate_sha256"], "Archive checksum mismatch"
    with tarfile.open(archive) as tar:
        members = {m.name.removeprefix("wgpu-core-30.0.1/"): m
                   for m in tar.getmembers() if m.isfile()}
        assert set(members) == set(record["files"])
        for name, member in members.items():
            assert sha(tar.extractfile(member).read()) == record["files"][name]["published"], name
print("Verified wgpu-core 30.0.1 published file set and exact backport hashes")
