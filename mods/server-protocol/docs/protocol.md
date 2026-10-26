# Server wire

The optional server_protocol module owns one bounded SRVR version 2 envelope for
Server control and dedicated Instance interaction. It also publishes the pure
terminal_observation_codec module for observation carriage and validation;
neither wire nor codec imports a live VT parser, Instance, PTY, renderer,
transport, listener, authentication or lifecycle owner.

Control covers Server status/tree observation, Session and Instance CRUD, and
exact Instance attachment. Session create carries a logical name. Process launch
policy belongs to Instance create.

A connection begins with empty hello and a welcome containing current Server
status. A client checks the expected Server incarnation before requesting one
exact Session/Instance. Successful attachment returns a single 40-byte ready
payload containing Server, Session, Instance, tree revision and client identity,
then dedicates that same ordered stream to the selected Instance. A separate
control connection remains available for catalog and CRUD. No terminal handshake
or per-Instance listener is introduced.

The envelope uses a 12-byte header: SRVR magic, version 2, one kind byte, two zero
reserved bytes and a big-endian u32 payload length. Control kinds are 1–13 with an
8 KiB payload ceiling. Terminal kinds are 32–63 with a 1 MiB response ceiling and
64 KiB request ceiling. Each phase rejects the other's tags before payload
admission. Old SRVR version 1 and HWLS version 10 are rejected.

[Terminal wire reference](terminal-wire.md) documents the borrowed VT observation,
input, image, property and consequence payloads. Their semantic codec grammar is
unchanged; Server owns delivery envelopes, revisions and predecessor correlation.
[Language-neutral vectors](../protocol/vectors.json) cover common framing, ready
identity, terminal payloads and hostile inputs. Zig proofs cover control model
operations and ownership; the independent oracle does not claim a second complete
control implementation.
