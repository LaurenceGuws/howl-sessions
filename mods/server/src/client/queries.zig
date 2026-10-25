//! Optional native queries and independent results over the curated client graph.
//! Mutable raw-cache borrows never escape as foreign snapshots.
const std = @import("std");
const client = @import("server_client");
const terminal = client.terminal;
const view = terminal.view;
const selection = terminal.selection;
const c = @import("native_abi_types");

/// Closed query, canonical extraction, projection and connection failures.
pub const Error = client.Error || terminal.search.Error || terminal.rich.Error || view.Error || error{
    InvalidArgument,
    RequestTooLarge,
    BufferTooSmall,
    CoordinatesTooLarge,
};

comptime {
    if (c.HSC_MAX_SEARCH_QUERY_BYTES != c.HVT_MAX_SEARCH_QUERY_BYTES or
        c.HSC_MAX_SELECTION_BYTES != terminal.protocol.maximum_payload_bytes)
        @compileError("Native query bounds must match exact child-owned contracts");
}

/// Owns reusable decoding state tied to one complete accepted ready occurrence.
// zig-audit: acknowledge opaque_type
// reason: Only this owner may change the raw baseline or its exact attachment binding.
pub const Cache = opaque {};
const CacheImpl = struct {
    allocator: std.mem.Allocator,
    ready: client.protocol.AttachReady,
    raw: terminal.rich.RawCache,
};
fn cacheImpl(cache: *Cache) *CacheImpl {
    // zig-audit: acknowledge ptr_cast
    // reason: Cache is the exact opaque view of its constructor-owned CacheImpl allocation.
    // zig-audit: acknowledge align_cast
    // reason: The Cache handle preserves the native alignment of CacheImpl.
    return @ptrCast(@alignCast(cache));
}

/// Owns one canonical extraction independently of every connection and snapshot.
// zig-audit: acknowledge opaque_type
// reason: The caller receives immutable bytes without lending mutable allocation/lifetime state.
pub const Text = opaque {};
const TextImpl = struct { allocator: std.mem.Allocator, bytes: []u8 };
fn textImpl(text: *const Text) *const TextImpl {
    // zig-audit: acknowledge ptr_cast
    // reason: Text is the exact opaque view of its constructor-owned TextImpl allocation.
    // zig-audit: acknowledge align_cast
    // reason: The Text handle preserves the native alignment of TextImpl.
    return @ptrCast(@alignCast(text));
}

/// Binds a fresh empty cache without borrowing connection or interrupt storage.
pub fn createCache(allocator: std.mem.Allocator, connection: *terminal.Connection) Error!*Cache {
    // zig-audit: acknowledge discard
    // reason: Cache construction checks liveness without retaining or owning the borrowed descriptor.
    _ = try connection.readinessFd();
    const state = try allocator.create(CacheImpl);
    state.* = .{ .allocator = allocator, .ready = connection.identity(), .raw = terminal.rich.RawCache.init(allocator) };
    // zig-audit: acknowledge ptr_cast
    // reason: This constructor publishes only its complete matching CacheImpl allocation.
    return @ptrCast(state);
}

/// Drops only cache-owned state; published immutable snapshots remain live.
pub fn releaseCache(cache: *Cache) void {
    const state = cacheImpl(cache);
    const allocator = state.allocator;
    state.raw.deinit();
    allocator.destroy(state);
}

/// Completes one raw/delta transaction and copies an independent immutable view.
/// Pre-I/O rejection preserves cache; any later failure resets it for revision-zero retry.
pub fn observeCached(cache: *Cache, connection: *terminal.Connection, result_allocator: std.mem.Allocator, after: u64, offset: u32) Error!*view.Snapshot {
    const state = cacheImpl(cache);
    if (!std.meta.eql(state.ready, connection.identity())) return error.InvalidArgument;
    state.raw.sendDeltaRequest(connection, after, offset) catch |failure| switch (failure) {
        error.DeltaBaselineMismatch => return error.InvalidArgument,
        else => return failure,
    };
    errdefer {
        state.raw.deinit();
        state.raw = terminal.rich.RawCache.init(state.allocator);
    }
    const borrowed = try state.raw.receive(connection);
    // Receive has accepted the complete transaction. Projection failure must not
    // retire that usable stream; contradictory decoded facts are our invariant.
    return view.projectView(result_allocator, &borrowed) catch |failure| switch (failure) {
        error.InvalidRichSnapshot => error.Internal,
        else => failure,
    };
}

fn rangeFromC(value: *const c.hvt_selection_range) Error!selection.Range {
    if (value.found != 1 or value.columns == 0 or value.start_row < 0 or value.end_row < 0 or
        value.start_column >= value.columns or value.end_column >= value.columns or
        value.alternate_screen > 1 or !std.mem.allEqual(u8, &value._reserved, 0))
        return error.InvalidArgument;
    return .{
        .anchor = .{ .row = value.start_row, .column = value.start_column },
        .focus = .{ .row = value.end_row, .column = value.end_column },
        .columns = value.columns,
        .alternate_screen = value.alternate_screen == 1,
    };
}

/// Allocates the text owner before sending; output-copy OOM after complete data preserves I/O.
pub fn extract(allocator: std.mem.Allocator, connection: *terminal.Connection, value: *const c.hvt_selection_range) Error!*Text {
    const range = try rangeFromC(value);
    const state = try allocator.create(TextImpl);
    errdefer allocator.destroy(state);
    const bytes = try selection.extract(connection, allocator, range);
    state.* = .{ .allocator = allocator, .bytes = bytes };
    // zig-audit: acknowledge ptr_cast
    // reason: Only this complete TextImpl allocation is published as its matching opaque owner.
    return @ptrCast(state);
}

/// Borrows immutable canonical UTF-8 until the matching text owner is released.
pub fn textBytes(text: *const Text) []const u8 {
    return textImpl(text).bytes;
}

/// Releases canonical extraction bytes and their owner exactly once.
pub fn releaseText(text: *Text) void {
    const state = textImpl(text);
    state.allocator.free(state.bytes);
    state.allocator.destroy(state);
}

fn viewport(snapshot: *const view.Snapshot, row: u16, column: ?u16) Error!void {
    const meta = view.metadata(snapshot);
    if (row >= meta.rows or (if (column) |col| col >= meta.columns else false))
        return error.InvalidArgument;
}

fn coordinates(snapshot: *const view.Snapshot) Error!void {
    const meta = view.metadata(snapshot);
    if (meta.rows == 0) return error.InvalidArgument;
    if (meta.history_offset > meta.history_count) return error.InvalidPoint;
    const last = if (meta.alternate_screen)
        @as(u64, meta.rows) - 1
    else
        @as(u64, meta.history_row_base) + meta.history_count - meta.history_offset + meta.rows - 1;
    if (last > std.math.maxInt(i32)) return error.CoordinatesTooLarge;
}

fn queryInput(query: []const u8) Error!void {
    if (query.len > c.HSC_MAX_SEARCH_QUERY_BYTES) return error.RequestTooLarge;
    if (query.len == 0 or !std.unicode.utf8ValidateSlice(query)) return error.InvalidArgument;
}

fn searchResult(snapshot: *const view.Snapshot, found: ?terminal.search.Match) c.hvt_search_match {
    const meta = view.metadata(snapshot);
    var result = std.mem.zeroes(c.hvt_search_match);
    result.cut_revision = meta.revision;
    result.columns = meta.columns;
    result.alternate_screen = @intFromBool(meta.alternate_screen);
    result.complete = 1;
    result.scanned_snapshots = 1;
    if (found) |match| {
        result.found = 1;
        result.row = match.range.ordered().start.row;
        result.start_column = match.start_column;
        result.end_column = match.end_column;
    }
    return result;
}

/// Searches exactly one projected row from an inclusive canonical column bound.
pub fn searchRow(snapshot: *const view.Snapshot, allocator: std.mem.Allocator, query: []const u8, row: u16, column: u16, reverse: bool, out: *c.hvt_search_match) Error!void {
    out.* = std.mem.zeroes(c.hvt_search_match);
    try queryInput(query);
    try viewport(snapshot, row, column);
    try coordinates(snapshot);
    const found = try terminal.search.rowFrom(snapshot, allocator, query, row, column, reverse);
    out.* = searchResult(snapshot, found);
}

/// Searches this immutable viewport only; no history paging or cross-row match.
pub fn search(snapshot: *const view.Snapshot, allocator: std.mem.Allocator, query: []const u8, start_row: u16, reverse: bool, out: *c.hvt_search_match) Error!void {
    out.* = std.mem.zeroes(c.hvt_search_match);
    try queryInput(query);
    try viewport(snapshot, start_row, null);
    try coordinates(snapshot);
    const found = try terminal.search.first(snapshot, allocator, query, start_row, reverse);
    out.* = searchResult(snapshot, found);
}

/// Expands a word/visual row using canonical client geometry and painted width.
pub fn expandSelection(snapshot: *const view.Snapshot, kind: u32, row: u16, column: u16, out: *c.hvt_selection_range) Error!void {
    out.* = std.mem.zeroes(c.hvt_selection_range);
    if (kind != c.HVT_SELECTION_WORD and kind != c.HVT_SELECTION_VISUAL_ROW) return error.InvalidArgument;
    try viewport(snapshot, row, column);
    try coordinates(snapshot);
    const selected = if (kind == c.HVT_SELECTION_WORD)
        try selection.word(snapshot, row, column)
    else
        try selection.visualRow(snapshot, row);
    const range = selected orelse return;
    const ordered = range.ordered();
    const meta = view.metadata(snapshot);
    const first: i64 = if (meta.alternate_screen) 0 else @as(i64, meta.history_row_base) + meta.history_count - meta.history_offset;
    const end_row = @as(i64, ordered.end.row) - first;
    if (end_row < 0 or end_row >= meta.rows) return error.InvalidPoint;
    const span = selection.visualSpan(snapshot, range, @intCast(end_row)) orelse return error.InvalidPoint;
    out.* = .{
        .start_row = ordered.start.row,
        .end_row = ordered.end.row,
        .start_column = ordered.start.column,
        .end_column = span.end_column,
        .columns = range.columns,
        .found = 1,
        .alternate_screen = @intFromBool(range.alternate_screen),
        ._reserved = @splat(0),
    };
}

/// Classifies copied coordinates without mutating or retargeting their range.
pub fn selectionValidity(snapshot: *const view.Snapshot, value: *const c.hvt_selection_range) Error!u32 {
    const range = try rangeFromC(value);
    try coordinates(snapshot);
    return switch (range.validity(view.begin(snapshot))) {
        .valid => c.HSC_SELECTION_VALID,
        .context_changed => c.HSC_SELECTION_CONTEXT_CHANGED,
        .evicted => c.HSC_SELECTION_EVICTED,
    };
}

/// Copies the text-shaped intersection of a range with this snapshot's row.
pub fn selectionSpan(snapshot: *const view.Snapshot, value: *const c.hvt_selection_range, row: u16, out: *c.hsc_selection_span) Error!void {
    out.* = std.mem.zeroes(c.hsc_selection_span);
    const range = try rangeFromC(value);
    try viewport(snapshot, row, null);
    try coordinates(snapshot);
    const shape = selection.rowShape(snapshot, row) orelse return error.InvalidPoint;
    const span = range.textSpan(view.begin(snapshot), row, shape) orelse return;
    out.first = span.start_column;
    out.last = span.end_column;
    out.found = 1;
}

/// Copies complete row-shape facts, leaving a short output entirely untouched.
pub fn copyRowShapes(snapshot: *const view.Snapshot, output: []c.hvt_row_shape, required: *usize) Error!void {
    required.* = view.rows(snapshot).len;
    if (output.len < required.*) return error.BufferTooSmall;
    for (output[0..required.*], 0..) |*destination, row| {
        const shape = selection.rowShape(snapshot, @intCast(row)) orelse return error.InvalidPoint;
        destination.* = .{ .content_end_exclusive = shape.content_end_exclusive, .wrapped = @intFromBool(shape.wrapped), ._reserved = 0 };
    }
}

fn hyperlink(snapshot: *const view.Snapshot, row: u16, column: u16) Error![]const u8 {
    try viewport(snapshot, row, column);
    const rows = view.rows(snapshot);
    const cells = view.cells(snapshot);
    const target = cells[@as(usize, rows[row].cell_offset) + column];
    if (target.x > column or target.y > row) return error.InvalidPoint;
    const lead_row = rows[row - target.y];
    const lead_column = column - target.x;
    if (lead_column >= lead_row.cell_count) return error.InvalidPoint;
    const lead = cells[@as(usize, lead_row.cell_offset) + lead_column];
    if (lead.link_id == 0) return "";
    for (view.hyperlinks(snapshot)) |link| {
        if (link.link_id == lead.link_id) return view.uris(snapshot)[link.uri_offset..][0..link.uri_len];
    }
    return error.InvalidRichSnapshot;
}

/// Copies a lead-cell URI; size query and shortage never write partial bytes.
pub fn copyHyperlink(snapshot: *const view.Snapshot, row: u16, column: u16, output: []u8, required: *usize) Error!void {
    required.* = 0;
    if (output.len > c.HSC_MAX_SELECTION_BYTES) return error.RequestTooLarge;
    const bytes = try hyperlink(snapshot, row, column);
    required.* = bytes.len;
    if (output.len < bytes.len) return error.BufferTooSmall;
    @memcpy(output[0..bytes.len], bytes);
}

/// Copies exact change-presence facts from an independent immutable snapshot.
pub fn changes(snapshot: *const view.Snapshot) c.hsc_changes {
    var result = std.mem.zeroes(c.hsc_changes);
    if (view.changedRows(snapshot)) |rows| {
        result.flags |= c.HSC_CHANGED_ROWS_PRESENT;
        result.row_count = @intCast(rows.len);
    }
    if (view.changedRowsBaseRevision(snapshot)) |revision| {
        result.flags |= c.HSC_CHANGE_BASE_PRESENT;
        result.base_revision = revision;
    }
    if (view.rowShift(snapshot)) |shift| {
        result.flags |= c.HSC_ROW_SHIFT_PRESENT;
        result.row_shift = shift;
    }
    return result;
}

/// Copies a known mask as native 0/1 bytes; absence has required extent zero.
pub fn copyChangedRows(snapshot: *const view.Snapshot, output: []u8, required: *usize) Error!void {
    required.* = 0;
    const rows = view.changedRows(snapshot) orelse return;
    required.* = rows.len;
    if (output.len < rows.len) return error.BufferTooSmall;
    for (output[0..rows.len], rows) |*destination, changed| destination.* = @intFromBool(changed);
}

fn testSnapshot(allocator: std.mem.Allocator, base: u32, alternate: bool, mask: bool, orphan: bool) !*view.Snapshot {
    var cells: [2][8]terminal.rich.Cell = undefined;
    for (&cells) |*row| for (row) |*cell| {
        cell.* = std.mem.zeroes(terminal.rich.Cell);
        cell.width = 1;
        cell.height = 1;
        cell.subscale_n = 1;
        cell.subscale_d = 1;
    };
    cells[0][0].scalars = &.{'A'};
    cells[0][1].scalars = &.{ 'e', 0x301 };
    cells[0][2].scalars = &.{0x754c};
    cells[0][2].width = 2;
    cells[0][2].link_id = 7;
    cells[0][3].width = 2;
    cells[0][3].x = 1;
    cells[0][4].scalars = &.{'x'};
    cells[0][4].style_bits = terminal.protocol.text_v1.style.invisible;
    cells[0][5].scalars = &.{' '};
    cells[0][6].scalars = &.{'b'};
    cells[1][0].scalars = &.{'f'};
    cells[1][1].scalars = &.{'o'};
    cells[1][2].scalars = &.{'o'};
    if (orphan) {
        cells[0][2].height = 2;
        cells[0][2].y = 1;
        cells[0][2].scalars = &.{};
        cells[0][3].height = 2;
        cells[0][3].y = 1;
    }
    var rows = [_]terminal.rich.Row{
        .{ .wrapped = true, .line_geometry = 0, .cells = &cells[0] },
        .{ .wrapped = false, .line_geometry = 0, .cells = &cells[1] },
    };
    var source = std.mem.zeroes(terminal.rich.View);
    source.begin.revision = 31;
    source.begin.terminal.revision = 17;
    source.begin.terminal.rows = 2;
    source.begin.terminal.columns = 8;
    source.begin.terminal.history_row_base = base;
    source.begin.terminal.history_count = if (alternate or base > 1000) 0 else 4;
    source.begin.terminal.history_offset = if (alternate or base > 1000) 0 else 2;
    source.begin.terminal.alternate_screen = alternate;
    source.rows = &rows;
    var uri = "https://example.invalid/query".*;
    const links = [_]terminal.rich.Hyperlink{.{ .link_id = 7, .uri_bytes = &uri }};
    source.hyperlinks = &links;
    source.properties = .{ .title = "fixture" };
    const changed = [_]bool{ true, false };
    if (mask) {
        source.changed_rows = &changed;
        source.changed_rows_base_revision = 30;
        source.row_shift = 1;
    }
    return view.projectView(allocator, &source);
}

test "native viewport searches preserve Unicode, concealment and immutable-domain completeness" {
    const snapshot = try testSnapshot(std.testing.allocator, 100, false, false, false);
    defer view.deinit(snapshot);
    var found: c.hvt_search_match = undefined;
    try searchRow(snapshot, std.testing.allocator, "界", 0, 0, false, &found);
    try std.testing.expect(found.found == 1 and found.row == 102 and found.start_column == 2 and found.end_column == 3);
    try std.testing.expect(found.cut_revision == 17 and found.complete == 1 and found.scanned_snapshots == 1 and found.columns == 8);
    try searchRow(snapshot, std.testing.allocator, "é", 0, 7, true, &found);
    try std.testing.expect(found.found == 1 and found.start_column == 1 and found.end_column == 1);
    try search(snapshot, std.testing.allocator, "x", 0, false, &found);
    try std.testing.expect(found.found == 0 and found.complete == 1);
    try search(snapshot, std.testing.allocator, "bfoo", 0, false, &found);
    try std.testing.expect(found.found == 0); // No cross-row substring, including a soft wrap.
    try search(snapshot, std.testing.allocator, "foo", 1, true, &found);
    try std.testing.expect(found.found == 1 and found.row == 103);
    var query: [4097]u8 = @splat('a');
    try search(snapshot, std.testing.allocator, query[0..4096], 0, false, &found);
    try std.testing.expectError(error.RequestTooLarge, search(snapshot, std.testing.allocator, &query, 0, false, &found));
    try std.testing.expectError(error.InvalidArgument, search(snapshot, std.testing.allocator, "", 0, false, &found));
    try std.testing.expectError(error.InvalidArgument, search(snapshot, std.testing.allocator, &.{0xff}, 0, false, &found));
    try std.testing.expectError(error.InvalidArgument, searchRow(snapshot, std.testing.allocator, "A", 2, 0, false, &found));
    try std.testing.expectError(error.InvalidArgument, searchRow(snapshot, std.testing.allocator, "A", 0, 8, false, &found));
    try std.testing.expect(found.found == 0 and found.cut_revision == 0);
    const overflow = try testSnapshot(std.testing.allocator, std.math.maxInt(i32), false, false, false);
    defer view.deinit(overflow);
    try std.testing.expectError(error.CoordinatesTooLarge, search(overflow, std.testing.allocator, "A", 0, false, &found));
}

test "native selection records validate context, eviction and text-shaped span" {
    const snapshot = try testSnapshot(std.testing.allocator, 100, false, false, false);
    defer view.deinit(snapshot);
    var range: c.hvt_selection_range = undefined;
    try expandSelection(snapshot, c.HVT_SELECTION_WORD, 0, 3, &range);
    try std.testing.expect(range.found == 1 and range.start_row == 102 and range.end_row == 102 and range.start_column == 0 and range.end_column == 3);
    try std.testing.expectEqual(@as(u32, c.HSC_SELECTION_VALID), try selectionValidity(snapshot, &range));
    var span: c.hsc_selection_span = undefined;
    try selectionSpan(snapshot, &range, 0, &span);
    try std.testing.expect(span.found == 1 and span.first == 0 and span.last == 3 and std.mem.allEqual(u8, &span.reserved, 0));
    try selectionSpan(snapshot, &range, 1, &span);
    try std.testing.expect(span.found == 0);
    var changed = range;
    changed.columns = 9;
    try std.testing.expectEqual(@as(u32, c.HSC_SELECTION_CONTEXT_CHANGED), try selectionValidity(snapshot, &changed));
    changed = range;
    changed.alternate_screen = 1;
    try std.testing.expectEqual(@as(u32, c.HSC_SELECTION_CONTEXT_CHANGED), try selectionValidity(snapshot, &changed));
    changed = range;
    changed.start_row = 99;
    try std.testing.expectEqual(@as(u32, c.HSC_SELECTION_EVICTED), try selectionValidity(snapshot, &changed));
    for (0..7) |which| {
        changed = range;
        switch (which) {
            0 => changed.found = 0,
            1 => changed.start_row = -1,
            2 => changed.end_row = -1,
            3 => changed.start_column = changed.columns,
            4 => changed.columns = 0,
            5 => changed.alternate_screen = 2,
            6 => changed._reserved[1] = 1,
            else => return error.InvalidTestCase,
        }
        try std.testing.expectError(error.InvalidArgument, selectionValidity(snapshot, &changed));
    }
    try expandSelection(snapshot, c.HVT_SELECTION_WORD, 0, 4, &range);
    try std.testing.expect(range.found == 0);
    try expandSelection(snapshot, c.HVT_SELECTION_VISUAL_ROW, 1, 0, &range);
    try std.testing.expect(range.found == 1 and range.start_column == 0 and range.end_column == 2);
    const alternate = try testSnapshot(std.testing.allocator, 0, true, false, false);
    defer view.deinit(alternate);
    try expandSelection(alternate, c.HVT_SELECTION_WORD, 0, 0, &range);
    try std.testing.expect(range.alternate_screen == 1 and range.start_row == 0);
}

test "native copies preserve shortages, exact extent and lead URI" {
    const snapshot = try testSnapshot(std.testing.allocator, 100, false, true, false);
    defer view.deinit(snapshot);
    var rows: [3]c.hvt_row_shape = @splat(.{ .content_end_exclusive = 77, .wrapped = 78, ._reserved = 79 });
    var count: usize = 99;
    try std.testing.expectError(error.BufferTooSmall, copyRowShapes(snapshot, rows[0..1], &count));
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(u16, 77), rows[0].content_end_exclusive);
    try copyRowShapes(snapshot, &rows, &count);
    try std.testing.expectEqual(@as(u16, 7), rows[0].content_end_exclusive);
    try std.testing.expectEqual(@as(u16, 3), rows[1].content_end_exclusive);
    try std.testing.expectEqual(@as(u16, 77), rows[2].content_end_exclusive);
    var bytes: [128]u8 = @splat(0xa5);
    try std.testing.expectError(error.BufferTooSmall, copyHyperlink(snapshot, 0, 3, bytes[0..1], &count));
    const uri = "https://example.invalid/query";
    try std.testing.expect(count == uri.len and std.mem.allEqual(u8, &bytes, 0xa5));
    try copyHyperlink(snapshot, 0, 3, &bytes, &count);
    try std.testing.expectEqualStrings(uri, bytes[0..count]);
    try std.testing.expect(bytes[count] == 0xa5);
    try copyHyperlink(snapshot, 0, 0, &bytes, &count);
    try std.testing.expect(count == 0);
    var mask: [3]u8 = @splat(77);
    try std.testing.expectError(error.BufferTooSmall, copyChangedRows(snapshot, mask[0..1], &count));
    try std.testing.expect(count == 2 and mask[0] == 77);
    try copyChangedRows(snapshot, &mask, &count);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 77 }, &mask);
    const info = changes(snapshot);
    try std.testing.expectEqual(@as(u8, 7), info.flags);
    try std.testing.expectEqual(@as(u32, 2), info.row_count);
    try std.testing.expectEqual(@as(u64, 30), info.base_revision);
    try std.testing.expectEqual(@as(u16, 1), info.row_shift);
    try std.testing.expectEqual(@as(u8, 0), info.reserved);
    const ordinary = try testSnapshot(std.testing.allocator, 100, false, false, false);
    defer view.deinit(ordinary);
    try std.testing.expect(changes(ordinary).flags == 0);
    try copyChangedRows(ordinary, &mask, &count);
    try std.testing.expect(count == 0 and mask[2] == 77);
    const orphan = try testSnapshot(std.testing.allocator, 100, false, false, true);
    defer view.deinit(orphan);
    try std.testing.expectError(error.InvalidPoint, copyHyperlink(orphan, 0, 3, &bytes, &count));
}

fn searchAllocationProof(allocator: std.mem.Allocator, snapshot: *const view.Snapshot) !void {
    var out: c.hvt_search_match = undefined;
    try search(snapshot, allocator, "foo", 0, false, &out);
    try std.testing.expect(out.found == 1);
}
test "native search unwinds every scratch allocation prefix" {
    const snapshot = try testSnapshot(std.testing.allocator, 100, false, false, false);
    defer view.deinit(snapshot);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, searchAllocationProof, .{snapshot});
}

const test_owner = @import("terminal_owner");
const protocol = terminal.protocol;
const SocketFixture = struct {
    connection: *terminal.Connection,
    peer: std.posix.fd_t,

    fn init(allocator: std.mem.Allocator, ready: client.protocol.AttachReady) !SocketFixture {
        var pair: [2]std.posix.fd_t = undefined;
        if (std.posix.errno(std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair)) != .SUCCESS)
            return error.TestSocketFailed;
        errdefer closeFd(pair[0]);
        errdefer closeFd(pair[1]);
        return .{ .connection = try test_owner.create(allocator, .{ .fd = pair[0] }, ready), .peer = pair[1] };
    }
    fn deinit(self: *SocketFixture) void {
        self.connection.deinit();
        closeFd(self.peer);
    }
    fn send(self: *SocketFixture, kind: protocol.Kind, payload: []const u8) !void {
        var header: [protocol.header_bytes]u8 = undefined;
        try protocol.encodeHeader(&header, .{ .kind = kind, .payload_len = @intCast(payload.len) });
        try writeAll(self.peer, &header);
        try writeAll(self.peer, payload);
    }
    fn consumeRequest(self: *SocketFixture) !void {
        var header: [protocol.header_bytes]u8 = undefined;
        try readAll(self.peer, &header);
        const decoded = try protocol.decodeHeader(&header);
        try std.testing.expect(decoded.kind == .observe_delta and decoded.payload_len == protocol.payload_bytes.observe);
        var payload: [protocol.payload_bytes.observe]u8 = undefined;
        try readAll(self.peer, &payload);
    }
    fn expectNoRequest(self: *SocketFixture) !void {
        var byte: [1]u8 = undefined;
        const result = std.posix.system.recvfrom(self.peer, &byte, 1, std.posix.MSG.DONTWAIT, null, null);
        try std.testing.expect(std.posix.errno(result) == .AGAIN);
    }
    fn snapshot(self: *SocketFixture, revision: u64, kind: protocol.Kind, body: []const u8) !void {
        var begin = std.mem.zeroes(protocol.SnapshotBegin);
        begin.revision = revision;
        begin.terminal.revision = 7; // Delivery revision deliberately differs.
        begin.terminal.rows = 2;
        begin.terminal.columns = 1;
        var encoded_begin: [protocol.payload_bytes.snapshot_begin]u8 = undefined;
        protocol.encodeSnapshotBegin(&encoded_begin, begin);
        try self.send(.snapshot_begin, &encoded_begin);
        try self.send(kind, body);
        var graphics: [protocol.graphics_v2.manifest_header_bytes]u8 = undefined;
        protocol.encodeSnapshotGraphicsHeader(&graphics, .{
            .generation = 0,
            .content_generation = 0,
            .cell_pixel_width = 10,
            .cell_pixel_height = 20,
            .image_count = 0,
            .placement_count = 0,
        });
        try self.send(.snapshot_graphics, &graphics);
        var props: [protocol.properties.header_bytes]u8 = undefined;
        const size = try protocol.properties.encode(&props, .{});
        try self.send(.snapshot_properties, props[0..size]);
        var end: [protocol.payload_bytes.snapshot_end]u8 = undefined;
        protocol.encodeSnapshotEnd(&end, .{ .revision = revision });
        try self.send(.snapshot_end, &end);
    }
};
fn testReady() client.protocol.AttachReady {
    return .{ .server_id = 1, .session_id = 2, .instance_id = 3, .tree_revision = 4, .client_id = 5 };
}
fn closeFd(fd: std.posix.fd_t) void {
    const result = std.posix.system.close(fd);
    std.debug.assert(std.posix.errno(result) == .SUCCESS or std.posix.errno(result) == .INTR);
}
fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var at: usize = 0;
    while (at < bytes.len) {
        const result = std.posix.system.write(fd, bytes[at..].ptr, bytes.len - at);
        switch (std.posix.errno(result)) {
            .SUCCESS => {
                const size = std.math.cast(usize, result) orelse return error.TestWriteFailed;
                if (size == 0 or size > bytes.len - at) return error.TestWriteFailed;
                at += size;
            },
            .INTR => continue,
            else => return error.TestWriteFailed,
        }
    }
}
fn readAll(fd: std.posix.fd_t, bytes: []u8) !void {
    var at: usize = 0;
    while (at < bytes.len) {
        const result = std.posix.system.read(fd, bytes[at..].ptr, bytes.len - at);
        switch (std.posix.errno(result)) {
            .SUCCESS => {
                const size = std.math.cast(usize, result) orelse return error.TestReadFailed;
                if (size == 0 or size > bytes.len - at) return error.TestReadFailed;
                at += size;
            },
            .INTR => continue,
            else => return error.TestReadFailed,
        }
    }
}
fn testRange() c.hvt_selection_range {
    return .{ .start_row = 0, .end_row = 0, .start_column = 0, .end_column = 0, .columns = 1, .found = 1, .alternate_screen = 0, ._reserved = @splat(0) };
}

test "extraction validates before I/O and complete rejection permits reuse" {
    if (comptime @import("builtin").os.tag != .linux) return;
    var fixture = try SocketFixture.init(std.testing.allocator, testReady());
    defer fixture.deinit();
    var range = testRange();
    range.start_row = -1;
    try std.testing.expectError(error.InvalidArgument, extract(std.testing.allocator, fixture.connection, &range));
    try fixture.expectNoRequest();
    var result: [protocol.payload_bytes.result]u8 = undefined;
    protocol.encodeResult(&result, .{ .request_kind = .text_extract, .code = .rejected });
    try fixture.send(.result, &result);
    range = testRange();
    try std.testing.expectError(error.SelectionRejected, extract(std.testing.allocator, fixture.connection, &range));
    try fixture.send(.text_extract_data, "owned");
    const text = try extract(std.testing.allocator, fixture.connection, &range);
    defer releaseText(text);
    try std.testing.expectEqualStrings("owned", textBytes(text));
    try fixture.send(.text_extract_data, "");
    const empty = try extract(std.testing.allocator, fixture.connection, &range);
    defer releaseText(empty);
    try std.testing.expect(textBytes(empty).len == 0);
}

test "semantically malformed extraction frames retire instead of preserving ordered I/O" {
    if (comptime @import("builtin").os.tag != .linux) return;
    const range = testRange();
    for (0..5) |which| {
        var fixture = try SocketFixture.init(std.testing.allocator, testReady());
        defer fixture.deinit();
        var result: [protocol.payload_bytes.result]u8 = undefined;
        switch (which) {
            0 => try fixture.send(.text_extract_data, &.{0xff}),
            1 => {
                protocol.encodeResult(&result, .{ .request_kind = .text_extract, .code = .ok });
                try fixture.send(.result, &result);
            },
            2 => {
                protocol.encodeResult(&result, .{ .request_kind = .resize, .code = .rejected });
                try fixture.send(.result, &result);
            },
            3 => try fixture.send(.result, &.{0}),
            4 => try fixture.send(.image_end, &.{}),
            else => return error.InvalidTestCase,
        }
        const expected: Error = switch (which) {
            0 => error.InvalidUtf8,
            3 => error.InvalidPayload,
            else => error.UnexpectedFrame,
        };
        try std.testing.expectError(expected, extract(std.testing.allocator, fixture.connection, &range));
        try std.testing.expectError(error.ConnectionRetired, fixture.connection.readinessFd());
    }
    var truncated = try SocketFixture.init(std.testing.allocator, testReady());
    defer truncated.deinit();
    var header: [protocol.header_bytes]u8 = undefined;
    try protocol.encodeHeader(&header, .{ .kind = .text_extract_data, .payload_len = 4 });
    try writeAll(truncated.peer, &header);
    try writeAll(truncated.peer, "x");
    try std.testing.expect(std.posix.errno(std.posix.system.shutdown(truncated.peer, std.posix.SHUT.WR)) == .SUCCESS);
    try std.testing.expectError(error.ConnectionClosed, extract(std.testing.allocator, truncated.connection, &range));
    try std.testing.expectError(error.ConnectionRetired, truncated.connection.readinessFd());
}

test "extraction distinguishes wrapper, receive and completed-copy allocation failure" {
    if (comptime @import("builtin").os.tag != .linux) return;
    const range = testRange();
    var fixture = try SocketFixture.init(std.testing.allocator, testReady());
    defer fixture.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, extract(failing.allocator(), fixture.connection, &range));
    try fixture.expectNoRequest();
    try fixture.send(.text_extract_data, "complete");
    failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, extract(failing.allocator(), fixture.connection, &range));
    try std.testing.expect((try fixture.connection.readinessFd()) >= 0);
    try fixture.send(.text_extract_data, "retry");
    const text = try extract(std.testing.allocator, fixture.connection, &range);
    defer releaseText(text);
    try std.testing.expectEqualStrings("retry", textBytes(text));

    // State allocation is first; receiving its nonempty body is the next allocation.
    var receive_fail = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var receiving = try SocketFixture.init(receive_fail.allocator(), testReady());
    defer receiving.deinit();
    try receiving.send(.text_extract_data, "body");
    try std.testing.expectError(error.OutOfMemory, extract(std.testing.allocator, receiving.connection, &range));
    try std.testing.expectError(error.ConnectionRetired, receiving.connection.readinessFd());
}
fn extractionAllocationProof(allocator: std.mem.Allocator) !void {
    var fixture = try SocketFixture.init(allocator, testReady());
    defer fixture.deinit();
    try fixture.send(.text_extract_data, "prefix");
    const range = testRange();
    const text = try extract(allocator, fixture.connection, &range);
    defer releaseText(text);
    try std.testing.expectEqualStrings("prefix", textBytes(text));
}
test "text result and receive allocation prefixes release every partial owner" {
    if (comptime @import("builtin").os.tag != .linux) return;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, extractionAllocationProof, .{});
}

const presentation_record = protocol.text_v1.record_header_bytes + protocol.text_v1.presentation_bytes;
const row_payload = protocol.text_v1.row_header_bytes + protocol.text_v1.cell_header_bytes + @sizeOf(u32);
const row_record = protocol.text_v1.record_header_bytes + row_payload;
fn rawBody(first: u32, second: u32) ![presentation_record + 2 * row_record]u8 {
    var body: [presentation_record + 2 * row_record]u8 = @splat(0);
    protocol.encodeTextRecordHeader(body[0..protocol.text_v1.record_header_bytes], .{ .kind = .presentation, .payload_len = protocol.text_v1.presentation_bytes });
    var at: usize = presentation_record;
    for ([_]u32{ first, second }) |scalar| {
        protocol.encodeTextRecordHeader(body[at..][0..protocol.text_v1.record_header_bytes], .{ .kind = .row, .payload_len = row_payload });
        at += protocol.text_v1.record_header_bytes;
        const row = body[at..][0..row_payload];
        std.mem.writeInt(u16, row[2..4], 1, .big);
        const cell = row[protocol.text_v1.row_header_bytes..][0..protocol.text_v1.cell_header_bytes];
        cell[0] = 1;
        cell[1] = 1;
        cell[2] = 1;
        var color: [protocol.text_v1.color_bytes]u8 = undefined;
        try protocol.encodeTextColor(&color, .{ .kind = .default, .value = 0 });
        @memcpy(cell[16..21], &color);
        @memcpy(cell[21..26], &color);
        @memcpy(cell[26..31], &color);
        std.mem.writeInt(u32, row[row_payload - 4 ..][0..4], scalar, .big);
        at += row_payload;
    }
    return body;
}
fn deltaBody(first: u32) ![presentation_record + protocol.text_v1.record_header_bytes + protocol.text_delta_v2.row_shift_bytes + row_record + protocol.text_v1.record_header_bytes]u8 {
    const full = try rawBody(first, 'Z');
    var body: [presentation_record + protocol.text_v1.record_header_bytes + protocol.text_delta_v2.row_shift_bytes + row_record + protocol.text_v1.record_header_bytes]u8 = undefined;
    @memcpy(body[0..presentation_record], full[0..presentation_record]);
    var at: usize = presentation_record;
    protocol.encodeTextRecordHeader(body[at..][0..protocol.text_v1.record_header_bytes], .{ .kind = .row_shift, .payload_len = protocol.text_delta_v2.row_shift_bytes });
    at += protocol.text_v1.record_header_bytes;
    protocol.encodeTextRowShift(body[at..][0..protocol.text_delta_v2.row_shift_bytes], 0);
    at += protocol.text_delta_v2.row_shift_bytes;
    @memcpy(body[at..][0..row_record], full[presentation_record..][0..row_record]);
    at += row_record;
    protocol.encodeTextRecordHeader(body[at..][0..protocol.text_v1.record_header_bytes], .{ .kind = .row, .payload_len = 0 });
    return body;
}

test "bound cached observations admit delivery revision and publish independent masks" {
    if (comptime @import("builtin").os.tag != .linux) return;
    var fixture = try SocketFixture.init(std.testing.allocator, testReady());
    defer fixture.deinit();
    const cache = try createCache(std.testing.allocator, fixture.connection);
    defer releaseCache(cache);
    const full = try rawBody('A', 'Z');
    try fixture.snapshot(100, .snapshot_raw_data, &full);
    const first = try observeCached(cache, fixture.connection, std.testing.allocator, 0, 0);
    defer view.deinit(first);
    try std.testing.expect(changes(first).base_revision == 0 and changes(first).flags == c.HSC_CHANGED_ROWS_PRESENT);
    const delta = try deltaBody('B');
    try fixture.snapshot(101, .snapshot_delta_data, &delta);
    const second = try observeCached(cache, fixture.connection, std.testing.allocator, 100, 0);
    defer view.deinit(second);
    try std.testing.expect(changes(second).base_revision == 100 and changes(second).row_count == 2);
    try std.testing.expectEqual(@as(u8, c.HSC_CHANGED_ROWS_PRESENT | c.HSC_CHANGE_BASE_PRESENT), changes(second).flags);
    var mask: [2]u8 = undefined;
    var required: usize = 0;
    try copyChangedRows(second, &mask, &required);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0 }, &mask);
    try std.testing.expectEqual(@as(u32, 'A'), view.scalars(first)[0]);
    try std.testing.expectEqual(@as(u32, 'B'), view.scalars(second)[0]);
    try fixture.consumeRequest();
    try fixture.consumeRequest();
    try std.testing.expectError(error.InvalidArgument, observeCached(cache, fixture.connection, std.testing.allocator, 7, 0));
    try std.testing.expectError(error.InvalidArgument, observeCached(cache, fixture.connection, std.testing.allocator, 101, 1));
    try std.testing.expect(cacheImpl(cache).raw.baseline.?.revision == 101);
    try fixture.expectNoRequest();
    try fixture.snapshot(102, .snapshot_delta_data, &delta);
    const unchanged = try observeCached(cache, fixture.connection, std.testing.allocator, 101, 0);
    defer view.deinit(unchanged);
    try copyChangedRows(unchanged, &mask, &required);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, &mask);
}

fn rotationBody() ![presentation_record + protocol.text_v1.record_header_bytes + protocol.text_delta_v2.row_shift_bytes + protocol.text_v1.record_header_bytes + row_record]u8 {
    const full = try rawBody('Z', 'C');
    var body: [presentation_record + protocol.text_v1.record_header_bytes + protocol.text_delta_v2.row_shift_bytes + protocol.text_v1.record_header_bytes + row_record]u8 = undefined;
    @memcpy(body[0..presentation_record], full[0..presentation_record]);
    var at: usize = presentation_record;
    protocol.encodeTextRecordHeader(body[at..][0..protocol.text_v1.record_header_bytes], .{ .kind = .row_shift, .payload_len = protocol.text_delta_v2.row_shift_bytes });
    at += protocol.text_v1.record_header_bytes;
    protocol.encodeTextRowShift(body[at..][0..protocol.text_delta_v2.row_shift_bytes], 1);
    at += protocol.text_delta_v2.row_shift_bytes;
    protocol.encodeTextRecordHeader(body[at..][0..protocol.text_v1.record_header_bytes], .{ .kind = .row, .payload_len = 0 });
    at += protocol.text_v1.record_header_bytes;
    @memcpy(body[at..][0..row_record], full[presentation_record + row_record ..][0..row_record]);
    return body;
}
test "cached row rotation preserves independent predecessor mask and values" {
    if (comptime @import("builtin").os.tag != .linux) return;
    var fixture = try SocketFixture.init(std.testing.allocator, testReady());
    defer fixture.deinit();
    const cache = try createCache(std.testing.allocator, fixture.connection);
    var cache_held = true;
    defer if (cache_held) releaseCache(cache);
    const body = try rawBody('A', 'Z');
    try fixture.snapshot(100, .snapshot_raw_data, &body);
    const old = try observeCached(cache, fixture.connection, std.testing.allocator, 0, 0);
    defer view.deinit(old);
    const rotation = try rotationBody();
    try fixture.snapshot(101, .snapshot_delta_data, &rotation);
    const next = try observeCached(cache, fixture.connection, std.testing.allocator, 100, 0);
    defer view.deinit(next);
    releaseCache(cache);
    cache_held = false;
    const info = changes(next);
    try std.testing.expect(info.flags == 7 and info.row_shift == 1 and info.base_revision == 100);
    try std.testing.expectEqualSlices(u32, &.{ 'Z', 'C' }, view.scalars(next));
    try std.testing.expectEqualSlices(u32, &.{ 'A', 'Z' }, view.scalars(old));
    var mask: [2]u8 = undefined;
    var required: usize = 0;
    try copyChangedRows(next, &mask, &required);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1 }, &mask);
}

test "complete ready record binding rejects every different occurrence before I/O" {
    if (comptime @import("builtin").os.tag != .linux) return;
    var original = try SocketFixture.init(std.testing.allocator, testReady());
    defer original.deinit();
    const cache = try createCache(std.testing.allocator, original.connection);
    defer releaseCache(cache);
    inline for (.{ "server_id", "session_id", "instance_id", "tree_revision", "client_id" }) |field| {
        var ready = testReady();
        @field(ready, field) += 1;
        var other = try SocketFixture.init(std.testing.allocator, ready);
        defer other.deinit();
        try std.testing.expectError(error.InvalidArgument, observeCached(cache, other.connection, std.testing.allocator, 0, 0));
        try other.expectNoRequest();
        try std.testing.expect((try other.connection.readinessFd()) >= 0);
    }
    try std.testing.expectError(error.InvalidArgument, observeCached(cache, original.connection, std.testing.allocator, 1, 0));
    try original.expectNoRequest();
}
fn cachedAllocationProof(allocator: std.mem.Allocator) !void {
    var fixture = try SocketFixture.init(std.testing.allocator, testReady());
    defer fixture.deinit();
    const cache = try createCache(allocator, fixture.connection);
    defer releaseCache(cache);
    const body = try rawBody('A', 'Z');
    try fixture.snapshot(100, .snapshot_raw_data, &body);
    const snapshot = try observeCached(cache, fixture.connection, allocator, 0, 0);
    defer view.deinit(snapshot);
    try std.testing.expectEqual(@as(u32, 'A'), view.scalars(snapshot)[0]);
}
test "cached receive and independent projection unwind every cache allocation prefix" {
    if (comptime @import("builtin").os.tag != .linux) return;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, cachedAllocationProof, .{});
}

test "post-complete projection OOM resets cache, preserves stream and requires zero retry" {
    if (comptime @import("builtin").os.tag != .linux) return;
    var fixture = try SocketFixture.init(std.testing.allocator, testReady());
    defer fixture.deinit();
    const cache = try createCache(std.testing.allocator, fixture.connection);
    defer releaseCache(cache);
    const body = try rawBody('A', 'Z');
    try fixture.snapshot(100, .snapshot_raw_data, &body);
    const first = try observeCached(cache, fixture.connection, std.testing.allocator, 0, 0);
    defer view.deinit(first);
    try fixture.consumeRequest();
    try fixture.snapshot(101, .snapshot_raw_data, &body);
    // Snapshot and mutable cache are distinct owners. Fail only the independent
    // projection allocator after the real receiver has accepted its response.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, observeCached(cache, fixture.connection, failing.allocator(), 100, 0));
    try fixture.consumeRequest();
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(cacheImpl(cache).raw.baseline == null and cacheImpl(cache).raw.pending_delta == null);
    try std.testing.expect((try fixture.connection.readinessFd()) >= 0);
    try std.testing.expectEqual(@as(u32, 'A'), view.scalars(first)[0]);
    try std.testing.expectError(error.InvalidArgument, observeCached(cache, fixture.connection, std.testing.allocator, 101, 0));
    try fixture.expectNoRequest();
    try fixture.snapshot(102, .snapshot_raw_data, &body);
    const recovered = try observeCached(cache, fixture.connection, std.testing.allocator, 0, 0);
    defer view.deinit(recovered);
    try std.testing.expect(changes(recovered).base_revision == 0);
}

test "malformed cached response invalidates baseline and retires stream" {
    if (comptime @import("builtin").os.tag != .linux) return;
    var fixture = try SocketFixture.init(std.testing.allocator, testReady());
    defer fixture.deinit();
    const cache = try createCache(std.testing.allocator, fixture.connection);
    defer releaseCache(cache);
    try fixture.send(.snapshot_end, &.{});
    try std.testing.expectError(error.UnexpectedFrame, observeCached(cache, fixture.connection, std.testing.allocator, 0, 0));
    try std.testing.expect(cacheImpl(cache).raw.baseline == null);
    try std.testing.expectError(error.ConnectionRetired, fixture.connection.readinessFd());
}

test "native scrolled viewport retains representable coordinates below an unprojected tail" {
    var cell = std.mem.zeroes(terminal.rich.Cell);
    cell.width = 1;
    cell.height = 1;
    cell.subscale_n = 1;
    cell.subscale_d = 1;
    cell.scalars = &.{'a'};
    var cells = [2][1]terminal.rich.Cell{ .{cell}, .{cell} };
    var rows = [_]terminal.rich.Row{
        .{ .wrapped = false, .line_geometry = 0, .cells = &cells[0] },
        .{ .wrapped = false, .line_geometry = 0, .cells = &cells[1] },
    };
    var source = std.mem.zeroes(terminal.rich.View);
    source.begin.revision = 31;
    source.begin.terminal.revision = 17;
    source.begin.terminal.columns = 1;
    source.begin.terminal.history_row_base = std.math.maxInt(i32) - 1;
    source.begin.terminal.history_count = 2;
    source.begin.terminal.history_offset = 2;
    source.hyperlinks = &.{};
    for ([_]u16{ 1, 2 }) |row_count| {
        source.begin.terminal.rows = row_count;
        source.rows = rows[0..row_count];
        const snapshot = try view.projectView(std.testing.allocator, &source);
        defer view.deinit(snapshot);
        const last = row_count - 1;
        const stable_last = @as(i32, std.math.maxInt(i32) - 1) + last;
        var match: c.hvt_search_match = undefined;
        try searchRow(snapshot, std.testing.allocator, "a", last, 0, false, &match);
        try std.testing.expect(match.found == 1 and match.row == stable_last);
        try search(snapshot, std.testing.allocator, "a", last, true, &match);
        try std.testing.expect(match.found == 1 and match.row == stable_last);
        var range: c.hvt_selection_range = undefined;
        try expandSelection(snapshot, c.HVT_SELECTION_WORD, last, 0, &range);
        try std.testing.expect(range.found == 1 and range.start_row == stable_last and range.end_row == stable_last);
        try std.testing.expectEqual(@as(u32, c.HSC_SELECTION_VALID), try selectionValidity(snapshot, &range));
        var span: c.hsc_selection_span = undefined;
        try selectionSpan(snapshot, &range, last, &span);
        try std.testing.expect(span.found == 1 and span.first == 0 and span.last == 0);
    }
    // Moving the projected window one row newer puts its actual last row above i32.
    source.begin.terminal.rows = 2;
    source.rows = &rows;
    source.begin.terminal.history_offset = 1;
    const overflow = try view.projectView(std.testing.allocator, &source);
    defer view.deinit(overflow);
    var match: c.hvt_search_match = undefined;
    try std.testing.expectError(error.CoordinatesTooLarge, searchRow(overflow, std.testing.allocator, "a", 1, 0, false, &match));
    try std.testing.expect(match.found == 0 and match.cut_revision == 0);
    try std.testing.expectError(error.CoordinatesTooLarge, search(overflow, std.testing.allocator, "a", 0, false, &match));
    var range = std.mem.zeroes(c.hvt_selection_range);
    try std.testing.expectError(error.CoordinatesTooLarge, expandSelection(overflow, c.HVT_SELECTION_WORD, 1, 0, &range));
    try std.testing.expect(range.found == 0);
    range = .{
        .start_row = std.math.maxInt(i32) - 1,
        .end_row = std.math.maxInt(i32) - 1,
        .start_column = 0,
        .end_column = 0,
        .columns = 1,
        .found = 1,
        .alternate_screen = 0,
        ._reserved = @splat(0),
    };
    try std.testing.expectError(error.CoordinatesTooLarge, selectionValidity(overflow, &range));
    var span: c.hsc_selection_span = undefined;
    try std.testing.expectError(error.CoordinatesTooLarge, selectionSpan(overflow, &range, 0, &span));
    try std.testing.expect(span.found == 0);
}
