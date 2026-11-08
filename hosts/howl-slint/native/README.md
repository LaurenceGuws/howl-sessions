# Native boundary

This directory selects published ABI compositions, not sibling checkouts.
`build.zig.zon` is the pin authority. Transitive owners pin their own dependencies;
do not add a second independent version of VT/Text/Render here.

| Profile | Installed artifact | Ownership |
| --- | --- | --- |
| `local` (default) | Instance + companion VT static libraries and headers | Local PTY, VT, presentation |
| `sessions` | `libhowl_sessions_native.so` and matching Client/Render/VT headers | Remote Sessions client and local presentation, no local PTY |

The Sessions composition includes Client 0.1.8-dev and Client Render 0.1.2-dev.
Both profiles resolve VT 0.1.7-dev, Text 0.1.6-dev and Render 0.1.10-dev to the
same exact published hashes. Only local Instance also needs PTY 0.1.6-dev.
The Sessions dependency is lazy: normal local builds do not fetch/build it.

```sh
zig build -Doptimize=ReleaseSafe
zig build -Dprofile=sessions -Doptimize=ReleaseSafe
zig build test -Dprofile=sessions -Doptimize=ReleaseSafe
```

These install into the same default `zig-out` unless `--prefix` is supplied;
use separate prefixes when comparing profiles. This qualifies the remote ABI,
not an implemented remote Slint UI. There is no raw-SSH profile yet: raw SSH
needs a channel/VT owner, not the Sessions protocol or a local Instance.

## Current local adapter

`terminal.c` is private to this host. Its `proof_*` functions are not a released
Howl ABI. Rust owns the worker, input queue, UI mailbox and shutdown request.
The adapter owns Instance/frame handles and the CPU pixel buffer. Howl owns
PTY/VT semantics, text shaping and canonical render commands.

The adapter borrows strings only during construction. It acquires each frame,
consumes commands/uploads while the lease is live, releases it, then lends CPU
pixels to Rust until the next call. Rust copies those pixels before calling
again. Zero-residency release deliberately trades atlas reuse for a complete,
independent CPU frame. No native handle or borrowed image reaches the UI thread.

Teardown closes the only frame endpoint before destroying Instance. The pinned
frame-close implementation abandons any outstanding lease. `HI_BUSY` on destroy
means a publication borrow remains; this exclusive-owner design should not have
one after close. The current Drop path only reports an unexpected failure; it is
not a general retry/recovery policy for future shared owners.

## Before promoting the proof

- Separate host launch/font/budget policy from the CPU compositor without
  duplicating canonical terminal or rendering behavior. Current launch is Bash,
  its environment is explicit, and the configured limits are proof limits.
- Consider compiling this C adapter in the existing Zig build rather than a
  second Cargo `cc` stage. This is build simplification, not an ABI redesign.
- Add isolated compositor tests for clipping, alpha/RGBA, malformed resources
  and limits. The current real-terminal lifecycle test is not that coverage.
- Decide presentation (CPU versus GPU) before publishing a generic pixel ABI.
- Keep shutdown ownership explicit if multiple frame consumers are introduced.
  Do not turn an unexpected borrow into an infinite retry loop.

The current Linux-only Cargo feature remains `terminal-proof`; Android builds
only the UI shell. No claim of cross-platform native qualification follows from
compiling the shell or the remote ABI on Linux.
