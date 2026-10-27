# Howl Sessions Flutter host

Flutter is a product host, not the owner of Server, terminal semantics, FFI
contracts or rendering. This is a **fresh** host; the original
`howl/hosts/howl-flutter` remains a behavioral reference while the ownership
boundaries are established.

## Current slice

- `main.dart` only initializes and launches the app.
- `app.dart` owns host navigation and endpoint selection.
- `servers/` owns local named endpoint preferences and their Settings CRUD.
- `sessions/` shows the selected Server's Session/Instance tree, with Session
  and Instance create/close. The add action for Sessions lives on that pane.
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
creates and closes a real remote Session and Instance; the second exercises a
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

The Linux runner scaffold exists but Home currently lacks Ninja; there is
no validated Linux desktop bundle yet. iOS host
packaging is also pending.

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
