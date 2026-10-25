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
- `instances/` owns a native Render Canvas and **explicit line input** to one
  Instance. Separate Instance attachments isolate rendering observation from
  input. The observer borrows a native snapshot, copies canonical Render frame
  commands and pixels on its worker, then releases both native borrows before
  posting the frame to Flutter. The Canvas decodes uploads, reports actual
  resident textures on its next pull, and retires removed images after a frame
  is painted. Blocked observation is cancelled and joined before the native
  interrupt is freed. Shell-line submission adds Enter; full terminal key
  handling, terminal geometry selection and graphics fetching remain pending.
- Android's canary font uses the device's verified DroidSansMono file with
  available Arabic/CJK fallbacks. The app does not yet bundle its own font.
  iOS font provisioning and native linking remain separate work.
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
input rejection and text projection.
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
That is a source/build qualification, not yet a live Android Canvas pass.
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
