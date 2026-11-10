const std = @import("std");
const protocol = @import("server_client").terminal.protocol;
const client = @import("server_client").terminal;
const rich_format = @import("rich_format.zig");

/// Selects the shared client's compact snapshot detail.
pub const Detail = client.snapshot.Detail;
/// Shared client line geometry vocabulary.
pub const LineGeometry = client.snapshot.LineGeometry;
/// Allocator-owned compact snapshot returned by the shared client.
pub const Snapshot = client.snapshot.Snapshot;
/// Requests a compact snapshot through the shared client owner.
pub const request = client.snapshot.request;

const Geometry = struct { rows: u16, columns: u16 };
const Viewport = struct {
    screen: []const u8,
    history_offset: u32,
    history_count: u32,
    history_row_base: u32,
};
const Cursor = struct {
    row: u16,
    column: u16,
    shape: []const u8,
    shape_id: u8,
    visible: bool,
    blink: bool,
};
const Lifecycle = struct { stream_closed: bool, child_exited: bool };
const Resize = struct { leader_present: bool, you_are_leader: bool };
const Compact = struct {
    schema: []const u8 = "howl.snapshot/v1",
    revision: u64,
    terminal_revision: u64,
    geometry: Geometry,
    viewport: Viewport,
    cursor: Cursor,
    lifecycle: Lifecycle,
    resize: Resize,
    lines: [][]const u8,
    wrapped_rows: []u16,
    line_geometry: []LineGeometry,
    detail: Detail,
};

/// Writes one compact snapshot as JSON without taking its ownership.
pub fn emitCompact(writer: *std.Io.Writer, value: *const Snapshot) !void {
    const begin = value.begin;
    try std.json.Stringify.value(Compact{
        .revision = begin.revision,
        .terminal_revision = begin.terminal.revision,
        .geometry = .{ .rows = begin.terminal.rows, .columns = begin.terminal.columns },
        .viewport = .{
            .screen = if (begin.terminal.alternate_screen) "alternate" else "primary",
            .history_offset = begin.terminal.history_offset,
            .history_count = begin.terminal.history_count,
            .history_row_base = begin.terminal.history_row_base,
        },
        .cursor = .{
            .row = begin.terminal.cursor_row,
            .column = begin.terminal.cursor_column,
            .shape = client.snapshot.cursorShapeName(begin.terminal.cursor_shape),
            .shape_id = begin.terminal.cursor_shape,
            .visible = begin.terminal.cursor_visible,
            .blink = begin.terminal.cursor_blink,
        },
        .lifecycle = .{
            .stream_closed = begin.stream_closed,
            .child_exited = begin.child_exited,
        },
        .resize = .{
            .leader_present = begin.leader_present,
            .you_are_leader = begin.you_are_leader,
        },
        .lines = value.lines,
        .wrapped_rows = value.wrapped_rows,
        .line_geometry = value.line_geometry,
        .detail = value.detail,
    }, .{}, writer);
    try writer.writeByte('\n');
}

/// Writes snapshot text without taking its ownership.
pub fn emitText(writer: *std.Io.Writer, value: *const Snapshot) !void {
    for (value.lines) |line| {
        try writer.writeAll(line);
        try writer.writeByte('\n');
    }
}

/// Formats an owned, validated Server terminal-client rich observation.
pub fn requestRich(
    allocator: std.mem.Allocator,
    connection: *client.Connection,
    writer: *std.Io.Writer,
    after_revision: u64,
    history_offset: u32,
) !void {
    var value = try client.rich.request(connection, allocator, after_revision, history_offset);
    defer value.deinit();
    try rich_format.emitNative(allocator, writer, &value);
}
