# server-client

Independently versioned client for Howl Sessions. It owns **connections** and
protocol interpretation, not Sessions, Instances, PTYs, listeners or product UIs.
No production client module imports the Server model or a live Instance.

| Selected module or artifact | Owner |
| --- | --- |
| `server_client` | Catalog/CRUD connection and dedicated terminal attachment |
| `server_client_byte` | Caller-driven terminal frames over borrowed byte buffers |
| `server_client_native` | Native semantic observations and request replies |
| `server_client_render` | Optional conversion of client observations for Howl Render |
| `server_client_render_native` | Exact Render-owned native module, forwarded unchanged |
| `howl_server_client` | Static C ABI by default, optional shared ABI (`-Dshared-abi=true`) |
| `bindings/dart` | Dart FFI for catalog and CRUD, retaining full unsigned u64 identities |

`server_protocol` is the independently versioned wire contract.
Transport, control and terminal owner modules are shared only with the
real-Server integration tests and are **not stable consumer interfaces**.

The [client](docs/client.md) and [byte client](docs/byte-client.md)
contracts define lifecycle, framing, failure and bounded allocation.

`zig build test` runs client-only proofs (including native and byte
decoders, render semantics and SIGPIPE). The Server package owns the separate
live-service and foreign-C integration tests, which consume this exact client
package without giving clients a Server dependency.

This package pins the independently published Howl core archives by exact Zig
hash. It requires no sibling Howl checkout.

`zig build install -Dshared-abi=true` emits the same version-1 symbols in
`libhowl_server_client.so` on Linux/Android. The Dart binding owns all native
struct layouts and handle cleanup; Flutter sees immutable copies and makes
blocking management requests on worker isolates. The installed header is the
single authority, and the [Dart live canary](bindings/dart/tool/catalog_canary.dart)
checks real Session and Instance create/observe/close against an explicit
development Server. Terminal attachments remain distinct from catalog CRUD.
