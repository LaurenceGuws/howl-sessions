# Native boundary

`build.zig.zon` pins the published Client Render composition by exact hash.
It exports Client 0.1.8-dev and Client Render 0.1.2-dev as
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
until the next call. Rust copies them before another native call. Disconnect
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

CPU snapshots use a bounded 2048-pixel side and 160×80 terminal grid. Zero atlas
residency gives each frame complete resources, at the cost of reuse. Graphics
images are explicitly unsupported. These constraints are not a GPU/performance
claim; they remain visible design work rather than alternate runtime modes.


`benchmark-workload -- ENDPOINT FONT_PATH SHELL_COMMAND` launches an explicit
finite command in its own 128×40 Session, starts it after the renderer is ready,
and samples the complete native adapter until child exit (15-second bound).
For example, use the installed `tui-zoo rain --fps 30 --duration-ms 4000 --seed 7
--cols 128 --rows 40 --synchronized-output`, or `cells` with `--dose 64`.
Redirect the workload's stderr to a chosen workstream receipt file to preserve
producer metrics separately. Samples follow Server delivery changes, which can
include non-content metadata changes; their count is not displayed FPS. The harness does not exercise
Slint upload, UI pacing or presentation and does not alter other Sessions.
