//! Transport-free complete/raw-delta text cache and borrowed observation lifetime.
const std = @import("std");
const wire = @import("wire.zig");
const values = @import("decoded.zig");
const Row = values.Row;
const Hyperlink = values.Hyperlink;
const Presentation = values.Presentation;
const decodePresentation = values.decodePresentation;
const decodeRow = values.decodeRow;
const decodeHyperlink = values.decodeHyperlink;
const deinitRows = values.deinitRows;

/// Full bodies are standalone; delta bodies may reuse the accepted row cache.
pub const Mode = enum { full, delta };

/// Borrows terminal text facts until the cache decodes, invalidates or deinitializes.
/// No slice borrows the encoded input. The changed mask names no delivery revision.
pub const View = struct {
    presentation: Presentation,
    rows: []const Row,
    hyperlinks: []const Hyperlink,
    changed_rows: []const bool,
    row_shift: ?u16,
};

const CachedRowRecord = struct {
    encoded: []u8 = &.{},
    link_ids: []u16 = &.{},
};

/// Retains exact decoded rows, scalar banks, encoded comparisons and URI bytes.
/// This owns no framing, requests, revisions, graphics or authority state.
pub const Cache = struct {
    allocator: std.mem.Allocator,
    rows: []Row = &.{},
    row_records: []CachedRowRecord = &.{},
    changed_rows: []bool = &.{},
    columns: u16 = 0,
    hyperlinks: []Hyperlink = &.{},
    complete: bool = false,

    /// Creates an empty cache without allocating.
    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{ .allocator = allocator };
    }

    /// Releases all retained row, scalar, encoded-record and URI allocations.
    pub fn deinit(self: *Cache) void {
        self.clearRows();
        self.clearHyperlinks();
        self.* = undefined;
    }

    /// Reports a complete prior text cut with exactly this viewport geometry.
    pub fn canReuse(self: *const Cache, geometry: values.Geometry) bool {
        return self.complete and self.rows.len == geometry.rows and self.columns == geometry.columns;
    }

    /// Invalidates every borrowed fact and row-reuse right; grid capacity remains.
    pub fn invalidate(self: *Cache) void {
        self.invalidateRows();
        self.clearHyperlinks();
    }

    /// Decodes one complete or explicit delta text body with nonzero rows/columns.
    /// Delta requires this cache's complete matching geometry; the caller owns
    /// delivery identity and must authorize the exact predecessor independently.
    /// Every failure invalidates retained row/link facts before returning.
    pub fn decode(
        self: *Cache,
        geometry: values.Geometry,
        mode: Mode,
        encoded: []const u8,
    ) values.Error!View {
        errdefer self.invalidate();
        const allow_row_reuse = mode == .delta;
        if (encoded.len == 0 or encoded.len > wire.maximum_text_snapshot_bytes)
            return error.SnapshotTooLarge;
        if (allow_row_reuse and !self.canReuse(geometry)) return error.InvalidSnapshot;
        if (encoded.len < try minimumBodyBytes(geometry, mode)) return error.InvalidSnapshot;
        try self.ensureGeometry(geometry.rows, geometry.columns);
        @memset(self.changed_rows, false);
        var row_shift_seen = false;
        var rows_up: u16 = 0;

        var referenced: [wire.text_v1.maximum_hyperlinks + 1]bool = @splat(false);
        var resolved: [wire.text_v1.maximum_hyperlinks + 1]bool = @splat(false);
        var presentation: Presentation = undefined;
        var presentation_seen = false;
        var row_count: u16 = 0;
        var phase: DecodePhase = .presentation;
        var links: std.ArrayList(Hyperlink) = .empty;
        errdefer {
            for (links.items) |link| self.allocator.free(link.uri_bytes);
            links.deinit(self.allocator);
        }

        var offset: usize = 0;
        while (offset < encoded.len) {
            if (encoded.len - offset < wire.text_v1.record_header_bytes)
                return error.InvalidSnapshot;
            var encoded_header: [wire.text_v1.record_header_bytes]u8 = undefined;
            @memcpy(&encoded_header, encoded[offset..][0..wire.text_v1.record_header_bytes]);
            const header = try wire.decodeTextRecordHeader(&encoded_header);
            const record_len = std.math.add(
                usize,
                wire.text_v1.record_header_bytes,
                header.payload_len,
            ) catch return error.InvalidSnapshot;
            if (record_len > encoded.len - offset) return error.InvalidSnapshot;
            const record = encoded[offset..][0..record_len];
            const payload = record[wire.text_v1.record_header_bytes..];
            switch (header.kind) {
                .presentation => {
                    if (phase != .presentation or presentation_seen) return error.InvalidSnapshot;
                    presentation = try decodePresentation(payload);
                    presentation_seen = true;
                    phase = .rows;
                },
                .row_shift => {
                    if (!allow_row_reuse or phase != .rows or !presentation_seen or
                        row_shift_seen or row_count != 0)
                        return error.InvalidSnapshot;
                    rows_up = try wire.decodeTextRowShift(payload);
                    if (rows_up >= geometry.rows and rows_up != 0) return error.InvalidSnapshot;
                    if (rows_up != 0) {
                        for (self.row_records) |cached_record|
                            if (cached_record.encoded.len == 0) return error.InvalidSnapshot;
                        self.rotateRowsUp(rows_up);
                    }
                    row_shift_seen = true;
                },
                .row => {
                    if (phase != .rows or !presentation_seen or row_count >= geometry.rows)
                        return error.InvalidSnapshot;
                    if (allow_row_reuse and !row_shift_seen) return error.InvalidSnapshot;
                    const row_index: usize = row_count;
                    const cached = self.row_records[row_index].encoded;
                    if (payload.len == 0) {
                        if (!allow_row_reuse or cached.len == 0) return error.InvalidSnapshot;
                        for (self.row_records[row_index].link_ids) |link_id| referenced[link_id] = true;
                    } else if (cached.len != 0 and std.mem.eql(u8, cached, record)) {
                        for (self.row_records[row_index].link_ids) |link_id| referenced[link_id] = true;
                    } else {
                        const replacement = try self.decodeCachedRow(geometry.columns, payload, record, &referenced);
                        errdefer replacement.deinit(self.allocator);
                        self.replaceRow(row_index, replacement);
                        self.changed_rows[row_index] = true;
                    }
                    row_count += 1;
                    if (row_count == geometry.rows) phase = .hyperlinks;
                },
                .hyperlink => {
                    if (phase != .hyperlinks) return error.InvalidSnapshot;
                    const link = try decodeHyperlink(self.allocator, payload, &referenced, &resolved);
                    errdefer self.allocator.free(link.uri_bytes);
                    try links.append(self.allocator, link);
                },
            }
            offset += record_len;
        }
        if (!presentation_seen or row_count != geometry.rows or allow_row_reuse != row_shift_seen)
            return error.InvalidSnapshot;
        for (referenced[1..], resolved[1..]) |needed, seen| if (needed != seen)
            return error.InvalidSnapshot;

        const accepted_links = try links.toOwnedSlice(self.allocator);
        self.clearHyperlinks();
        self.hyperlinks = accepted_links;
        self.complete = true;
        return .{
            .presentation = presentation,
            .rows = self.rows,
            .hyperlinks = self.hyperlinks,
            .changed_rows = self.changed_rows,
            .row_shift = if (rows_up == 0) null else rows_up,
        };
    }

    const RowReplacement = struct {
        row: Row,
        encoded: []u8,
        link_ids: []u16,

        fn deinit(self: RowReplacement, allocator: std.mem.Allocator) void {
            deinitRows(allocator, @as(*const [1]Row, &self.row));
            allocator.free(self.encoded);
            allocator.free(self.link_ids);
        }
    };

    fn decodeCachedRow(
        self: *Cache,
        columns: u16,
        payload: []const u8,
        record: []const u8,
        referenced: *[wire.text_v1.maximum_hyperlinks + 1]bool,
    ) values.Error!RowReplacement {
        const row = try decodeRow(self.allocator, columns, payload, referenced);
        errdefer deinitRows(self.allocator, @as(*const [1]Row, &row));
        var link_count: usize = 0;
        for (row.cells) |cell| {
            if (cell.link_id != 0) link_count += 1;
        }
        const link_ids = try self.allocator.alloc(u16, link_count);
        errdefer self.allocator.free(link_ids);
        var used: usize = 0;
        for (row.cells) |cell| {
            if (cell.link_id == 0) continue;
            link_ids[used] = @intCast(cell.link_id);
            used += 1;
        }
        const copied = try self.allocator.dupe(u8, record);
        return .{ .row = row, .encoded = copied, .link_ids = link_ids };
    }

    fn replaceRow(self: *Cache, index: usize, replacement: RowReplacement) void {
        // Wire admission has already checked the viewport index. Replacing a
        // retained row must retire its old owned buffers exactly once; an
        // out-of-range index here is broken local bookkeeping, not bad input.
        std.debug.assert(index < self.rows.len);
        if (self.row_records[index].encoded.len != 0) {
            deinitRows(self.allocator, self.rows[index .. index + 1]);
            self.allocator.free(self.row_records[index].encoded);
            self.allocator.free(self.row_records[index].link_ids);
        }
        self.rows[index] = replacement.row;
        self.row_records[index] = .{
            .encoded = replacement.encoded,
            .link_ids = replacement.link_ids,
        };
    }

    fn rotateRowsUp(self: *Cache, shift: u16) void {
        // A complete-window shift has no reusable baseline. Partial shifts
        // first retire evicted rows, then transfer ownership of retained rows
        // without copying or freeing their scalar and hyperlink allocations.
        std.debug.assert(shift > 0 and shift < self.rows.len);
        const amount: usize = shift;
        const retained = self.rows.len - amount;
        for (0..amount) |index| self.clearCachedRow(index);
        std.mem.copyForwards(Row, self.rows[0..retained], self.rows[amount..]);
        std.mem.copyForwards(
            CachedRowRecord,
            self.row_records[0..retained],
            self.row_records[amount..],
        );
        for (self.row_records[retained..]) |*record| record.* = .{};
        for (self.rows[retained..]) |*row| row.* = undefined;
    }

    fn clearCachedRow(self: *Cache, index: usize) void {
        std.debug.assert(index < self.rows.len);
        const record = &self.row_records[index];
        if (record.encoded.len == 0) return;
        deinitRows(self.allocator, self.rows[index .. index + 1]);
        self.allocator.free(record.encoded);
        self.allocator.free(record.link_ids);
        record.* = .{};
    }

    fn ensureGeometry(self: *Cache, rows: u16, columns: u16) values.Error!void {
        if (rows == 0 or columns == 0) return error.InvalidSnapshot;
        if (self.rows.len == rows and self.columns == columns) return;
        self.clearRows();
        self.rows = try self.allocator.alloc(Row, rows);
        errdefer {
            self.allocator.free(self.rows);
            self.rows = &.{};
        }
        self.row_records = try self.allocator.alloc(CachedRowRecord, rows);
        errdefer {
            self.allocator.free(self.row_records);
            self.row_records = &.{};
        }
        self.changed_rows = try self.allocator.alloc(bool, rows);
        errdefer {
            self.allocator.free(self.changed_rows);
            self.changed_rows = &.{};
        }
        for (self.row_records) |*record| record.* = .{};
        @memset(self.changed_rows, true);
        self.columns = columns;
    }

    fn invalidateRows(self: *Cache) void {
        self.complete = false;
        for (self.row_records, 0..) |_, index| self.clearCachedRow(index);
        if (self.changed_rows.len != 0) @memset(self.changed_rows, true);
    }

    fn clearRows(self: *Cache) void {
        self.invalidateRows();
        if (self.changed_rows.len != 0) self.allocator.free(self.changed_rows);
        if (self.row_records.len != 0) self.allocator.free(self.row_records);
        if (self.rows.len != 0) self.allocator.free(self.rows);
        self.rows = &.{};
        self.row_records = &.{};
        self.changed_rows = &.{};
        self.columns = 0;
    }

    fn clearHyperlinks(self: *Cache) void {
        for (self.hyperlinks) |link| self.allocator.free(link.uri_bytes);
        if (self.hyperlinks.len != 0) self.allocator.free(self.hyperlinks);
        self.hyperlinks = &.{};
    }
};

const DecodePhase = enum { presentation, rows, hyperlinks };

fn minimumBodyBytes(geometry: values.Geometry, mode: Mode) error{InvalidSnapshot}!usize {
    // Full bodies must fit mandatory cell/row records before inducing allocation.
    // Delta can omit row payloads only with a complete matching cache.
    const cell_bytes = if (mode == .full)
        std.math.mul(usize, geometry.columns, wire.text_v1.cell_header_bytes) catch return error.InvalidSnapshot
    else
        0;
    const row_bytes = std.math.add(
        usize,
        wire.text_v1.record_header_bytes + if (mode == .full) wire.text_v1.row_header_bytes else @as(usize, 0),
        cell_bytes,
    ) catch return error.InvalidSnapshot;
    const rows_bytes = std.math.mul(usize, geometry.rows, row_bytes) catch return error.InvalidSnapshot;
    const fixed_bytes = wire.text_v1.record_header_bytes + wire.text_v1.presentation_bytes +
        if (mode == .delta) wire.text_v1.record_header_bytes + wire.text_delta_v2.row_shift_bytes else @as(usize, 0);
    return std.math.add(usize, fixed_bytes, rows_bytes) catch return error.InvalidSnapshot;
}

fn testRawCacheDeltaBody(allocator: std.mem.Allocator, first: u32) ![]u8 {
    const full = try testRawCacheBody(allocator, first, 'Z');
    defer allocator.free(full);
    const presentation_record = wire.text_v1.record_header_bytes + wire.text_v1.presentation_bytes;
    const shift_record = wire.text_v1.record_header_bytes + wire.text_delta_v2.row_shift_bytes;
    const row_payload = wire.text_v1.row_header_bytes + wire.text_v1.cell_header_bytes + @sizeOf(u32);
    const row_record = wire.text_v1.record_header_bytes + row_payload;
    const body = try allocator.alloc(u8, presentation_record + shift_record + row_record + wire.text_v1.record_header_bytes);
    @memcpy(body[0..presentation_record], full[0..presentation_record]);
    var at = presentation_record;
    wire.encodeTextRecordHeader(body[at..][0..wire.text_v1.record_header_bytes], .{
        .kind = .row_shift,
        .payload_len = wire.text_delta_v2.row_shift_bytes,
    });
    at += wire.text_v1.record_header_bytes;
    wire.encodeTextRowShift(body[at..][0..wire.text_delta_v2.row_shift_bytes], 0);
    at += wire.text_delta_v2.row_shift_bytes;
    @memcpy(body[at..][0..row_record], full[presentation_record..][0..row_record]);
    at += row_record;
    wire.encodeTextRecordHeader(body[at..][0..wire.text_v1.record_header_bytes], .{
        .kind = .row,
        .payload_len = 0,
    });
    return body;
}

fn testRawCacheShiftedDeltaBody(allocator: std.mem.Allocator, bottom: u32) ![]u8 {
    const full = try testRawCacheBody(allocator, 'Z', bottom);
    defer allocator.free(full);
    const presentation_record = wire.text_v1.record_header_bytes + wire.text_v1.presentation_bytes;
    const shift_record = wire.text_v1.record_header_bytes + wire.text_delta_v2.row_shift_bytes;
    const row_payload = wire.text_v1.row_header_bytes + wire.text_v1.cell_header_bytes + @sizeOf(u32);
    const row_record = wire.text_v1.record_header_bytes + row_payload;
    const body = try allocator.alloc(u8, presentation_record + shift_record + wire.text_v1.record_header_bytes + row_record);
    @memcpy(body[0..presentation_record], full[0..presentation_record]);
    var at = presentation_record;
    wire.encodeTextRecordHeader(body[at..][0..wire.text_v1.record_header_bytes], .{
        .kind = .row_shift,
        .payload_len = wire.text_delta_v2.row_shift_bytes,
    });
    at += wire.text_v1.record_header_bytes;
    wire.encodeTextRowShift(body[at..][0..wire.text_delta_v2.row_shift_bytes], 1);
    at += wire.text_delta_v2.row_shift_bytes;
    wire.encodeTextRecordHeader(body[at..][0..wire.text_v1.record_header_bytes], .{
        .kind = .row,
        .payload_len = 0,
    });
    at += wire.text_v1.record_header_bytes;
    @memcpy(body[at..][0..row_record], full[presentation_record + row_record ..][0..row_record]);
    return body;
}

fn testRawCacheBody(allocator: std.mem.Allocator, first: u32, second: u32) ![]u8 {
    const presentation_record = wire.text_v1.record_header_bytes + wire.text_v1.presentation_bytes;
    const row_payload = wire.text_v1.row_header_bytes + wire.text_v1.cell_header_bytes + @sizeOf(u32);
    const row_record = wire.text_v1.record_header_bytes + row_payload;
    const body = try allocator.alloc(u8, presentation_record + 2 * row_record);
    @memset(body, 0);

    wire.encodeTextRecordHeader(body[0..wire.text_v1.record_header_bytes], .{
        .kind = .presentation,
        .payload_len = wire.text_v1.presentation_bytes,
    });
    var at = presentation_record;
    for ([_]u32{ first, second }) |scalar| {
        wire.encodeTextRecordHeader(body[at..][0..wire.text_v1.record_header_bytes], .{
            .kind = .row,
            .payload_len = row_payload,
        });
        at += wire.text_v1.record_header_bytes;
        const row = body[at..][0..row_payload];
        encodeU16(row[2..4], 1);
        const cell = row[wire.text_v1.row_header_bytes..][0..wire.text_v1.cell_header_bytes];
        cell[0] = 1;
        cell[1] = 1;
        cell[2] = 1;
        var color: [wire.text_v1.color_bytes]u8 = undefined;
        try wire.encodeTextColor(&color, .{ .kind = .default, .value = 0 });
        @memcpy(cell[16..21], &color);
        @memcpy(cell[21..26], &color);
        @memcpy(cell[26..31], &color);
        encodeU32(row[row_payload - 4 ..], scalar);
        at += row_payload;
    }
    std.debug.assert(at == body.len);
    return body;
}

test "raw cache reuses byte-identical decoded rows" {
    const allocator = std.testing.allocator;
    var cache = Cache.init(allocator);
    defer cache.deinit();

    const geometry: values.Geometry = .{ .rows = 2, .columns = 1 };
    const first_body = try testRawCacheBody(allocator, 'A', 'Z');
    defer allocator.free(first_body);
    const first = try cache.decode(geometry, .full, first_body);
    try std.testing.expectEqualSlices(bool, &.{ true, true }, first.changed_rows);
    try std.testing.expectEqual(@as(u32, 'A'), first.rows[0].cells[0].scalars[0]);
    const first_row_cells = first.rows[0].cells.ptr;
    const second_row_cells = first.rows[1].cells.ptr;

    const second = try cache.decode(geometry, .full, first_body);
    try std.testing.expectEqualSlices(bool, &.{ false, false }, second.changed_rows);
    try std.testing.expectEqual(first_row_cells, second.rows[0].cells.ptr);
    try std.testing.expectEqual(second_row_cells, second.rows[1].cells.ptr);

    const changed_body = try testRawCacheBody(allocator, 'B', 'Z');
    defer allocator.free(changed_body);
    const third = try cache.decode(geometry, .full, changed_body);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, third.changed_rows);
    try std.testing.expectEqual(@as(u32, 'B'), third.rows[0].cells[0].scalars[0]);
    try std.testing.expectEqual(second_row_cells, third.rows[1].cells.ptr);
}

test "raw cache accepts row reuse only in explicit delta bodies" {
    const allocator = std.testing.allocator;
    var cache = Cache.init(allocator);
    defer cache.deinit();

    const geometry: values.Geometry = .{ .rows = 2, .columns = 1 };
    const baseline_body = try testRawCacheBody(allocator, 'A', 'Z');
    defer allocator.free(baseline_body);
    const baseline = try cache.decode(geometry, .full, baseline_body);
    try std.testing.expectEqual(@as(u32, 'A'), baseline.rows[0].cells[0].scalars[0]);

    const delta_body = try testRawCacheDeltaBody(allocator, 'B');
    defer allocator.free(delta_body);
    const delta = try cache.decode(geometry, .delta, delta_body);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, delta.changed_rows);
    try std.testing.expect(delta.row_shift == null);
    try std.testing.expectEqual(@as(u32, 'B'), delta.rows[0].cells[0].scalars[0]);
    try std.testing.expectEqual(@as(u32, 'Z'), delta.rows[1].cells[0].scalars[0]);

    var complete_only = Cache.init(allocator);
    defer complete_only.deinit();
    const complete_baseline = try complete_only.decode(geometry, .full, baseline_body);
    try std.testing.expectEqual(@as(u32, 'Z'), complete_baseline.rows[1].cells[0].scalars[0]);
    try std.testing.expectError(
        error.InvalidSnapshot,
        complete_only.decode(geometry, .full, delta_body),
    );
}

test "raw cache applies explicit upward shift before row reuse" {
    const allocator = std.testing.allocator;
    var cache = Cache.init(allocator);
    defer cache.deinit();

    const geometry: values.Geometry = .{ .rows = 2, .columns = 1 };
    const baseline_body = try testRawCacheBody(allocator, 'A', 'Z');
    defer allocator.free(baseline_body);
    const baseline = try cache.decode(geometry, .full, baseline_body);
    const z_cells = baseline.rows[1].cells.ptr;

    const shifted_body = try testRawCacheShiftedDeltaBody(allocator, 'B');
    defer allocator.free(shifted_body);
    const shifted = try cache.decode(geometry, .delta, shifted_body);
    try std.testing.expectEqual(@as(?u16, 1), shifted.row_shift);
    try std.testing.expectEqualSlices(bool, &.{ false, true }, shifted.changed_rows);
    try std.testing.expectEqual(z_cells, shifted.rows[0].cells.ptr);
    try std.testing.expectEqual(@as(u32, 'Z'), shifted.rows[0].cells[0].scalars[0]);
    try std.testing.expectEqual(@as(u32, 'B'), shifted.rows[1].cells[0].scalars[0]);
}

fn testRawCacheHyperlinkAllocation(allocator: std.mem.Allocator, body: []const u8) !void {
    var cache = Cache.init(allocator);
    defer cache.deinit();
    const view = try cache.decode(.{ .rows = 2, .columns = 1 }, .full, body);
    try std.testing.expectEqual(@as(usize, 1), view.hyperlinks.len);
    try std.testing.expectEqualSlices(u8, &.{ 'A', 0, 0xff, 'Z' }, view.hyperlinks[0].uri_bytes);
}

test "raw cache hyperlink handoff unwinds at every allocation failure" {
    const rows = try testRawCacheBody(std.testing.allocator, 'A', 'Z');
    defer std.testing.allocator.free(rows);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    try body.appendSlice(std.testing.allocator, rows);
    const first_link = wire.text_v1.record_header_bytes + wire.text_v1.presentation_bytes +
        wire.text_v1.record_header_bytes + wire.text_v1.row_header_bytes + 31;
    encodeU32(body.items[first_link..][0..4], 2);
    const link = [_]u8{ 0, 0, 0, 2, 0, 4, 'A', 0, 0xff, 'Z' };
    var header: [wire.text_v1.record_header_bytes]u8 = undefined;
    wire.encodeTextRecordHeader(&header, .{ .kind = .hyperlink, .payload_len = link.len });
    try body.appendSlice(std.testing.allocator, &header);
    try body.appendSlice(std.testing.allocator, &link);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testRawCacheHyperlinkAllocation, .{body.items});
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

fn testLinkedBody(allocator: std.mem.Allocator, source: []const u8, first_row: usize) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);
    try body.appendSlice(allocator, source);
    const first_link = first_row + wire.text_v1.record_header_bytes + wire.text_v1.row_header_bytes + 31;
    encodeU32(body.items[first_link..][0..4], 2);
    const link = [_]u8{ 0, 0, 0, 2, 0, 4, 'A', 0, 0xff, 'Z' };
    var header: [wire.text_v1.record_header_bytes]u8 = undefined;
    wire.encodeTextRecordHeader(&header, .{ .kind = .hyperlink, .payload_len = link.len });
    try body.appendSlice(allocator, &header);
    try body.appendSlice(allocator, &link);
    return body.toOwnedSlice(allocator);
}

test "cache owns encoded comparisons scalars and exact URI bytes" {
    const allocator = std.testing.allocator;
    const rows = try testRawCacheBody(allocator, 'A', 'Z');
    defer allocator.free(rows);
    const presentation_bytes = wire.text_v1.record_header_bytes + wire.text_v1.presentation_bytes;
    const linked = try testLinkedBody(allocator, rows, presentation_bytes);
    defer allocator.free(linked);
    const repeated = try allocator.dupe(u8, linked);
    defer allocator.free(repeated);
    var cache = Cache.init(allocator);
    defer cache.deinit();
    const geometry: values.Geometry = .{ .rows = 2, .columns = 1 };
    const first = try cache.decode(geometry, .full, linked);
    const retained_cells = first.rows[0].cells.ptr;
    @memset(linked, 0);
    try std.testing.expectEqual(@as(u32, 'A'), first.rows[0].cells[0].scalars[0]);
    try std.testing.expectEqualSlices(u8, &.{ 'A', 0, 0xff, 'Z' }, first.hyperlinks[0].uri_bytes);
    const second = try cache.decode(geometry, .full, repeated);
    try std.testing.expectEqual(retained_cells, second.rows[0].cells.ptr);
    try std.testing.expectEqualSlices(bool, &.{ false, false }, second.changed_rows);
}

test "cold geometry-mismatched and failed caches cannot authorize delta reuse" {
    const allocator = std.testing.allocator;
    const full = try testRawCacheBody(allocator, 'A', 'Z');
    defer allocator.free(full);
    const delta = try testRawCacheDeltaBody(allocator, 'B');
    defer allocator.free(delta);
    const geometry: values.Geometry = .{ .rows = 2, .columns = 1 };
    var cache = Cache.init(allocator);
    defer cache.deinit();
    try std.testing.expectError(error.InvalidSnapshot, cache.decode(geometry, .delta, delta));
    const first = try cache.decode(geometry, .full, full);
    try std.testing.expectEqual(@as(u32, 'A'), first.rows[0].cells[0].scalars[0]);
    try std.testing.expect(cache.canReuse(geometry));
    try std.testing.expectError(error.InvalidSnapshot, cache.decode(.{ .rows = 2, .columns = 2 }, .delta, delta));
    try std.testing.expect(!cache.canReuse(geometry));
    try std.testing.expectError(error.InvalidSnapshot, cache.decode(geometry, .delta, delta));
    const recovered = try cache.decode(geometry, .full, full);
    try std.testing.expectEqualSlices(bool, &.{ true, true }, recovered.changed_rows);
    cache.invalidate();
    try std.testing.expect(!cache.canReuse(geometry));
    try std.testing.expectError(error.InvalidSnapshot, cache.decode(geometry, .delta, delta));
}

test "early malformed full body drops every reusable row fact" {
    const allocator = std.testing.allocator;
    const full = try testRawCacheBody(allocator, 'A', 'Z');
    defer allocator.free(full);
    const malformed = try allocator.dupe(u8, full);
    defer allocator.free(malformed);
    malformed[1] = 1; // Reserved record byte, before any decoded row changes.
    const geometry: values.Geometry = .{ .rows = 2, .columns = 1 };
    var cache = Cache.init(allocator);
    defer cache.deinit();
    const first = try cache.decode(geometry, .full, full);
    try std.testing.expectEqual(@as(u32, 'Z'), first.rows[1].cells[0].scalars[0]);
    try std.testing.expectError(error.InvalidPayload, cache.decode(geometry, .full, malformed));
    try std.testing.expect(!cache.canReuse(geometry));
    const recovered = try cache.decode(geometry, .full, full);
    try std.testing.expectEqualSlices(bool, &.{ true, true }, recovered.changed_rows);
}

test "delta ordering rotation and unresolved links invalidate partial rows" {
    const allocator = std.testing.allocator;
    const full = try testRawCacheBody(allocator, 'A', 'Z');
    defer allocator.free(full);
    const shifted = try testRawCacheShiftedDeltaBody(allocator, 'B');
    defer allocator.free(shifted);
    const late_invalid = try allocator.dupe(u8, shifted);
    defer allocator.free(late_invalid);
    const bottom_row = wire.text_v1.record_header_bytes + wire.text_v1.presentation_bytes +
        wire.text_v1.record_header_bytes + wire.text_delta_v2.row_shift_bytes + wire.text_v1.record_header_bytes;
    encodeU32(late_invalid[bottom_row + wire.text_v1.record_header_bytes + wire.text_v1.row_header_bytes + 31 ..][0..4], 2);
    const geometry: values.Geometry = .{ .rows = 2, .columns = 1 };
    var cache = Cache.init(allocator);
    defer cache.deinit();
    const first = try cache.decode(geometry, .full, full);
    try std.testing.expectEqual(@as(u32, 'A'), first.rows[0].cells[0].scalars[0]);
    try std.testing.expectError(error.InvalidSnapshot, cache.decode(geometry, .delta, full)); // No mandatory rotation record.
    const second = try cache.decode(geometry, .full, full);
    try std.testing.expectEqualSlices(bool, &.{ true, true }, second.changed_rows);
    try std.testing.expectError(error.InvalidSnapshot, cache.decode(geometry, .delta, late_invalid)); // Rotation/new row, then unresolved URI.
    try std.testing.expect(!cache.canReuse(geometry));
    const third = try cache.decode(geometry, .full, full);
    try std.testing.expectEqual(@as(u32, 'Z'), third.rows[1].cells[0].scalars[0]);
    const shift_at = wire.text_v1.record_header_bytes + wire.text_v1.presentation_bytes + wire.text_v1.record_header_bytes;
    encodeU16(shifted[shift_at..][0..2], geometry.rows);
    try std.testing.expectError(error.InvalidSnapshot, cache.decode(geometry, .delta, shifted));
    try std.testing.expect(!cache.canReuse(geometry));
}

test "full geometry must fit its mandatory records before cache allocation" {
    const full = try testRawCacheBody(std.testing.allocator, 'A', 'Z');
    defer std.testing.allocator.free(full);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var cache = Cache.init(failing.allocator());
    defer cache.deinit();
    try std.testing.expectError(error.InvalidSnapshot, cache.decode(.{ .rows = 65535, .columns = 65535 }, .full, full));
    try std.testing.expectError(error.InvalidSnapshot, cache.decode(.{ .rows = 0, .columns = 0 }, .full, full));
    try std.testing.expectError(error.SnapshotTooLarge, cache.decode(.{ .rows = 2, .columns = 1 }, .full, &.{}));
}

fn testAllocationTransition(
    allocator: std.mem.Allocator,
    baseline: []const u8,
    update: []const u8,
    shift: ?u16,
) !void {
    var cache = Cache.init(allocator);
    defer cache.deinit();
    const geometry: values.Geometry = .{ .rows = 2, .columns = 1 };
    const first = cache.decode(geometry, .full, baseline) catch |err| {
        try std.testing.expect(!cache.canReuse(geometry));
        try std.testing.expectError(error.InvalidSnapshot, cache.decode(geometry, .delta, update));
        return err;
    };
    try std.testing.expectEqual(@as(u32, 'A'), first.rows[0].cells[0].scalars[0]);
    const second = cache.decode(geometry, .delta, update) catch |err| {
        try std.testing.expect(!cache.canReuse(geometry));
        try std.testing.expectError(error.InvalidSnapshot, cache.decode(geometry, .delta, update));
        return err;
    };
    try std.testing.expectEqual(shift, second.row_shift);
    try std.testing.expectEqual(@as(u32, 'B'), second.rows[if (shift == null) 0 else 1].cells[0].scalars[0]);
    try std.testing.expect(cache.canReuse(geometry));
}

test "row replacement URI handoff and rotation unwind at every allocation failure" {
    const allocator = std.testing.allocator;
    const full = try testRawCacheBody(allocator, 'A', 'Z');
    defer allocator.free(full);
    const delta = try testRawCacheDeltaBody(allocator, 'B');
    defer allocator.free(delta);
    const presentation_bytes = wire.text_v1.record_header_bytes + wire.text_v1.presentation_bytes;
    const linked_full = try testLinkedBody(allocator, full, presentation_bytes);
    defer allocator.free(linked_full);
    const linked_delta = try testLinkedBody(allocator, delta, presentation_bytes + wire.text_v1.record_header_bytes + wire.text_delta_v2.row_shift_bytes);
    defer allocator.free(linked_delta);
    try std.testing.checkAllAllocationFailures(allocator, testAllocationTransition, .{ linked_full, linked_delta, @as(?u16, null) });
    const shifted = try testRawCacheShiftedDeltaBody(allocator, 'B');
    defer allocator.free(shifted);
    try std.testing.checkAllAllocationFailures(allocator, testAllocationTransition, .{ full, shifted, @as(?u16, 1) });
}
