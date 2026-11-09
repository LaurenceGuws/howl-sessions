# Howl's temporary wgpu-core 30.0.1 backport

This is the complete published `wgpu-core` crate, with exactly three Rust files
changed by the upstream fix below. All other published bytes, including the
normalized Cargo manifest, original manifest, crate lockfile, build script and
both MIT/Apache licenses, are unchanged. No other dependency is vendored.

## Provenance

- Crate: https://static.crates.io/crates/wgpu-core/wgpu-core-30.0.1.crate
- Crates.io sparse index: https://index.crates.io/wg/pu/wgpu-core
- Archive SHA-256: `14c018fce9b6270aa203c2fdd56f3cce996713534bd757e4ea58c8560b121f14`
- Published source revision: `40f4a34ebaf56f9a046231f54125ad046239d3f3`
- Fix: https://github.com/gfx-rs/wgpu/commit/efcf445784dd31537f09bc61bad27431de713fce
- PR: https://github.com/gfx-rs/wgpu/pull/10030
- Patch SHA-256: `a1c76783ee34725d6170ca4135a8aa78041272d25667418d748c08a4f1228456`

The patch contains the three official commit API file hunks, concatenated with
`--- a/<filename>` / `+++ b/<filename>` headers. It was independently retrieved
from the official GitHub commit API and matched the earlier isolated proof.
Applied with `patch --batch --no-backup-if-mismatch --fuzz=0 -p2`: observing.rs and snatch.rs require
line offsets only; no content edits or conflict resolutions were needed.
Changed files: `src/lock/observing.rs`, `src/lock/ranked.rs`, `src/snatch.rs`.

The fix tolerates already-destroyed diagnostic thread-local state during
shutdown. Actual synchronization remains intact. It retains recursive-lock
and lock-rank diagnostics while their TLS is available, and includes upstream's
`snatch::tests::read_during_tls_destruction` regression test. Do not replace it
with disabled debug assertions, queue initialization ordering, or leaked owners.

## Verification and reproduction

`python3 howl-backport/verify.py [path/to/wgpu-core-30.0.1.crate]` verifies the
exact published file set and every patched-file hash; the optional archive
also verifies the crates.io archive checksum and all pristine-file hashes.
`checksums.json` records published and patched SHA-256 values for all 86
published files. These records were generated only after verifying the archive
against the official sparse-index checksum and applying the exact upstream
patch. To reconstruct, extract the verified archive in a fresh directory and
apply `patch --batch --no-backup-if-mismatch --fuzz=0 -p2 < howl-backport/upstream-fix.patch` from the
extracted crate root. Keep proof downloads/builds outside this vendored tree.

Run upstream library tests with default features, then repeat with
`RUSTFLAGS="--cfg wgpu_validate_locks"`, then with `--features observe_locks`.
Use an isolated copy/target directory so Cargo does not modify the preserved
published crate lockfile. Host checks must additionally prove its resolved
`wgpu-core` is this path dependency, and exercise manual-WGPU shutdown.

## Backport qualification

On Home (Linux x86_64), the isolated published crate plus this exact patch
passed all 66 upstream library tests in each of four debug configurations:
default, `--cfg wgpu_validate_locks`, `--features observe_locks`, and observation
feature with `WGPU_CORE_LOCK_OBSERVE_DIR` enabled. The TLS-destruction regression
passed in all four. Fleet jobs exited 0 and drained; builds used two Cargo jobs
and bounded timeouts. This is library-test coverage, not a claim of cross-platform
GPU or host UI qualification. The host integration owns its additional gates.

## Removal gate

Remove the host `[patch.crates-io]` entry and this entire vendor directory when
a compatible published wgpu-core release contains this fix (or an equivalent
verified upstream correction), and the host lockfile resolves that release.
Before removal, run the TLS regression and lock tests, host tests/build and the
manual-WGPU live window/shutdown regression with debug assertions enabled.
A new version number alone is not evidence that the fix is present. Keep Slint
and WGPU compatibility explicit; do not silently upgrade unrelated dependencies.

The host's `.gitattributes` exempts end-of-line whitespace checks only for this
exact patch (blank unified-diff context lines) and the published
`src/timestamp_normalization/common.wgsl` (one pre-existing trailing space).
This preserves verified upstream bytes; owned source retains normal checks.
