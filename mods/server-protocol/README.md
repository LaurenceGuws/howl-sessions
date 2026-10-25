# Server protocol

Owns SRVR v2 control and terminal framing for Howl Sessions.

This pure package imports the optional Howl VT observation codec. It owns no
listener, socket, Server/Session/Instance lifetime, rendering, or platform UI.
The wire version is independent of this package's release version.

`zig build test` runs the protocol proofs and the independent 85-vector oracle.
`zig build wire` runs just the vectors; `zig build audit` is a separate
standalone-package gate. The source manifest's Howl path is a temporary
development bridge; releases must pin an immutable Howl VT package.
