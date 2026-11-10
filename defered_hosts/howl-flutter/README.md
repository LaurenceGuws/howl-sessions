# Howl Sessions Flutter host

Flutter is a product host, not the owner of Server, terminal semantics, FFI
contracts or rendering. This is a **fresh** host; the original
`howl/hosts/howl-flutter` remains a behavioral reference while the ownership
boundaries are established.

## Current slice

- `main.dart` only initializes and launches the app.
- `app.dart` owns host navigation and endpoint selection.
- `servers/` owns local named endpoint preferences and their Settings CRUD.
  The existing v1 preferences remain readable, with explicit limits: 32 Servers,
  64 Unicode scalars per name, 1024 UTF-8 bytes per endpoint and 64 KiB encoded
  settings. Invalid/duplicate configurations fail before a save; invalid stored
  data is reported rather than silently truncated on load. The host validates
  bounds and control characters, leaving transport grammar to the native owner.
  Settings serialize editor/removal dialogs through completion, and the home
  view retains the save gate across Settings navigation. Field errors are shown
  inline; a failed save keeps the previous in-memory configuration.
- `sessions/` shows the selected Server's Session/Instance tree, with Session
  and Instance create/close. The add action for Sessions lives on that pane.
  Phones open a selected Instance into a full terminal viewport; Back returns to
  the catalog and detaches the view without stopping its process. Wide windows
  keep the catalog alongside the terminal. One management action or dialog may
  be active at a time. Capacity comes from the observed Server catalog.
  Every mutation requires that catalog's Server incarnation; the Dart binding
  checks it on the same control connection before sending a mutation. A restart
  clears old numeric selections. Failed requests are never automatically replayed;
  the error action refreshes the catalog so the operator can inspect the result.
  Create forms own their editing lifetime until the dialog route is disposed.
  Opening Settings retains only the browser's catalog selection: the terminal
  subtree is removed, disposing observation, input and sizing attachments. On
  return, a fresh catalog must confirm the same Server incarnation before the
  selected terminal is reattached. Input starts empty and sizing starts as a
  follower. An in-flight read cannot publish into a hidden view. This is a
  Settings-navigation guarantee; direct mobile background cancellation remains
  a separate owner-lifecycle qualification because paused Flutter apps do not
  necessarily render a frame to dispose their widget subtree.
- `instances/` owns a native Render Canvas and **semantic terminal input** to one
  Instance. Separate Instance attachments isolate rendering observation from
  input. The observer borrows a native snapshot, copies canonical Render frame
  commands and pixels on its worker, then releases both native borrows before
  posting the frame to Flutter. The Canvas decodes uploads, reports actual
  resident textures on its next pull, and retires removed images after a frame
  is painted. Blocked observation is cancelled and joined before the native
  interrupt is freed. IME commits travel as UTF-8 text; named and modified
  physical keys travel as native press/repeat/release transitions. Software
  Backspace uses private IME editing guards that never reach the Server.
  The host owns a delta TextInput connection rather than resetting a hidden
  TextField after each character. Queued platform deltas send only their actual
  insertion, even when their old text predates a reset. Preedit stays local until
  commit, with a 4096 UTF-16-unit bound; one callback accepts at most 64 deltas.
  Smart quotes/dashes, prediction and IME learning are disabled. Unsupported
  replacement of already transmitted text, multi-character deletion, oversized
  input and a platform that does not provide deltas stop input explicitly.
  Reconnect abandons pending input rather than guessing or replaying it.
  Terminal input has a bounded ordered queue and explicit reconnect, without
  replaying ambiguous sends. Geometry has its own exact-identity Client
  attachment. The drawable rectangle and native Render cell metrics determine
  the proposed rows/columns. Opening a viewport never claims the lease; the
  user must select **Take sizing control**. Only that attachment then sends
  debounced changes as keyboard insets or rotation change available space.
  A lost leader receives an ordinary NOT_LEADER response and stops automatic
  resizing. Reconnection starts as a follower and needs a new explicit takeover.
  Canvas zoom/pan never changes terminal geometry. Graphics fetching remains
  pending.
- Android and iOS select two Flutter-owned, licensed font assets: unmodified
  IosevkaTerm Nerd Font (primary) and Noto Sans (fallback). The host verifies
  bundled bytes against pinned SHA-256 digests, writes them to an app-private
  application-support directory using same-filesystem staged rename, and
  revalidates/replaces corrupt or partial installed copies on subsequent use.
  Concurrent requests in one Dart isolate coalesce, and failures permit retry.
  Flutter passes the resulting paths to the existing native Text/Render owner;
  there is no alternative Flutter text renderer or new C ABI. The full OFL
  notice is shipped as `LICENSES/redistributed-fonts.txt` and both font files
  remain byte-identical to the recorded Howl Text fixtures. The 13 MiB Iosevka
  binary is a deliberate development packaging cost, not a stable-size promise.
  The two bundled faces do not promise complete Unicode/emoji coverage.
  Linux keeps its existing explicit environment/fontconfig selection.
  iOS native library linking, sandbox use, provisioning and runtime **remain
  unqualified** until an independent real-target gate.
- `mods/server-client/bindings/dart` owns all C struct layouts, framing via
  the native library, exact unsigned 64-bit identities and handle cleanup.
  Each management operation runs off the UI isolate. Each retained attachment
  borrows a separately owned native interrupt whose only cross-isolate call is
  its documented synchronous cancellation. Tokens outlive worker exit.
- `mods/server-client-render/bindings/dart` owns the versioned Render native
  frame records and a separate observing worker. The Flutter host owns image
  decoding, drawing, and backend texture residency, never a second cell grid.

## Checks and platform build

`flutter analyze` and `flutter test test` validate the current Dart host. The
client's `dart analyze`, `tool/catalog_canary.dart ENDPOINT` and
`tool/attachment_canary.dart ENDPOINT` qualify the separate binding. The first
creates and closes a real remote Session and Instance, and proves all four
management mutations reject stale Server identity without changing the catalog; the second exercises a
dedicated terminal attachment, output revision, input, retained live following,
cancel-while-blocked, independent input during parked observation, oversize
input rejection and text projection. The attachment canary additionally checks
follower resize rejection, explicit geometry takeover, and nonfatal loss of
authority on the superseded connection.
`tool/semantic_input_canary.dart ENDPOINT` additionally proves real native
named/Unicode key transitions, Ctrl+C interruption and observer cancellation.
Both require `HOWL_SERVER_CLIENT_LIBRARY` pointing to the compiled shared ABI
and an explicitly started development Server.
The initial Linux and Android attachment integration passes include a Server
identity above the signed 64-bit boundary. The Dart binding converts unsigned
IDs to native two's-complement bit patterns before FFI calls.

Home builds Android, not Note10. Set `ANDROID_NDK_ROOT` to a usable Android NDK
with API 24 files, then run `./build-android.sh debug`. The script builds the
composed Server Client + Render shared ABI for Android arm64 with the pinned Zig,
packages only `libhowl_sessions_native.so` in the APK, and verifies both
Client and Render exports. Generated binaries
stay ignored under `native/android` and `build/`. Installation and test-server
selection are separate attended canaries.

The composed Flutter Canvas builds, analyzes and passes widget/resource tests.
The earlier Note10 Android Canvas canary passed; the expanded semantic keyboard
still needs its own attended Note10 device canary.
Native graphics manifests are currently rejected explicitly; a full image
fetch/refill lane is not silently substituted.

## Linux bundle

Run `./build-linux.sh debug` (or `profile`/`release`) with Ninja on PATH. If Ninja
is already installed with the Android SDK, a build-local example is
`PATH=/opt/android-sdk/cmake/3.22.1/bin:$PATH ./build-linux.sh debug`.
The script composes the exact native Client/Render owners, builds Flutter and
puts `libhowl_sessions_native.so` in the bundle's `lib/`, verifying both owners'
exports. The executable resolves that library relative to itself; no environment
library override is required. This is a host-built Linux bundle, not a portable
cross-distribution release. Font selection still uses the explicit HOWL_FONT_PATH
or the existing fontconfig path.

A real private KWin 430×900 canary covers catalog/create, full terminal display,
explicit sizing takeover, Back/detach and reattach with the process still alive.
It first exposed cumulative input replay at 1 ms key intervals with the hidden
TextField. The delta-owned replacement passes that same rapid-typing reproducer,
physical Backspace and Ctrl+C interruption. Unicode/composition are model-tested;
WMIO's private EIS typing surface is ASCII-only, so this is not a real mobile IME
claim. The changed Android app is build-qualified, with device keyboard/runtime
qualification still pending. iOS host packaging remains unqualified.

## Android native canary

`integration_test/native_client_test.dart` loads the APK-packaged native client
on Android and performs real Session/Instance CRUD and concurrent observation
and text input on separate attachments, then cleans up. It requires
an explicit `HOWL_CANARY_ENDPOINT` via `--dart-define`. The initial Note10 pass
used Home USB ADB reverse to a localhost development Server; this proves native
ABI, Android library loading and transport correctness, **not** representative
remote-network latency. A direct Note10-to-Home Cloudflare Mesh connection to
Home's Mesh-bound dev port timed out and remains a separate gate. The main
Android manifest owns TCP socket permission in all build modes.
