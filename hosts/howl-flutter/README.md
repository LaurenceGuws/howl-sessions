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
- `instances/` owns a text-only diagnostic preview from one **dedicated native
  Instance attachment**, refreshed explicitly. The host does not own framing,
  decoding or snapshot memory. Incremental observation, input scheduling,
  VT cell painting and graphics are **not yet implemented** in Flutter.
- `mods/server-client/bindings/dart` owns all C struct layouts, framing via
  the native library, exact unsigned 64-bit identities and handle cleanup.
  Each management operation runs off the UI isolate.

## Checks and platform build

`flutter analyze` and `flutter test test` validate the current Dart host. The
client's `dart analyze`, `tool/catalog_canary.dart ENDPOINT` and
`tool/attachment_canary.dart ENDPOINT` qualify the separate binding. The first
creates and closes a real remote Session and Instance; the second exercises a
dedicated terminal attachment, output revision, input and text projection.
Both require `HOWL_SERVER_CLIENT_LIBRARY` pointing to the compiled shared ABI
and an explicitly started development Server.
The initial Linux and Android attachment integration passes include a Server
identity above the signed 64-bit boundary. The Dart binding converts unsigned
IDs to native two's-complement bit patterns before FFI calls.

Home builds Android, not Note10. Set `ANDROID_NDK_ROOT` to a usable Android NDK
with API 24 files, then run `./build-android.sh debug`. The script builds the
versioned Server client shared ABI for Android arm64 with the pinned Zig,
packages it in the APK, and verifies the library exists. Generated binaries
stay ignored under `native/android` and `build/`. Installation and test-server
selection are separate attended canaries.

The Linux runner scaffold exists but Home currently lacks Ninja; there is
no validated Linux desktop bundle yet. iOS host
packaging is also pending.

## Android native canary

`integration_test/native_client_test.dart` loads the APK-packaged native client
on Android and performs real Session/Instance CRUD, then cleans up. It requires
an explicit `HOWL_CANARY_ENDPOINT` via `--dart-define`. The initial Note10 pass
used Home USB ADB reverse to a localhost development Server; this proves native
ABI, Android library loading and transport correctness, **not** representative
remote-network latency. A direct Note10-to-Home Cloudflare Mesh connection to
Home's Mesh-bound dev port timed out and remains a separate gate. The main
Android manifest owns TCP socket permission in all build modes.
