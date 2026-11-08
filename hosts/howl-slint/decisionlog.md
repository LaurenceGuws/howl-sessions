# Howl Slint decisions

Recorded 8 November 2026. This is the host's current rationale, not a transcript
or qualification checklist. Update an entry when its decision changes; keep
historical detail in Git. The [product decision log](../../decisionlog.md) and
[repository contract](../../AGENTS.md) still govern ownership.

## 1. A small host, not a new terminal engine

**Accepted direction:** explore Slint/Rust as a lighter, shared desktop/mobile
host. Keep Flutter untouched while proving the alternative. Do not claim feature
parity or a completed replacement.

Howl owns VT, PTY, Text, Render and Instance. Howl Sessions owns Sessions/Server
orchestration. This host owns presentation, input integration, scheduling,
configuration and application lifecycle. Reuse the modules and their foreign
interfaces rather than porting their semantics into Rust.

**Source shape:** Rust entry/lifecycle in `src/lib.rs`, preview state in
`src/state.rs`, and the real terminal owner in `src/terminal.rs`.
`src/ui/app.slint` composes named components, one meaningful component per file.
Slint files import each other directly. `build.rs` uses `slint-build`;
Rust uses `include_modules!`. Avoid nested anonymous layout soup, speculative
managers and parallel representations of the same state.

## 2. Three connections, not three names for one transport

- **Local:** a presented Howl Instance owns the local PTY/VT and rendering.
  No Server or Session is needed. This is the implemented Linux proof.
- **Remote Howl Sessions:** Client attaches to the existing Server; Server owns
  the remote Instance. Client Render presents its observations locally. Do not
  invent another server or add a redundant local Instance. This host has not
  wired this path yet.
- **Raw SSH:** especially important on mobile. A native SSH channel requests a
  *remote* PTY; its bytes feed Howl VT, encoded input/replies go back through SSH,
  and resize updates both VT and the remote channel. This need not launch a local
  `ssh` process or require a local PTY. It is not the Sessions wire protocol.

**Open:** choose and qualify the native SSH transport and its ownership boundary.
Current Instance owns a local PTY and is not a pluggable SSH transport.
Russh is a candidate, not an adopted dependency. Host-key verification,
authentication, cancellation, reconnect and mobile background lifecycle still
need design. Desktop Instance + system `ssh` is a possible local convenience,
not the mobile solution.

## 3. One real terminal first; bounded CPU presentation is provisional

The opt-in `terminal-proof` feature runs one real local Bash terminal.
`native/terminal.c` adapts the published Instance C ABI and composites canonical
Render commands into RGBA for Slint. It is a bounded presentation proof, not a
second shaping/terminal engine and not a GPU/performance claim.

One worker exclusively enters Howl. Ordered keys use a bounded 64-entry queue;
frame, size and status use latest-value mailboxes. The UI takes shared state,
releases the lock, then converts pixels. Shutdown joins the worker and tears down
its native owner. Preserve explicit lifetime, bounds and failure ownership as
the integration evolves.

Current limits include 2048-pixel sides, a 160×80 grid, full CPU frame copies and
16 ms service/UI polling. Fast synthetic typing can fill the key queue and reports
rejection; do not disguise that by making it unbounded. IME, full paste/mouse
integration, multiple real sessions and production scheduling are not qualified.
The default build remains an honestly labelled layout preview.

**Open:** simplify the Rust/C/Zig build boundary and replace CPU presentation when
evidence justifies it. Neither an extra framework nor an engine rewrite follows
automatically from this proof.

## 4. Compact, coherent UI; layout should carry the sizing

**Accepted:** a cozy terminal-first surface, restrained contrast, readable
hierarchy, content/layout sizing and shared style defaults. Avoid fat controls
and arbitrary fixed widget dimensions. Legitimate strokes, spacing, minimums and
preferred window size remain explicit; “no hard-coded sizes” is not a ban on
design values.

`src/ui/style.slint` owns palette, font settings, spacing, padding and radii.
No duplicate Rust style initializer. Sidebar rows, top controls and the active
tab share a visual language without pretending to have identical roles.
Hover/selected/focus states should communicate actual behavior; the current-tab
marker is not a fake action button.

The sidebar owns its header/list; terminal tabs belong to the terminal pane.
Shared header insets keep controls consistent when the sidebar is hidden.
The resize hit area straddles the visible divider. Dragging below the minimum
can hide the sidebar; reversing while still pressed restores it. Releasing ends
the gesture. Portrait uses one pane; safe-area insets protect mobile content.

Icons come through pinned `lucide-slint`, not hand-maintained copied SVGs;
`licenses/Lucide.txt` retains its notice. Shell/application icon-set exploration
is deferred and its temporary comparison UI was removed. The wolf design canary
under `design/` is exploratory, not an accepted product mark.

## 5. Terminal font precision is separate from UI fonts

Slint platform fonts serve UI text. They do not provide fallback for a Howl
terminal displayed as an image.

**Current desktop policy:** style.slint explicitly selects regular, italic, bold
and bold-italic terminal faces, with Arabic/CJK/emoji fallbacks. Defaults match
Captain's saved howl-app preferences: Iosevka Nerd Font, four styles, 18 px.
UI family/size remain Slint platform defaults. Native font discovery accepts
existing files or verifies Fontconfig family/style matches; missing named faces
must not silently turn into substitutes. Explicit HOWL_* font overrides remain
available in `src/terminal.rs`.

Canonical Howl supports four style slots and per-face fallback chains. The current
host exposes four primary faces, one shared fallback list and one pixel size.
Generated box/block/Braille/Powerline and other supported procedural glyphs belong
to Howl, not a fallback font pack.

**Open:** a portable, licensed font bundle and Android discovery. No universal
Unicode coverage promise. A compact unpatched mono family + separate Nerd symbols
is promising; CJK and emoji dominate size. Some old icon-finder entries use retired
Nerd codepoints. Glyph presence alone does not prove shaping/bidi quality.
Avoid copying large fallback font blobs separately into every face without a
memory plan. No new fonts have been bundled by this host.

## 6. Immutable dependencies; ABI numbers are not stability promises

`native/build.zig.zon` pins the published Instance 0.1.8-dev.1 archive by exact
Zig hash. Do not replace it with an implicit sibling-checkout dependency.
Cargo.lock records Rust resolution; Slint build tooling and Lucide have explicit
version constraints in Cargo.toml. Use the tracked Zig version.

Relevant Sessions releases are Client 0.1.8-dev.1 and Client Render 0.1.2-dev.1.
Render now adds `hsr_create_family` for four explicit font faces without changing
the old constructor/layout. New callers require that release's symbol; an old
binary does not gain it merely because both report ABI 1. These are development
package releases, not a v1 stability declaration.

The local Slint proof consumes Instance, not Client Render. The native build
now has an explicit lazy `sessions` profile pinned to Client Render 0.1.2-dev.1
for remote ABI qualification; this does not wire remote sessions into the UI. Release manifests, package manifests and
headers are the authorities for exact hashes and contracts, not this log.

## 7. Home development; Note10 is a real Android canary

**Accepted:** edit on Home; use Note10's Debian chroot as a build machine and its
Android system as a deployment target. An Android app is not a desktop GUI running
inside the chroot. NativeActivity loads the Rust cdylib with the shared Slint UI.

Android support currently covers the UI shell, not the local terminal feature.
The debug manifest targets SDK 35/minimum 28 and has no Internet permission yet.
The Linux terminal proof explicitly rejects Android and cross-compilation rather
than silently producing the wrong native library.

The lean Note10 SDK/NDK/Rust packaging route lives in its android-native-canary
workstream; it is not yet a self-contained repository build recipe. A shell APK
has been built, signed and run. Subsequent cleanup was rebuilt and signature
verified, not reinstalled/launched. This is not evidence of working mobile SSH.

## 8. Evidence follows the boundary being changed

For host changes: fmt, clippy and tests for the default and terminal-proof builds;
exercise real terminal input, resize, output and teardown when touching that path.
Use isolated kwin-seat/headless previews for automation, never compete with
Captain's physical desktop. Captain can launch his own GUI.

Canonical Text tests, real Nerd-icon finder, procedural-glyph gallery and btop
have supplied useful desktop evidence, but not complete font/Unicode or Android
qualification. Package changes also require the repository Zig check/test/audit
gates and extracted-release checks. The four-face Render addition passed its
native/foreign tests and extracted-package checks before release.

Keep exact run logs and screenshots in the active workstream, not this decision
log. Passing tests do not turn provisional architecture into an accepted design.
