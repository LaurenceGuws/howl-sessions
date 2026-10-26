# Server protocol

Owns SRVR v2 control and terminal framing for Howl Sessions.

This package publishes both the Server wire and its terminal observation codec.
The codec's encoder borrows canonical VT facts directly; neither module owns
the terminal, a second grid, a listener, Server/Session/Instance lifetime,
rendering, or platform UI.
The wire version is independent of this package's release version.

`zig build test` runs the pure protocol/codec and 85-vector oracle proofs.
`zig build wire` runs just the vectors; `zig build audit` is a separate
standalone-package gate. Server separately qualifies the encoder against the
exact VT module published by its Instance dependency.
