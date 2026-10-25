# Server terminal wire

The Server implementation owns this ordered-stream terminal protocol. It consumes
Instance semantic APIs; remote clients consume this wire package.

## Framing

Every message is one 12-byte header followed immediately by `payload_len`
payload bytes. There are no transport delimiters between frames.

| Offset | Bytes | Meaning |
| --- | ---: | --- |
| 0 | 4 | ASCII `SRVR` |
| 4 | 1 | framing version, currently `2` |
| 5 | 1 | frame kind |
| 6 | 2 | reserved, zero |
| 8 | 4 | payload length |

One frame payload is at most 1 MiB. The Server attachment accepts at most
64 KiB in one **client request** payload. A client must therefore keep every
outbound frame payload at or below 65,536 bytes even though response frames may
be larger. The encoded and decoded `text_v1` body is bounded to 4 MiB. A complete
Server observation additionally carries one graphics manifest of at most 857,116
bytes, one properties packet of at most 6,180 bytes, and bounded frame headers.
Exact image pixels use separate resource transactions.

Frame kinds are:

| Value | Kind | Direction |
| ---: | --- | --- |
| 32 | `observe` | client → endpoint |
| 33 | `snapshot_begin` | endpoint → client |
| 34 | `snapshot_data` | endpoint → client |
| 35 | `snapshot_end` | endpoint → client |
| 36 | `input` | client → endpoint |
| 37 | `assign_leader` | client → endpoint |
| 38 | `resize` | client → endpoint |
| 39 | `signal` | client → endpoint |
| 40 | `result` | endpoint → client |
| 41 | `interaction_state` | client → endpoint |
| 42 | `interaction_state_snapshot` | endpoint → client |
| 43 | `assign_consequence_leader` | client → endpoint |
| 44 | `consequence_observe` | client → endpoint |
| 45 | `consequence_begin` | endpoint → client |
| 46 | `consequence_data` | endpoint → client |
| 47 | `consequence_end` | endpoint → client |
| 48 | `consequence_consume` | client → endpoint |
| 49 | `consequence_reply` | client → endpoint |
| 50 | `text_extract` | client → endpoint |
| 51 | `text_extract_data` | endpoint → client |
| 52 | `snapshot_graphics` | endpoint → client |
| 53 | `image_request` | client → endpoint |
| 54 | `image_begin` | endpoint → client |
| 55 | `image_data` | endpoint → client |
| 56 | `image_end` | endpoint → client |
| 57 | `observe_raw` | client → endpoint |
| 58 | `snapshot_raw_data` | endpoint → client |
| 59 | `observe_delta` | client → endpoint |
| 60 | `snapshot_delta_data` | endpoint → client |
| 61 | `snapshot_properties` | endpoint → client |
| 62 | `observe_packed` | client → endpoint |
| 63 | `snapshot_packed_data` | endpoint → client |

Invalid magic, framing version, reserved header bits, frame kind, or a declared
payload above 1 MiB is a framing failure. The endpoint closes a connection on a
framing failure or an inbound request payload above 64 KiB.

## Attachment readiness

A new connection starts in Server control: empty `hello`, then `welcome` with the
Server's current status. The client validates the expected Server incarnation and
requests `attach_instance` with the exact nonzero Session and Instance IDs.
Successful admission returns one `attach_ready` payload, exactly 40 bytes:

| Offset | Bytes | Meaning |
| --- | ---: | --- |
| 0 | 8 | Server incarnation |
| 8 | 8 | Session identity |
| 16 | 8 | Instance identity |
| 24 | 8 | Server tree revision |
| 32 | 8 | attachment-local client identity |

All five fields are nonzero big-endian u64 values. This ready response completes
attachment construction for native and browser consumers. There is no terminal
hello or second welcome. The same stream is then dedicated to that exact Instance,
and accepts only the terminal kinds listed above. The Server queues ready before any
response to already-buffered terminal input.

Control uses kinds 1–13 and an 8 KiB payload ceiling. Terminal interaction uses
kinds 32–63 and a 1 MiB response ceiling; terminal requests remain at most 64 KiB.
Both phases use the same SRVR version 2 envelope. Wrong-phase kinds are framing
failures. Version 2 is the complete wire boundary; no legacy Server terminal decoder is kept.

The client identity lasts only for this attachment, including explicit geometry
or consequence leadership. Detaching releases that authority and the stream;
the Server's Instance and PTY/VT remain alive. Explicit Instance close ends their
lifetime. Separate catalog/CRUD connections remain Server control connections.

## Interaction state

Some terminal modes do not alter visible cells but do alter how the same next
semantic input is encoded. A client may therefore send an empty
`interaction_state` frame to observe that coherent mode-directed state without
perturbing the terminal. This is semantic state, not a second snapshot format.

The endpoint replies with one `interaction_state_snapshot` payload of exactly 20
bytes:

| Offset | Bytes | Meaning |
| --- | ---: | --- |
| 0 | 8 | canonical `terminal_revision` at which this state was copied |
| 8 | 4 | interaction boolean flags below |
| 12 | 1 | mouse tracking: `0=off`, `1=x10`, `2=normal`, `3=button_event`, `4=any_event` |
| 13 | 1 | mouse protocol: `0=none`, `1=utf8`, `2=sgr`, `3=sgr_pixel`, `4=urxvt` |
| 14 | 1 | signed `modify_other_keys` state, two's-complement `i8` |
| 15 | 1 | active-screen Kitty keyboard flags, high bit reserved zero |
| 16 | 2 | xterm key-format resource 4 value |
| 18 | 1 | xterm pointer mode, `0..3` |
| 19 | 1 | reserved, zero |

The flags word uses these bits:

| Bit | Meaning |
| ---: | --- |
| 0 | keyboard action mode |
| 1 | auto repeat |
| 2 | newline mode |
| 3 | application cursor keys |
| 4 | application keypad |
| 5 | Meta sends Escape |
| 6 | report key-up |
| 7 | bracketed paste |
| 8 | focus reporting |
| 9 | termios signals |
| 10 | alternate scroll |
| 11 | paste events |
| 12 | in-band resize notifications |

Bits 13..31 are reserved and must be zero.

## Host consequences

VT retains caller-neutral protocol consequences in one bounded global order. Server terminal
allows one explicit consequence authority to observe that order and either consume an
occurrence or provide a typed reply. When no client owns consequence authority,
Instance applies a deterministic headless policy so canonical PTY/VT progress never
waits for presentation policy:

| Consequence | Headless Instance policy |
| --- | --- |
| clipboard query | reply with empty clipboard content |
| clipboard set/other | consume |
| notification | consume |
| pointer-shape query | reply `default` |
| pointer-shape set/other | consume |
| file transfer | consume |
| drag/drop | consume |
| container screen-cell query | reply with current canonical rows/columns |
| container state/position/icon-title query | decline |
| other container intent | consume |
| color-preference query | reply `dark` |
| media copy, bell, legacy control, DCS, string control | consume |

`server_client.terminal.consequences` exposes the authority/observe/consume/reply mechanism but
does not choose host policy. A direct `howl-vt` embedder that bypasses Instance owns
its own consequence policy; VT itself never opens files, steals focus, accesses a
clipboard, or performs another host side effect.

## Observation model

Observation is request-driven. A client has at most one outstanding observation
request: ordinary `observe`, complete `observe_raw`, revision-relative
`observe_delta`, or complete packed `observe_packed`. There is no server-side
stream queue per observer, so a slow observer never paces the PTY or canonical
VT.

All four observation requests use the same 12-byte payload:

| Offset | Bytes | Meaning |
| --- | ---: | --- |
| 0 | 8 | `after_revision` |
| 8 | 4 | requested `history_offset` |

`after_revision = 0` always requests an immediate snapshot. Otherwise the
endpoint waits while the current observation revision is less than or equal to
`after_revision`, and responds when a newer revision exists. Asking for a
revision newer than the endpoint currently owns is malformed.

The requested history offset is clamped to canonical retained history. The
snapshot reports the effective history offset actually used.

Each observation is:

1. one `snapshot_begin`;
2. one or more text transport chunks: `snapshot_data` for `observe`,
   `snapshot_raw_data` for complete raw/fallback responses,
   `snapshot_delta_data` for an accepted revision-relative delta, or
   `snapshot_packed_data` for `observe_packed`;
3. one `snapshot_graphics` manifest;
4. one `snapshot_properties` frame from the same immutable cut;
5. one `snapshot_end` with the same observation revision.

A single snapshot never mixes compressed, raw, delta, and packed text chunks. The endpoint
materializes the coherent snapshot before emitting `snapshot_begin`. PTY/VT
progress may continue while those already-copied bytes drain to the observer.

`observe` is the ordinary transport and keeps the bounded zlib/DEFLATE envelope.
`observe_raw` remains the complete standalone raw lane: it changes only the
text transport envelope; snapshot semantics, history selection, graphics
manifests, revisions, and `text_v1` records are identical.

`observe_packed` is the Server v2 complete carriage lane used by maintained
managed/mobile clients. It does not define a second terminal model. The endpoint
losslessly packs the exact complete `text_v1` body by preserving record headers,
carrying presentation/hyperlink records verbatim, and replacing repeated complete
row-cell attribute headers with consecutive attribute runs. Rows that would grow
fall back independently to verbatim payloads. The packed bytes are compressed with
fastest zlib/DEFLATE. The client inflates and unpacks them back to byte-identical
`text_v1` before the existing semantic decoder runs.

`observe_delta` is the framing-v7 revision-relative lane. Its `after_revision`
names the caller's exact baseline. If the endpoint cannot prove that baseline
against its bounded row mirror, it responds with ordinary `snapshot_raw_data`;
that fallback is a complete standalone `text_v1` snapshot. When the baseline is
proven, the endpoint may instead emit `snapshot_delta_data` carrying
`text_delta_v2`. The endpoint retains one bounded delta-row baseline total, not
one copy per client. A valid client baseline can therefore still receive a
complete raw fallback when another delta observer has advanced or replaced the
endpoint cache; clients must treat that fallback as the normal resynchronization
path. There is still no feature negotiation.

### `snapshot_begin`

The payload is exactly 38 bytes:

| Offset | Bytes | Meaning |
| --- | ---: | --- |
| 0 | 8 | observation `revision` |
| 8 | 8 | canonical terminal semantic `terminal_revision` |
| 16 | 4 | effective history offset |
| 20 | 4 | total retained history row count |
| 24 | 4 | history row base |
| 28 | 2 | rows in this snapshot |
| 30 | 2 | canonical columns |
| 32 | 2 | cursor row |
| 34 | 2 | cursor column |
| 36 | 1 | cursor shape |
| 37 | 1 | flags |

Cursor shapes emitted today are `0=block`, `1=underline`, `2=bar`, `3=none`.
Clients should render an unknown future shape with a safe fallback rather than
rejecting an otherwise valid snapshot.

Flag byte bits are:

| Bit | Meaning |
| ---: | --- |
| 0 | cursor visible |
| 1 | cursor blink enabled |
| 2 | alternate screen active |
| 3 | PTY stream closed |
| 4 | child exited |
| 5 | a resize leader exists |
| 6 | this client is the resize leader |
| 7 | reserved, zero |

`snapshot_end` is exactly eight bytes containing the observation revision from
`snapshot_begin`.

## `text_v1`

`text_v1` remains the frozen renderer-neutral terminal-text representation.
There are no font file names, glyph ids, GPU objects, Flutter types, or
window-system concepts on this wire. Framing v4 added terminal graphics beside
it rather than changing its record grammar. Framing v5 added a raw transport lane without changing the `text_v1` record
grammar. Framing v7 added explicit revision-relative `text_delta_v2` beside the
unchanged complete representation. Framing v10 adds lossless `text_pack_v1`
carriage for complete snapshots while keeping `text_v1` byte-for-byte frozen.

For ordinary `observe`, the `snapshot_data` payloads are transport chunks only.
Concatenate them in order. The resulting bytes are:

| Offset | Bytes | Meaning |
| --- | ---: | --- |
| 0 | 4 | exact uncompressed body byte count, big-endian `u32` |
| 4 | variable | one zlib/DEFLATE stream containing the complete semantic body |

The declared uncompressed body is bounded to 4 MiB before allocation. The zlib
stream must finish exactly, with no trailing or unconsumed bytes, and inflate to
exactly the declared length. Every compressed snapshot is independently
decompressible; no previous client revision is needed to recover or validate it.

For `observe_packed`, concatenate `snapshot_packed_data` payloads in order.
The resulting bytes begin with an eight-byte big-endian prefix:

| Offset | Bytes | Meaning |
| --- | ---: | --- |
| 0 | 4 | exact reconstructed `text_v1` byte count |
| 4 | 4 | exact uncompressed `text_pack_v1` byte count |
| 8 | variable | one zlib/DEFLATE stream containing packed carriage bytes |

The zlib stream must finish exactly and inflate to the declared packed size. The
packed body must then reconstruct exactly the declared bounded `text_v1` size.
Presentation and hyperlink records are preserved verbatim. Each row preserves its
original `text_v1` record header and uses either a verbatim row payload or exact
consecutive 34-byte attribute runs followed by each cell's scalar count/scalars.
The unpacker rejects zero/overflowing runs, truncation, scalar-count overflow,
record-length mismatch, trailing bytes, and any delta-only row-shift record.
Only after this reconstruction does the ordinary `text_v1` decoder run.

For `observe_raw` or a delta fallback, concatenate the `snapshot_raw_data`
payloads in order. Those bytes are the complete bounded `text_v1` record body
directly, with no four-byte length prefix and no zlib stream. An empty or
larger-than-4-MiB raw body is invalid. Compression is therefore a transport
choice, not part of the semantic `text_v1` grammar.

For an accepted `observe_delta`, concatenate `snapshot_delta_data` payloads in
order. The resulting bounded `text_delta_v2` body uses the same presentation,
row, and hyperlink record headers as `text_v1`, plus exactly one delta-only
`row_shift` record after presentation and before the first row. Its two-byte
big-endian payload is the number of visible rows by which the exact
`after_revision` baseline moves upward before row reuse is interpreted. Zero
means no viewport movement; a positive shift must be smaller than the visible
row count. After applying that rotation, a row record with zero payload means
"reuse this same visible row from the rotated baseline." A newly exposed row
therefore has no reusable source and must be sent in full. Zero-payload rows and
`row_shift` records are invalid in complete `text_v1`. Presentation and
hyperlink resolver records remain complete on every delta, and a client must
reject delta data unless it owns the exact requested baseline revision, history
offset, and geometry.

After inflation or direct raw assembly, the body is a concatenation of
self-delimiting records. The eight-byte record header is:

| Offset | Bytes | Meaning |
| --- | ---: | --- |
| 0 | 1 | record kind: `1=presentation`, `2=row`, `3=hyperlink`, `4=row_shift` (delta only) |
| 1 | 3 | reserved, zero |
| 4 | 4 | record payload length |

Records may cross `snapshot_data`, `snapshot_raw_data`, `snapshot_packed_data`, or
`snapshot_delta_data` transport-chunk boundaries because those boundaries have
no semantic meaning. Complete `text_v1` order is exactly one presentation
record, exactly `snapshot_begin.rows` row records, then zero or more hyperlink
resolver records. `text_delta_v2` inserts exactly one `row_shift` record between
presentation and rows. Every nonzero hyperlink id referenced by a row must
resolve exactly once before `snapshot_end`.

### Presentation record

The presentation payload is exactly 1,060 bytes:

| Offset | Bytes | Meaning |
| --- | ---: | --- |
| 0 | 8 | cursor age in nanoseconds |
| 8 | 1 | optional-color presence bits |
| 9 | 1 | presentation flags |
| 10 | 2 | reserved, zero |
| 12 | 1024 | 256 RGBA palette entries, four bytes each |
| 1036 | 4 | default foreground RGBA |
| 1040 | 4 | default background RGBA |
| 1044 | 4 | cursor RGBA slot |
| 1048 | 4 | cursor-text RGBA slot |
| 1052 | 4 | selection-background RGBA slot |
| 1056 | 4 | selection-foreground RGBA slot |

Cursor age uses `0xffffffffffffffff` when no absolute cursor movement timestamp
is tracked. Otherwise it is an age observed on the instance node, so it remains
meaningful to a client with a different monotonic clock origin.

Optional-color presence bits are cursor `0x01`, cursor text `0x02`, selection
background `0x04`, and selection foreground `0x08`. Ignore an optional RGBA slot
when its presence bit is clear. Presentation flag `0x01` means DEC reverse-screen
mode; all other presentation flag bits are reserved.

### Row and cell records

A row starts with a four-byte prefix: wrapped, DEC line geometry, and exact
canonical column count. It is followed by exactly one cell entry for each
canonical column.

Each cell has a fixed 35-byte prefix followed by `scalar_count` four-byte Unicode
scalars:

| Offset | Bytes | Meaning |
| --- | ---: | --- |
| 0 | 1 | scalar count, `0..24` |
| 1 | 1 | multicell width, nonzero |
| 2 | 1 | multicell height, nonzero |
| 3 | 1 | multicell x, `< width` |
| 4 | 1 | multicell y, `< height` |
| 5 | 1 | retained OSC 66 subscale numerator, `0..15` |
| 6 | 1 | retained OSC 66 subscale denominator, `0..15` |
| 7 | 1 | retained OSC 66 vertical-align value, `0..3` |
| 8 | 1 | retained OSC 66 horizontal-align value, `0..3` |
| 9 | 1 | semantic-width flag, `0` or `1` |
| 10 | 1 | retained terminal font slot, `0..15` |
| 11 | 1 | baseline: `0=normal`, `1=raised`, `2=lowered` |
| 12 | 1 | underline style: straight/double/curly/dotted/dashed = `0..4` |
| 13 | 1 | protection: `0=none`, `1=iso`, `2=dec` |
| 14 | 2 | style bit mask |
| 16 | 5 | foreground semantic color |
| 21 | 5 | background semantic color |
| 26 | 5 | underline semantic color |
| 31 | 4 | hyperlink id, zero means none |
| 35 | `scalar_count × 4` | Unicode scalars |

Style bits are:

| Bit | Mask | Meaning |
| ---: | ---: | --- |
| 0 | `0x001` | bold |
| 1 | `0x002` | dim |
| 2 | `0x004` | italic |
| 3 | `0x008` | blink |
| 4 | `0x010` | fast blink |
| 5 | `0x020` | reverse cell colors |
| 6 | `0x040` | invisible |
| 7 | `0x080` | underline |
| 8 | `0x100` | strikethrough |

Bits above `0x100` are reserved in `text_v1`.

A semantic color is five bytes: one-byte kind followed by a four-byte value.
Kind `0=default` requires value zero. Kind `1=indexed` permits `0..255`. Kind
`2=rgb` uses the low 24 bits as `0xRRGGBB` and requires the high byte to be zero.

Only the lead coordinate of a grapheme/multicell rectangle carries scalars.
Continuation coordinates (`x != 0` or `y != 0`) carry `scalar_count = 0`.
This prevents duplicate graphemes for wide and OSC 66 cells. Blank lead cells
may also have zero scalars.

### Hyperlink resolver records

The payload is:

| Offset | Bytes | Meaning |
| --- | ---: | --- |
| 0 | 4 | link id, `1..4096` |
| 4 | 2 | URI byte length, `1..2048` |
| 6 | variable | exact URI bytes |

Only hyperlink ids referenced by rows are emitted. Clients should therefore
build the resolver table per snapshot rather than assuming a node-global table.

## `graphics_v2` manifest and image resources

Terminal image pixels do not belong inside `text_v1` or the 4 MiB text snapshot
body. The canonical VT may retain one decoded RGBA image up to 16 MiB, so
copying image bytes into every observation could not be complete within the
snapshot bound and would retransmit unchanged content unnecessarily.

Every observation includes exactly one `snapshot_graphics` frame after the final
text-data chunk. In v10 it is followed by exactly one `snapshot_properties` frame,
then `snapshot_end`. The graphics payload is
one 28-byte header, zero or more 20-byte image descriptors, then zero or more
52-byte visible placements. The complete manifest always fits in one ordinary
response frame.

The manifest header is:

| Offset | Bytes | Meaning |
| --- | ---: | --- |
| 0 | 8 | image-plane generation |
| 8 | 8 | image-content generation |
| 16 | 4 | canonical terminal cell pixel width |
| 20 | 4 | canonical terminal cell pixel height |
| 24 | 2 | referenced image descriptor count, `0..256` |
| 26 | 2 | visible placement count, `0..16384` |

The cell-pixel dimensions belong to the canonical Instance graphics lattice,
not to any one attached client's font or display. Image placement pixel fields
are expressed in that stable lattice. A graphical client scales them into its
own presentation lattice while preserving terminal cell anchors and source
pixel rectangles.

Only images referenced by a placement visible in the selected snapshot
viewport are described. One image descriptor is:

| Offset | Bytes | Meaning |
| --- | ---: | --- |
| 0 | 4 | nonzero canonical image id |
| 4 | 8 | nonzero exact content generation |
| 12 | 4 | decoded pixel width, `1..4096` |
| 16 | 4 | decoded pixel height, `1..4096` |

One placement is:

| Offset | Bytes | Meaning |
| --- | ---: | --- |
| 0 | 4 | referenced image id |
| 4 | 8 | nonzero placement generation |
| 12 | 2 | viewport row |
| 14 | 2 | physical terminal column |
| 16 | 4 | source x in decoded pixels |
| 20 | 4 | source y in decoded pixels |
| 24 | 4 | source width in decoded pixels |
| 28 | 4 | source height in decoded pixels |
| 32 | 4 | destination x offset within anchor cell |
| 36 | 4 | destination y offset within anchor cell |
| 40 | 4 | destination pixel width |
| 44 | 4 | destination pixel height |
| 48 | 4 | signed z order |

The source rectangle must lie inside the referenced image. Placement row and
column must lie inside `snapshot_begin` geometry. Every descriptor must be
referenced by at least one visible placement.

Pixels are demand-driven. A client sends one 12-byte `image_request` containing
image id followed by content generation. For each client, the endpoint retains
the exact visible image generations named by that client's most recently
delivered snapshot until it delivers that client a newer snapshot. A request is
therefore valid even if the canonical VT has already advanced past that image;
`result/rejected` means the generation belongs to neither current canonical
state nor that client's latest delivered snapshot. A successful request returns:

1. `image_begin`, 24 bytes: id, generation, width, height, and exact RGBA8 byte
   count;
2. one or more nonempty `image_data` frames, each at most 256 KiB;
3. `image_end`, 12 bytes repeating id and generation.

The declared byte count must equal `width × height × 4` and is bounded to 16
MiB. Image fetches are read-only: they do not advance terminal semantic or
observation revision. A graphical client owns cache/residency policy and should
reuse an already-fetched `image_id + generation` until a later manifest names a
different content generation.

## Input

Every `input` frame begins with a one-byte input kind:

| Value | Kind |
| ---: | --- |
| 1 | raw bytes |
| 2 | paste |
| 3 | physical key |
| 4 | mouse |
| 5 | focus |

Raw bytes are the explicit exact-byte input lane and are passed unchanged to
the canonical input owner. Paste is semantic input: the remaining payload is exact paste
content, and the canonical VT decides whether bracketed-paste framing applies.

For key, mouse, and focus events, **the client sends physical meaning, not
terminal escape sequences**. The canonical `howl-vt` on the instance node owns
application cursor/keypad modes, modifyOtherKeys, Kitty keyboard flags, mouse
protocols, focus reporting, bracketed paste, and every other mode-sensitive
encoding decision.

### Physical key body

After input kind `3`, the fixed key header is 20 bytes followed by exact legacy
bytes and committed UTF-8 text:

| Offset | Bytes | Meaning |
| --- | ---: | --- |
| 0 | 1 | key identity kind: `1=named`, `2=unicode` |
| 1 | 1 | action: `1=press`, `2=repeat`, `3=release` |
| 2 | 1 | modifier bits |
| 3 | 1 | optional-scalar presence bits |
| 4 | 4 | named-key number or Unicode scalar |
| 8 | 4 | shifted Unicode scalar, or zero if absent |
| 12 | 4 | alternate-layout Unicode scalar, or zero if absent |
| 16 | 2 | legacy byte length, `0..511` |
| 18 | 2 | committed UTF-8 byte length, `0..64` |
| 20 | variable | legacy bytes, then committed UTF-8 bytes |

Presence bit `0x01` means the shifted scalar is present; `0x02` means the
alternate-layout scalar is present. When a presence bit is clear, its four-byte
storage must be zero. Unicode values must be valid scalar values, never surrogate
halves.

The 511-byte legacy ceiling is deliberate. The canonical VT owns a 512-byte key
scratch and may need to prepend one ESC for Meta behavior. Do not raise this
limit to 512 in a client.

Modifier bits are shift `0x01`, alt `0x02`, control `0x04`, super `0x08`, hyper
`0x10`, meta `0x20`, caps lock `0x40`, and num lock `0x80`. All eight bits are
defined.

Named-key numbers are frozen as follows:

| Value | Name | Value | Name |
| ---: | --- | ---: | --- |
| 1 | enter | 30 | f2 |
| 2 | tab | 31 | f3 |
| 3 | backspace | 32 | f4 |
| 4 | escape | 33 | f5 |
| 5 | up | 34 | f6 |
| 6 | down | 35 | f7 |
| 7 | left | 36 | f8 |
| 8 | right | 37 | f9 |
| 9 | insert | 38 | f10 |
| 10 | delete | 39 | f11 |
| 11 | home | 40 | f12 |
| 12 | end | 41 | keypad_0 |
| 13 | page_up | 42 | keypad_1 |
| 14 | page_down | 43 | keypad_2 |
| 15 | left_shift | 44 | keypad_3 |
| 16 | right_shift | 45 | keypad_4 |
| 17 | left_control | 46 | keypad_5 |
| 18 | right_control | 47 | keypad_6 |
| 19 | left_alt | 48 | keypad_7 |
| 20 | right_alt | 49 | keypad_8 |
| 21 | left_super | 50 | keypad_9 |
| 22 | right_super | 51 | keypad_decimal |
| 23 | left_hyper | 52 | keypad_add |
| 24 | right_hyper | 53 | keypad_subtract |
| 25 | left_meta | 54 | keypad_multiply |
| 26 | right_meta | 55 | keypad_divide |
| 27 | caps_lock | 56 | keypad_separator |
| 28 | num_lock | 57 | keypad_equal |
| 29 | f1 | 58 | keypad_enter |

`legacy_text` is an exact byte sequence supplied by the platform key system for
legacy terminal behavior. It may contain ESC or C0 bytes and is not UTF-8
validated. `text` is committed text for extended keyboard protocols and must be
valid UTF-8. Either may be empty.

### Mouse body

After input kind `4`, the mouse body is exactly 19 bytes:

| Offset | Bytes | Meaning |
| --- | ---: | --- |
| 0 | 1 | event kind: `1=press`, `2=release`, `3=move`, `4=wheel` |
| 1 | 1 | button: none/left/middle/right/wheel_up/wheel_down = `0..5` |
| 2 | 1 | modifier bits, same as key input |
| 3 | 1 | held-button mask; only low three bits are valid |
| 4 | 4 | signed big-endian `i32` cell row |
| 8 | 2 | cell column |
| 10 | 1 | presence; bit `0x01` means both pixel coordinates are present |
| 11 | 4 | pixel x, or zero when absent |
| 15 | 4 | pixel y, or zero when absent |

Pixel x and y are an all-or-nothing pair. When presence bit `0x01` is clear,
both stored values must be zero. The VT decides whether the active mouse mode
uses cell coordinates, pixel coordinates, or no report at all.

### Focus body

After input kind `5`, exactly one byte follows: `1=focus in`, `2=focus out`.
The VT emits no terminal bytes when focus reporting is disabled by the child.

## Selected-text extraction

Selection state remains entirely client-local. A client that wants canonical UTF-8 for an
inclusive terminal-cell range sends `text_extract`; the endpoint does not retain, mutate,
or authorize a selection. Rows are stable projected history-and-screen identities, not
indices into whichever scrollback snapshot the client currently displays.

`text_extract` is exactly 16 bytes: `start.row:i32`, `start.column:u16`,
`end.row:i32`, `end.column:u16`, expected `columns:u16`, `alternate_screen:u8`,
and one reserved-zero byte, all multi-byte fields big-endian. The endpoint rejects a bank or
column-geometry mismatch so a remote resize/screen-switch race cannot retarget a selection. The endpoint orders reversed ranges,
resolves retained history plus the active screen, joins soft-wrapped rows without inventing
a newline, emits complete retained grapheme scalars once per lead cell, and projects SGR
concealed cells as blanks. An endpoint that has been evicted from the bounded history ring
or is outside canonical columns rejects the request rather than returning partial text.

A successful request returns one `text_extract_data` frame containing bounded UTF-8, at
most the ordinary 1 MiB response-frame ceiling. Extraction is read-only and does not change
the terminal or observation revision.

## Placement bounds introduced in framing v8

Framing v8 introduced the pixel-geometry/placement changes retained by v10.
Current clients and endpoints must both use v10; mismatched headers are rejected
rather than falling back to an older grammar.
The image byte format remains exact RGBA8. The placement ceiling is 16,384
independent identities to accommodate cell-tiled previews. The largest graphics
manifest is 857,116 bytes, within the unchanged 1 MiB frame ceiling. Renderer
command, client projection and native/Web packet bounds are tested together.
The decoded-image quota remains 64 MiB per VT; a larger placement catalogue does
not increase image-pixel storage or merge replacement/deletion identities.

## Framing v9 coherent terminal properties (retained by v10)

Every compressed, raw, delta, or packed snapshot includes exactly one
`snapshot_properties` frame after `snapshot_graphics` and before `snapshot_end`.
It belongs to the same immutable cut and needs no second query or title socket.
Metadata-only mutation wakes ordinary observers; a new attachment receives the
current values. Missing, duplicate, malformed or wrongly ordered packets fail validation.
Historical v8/v9 bundles must be rebuilt as matching bundles; current peers use
one exact Server v2 boundary.

The payload is `properties_v1`, at most 6,180 bytes. Multi-byte fields are big-endian.

| Offset | Bytes | Meaning |
| --- | ---: | --- |
| 0 | 1 | property format version, `1` |
| 1 | 1 | presence bits: title, icon, directory, remote host, shell, shell name, mark status; top bit reserved |
| 2 | 1 | directory interpretation: absent `0`, URI `1`, path `2` |
| 3 | 1 | latest shell mark: absent `0`, or ASCII A/B/C/D |
| 4 | 4 | shell integration version; zero when absent |
| 8 | 8 | shell-mark generation; zero when absent |
| 16 | 4 | signed shell exit status; zero bytes when absent, permitted only for mark D |
| 20 | 1 | progress state: none `0`, normal `1`, failure `2`, indeterminate `3`, paused `4` |
| 21 | 1 | progress percentage `0..100`; zero for none/indeterminate |
| 22 | 2 | reserved, zero |
| 24 | 12 | six unsigned 16-bit byte lengths |
| 36 | variable | title, icon, directory, remote host, shell name, shell-mark metadata, concatenated |

Each string is bounded to 1,024 bytes. Presence bits distinguish missing properties
from explicitly reported empty strings. Bytes are preserved exactly, including
invalid UTF-8; a desktop must validate/sanitize its label projection instead of
rewriting canonical state. A directory, title or remote-host report conveys no
permission to execute a command, open a resource, change cwd, or change ownership.
The shell mark is not the Instance child-process lifecycle.

OSC `9;4` progress is retained state, not a queued notification. Normal progress
requires a percentage. Failure/paused updates without a percentage retain the
previous value; clear/indeterminate normalize it to zero. Invalid states, extra
fields and out-of-range percentages are ignored. Ordinary OSC9 notifications keep
their existing consequence path. Terminal reset clears progress. Clients may
choose a presentation but do not invent a second terminal-animation clock.

The image and text resource bounds are unchanged; the observation byte envelope
includes one additional bounded properties frame. The native client preserves
properties in owning, cached and coarse immutable snapshots. The rich CLI emits
readable title/progress plus a lossless `packet_hex` for all properties.

## Resize leadership

Geometry has one optional explicit leader. Attach does not resize and does not
elect a leader. There is no fallback election and no largest-viewport rule.

`assign_leader` is exactly eight bytes containing a client id. Client id zero
clears leadership. A nonzero id must name an attached client or the endpoint
returns `no_such_client`.

Framing v8 `resize` is exactly eight big-endian bytes: rows `u16`, columns `u16`,
cell-pixel width `u16`, and cell-pixel height `u16`. A zero pixel pair preserves
accepted metrics; a mixed zero/nonzero pair is malformed. Nonzero metrics update
VT geometry/replies and PTY `TIOCSWINSZ` pixel extents together. Pixel products
must fit the native unsigned 16-bit PTY extents; overflow is rejected without
changing either owner. Pixel-only changes publish a new canonical revision and
in-band resize reports use the newly committed metrics.

Only the current leader may change canonical PTY geometry.
A nonleader receives `not_leader`. If the leader disconnects, leadership becomes
empty and the last canonical geometry remains unchanged.

## Signals and results

`signal` is one byte. Defined values are:

| Value | Signal |
| ---: | --- |
| 1 | hangup |
| 2 | interrupt |
| 3 | resize_notify |
| 9 | kill |
| 15 | terminate |

The instance translates these semantic values to the node process-group boundary;
host-specific errno values never cross the wire.

`result` is exactly two bytes: the original frame kind, then a result code:

| Value | Result |
| ---: | --- |
| 0 | ok |
| 1 | malformed |
| 2 | unsupported |
| 3 | no_such_client |
| 4 | not_leader |
| 5 | rejected |

Malformed post-handshake commands are reported as bounded semantic results where
the endpoint can safely retain the connection. Recognized request families that
the endpoint does not implement return `unsupported`. Framing/attach failures
are connection-level failures instead.

## Ownership rules for a client implementation

A client owns framing, connection-local state, UI-local state, and physical input capture.
The instance node owns the PTY, canonical VT, terminal protocol modes, process
lifecycle, canonical geometry, and deterministic host consequences. Presentation
code may shape and draw `text_v1`, but must not reinterpret terminal modes or
write PTY escape bytes for typed input.

The minimal client implementation order is:

1. stream-safe 12-byte frame reader/writer and frame-version validation;
2. empty `hello`, `welcome`, and connection-local client identity;
3. request-driven `observe`, complete `observe_raw`, or revision-relative
   `observe_delta`, with `text_v1` / `text_delta_v2` decoding;
4. semantic key/mouse/focus plus paste/raw-byte input;
5. explicit resize leadership, history offsets, and interaction-state queries as needed.

Before connecting a new language implementation, run the independent corpus:

```sh
cd mods/server
python3 tools/validate_vectors.py protocol/vectors.json
```

The validator is build-time evidence only. Python is not a Howl runtime
dependency.
