# Howl Web gateway

This package owns the node-local browser transport edge for the experimental Howl Web
client. It binds loopback, admits bounded HTTP/WebSocket traffic, performs one exact
Server attach, and then becomes a protocol-blind Server terminal byte bridge.

Each browser WebSocket creates a Server control connection, verifies the configured
Server incarnation, and requests the exact Session/Instance. The gateway consumes
the complete ready response and forwards it as the first binary WebSocket message.
The native socket then belongs to that dedicated attachment; Wasm completes
construction from the same ready response.

After ready, the gateway pumps opaque bytes. It parses no terminal state, PTY bytes
or renderer data, and owns no PTY, VT, Instance, Session or Server lifetime. The
operator supplies the Server port and all three exact nonzero IDs. Disconnecting a
WebSocket releases only that attachment.

The process binds **only `127.0.0.1`**. Public delivery belongs to an external edge such
as Cloudflare Tunnel/Access; do not bind this gateway to a non-loopback address or treat
the presence of a Cloudflare header as cryptographic authentication by itself.

## Admission

Before opening any Server control connection the gateway requires:

- exact `Host`;
- exact WebSocket `Origin`;
- HTTP/1.1 GET with no request body;
- WebSocket version 13, one valid 16-byte nonce, and exact upgrade tokens;
- when `--require-access` is selected, a nonempty `Cf-Access-Jwt-Assertion` injected by
  the already-enforcing Cloudflare Access application.

The last check is an origin-misrouting guard. Cloudflare Access remains the identity
authority. Rejected browser requests therefore create **zero Server connections**.

At most six simultaneous WebSockets are admitted. Each admitted WebSocket obtains its
own exact attach to the configured Instance, matching the existing observer/control/
history/image client model. One browser message is at most 64 KiB and upstream reads are
emitted as at most 16 KiB binary WebSocket messages. Text and fragmented browser
messages fail closed. Ordinary HTTP concurrency is bounded to eight connections.

Static serving is an exact route table only. There is no request-derived filesystem
path, proxy route, directory listing, or fallback SPA path.

## Build and prove

```sh
zig build check test
zig build install -Doptimize=ReleaseSafe
```

`test` includes a Python-standard-library black-box proof. Its upstream is a minimal
`server_protocol` peer that validates `hello`, exact Session+Instance attach and
`attach_ready`, then becomes an opaque echo stream. Denied Host, Origin, Access and
malformed WebSocket requests are proven to create zero Server connections. Six admitted
WebSockets all attach the exact configured identity, a seventh is refused, text is
rejected, and more than 9 MiB crosses one long-lived post-attach binary stream.

The executable is:

```text
zig-out/bin/howl-web-gateway
```

Usage:

```text
howl-web-gateway LISTEN_PORT SERVER_PORT SERVER_ID SESSION_ID INSTANCE_ID EXPECTED_HOST EXPECTED_ORIGIN SITE_DIR WIRE_WASM [--require-access]
```

`SERVER_PORT` is the loopback Howl Server control listener. `SESSION_ID` and
`INSTANCE_ID` identify the exact terminal occurrence to expose. The gateway does not
perform Session-name lookup, Instance selection, creation, restart or discovery.

Managed target identity includes the expected `SERVER_ID` from Server status/tree
(or the run receipt), before Session and Instance IDs. All three are nonzero decimal
u64 values. A reused endpoint with a different Server incarnation fails closed as
stale; explicitly browse/select the new Server instead of silently reconnecting to
its reused Session/Instance numbers. This is target identity, not authentication.
