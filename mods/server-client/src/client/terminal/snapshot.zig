//! Compact reasoning-friendly projection over the lossless native rich snapshot.
//!
//! rich.zig receives Server observations through the optional VT codec.
//! This module projects validated terminal facts without parsing wire bytes.

const std = @import("std");
const protocol = @import("server_protocol").terminal;
const client = @import("terminal_owner");
const rich = @import("rich.zig");

/// Reports lossless rich-snapshot or projection allocation failures.
pub const Error = rich.Error || std.mem.Allocator.Error;

/// Counts rich facts intentionally summarized out of the compact text projection.
pub const Detail = struct {
    styled_cells: u32 = 0,
    linked_cells: u32 = 0,
    multicell_cells: u32 = 0,
    hyperlinks: u32 = 0,
    images: u32 = 0,
    image_placements: u32 = 0,
};

/// Names one non-default DEC line geometry in the compact projection.
pub const LineGeometry = struct {
    row: u16,
    value: []const u8,
    value_id: u8,
};

/// Owns one compact text-first projection of a lossless rich snapshot.
pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    begin: protocol.SnapshotBegin,
    lines: [][]const u8,
    wrapped_rows: []u16,
    line_geometry: []LineGeometry,
    detail: Detail,

    /// Releases every owned projected line and metadata array.
    pub fn deinit(self: *Snapshot) void {
        for (self.lines) |line| self.allocator.free(line);
        self.allocator.free(self.lines);
        self.allocator.free(self.wrapped_rows);
        self.allocator.free(self.line_geometry);
        self.* = undefined;
    }
};

/// Requests one rich snapshot and immediately projects it into compact owned form.
pub fn request(
    connection: *client.Connection,
    allocator: std.mem.Allocator,
    after_revision: u64,
    history_offset: u32,
) Error!Snapshot {
    var full = try rich.request(connection, allocator, after_revision, history_offset);
    defer full.deinit();
    return project(allocator, &full);
}

/// Projects one already-owned rich snapshot into compact text and detail counts.
pub fn project(allocator: std.mem.Allocator, full: *const rich.Snapshot) std.mem.Allocator.Error!Snapshot {
    const lines = try allocator.alloc([]const u8, full.rows.len);
    errdefer allocator.free(lines);
    var initialized_lines: usize = 0;
    errdefer for (lines[0..initialized_lines]) |line| allocator.free(line);

    var wrapped_rows: std.ArrayList(u16) = .empty;
    errdefer wrapped_rows.deinit(allocator);
    var line_geometry: std.ArrayList(LineGeometry) = .empty;
    errdefer line_geometry.deinit(allocator);
    var detail: Detail = .{
        .hyperlinks = @intCast(full.hyperlinks.len),
        .images = @intCast(full.graphics.images.len),
        .image_placements = @intCast(full.graphics.placements.len),
    };

    for (full.rows, 0..) |row, row_index| {
        lines[row_index] = try projectRow(allocator, row, &detail);
        initialized_lines += 1;
        if (row.wrapped) try wrapped_rows.append(allocator, @intCast(row_index));
        if (row.line_geometry != 0) try line_geometry.append(allocator, .{
            .row = @intCast(row_index),
            .value = lineGeometryName(row.line_geometry),
            .value_id = row.line_geometry,
        });
    }

    const wrapped_owned = try wrapped_rows.toOwnedSlice(allocator);
    errdefer allocator.free(wrapped_owned);
    const geometry_owned = try line_geometry.toOwnedSlice(allocator);
    errdefer allocator.free(geometry_owned);
    return .{
        .allocator = allocator,
        .begin = full.begin,
        .lines = lines,
        .wrapped_rows = wrapped_owned,
        .line_geometry = geometry_owned,
        .detail = detail,
    };
}

fn projectRow(allocator: std.mem.Allocator, row: rich.Row, detail: *Detail) std.mem.Allocator.Error![]u8 {
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(allocator);
    for (row.cells) |cell| {
        if (cell.link_id != 0) detail.linked_cells += 1;
        if (cell.style_bits != 0 or cell.foreground.kind != .default or cell.background.kind != .default or
            cell.underline_color.kind != .default or cell.subscale_n != 0 or cell.subscale_d != 0 or
            cell.vertical_align != 0 or cell.horizontal_align != 0 or cell.semantic_width or cell.font != 0 or
            cell.baseline != 0 or cell.underline_style != 0 or cell.protection != 0)
            detail.styled_cells += 1;
        if (cell.width != 1 or cell.height != 1 or cell.x != 0 or cell.y != 0)
            detail.multicell_cells += 1;

        if (cell.scalars.len == 0) {
            if (cell.x == 0 and cell.y == 0) try line.append(allocator, ' ');
            continue;
        }
        for (cell.scalars) |scalar| {
            var encoded: [4]u8 = undefined;
            // zig-audit: acknowledge catch_unreachable
            // reason: Rich-snapshot decoding validates every retained scalar before compact projection.
            const length = std.unicode.utf8Encode(@intCast(scalar), &encoded) catch unreachable;
            try line.appendSlice(allocator, encoded[0..length]);
        }
    }
    while (line.items.len != 0 and line.items[line.items.len - 1] == ' ') line.items.len -= 1;
    return line.toOwnedSlice(allocator);
}

fn lineGeometryName(value: u8) []const u8 {
    return switch (value) {
        1 => "double_width",
        2 => "double_height_top",
        3 => "double_height_bottom",
        else => "single_width",
    };
}

/// Returns a stable human-readable name for one encoded cursor shape value.
pub fn cursorShapeName(value: u8) []const u8 {
    return switch (value) {
        0 => "block",
        1 => "underline",
        2 => "bar",
        3 => "none",
        else => "unknown",
    };
}

test "compact projection preserves readable grapheme and reports omitted detail" {
    const scalars = [_]u32{'A'};
    var cells = [_]rich.Cell{
        .{
            .scalars = &scalars,
            .width = 1,
            .height = 1,
            .x = 0,
            .y = 0,
            .subscale_n = 0,
            .subscale_d = 0,
            .vertical_align = 0,
            .horizontal_align = 0,
            .semantic_width = false,
            .font = 0,
            .baseline = 0,
            .underline_style = 0,
            .protection = 0,
            .style_bits = protocol.text_v1.style.bold,
            .foreground = .{ .kind = .default, .value = 0 },
            .background = .{ .kind = .default, .value = 0 },
            .underline_color = .{ .kind = .default, .value = 0 },
            .link_id = 0,
        },
        .{
            .scalars = &.{},
            .width = 1,
            .height = 1,
            .x = 0,
            .y = 0,
            .subscale_n = 0,
            .subscale_d = 0,
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
        },
    };
    var detail: Detail = .{};
    const text = try projectRow(std.testing.allocator, .{
        .wrapped = true,
        .line_geometry = 0,
        .cells = &cells,
    }, &detail);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("A", text);
    try std.testing.expectEqual(@as(u32, 1), detail.styled_cells);
}
