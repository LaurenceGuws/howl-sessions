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

**Source shape:** Rust entry/lifecycle in `src/lib.rs`, connection ownership in
`src/sessions.rs`, and shared key/font configuration in `src/input.rs`.
`src/ui/app.slint` composes named components, one meaningful component per file.
Slint files import each other directly. `build.rs` uses `slint-build`;
Rust uses `include_modules!`. Avoid nested anonymous layout soup, speculative
managers and parallel representations of the same state.

## 2. Server first, no local Instance in this host

**Accepted:** the first product slice connects to the existing Howl Sessions
Server through published Client and Client Render interfaces. Server owns the
remote Instance and its child. Rust owns the host, not an alternative resident.
`cargo run` starts this path directly, with no preview/proof feature switches.
The earlier local-Bash adapter and fake catalog were removed, not maintained as
parallel architectures. Their history remains in Git.

Connections and catalog selection are explicit. Disconnect and mobile pause
release the attachment, not the remote Session. Reconnection is explicit and
selects current Server/Session/Instance identities; no hidden persistence claim.

**Deferred:** local Instance integration and raw SSH. They are distinct transports,
not names for the Sessions protocol. Raw SSH needs native channel/PTY request,
VT feeding, authentication and host-key ownership; it is not implemented here.

## 3. Bounded presentation and clear lifetime ownership

One worker exclusively enters Client/Render. Ordered keys use a bounded 64-entry
queue; frame, size and status use latest-value mailboxes. The UI releases the
mailbox lock before converting pixels. Shutdown cancels blocking work and joins
the worker before releasing its interrupt handle.

The C adapter paints canonical Render commands to CPU RGBA for Slint. Howl owns
shaping and terminal semantics. Current limits include 2048-pixel sides, 160×80
grid, full-frame copies and 16 ms polling. This is not a GPU/performance claim.
Input overflow is reported, not hidden with an unbounded queue. IME, full
paste/mouse integration and graphics-image presentation remain incomplete.

**Open:** scheduling, GPU presentation and simpler build integration should follow
measured needs and clear ownership, not add speculative framework machinery.

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
available in `src/input.rs`.

Canonical Howl supports four style slots and per-face fallback chains. The current
host exposes four primary faces, one shared fallback list and one pixel size.
Generated box/block/Braille/Powerline and other supported procedural glyphs belong
to Howl, not a fallback font pack.

**Android font decision:** use explicit system font files, not pretend
Fontconfig exists. DroidSansMono supplies regular, optional style slots are absent,
and available system Arabic/CJK/emoji files supply fallbacks. A visible limited-
coverage label distinguishes this from the desktop four-face configuration.
Preferred-face overrides remain available.

**Open:** a portable, licensed font bundle and broader Android font discovery. No universal
Unicode coverage promise. A compact unpatched mono family + separate Nerd symbols
is promising; CJK and emoji dominate size. Some old icon-finder entries use retired
Nerd codepoints. Glyph presence alone does not prove shaping/bidi quality.
Avoid copying large fallback font blobs separately into every face without a
memory plan. No new fonts have been bundled by this host.

## 6. Immutable dependencies; ABI numbers are not stability promises

`native/build.zig.zon` pins Client Render 0.1.2-dev.1 by exact Zig hash, which
brings its exact Client 0.1.8-dev dependency. Transitive owners pin VT/Text/Render.
There is no local Instance dependency. Cargo.lock records Rust resolution;
Slint build tooling and Lucide have explicit constraints. Use the tracked Zig.

Render's `hsr_create_family` accepts four explicit font faces without changing
the old constructor/layout. Callers require the release's symbol; reporting ABI
1 does not grant an old binary the new function. These are development package
releases, not a v1 stability declaration. Release manifests, headers and package
manifests are the authorities for exact contracts.

## 7. Home development; Note10 is a real Android canary

**Accepted:** edit on Home; use Note10's Debian chroot as a build machine and its
Android system as a deployment target. An Android app is not a desktop GUI running
inside the chroot. NativeActivity loads the Rust cdylib with the shared Slint UI.

Both desktop and Android use the same Server client path, with no local PTY.
The manifest targets SDK 35/minimum 28 and includes Internet permission.
The ARM64 native integration test and APK connect/render/background/re-attach
checks passed on Note10. The same remote shell survived activity pause and APK
replacement. Basic key input works; rapid injected input and full IME remain
unqualified. Android app network access must be enabled by the device owner.

The lean SDK/NDK/Rust packaging route currently lives in the Note10 workstream,
not yet a self-contained repository build recipe. No working mobile SSH claim
follows from building or running the Sessions app.

## 8. Evidence follows the boundary being changed

For host changes: fmt, clippy, CPU compositor tests and live Server attachment tests;
exercise real input, resize, output, cancellation and re-attachment.
Use isolated kwin-seat/headless previews for automation, never compete with
Captain's physical desktop. Captain can launch his own GUI.

Canonical Text tests, real Nerd-icon finder, procedural-glyph gallery and btop
have supplied useful desktop evidence, but not complete font/Unicode or Android
qualification. Package changes also require the repository Zig check/test/audit
gates and extracted-release checks. The four-face Render addition passed its
native/foreign tests and extracted-package checks before release.

Keep exact run logs and screenshots in the active workstream, not this decision
log. Passing tests do not turn provisional architecture into an accepted design.
