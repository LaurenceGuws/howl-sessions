# Howl Sessions

Howl's orchestration and application product family.

- **Howl:** native VT, PTY, Instance, Text, Render, and direct local hosts.
- **Howl Sessions:** Server, protocol, clients, CLI, Flutter, Web, and Odin.
- Hosts remain free to use local Instances without a Server.

## Extraction checkpoint

Server, CLI, Web and Odin originated from Howl commit
`73c529b7e356f27e709e44e05928bb44ca2bcb2e`. The original checkout
remains the behavioral reference and is not deleted. The product modules now
resolve Howl core through **independently published and hash-pinned packages**,
with no adjacent checkout required.

`zig build test` exercises the maintained packages. Each package retains its
own `build.zig.zon` version and proofs. `zig build check` runs those proofs
plus one root audit of all Git-owned Zig source; the installed zig-audit
currently refuses nested Git configuration roots.

The Server protocol and client are separately owned and versioned; consumers
select the client without importing Server. The Odin host stages its exact
VT/Render/Instance bindings from the same pinned packages while retaining its
direct local Instance route.

A **fresh Flutter host** is now under `hosts/howl-flutter`. Its `main.dart`
only boots the app; endpoint preferences, Session tree, Instance selection and
platform packaging have distinct owners. It uses the Dart bindings owned by
`mods/server-client`, which invoke the exact C ABI in worker isolates.
The live catalog and Session/Instance CRUD have an independent native proof.
Flutter is a product host, with live terminal following, input and native
rendering. Its current capabilities and remaining qualification limits belong
in [the host README](hosts/howl-flutter/README.md).
See [decisionlog.md](decisionlog.md) for why the product split and fresh host
exist; the old text-only projection canary is not the current product scope.
