# Howl Slint

Small desktop/Android host over the published Howl module interfaces.
See [decisionlog.md](decisionlog.md) for rationale and open decisions.

```sh
cargo run
```

The app connects to an existing Howl Sessions Server; it never launches a local
PTY. Native builds require the tracked Zig and desktop FreeType/HarfBuzz.
[native/README.md](native/README.md) describes the pinned Client/Render ABI and
its test commands.

## Server connection

Add named servers from the sidebar using `unix:/absolute/socket` or
`tcp://NUMERIC_IPV4:PORT`. Editing uses one app-level form above the software
keyboard. Each visible server shows its running sessions;
selecting a session attaches the single terminal viewport. Refresh updates only
that server's catalog. Hidden servers are not queried. Editing, hiding or removing
a saved server does not redirect or terminate the current terminal.

Profiles, visibility and an optional terminal font-size override are saved in
`$XDG_CONFIG_HOME/howl-sessions/settings.json` (or `~/.config/howl-sessions/`)
on desktop, and Android's app-private data directory on mobile. No credentials,
active selection or live connection are persisted. Showing a server discovers its
catalog; attaching a terminal always requires selection. No sessions are created.
Each entry binds exact Server incarnation, Session and Instance IDs.

The sidebar can be hidden with its header control and restored from the tab bar.
Pinching the terminal previews its scale, then commits a crisp font size when the
gesture ends. The logical size is bounded to 8–48 pixels; the theme owns the
unsaved default. Saving failures are reported rather than silently discarded.

Use a trusted Unix socket or an independently secured tunnel/network. The native
TCP protocol does not add TLS or authentication. A Server incarnation ID prevents
stale identity reuse; it is not authentication. Do not expose an unauthenticated
Server to an untrusted network.

The command owner handles input and geometry on one attachment; the observer
owns a separate attachment and renderer, sleeping until the Server changes.
Only the command attachment acquires resize leadership. Input is bounded; frame
and resize mailboxes keep the newest value. Coalesced events wake the UI without
a polling timer. Mobile owns no local PTY. Android
Pause/Stop/Destroy requests detach rather than running an invisible terminal
service; resuming requires explicit session selection. Device lifecycle
was exercised on Note10: Home/background detaches; explicit reconnect and selection
returns to the same remote shell.

## Current limits

- Linux desktop Server attach/input/resize/render/disconnect/re-attach has been
  exercised against a real private Server.
- The Android ARM64 native Client/Render canary has run on Note10 and demonstrated
  remote-child survival across detach/cancel/re-attach. The APK also connected, rendered the remote shell, accepted basic key input and
  reattached after background/resume. Rapid injected typing was unreliable; full
  IME/touch typing is not qualified.
- Android defaults explicitly use DroidSansMono and available system
  Arabic/CJK/emoji files. Missing italic/bold slots use canonical style fallback.
  The UI labels limited coverage; these are not Nerd Fonts or desktop-equivalent
  four-face fidelity. Explicit preferred-face overrides remain available. Portable
  font packaging is still open. Slint platform fonts independently serve UI text.
- Packed snapshots, CPU-default frames, 256 selectable running instances, 160×80 terminal
  grid and 4096-pixel sides (16 million pixels total) are current host bounds.
  Native framebuffer storage grows to actual frames rather than allocating the
  maximum on connection. This is not a performance claim.
- Graphics-image snapshots are explicitly unsupported by this Render integration;
  IME, full paste/mouse integration and network auto-discovery are not implemented.

## Performance checks

The development profile uses optimization level 2 for the host and UI dependencies
(including the C compositor), while retaining debug information and assertions.
The first build costs more than an unoptimized dependency build; subsequent
host edits reuse those dependencies. The frame worker
copies the native pixel borrow once into a Slint shared pixel buffer; the UI
moves that buffer into its image rather than allocating/copying it again.

`cargo test frame_handoff_cost -- --ignored --nocapture` isolates buffer handoff
cost. Native live/workload benchmarks are documented in `native/README.md`.
Neither producer cadence nor native step throughput is displayed FPS. Remaining
cost includes full snapshot transport, canonical rendering, image upload and
Slint presentation; no GPU or terminal-semantic shortcut is implied.

## Optional Linux GPU presentation

Home's Linux WGPU path is available explicitly:

```sh
HOWL_GPU=1 cargo run --locked --features gpu
```

Without `HOWL_GPU=1`, the same build uses the existing CPU frame path. Ordinary
`cargo run --locked` also remains CPU-only. GPU initialization errors are reported;
restart with `HOWL_GPU=0` to use CPU frames. This does not change the Server wire
mode, terminal semantics, fonts, settings or saved connections. Android keeps the
CPU path; no mobile GPU or suspend/resume qualification is implied.

The observer copies typed canonical commands and complete atlas uploads while
the native frame lease is alive. Only UI callbacks compose images, on the same
explicit WGPU Device/Queue supplied to Slint. One pending frame and two output
textures bound retention. The currently published image is never rewritten.
Slint scene encoding, property replacement and our submissions serialize on the
UI thread; all GPU sampling and writes serialize on the same queue. Completion
flags bound composition backlog, **not** Slint sampling or physical presentation.
Do not retain these textures in another view or use another queue/encoder thread.
No rendering notifier or thread-local initialization workaround is installed.

Slint is pinned to 1.18.1 for its unstable WGPU 30 interface. The temporary
[wgpu-core backport](vendor/wgpu-core/howl-backport/README.md) contains only the
verified upstream TLS-destruction fix over published 30.0.1, with exact provenance,
checksums, verification script and removal gate. Debug assertions stay enabled.

A presentation error stops the attachment and requires a host restart; the Server
session and child survive. A lost shared device also breaks Slint rendering, so
CPU pixels cannot repair it. Automatic device recreation, actual driver loss and
suspend/resume remain unqualified.

Additional checks (run GPU/window tests under an isolated `kwin-seat`, never on
Captain's physical desktop):

```sh
cargo test --locked --features gpu
cargo clippy --locked --features gpu --all-targets -- -D warnings
cargo run --locked --features gpu --example queue_tls
# In a private compositor:
HOWL_GPU=1 cargo test --locked --features gpu gpu::tests::window_parity_and_reuse -- --exact --ignored --nocapture
HOWL_GPU=1 cargo test --locked --features gpu gpu::tests::cancelled_frames_and_presentation_failure -- --exact --ignored --nocapture
```

The ignored `sessions::tests::live_presentation` takes `HOWL_TEST_ENDPOINT` for a
disposable Server containing exactly one workload gated on Enter, plus an absolute
`HOWL_TEST_STARTED` marker path. It measures host CPU over seven seconds in the
actual App; it is not a displayed-FPS or input-to-display-latency benchmark.
