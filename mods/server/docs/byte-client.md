# Caller-driven byte client

Select `server_client_byte` from this package, or use the exact same module through
`server_client.terminal.byte`. This is a Zig interface for one dedicated terminal
attachment. It imports the Server wire vocabulary; it does not import the native
transport, Server model, Instance, PTY, live VT or renderer.

The caller supplies stable `Storage` and four mutually disjoint byte buffers:
packet assembly, outgoing request, collected observation and selected-text/image
result. Construction checks their bounds and overlap, including overlap with
Storage, before initializing the opaque `ByteClient`. Construction leaves the byte
buffers untouched. There is no allocator, socket, clock, wait, worker, reconnect or
destructor. Storage size and alignment are module-owned and target-dependent;
callers must not persist or reinterpret its private bytes.

## Setup and driving

The carrier completes Server welcome and exact Instance attachment first. The
byte client starts at the common attachment-ready response, not at Server catalog
negotiation. Call `resetAwaitReady`, then supply ordered bytes to `feed`. The
`attached` event copies all accepted ready facts. The caller remains responsible
for comparing them with its selected target; the byte client validates wire
grammar and nonzero identities, not discovery or target policy. Web's gateway
already performs the exact target negotiation.

After attachment, start one typed request at a time. Send the borrowed
`outgoing()` bytes through the caller's carrier, then feed response bytes.
`feed` accepts arbitrary splits and returns a consumed count at the first
response event. Retain and re-feed the unconsumed suffix only after handling that
event. On `outgoing_followup`, send the newly staged request before continuing
receive; this implements the explicitly requested claim-then-resize exchange.
The byte client never chooses whether an application should claim geometry.

A complete recognized rejection is a `result` event and permits another request.
Malformed, mismatched, oversized or incomplete framed responses retire the
stream. Discard the stream on a receive error; no consumed count is promised on
failure. Invalid input aliases and calls in an invalid state consume nothing.
Invalid request starts leave state and byte buffers untouched.

`finish()` accepts EOF only between exchanges, with no partial frame. It closes
the logical stream and clears staged output. `retire()` abandons it without
releasing caller storage. `resetAwaitReady()` starts a fresh logical attachment
and invalidates all old response borrows. The caller serializes all calls and
keeps Storage and buffers at stable addresses throughout use.

## Buffer bounds and borrows

Packet and outgoing buffers must each fit at least a protocol header. A packet
buffer must also fit each complete received frame; a too-small buffer fails at
the decoded header. Request admission checks outgoing capacity before writing.
Observation and result buffers may be empty if their operations are unused.
Larger operations fail explicitly within caller capacity and protocol bounds.
A valid selected-text or image response exceeding result storage reports
`ResultTooSmall` and retires the stream. Invalid UTF-8 and mismatched image
identity retain their semantic errors; capacity does not stand in for corruption.

Incoming `feed` slices and `sendBytes` slices must not overlap Storage or any
supplied buffer. Borrowed selected text must be copied to independent input
storage before sending it back. This restriction keeps mutation and receive
aliasing explicit. Buffer contents may be inspected by the caller, but must not
be changed while a borrowed result is in use or a call is executing.

- `outgoing()` lasts until the next client mutation.
- `observationBytes()` is complete only after an `observation` event. It lasts
  until the next observation, reset, reinitialization or caller buffer write.
- A `text` event borrows copied UTF-8 from the result buffer, independently of
  the incoming slice. Copy it before a new text/image operation, reset,
  reinitialization or caller buffer write.
- An `image` event borrows the complete exact-generation image from result
  storage. Ordinary requests are blocked while it is held. `releaseImage()`,
  explicit replacement with `requestImage()`, reset or reinitialization ends
  that borrow. `image()` before completion reports staging only.
- Identity and interaction events are values. They do not borrow packet storage.

A response may have filled part of a buffer before a later error. Treat result
bytes as usable only after their successful completion event; receive failures
do not promise to undo partial staging.

## Observation validation

`collect` accepts the ordinary framed snapshot lane and returns its collected
frames. The caller must run `server_client.terminal.rich.decodeFrames` before
using terminal facts. Completion is not a claim that VT payloads are valid.

`live` additionally checks ordered begin/body/graphics/properties/end framing,
consistent body encoding, matching observation revisions and zero history
offset. It deliberately does not decode VT payloads. Web's renderer performs
that semantic decode on its own side of the boundary. Packed/delta cache
transactions and retained terminal requests remain separate existing native
client capabilities; this interface does not add them.

Committed byte input, paste, typed key/mouse/focus, interaction state, selected
text, image retrieval and resize use the Server-owned codecs. Byte input has the
protocol request ceiling, rather than Web's four KiB limit. UTF-8 admission for
committed input, application close/retry policy, rich projection, queues and
scheduling belong to the caller.

## Qualification

`zig build test:byte -Doptimize=ReleaseSafe` covers split-ready delivery, typed
admission, untouched rejected starts, copied results, response correlation,
claim/resize follow-up, image chunks, capacity, retirement and EOF. The package
check/test graph includes it. The distribution consumer proves exact module and
protocol type identity.

The Web wrapper retains its existing 56 exports, phase values, memory lanes and
application rejection policy. Actual old/new Wasm comparison and a private live
Server/PTY run qualify that adapter; these are Node/Wasm contract proofs,
separate from browser or device deployment.
