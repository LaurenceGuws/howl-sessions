//! Client-local terminal selection over stable canonical history/screen points.
//!
//! Selection ownership stays with the presentation client. The server owns only
//! canonical text extraction for an inclusive stable range. Viewport scrolling
//! therefore never mutates the selected range, while history eviction, screen-bank
//! switches, and geometry changes are detected explicitly.

const std = @import("std");
const protocol = @import("server_protocol").terminal;
const client = @import("terminal_owner");
const rich = @import("rich.zig");
const view = @import("view.zig");

/// Stable canonical text point used by selection and extraction requests.
pub const Point = protocol.TextPoint;

/// Reports invalid selection geometry, extraction framing, or allocation failures.
pub const Error = client.Error || protocol.PayloadError || std.mem.Allocator.Error || error{
    ContextChanged,
    InvalidPoint,
    InvalidUtf8,
    SelectionRejected,
    UnexpectedFrame,
};

/// Classifies whether one retained canonical range still belongs to the current text domain.
pub const Validity = enum { valid, context_changed, evicted };

/// Inclusive painted column span within one displayed row.
pub const Span = struct {
    start_column: u16,
    end_column: u16,
};

/// Per-row presentation facts needed to paint terminal selection like copied
/// text instead of like a rectangular block. `content_end_exclusive` trims the
/// untouched/trailing blank tail while `wrapped` distinguishes a soft wrap from
/// a real row break. The range itself remains canonical stable cell identity.
pub const RowShape = struct {
    content_end_exclusive: u16,
    wrapped: bool,
};

/// Stable inclusive selection endpoints plus the geometry/bank context that names them.
pub const Range = struct {
    anchor: Point,
    focus: Point,
    columns: u16,
    alternate_screen: bool,

    /// Starts one collapsed selection at a displayed terminal cell.
    pub fn start(snapshot: *const view.Snapshot, viewport_row: u16, column: u16) Error!Range {
        const value = try point(snapshot, viewport_row, column);
        const begin = view.begin(snapshot);
        return .{
            .anchor = value,
            .focus = value,
            .columns = begin.terminal.columns,
            .alternate_screen = begin.terminal.alternate_screen,
        };
    }

    /// Moves only the focus endpoint. Geometry/bank changes invalidate rather than retarget.
    pub fn extend(self: *Range, snapshot: *const view.Snapshot, viewport_row: u16, column: u16) Error!void {
        if (self.validity(view.begin(snapshot)) == .context_changed) return error.ContextChanged;
        self.focus = try point(snapshot, viewport_row, column);
    }

    /// Classifies whether this stable range can still name the current canonical text domain.
    pub fn validity(self: Range, begin: *const protocol.SnapshotBegin) Validity {
        if (begin.terminal.columns != self.columns or begin.terminal.alternate_screen != self.alternate_screen)
            return .context_changed;
        const bounds = retainedRows(begin) orelse return .evicted;
        if (!pointRetained(self.anchor, self.columns, bounds) or
            !pointRetained(self.focus, self.columns, bounds))
            return .evicted;
        return .valid;
    }

    /// Returns the inclusive selected column span intersecting one displayed viewport row.
    pub fn viewportSpan(self: Range, begin: *const protocol.SnapshotBegin, viewport_row: u16) ?Span {
        if (self.validity(begin) != .valid or viewport_row >= begin.terminal.rows) return null;
        const row = viewportRow(begin, viewport_row) catch return null;
        const bounds = self.ordered();
        if (row < bounds.start.row or row > bounds.end.row) return null;
        return .{
            .start_column = if (row == bounds.start.row) bounds.start.column else 0,
            .end_column = if (row == bounds.end.row) bounds.end.column else self.columns - 1,
        };
    }

    /// Paints a stable range using row facts from the same presented snapshot.
    /// This matches Web/Flutter's text-shaped selection: hard line breaks get
    /// one visible newline cell; final and soft-wrapped rows get no blank tail.
    /// Only presentation changes. `request` still names the original endpoints.
    pub fn textSpan(self: Range, begin: *const protocol.SnapshotBegin, viewport_row: u16, shape: RowShape) ?Span {
        const span = self.viewportSpan(begin, viewport_row) orelse return null;
        const row = viewportRow(begin, viewport_row) catch return null;
        const content_end = @min(shape.content_end_exclusive, self.columns);
        if (row == self.ordered().end.row or shape.wrapped) {
            if (content_end == 0) return null;
            const last = @min(span.end_column, content_end - 1);
            if (last < span.start_column) return null;
            return .{ .start_column = span.start_column, .end_column = last };
        }
        const newline_column = @min(content_end, self.columns - 1);
        return .{
            .start_column = if (span.start_column < content_end) span.start_column else newline_column,
            .end_column = newline_column,
        };
    }

    /// Converts this client-local range into the canonical extraction request payload.
    pub fn request(self: Range) protocol.TextExtract {
        return .{
            .start = self.anchor,
            .end = self.focus,
            .columns = self.columns,
            .alternate_screen = self.alternate_screen,
        };
    }

    /// Returns endpoints ordered in canonical text order without mutating anchor/focus identity.
    pub fn ordered(self: Range) struct { start: Point, end: Point } {
        if (pointBeforeOrEqual(self.anchor, self.focus))
            return .{ .start = self.anchor, .end = self.focus };
        return .{ .start = self.focus, .end = self.anchor };
    }
};

/// Resolves one displayed cell to its stable canonical lead-cell identity.
pub fn point(snapshot: *const view.Snapshot, viewport_row: u16, column: u16) Error!Point {
    const begin = view.begin(snapshot);
    if (viewport_row >= begin.terminal.rows or column >= begin.terminal.columns) return error.InvalidPoint;
    const row = view.rows(snapshot)[viewport_row];
    if (column >= row.cell_count) return error.InvalidPoint;
    const cell = view.cells(snapshot)[@as(usize, row.cell_offset) + column];
    return viewportPoint(begin, viewport_row, column, cell.x, cell.y);
}

/// Expands one displayed nonblank terminal cell to the contiguous non-space word,
/// crossing only canonical soft-wrap boundaries. Returns null for blank/concealed cells.
pub fn word(snapshot: *const view.Snapshot, viewport_row: u16, column: u16) Error!?Range {
    const begin = view.begin(snapshot);
    if (viewport_row >= begin.terminal.rows or column >= begin.terminal.columns) return error.InvalidPoint;
    const start_pos = leadViewportPosition(snapshot, viewport_row, column) orelse return error.InvalidPoint;
    if (!selectableLead(snapshot, start_pos.row, start_pos.column)) return null;

    var first = start_pos;
    while (previousLead(snapshot, first.row, first.column)) |candidate| {
        if (!selectableLead(snapshot, candidate.row, candidate.column)) break;
        first = candidate;
    }

    var last = start_pos;
    while (nextLead(snapshot, last.row, last.column)) |candidate| {
        if (!selectableLead(snapshot, candidate.row, candidate.column)) break;
        last = candidate;
    }
    return .{
        .anchor = try point(snapshot, first.row, first.column),
        .focus = try point(snapshot, last.row, last.column),
        .columns = begin.terminal.columns,
        .alternate_screen = begin.terminal.alternate_screen,
    };
}

/// Selects the text-shaped content of one projected visual row.
///
/// This is deliberately not a logical hard-line abstraction: a soft-wrapped
/// terminal line may span several projected rows, and a viewport boundary may
/// expose only one part of it. Returns null for a visually blank row.
pub fn visualRow(snapshot: *const view.Snapshot, viewport_row: u16) Error!?Range {
    const begin = view.begin(snapshot);
    if (viewport_row >= begin.terminal.rows or begin.terminal.columns == 0) return error.InvalidPoint;
    const shape = rowShape(snapshot, viewport_row) orelse return error.InvalidPoint;
    if (shape.content_end_exclusive == 0) return null;

    const row = view.rows(snapshot)[viewport_row];
    const row_cells = view.cells(snapshot)[row.cell_offset .. row.cell_offset + row.cell_count];
    var start_column: ?u16 = null;
    for (row_cells, 0..) |cell, index| {
        if (cell.x == 0 and cell.y == 0) {
            start_column = @intCast(index);
            break;
        }
    }
    const first = start_column orelse return null;
    const last: u16 = shape.content_end_exclusive - 1;
    const range = Range{
        .anchor = try point(snapshot, viewport_row, first),
        .focus = try point(snapshot, viewport_row, last),
        .columns = begin.terminal.columns,
        .alternate_screen = begin.terminal.alternate_screen,
    };
    return range;
}

/// Returns the painted column span for one displayed row, expanding a selected
/// final lead cell across its complete horizontal terminal-cell width.
pub fn visualSpan(snapshot: *const view.Snapshot, range: Range, viewport_row: u16) ?Span {
    const span = range.viewportSpan(view.begin(snapshot), viewport_row) orelse return null;
    const ordered = range.ordered();
    const row_identity = viewportRow(view.begin(snapshot), viewport_row) catch return null;
    if (row_identity != ordered.end.row) return span;
    const row = view.rows(snapshot)[viewport_row];
    if (span.end_column >= row.cell_count) return span;
    const cell = view.cells(snapshot)[@as(usize, row.cell_offset) + span.end_column];
    if (cell.x != 0 or cell.y != 0) return span;
    const expanded = @min(
        @as(u32, range.columns - 1),
        @as(u32, span.end_column) + @as(u32, @max(cell.width, 1)) - 1,
    );
    return .{ .start_column = span.start_column, .end_column = @intCast(expanded) };
}

/// Returns the text-shaped extent for one displayed row. Trailing ordinary
/// spaces are deliberately trimmed to match multi-row canonical text copy.
/// Wide lead cells retain their complete horizontal cell width.
pub fn rowShape(snapshot: *const view.Snapshot, viewport_row: u16) ?RowShape {
    const begin = view.begin(snapshot);
    if (viewport_row >= begin.terminal.rows) return null;
    const row = view.rows(snapshot)[viewport_row];
    const row_cells = view.cells(snapshot)[row.cell_offset .. row.cell_offset + row.cell_count];
    const row_scalars = view.scalars(snapshot);
    var scan = row_cells.len;
    while (scan > 0) {
        scan -= 1;
        const cell = row_cells[scan];
        if (cell.x != 0 or cell.y != 0 or cell.scalar_count == 0) continue;
        const first = row_scalars[cell.scalar_offset];
        if (first == ' ') continue;
        const width = @max(cell.width, 1);
        const end = @min(@as(usize, begin.terminal.columns), scan + width);
        return .{ .content_end_exclusive = @intCast(end), .wrapped = row.wrapped };
    }
    return .{ .content_end_exclusive = 0, .wrapped = row.wrapped };
}

/// Borrowed-rich equivalent of rowShape. Rich observations have already passed
/// the wire decoder's semantic validation; this scan retains no source slices.
pub fn rowShapeRich(snapshot: *const rich.View, viewport_row: u16) ?RowShape {
    if (viewport_row >= snapshot.begin.terminal.rows or viewport_row >= snapshot.rows.len) return null;
    const row = snapshot.rows[viewport_row];
    var scan = row.cells.len;
    while (scan > 0) {
        scan -= 1;
        const cell = row.cells[scan];
        if (cell.x != 0 or cell.y != 0 or cell.scalars.len == 0) continue;
        if (cell.scalars[0] == ' ') continue;
        const width = @max(cell.width, 1);
        const end = @min(@as(usize, snapshot.begin.terminal.columns), scan + width);
        return .{ .content_end_exclusive = @intCast(end), .wrapped = row.wrapped };
    }
    return .{ .content_end_exclusive = 0, .wrapped = row.wrapped };
}

/// Requests canonical UTF-8 for one client-local range. The returned allocation belongs to `allocator`.
pub fn extract(connection: *client.Connection, allocator: std.mem.Allocator, range: Range) Error![]u8 {
    if (range.columns == 0 or range.anchor.column >= range.columns or
        range.focus.column >= range.columns or range.anchor.row < 0 or range.focus.row < 0)
        return error.InvalidPoint;
    var payload: [protocol.payload_bytes.text_extract]u8 = undefined;
    protocol.encodeTextExtract(&payload, range.request());
    try connection.send(.text_extract, &payload);
    var completed = false;
    defer if (!completed) client.retire(connection);
    var frame = try connection.receive();
    defer frame.deinit();
    switch (frame.kind) {
        .text_extract_data => {
            if (!std.unicode.utf8ValidateSlice(frame.payload)) return error.InvalidUtf8;
            completed = true;
            return allocator.dupe(u8, frame.payload);
        },
        .result => {
            const result = try protocol.decodeResult(frame.payload);
            if (result.request_kind != .text_extract or result.code == .ok) return error.UnexpectedFrame;
            completed = true;
            return error.SelectionRejected;
        },
        else => return error.UnexpectedFrame,
    }
}

const RowBounds = struct { first: i32, last: i32 };

fn retainedRows(begin: *const protocol.SnapshotBegin) ?RowBounds {
    if (begin.terminal.rows == 0) return null;
    if (begin.terminal.alternate_screen) return .{ .first = 0, .last = @intCast(begin.terminal.rows - 1) };
    const first: u64 = begin.terminal.history_row_base;
    const last = first + @as(u64, begin.terminal.history_count) + @as(u64, begin.terminal.rows) - 1;
    // Points name only the representable retained prefix. Newer unprojected
    // rows beyond i32 cannot evict older coordinates that still name text.
    if (first > std.math.maxInt(i32)) return null;
    return .{ .first = @intCast(first), .last = @intCast(@min(last, std.math.maxInt(i32))) };
}

fn pointRetained(value: Point, columns: u16, bounds: RowBounds) bool {
    return value.column < columns and value.row >= bounds.first and value.row <= bounds.last;
}

fn viewportRow(begin: *const protocol.SnapshotBegin, viewport_row: u16) error{InvalidPoint}!i32 {
    if (viewport_row >= begin.terminal.rows) return error.InvalidPoint;
    if (begin.terminal.alternate_screen) return @intCast(viewport_row);
    if (begin.terminal.history_offset > begin.terminal.history_count) return error.InvalidPoint;
    const row = @as(u64, begin.terminal.history_row_base) + begin.terminal.history_count - begin.terminal.history_offset + viewport_row;
    if (row > std.math.maxInt(i32)) return error.InvalidPoint;
    return @intCast(row);
}

fn viewportPoint(
    begin: *const protocol.SnapshotBegin,
    viewport_row: u16,
    column: u16,
    continuation_x: u8,
    continuation_y: u8,
) error{InvalidPoint}!Point {
    if (column >= begin.terminal.columns or continuation_x > column) return error.InvalidPoint;
    const row = try viewportRow(begin, viewport_row);
    if (@as(i64, row) < continuation_y) return error.InvalidPoint;
    return .{
        .row = row - @as(i32, continuation_y),
        .column = column - continuation_x,
    };
}

fn pointBeforeOrEqual(left: Point, right: Point) bool {
    return left.row < right.row or left.row == right.row and left.column <= right.column;
}

const ViewportPosition = struct { row: u16, column: u16 };

fn leadViewportPosition(snapshot: *const view.Snapshot, row_index: u16, column: u16) ?ViewportPosition {
    const row = view.rows(snapshot)[row_index];
    if (column >= row.cell_count) return null;
    const cell = view.cells(snapshot)[@as(usize, row.cell_offset) + column];
    if (cell.x > column or cell.y > row_index) return null;
    return .{ .row = row_index - cell.y, .column = column - cell.x };
}

fn selectableLead(snapshot: *const view.Snapshot, row_index: u16, column: u16) bool {
    const row = view.rows(snapshot)[row_index];
    if (column >= row.cell_count) return false;
    const cell = view.cells(snapshot)[@as(usize, row.cell_offset) + column];
    if (cell.x != 0 or cell.y != 0 or cell.scalar_count == 0 or
        view.cellStyle(cell).invisible)
        return false;
    const first_scalar = view.scalars(snapshot)[cell.scalar_offset];
    return first_scalar != ' ';
}

// Repeated lower-row occupancy is an earlier cluster, never a traversal step.
// Every scan advances physically even when a malformed extent is zero.
fn previousLead(snapshot: *const view.Snapshot, row_index: u16, column_index: u16) ?ViewportPosition {
    const rows = view.rows(snapshot);
    const cells = view.cells(snapshot);
    var row = row_index;
    var column: i32 = @as(i32, column_index) - 1;
    while (true) {
        const current = rows[row];
        while (column >= 0) {
            if (column >= current.cell_count) return null;
            const cell = cells[@as(usize, current.cell_offset) + @as(usize, @intCast(column))];
            if (cell.y == 0) {
                const lead = leadViewportPosition(snapshot, row, @intCast(column)) orelse return null;
                if (lead.row < row_index or (lead.row == row_index and lead.column < column_index)) return lead;
            }
            column -= @as(i32, cell.x) + 1;
        }
        if (row == 0 or !rows[row - 1].wrapped) return null;
        row -= 1;
        // Projected row count is bounded by the u16 column geometry.
        column = @as(i32, @intCast(rows[row].cell_count)) - 1;
    }
}

fn nextLead(snapshot: *const view.Snapshot, row_index: u16, column_index: u16) ?ViewportPosition {
    const rows = view.rows(snapshot);
    const cells = view.cells(snapshot);
    const first_row = rows[row_index];
    if (column_index >= first_row.cell_count) return null;
    const first = cells[@as(usize, first_row.cell_offset) + column_index];
    var row = row_index;
    var column = @as(u32, column_index) + @max(@as(u32, first.width), 1);
    while (true) {
        const current = rows[row];
        while (column < current.cell_count) {
            const cell = cells[@as(usize, current.cell_offset) + column];
            if (cell.y == 0) {
                const lead = leadViewportPosition(snapshot, row, @intCast(column)) orelse return null;
                if (lead.row > row_index or (lead.row == row_index and lead.column > column_index)) return lead;
            }
            column += @max(@as(u32, cell.width) -| cell.x, 1);
        }
        if (!current.wrapped or row + 1 >= rows.len) return null;
        row += 1;
        column = 0;
    }
}

test "viewport points retain stable row identity while history offset changes" {
    var begin = testBegin();
    try std.testing.expectEqual(Point{ .row = 104, .column = 7 }, try viewportPoint(&begin, 1, 7, 0, 0));
    begin.terminal.history_offset = 3;
    try std.testing.expectEqual(Point{ .row = 101, .column = 7 }, try viewportPoint(&begin, 1, 7, 0, 0));
    try std.testing.expectEqual(Point{ .row = 100, .column = 5 }, try viewportPoint(&begin, 1, 7, 2, 1));
}

test "selection survives scroll movement and exposes deterministic viewport spans" {
    var begin = testBegin();
    const range = Range{
        .anchor = .{ .row = 101, .column = 3 },
        .focus = .{ .row = 105, .column = 5 },
        .columns = begin.terminal.columns,
        .alternate_screen = false,
    };
    try std.testing.expectEqual(Validity.valid, range.validity(&begin));
    try std.testing.expectEqual(@as(?Span, .{ .start_column = 0, .end_column = 5 }), range.viewportSpan(&begin, 2));
    begin.terminal.history_offset = 3;
    try std.testing.expectEqual(@as(?Span, .{ .start_column = 3, .end_column = 7 }), range.viewportSpan(&begin, 1));
    try std.testing.expectEqual(@as(?Span, .{ .start_column = 0, .end_column = 7 }), range.viewportSpan(&begin, 2));
}

test "selection invalidates on eviction bank change or geometry change" {
    var begin = testBegin();
    var range = Range{
        .anchor = .{ .row = 100, .column = 0 },
        .focus = .{ .row = 102, .column = 2 },
        .columns = begin.terminal.columns,
        .alternate_screen = false,
    };
    try std.testing.expectEqual(Validity.valid, range.validity(&begin));
    begin.terminal.history_row_base = 101;
    try std.testing.expectEqual(Validity.evicted, range.validity(&begin));
    begin = testBegin();
    begin.terminal.columns += 1;
    try std.testing.expectEqual(Validity.context_changed, range.validity(&begin));
    begin = testBegin();
    begin.terminal.alternate_screen = true;
    try std.testing.expectEqual(Validity.context_changed, range.validity(&begin));

    range = .{
        .anchor = .{ .row = 2, .column = 2 },
        .focus = .{ .row = 0, .column = 1 },
        .columns = 8,
        .alternate_screen = true,
    };
    begin = testBegin();
    begin.terminal.alternate_screen = true;
    begin.terminal.history_count = 0;
    begin.terminal.history_offset = 0;
    try std.testing.expectEqual(Validity.valid, range.validity(&begin));
    const ordered = range.ordered();
    try std.testing.expectEqual(Point{ .row = 0, .column = 1 }, ordered.start);
    try std.testing.expectEqual(Point{ .row = 2, .column = 2 }, ordered.end);
}

test "word selection crosses soft wrap and visual span covers a wide grapheme" {
    var cells0 = [_]rich.Cell{
        testCell(&.{'f'}, 1), testCell(&.{'o'}, 1), testCell(&.{'o'}, 1),
        testCell(&.{' '}, 1), testCell(&.{'b'}, 1), testCell(&.{'a'}, 1),
    };
    var cells1 = [_]rich.Cell{
        testCell(&.{'r'}, 1), testCell(&.{' '}, 1), testCell(&.{0x754c}, 2),
        testCell(&.{}, 2),    testCell(&.{'z'}, 1), testCell(&.{' '}, 1),
    };
    cells1[3].x = 1;
    var source_rows = [_]rich.Row{
        .{ .wrapped = true, .line_geometry = 0, .cells = &cells0 },
        .{ .wrapped = false, .line_geometry = 0, .cells = &cells1 },
    };
    const palette: [256]rich.Rgba = @splat(.{ .r = 0, .g = 0, .b = 0, .a = 0xff });
    const source = rich.Snapshot{
        .allocator = std.testing.allocator,
        .begin = testBeginForRows(2, 6),
        .presentation = testPresentation(palette),
        .rows = &source_rows,
        .hyperlinks = &.{},
    };
    const snapshot = try view.project(std.testing.allocator, &source);
    defer view.deinit(snapshot);

    const wrapped_word = (try word(snapshot, 1, 0)).?;
    const ordered_word = wrapped_word.ordered();
    try std.testing.expectEqual(Point{ .row = 0, .column = 4 }, ordered_word.start);
    try std.testing.expectEqual(Point{ .row = 1, .column = 0 }, ordered_word.end);
    try std.testing.expect((try word(snapshot, 0, 3)) == null);

    // The adjacent "z" belongs to the same non-space word as the wide glyph.
    const wide_word = (try word(snapshot, 1, 2)).?;
    try std.testing.expectEqual(@as(?Span, .{ .start_column = 2, .end_column = 4 }), visualSpan(snapshot, wide_word, 1));
    const lead = try point(snapshot, 1, 2);
    const wide_cell = Range{ .anchor = lead, .focus = lead, .columns = 6, .alternate_screen = false };
    try std.testing.expectEqual(@as(?Span, .{ .start_column = 2, .end_column = 3 }), visualSpan(snapshot, wide_cell, 1));
}

test "row shape trims blank tail and preserves wide text plus wrap identity" {
    var cells0 = [_]rich.Cell{
        testCell(&.{'A'}, 1), testCell(&.{'B'}, 1), testCell(&.{0x754c}, 2),
        testCell(&.{}, 2),    testCell(&.{' '}, 1), testCell(&.{}, 1),
    };
    cells0[3].x = 1;
    var cells1 = [_]rich.Cell{
        testCell(&.{}, 1), testCell(&.{}, 1), testCell(&.{}, 1),
        testCell(&.{}, 1), testCell(&.{}, 1), testCell(&.{}, 1),
    };
    var source_rows = [_]rich.Row{
        .{ .wrapped = true, .line_geometry = 0, .cells = &cells0 },
        .{ .wrapped = false, .line_geometry = 0, .cells = &cells1 },
    };
    const palette: [256]rich.Rgba = @splat(.{ .r = 0, .g = 0, .b = 0, .a = 0xff });
    const source = rich.Snapshot{
        .allocator = std.testing.allocator,
        .begin = testBeginForRows(2, 6),
        .presentation = testPresentation(palette),
        .rows = &source_rows,
        .hyperlinks = &.{},
    };
    const snapshot = try view.project(std.testing.allocator, &source);
    defer view.deinit(snapshot);

    try std.testing.expectEqual(
        @as(?RowShape, .{ .content_end_exclusive = 4, .wrapped = true }),
        rowShape(snapshot, 0),
    );
    try std.testing.expectEqual(
        @as(?RowShape, .{ .content_end_exclusive = 0, .wrapped = false }),
        rowShape(snapshot, 1),
    );
    try std.testing.expect(rowShape(snapshot, 2) == null);

    const borrowed = source.view();
    try std.testing.expectEqual(rowShape(snapshot, 0), rowShapeRich(&borrowed, 0));
    try std.testing.expectEqual(rowShape(snapshot, 1), rowShapeRich(&borrowed, 1));
    try std.testing.expect(rowShapeRich(&borrowed, 2) == null);

    const visual = (try visualRow(snapshot, 0)).?;
    const ordered = visual.ordered();
    try std.testing.expectEqual(Point{ .row = 0, .column = 0 }, ordered.start);
    try std.testing.expectEqual(Point{ .row = 0, .column = 2 }, ordered.end);
    try std.testing.expectEqual(
        @as(?Span, .{ .start_column = 0, .end_column = 3 }),
        visualSpan(snapshot, visual, 0),
    );
    try std.testing.expect((try visualRow(snapshot, 1)) == null);
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

fn testBeginForRows(rows: u16, columns: u16) protocol.SnapshotBegin {
    var value = testBegin();
    value.terminal.history_count = 0;
    value.terminal.history_row_base = 0;
    value.terminal.rows = rows;
    value.terminal.columns = columns;
    return value;
}

fn testPresentation(palette: [256]rich.Rgba) rich.Presentation {
    return .{
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
    };
}

fn testBegin() protocol.SnapshotBegin {
    return .{
        .revision = 10,
        .terminal = .{
            .revision = 9,
            .history_offset = 0,
            .history_count = 3,
            .history_row_base = 100,
            .rows = 4,
            .columns = 8,
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
}

test "text-shaped selection trims tails and keeps hard newline markers" {
    const begin = testBeginForRows(4, 8);
    const shapes = [_]RowShape{
        .{ .content_end_exclusive = 4, .wrapped = false },
        .{ .content_end_exclusive = 0, .wrapped = false },
        .{ .content_end_exclusive = 8, .wrapped = true },
        .{ .content_end_exclusive = 3, .wrapped = false },
    };
    const expected = [_]Span{
        .{ .start_column = 2, .end_column = 4 },
        .{ .start_column = 0, .end_column = 0 },
        .{ .start_column = 0, .end_column = 7 },
        .{ .start_column = 0, .end_column = 2 },
    };
    const forward = Range{
        .anchor = .{ .row = 0, .column = 2 },
        .focus = .{ .row = 3, .column = 6 },
        .columns = 8,
        .alternate_screen = false,
    };
    var reverse = forward;
    reverse.anchor = forward.focus;
    reverse.focus = forward.anchor;
    for (shapes, expected, 0..) |shape, want, row| {
        try std.testing.expectEqual(@as(?Span, want), forward.textSpan(&begin, @intCast(row), shape));
        try std.testing.expectEqual(@as(?Span, want), reverse.textSpan(&begin, @intCast(row), shape));
    }
    var tail = forward;
    tail.anchor.column = 7;
    tail.focus = .{ .row = 1, .column = 3 };
    try std.testing.expectEqual(@as(?Span, .{ .start_column = 4, .end_column = 4 }), tail.textSpan(&begin, 0, shapes[0]));
    try std.testing.expect(tail.textSpan(&begin, 1, shapes[1]) == null);
    try std.testing.expect(tail.textSpan(&begin, 2, shapes[2]) == null);
    const before = tail.request();
    try std.testing.expect(tail.textSpan(&begin, 0, shapes[0]) != null);
    try std.testing.expectEqualDeep(before, tail.request());
}

test "text-shaped selection stays bounded across history and context changes" {
    var begin = testBegin();
    const shape = RowShape{ .content_end_exclusive = 4, .wrapped = false };
    const range = Range{
        .anchor = .{ .row = 101, .column = 3 },
        .focus = .{ .row = 105, .column = 5 },
        .columns = 8,
        .alternate_screen = false,
    };
    try std.testing.expectEqual(@as(?Span, .{ .start_column = 0, .end_column = 3 }), range.textSpan(&begin, 2, shape));
    begin.terminal.history_offset = 3;
    try std.testing.expectEqual(@as(?Span, .{ .start_column = 3, .end_column = 4 }), range.textSpan(&begin, 1, shape));
    try std.testing.expectEqual(@as(?Span, .{ .start_column = 3, .end_column = 7 }), range.textSpan(&begin, 1, .{ .content_end_exclusive = 65535, .wrapped = false }));
    try std.testing.expect(range.textSpan(&begin, begin.terminal.rows, shape) == null);
    begin.terminal.columns += 1;
    try std.testing.expect(range.textSpan(&begin, 1, shape) == null);
    begin.terminal.columns -= 1;
    begin.terminal.alternate_screen = true;
    try std.testing.expect(range.textSpan(&begin, 1, shape) == null);
    begin.terminal.alternate_screen = false;
    begin.terminal.history_row_base = 102;
    try std.testing.expect(range.textSpan(&begin, 1, shape) == null);
}

test "text-shaped blank and soft-wrap final rows have no invented newline" {
    const begin = testBeginForRows(2, 8);
    const range = Range{
        .anchor = .{ .row = 0, .column = 5 },
        .focus = .{ .row = 1, .column = 7 },
        .columns = 8,
        .alternate_screen = false,
    };
    try std.testing.expect(range.textSpan(&begin, 0, .{ .content_end_exclusive = 4, .wrapped = true }) == null);
    try std.testing.expect(range.textSpan(&begin, 0, .{ .content_end_exclusive = 0, .wrapped = true }) == null);
    try std.testing.expect(range.textSpan(&begin, 1, .{ .content_end_exclusive = 0, .wrapped = false }) == null);
    try std.testing.expectEqual(@as(?Span, .{ .start_column = 0, .end_column = 3 }), range.textSpan(&begin, 1, .{ .content_end_exclusive = 4, .wrapped = true }));
}

test "tall wrapped word traversal progresses through repeated occupancy in both directions" {
    var cells: [2][8]rich.Cell = undefined;
    for (&cells) |*row| for (row) |*cell| {
        cell.* = testCell(&.{}, 1);
    };
    for (0..2) |row| for (0..4) |column| {
        cells[row][column] = testCell(&.{}, 4);
        cells[row][column].height = 2;
        cells[row][column].x = @intCast(column);
        cells[row][column].y = @intCast(row);
    };
    cells[0][0].scalars = &.{ 'H', 'i' };
    const letters = [_]u32{ 'a', 'b', 'c', 'd', 'e' };
    for (0..4) |column| cells[0][4 + column].scalars = letters[column..][0..1];
    cells[1][4].scalars = letters[4..5];
    var rows = [_]rich.Row{
        .{ .wrapped = true, .line_geometry = 0, .cells = &cells[0] },
        .{ .wrapped = false, .line_geometry = 0, .cells = &cells[1] },
    };
    const source = rich.Snapshot{
        .allocator = std.testing.allocator,
        .begin = testBeginForRows(2, 8),
        .presentation = testPresentation(@splat(.{ .r = 0, .g = 0, .b = 0, .a = 0xff })),
        .rows = &rows,
        .hyperlinks = &.{},
    };
    var snapshot = try view.project(std.testing.allocator, &source);
    defer view.deinit(snapshot);
    // Pin each physical transition before exercising the repeated word loop.
    try std.testing.expectEqual(@as(?ViewportPosition, .{ .row = 1, .column = 4 }), nextLead(snapshot, 0, 7));
    try std.testing.expectEqual(@as(?ViewportPosition, .{ .row = 0, .column = 7 }), previousLead(snapshot, 1, 4));
    for ([_]ViewportPosition{ .{ .row = 0, .column = 0 }, .{ .row = 0, .column = 2 }, .{ .row = 1, .column = 4 } }) |entry| {
        const range = (try word(snapshot, entry.row, entry.column)).?.ordered();
        try std.testing.expectEqual(Point{ .row = 0, .column = 0 }, range.start);
        try std.testing.expectEqual(Point{ .row = 1, .column = 4 }, range.end);
    }
    cells[0][6] = testCell(&.{' '}, 1);
    const separated = try view.project(std.testing.allocator, &source);
    view.deinit(snapshot);
    snapshot = separated;
    const range = (try word(snapshot, 1, 4)).?.ordered();
    try std.testing.expectEqual(Point{ .row = 0, .column = 7 }, range.start);
    try std.testing.expectEqual(Point{ .row = 1, .column = 4 }, range.end);
}
