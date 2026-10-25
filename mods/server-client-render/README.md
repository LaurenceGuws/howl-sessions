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

The current native slice admits a primary font and up to 24 fallbacks, plus
one frame per renderer. Scratch grows to finite command/atlas limits. It rejects graphics
manifests explicitly until the separate image-fetch/resource-binding lane is
wired. The Flutter host now builds with this composed library and paints copied
canonical commands on Canvas. The Dart binding owns native record layout;
Flutter owns image decoding and actual backend residency. Android live Canvas,
iOS packaging, font-style variants and graphics fetching are still pending.

This package starts at 0.1.0-dev. It currently depends on the sibling Server
Client package until independently releasable archives are qualified.
