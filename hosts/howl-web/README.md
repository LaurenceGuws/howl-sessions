# Howl Web

Web is a maintained experimental browser canary, not another terminal engine and not a
Server implementation. It pressures the same Instance client, text, terminal renderer and
browser-host boundaries from Wasm/JavaScript.

## Current ownership

The browser owns presentation and browser input policy only. Canonical terminal truth
remains in one Howl **Instance**:

Instance owns PTY, VT and canonical geometry. The Server-owned terminal service
borrows that Instance and exposes Server terminal interaction on dedicated attachment streams. Web wire/Wasm
consumes those streams and projects through shared text/render machinery into browser
resources.

JavaScript never parses terminal cells, shapes terminal text, or constructs terminal
escape sequences. It hosts Wasm, owns browser resources and UI state, and submits the
existing semantic Howl input vocabulary.

The Web package owns no PTY, VT, Instance, Session, Server, authentication, discovery,
or service-supervision lifetime.

## Maintained gates

These are current and supported as repository proofs:

```sh
cd howl-web
zig build check
zig build render-check
zig build text-check
zig build gateway-check
```

`zig build check` validates the zero-import freestanding wire module, including framing,
split delivery, bounded snapshots and semantic control messages.

`zig build render-check` pressure-tests the shared
`server_client.terminal.view -> howl-text -> howl-render.terminal.Renderer -> terminal Frame`
path in Wasm.

`zig build text-check` compares target-built native/Wasm text metrics, shaping, source
clusters, glyph positions and alpha masks.

`zig build gateway-check` proves the loopback HTTP/WebSocket carrier policy: rejected
Host/Origin/Access/WebSocket requests cause zero upstream terminal connections and only
admitted binary WebSockets cross the protocol-blind byte-pump boundary.

Buildable browser artifacts remain available through:

```sh
zig build render-web
zig build text-web
zig build gateway-install
```

## Live gateway route

The browser gateway follows the same topology as Flutter and the native CLI. The
operator supplies a loopback Server port and exact Server, Session and Instance IDs.
The gateway checks the incarnation, completes attachment at the common ready response,
and forwards that response as the first binary WebSocket message. Wasm accepts it as
its established state; there is no browser hello or second welcome.

Each observer/control/history/image WebSocket independently attaches to the selected
Instance. The gateway then pumps opaque ordered bytes. Server publishes no per-Instance
listener. The gateway owns no canonical lifetime or terminal semantics.

The black-box gate verifies fail-closed HTTP admission before any Server connection,
exact identity and client ID in the first ready message, independent attachments,
bounded capacity and long-lived binary streaming.

The disposable Node/Wasm pressure command is:

```sh
zig build live -- SERVER_LOOPBACK_PORT SERVER_ID SESSION_ID INSTANCE_ID
```

It negotiates the Server welcome, requests that exact Instance, and feeds the shared
ready response and terminal traffic into the real Wasm under single-byte delivery.
It is a private runtime/wire proof; browser platform qualification remains separate.

## Browser interaction policy

The maintained browser host preserves the same client-side policies already pressure-
proved in Flutter/Web canaries:

- semantic committed text, paste, key, focus, resize and mouse actions;
- explicit resize authority, with `not_leader` treated as a normal follower outcome;
- local history viewport state while canonical history remains Instance-owned;
- presentation-local selection/highlight and conceal-safe visible-text projection;
- browser touch kept as UI input while mouse/pen may become semantic terminal mouse;
- bounded reconnect/telemetry state that never becomes terminal truth;
- terminal images and glyph resources following exact generation/residency contracts.

Browser pane/layout composition, if introduced, remains browser presentation state. It
does not create Server geometry or Session pane semantics.

## Gateway and delivery boundary

`gateway/` binds loopback, serves a closed static route table and bridges binary
WebSocket messages to one explicit upstream byte stream after forwarding the complete Server ready response. Public
identity remains an external delivery-edge concern such as Cloudflare Access; the
gateway's optional assertion check is only an origin-misrouting guard.

Chromium remains the fast browser acceptance lane. Safari/Home-Screen remains the
narrower WebKit/PWA platform canary. Neither browser is allowed to redefine terminal or
Server ownership.


All live command formats consume Render-owned native command projection through
the exact Server-forwarded `server_client_render_native` module. Web retains v2
object JSON, v3 positional JSON and its v4 binary packing. The v4 record is packed
field by field: its 64-byte layout differs from Render's 64-byte C record. One
native record on the stack supplies each command; no additional command array,
allocation or C call is introduced. Browser memory lanes, envelope formatting,
format negotiation, resource acknowledgement and UI remain host responsibilities.
Actual prior-Wasm v2/v3 JSON bytes, including text/cursor and external images, are
preserved. This is Node/Wasm contract qualification; browser/device deployment is
separate.

The freestanding wire wrapper uses the exact `server_client_byte` module for
split-frame assembly, attachment-ready validation, response correlation,
observation/image transactions and explicit claim-then-resize. This caller-driven
[byte client](../../mods/server/docs/byte-client.md) owns no socket or allocation.
Web retains rich semantic decoding and projection, its private ABI, fixed memory
budgets, four KiB input admission, phase/error policy and browser runtime. A
complete rejection may be reusable in the byte client while Web still applies
its existing close policy. The adapter adds no exports or memory lanes.
