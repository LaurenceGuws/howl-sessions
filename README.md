# Howl Sessions

Howl's orchestration and application product family.

- **Howl:** native VT, PTY, Instance, Text, Render, and direct local hosts.
- **Howl Sessions:** Server, protocol, clients, CLI, Flutter, Web, and Odin.
- Hosts remain free to use local Instances without a Server.

## Extraction checkpoint

Server, CLI, Web and Odin have been copied from Howl commit
`73c529b7e356f27e709e44e05928bb44ca2bcb2e` with no application behavior
change. The original checkout remains the behavioral reference and is not
deleted. The copied packages temporarily resolve Howl core through the
adjacent source checkout; **this is not a distributable release**.

`zig build test` exercises the maintained packages. Each package retains its
own `build.zig.zon` version and proofs. `zig build check` runs those proofs
plus one root audit of all Git-owned Zig source; the installed zig-audit
currently refuses nested Git configuration roots.

The pure Server protocol now has a separate package/version and exact forwarded
module identity. Next: independently pinned Howl package releases, a separate
client release root, fresh Flutter host, and explicit C/Dart
foreign-interface ownership. Network follow/streaming is a later experiment.
