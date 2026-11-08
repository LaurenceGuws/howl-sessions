# Server Client Render

An independently versioned adapter from immutable Server Client terminal views
to canonical Howl Render. It owns no Server, Instance, VT, network connection,
window, platform UI, or extra terminal semantics.

Render owns glyph shaping, atlas and frame construction. The consumer owns its
presentation and backend residency. The adapter's public Zig module is
server_client_render; the native Render record vocabulary is forwarded from
the exact Howl Render dependency.

The native C owner is compositional: one dynamic artifact exports the Server
Client ABI and the Render adapter ABI together. It never loads or casts an
opaque snapshot from a different copy of Server Client. The C side receives
the exact canonical Howl Render frame records, and a frame owns its copied
commands/pixels until release. The snapshot is borrowed only during capture.

The native ABI v1 retains its original single-face `hsr_create` constructor.
`hsr_create_family` additionally accepts regular, italic, bold and bold-italic
faces, each with up to 24 ordered fallback paths. Regular is required; absent
optional faces follow canonical Render fallback. Regular metrics fix the grid,
and all C family faces use one pixel size. Font paths are copied during the call;
failed construction releases staged faces. Each renderer admits one frame. Scratch grows to finite command/atlas limits. It rejects graphics
manifests explicitly until the separate image-fetch/resource-binding lane is
wired. The Flutter host now builds with this composed library and paints copied
canonical commands on Canvas. The Dart binding owns native record layout;
Flutter owns image decoding and actual backend residency. Android live Canvas,
iOS packaging and graphics fetching are still pending. Hosts must opt into the
family constructor to supply explicit style faces.

The workspace composes the sibling Server Client. Release archives replace that
path with an exact published URL/hash. Package versions and ABI v1 are distinct:
the family constructor adds a symbol and record without changing old layouts or
single-face behavior; old binaries do not provide the new symbol.
