//! Terminal-only metadata for one semantic observation.
const std = @import("std");
const values = @import("decoded.zig");
const wire = @import("wire.zig");

/// Exact portable metadata width, independent of framing or Server state.
pub const bytes: usize = 30;
/// Cursor visibility/blink and screen-bank flags; every other bit is reserved.
pub const flags_mask: u8 = 0x07;

/// VT facts captured with the text, graphics and properties of one observation.
pub const Metadata = struct {
    /// Canonical VT semantic revision, independent of observer delivery identity.
    revision: u64,
    history_offset: u32,
    history_count: u32,
    history_row_base: u32,
    rows: u16,
    columns: u16,
    cursor_row: u16,
    cursor_column: u16,
    cursor_shape: u8,
    cursor_visible: bool,
    cursor_blink: bool,
    alternate_screen: bool,

    /// Returns the viewport geometry used by text and graphics payload validation.
    pub fn geometry(self: Metadata) values.Geometry {
        return .{ .rows = self.rows, .columns = self.columns };
    }
};

/// Encodes terminal facts without any observation, lifecycle or authority flags.
pub fn encode(output: *[bytes]u8, value: Metadata) void {
    std.mem.writeInt(u64, output[0..8], value.revision, .big);
    std.mem.writeInt(u32, output[8..12], value.history_offset, .big);
    std.mem.writeInt(u32, output[12..16], value.history_count, .big);
    std.mem.writeInt(u32, output[16..20], value.history_row_base, .big);
    std.mem.writeInt(u16, output[20..22], value.rows, .big);
    std.mem.writeInt(u16, output[22..24], value.columns, .big);
    std.mem.writeInt(u16, output[24..26], value.cursor_row, .big);
    std.mem.writeInt(u16, output[26..28], value.cursor_column, .big);
    output[28] = value.cursor_shape;
    output[29] = @as(u8, @intFromBool(value.cursor_visible)) |
        (@as(u8, @intFromBool(value.cursor_blink)) << 1) |
        (@as(u8, @intFromBool(value.alternate_screen)) << 2);
}

/// Decodes exact-width terminal metadata and rejects nonterminal flag bits.
/// Cursor-shape and geometry coherence are checked by semantic view projection;
/// this byte grammar preserves all u8 shapes and the valid empty viewport.
pub fn decode(input: []const u8) wire.PayloadError!Metadata {
    if (input.len != bytes or input[29] & ~flags_mask != 0) return error.InvalidPayload;
    return .{
        .revision = std.mem.readInt(u64, input[0..8], .big),
        .history_offset = std.mem.readInt(u32, input[8..12], .big),
        .history_count = std.mem.readInt(u32, input[12..16], .big),
        .history_row_base = std.mem.readInt(u32, input[16..20], .big),
        .rows = std.mem.readInt(u16, input[20..22], .big),
        .columns = std.mem.readInt(u16, input[22..24], .big),
        .cursor_row = std.mem.readInt(u16, input[24..26], .big),
        .cursor_column = std.mem.readInt(u16, input[26..28], .big),
        .cursor_shape = input[28],
        .cursor_visible = input[29] & 1 != 0,
        .cursor_blink = input[29] & 2 != 0,
        .alternate_screen = input[29] & 4 != 0,
    };
}

test "metadata bytes contain only terminal facts" {
    const value: Metadata = .{
        .revision = 0x1112_1314_1516_1718,
        .history_offset = 0x2122_2324,
        .history_count = 0x3132_3334,
        .history_row_base = 0x4142_4344,
        .rows = 0x5152,
        .columns = 0x6162,
        .cursor_row = 0x7172,
        .cursor_column = 0x8182,
        .cursor_shape = 0x91,
        .cursor_visible = true,
        .cursor_blink = true,
        .alternate_screen = true,
    };
    var encoded: [bytes]u8 = undefined;
    encode(&encoded, value);
    try std.testing.expectEqualSlices(u8, &.{
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
        0x21, 0x22, 0x23, 0x24, 0x31, 0x32, 0x33, 0x34,
        0x41, 0x42, 0x43, 0x44, 0x51, 0x52, 0x61, 0x62,
        0x71, 0x72, 0x81, 0x82, 0x91, 0x07,
    }, &encoded);
    try std.testing.expectEqualDeep(value, try decode(&encoded));
    try std.testing.expectEqual(values.Geometry{ .rows = value.rows, .columns = value.columns }, value.geometry());
    try std.testing.expectError(error.InvalidPayload, decode(encoded[0 .. bytes - 1]));
    var extended: [bytes + 1]u8 = @splat(0);
    @memcpy(extended[0..bytes], &encoded);
    try std.testing.expectError(error.InvalidPayload, decode(&extended));
    for (0..256) |flags| {
        encoded[29] = @intCast(flags);
        if (flags & ~@as(usize, flags_mask) != 0) {
            try std.testing.expectError(error.InvalidPayload, decode(&encoded));
        } else {
            const decoded = try decode(&encoded);
            try std.testing.expectEqual(flags & 1 != 0, decoded.cursor_visible);
            try std.testing.expectEqual(flags & 2 != 0, decoded.cursor_blink);
            try std.testing.expectEqual(flags & 4 != 0, decoded.alternate_screen);
        }
    }
}

test "metadata retains an empty viewport without Server identity" {
    const encoded: [bytes]u8 = @splat(0);
    const value = try decode(&encoded);
    try std.testing.expectEqual(@as(u64, 0), value.revision);
    try std.testing.expectEqual(values.Geometry{ .rows = 0, .columns = 0 }, value.geometry());
}
