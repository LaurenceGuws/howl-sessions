# server

`server` is optional orchestration above the Howl terminal module family. It is not
Howl's identity and it is not required by `howl-vt`, `howl-pty`, `howl-instance`,
or a local terminal host.

The ownership tree is exact:

Server owns Sessions; each Session owns its concrete Instance lifetimes.

An Instance is one concrete Howl terminal occurrence. A Session is not an Instance:
it is a logical orchestration lifetime that may contain zero or more Instances. Creating
a Session never launches a shell. Shell, command, cwd and terminal geometry belong only
to explicit Instance creation.

The Server model and control service remain listener-free. Server owns an optional `server_terminal_service` interaction service beside each concrete Instance; Server routes already-connected streams by exact Session + Instance identity into that service.

The foreground listener/scheduler is this package's `server_runtime` entry point,
composed by the existing CLI. It selects presentation-free Instance and consumes
the optional VT codec; local terminal composition does not import this package.

## Shared protocol

`server_protocol` owns the bounded control and terminal-interaction wire in
the independently versioned [Server protocol](../server-protocol) package.
The independently versioned [Server client](../server-client) owns
connection/control and terminal APIs, with its own private transport.
Server forwards the exact imported protocol module for consumers;
neither client nor wire-only consumers import the Server model,
Instance, PTY or live VT.

All connections use one SRVR version 2 envelope. Catalog/CRUD connections stay in
Server control; each successful attachment dedicates its stream to one exact
Instance. A single ready response carries Server, Session, Instance, tree revision
and client identity for both native and browser consumers. Disconnect releases the
attachment; only explicit close destroys the Instance. UI owns tabs and layout.

| Export | Selected ownership |
| --- | --- |
| `server_runtime` | listeners, scheduling and shutdown over the Server owner |
| `server` | listener-free Server/Session/Instance lifetime model |
| `server_service` | bounded adopted control streams and exact routing |
| `server_terminal_service` | bounded adopted terminal streams and observation delivery |
| `server_protocol` | pure Server wire plus optional VT observation codec |
| `server-client` dependency (integration tests only) | real-client fixtures and foreign-C proofs; not linked into the Server runtime |

`zig build check test` proves Server and its integration with the independent
client, including a foreign C caller against a private live Server.
`zig build wire` validates its wire corpus. The
[runtime](docs/runtime.md), [client](../server-client/docs/client.md),
[byte client](../server-client/docs/byte-client.md) and
[protocol](../server-protocol/docs/protocol.md) contracts describe the
selected connection interfaces.

## Control service

`server_service` is a listener-free adopted-stream service around one borrowed
`Server`. It owns bounded control-client buffers and long-poll state, decodes
`server_protocol`, performs exact CRUD through the Server model, serializes the
read-only tree, and transfers an exact `(session_id, instance_id)` stream into
the Server-owned terminal service beside that Instance. It does not turn Instances itself: a higher runtime
must schedule control and Server terminal service turns independently.

The service borrows both Server and inherited environment lifetime. It creates no
listener, endpoint address, daemon, child process, authentication policy, route,
or supervision policy. On failed stream adoption the caller retains the fd; on
successful Instance attach the fd changes ownership directly from control service
to Server terminal service with no byte proxy.

## Ownership and shutdown boundaries

Server is an opaque allocated owner: `*Server` grants mutation and `*const Server`
grants observation. Runtime owns that one allocation directly. Session records remain
typed and internal, allocated lazily behind Server; no wrapper or public storage pointer
lends their ownership. Direct owner methods remain the mutation lane; tree views copy
identity/state and borrow const names.
Session names use the same model/wire contract: 1–64 ASCII bytes from `[A-Za-z0-9._-]`.
Invalid names change neither counts, identity issuance nor tree revision.

The listener/scheduler and ordinary shutdown policy are owned by this package's
runtime. This family remains optional orchestration above Instance.
