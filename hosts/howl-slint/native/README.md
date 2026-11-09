# Native boundary

`build.zig.zon` pins the published Client Render composition by exact hash.
It exports Client 0.1.9-dev and Client Render 0.1.4-dev as
`libhowl_sessions_native.so`, with the matching Client/Render/VT headers.
Transitive owners pin VT/Text/Render themselves. No local Instance or PTY is
linked into this host, and no sibling checkout is an implicit dependency.

Rust owns connection scheduling, input, UI mailboxes and cancellation.
`remote.c` keeps an observer (Client/Render and CPU surface) separate from its
action attachment. Each has one owner and an independent interrupt. Observation
blocks on the last delivery revision; action calls remain available while it
waits. Only actions acquire geometry leadership. `cpu.c` consumes
canonical Render commands; Howl still owns terminal semantics and text shaping.
A frame is painted while its lease is live, released, then pixels are borrowed
until the next call. Rust copies them before another native call. Client Render 0.1.4-dev leases its
existing atlas scratch for the single outstanding native frame rather than
allocating/copying atlas bytes a second time. Capture and destruction reject
an open frame lease; the public ABI and host borrow lifetime are unchanged. The optional Linux GPU consumer
copies typed canonical commands/atlas bytes through the same synchronous
`remote_visit` callback before lease release. It never retains native pointers. Disconnect
releases local resources, never closes the remote Session or kills its child.

`build.rs` invokes the pinned Zig composition and compiles the host's small C
adapter with Cargo `cc`. Linux uses system FreeType/HarfBuzz. Android ARM64 uses
Text's pinned bundled builds with an explicit NDK libc description via
`HOWL_ANDROID_LIBC`. The APK must contain both the Rust and Sessions shared
libraries. The current Linux run path uses the Cargo output directory as an
rpath; independent application packaging remains separate work.

## Tests

```sh
zig build -Doptimize=ReleaseSafe
zig build test test-cpu -Doptimize=ReleaseSafe
zig build test-live -Doptimize=ReleaseSafe -- \
  unix:/absolute/private-server.sock /absolute/regular-font.ttf
```

`test-cpu` exercises clipping, alpha/RGBA, malformed resources and bounds.
`test` forwards the published Client Render package's tests.
`test-live` creates and cleans up its own disposable Session on the given Server.
It tests parked observation, input wakeup, geometry, four-face capture, independent
cancellation, re-attachment and the actual host adapter. Only run against a Server authorized for that temporary
work. The four slots use one fixture font; style differentiation belongs to
Render's tests. `build-live` installs that executable for device tests.

Android builds use `-Dtarget=aarch64-linux-android.28 -Dbundled_text=true --libc
/path/to/ndk-libc.txt`. The ARM64 native integration test has passed on Note10
against a private Server through an SSH loopback forward. That evidence does not
replace APK UI and activity-lifecycle testing.

## Current presentation limits

CPU snapshots use a bounded 4096-pixel side, 16-million-pixel area and 512×192
terminal grid. Pixel storage grows to actual frame size and retains its high-water
allocation until close; opening a catalog does not allocate a framebuffer. CPU
painting uses zero atlas residency. The GPU observer passes its actual owned
CPU atlas residency, reconstructs complete immutable frames from cached and new
resources, and commits residency only after successful validation. Each resource
set is limited to 9 atlases/80 MiB. Cache, pending frame and construction can
retain different generations: their conservative combined ceiling is three such
sets, excluding native scratch and GPU textures. Shared unchanged generations
occupy one allocation; no historical cache or UI acknowledgement queue grows.
Graphics
images are explicitly unsupported. These constraints are not a GPU/performance
claim; they remain visible design work rather than alternate runtime modes.


`benchmark-workload -- ENDPOINT FONT_PATH SHELL_COMMAND [COLUMNS ROWS FONT_PIXELS]`
launches an explicit finite command in its own Session (default 128×40, 16px), starts it after the renderer is ready,
and samples the complete native adapter until child exit (15-second bound).
For example, use the installed `tui-zoo rain --fps 30 --duration-ms 4000 --seed 7
--cols 128 --rows 40 --synchronized-output`, or `cells` with `--dose 64`.
Redirect the workload's stderr to a chosen workstream receipt file to preserve
producer metrics separately. Samples follow Server delivery changes, which can
include non-content metadata changes; their count is not displayed FPS. The harness does not exercise
Slint upload, UI pacing or presentation and does not alter other Sessions.

The optional geometry is applied with actual font cell metrics before starting
the workload. Up to 4096 timestamped observation wall/CPU samples are retained
and printed after measurement, so stdout does not pace the client. Compare
identical grids, font files, physical rasters and producer receipts across routes.
These samples include waiting plus native rendering, not UI presentation.

### Observation encoding comparison

`zig build benchmark-observe -Doptimize=ReleaseSafe -- ENDPOINT FONT COMMAND packed|cached [COLS ROWS PIXELS]`
uses a disposable Session and test-only Client/ClientRender ABI composition with
our existing `cpu.c`. It does **not** add a transport-mode switch to the host.
The bounded 15-second run reports observation wall/thread CPU, canonical capture
CPU and CPU composition separately. Observation wall includes server waiting,
encoding, transport and client decoding; it is not network latency. Counts are
observations, not displayed frames. Samples are printed after measurement.

Use identical geometry/font/producer and alternate mode order. Example producers
(the command executes on the Server machine):

- Sparse: `tui-zoo cells --fps 60 --duration-ms 6000 --seed 7 --cols 128 --rows 40 --dose 1 --synchronized-output`
- More rows touched: the same command with `--dose 64` or `--dose 512`. Dose counts random writes, not full-screen redraws.
- Scrolling: `python3 /path/to/native/test/scroll.py` (fixed 360 lines/6 seconds).

Keep producer stderr receipts separately from client timing. Quiescent post-exit
checks compare packed/cached cells and scalars, snapshot lifetime after cache
release, foreign-attachment rejection, fresh-attachment cache and cancellation.
TUI workloads may restore an empty primary screen, so those checks do not prove
live-frame parity. For nonempty pixel parity, run a finite `printf` fixture with
Unicode, wide/combining text, colors and styles, and `\033[?25l` to hide the cursor.
When hidden, two independently initialized canonical renderers must yield exactly
equal RGBA pixels. Visible cursor age is deliberately excluded from that claim.

The composition also exports `hsc_observe_cached_compressed` for peers that
explicitly support the new request. The host still uses packed observations;
pinning this additive release does not switch its wire mode or upgrade a Server.

## iOS linkage

The experimental iOS target builds the same published composition as a relocatable
object, forwarding its exact headers through Zig's installLibraryHeaders. Cargo
archives that complete object with the C adapter. Unlike a plain static archive,
the relocatable link includes the bundled FT/HB objects. It
does not reimplement the native ABI or alter a downloaded dependency. The
`build-static -Dbundled_text=true` path can also be exercised on Linux.
macOS/Xcode supplies the iPhoneOS sysroot and C/C++ headers; Linux headers are
not an iOS SDK. Apple-target compilation and device behavior remain separate
qualification gates. The small ARC `ios.m` bridge uses only public Foundation,
UIKit and CoreText APIs for sandbox paths, font discovery and lifecycle events.
