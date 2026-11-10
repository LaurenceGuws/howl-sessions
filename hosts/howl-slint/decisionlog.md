# Howl Slint decisions

Updated 9 November 2026. This is the host's current rationale, not a transcript
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

A command owner handles input/resize while a separate observer waits for the next
Server delivery revision. Each connection has exactly one I/O owner. Only the
command attachment acquires geometry leadership. The published Client ABI has
blocking observations, not resumable I/O; blocking the command owner would stall
keys. Two sleeping owners avoid changing the protocol just to fit this host.

Ordered keys use a bounded 64-entry queue. Coalesced resize/ready facts wake the
command owner; latest-value UI updates schedule at most one pending callback.
Selection cancels and joins its old observer before clearing/replacing its frame.
Disconnect first invalidates queued UI work and cancels both I/O lanes, then joins
owners before releasing their interrupt handles. There is no periodic host timer.

The C adapter paints canonical Render commands to CPU RGBA for Slint. Howl owns
shaping and terminal semantics. Current limits include 4096-pixel sides, 16 million pixels and a 160×80
grid. Observations use the last Server delivery revision, not Render's narrower
content revision. Current Render is untimed: timed cursor blinking remains an
explicit future presentation contract, not something this host silently disables.
Rendered images are compared byte-for-byte before
copying/publishing them to Slint. Retain the last shared buffer, not another pixel
copy. Content revision alone is insufficient: cursor commands can change without
new PTY output. This avoids redundant image uploads, not full snapshot/render work.
This is not a GPU/performance claim.
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

`native/build.zig.zon` pins Client Render release 0.1.4-dev.1 by exact Zig hash, which
brings its exact Client 0.1.9-dev.1 release dependency. Transitive owners pin VT/Text/Render.
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

### Performance and fidelity policy

Keep debug assertions and symbols while optimizing the entire development frame
path, including Slint dependencies. Canonical CPU paint optimizations remain
covered by exact-byte and unaligned-buffer tests. Do not retain a cache unless
its measured gain pays for ownership/invalidation complexity.

UI font preferences are logical lengths; terminal viewport, raster size and
framebuffer are physical pixels. DPI changes recreate only the observer/font
owner, preserving command ownership and the remote shell. The first observation
waits for acknowledged geometry; cancellation wakes that wait. Allocation grows
to actual frames within 4096-pixel sides and 64 MiB RGBA. Fidelity costs real
composition/upload work on high-density screens.

Home 2× and Android 3.5× attach/input/resize/reconnect were exercised. A small
Note10-local workload sustained approximately 60 Hz; larger grids exceeded the
budget. Networked observations also had long tails absent from local controls.
Neither result identifies a Wi-Fi defect or guarantees universal 60 Hz. Live
cross-monitor DPI, orientation and complete mobile lifecycle remain separate
qualification. Preserve exact workload, grid, pixels, fonts, build and route when
comparing; producer rate, observation rate, rendering callbacks and physical
presentation are different measurements.

### Current wire contract and compressed-delta decision

**Integrated:** bounded additive compressed deltas are published in Protocol
0.1.2-dev.1, Client 0.1.9-dev.1 and Client Render 0.1.3-dev.1 releases; this host
pins that cohort. **The host still uses packed observations.** Existing live
Servers were not upgraded. A new symbol/package does not negotiate an old peer's
wire support; changing the default requires an explicit compatible-peer contract.

Workstream-only host tests compared packed/compressed on Unix and TCP loopback.
Both already sustained approximately 60 rendering callbacks/s at the measured
grid. Compression helps wire/Server work, especially sparse updates; it is not
a demonstrated local FPS gain and does not remove CPU composition/full-image
upload. The matched howl-app comparison still showed substantially lower CPU
there; no performance-parity claim is accepted.

### Optional Linux GPU presentation with a narrow upstream backport

**Integrated:** the private synchronous `remote_visit` foundation now also feeds
an opt-in typed command/atlas owner and Linux WGPU painter. The ordinary build and
runtime remain CPU-default. `HOWL_GPU=1 cargo run --locked --features gpu` selects
the qualified Home path; unset it or use `HOWL_GPU=0` for CPU presentation. The
Server wire mode, canonical terminal/font owners, settings and Android path stay
unchanged. A native frame is copied while its lease lives, then released before
publication; no pointer or renderer lease crosses to the UI.

The rejected notifier implementation remains out of product code. One explicit
Manual Device/Queue is shared with Slint 1.18.1, without a rendering notifier or
host thread-local owner. Only the UI submits composition or changes the terminal
image. One latest pending frame, two alternating output textures and bounded
atlas/command storage preserve the established resource limits. The current
image is never rewritten. Single-threaded UI encoding and the same Queue order
old Slint sampling before later writes. Composition completion only bounds our
backlog; it is not a Slint sampling or physical-presentation fence. Do not extend
this ownership model to another view, encoder thread or queue.

WGPU 30.0.1's debug TLS shutdown crash is independently reproducible without Slint.
The product vendors only `wgpu-core` 30.0.1 with the exact three-file official fix
`efcf445784dd31537f09bc61bad27431de713fce` (PR 10030). Published bytes/checksum,
upstream patch, retained licenses, verifier and removal gate live in
`vendor/wgpu-core/howl-backport/`. No registry mutation, disabled assertions,
leaked owner or initialization-order workaround is used. No fixed published
30.x release was verified. Remove this backport only after verifying a compatible
published replacement and rerunning shutdown, lock and host gates.

Qualification on Home: all 66 upstream library tests pass in default, ranked,
observing and recording-enabled lock configurations. Host unit/default-feature
checks, clippy, CPU/native live tests and repository test/check/audit gates pass.
Twenty-four exact real Slint-window snapshots cover alpha, clipping, command
order, atlas generations, coalescing and resizing. Cancellation and presentation
failure clear pending frames and disable the attachment. Independent queue TLS
shutdown and eight full App runs exit normally with assertions enabled.

These historical CPU-image runs also initialized Manual WGPU; they compare
composition within that backend, not production CPU-default startup.
At the matched 1024×900 window / 128×42 terminal / 16px font, sparse host CPU was
0.52s versus CPU presentation's 1.02–1.09s; dense was 0.90–0.91s versus 1.66–1.67s,
measured over approximately seven seconds. Every six-second producer completed
360 frames with no skipped slots. These are host CPU savings, not physical FPS,
latency, GPU timestamp, memory improvement or howl-app parity claims. Exact
source, flags, logs and receipts remain in Home's active workstream under
`frame-timing/wgpu-proof/product-integration/` and `product-backport/`.

Presentation failure disconnects the local attachment and requires restart;
the Server session/child remains independent. Device loss also invalidates Slint's
shared rendering device, so supplying CPU pixels is not recovery. Automatic
recreation, actual driver/device loss, suspend/resume and mobile GPU support are
not qualified. iPhone and heavy Note10 builds were not part of this change.

### Mobile qualification boundary

A later compressed-Client build exhausted Note10 memory and restarted Android's
framework. That ARM qualification did not pass. Recovery was checked, but app,
Server and relay restoration was not assumed. Do not run further heavy phone
builds without a new resource plan; Home evidence does not fill the missing gate.

Slint supports Rust iOS hosts, but this host currently rejects iOS in build.rs.
Apple SDK/packaging, composed native linkage, font lookup, sandbox storage and
lifecycle/input qualification are still required. Start the iPhone route with the
existing remote ABI and CPU image presenter, not a phone PTY or unproved Metal
import. A Mac/Xcode build and actual simulator/device evidence are prerequisites;
Android success is not iOS support. No iPhone build or deployment has occurred.

## Saved servers and one active terminal

Server navigation belongs in the sidebar, not above the terminal. Configuration
opens one app-level centered form, constrained by the reported software-keyboard
rectangle. It does not compete with the narrow sidebar or hide behind the IME.
Note10 landscape qualification covered both focused fields and visible actions,
Cancel/Save keyboard dismissal and unchanged profile preservation. Portrait
keyboard layout has not yet been exercised.
Named profiles have stable local IDs, explicit visibility and independent bounded
catalog discovery. At most 16 profiles are saved. Discovery is cancellable and
runs when a profile is shown, its endpoint changes, or refresh is requested;
there is no background polling. Catalog results carry a generation so late
responses cannot restore removed or changed entries.

The single active terminal owns an immutable endpoint and exact remote
Server/Session/Instance identity. Hiding, editing or removing a profile changes
catalog visibility/configuration only; it never redirects that connection or
stops a remote job. Selecting another session or the tab's Detach action ends
only the attachment. Catalog failures are independent of the active terminal.

Profiles/visibility and an optional font-size override are private local settings,
not credentials or saved live connections. The theme remains the default font
source. Writes are bounded, validated and atomically replaced; malformed existing
files are not silently overwritten. Desktop uses XDG config, Android its private
application data directory. The former unsaved HOWL_SERVER field shortcut is
removed with that field; saved profiles are the configuration surface.

Pinch previews a clipped scaled frame while fingers move, then commits a bounded
logical font size on release so Howl re-rasterizes sharply. Cancellation restores
the prior view. This avoids rebuilding the font owner on every pointer update.
Actual multi-touch acceptance remains a device check, distinct from compiling
Slint's documented touchscreen gesture handler.

Qualified with two real Server instances through App callbacks: exact selection
and rendering, stale-incarnation refusal, independent failed catalogs, and
hide/edit/remove preserving the active owner through a subsequent resize/frame.
The reproducible live test is explicitly ignored by ordinary unit runs and uses
caller-provided isolated fixtures. Android subsequently saved a profile through the real form, reloaded it after
force-stop/relaunch, rendered the retained remote shell and hid/restored the
sidebar. Real pinch acceptance remains pending a finger check; synthetic
single-pointer input does not establish multi-touch support.

### Exclusive native atlas lease

Client Render 0.1.4-dev.1 removes the second per-frame allocation/copy of
canonical atlas pixels. Its existing single-frame admission rule prevents
capture or destruction until release, so the frame exclusively leases the
renderer pixel scratch. Cell-size queries are immutable. Snapshot ownership,
canonical record layouts and the public frame lifetime remain unchanged. The
Slint GPU worker still copies frame data before crossing to the UI; this change
does not introduce shared native pointers or backend residency assumptions.
Root test/check/audit, extracted-release and native-consumer tests passed.
The matched runtime results below qualify the combined host changes.

### Bounded GPU observer residency

The GPU observer retains actual immutable CPU atlas bytes and supplies their
exact canonical resource/generation/format/extent as residency. It applies new
uploads and removals transactionally, validates every command against the
complete resulting set, and only then commits residency. Each UI frame owns
shared references to every required atlas, so dropping intermediate frames
cannot lose a required upload. Font/DPI observer replacement creates a fresh
namespace/cache. Cancellation can drop the cache while pending frames remain
valid until discarded. No native pointers cross threads.

Resource sets retain the existing 9-atlas/80-MiB bound; cache, pending and
construction have a conservative aggregate ceiling of three sets, plus native
scratch/GPU storage. The GPU owner retains fingerprints, not CPU atlas copies.
Fingerprinting happens once at immutable upload construction, avoiding repeated
full-byte hashing during presentation. CPU presentation remains uncached.
Unit coverage includes dropped delivery, cancellation, resize, namespace reset,
generation/extent/format replacement, failed validation preserving residency,
removals and resource bounds. Exact real-window parity and presentation-failure
tests passed on Home. The matched runtime results below cover this change.


### Matched Home runtime qualification, 9 November 2026

The live test now follows production startup, initializing Manual WGPU only
when GPU mode is enabled. Private KWin, Iosevka 16px, the same 128×42 grid and
1024×840 terminal pixels, and six-second/360-frame 60Hz Cells workloads were
used for every host. Slint includes its tab bar in a 1024×900 window; howl-app
hides its bar in 1024×840. Startup is excluded; process CPU samples span about
5.9 active seconds. Two GPU pairs reverse execution order.

GPU host CPU fell from 0.72–0.73s to 0.53–0.57s for sparse dose 1, and from
1.03–1.05s to 0.86–0.87s for dense dose 512: about 24% and 17% less. CPU-image
presentation measured 0.95s/1.66s versus 0.95s/1.72s before; no broad CPU-default
speedup is claimed. Explicitly built howl-app ReleaseSafe remains faster at
0.21–0.22s/0.45s. Slint's separate Server adds about 0.14s/0.49s; local and remote
product ownership is not identical.

Connected idle GPU RSS fell from about 422 to 289 MiB; running btop fell from
429 to 298 MiB, excluding both Server and btop. The principal change removes
unused LLVM/Gallium/EGL mappings by selecting Vulkan only, with no device/vendor
hardcoding. It is not 130 MiB of private-heap savings: post-change btop host
private memory was about 90 MiB; PSS varies with concurrent sharing. Disconnected
GPU VRAM stayed about 32 MiB. SDL/OpenGL also loads extra drivers in private
KWin; an explicit SDL/Vulkan control used less RSS but more CPU, so howl-app's
renderer default was not changed.

All producers completed 360 frames without skipped slots. GPU composition
counts remained 362–364 with no busy skips. These are not physical displayed
FPS, input-to-display latency or GPU timestamps. Dota ran concurrently. No
mobile GPU or suspend/resume qualification is implied. Exact receipts, process
samples and command fixtures are in Home's active workstream under
`horse-race-20261109/`. Production binaries require restart to use the changes.

The follow-up Android native-only cross-build on Brommer did not qualify this
checkpoint on Note10. Exact Zig 0.17.0 and NDK r28c exposed a compiler integration
fault: the driver forwards the Android target after the internal translate-c
wrapper's `--`, but the wrapper selects native header paths using only the
target parsed before that separator. This admits host glibc limits.h alongside
Bionic headers. Explicit ZIG_LIBC/sysroot retries reproduced the failure;
bundled-text forwarding was correct and pinned dependencies were not edited.
After a translation-only Fortify suppression removed separate Bionic wrapper
errors, adding the missing wrapper target to the captured child invocation
passed translation. Restoring production Fortify with that target correction
still fails seven Bionic wrapper translations, with no host glibc errors.
That isolates two defects, not a complete production Android fix. The installed
binary and relevant translator sources match the cached declared release
archive, ruling out post-install mixing of those components. The diagnostic
invocation is not a supported build route: the
public TranslateC build API cannot express it, and the outer CLI rejects the
wrapper's target option. The fix belongs to the compiler integration/pin, not
to a Text header shim or a modified dependency cache.

Brommer attempts stayed within 2 CPUs/4 GiB (2.02 GiB observed peak) and were
stopped. Note10's private Server start/stop passed at that checkpoint, but the
new native canary had not yet run. No Android APK deployment, UI or system-setting
changes occurred. Home results do not fill the Android qualification gate.

## Initial iOS build lane (2026-11-09)

Captain asked to build the Slint application for the connected iPhone and iterate.
Home's existing `ios doctor` passed Wi-Fi pairing, Developer Mode, Apple trust
and provisioning services. A Linux ARM64 iOS cross-build failed on missing Apple
SDK headers, so the build lane uses GitHub macOS/Xcode and leaves signing with
Home/Splice. It creates a separate Howl Slint bundle, preserving the installed
older app. The original mobile qualification boundary above records the state
before this work, not an instruction to retain the iOS target rejection.

Keep the remote ABI and CPU image presenter. Reuse the exact published composite
root module and headers with static linkage on iOS, avoiding embedded dylib
signing. iOS-specific policy is limited to Foundation sandbox storage, public
CoreText monospace-file discovery and UIKit app/scene detach notifications. No
fixed private font paths, phone PTY, new provisioning credentials or speculative
Metal importer is introduced. This is an experimental build lane pending actual
Apple compilation, installation and device evidence, not an iOS support claim.

The first real Apple build compiled Slint/Skia and bundled ARM64 FreeType/HarfBuzz,
then exposed a Zig 0.17 `Io.Threaded.NullFile.fd` compile error through the default
panic/debug I/O vtable's unsupported iOS process-spawn branch. The mobile static
root now retains FullPanic safety checks but writes a bounded fatal message using
libc and traps; the operating system crash report owns stack inspection. It imports
the unchanged published ABI rather than patching Zig, an SDK or dependency cache.

## Production-window runtime matrix (2026-11-10)

Captain narrowed the overnight work to benchmarks on Home or Note10, with no
further mobile/toolchain remediation. Home completed 36 successful production
runs: three rotated repetitions of howl-app, Slint CPU and Slint GPU, each with
idle, btop, sparse and dense workloads. These used the normal optimized Slint
dev profile and ReleaseSafe native code; howl-app was explicitly ReleaseSafe.
The production windows replace the earlier fixture's 20-ms supervisory timer.
All runs verified a 128×42 grid with Iosevka 16px. Native frame geometry was
1024×840; Slint's 1024×936 frame includes 36px window decoration and 60px app
chrome. Startup and UI selection were outside the sampled interval.

Median host CPU, as a percentage of one core, in native / Slint CPU / Slint GPU
order:
- Idle: zero measured ticks / 0.09% / 0.14%.
- btop: 0.18% / 1.14% / 0.50%.
- Sparse 60Hz Cells: 2.38% / 24.59% / 7.14%.
- Dense 60Hz Cells: 5.44% / 34.23% / 13.25%.

Slint's separate Server adds about 2% of one core for sparse and 8% for dense
workloads. Native remains faster; the CPU-rendered Slint path has the largest
host CPU gap. Subcomponent costs were not isolated. These current-production comparisons are not a before/after claim
against the earlier fixture runs while Dota was active. Idle/btop samples span
about 21.85 seconds, active samples about 5.9 seconds. Tick precision is 10ms;
zero observed ticks does not prove literally zero CPU use.

Median btop host RSS/PSS/private MiB was 402.64/168.61/109.42 for native,
306.97/149.17/111.50 for Slint CPU, and 298.08/140.35/102.72 for Slint GPU.
Idle private memory was respectively 95.80, 104.72 and 97.75 MiB. Server memory
was normally 4.8–5.3 MiB and btop RSS about 33.7 MiB, both separate from the host;
btop PSS/private was inaccessible through normal proc permissions. Native's
private-seat EGL/OpenGL driver mappings explain why RSS alone is misleading
and do not invalidate Captain's physical-desktop observation. GPU mode logged
RTX 3060/Vulkan. Separate post-sample framebuffer captures showed native 29–31MB,
Slint CPU 52MB and Slint GPU 48MB. CPU terminal rendering still uses GPU-backed
Slint UI composition; framebuffer allocations are not added to RSS as a claim
about unique physical memory.

All 18 active producers emitted 360 frames without skipped slots. Producer
cadence is not presentation count, physical display FPS or input latency; those
remain unmeasured. One empty stty-marker read was a harness race, fixed and
rerun, with the failed pilot retained separately and excluded. No runtime source
changed for these measurements. All owned processes and private seats drained.
Complete samples, ranges, process breakdowns, binary hashes and cleanup receipts
are under `horse-race-20261109/production-results.json` and adjacent production
provenance/matrix files in Home's active workstream.

Note10's native Debian canary did not produce a new executable. With no system
FreeType/HarfBuzz development files, the bundled build ran under a 1500-MiB hard
limit, 1200-MiB pressure threshold, zero swap, one CPU, -j1 and a 900-second bound.
The watcher stopped it on the first memory.high event after roughly ten minutes;
sampled peak was 1,257,979,904 bytes, high events 25, max/OOM/OOM-kill events zero.
This was the conservative per-build guard, not evidence the phone exhausted
system RAM. No retry, package installation or settings change followed. The
partial cache is retained; owned units and private sockets are gone. Three old
baseline integrity runs passed, but neither qualify current pins nor provide
runtime benchmark evidence. Android APK/UI qualification remains open.

### Fresh-launch btop peak trace

A further three rotated repetitions per production host traced memory from a
pre-exec handshake through opening btop and 26 seconds after observed output.
All nine runs kept the same 128×42 geometry. Status/VmHWM sampling had roughly
10.1ms cadence (maximum gap 12.38ms); independent smaps_rollup samples had roughly
250.1ms cadence (maximum gap 253.01ms). There were 29,859 host status samples with
no read errors. Settled values are final-five-second medians; a separate pilot
is retained but excluded from these ranges.

Peak VmRSS/VmHWM was 418.3–419.1 MiB for native, 317.2–317.5 MiB for Slint CPU
and 307.6–308.9 MiB for Slint GPU. Native's peak equaled its settled status RSS;
Slint settled about 0.7–0.8 MiB below peak. The independently sampled smaps peak
RSS/PSS/private ranges were respectively:
- Native: 402.0–402.8 / 167.9–168.7 / 108.7–109.5 MiB.
- Slint CPU: 306.8–307.2 / 149.0–149.3 / 111.3–111.6 MiB.
- Slint GPU: 296.8–298.1 / 139.0–140.4 / 101.3–102.8 MiB.

The previously reported roughly 800-MiB native spike was not reproduced in
these fresh private-seat runs. This does not disprove that physical-desktop
observation, where geometry, session history and environment may differ.
Status counters and smaps disagree materially; both are preserved without an
attribution guess. Status may lag, VmHWM is not timestamped allocation tracing,
and independently sampled PSS/private peaks need not coincide with RSS peaks.
Monitoring and screenshots can perturb timing. Filesystem caches were warm;
first PTY output was bracketed by gate release and the first output screenshot,
not directly instrumented. No speed, latency or displayed-FPS claim follows.
Server and btop remain separate; device-memory snapshots are not memory peaks.
Hashes were unchanged and all owned processes/seats drained. `peak-results.json`,
per-run traces, provenance and cleanup receipts are beside the production matrix
in Home's active workstream. No runtime source changed.

### Keep the CPU blend change small (2026-11-10)

Production phase timing put dense CPU painting at about 547 ms per connection;
UI-thread work remained substantial, especially for sparse changes. GCC's normal
-O2 build called the blend helper per mask pixel. Inline fixed RGB assignments
and one immutable tint snapshot expose those command invariants without a new
cache, renderer, ABI or ownership path. Exhaustive mask-coverage/tint-alpha tests
and a captured canonical frame retain exact pixel parity, including unaligned
output and sentinel bounds. Six rotated replay rounds used about 20.4% less paint
CPU; inline alone did not provide that improvement.

Three alternating production pairs observed dense host CPU at 28.25% before and
25.22% after (medians, one core), with observer CPU consistently lower. UI-thread
variation also contributed, so the entire host delta is not attributed to blend.
Sparse results overlapped and establish no meaningful speedup. Geometry, fonts,
producer and optimization remained matched; producer counts are not displayed
FPS. A separate FemtoVG backend experiment saved CPU but added roughly 52 MiB PSS
and 32 MiB private memory, so the default backend remains unchanged. Temporary
phase instrumentation was removed. Samples, isolated replay, hashes and gates
are in Home's active workstream under `cpu-phase-20261110/`.


### Fold opaque surface initialization (2026-11-10)

A scratch-only packed-observation probe found just one repeated command set in
363 sparse Cells deliveries, none in 362 dense deliveries, and one in 17 btop
deliveries. Canonical content revision advanced on every capture in these runs.
That does not justify retaining another scene to reject unchanged frames here.

Instead, command zero's opaque full-surface solid can initialize the CPU surface
rather than overwrite a separate background clear. Origin, extent and clip must
all prove full coverage; alpha, textured and partial first commands keep the
ordinary path. Command order, integer blending, errors and pixel ownership stay
unchanged. There is no new cache, allocation, backend or ABI. An independent
per-pixel oracle covers all alpha values and 14 coverage/clip cases, unaligned
output, sentinel bounds and missing resources before/after the folded command.

Six alternating dense-frame replay rounds saved 9.38% paint thread CPU with exact
full-buffer parity. Three alternating native-adapter pairs per workload measured
sparse client CPU at 273.87 to 238.23 ms (13.0% less) and dense at 850.94 to
820.53 ms (3.6% less), including transport/canonical capture but not Slint UI.
The matched production-window matrix was mixed: sparse host medians were 23.14%
to 16.08% of one core; dense were 27.55% to 28.73%, with overlapping ranges and
substantial independent UI-thread variation. Those whole-host deltas are not
attributed to the paint change; no broad host speedup or memory saving is claimed.
All accepted active producers emitted 360 frames without skipped slots. Producer
cadence is not displayed FPS or latency.

CPU/GPU unit and clippy, formatting, native/live, sanitizer, private-window parity
and viewport/failure checks, and root ReleaseSafe test/check/audit passed on Home.
A mismatched-feature pilot was stopped and excluded; a private screenshot failure
preceded workload start and was retained separately. No phone build, physical
GUI automation, package-pin edit or existing-service restart occurred. Evidence,
precise limitations and reproducible commands are in Home's active workstream
under `cpu-phase-20261110/next-win/`.


### Pack GPU command uploads once (2026-11-10)

The next UI investigation did not justify a scene cache or backend change.
Chrome cache hints were removed: the combined hint changed exact tab-icon pixels
at scale 2; a status-only hint preserved pixels but did not reduce measured UI
CPU. The existing unchanged-command probe also remains a rejection, not a cache
proposal. Howl-app's direct bounded geometry storage is a useful source lesson;
its local Instance/content-retention architecture is not imported into this host.

Instead, the GPU compositor previously built native u32 records and then
allocated/copied a second byte vector. It now emits one fixed-size record of
explicit little-endian word bytes per command and borrows that storage for upload.
The uniform uses stack bytes. There is no unsafe cast, new dependency, retained
cache, backend switch, ABI change, or texture/resource lifetime change. The
80-byte vertex layout, command bounds and consecutive resource batches stay put.

Six alternating dense-frame replay rounds (5,032 commands) measured packing
thread CPU at 305.60 to 36.80 microseconds per frame, 88.0% less, with all 402,560
upload bytes identical. Layout tests cover signed coordinate extremes, u16
bounds, color channels, tags, padding and concatenated records. Existing private
GPU window tests still compare exact pixels across resource replacement/resize.

Three matched production GPU pairs per workload had sparse host CPU medians
8.47% to 7.12% of one core and dense 13.89% to 14.90%. Ranges overlap; UI-thread
CPU medians were 0.32 to 0.26 seconds sparse and 0.40 to 0.38 dense, while other
thread costs varied. These do not establish an overall host speedup or memory
saving. The justified claim is isolated packing work removed, not displayed FPS,
physical presentation latency or a CPU-route optimization. All 14 GPU/CPU-canary
producers emitted 360 frames without skipped slots, at matching fonts/grid.

CPU/GPU unit and clippy, formatting, native CPU/live and sanitizer, private-window
viewport/parity/failure, WGPU TLS teardown, and root ReleaseSafe test/check/audit
passed. No pins, Server semantics, physical desktop, existing services or phone
builds changed. Reproduction, binaries, raw measurements, rejected probes and
limits are in Home's active workstream at
`cpu-phase-20261110/ui-runtime/PACKING_RESULTS.md`.
