//! Server-framed observations over VT-owned terminal text values.
//!
//! Server framing, request correlation, lifecycle and authority stay here.
//! The optional VT codec owns text decoding and retained rows, scalars and links;
//! this receiver chooses no renderer, CLI schema, font or platform presentation.

const std = @import("std");
const protocol = @import("server_protocol").terminal;
const codec = @import("howl_vt_codec");
const decodeGraphics = codec.decoded.decodeGraphics;
const deinitRows = codec.decoded.deinitRows;
const client = @import("terminal_owner");

/// Reports transport, framing, allocation, and rich-snapshot validation failures.
pub const Error = client.Error || std.mem.Allocator.Error || protocol.PayloadError || error{
    UnexpectedFrame,
    SnapshotTooLarge,
    InvalidSnapshot,
    ObservationPending,
    DeltaBaselineMismatch,
};

/// VT-owned lossless observation value.
pub const Rgba = codec.Rgba;
/// VT-owned lossless observation value.
pub const Presentation = codec.Presentation;
/// VT-owned lossless observation value.
pub const Cell = codec.Cell;
/// VT-owned lossless observation value.
pub const Row = codec.Row;
/// VT-owned lossless observation value.
pub const Hyperlink = codec.Hyperlink;
/// VT-owned lossless observation value.
pub const Graphics = codec.Graphics;

/// Owns one complete lossless rich terminal snapshot.
pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    begin: protocol.SnapshotBegin,
    presentation: Presentation,
    rows: []Row,
    hyperlinks: []Hyperlink,
    graphics: Graphics = .{},
    properties: protocol.properties.View = .{},
    properties_storage: []u8 = &.{},

    /// Borrows this owned snapshot through the common immutable rich-view contract.
    pub fn view(self: *const Snapshot) View {
        return .{
            .begin = self.begin,
            .presentation = self.presentation,
            .rows = self.rows,
            .hyperlinks = self.hyperlinks,
            .graphics = self.graphics,
            .properties = self.properties,
            .changed_rows = null,
            .changed_rows_base_revision = null,
            .row_shift = null,
        };
    }

    /// Releases every row, scalar, hyperlink, graphics, and property allocation.
    pub fn deinit(self: *Snapshot) void {
        deinitRows(self.allocator, self.rows);
        self.allocator.free(self.rows);
        for (self.hyperlinks) |link| self.allocator.free(link.uri_bytes);
        self.allocator.free(self.hyperlinks);
        self.graphics.deinit(self.allocator);
        self.allocator.free(self.properties_storage);
        self.* = undefined;
    }
};

/// Borrows one complete decoded rich snapshot from a reusable raw-observation cache.
///
/// Every slice remains valid only until the owning `RawCache` receives again or
/// is deinitialized. Instance remains canonical; `changed_rows` reports only
/// exact encoded-row record inequality against the cache's previous accepted cut.
pub const View = struct {
    begin: protocol.SnapshotBegin,
    presentation: Presentation,
    rows: []const Row,
    hyperlinks: []const Hyperlink,
    graphics: Graphics,
    properties: protocol.properties.View = .{},
    /// Exact changed-row mask when supplied by a reusable raw cache. `null`
    /// means callers must treat every row as potentially changed.
    changed_rows: ?[]const bool = null,
    /// Observation revision whose retained rows were compared to produce
    /// `changed_rows`. `null` means the mask has no reusable predecessor.
    changed_rows_base_revision: ?u64 = null,
    /// Explicit framing-v7 upward baseline rotation applied before row reuse.
    row_shift: ?u16 = null,
};

const CacheBaseline = struct {
    revision: u64,
    history_offset: u32,
};

/// Reuses already-validated row facts across framing-v7 raw/delta observations.
///
/// Complete raw snapshots establish a standalone baseline. Explicit delta bodies
/// may then reuse rows from the exact revision named by the ordered request; full
/// row records are still compared byte-for-byte and decoded only when changed.
/// Geometry changes invalidate the complete row cache. Invalid input likewise
/// clears cached rows before returning an error, so stale partial facts can never
/// become an accepted borrowed view.
pub const RawCache = struct {
    allocator: std.mem.Allocator,
    text_body: std.ArrayList(u8) = .empty,
    decoded_text: codec.cache.Cache,
    baseline: ?CacheBaseline = null,
    pending_delta: ?CacheBaseline = null,
    graphics: Graphics = .{},
    properties_storage: []u8 = &.{},

    /// Creates an empty reusable raw/delta observation cache.
    pub fn init(allocator: std.mem.Allocator) RawCache {
        return .{ .allocator = allocator, .decoded_text = codec.cache.Cache.init(allocator) };
    }

    /// Releases all cached rows, hyperlinks, graphics, and framing scratch.
    pub fn deinit(self: *RawCache) void {
        self.decoded_text.deinit();
        self.graphics.deinit(self.allocator);
        self.allocator.free(self.properties_storage);
        self.text_body.deinit(self.allocator);
        self.* = undefined;
    }

    /// Receives one previously armed complete-raw or delta observation.
    ///
    /// `snapshot_delta_data` is accepted only against the exact revision and
    /// history window armed through `sendDeltaRequest`; complete raw fallback
    /// remains independently decodable.
    pub fn receive(self: *RawCache, connection: *client.Connection) Error!View {
        errdefer client.retire(connection);
        return self.receiveFrom(connection);
    }

    // zig-audit: acknowledge anytype
    // reason: The same frame receiver serves the real Connection and deterministic fixtures implementing its receive contract.
    fn receiveFrom(self: *RawCache, connection: anytype) Error!View {
        self.text_body.clearRetainingCapacity();
        const pending_delta = self.pending_delta;
        errdefer {
            self.pending_delta = null;
            self.baseline = null;
            self.decoded_text.invalidate();
        }
        var total_bytes: usize = 0;
        var begin_frame = try connection.receive();
        defer begin_frame.deinit();
        try accountFrame(&total_bytes, begin_frame.payload.len);
        if (begin_frame.kind != .snapshot_begin) return error.UnexpectedFrame;
        const begin = try protocol.decodeSnapshotBegin(begin_frame.payload);

        const BodyEncoding = enum { none, raw, delta };
        var body_encoding: BodyEncoding = .none;
        var next_properties: ?[]u8 = null;
        errdefer if (next_properties) |value| self.allocator.free(value);
        var next_graphics: ?Graphics = null;
        errdefer if (next_graphics) |*value| value.deinit(self.allocator);
        while (true) {
            var frame = try connection.receive();
            defer frame.deinit();
            try accountFrame(&total_bytes, frame.payload.len);
            switch (frame.kind) {
                .snapshot_raw_data, .snapshot_delta_data => {
                    if (next_graphics != null) return error.InvalidSnapshot;
                    const encoding: BodyEncoding = if (frame.kind == .snapshot_delta_data)
                        .delta
                    else
                        .raw;
                    if (body_encoding != .none and body_encoding != encoding)
                        return error.InvalidSnapshot;
                    body_encoding = encoding;
                    if (self.text_body.items.len + frame.payload.len > protocol.maximum_text_snapshot_bytes)
                        return error.SnapshotTooLarge;
                    try self.text_body.appendSlice(self.allocator, frame.payload);
                },
                .snapshot_data => return error.UnexpectedFrame,
                .snapshot_graphics => {
                    if (next_graphics != null) return error.InvalidSnapshot;
                    next_graphics = try decodeGraphics(self.allocator, begin.terminal.geometry(), frame.payload);
                },
                .snapshot_properties => {
                    if (next_graphics == null or next_properties != null) return error.InvalidSnapshot;
                    const value = protocol.properties.decode(frame.payload) catch return error.InvalidSnapshot;
                    // zig-audit: acknowledge catch_unreachable
                    // reason: properties.decode just validated this exact payload, so recomputing its encoded size cannot fail for the same value.
                    std.debug.assert((protocol.properties.encodedSize(value) catch unreachable) == frame.payload.len);
                    next_properties = try self.allocator.dupe(u8, frame.payload);
                },
                .snapshot_end => {
                    if (body_encoding == .none or next_graphics == null or next_properties == null) return error.InvalidSnapshot;
                    const end = try protocol.decodeSnapshotEnd(frame.payload);
                    if (end.revision != begin.revision) return error.InvalidSnapshot;
                    const delta = body_encoding == .delta;
                    if (delta) {
                        const expected = pending_delta orelse return error.InvalidSnapshot;
                        const baseline = self.baseline orelse return error.InvalidSnapshot;
                        if (expected.revision == 0 or baseline.revision != expected.revision or
                            baseline.history_offset != expected.history_offset or
                            begin.terminal.history_offset != expected.history_offset or
                            !self.decoded_text.canReuse(begin.terminal.geometry()))
                            return error.InvalidSnapshot;
                    }
                    var result = try self.decodeRaw(
                        begin,
                        self.text_body.items,
                        next_graphics.?,
                        delta,
                    );
                    next_graphics = null;
                    self.allocator.free(self.properties_storage);
                    self.properties_storage = next_properties.?;
                    next_properties = null;
                    // zig-audit: acknowledge catch_unreachable
                    // reason: properties_storage is an owned copy of bytes successfully decoded earlier in this same transaction.
                    result.properties = protocol.properties.decode(self.properties_storage) catch unreachable;
                    self.baseline = .{
                        .revision = begin.revision,
                        .history_offset = begin.terminal.history_offset,
                    };
                    self.pending_delta = null;
                    return result;
                },
                else => return error.UnexpectedFrame,
            }
        }
    }

    fn decodeRaw(
        self: *RawCache,
        begin: protocol.SnapshotBegin,
        encoded: []const u8,
        next_graphics: Graphics,
        allow_row_reuse: bool,
    ) Error!View {
        errdefer self.baseline = null;
        const changed_rows_base_revision: ?u64 = if (self.baseline) |baseline|
            if (baseline.history_offset == begin.terminal.history_offset and
                self.decoded_text.canReuse(begin.terminal.geometry()))
                baseline.revision
            else
                null
        else
            null;
        const text = try self.decoded_text.decode(
            begin.terminal.geometry(),
            if (allow_row_reuse) .delta else .full,
            encoded,
        );
        self.graphics.deinit(self.allocator);
        self.graphics = next_graphics;
        return .{
            .begin = begin,
            .presentation = text.presentation,
            .rows = text.rows,
            .hyperlinks = text.hyperlinks,
            .graphics = self.graphics,
            .changed_rows = text.changed_rows,
            .changed_rows_base_revision = changed_rows_base_revision,
            .row_shift = text.row_shift,
        };
    }

    /// Arms one revision-relative delta observation for this reusable cache.
    ///
    /// The endpoint may fall back to a complete raw snapshot. Nonzero
    /// `after_revision` must name this cache's current accepted baseline exactly;
    /// revision zero explicitly requests resynchronization without a baseline.
    pub fn sendDeltaRequest(
        self: *RawCache,
        connection: *client.Connection,
        after_revision: u64,
        history_offset: u32,
    ) Error!void {
        if (self.pending_delta != null) return error.ObservationPending;
        if (after_revision != 0) {
            const baseline = self.baseline orelse return error.DeltaBaselineMismatch;
            if (baseline.revision != after_revision or baseline.history_offset != history_offset)
                return error.DeltaBaselineMismatch;
        }
        var payload: [protocol.payload_bytes.observe]u8 = undefined;
        protocol.encodeObserve(&payload, .{
            .after_revision = after_revision,
            .history_offset = history_offset,
        });
        try connection.send(.observe_delta, &payload);
        self.pending_delta = .{
            .revision = after_revision,
            .history_offset = history_offset,
        };
    }
};

/// Sends one ordinary request-driven rich observation without receiving it yet.
///
/// The caller must pair every successful call with exactly one `receive` on the
/// same connection before sending another request.
pub fn sendRequest(
    connection: *client.Connection,
    after_revision: u64,
    history_offset: u32,
) client.Error!void {
    var payload: [protocol.payload_bytes.observe]u8 = undefined;
    protocol.encodeObserve(&payload, .{
        .after_revision = after_revision,
        .history_offset = history_offset,
    });
    try connection.send(.observe, &payload);
}

/// Sends one complete raw rich observation request. Framing v7 keeps this lane distinct
/// from ordinary compressed `observe`; text_v1 record bytes are unchanged.
pub fn sendRawRequest(
    connection: *client.Connection,
    after_revision: u64,
    history_offset: u32,
) client.Error!void {
    var payload: [protocol.payload_bytes.observe]u8 = undefined;
    protocol.encodeObserve(&payload, .{
        .after_revision = after_revision,
        .history_offset = history_offset,
    });
    try connection.send(.observe_raw, &payload);
}

/// Sends one complete packed text_v1 observation request. The endpoint packs
/// exact text_v1 row bytes for carriage; receive reconstructs the frozen body
/// before semantic decoding.
pub fn sendPackedRequest(
    connection: *client.Connection,
    after_revision: u64,
    history_offset: u32,
) client.Error!void {
    var payload: [protocol.payload_bytes.observe]u8 = undefined;
    protocol.encodeObserve(&payload, .{
        .after_revision = after_revision,
        .history_offset = history_offset,
    });
    try connection.send(.observe_packed, &payload);
}

/// Requests one ordinary compressed rich observation and owns the complete decoded snapshot.
pub fn request(
    connection: *client.Connection,
    allocator: std.mem.Allocator,
    after_revision: u64,
    history_offset: u32,
) Error!Snapshot {
    try sendRequest(connection, after_revision, history_offset);
    return receive(connection, allocator);
}

/// Requests one complete raw text_v1 observation. Snapshot ownership is identical to
/// `request`; only the transport envelope skips DEFLATE.
pub fn requestRaw(
    connection: *client.Connection,
    allocator: std.mem.Allocator,
    after_revision: u64,
    history_offset: u32,
) Error!Snapshot {
    try sendRawRequest(connection, after_revision, history_offset);
    return receive(connection, allocator);
}

/// Requests one complete packed text_v1 observation. Snapshot ownership and
/// semantic decoding are identical to `request`.
pub fn requestPacked(
    connection: *client.Connection,
    allocator: std.mem.Allocator,
    after_revision: u64,
    history_offset: u32,
) Error!Snapshot {
    try sendPackedRequest(connection, after_revision, history_offset);
    return receive(connection, allocator);
}

/// Receives one complete rich snapshot after `observe` or `observe_raw`.
/// Revision-relative delta responses are owned by `RawCache`.
pub fn receive(connection: *client.Connection, allocator: std.mem.Allocator) Error!Snapshot {
    errdefer client.retire(connection);
    return receiveFrom(connection, allocator);
}

/// Decodes exactly one complete framed snapshot without a socket or platform I/O.
/// The caller retains `bytes` for this call only; the returned snapshot owns its
/// allocations. Truncation and trailing frames are errors, not partial success.
/// Asynchronous hosts must bound and assemble a complete response before calling.
pub fn decodeFrames(allocator: std.mem.Allocator, bytes: []const u8) Error!Snapshot {
    if (bytes.len > protocol.maximum_observation_bytes) return error.SnapshotTooLarge;
    var reader = BufferedFrames{ .bytes = bytes };
    var snapshot = try receiveFrom(&reader, allocator);
    errdefer snapshot.deinit();
    if (reader.offset != bytes.len) return error.InvalidSnapshot;
    return snapshot;
}

const BufferedFrames = struct {
    bytes: []const u8,
    offset: usize = 0,

    const Frame = struct {
        kind: protocol.Kind,
        payload: []const u8,

        fn deinit(self: *Frame) void {
            // A borrowed view, not an allocation; invalidate only this handle.
            self.* = undefined;
        }
    };

    fn receive(self: *BufferedFrames) Error!Frame {
        const remaining = self.bytes[self.offset..];
        if (remaining.len < protocol.header_bytes) return error.InvalidSnapshot;
        const header = try protocol.decodeHeader(remaining[0..protocol.header_bytes]);
        if (header.payload_len > remaining.len - protocol.header_bytes)
            return error.InvalidSnapshot;
        self.offset += protocol.header_bytes + header.payload_len;
        return .{
            .kind = header.kind,
            .payload = remaining[protocol.header_bytes..][0..header.payload_len],
        };
    }
};

// One frame receiver, specialized only for owned socket frames or borrowed bytes.
// zig-audit: acknowledge anytype
// reason: The same decoder is exercised by the real Connection and the bounded in-memory frame reader used for exact offline decoding.
fn receiveFrom(connection: anytype, allocator: std.mem.Allocator) Error!Snapshot {
    var total_bytes: usize = 0;
    var begin_frame = try connection.receive();
    defer begin_frame.deinit();
    try accountFrame(&total_bytes, begin_frame.payload.len);
    if (begin_frame.kind != .snapshot_begin) return error.UnexpectedFrame;
    const begin = try protocol.decodeSnapshotBegin(begin_frame.payload);

    var text_body: std.ArrayList(u8) = .empty;
    defer text_body.deinit(allocator);
    const BodyEncoding = codec.text.Encoding;
    var body_encoding: ?BodyEncoding = null;
    var property_bytes: ?[]u8 = null;
    errdefer if (property_bytes) |value| allocator.free(value);
    var graphics: ?Graphics = null;
    errdefer if (graphics) |*value| value.deinit(allocator);

    while (true) {
        var frame = try connection.receive();
        defer frame.deinit();
        try accountFrame(&total_bytes, frame.payload.len);
        switch (frame.kind) {
            .snapshot_data, .snapshot_raw_data, .snapshot_packed_data => {
                if (graphics != null) return error.InvalidSnapshot;
                const encoding: BodyEncoding = switch (frame.kind) {
                    .snapshot_data => .zlib,
                    .snapshot_raw_data => .raw,
                    .snapshot_packed_data => .packed_zlib,
                    // zig-audit: acknowledge unreachable
                    // reason: The enclosing switch admits only the three snapshot body frame kinds handled above.
                    else => unreachable,
                };
                if (body_encoding) |previous| {
                    if (previous != encoding) return error.InvalidSnapshot;
                }
                body_encoding = encoding;
                if (text_body.items.len + frame.payload.len > protocol.maximum_text_snapshot_bytes)
                    return error.SnapshotTooLarge;
                try text_body.appendSlice(allocator, frame.payload);
            },
            .snapshot_graphics => {
                if (graphics != null) return error.InvalidSnapshot;
                graphics = try decodeGraphics(allocator, begin.terminal.geometry(), frame.payload);
            },
            .snapshot_properties => {
                if (graphics == null or property_bytes != null) return error.InvalidSnapshot;
                const value = protocol.properties.decode(frame.payload) catch return error.InvalidSnapshot;
                // zig-audit: acknowledge catch_unreachable
                // reason: properties.decode just validated this exact payload, so recomputing its encoded size cannot fail for the same value.
                std.debug.assert((protocol.properties.encodedSize(value) catch unreachable) == frame.payload.len);
                property_bytes = try allocator.dupe(u8, frame.payload);
            },
            .snapshot_end => {
                if (graphics == null or property_bytes == null) return error.InvalidSnapshot;
                const end = try protocol.decodeSnapshotEnd(frame.payload);
                if (end.revision != begin.revision) return error.InvalidSnapshot;
                const text = try codec.text.decode(
                    allocator,
                    begin.terminal.geometry(),
                    body_encoding orelse return error.InvalidSnapshot,
                    text_body.items,
                );
                return .{
                    .allocator = allocator,
                    .begin = begin,
                    .presentation = text.presentation,
                    .rows = text.rows,
                    .hyperlinks = text.hyperlinks,
                    .graphics = graphics.?,
                    .properties_storage = property_bytes.?,
                    // zig-audit: acknowledge catch_unreachable
                    // reason: property_bytes owns the exact payload successfully decoded earlier in this observation transaction.
                    .properties = protocol.properties.decode(property_bytes.?) catch unreachable,
                };
            },
            else => return error.UnexpectedFrame,
        }
    }
}

fn accountFrame(total: *usize, payload_len: usize) error{SnapshotTooLarge}!void {
    total.* = std.math.add(usize, total.*, protocol.header_bytes + payload_len) catch
        return error.SnapshotTooLarge;
    if (total.* > protocol.maximum_observation_bytes) return error.SnapshotTooLarge;
}

fn encodeU16(bytes: []u8, value: u16) void {
    bytes[0] = @truncate(value >> 8);
    bytes[1] = @truncate(value);
}

fn encodeU32(bytes: []u8, value: u32) void {
    bytes[0] = @truncate(value >> 24);
    bytes[1] = @truncate(value >> 16);
    bytes[2] = @truncate(value >> 8);
    bytes[3] = @truncate(value);
}

fn testRowBegin(columns: u16) protocol.SnapshotBegin {
    return .{
        .revision = 1,
        .terminal = .{
            .revision = 1,
            .history_offset = 0,
            .history_count = 0,
            .history_row_base = 0,
            .rows = 1,
            .columns = columns,
            .cursor_row = 0,
            .cursor_column = 0,
            .cursor_shape = 0,
            .cursor_visible = false,
            .cursor_blink = false,
            .alternate_screen = false,
        },
        .stream_closed = false,
        .child_exited = false,
        .leader_present = false,
        .you_are_leader = false,
    };
}

fn testDeflateBody(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    // Compressor initialization requires a nonempty writable output buffer.
    var compressed = try std.Io.Writer.Allocating.initCapacity(allocator, 64);
    defer compressed.deinit();
    const work = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(work);
    const compressor = try allocator.create(std.compress.flate.Compress);
    defer allocator.destroy(compressor);
    compressor.* = try std.compress.flate.Compress.init(
        &compressed.writer,
        work,
        .zlib,
        .fastest,
    );
    try compressor.writer.writeAll(body);
    try compressor.finish();
    const result = try allocator.alloc(
        u8,
        protocol.text_v1.compressed_header_bytes + compressed.written().len,
    );
    encodeU32(result[0..protocol.text_v1.compressed_header_bytes], @intCast(body.len));
    @memcpy(result[protocol.text_v1.compressed_header_bytes..], compressed.written());
    return result;
}

fn testPackedBody(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var packed_body: std.ArrayList(u8) = .empty;
    defer packed_body.deinit(allocator);
    try protocol.packTextV1(allocator, body, &packed_body);

    var compressed = try std.Io.Writer.Allocating.initCapacity(allocator, 64);
    defer compressed.deinit();
    const work = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(work);
    var huffman = try std.compress.flate.Compress.Huffman.init(&compressed.writer, work, .zlib);
    try huffman.writer.writeAll(packed_body.items);
    try huffman.finish();

    const result = try allocator.alloc(
        u8,
        protocol.text_pack_v1.compressed_header_bytes + compressed.written().len,
    );
    encodeU32(result[0..4], @intCast(body.len));
    encodeU32(result[4..8], @intCast(packed_body.items.len));
    @memcpy(result[protocol.text_pack_v1.compressed_header_bytes..], compressed.written());
    return result;
}

const TestBodyEncoding = enum { compressed, raw, packed_text };

fn testFramedSnapshot(allocator: std.mem.Allocator, encoding: TestBodyEncoding) ![]u8 {
    const begin: protocol.SnapshotBegin = .{
        .revision = 3,
        .terminal = .{
            .revision = 9,
            .history_offset = 0,
            .history_count = 0,
            .history_row_base = 0,
            .rows = 0,
            .columns = 0,
            .cursor_row = 0,
            .cursor_column = 0,
            .cursor_shape = 0,
            .cursor_visible = true,
            .cursor_blink = false,
            .alternate_screen = false,
        },
        .stream_closed = false,
        .child_exited = false,
        .leader_present = false,
        .you_are_leader = false,
    };
    var body: [protocol.text_v1.record_header_bytes + protocol.text_v1.presentation_bytes]u8 = @splat(0);
    protocol.encodeTextRecordHeader(body[0..protocol.text_v1.record_header_bytes], .{
        .kind = .presentation,
        .payload_len = protocol.text_v1.presentation_bytes,
    });
    const encoded_body: []const u8 = switch (encoding) {
        .raw => &body,
        .compressed => try testDeflateBody(allocator, &body),
        .packed_text => try testPackedBody(allocator, &body),
    };
    defer if (encoding != .raw) allocator.free(encoded_body);
    const text_bytes = encoded_body;
    const graphics_bytes = protocol.graphics_v2.manifest_header_bytes;
    const length = 5 * protocol.header_bytes + protocol.payload_bytes.snapshot_begin +
        text_bytes.len + graphics_bytes + protocol.properties.header_bytes + protocol.payload_bytes.snapshot_end;
    const frames = try allocator.alloc(u8, length);
    errdefer allocator.free(frames);
    var at: usize = 0;
    try protocol.encodeHeader(frames[at..][0..protocol.header_bytes], .{
        .kind = .snapshot_begin,
        .payload_len = protocol.payload_bytes.snapshot_begin,
    });
    at += protocol.header_bytes;
    protocol.encodeSnapshotBegin(frames[at..][0..protocol.payload_bytes.snapshot_begin], begin);
    at += protocol.payload_bytes.snapshot_begin;
    try protocol.encodeHeader(frames[at..][0..protocol.header_bytes], .{
        .kind = switch (encoding) {
            .raw => .snapshot_raw_data,
            .compressed => .snapshot_data,
            .packed_text => .snapshot_packed_data,
        },
        .payload_len = @intCast(text_bytes.len),
    });
    at += protocol.header_bytes;
    @memcpy(frames[at..][0..text_bytes.len], text_bytes);
    at += text_bytes.len;
    try protocol.encodeHeader(frames[at..][0..protocol.header_bytes], .{
        .kind = .snapshot_graphics,
        .payload_len = graphics_bytes,
    });
    at += protocol.header_bytes;
    var graphics_header: [protocol.graphics_v2.manifest_header_bytes]u8 = undefined;
    protocol.encodeSnapshotGraphicsHeader(&graphics_header, .{
        .generation = 0,
        .content_generation = 0,
        .cell_pixel_width = 10,
        .cell_pixel_height = 20,
        .image_count = 0,
        .placement_count = 0,
    });
    @memcpy(frames[at..][0..graphics_header.len], &graphics_header);
    at += graphics_header.len;
    try protocol.encodeHeader(frames[at..][0..protocol.header_bytes], .{
        .kind = .snapshot_properties,
        .payload_len = protocol.properties.header_bytes,
    });
    at += protocol.header_bytes;
    at += try protocol.properties.encode(frames[at..], .{});
    try protocol.encodeHeader(frames[at..][0..protocol.header_bytes], .{
        .kind = .snapshot_end,
        .payload_len = protocol.payload_bytes.snapshot_end,
    });
    at += protocol.header_bytes;
    protocol.encodeSnapshotEnd(frames[at..][0..protocol.payload_bytes.snapshot_end], .{ .revision = begin.revision });
    return frames;
}

fn testDecodeOwned(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var snapshot = try decodeFrames(allocator, bytes);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(u64, 3), snapshot.begin.revision);
    try std.testing.expectEqual(@as(u64, 9), snapshot.begin.terminal.revision);
    try std.testing.expectEqual(@as(usize, 0), snapshot.rows.len);
    try std.testing.expectEqual(@as(usize, 0), snapshot.graphics.images.len);
    try std.testing.expectEqual(@as(usize, 0), snapshot.graphics.placements.len);
}

test "buffered frames share decoder and clean up at every allocation failure" {
    const frames = try testFramedSnapshot(std.testing.allocator, .compressed);
    defer std.testing.allocator.free(frames);
    try testDecodeOwned(std.testing.allocator, frames);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testDecodeOwned, .{frames});
}

test "packed framed snapshots share semantic decoder and clean up allocations" {
    const frames = try testFramedSnapshot(std.testing.allocator, .packed_text);
    defer std.testing.allocator.free(frames);
    try testDecodeOwned(std.testing.allocator, frames);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testDecodeOwned, .{frames});

    // Corrupt the zlib tail; packed carriage must fail before semantic decode.
    frames[frames.len - protocol.payload_bytes.snapshot_end - protocol.header_bytes - 1] ^= 0xff;
    defer frames[frames.len - protocol.payload_bytes.snapshot_end - protocol.header_bytes - 1] ^= 0xff;
    try std.testing.expectError(error.InvalidSnapshot, decodeFrames(std.testing.allocator, frames));
}

test "buffered frames decode raw text_v1 snapshot lane" {
    const frames = try testFramedSnapshot(std.testing.allocator, .raw);
    defer std.testing.allocator.free(frames);
    try testDecodeOwned(std.testing.allocator, frames);
}

test "buffered frames reject truncation trailing data and mismatched revision" {
    const frames = try testFramedSnapshot(std.testing.allocator, .compressed);
    defer std.testing.allocator.free(frames);
    for (0..frames.len) |length| {
        try std.testing.expectError(error.InvalidSnapshot, decodeFrames(std.testing.allocator, frames[0..length]));
    }
    const trailing = try std.testing.allocator.alloc(u8, frames.len + 1);
    defer std.testing.allocator.free(trailing);
    @memcpy(trailing[0..frames.len], frames);
    trailing[frames.len] = 0;
    try std.testing.expectError(error.InvalidSnapshot, decodeFrames(std.testing.allocator, trailing));
    frames[frames.len - 1] ^= 1;
    try std.testing.expectError(error.InvalidSnapshot, decodeFrames(std.testing.allocator, frames));
    frames[frames.len - 1] ^= 1;
    frames[0] = 0;
    try std.testing.expectError(error.InvalidMagic, decodeFrames(std.testing.allocator, frames));
}

test "raw cache changed-row mask names its exact predecessor revision" {
    const allocator = std.testing.allocator;
    var cache = RawCache.init(allocator);
    defer cache.deinit();

    const begin = protocol.SnapshotBegin{
        .revision = 1,
        .terminal = .{
            .revision = 1,
            .history_offset = 0,
            .history_count = 0,
            .history_row_base = 0,
            .rows = 2,
            .columns = 1,
            .cursor_row = 0,
            .cursor_column = 0,
            .cursor_shape = 0,
            .cursor_visible = true,
            .cursor_blink = false,
            .alternate_screen = false,
        },
        .stream_closed = false,
        .child_exited = false,
        .leader_present = false,
        .you_are_leader = false,
    };
    const baseline_body = try testRawCacheBody(allocator, 'A', 'Z');
    defer allocator.free(baseline_body);
    const baseline = try cache.decodeRaw(begin, baseline_body, .{}, false);
    try std.testing.expect(baseline.changed_rows_base_revision == null);

    cache.baseline = .{ .revision = begin.revision, .history_offset = begin.terminal.history_offset };
    var next_begin = begin;
    next_begin.revision = 2;
    next_begin.terminal.revision = 2;
    const changed_body = try testRawCacheBody(allocator, 'B', 'Z');
    defer allocator.free(changed_body);
    const changed = try cache.decodeRaw(next_begin, changed_body, .{}, false);
    try std.testing.expectEqual(@as(?u64, 1), changed.changed_rows_base_revision);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, changed.changed_rows.?);

    cache.baseline = .{ .revision = next_begin.revision, .history_offset = 3 };
    var history_begin = next_begin;
    history_begin.revision = 3;
    history_begin.terminal.history_offset = 0;
    const history_mismatch = try cache.decodeRaw(history_begin, changed_body, .{}, false);
    try std.testing.expect(history_mismatch.changed_rows_base_revision == null);
}

fn testRawCacheDeltaBody(allocator: std.mem.Allocator, first: u32) ![]u8 {
    const full = try testRawCacheBody(allocator, first, 'Z');
    defer allocator.free(full);
    const presentation_record = protocol.text_v1.record_header_bytes + protocol.text_v1.presentation_bytes;
    const shift_record = protocol.text_v1.record_header_bytes + protocol.text_delta_v2.row_shift_bytes;
    const row_payload = protocol.text_v1.row_header_bytes + protocol.text_v1.cell_header_bytes + @sizeOf(u32);
    const row_record = protocol.text_v1.record_header_bytes + row_payload;
    const body = try allocator.alloc(u8, presentation_record + shift_record + row_record + protocol.text_v1.record_header_bytes);
    @memcpy(body[0..presentation_record], full[0..presentation_record]);
    var at = presentation_record;
    protocol.encodeTextRecordHeader(body[at..][0..protocol.text_v1.record_header_bytes], .{
        .kind = .row_shift,
        .payload_len = protocol.text_delta_v2.row_shift_bytes,
    });
    at += protocol.text_v1.record_header_bytes;
    protocol.encodeTextRowShift(body[at..][0..protocol.text_delta_v2.row_shift_bytes], 0);
    at += protocol.text_delta_v2.row_shift_bytes;
    @memcpy(body[at..][0..row_record], full[presentation_record..][0..row_record]);
    at += row_record;
    protocol.encodeTextRecordHeader(body[at..][0..protocol.text_v1.record_header_bytes], .{
        .kind = .row,
        .payload_len = 0,
    });
    return body;
}

fn testRawCacheBody(allocator: std.mem.Allocator, first: u32, second: u32) ![]u8 {
    const presentation_record = protocol.text_v1.record_header_bytes + protocol.text_v1.presentation_bytes;
    const row_payload = protocol.text_v1.row_header_bytes + protocol.text_v1.cell_header_bytes + @sizeOf(u32);
    const row_record = protocol.text_v1.record_header_bytes + row_payload;
    const body = try allocator.alloc(u8, presentation_record + 2 * row_record);
    @memset(body, 0);

    protocol.encodeTextRecordHeader(body[0..protocol.text_v1.record_header_bytes], .{
        .kind = .presentation,
        .payload_len = protocol.text_v1.presentation_bytes,
    });
    var at = presentation_record;
    for ([_]u32{ first, second }) |scalar| {
        protocol.encodeTextRecordHeader(body[at..][0..protocol.text_v1.record_header_bytes], .{
            .kind = .row,
            .payload_len = row_payload,
        });
        at += protocol.text_v1.record_header_bytes;
        const row = body[at..][0..row_payload];
        encodeU16(row[2..4], 1);
        const cell = row[protocol.text_v1.row_header_bytes..][0..protocol.text_v1.cell_header_bytes];
        cell[0] = 1;
        cell[1] = 1;
        cell[2] = 1;
        var color: [protocol.text_v1.color_bytes]u8 = undefined;
        try protocol.encodeTextColor(&color, .{ .kind = .default, .value = 0 });
        @memcpy(cell[16..21], &color);
        @memcpy(cell[21..26], &color);
        @memcpy(cell[26..31], &color);
        encodeU32(row[row_payload - 4 ..], scalar);
        at += row_payload;
    }
    std.debug.assert(at == body.len);
    return body;
}

test "rich snapshots require exactly one coherent property packet and own its bytes" {
    const allocator = std.testing.allocator;
    const frames = try testFramedSnapshot(allocator, .raw);
    defer allocator.free(frames);
    var offset: usize = 0;
    var properties_at: usize = 0;
    while (offset < frames.len) {
        const header = try protocol.decodeHeader(frames[offset..][0..protocol.header_bytes]);
        if (header.kind == .snapshot_properties) properties_at = offset;
        offset += protocol.header_bytes + header.payload_len;
    }
    try std.testing.expect(properties_at != 0);
    const old_size = protocol.header_bytes + protocol.properties.header_bytes;
    const body_size = try protocol.properties.encodedSize(.{ .title = "safe λ", .progress = .{ .kind = .paused, .value = 51 } });
    const changed = try allocator.alloc(u8, frames.len + body_size - protocol.properties.header_bytes);
    defer allocator.free(changed);
    @memcpy(changed[0..properties_at], frames[0..properties_at]);
    try protocol.encodeHeader(changed[properties_at..][0..protocol.header_bytes], .{ .kind = .snapshot_properties, .payload_len = @intCast(body_size) });
    const encoded = try protocol.properties.encode(changed[properties_at + protocol.header_bytes ..], .{ .title = "safe λ", .progress = .{ .kind = .paused, .value = 51 } });
    @memcpy(changed[properties_at + protocol.header_bytes + encoded ..], frames[properties_at + old_size ..]);
    var snapshot = try decodeFrames(allocator, changed);
    defer snapshot.deinit();
    @memset(changed, 0);
    try std.testing.expectEqualStrings("safe λ", snapshot.properties.title.?);
    try std.testing.expectEqualDeep(protocol.properties.Progress{ .kind = .paused, .value = 51 }, snapshot.properties.progress);

    const missing = try std.mem.concat(allocator, u8, &.{ frames[0..properties_at], frames[properties_at + old_size ..] });
    defer allocator.free(missing);
    try std.testing.expectError(error.InvalidSnapshot, decodeFrames(allocator, missing));
    const duplicate = try std.mem.concat(allocator, u8, &.{ frames[0..properties_at], frames[properties_at .. properties_at + old_size], frames[properties_at..] });
    defer allocator.free(duplicate);
    try std.testing.expectError(error.InvalidSnapshot, decodeFrames(allocator, duplicate));
    frames[properties_at + protocol.header_bytes + 21] = 101;
    try std.testing.expectError(error.InvalidSnapshot, decodeFrames(allocator, frames));
}

test "raw cached observations own properties and clear them independently of reused rows" {
    const allocator = std.testing.allocator;
    const raw = try testRawCacheBody(allocator, 'A', 'Z');
    defer allocator.free(raw);
    var begin = testRowBegin(1);
    begin.terminal.rows = 2;
    const first_bytes = try testCachedFrames(allocator, begin, .snapshot_raw_data, raw, .{ .title = "cached title", .progress = .{ .kind = .normal, .value = 25 } });
    defer allocator.free(first_bytes);
    var cache = RawCache.init(allocator);
    defer cache.deinit();
    var first_reader = BufferedFrames{ .bytes = first_bytes };
    const first = try cache.receiveFrom(&first_reader);
    const row_cells = first.rows[0].cells.ptr;
    @memset(first_bytes, 0);
    try std.testing.expectEqualStrings("cached title", first.properties.title.?);
    try std.testing.expectEqual(@as(u8, 25), first.properties.progress.value);
    begin.revision = 2;
    const next_bytes = try testCachedFrames(allocator, begin, .snapshot_raw_data, raw, .{});
    defer allocator.free(next_bytes);
    var next_reader = BufferedFrames{ .bytes = next_bytes };
    const next = try cache.receiveFrom(&next_reader);
    try std.testing.expectEqual(row_cells, next.rows[0].cells.ptr);
    try std.testing.expectEqualSlices(bool, &.{ false, false }, next.changed_rows.?);
    try std.testing.expect(next.properties.title == null);
    try std.testing.expectEqual(protocol.properties.ProgressKind.none, next.properties.progress.kind);
}

fn testCachedFrames(
    allocator: std.mem.Allocator,
    begin: protocol.SnapshotBegin,
    body_kind: protocol.Kind,
    raw: []const u8,
    value: protocol.properties.View,
) ![]u8 {
    const base = try testFramedSnapshot(allocator, .raw);
    defer allocator.free(base);
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var offset: usize = 0;
    while (offset < base.len) {
        var header = try protocol.decodeHeader(base[offset..][0..protocol.header_bytes]);
        var payload: []const u8 = base[offset + protocol.header_bytes ..][0..header.payload_len];
        var scratch: [protocol.properties.maximum_bytes]u8 = undefined;
        switch (header.kind) {
            .snapshot_begin => {
                protocol.encodeSnapshotBegin(scratch[0..protocol.payload_bytes.snapshot_begin], begin);
                payload = scratch[0..protocol.payload_bytes.snapshot_begin];
            },
            .snapshot_raw_data => {
                header.kind = body_kind;
                payload = raw;
            },
            .snapshot_properties => {
                const length = try protocol.properties.encode(&scratch, value);
                payload = scratch[0..length];
            },
            .snapshot_end => {
                protocol.encodeSnapshotEnd(scratch[0..protocol.payload_bytes.snapshot_end], .{ .revision = begin.revision });
                payload = scratch[0..protocol.payload_bytes.snapshot_end];
            },
            else => {},
        }
        var framing: [protocol.header_bytes]u8 = undefined;
        try protocol.encodeHeader(&framing, .{ .kind = header.kind, .payload_len = @intCast(payload.len) });
        try bytes.appendSlice(allocator, &framing);
        try bytes.appendSlice(allocator, payload);
        offset += protocol.header_bytes + header.payload_len;
    }
    return bytes.toOwnedSlice(allocator);
}

test "Server delta admission uses the accepted observation revision independently of VT revision" {
    const allocator = std.testing.allocator;
    const full = try testRawCacheBody(allocator, 'A', 'Z');
    defer allocator.free(full);
    const delta = try testRawCacheDeltaBody(allocator, 'B');
    defer allocator.free(delta);
    var begin = testRowBegin(1);
    begin.terminal.rows = 2;
    begin.revision = 100;
    begin.terminal.revision = 7;
    const first_packet = try testCachedFrames(allocator, begin, .snapshot_raw_data, full, .{});
    defer allocator.free(first_packet);
    var cache = RawCache.init(allocator);
    defer cache.deinit();
    var first_reader = BufferedFrames{ .bytes = first_packet };
    const first = try cache.receiveFrom(&first_reader);
    try std.testing.expect(first.changed_rows_base_revision == null);
    const retained = first.rows[1].cells.ptr;

    begin.revision = 101; // Authority/lifecycle cut may change without VT revision.
    const next_packet = try testCachedFrames(allocator, begin, .snapshot_delta_data, delta, .{});
    defer allocator.free(next_packet);
    cache.pending_delta = .{ .revision = 100, .history_offset = 0 };
    var next_reader = BufferedFrames{ .bytes = next_packet };
    const second = try cache.receiveFrom(&next_reader);
    try std.testing.expectEqual(@as(u64, 7), second.begin.terminal.revision);
    try std.testing.expectEqual(@as(?u64, 100), second.changed_rows_base_revision);
    try std.testing.expectEqual(retained, second.rows[1].cells.ptr);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, second.changed_rows.?);
    try std.testing.expect(cache.pending_delta == null);

    cache.pending_delta = .{ .revision = 7, .history_offset = 0 }; // A VT revision cannot name delivery.
    var wrong_reader = BufferedFrames{ .bytes = next_packet };
    try std.testing.expectError(error.InvalidSnapshot, cache.receiveFrom(&wrong_reader));
    try std.testing.expect(cache.baseline == null);
    try std.testing.expect(cache.pending_delta == null);
    try std.testing.expect(!cache.decoded_text.canReuse(begin.terminal.geometry()));

    begin.revision = 102;
    const recovered_packet = try testCachedFrames(allocator, begin, .snapshot_raw_data, full, .{});
    defer allocator.free(recovered_packet);
    var recovered_reader = BufferedFrames{ .bytes = recovered_packet };
    const recovered = try cache.receiveFrom(&recovered_reader);
    try std.testing.expect(recovered.changed_rows_base_revision == null);
    try std.testing.expectEqualSlices(bool, &.{ true, true }, recovered.changed_rows.?);
}

test "failed framing and unarmed delta clear Server and codec reuse state together" {
    const allocator = std.testing.allocator;
    const full = try testRawCacheBody(allocator, 'A', 'Z');
    defer allocator.free(full);
    const delta = try testRawCacheDeltaBody(allocator, 'B');
    defer allocator.free(delta);
    var begin = testRowBegin(1);
    begin.terminal.rows = 2;
    const first_packet = try testCachedFrames(allocator, begin, .snapshot_raw_data, full, .{});
    defer allocator.free(first_packet);
    var cache = RawCache.init(allocator);
    defer cache.deinit();
    var reader = BufferedFrames{ .bytes = first_packet };
    const first = try cache.receiveFrom(&reader);
    try std.testing.expectEqual(@as(u32, 'A'), first.rows[0].cells[0].scalars[0]);

    begin.revision = 2;
    const unarmed_packet = try testCachedFrames(allocator, begin, .snapshot_delta_data, delta, .{});
    defer allocator.free(unarmed_packet);
    var unarmed_reader = BufferedFrames{ .bytes = unarmed_packet };
    try std.testing.expectError(error.InvalidSnapshot, cache.receiveFrom(&unarmed_reader));
    try std.testing.expect(cache.baseline == null);
    try std.testing.expect(!cache.decoded_text.canReuse(begin.terminal.geometry()));

    reader = .{ .bytes = first_packet };
    const restored = try cache.receiveFrom(&reader);
    try std.testing.expectEqualSlices(bool, &.{ true, true }, restored.changed_rows.?);
    const malformed = try allocator.dupe(u8, first_packet);
    defer allocator.free(malformed);
    protocol.encodeSnapshotEnd(malformed[malformed.len - protocol.payload_bytes.snapshot_end ..][0..protocol.payload_bytes.snapshot_end], .{ .revision = 99 });
    cache.pending_delta = .{ .revision = 1, .history_offset = 0 };
    var malformed_reader = BufferedFrames{ .bytes = malformed };
    try std.testing.expectError(error.InvalidSnapshot, cache.receiveFrom(&malformed_reader));
    try std.testing.expect(cache.baseline == null and cache.pending_delta == null);
    try std.testing.expect(!cache.decoded_text.canReuse(begin.terminal.geometry()));

    reader = .{ .bytes = first_packet };
    const recovered = try cache.receiveFrom(&reader);
    try std.testing.expect(recovered.changed_rows_base_revision == null);
    try std.testing.expectEqualSlices(bool, &.{ true, true }, recovered.changed_rows.?);
}
