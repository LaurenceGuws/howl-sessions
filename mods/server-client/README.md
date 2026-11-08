# server-client

Independently versioned client for Howl Sessions. It owns **connections** and
protocol interpretation, not Sessions, Instances, PTYs, listeners or product UIs.
No production client module imports the Server model or a live Instance.

| Selected module or artifact | Owner |
| --- | --- |
| `server_client` | Catalog/CRUD connection and dedicated terminal attachment |
| `server_client_byte` | Caller-driven terminal frames over borrowed byte buffers |
| `server_client_native` | Native semantic observations and request replies |
| `terminal_client` | Exact terminal module consumed by the independently versioned Render adapter |
| `howl_server_client` | Static C ABI by default, optional shared ABI (`-Dshared-abi=true`) |
| `bindings/dart` | Dart FFI for catalog/CRUD and dedicated native terminal attachments, retaining full unsigned u64 identities |

`server_protocol` is the independently versioned wire contract.
Transport and control owner modules are private proof interfaces.
The terminal module is forwarded unchanged to the separately versioned
Server Client Render adapter; it does not acquire rendering responsibilities.

The [client](docs/client.md) and [byte client](docs/byte-client.md)
contracts define lifecycle, framing, failure and bounded allocation.

`zig build test` runs client-only proofs (including native and byte
decoders and SIGPIPE). The Render adapter owns its own tests. The Server package owns the separate
live-service and foreign-C integration tests, which consume this exact client
package without giving clients a Server dependency.

This package pins the independently published Howl core archives by exact Zig
hash. It requires no sibling Howl checkout.

`zig build install -Dshared-abi=true` retains the standalone Client-only
`libhowl_server_client.so` artifact. The Flutter product instead composes
Client and Render in `libhowl_sessions_native.so`; that is the default Dart
library name. Standalone Client canaries select their older artifact explicitly
with `HOWL_SERVER_CLIENT_LIBRARY`. No snapshot handle may cross the two builds.
The Dart binding owns all native
struct layouts and handle cleanup; Flutter sees immutable copies and makes
blocking management requests on worker isolates. The installed header is the
single authority, and the [Dart live canary](bindings/dart/tool/catalog_canary.dart)
checks real Session and Instance create/observe/close against an explicit
development Server. A separate [attachment canary](bindings/dart/tool/attachment_canary.dart)
owns one dedicated connection, observes immutable text, sends input and proves
advancing revisions and resize before release. The independent
[`u64` boundary canary](bindings/dart/tool/native_identity_canary.dart) verifies
lossless C/Dart identities through the signed-bit boundary and full unsigned
range. The text preview remains diagnostic; the Flutter product's Render
observer consumes native snapshots synchronously with the exact composed ABI.
Terminal attachments remain distinct from catalog CRUD.

## Dart native image ownership

The Dart native attachment exposes `imageManifest` only inside its existing
`observeWith` snapshot borrow, and `fetchImage` on that same serialized
attachment. It copies exact image ID/generation/extent and RGBA8 bytes before
releasing the C image owner. A copied result can outlive both snapshot and
attachment. The manifest limit is the protocol's 256 identities; each fetched
image is bounded by `HSC_MAX_IMAGE_BYTES` (16 MiB). Extents are checked by division
before multiplication or pixel copying. Manifest membership is not visibility
or Render residency; the consumer still selects visible resources and owns its
aggregate cache/decoded-image budget.

The native C fixture and `bindings/dart/tool/image_canary.dart ENDPOINT` prove
fetching while an immutable snapshot is held, exact RGBA copying, stale-generation
rejection with the completed connection still usable, and cancellation before
fetch. `tool/image_identity_check.dart` covers bounds without a live Server.
These additions use existing C ABI v1 functions. They do not enable graphics in
Flutter or change Render's backend residency contract; that two-phase staging
work remains separate.

`hsc_observe_cached_compressed` explicitly opts into compressed revision deltas.
The peer must implement `observe_delta_compressed`; this is not negotiated or
automatically retried as another mode. Cache, cancellation and immutable snapshot
ownership match `hsc_observe_cached`. Existing `hsc_observe` remains packed and
works with earlier peers.
