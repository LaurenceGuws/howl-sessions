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

Enter an explicit `unix:/absolute/socket` or `tcp://NUMERIC_IPV4:PORT` endpoint,
Connect, then select a running terminal from the returned catalog. `HOWL_SERVER`
may prefill the field; it does not auto-connect. No sessions are silently created.
Each entry binds the observed Server incarnation, Session and Instance IDs.
Refresh re-reads the catalog and detaches the current view; select again explicitly.
Disconnect/closing the app does **not** close the remote Session or its child.
The app does not persist addresses, selection or credentials, or silently reconnect.

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
service; resuming requires an explicit connection and selection. Device lifecycle
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
- Full snapshots/CPU frames, 256 selectable running instances, 160×80 terminal
  grid and 4096-pixel sides (16 million pixels total) are current host bounds.
  Native framebuffer storage grows to actual frames rather than allocating the
  maximum on connection. This is not a performance claim.
- Graphics-image snapshots are explicitly unsupported by this Render integration;
  IME, full paste/mouse integration and automatic discovery are not implemented.

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
