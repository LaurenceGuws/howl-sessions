//! Client-local exact search over one immutable projected terminal snapshot.
//!
//! Search is presentation/navigation policy. Instance remains canonical and this
//! helper never mutates terminal state. Matches are returned as stable canonical
//! selection points so callers can navigate or extract text without retaining a
//! second terminal model.

const std = @import("std");
const protocol = @import("server_protocol").terminal;
const rich = @import("rich.zig");
const view = @import("view.zig");
const selection = @import("selection.zig");

/// Reports invalid search input or selection/projection failures.
pub const Error = selection.Error || error{
    InvalidQuery,
    RowTooLarge,
};

/// One exact viewport-local match and its canonical selection range.
pub const Match = struct {
    range: selection.Range,
    viewport_row: u16,
    start_column: u16,
    end_column: u16,
};

/// Finds one exact UTF-8 substring in a projected row.
///
/// This primitive deliberately does not cross projected-row boundaries. A
/// higher-level retained-history search may page snapshots and decide whether a
/// future logical-line search contract should cross soft wraps.
pub fn row(
    snapshot: *const view.Snapshot,
    allocator: std.mem.Allocator,
    query: []const u8,
    viewport_row: u16,
    reverse: bool,
) Error!?Match {
    const begin = view.begin(snapshot);
    if (viewport_row >= begin.terminal.rows or begin.terminal.columns == 0) return null;
    return rowFrom(
        snapshot,
        allocator,
        query,
        viewport_row,
        if (reverse) begin.terminal.columns - 1 else 0,
        reverse,
    );
}

/// Finds one exact UTF-8 substring in a projected row at/after (forward) or
/// ending at/before (reverse) the supplied canonical column bound.
pub fn rowFrom(
    snapshot: *const view.Snapshot,
    allocator: std.mem.Allocator,
    query: []const u8,
    viewport_row: u16,
    column_bound: u16,
    reverse: bool,
) Error!?Match {
    if (query.len == 0 or !std.unicode.utf8ValidateSlice(query)) return error.InvalidQuery;
    const begin = view.begin(snapshot);
    if (viewport_row >= begin.terminal.rows) return null;

    const rows = view.rows(snapshot);
    const cells = view.cells(snapshot);
    const scalars = view.scalars(snapshot);
    const projected_row = rows[viewport_row];
    const row_cells = cells[projected_row.cell_offset .. projected_row.cell_offset + projected_row.cell_count];
    const last_cell = lastSearchCell(row_cells) orelse return null;
    const maximum_bytes = std.math.mul(
        usize,
        last_cell + 1,
        @as(usize, protocol.text_v1.maximum_cell_scalars) * 4,
    ) catch return error.RowTooLarge;
    const text = try allocator.alloc(u8, maximum_bytes);
    defer allocator.free(text);
    const byte_columns = try allocator.alloc(u16, maximum_bytes);
    defer allocator.free(byte_columns);

    var offset: usize = 0;
    for (row_cells[0 .. last_cell + 1], 0..) |cell, column| {
        if (cell.x != 0 or cell.y != 0) continue;
        if (!textCellVisible(cell) or cell.scalar_count == 0) {
            text[offset] = ' ';
            byte_columns[offset] = @intCast(column);
            offset += 1;
            continue;
        }
        const scalar_begin = cell.scalar_offset;
        const scalar_end = scalar_begin + cell.scalar_count;
        for (scalars[scalar_begin..scalar_end]) |scalar| {
            var encoded: [4]u8 = undefined;
            // zig-audit: acknowledge catch_unreachable
            // reason: Rich-view scalar validation guarantees every retained value is a valid Unicode scalar before search projection.
            const encoded_len = std.unicode.utf8Encode(@intCast(scalar), &encoded) catch unreachable;
            @memcpy(text[offset .. offset + encoded_len], encoded[0..encoded_len]);
            @memset(byte_columns[offset .. offset + encoded_len], @as(u16, @intCast(column)));
            offset += encoded_len;
        }
    }
    if (query.len > offset) return null;
    const haystack = text[0..offset];
    if (reverse) {
        var search_end = haystack.len;
        while (search_end >= query.len) {
            const found = std.mem.lastIndexOf(u8, haystack[0..search_end], query) orelse return null;
            const start_column = byte_columns[found];
            const end_column = byte_columns[found + query.len - 1];
            if (end_column <= column_bound)
                return try matchAt(snapshot, viewport_row, start_column, end_column);
            if (found == 0) return null;
            search_end = found;
        }
        return null;
    }

    var search_start: usize = 0;
    while (search_start + query.len <= haystack.len) {
        const relative = std.mem.indexOf(u8, haystack[search_start..], query) orelse return null;
        const found = search_start + relative;
        const start_column = byte_columns[found];
        const end_column = byte_columns[found + query.len - 1];
        if (start_column >= column_bound)
            return try matchAt(snapshot, viewport_row, start_column, end_column);
        search_start = found + 1;
    }
    return null;
}

fn matchAt(
    snapshot: *const view.Snapshot,
    viewport_row: u16,
    start_column: u16,
    end_column: u16,
) Error!Match {
    var range = try selection.Range.start(snapshot, viewport_row, start_column);
    try range.extend(snapshot, viewport_row, end_column);
    const visual = selection.visualSpan(snapshot, range, viewport_row) orelse return error.InvalidPoint;
    return .{
        .range = range,
        .viewport_row = viewport_row,
        .start_column = visual.start_column,
        .end_column = visual.end_column,
    };
}

/// Searches projected rows in display order starting at `start_row`.
pub fn first(
    snapshot: *const view.Snapshot,
    allocator: std.mem.Allocator,
    query: []const u8,
    start_row: u16,
    reverse: bool,
) Error!?Match {
    const begin = view.begin(snapshot);
    if (begin.terminal.rows == 0 or start_row >= begin.terminal.rows) return null;
    if (reverse) {
        var row_index: usize = start_row;
        while (true) {
            if (try row(snapshot, allocator, query, @intCast(row_index), true)) |found| return found;
            if (row_index == 0) break;
            row_index -= 1;
        }
        return null;
    }
    var row_index: usize = start_row;
    while (row_index < begin.terminal.rows) : (row_index += 1) {
        if (try row(snapshot, allocator, query, @intCast(row_index), false)) |found| return found;
    }
    return null;
}

fn lastSearchCell(row_cells: []const view.Cell) ?usize {
    var index = row_cells.len;
    while (index > 0) {
        index -= 1;
        const cell = row_cells[index];
        if (cell.x == 0 and cell.y == 0 and textCellVisible(cell) and cell.scalar_count != 0)
            return index;
    }
    return null;
}

fn textCellVisible(cell: view.Cell) bool {
    return !view.cellStyle(cell).invisible;
}

fn testCell(scalars: []const u32, width: u8) rich.Cell {
    return .{
        .scalars = scalars,
        .width = width,
        .height = 1,
        .x = 0,
        .y = 0,
        .subscale_n = 1,
        .subscale_d = 1,
        .vertical_align = 0,
        .horizontal_align = 0,
        .semantic_width = false,
        .font = 0,
        .baseline = 0,
        .underline_style = 0,
        .protection = 0,
        .style_bits = 0,
        .foreground = .{ .kind = .default, .value = 0 },
        .background = .{ .kind = .default, .value = 0 },
        .underline_color = .{ .kind = .default, .value = 0 },
        .link_id = 0,
    };
}

fn testSnapshot(source_rows: []rich.Row, rows_count: u16, columns: u16) rich.Snapshot {
    const palette: [256]rich.Rgba = @splat(.{ .r = 0, .g = 0, .b = 0, .a = 0xff });
    return .{
        .allocator = std.testing.allocator,
        .begin = .{
            .revision = 5,
            .terminal = .{
                .revision = 4,
                .history_offset = 2,
                .history_count = 6,
                .history_row_base = 100,
                .rows = rows_count,
                .columns = columns,
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
        },
        .presentation = .{
            .cursor_age_ns = 0,
            .presence_bits = 0,
            .flags = 0,
            .reverse_screen = false,
            .palette = palette,
            .foreground = .{ .r = 0xee, .g = 0xee, .b = 0xee, .a = 0xff },
            .background = .{ .r = 0, .g = 0, .b = 0, .a = 0xff },
            .cursor = null,
            .cursor_text = null,
            .selection_background = null,
            .selection_foreground = null,
        },
        .rows = source_rows,
        .hyperlinks = &.{},
    };
}

test "search exact row returns stable canonical columns" {
    var row0 = [_]rich.Cell{
        testCell(&.{'a'}, 1), testCell(&.{'l'}, 1), testCell(&.{'p'}, 1),
        testCell(&.{'h'}, 1), testCell(&.{'a'}, 1), testCell(&.{' '}, 1),
        testCell(&.{'b'}, 1), testCell(&.{'e'}, 1), testCell(&.{'t'}, 1),
        testCell(&.{'a'}, 1), testCell(&.{}, 1),    testCell(&.{}, 1),
    };
    var source_rows = [_]rich.Row{.{ .wrapped = false, .line_geometry = 0, .cells = &row0 }};
    var source = testSnapshot(&source_rows, 1, 12);
    const snapshot = try view.project(std.testing.allocator, &source);
    defer view.deinit(snapshot);

    const found = (try row(snapshot, std.testing.allocator, "beta", 0, false)).?;
    try std.testing.expectEqual(@as(u16, 6), found.start_column);
    try std.testing.expectEqual(@as(u16, 9), found.end_column);
    const ordered = found.range.ordered();
    try std.testing.expectEqual(@as(i32, 104), ordered.start.row);
    try std.testing.expectEqual(@as(u16, 6), ordered.start.column);
    try std.testing.expectEqual(@as(u16, 9), ordered.end.column);
}

test "search handles unicode wide cells and concealed text" {
    var row0 = [_]rich.Cell{
        testCell(&.{'A'}, 1), testCell(&.{0x754c}, 2), testCell(&.{}, 2),
        testCell(&.{'B'}, 1), testCell(&.{'x'}, 1),    testCell(&.{'x'}, 1),
    };
    row0[2].x = 1;
    row0[4].style_bits = protocol.text_v1.style.invisible;
    row0[5].style_bits = protocol.text_v1.style.invisible;
    var source_rows = [_]rich.Row{.{ .wrapped = false, .line_geometry = 0, .cells = &row0 }};
    var source = testSnapshot(&source_rows, 1, 6);
    const snapshot = try view.project(std.testing.allocator, &source);
    defer view.deinit(snapshot);

    const wide = (try row(snapshot, std.testing.allocator, "界B", 0, false)).?;
    try std.testing.expectEqual(@as(u16, 1), wide.start_column);
    try std.testing.expectEqual(@as(u16, 3), wide.end_column);
    const wide_only = (try row(snapshot, std.testing.allocator, "界", 0, false)).?;
    try std.testing.expectEqual(@as(u16, 1), wide_only.start_column);
    try std.testing.expectEqual(@as(u16, 2), wide_only.end_column);
    try std.testing.expect((try row(snapshot, std.testing.allocator, "xx", 0, false)) == null);
}

test "search first honors row and match direction" {
    var row0 = [_]rich.Cell{ testCell(&.{'x'}, 1), testCell(&.{'a'}, 1), testCell(&.{'a'}, 1) };
    var row1 = [_]rich.Cell{ testCell(&.{'a'}, 1), testCell(&.{'a'}, 1), testCell(&.{'x'}, 1) };
    var source_rows = [_]rich.Row{
        .{ .wrapped = false, .line_geometry = 0, .cells = &row0 },
        .{ .wrapped = false, .line_geometry = 0, .cells = &row1 },
    };
    var source = testSnapshot(&source_rows, 2, 3);
    const snapshot = try view.project(std.testing.allocator, &source);
    defer view.deinit(snapshot);

    const forward = (try first(snapshot, std.testing.allocator, "aa", 0, false)).?;
    try std.testing.expectEqual(@as(u16, 0), forward.viewport_row);
    try std.testing.expectEqual(@as(u16, 1), forward.start_column);

    const backward = (try first(snapshot, std.testing.allocator, "aa", 1, true)).?;
    try std.testing.expectEqual(@as(u16, 1), backward.viewport_row);
    try std.testing.expectEqual(@as(u16, 0), backward.start_column);
}

test "search rowFrom continues between multiple matches on one row" {
    var row0 = [_]rich.Cell{
        testCell(&.{'a'}, 1), testCell(&.{'a'}, 1), testCell(&.{' '}, 1),
        testCell(&.{'a'}, 1), testCell(&.{'a'}, 1), testCell(&.{' '}, 1),
        testCell(&.{'a'}, 1), testCell(&.{'a'}, 1),
    };
    var source_rows = [_]rich.Row{.{ .wrapped = false, .line_geometry = 0, .cells = &row0 }};
    var source = testSnapshot(&source_rows, 1, 8);
    const snapshot = try view.project(std.testing.allocator, &source);
    defer view.deinit(snapshot);

    const second = (try rowFrom(snapshot, std.testing.allocator, "aa", 0, 3, false)).?;
    try std.testing.expectEqual(@as(u16, 3), second.start_column);
    const before_last = (try rowFrom(snapshot, std.testing.allocator, "aa", 0, 4, true)).?;
    try std.testing.expectEqual(@as(u16, 3), before_last.start_column);
    const first_match = (try rowFrom(snapshot, std.testing.allocator, "aa", 0, 2, true)).?;
    try std.testing.expectEqual(@as(u16, 0), first_match.start_column);
}

test "search query is exact utf8 and does not cross projected rows" {
    var row0 = [_]rich.Cell{ testCell(&.{'a'}, 1), testCell(&.{'b'}, 1) };
    var row1 = [_]rich.Cell{ testCell(&.{'c'}, 1), testCell(&.{'d'}, 1) };
    var source_rows = [_]rich.Row{
        .{ .wrapped = true, .line_geometry = 0, .cells = &row0 },
        .{ .wrapped = false, .line_geometry = 0, .cells = &row1 },
    };
    var source = testSnapshot(&source_rows, 2, 2);
    const snapshot = try view.project(std.testing.allocator, &source);
    defer view.deinit(snapshot);

    try std.testing.expect((try first(snapshot, std.testing.allocator, "bc", 0, false)) == null);
    try std.testing.expectError(error.InvalidQuery, first(snapshot, std.testing.allocator, "", 0, false));
    try std.testing.expectError(error.InvalidQuery, first(snapshot, std.testing.allocator, &.{0xff}, 0, false));
}
