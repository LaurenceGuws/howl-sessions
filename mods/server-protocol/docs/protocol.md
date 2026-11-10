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
8 KiB payload ceiling. Terminal kinds are 32–66 (64 retired/rejected) with a 1 MiB response ceiling and
64 KiB request ceiling. Each phase rejects the other's tags before payload
admission. Old SRVR version 1 and HWLS version 10 are rejected.

[Terminal wire reference](terminal-wire.md) documents the borrowed VT observation,
input, image, property and consequence payloads. Their semantic codec grammar is
unchanged; Server owns delivery envelopes, revisions and predecessor correlation.
[Language-neutral vectors](../protocol/vectors.json) cover common framing, ready
identity, terminal payloads and hostile inputs. Zig proofs cover control model
operations and ownership; the independent oracle does not claim a second complete
control implementation.

## Pre-release compressed-cache cut

The sole logical compressed cached operation now explicitly requests 66 and
receives packed full 63 or compressed delta 65. Request 64 is retired/rejected,
not reinterpreted. Raw 59 and ordinary 32/57/62 retain their contracts. This is a
wire-floor incompatibility for old 64 callers/new 66 calls on old Servers, without
a framing-version or native layout/symbol-set change. SRVR 2/C ABI 1/symbol presence
are not feature discovery. No negotiation, alias, probe, replay or fallback.

The [authoritative terminal contract](terminal-wire.md#pre-release-wire-floor-cut--compatibility)
records exact carriage, recovery, independent Client baselines, public 64 release
availability/unknown use and incomplete deployment inventory. A matching pinned
Client and verified 66-capable Server source/binary are required before use; record
commit/artifact hashes at separately authorized publication. No installed runtime,
existing artifact, package pin or host default is changed by this source cut.
