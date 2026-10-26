//! Complete transport-free text observations and their allocation lifetime.
const std = @import("std");
const wire = @import("wire.zig");
const values = @import("decoded.zig");

/// Exact full-text body encodings; delta reuse is a separate baseline contract.
pub const Encoding = enum { raw, zlib, packed_zlib };

/// Complete body carriage selected independently of any socket framing.
pub const Compression = enum { zlib, packed_zlib };

/// Copies the length prefix and borrows compressed bytes until the compressor's
/// next call or deinitialization. Prefix and data remain separate for direct framing.
pub const Compressed = struct {
    header: union(Compression) {
        zlib: [wire.text_v1.compressed_header_bytes]u8,
        packed_zlib: [wire.text_pack_v1.compressed_header_bytes]u8,
    },
    data: []const u8,

    /// Borrows the exact zlib or packed-zlib length prefix from this value.
    pub fn prefix(self: *const Compressed) []const u8 {
        return switch (self.header) {
            .zlib => &self.header.zlib,
            .packed_zlib => &self.header.packed_zlib,
        };
    }

    /// Reports the validated complete payload size, including its length prefix.
    pub fn size(self: *const Compressed) usize {
        return self.prefix().len + self.data.len;
    }
};

/// Retains compression output, packed-record scratch and a DEFLATE window.
/// It owns no observation delivery, connection, Server revision or scheduling.
pub const Compressor = struct {
    allocator: std.mem.Allocator,
    packed_body: std.ArrayList(u8) = .empty,
    output: std.Io.Writer.Allocating,
    work: []u8,
    compressor: *std.compress.flate.Compress,

    /// Allocates the same work window and compressor storage used across all cuts.
    pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Compressor {
        const work = try allocator.alloc(u8, std.compress.flate.max_window_len);
        errdefer allocator.free(work);
        const compressor = try allocator.create(std.compress.flate.Compress);
        errdefer allocator.destroy(compressor);
        return .{
            .allocator = allocator,
            .output = .init(allocator),
            .work = work,
            .compressor = compressor,
        };
    }

    /// Releases all retained compression and packing allocations.
    pub fn deinit(self: *Compressor) void {
        self.packed_body.deinit(self.allocator);
        self.output.deinit();
        self.allocator.free(self.work);
        self.allocator.destroy(self.compressor);
        self.* = undefined;
    }

    /// Wraps one nonempty bounded raw body. Packed carriage also validates record
    /// layout; zlib does not re-parse the caller's already encoded terminal records.
    /// Every call expires prior borrowed bytes, including failed calls. Failure
    /// clears partial output; the next call reinitializes compression in place.
    pub fn compress(self: *Compressor, mode: Compression, body: []const u8) values.Error!Compressed {
        self.output.writer.end = 0;
        self.packed_body.clearRetainingCapacity();
        errdefer {
            self.output.writer.end = 0;
            self.packed_body.clearRetainingCapacity();
        }
        if (body.len == 0 or body.len > wire.maximum_text_snapshot_bytes)
            return error.SnapshotTooLarge;
        if (mode == .packed_zlib) {
            wire.packTextV1(self.allocator, body, &self.packed_body) catch |failure| switch (failure) {
                error.InvalidPayload => return error.InvalidSnapshot,
                else => |err| return err,
            };
            if (self.packed_body.items.len == 0 or self.packed_body.items.len > wire.text_pack_v1.maximum_body_bytes)
                return error.SnapshotTooLarge;
        }
        try self.output.ensureTotalCapacity(64);
        // This writer is owned allocating memory, not caller I/O. With bounded
        // input, its WriteFailed can only report allocation failure.
        self.compressor.* = std.compress.flate.Compress.init(
            &self.output.writer,
            self.work,
            .zlib,
            .fastest,
        ) catch return error.OutOfMemory;
        const input = if (mode == .packed_zlib) self.packed_body.items else body;
        self.compressor.writer.writeAll(input) catch return error.OutOfMemory;
        self.compressor.finish() catch return error.OutOfMemory;
        const data = self.output.written();
        var result: Compressed = .{
            .header = switch (mode) {
                .zlib => .{ .zlib = undefined },
                .packed_zlib => .{ .packed_zlib = undefined },
            },
            .data = data,
        };
        const header: []u8 = switch (mode) {
            .zlib => &result.header.zlib,
            .packed_zlib => &result.header.packed_zlib,
        };
        writeU32(header[0..4], @intCast(body.len));
        if (mode == .packed_zlib) writeU32(header[4..8], @intCast(self.packed_body.items.len));
        if (result.size() > wire.maximum_text_snapshot_bytes) return error.SnapshotTooLarge;
        return result;
    }
};

/// Owns one complete text observation; no slice borrows encoded input.
pub const Text = struct {
    allocator: std.mem.Allocator,
    presentation: values.Presentation,
    rows: []values.Row,
    hyperlinks: []values.Hyperlink,

    /// Releases rows, scalar banks, URI bytes and their outer arrays.
    pub fn deinit(self: *Text) void {
        values.deinitRows(self.allocator, self.rows);
        self.allocator.free(self.rows);
        for (self.hyperlinks) |link| self.allocator.free(link.uri_bytes);
        self.allocator.free(self.hyperlinks);
        self.* = undefined;
    }
};

/// Decodes one bounded complete text body and returns its sole allocation owner.
/// Geometry and payload grammar are sufficient; no delivery or authority state
/// participates. Malformed input and allocation failure retain no partial result.
pub fn decode(
    allocator: std.mem.Allocator,
    geometry: values.Geometry,
    encoding: Encoding,
    encoded: []const u8,
) values.Error!Text {
    if (encoded.len > wire.maximum_text_snapshot_bytes) return error.SnapshotTooLarge;
    switch (encoding) {
        .raw => {
            if (encoded.len == 0) return error.SnapshotTooLarge;
            return decodeRecords(allocator, geometry, encoded);
        },
        .zlib => {
            if (encoded.len <= wire.text_v1.compressed_header_bytes) return error.InvalidSnapshot;
            const text_len = readU32(encoded[0..wire.text_v1.compressed_header_bytes]);
            if (text_len == 0 or text_len > wire.maximum_text_snapshot_bytes)
                return error.SnapshotTooLarge;
            const body = try inflate(allocator, encoded[wire.text_v1.compressed_header_bytes..], text_len);
            defer allocator.free(body);
            return decodeRecords(allocator, geometry, body);
        },
        .packed_zlib => {
            if (encoded.len <= wire.text_pack_v1.compressed_header_bytes) return error.InvalidSnapshot;
            const text_len = readU32(encoded[0..4]);
            const packed_len = readU32(encoded[4..8]);
            if (text_len == 0 or text_len > wire.maximum_text_snapshot_bytes or
                packed_len == 0 or packed_len > wire.text_pack_v1.maximum_body_bytes)
                return error.SnapshotTooLarge;
            const packed_body = try inflate(allocator, encoded[wire.text_pack_v1.compressed_header_bytes..], packed_len);
            defer allocator.free(packed_body);
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(allocator);
            wire.unpackTextV1(allocator, packed_body, text_len, &body) catch |failure| switch (failure) {
                error.SnapshotTooLarge => return error.SnapshotTooLarge,
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidSnapshot,
            };
            return decodeRecords(allocator, geometry, body.items);
        },
    }
}

fn inflate(allocator: std.mem.Allocator, encoded: []const u8, expected: u32) values.Error![]u8 {
    const body = try allocator.alloc(u8, expected);
    errdefer allocator.free(body);
    var output: std.Io.Writer = .fixed(body);
    var input: std.Io.Reader = .fixed(encoded);
    const work = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(work);
    var decompressor: std.compress.flate.Decompress = .init(&input, .zlib, work);
    const count = decompressor.reader.streamRemaining(&output) catch return error.InvalidSnapshot;
    if (count != expected or output.buffered().len != expected or input.seek != input.end)
        return error.InvalidSnapshot;
    // Decompress parses the container footer; its caller verifies the content.
    if (std.hash.Adler32.hash(body) != decompressor.container_metadata.zlib.adler)
        return error.InvalidSnapshot;
    return body;
}

const Decoder = struct {
    allocator: std.mem.Allocator,
    geometry: values.Geometry,
    rows: []values.Row,
    initialized_rows: usize = 0,
    hyperlinks: std.ArrayList(values.Hyperlink) = .empty,
    referenced: [wire.text_v1.maximum_hyperlinks + 1]bool = @splat(false),
    resolved: [wire.text_v1.maximum_hyperlinks + 1]bool = @splat(false),
    presentation: ?values.Presentation = null,
    phase: enum { presentation, rows, hyperlinks } = .presentation,

    fn deinit(self: *Decoder) void {
        values.deinitRows(self.allocator, self.rows[0..self.initialized_rows]);
        self.allocator.free(self.rows);
        for (self.hyperlinks.items) |link| self.allocator.free(link.uri_bytes);
        self.hyperlinks.deinit(self.allocator);
    }

    fn record(self: *Decoder, kind: wire.TextRecordKind, payload: []const u8) values.Error!void {
        switch (kind) {
            .presentation => {
                if (self.phase != .presentation or self.presentation != null) return error.InvalidSnapshot;
                self.presentation = try values.decodePresentation(payload);
                self.phase = if (self.geometry.rows == 0) .hyperlinks else .rows;
            },
            .row => {
                if (self.phase != .rows or self.initialized_rows >= self.rows.len)
                    return error.InvalidSnapshot;
                self.rows[self.initialized_rows] = try values.decodeRow(
                    self.allocator,
                    self.geometry.columns,
                    payload,
                    &self.referenced,
                );
                self.initialized_rows += 1;
                if (self.initialized_rows == self.rows.len) self.phase = .hyperlinks;
            },
            .hyperlink => {
                if (self.phase != .hyperlinks) return error.InvalidSnapshot;
                const link = try values.decodeHyperlink(self.allocator, payload, &self.referenced, &self.resolved);
                errdefer self.allocator.free(link.uri_bytes);
                try self.hyperlinks.append(self.allocator, link);
            },
            .row_shift => return error.InvalidSnapshot,
        }
    }
};

fn decodeRecords(
    allocator: std.mem.Allocator,
    geometry: values.Geometry,
    body: []const u8,
) values.Error!Text {
    // A claimed geometry must fit the mandatory fixed records before it can
    // induce any row allocation, even when all cell scalar lists are empty.
    const cells_bytes = std.math.mul(usize, geometry.columns, wire.text_v1.cell_header_bytes) catch
        return error.InvalidSnapshot;
    const row_bytes = std.math.add(
        usize,
        wire.text_v1.record_header_bytes + wire.text_v1.row_header_bytes,
        cells_bytes,
    ) catch return error.InvalidSnapshot;
    const rows_bytes = std.math.mul(usize, geometry.rows, row_bytes) catch return error.InvalidSnapshot;
    const minimum_bytes = std.math.add(
        usize,
        wire.text_v1.record_header_bytes + wire.text_v1.presentation_bytes,
        rows_bytes,
    ) catch return error.InvalidSnapshot;
    if (body.len < minimum_bytes) return error.InvalidSnapshot;

    var decoder = Decoder{
        .allocator = allocator,
        .geometry = geometry,
        .rows = try allocator.alloc(values.Row, geometry.rows),
    };
    errdefer decoder.deinit();
    var offset: usize = 0;
    while (offset < body.len) {
        if (body.len - offset < wire.text_v1.record_header_bytes) return error.InvalidSnapshot;
        var encoded_header: [wire.text_v1.record_header_bytes]u8 = undefined;
        @memcpy(&encoded_header, body[offset..][0..wire.text_v1.record_header_bytes]);
        const header = try wire.decodeTextRecordHeader(&encoded_header);
        const record_len = std.math.add(
            usize,
            wire.text_v1.record_header_bytes,
            header.payload_len,
        ) catch return error.InvalidSnapshot;
        if (record_len > body.len - offset) return error.InvalidSnapshot;
        try decoder.record(header.kind, body[offset + wire.text_v1.record_header_bytes ..][0..header.payload_len]);
        offset += record_len;
    }
    if (decoder.presentation == null or decoder.initialized_rows != decoder.rows.len)
        return error.InvalidSnapshot;
    for (decoder.referenced[1..], decoder.resolved[1..]) |needed, seen| if (needed != seen)
        return error.InvalidSnapshot;
    return .{
        .allocator = allocator,
        .presentation = decoder.presentation.?,
        .rows = decoder.rows,
        .hyperlinks = try decoder.hyperlinks.toOwnedSlice(allocator),
    };
}

fn readU32(bytes: []const u8) u32 {
    std.debug.assert(bytes.len >= 4);
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        bytes[3];
}

fn writeU32(bytes: []u8, value: u32) void {
    std.debug.assert(bytes.len >= 4);
    bytes[0] = @intCast((value >> 24) & 0xff);
    bytes[1] = @intCast((value >> 16) & 0xff);
    bytes[2] = @intCast((value >> 8) & 0xff);
    bytes[3] = @intCast(value & 0xff);
}

fn testRecord(allocator: std.mem.Allocator, body: *std.ArrayList(u8), kind: wire.TextRecordKind, payload: []const u8) !void {
    var header: [wire.text_v1.record_header_bytes]u8 = undefined;
    wire.encodeTextRecordHeader(&header, .{ .kind = kind, .payload_len = @intCast(payload.len) });
    try body.appendSlice(allocator, &header);
    try body.appendSlice(allocator, payload);
}

fn testBody(allocator: std.mem.Allocator) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);
    var presentation: [wire.text_v1.presentation_bytes]u8 = @splat(0);
    presentation[12] = 0x7f;
    try testRecord(allocator, &body, .presentation, &presentation);
    var row: [wire.text_v1.row_header_bytes + 2 * wire.text_v1.cell_header_bytes + 8]u8 = @splat(0);
    row[3] = 2;
    row[4] = 2;
    row[5] = 1;
    row[6] = 1;
    writeU32(row[4 + 31 ..][0..4], 2);
    writeU32(row[4 + wire.text_v1.cell_header_bytes ..][0..4], 'e');
    writeU32(row[4 + wire.text_v1.cell_header_bytes + 4 ..][0..4], 0x0301);
    const second = 4 + wire.text_v1.cell_header_bytes + 8;
    row[second + 1] = 1;
    row[second + 2] = 1;
    try testRecord(allocator, &body, .row, &row);
    const link = [_]u8{ 0, 0, 0, 2, 0, 4, 'A', 0, 0xff, 'Z' };
    try testRecord(allocator, &body, .hyperlink, &link);
    return body.toOwnedSlice(allocator);
}

fn testEncode(allocator: std.mem.Allocator, encoding: Encoding, body: []const u8) ![]u8 {
    if (encoding == .raw) return allocator.dupe(u8, body);
    var packed_body: std.ArrayList(u8) = .empty;
    defer packed_body.deinit(allocator);
    if (encoding == .packed_zlib) try wire.packTextV1(allocator, body, &packed_body);
    const input = if (encoding == .packed_zlib) packed_body.items else body;
    var compressed = try std.Io.Writer.Allocating.initCapacity(allocator, 64);
    defer compressed.deinit();
    const work = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(work);
    var huffman = try std.compress.flate.Compress.Huffman.init(&compressed.writer, work, .zlib);
    try huffman.writer.writeAll(input);
    try huffman.finish();
    const prefix: usize = if (encoding == .zlib)
        wire.text_v1.compressed_header_bytes
    else
        wire.text_pack_v1.compressed_header_bytes;
    const result = try allocator.alloc(u8, prefix + compressed.written().len);
    writeU32(result[0..4], @intCast(body.len));
    if (encoding == .packed_zlib) writeU32(result[4..8], @intCast(packed_body.items.len));
    @memcpy(result[prefix..], compressed.written());
    return result;
}

fn testDecodeAllocation(allocator: std.mem.Allocator, encoding: Encoding, encoded: []const u8) !void {
    var text = try decode(allocator, .{ .rows = 1, .columns = 2 }, encoding, encoded);
    defer text.deinit();
    try std.testing.expectEqual(@as(usize, 1), text.rows.len);
    try std.testing.expectEqual(@as(usize, 1), text.hyperlinks.len);
    try std.testing.expectEqualSlices(u32, &.{ 'e', 0x0301 }, text.rows[0].cells[0].scalars);
}

test "complete text encodings own scalar and URI bytes independently of input" {
    const body = try testBody(std.testing.allocator);
    defer std.testing.allocator.free(body);
    for (std.enums.values(Encoding)) |encoding| {
        const encoded = try testEncode(std.testing.allocator, encoding, body);
        defer std.testing.allocator.free(encoded);
        var text = try decode(std.testing.allocator, .{ .rows = 1, .columns = 2 }, encoding, encoded);
        defer text.deinit();
        @memset(encoded, 0);
        try std.testing.expectEqual(@as(u8, 0x7f), text.presentation.palette[0].r);
        try std.testing.expectEqualSlices(u32, &.{ 'e', 0x0301 }, text.rows[0].cells[0].scalars);
        try std.testing.expectEqualSlices(u8, &.{ 'A', 0, 0xff, 'Z' }, text.hyperlinks[0].uri_bytes);
    }
}

test "complete text decoding unwinds every allocation including URI append handoff" {
    const body = try testBody(std.testing.allocator);
    defer std.testing.allocator.free(body);
    for (std.enums.values(Encoding)) |encoding| {
        const encoded = try testEncode(std.testing.allocator, encoding, body);
        defer std.testing.allocator.free(encoded);
        try std.testing.checkAllAllocationFailures(std.testing.allocator, testDecodeAllocation, .{ encoding, encoded });
    }
}

test "complete text decoding rejects impossible geometry before row allocation" {
    const body = try testBody(std.testing.allocator);
    defer std.testing.allocator.free(body);
    var storage: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    try std.testing.expectError(error.InvalidSnapshot, decode(
        fixed.allocator(),
        .{ .rows = 65535, .columns = 65535 },
        .raw,
        body,
    ));
}

test "deflated text rejects corrupt footer trailing bytes and length mismatch" {
    const body = try testBody(std.testing.allocator);
    defer std.testing.allocator.free(body);
    for ([_]Encoding{ .zlib, .packed_zlib }) |encoding| {
        const encoded = try testEncode(std.testing.allocator, encoding, body);
        defer std.testing.allocator.free(encoded);
        for (1..5) |trailer_offset| {
            encoded[encoded.len - trailer_offset] ^= 0xff;
            defer encoded[encoded.len - trailer_offset] ^= 0xff;
            try std.testing.expectError(error.InvalidSnapshot, decode(
                std.testing.allocator,
                .{ .rows = 1, .columns = 2 },
                encoding,
                encoded,
            ));
        }
        try std.testing.expectError(error.InvalidSnapshot, decode(
            std.testing.allocator,
            .{ .rows = 1, .columns = 2 },
            encoding,
            encoded[0 .. encoded.len - 1],
        ));
        const trailing = try std.testing.allocator.alloc(u8, encoded.len + 1);
        defer std.testing.allocator.free(trailing);
        @memcpy(trailing[0..encoded.len], encoded);
        trailing[encoded.len] = 0;
        try std.testing.expectError(error.InvalidSnapshot, decode(
            std.testing.allocator,
            .{ .rows = 1, .columns = 2 },
            encoding,
            trailing,
        ));
        const old_len = readU32(encoded[0..4]);
        writeU32(encoded[0..4], old_len - 1);
        try std.testing.expectError(error.InvalidSnapshot, decode(
            std.testing.allocator,
            .{ .rows = 1, .columns = 2 },
            encoding,
            encoded,
        ));
        writeU32(encoded[0..4], wire.maximum_text_snapshot_bytes + 1);
        try std.testing.expectError(error.SnapshotTooLarge, decode(
            std.testing.allocator,
            .{ .rows = 1, .columns = 2 },
            encoding,
            encoded,
        ));
    }
}

fn testLateInvalidAllocation(allocator: std.mem.Allocator, body: []const u8) !void {
    var text = decode(allocator, .{ .rows = 1, .columns = 2 }, .raw, body) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.InvalidSnapshot => return,
        else => return err,
    };
    text.deinit();
    return error.TestUnexpectedResult;
}

test "late duplicate hyperlink unwinds prior decoded rows and URIs" {
    const body = try testBody(std.testing.allocator);
    defer std.testing.allocator.free(body);
    var duplicate: std.ArrayList(u8) = .empty;
    defer duplicate.deinit(std.testing.allocator);
    try duplicate.appendSlice(std.testing.allocator, body);
    const link = [_]u8{ 0, 0, 0, 2, 0, 4, 'A', 0, 0xff, 'Z' };
    try testRecord(std.testing.allocator, &duplicate, .hyperlink, &link);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testLateInvalidAllocation, .{duplicate.items});
}

test "empty full text observation preserves zero viewport behavior" {
    var body: [wire.text_v1.record_header_bytes + wire.text_v1.presentation_bytes]u8 = @splat(0);
    var header: [wire.text_v1.record_header_bytes]u8 = undefined;
    wire.encodeTextRecordHeader(&header, .{ .kind = .presentation, .payload_len = wire.text_v1.presentation_bytes });
    @memcpy(body[0..header.len], &header);
    for (std.enums.values(Encoding)) |encoding| {
        const encoded = try testEncode(std.testing.allocator, encoding, &body);
        defer std.testing.allocator.free(encoded);
        var text = try decode(std.testing.allocator, .{ .rows = 0, .columns = 0 }, encoding, encoded);
        defer text.deinit();
        try std.testing.expectEqual(@as(usize, 0), text.rows.len);
        try std.testing.expectEqual(@as(usize, 0), text.hyperlinks.len);
    }
}

test "full text rejects missing links and delta-only records" {
    const body = try testBody(std.testing.allocator);
    defer std.testing.allocator.free(body);
    const link_record_bytes = wire.text_v1.record_header_bytes + wire.text_v1.hyperlink_header_bytes + 4;
    try std.testing.expectError(error.InvalidSnapshot, decode(
        std.testing.allocator,
        .{ .rows = 1, .columns = 2 },
        .raw,
        body[0 .. body.len - link_record_bytes],
    ));
    var extra: std.ArrayList(u8) = .empty;
    defer extra.deinit(std.testing.allocator);
    try extra.appendSlice(std.testing.allocator, body);
    const shift = [_]u8{ 0, 0 };
    try testRecord(std.testing.allocator, &extra, .row_shift, &shift);
    try std.testing.expectError(error.InvalidSnapshot, decode(
        std.testing.allocator,
        .{ .rows = 1, .columns = 2 },
        .raw,
        extra.items,
    ));
    extra.shrinkRetainingCapacity(body.len);
    const unused_link = [_]u8{ 0, 0, 0, 3, 0, 4, 'A', 0, 0xff, 'Z' };
    try testRecord(std.testing.allocator, &extra, .hyperlink, &unused_link);
    try std.testing.expectError(error.InvalidSnapshot, decode(
        std.testing.allocator,
        .{ .rows = 1, .columns = 2 },
        .raw,
        extra.items,
    ));
    extra.shrinkRetainingCapacity(body.len);
    const empty_row: [0]u8 = .{};
    try testRecord(std.testing.allocator, &extra, .row, &empty_row);
    try std.testing.expectError(error.InvalidSnapshot, decode(
        std.testing.allocator,
        .{ .rows = 1, .columns = 2 },
        .raw,
        extra.items,
    ));
}

test "retained compression preserves complete text and copies bounded length prefixes" {
    const allocator = std.testing.allocator;
    const body = try testBody(allocator);
    defer allocator.free(body);
    var compressor = try Compressor.init(allocator);
    defer compressor.deinit();
    const work = compressor.work.ptr;
    const state = compressor.compressor;
    for ([_]Compression{ .zlib, .packed_zlib, .zlib, .packed_zlib }) |mode| {
        const encoded = try compressor.compress(mode, body);
        try std.testing.expectEqual(work, compressor.work.ptr);
        try std.testing.expectEqual(state, compressor.compressor);
        try std.testing.expectEqual(encoded.data.ptr, compressor.output.written().ptr);
        try std.testing.expectEqual(body.len, readU32(encoded.prefix()[0..4]));
        if (mode == .packed_zlib) {
            try std.testing.expectEqual(compressor.packed_body.items.len, readU32(encoded.prefix()[4..8]));
        } else {
            try std.testing.expectEqual(@as(usize, 0), compressor.packed_body.items.len);
        }
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(allocator);
        try joined.appendSlice(allocator, encoded.prefix());
        try joined.appendSlice(allocator, encoded.data);
        try std.testing.expectEqual(encoded.size(), joined.items.len);
        var text = try decode(allocator, .{ .rows = 1, .columns = 2 }, if (mode == .zlib) .zlib else .packed_zlib, joined.items);
        defer text.deinit();
        try std.testing.expectEqualSlices(u32, &.{ 'e', 0x0301 }, text.rows[0].cells[0].scalars);
        try std.testing.expectEqualSlices(u8, &.{ 'A', 0, 0xff, 'Z' }, text.hyperlinks[0].uri_bytes);
        try std.testing.expectEqual(@as(u8, 0x7f), text.presentation.palette[0].r);
    }
}

fn testCompressAllocation(allocator: std.mem.Allocator, body: []const u8) !void {
    var compressor = try Compressor.init(allocator);
    defer compressor.deinit();
    for ([_]Compression{ .zlib, .packed_zlib }) |mode| {
        const result = compressor.compress(mode, body) catch |err| {
            try std.testing.expectEqual(@as(usize, 0), compressor.output.written().len);
            try std.testing.expectEqual(@as(usize, 0), compressor.packed_body.items.len);
            return err;
        };
        try std.testing.expectEqual(body.len, readU32(result.prefix()[0..4]));
        try std.testing.expect(result.data.len != 0);
    }
}

test "compression allocation failure releases partial construction and reusable output" {
    const body = try testBody(std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testCompressAllocation, .{body});
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var compressor = try Compressor.init(failing.allocator());
    defer compressor.deinit();
    const first = try compressor.compress(.zlib, body);
    try std.testing.expect(first.data.len != 0);
    const random_body = try std.testing.allocator.alloc(u8, 128 * 1024);
    defer std.testing.allocator.free(random_body);
    var random = std.Random.DefaultPrng.init(0x6121_3213_abc1_4431);
    random.random().bytes(random_body);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, compressor.compress(.zlib, random_body));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), compressor.output.written().len);
    failing.fail_index = std.math.maxInt(usize);
    const recovered = try compressor.compress(.zlib, random_body);
    const inflated = try inflate(std.testing.allocator, recovered.data, @intCast(random_body.len));
    defer std.testing.allocator.free(inflated);
    try std.testing.expectEqualSlices(u8, random_body, inflated);
}

test "compression rejects empty oversized and malformed packed bodies then recovers" {
    const allocator = std.testing.allocator;
    const body = try testBody(allocator);
    defer allocator.free(body);
    var compressor = try Compressor.init(allocator);
    defer compressor.deinit();
    const oversize = try allocator.alloc(u8, wire.maximum_text_snapshot_bytes + 1);
    defer allocator.free(oversize);
    for ([_]Compression{ .zlib, .packed_zlib }) |mode| {
        try std.testing.expectError(error.SnapshotTooLarge, compressor.compress(mode, &.{}));
        try std.testing.expectError(error.SnapshotTooLarge, compressor.compress(mode, oversize));
    }
    try std.testing.expectError(error.InvalidSnapshot, compressor.compress(.packed_zlib, body[0 .. body.len - 1]));
    try std.testing.expectEqual(@as(usize, 0), compressor.output.written().len);
    try std.testing.expectEqual(@as(usize, 0), compressor.packed_body.items.len);
    const recovered = try compressor.compress(.packed_zlib, body);
    try std.testing.expect(recovered.size() <= wire.maximum_text_snapshot_bytes);
    try std.testing.expectEqual(body.len, readU32(recovered.prefix()[0..4]));
}
