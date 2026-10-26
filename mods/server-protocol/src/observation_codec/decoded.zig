//! Pure terminal observation values and payload validation.
//! Owned rows and graphics never borrow packet bytes; URI bytes are copied exactly.
const std = @import("std");
const protocol = @import("wire.zig");

/// Allocation failure or malformed/bounded terminal-state payload.
pub const Error = std.mem.Allocator.Error || protocol.PayloadError || error{
    InvalidSnapshot,
    SnapshotTooLarge,
};
/// The viewport needed to validate row and placement coordinates.
pub const Geometry = struct { rows: u16, columns: u16 };

/// One exact 8-bit RGBA color value from terminal presentation state.
pub const Rgba = struct { r: u8, g: u8, b: u8, a: u8 };

/// Complete decoded terminal presentation colors, palette, cursor age, and flags.
pub const Presentation = struct {
    cursor_age_ns: ?u64,
    presence_bits: u8,
    flags: u8,
    reverse_screen: bool,
    palette: [256]Rgba,
    foreground: Rgba,
    background: Rgba,
    cursor: ?Rgba,
    cursor_text: ?Rgba,
    selection_background: ?Rgba,
    selection_foreground: ?Rgba,
};

/// One lossless decoded terminal cell and its scalar/rendition metadata.
pub const Cell = struct {
    scalars: []const u32,
    width: u8,
    height: u8,
    x: u8,
    y: u8,
    subscale_n: u8,
    subscale_d: u8,
    vertical_align: u8,
    horizontal_align: u8,
    semantic_width: bool,
    font: u8,
    baseline: u8,
    underline_style: u8,
    protection: u8,
    style_bits: u16,
    foreground: protocol.TextColor,
    background: protocol.TextColor,
    underline_color: protocol.TextColor,
    link_id: u32,
};

/// One decoded terminal row plus its retained scalar storage.
pub const Row = struct {
    wrapped: bool,
    line_geometry: u8,
    cells: []Cell,
    /// One decoded-row scalar bank. Hand-built rows may leave this empty and
    /// retain independently owned cell scalar slices.
    scalar_storage: []u32 = &.{},
};

/// One retained OSC 8 hyperlink identity and owned URI bytes.
pub const Hyperlink = struct {
    link_id: u32,
    uri_bytes: []u8,
};

/// One decoded terminal graphics manifest and canonical cell-pixel lattice.
pub const Graphics = struct {
    generation: u64 = 0,
    content_generation: u64 = 0,
    cell_pixel_width: u32 = 0,
    cell_pixel_height: u32 = 0,
    images: []protocol.SnapshotImage = &.{},
    placements: []protocol.SnapshotImagePlacement = &.{},

    /// Releases owned descriptor and placement arrays.
    pub fn deinit(self: *Graphics, allocator: std.mem.Allocator) void {
        if (self.images.len != 0) allocator.free(self.images);
        if (self.placements.len != 0) allocator.free(self.placements);
        self.* = undefined;
    }
};

/// Validates and owns one graphics manifest within the supplied viewport.
pub fn decodeGraphics(
    allocator: std.mem.Allocator,
    begin: Geometry,
    payload: []const u8,
) Error!Graphics {
    if (payload.len < protocol.graphics_v2.manifest_header_bytes) return error.InvalidSnapshot;
    const header = protocol.decodeSnapshotGraphicsHeader(
        payload[0..protocol.graphics_v2.manifest_header_bytes],
    ) catch return error.InvalidSnapshot;
    const image_bytes = std.math.mul(
        usize,
        header.image_count,
        protocol.graphics_v2.image_bytes,
    ) catch return error.InvalidSnapshot;
    const placement_bytes = std.math.mul(
        usize,
        header.placement_count,
        protocol.graphics_v2.placement_bytes,
    ) catch return error.InvalidSnapshot;
    const expected = std.math.add(
        usize,
        protocol.graphics_v2.manifest_header_bytes + image_bytes,
        placement_bytes,
    ) catch return error.InvalidSnapshot;
    if (payload.len != expected) return error.InvalidSnapshot;

    const images = try allocator.alloc(protocol.SnapshotImage, header.image_count);
    errdefer allocator.free(images);
    const placements = try allocator.alloc(protocol.SnapshotImagePlacement, header.placement_count);
    errdefer allocator.free(placements);

    var offset: usize = protocol.graphics_v2.manifest_header_bytes;
    for (images, 0..) |*image, index| {
        image.* = protocol.decodeSnapshotImage(
            payload[offset..][0..protocol.graphics_v2.image_bytes],
        ) catch return error.InvalidSnapshot;
        for (images[0..index]) |prior| if (prior.image_id == image.image_id)
            return error.InvalidSnapshot;
        offset += protocol.graphics_v2.image_bytes;
    }

    var referenced = try allocator.alloc(bool, images.len);
    defer allocator.free(referenced);
    @memset(referenced, false);
    for (placements) |*placement| {
        placement.* = protocol.decodeSnapshotImagePlacement(
            payload[offset..][0..protocol.graphics_v2.placement_bytes],
        ) catch return error.InvalidSnapshot;
        if (placement.row >= begin.rows or placement.column >= begin.columns)
            return error.InvalidSnapshot;
        const image_index = graphicsImageIndex(images, placement.image_id) orelse
            return error.InvalidSnapshot;
        const image = images[image_index];
        if (placement.source_x > image.width or placement.source_y > image.height or
            placement.source_width > image.width - placement.source_x or
            placement.source_height > image.height - placement.source_y)
            return error.InvalidSnapshot;
        referenced[image_index] = true;
        offset += protocol.graphics_v2.placement_bytes;
    }
    for (referenced) |used| if (!used) return error.InvalidSnapshot;
    if (offset != payload.len) return error.InvalidSnapshot;
    return .{
        .generation = header.generation,
        .content_generation = header.content_generation,
        .cell_pixel_width = header.cell_pixel_width,
        .cell_pixel_height = header.cell_pixel_height,
        .images = images,
        .placements = placements,
    };
}

fn graphicsImageIndex(images: []const protocol.SnapshotImage, image_id: u32) ?usize {
    for (images, 0..) |image, index| if (image.image_id == image_id) return index;
    return null;
}

/// Validates and copies the complete terminal palette and optional colors.
pub fn decodePresentation(payload: []const u8) Error!Presentation {
    if (payload.len != protocol.text_v1.presentation_bytes) return error.InvalidSnapshot;
    const presence = payload[8];
    const flags = payload[9];
    if (presence & ~protocol.text_v1.presentation_presence.known != 0 or
        flags & ~protocol.text_v1.presentation_flags.known != 0 or
        payload[10] != 0 or payload[11] != 0)
        return error.InvalidSnapshot;

    var palette: [256]Rgba = undefined;
    var offset: usize = 12;
    for (&palette) |*slot| {
        slot.* = rgba(payload[offset..][0..4]);
        offset += 4;
    }
    const foreground = rgba(payload[offset..][0..4]);
    offset += 4;
    const background = rgba(payload[offset..][0..4]);
    offset += 4;
    const cursor_raw = rgba(payload[offset..][0..4]);
    offset += 4;
    const cursor_text_raw = rgba(payload[offset..][0..4]);
    offset += 4;
    const selection_background_raw = rgba(payload[offset..][0..4]);
    offset += 4;
    const selection_foreground_raw = rgba(payload[offset..][0..4]);
    offset += 4;
    if (offset != payload.len) return error.InvalidSnapshot;

    const age = readU64(payload[0..8]);
    return .{
        .cursor_age_ns = if (age == protocol.text_v1.no_cursor_movement_age_ns) null else age,
        .presence_bits = presence,
        .flags = flags,
        .reverse_screen = flags & protocol.text_v1.presentation_flags.reverse_screen != 0,
        .palette = palette,
        .foreground = foreground,
        .background = background,
        .cursor = if (presence & protocol.text_v1.presentation_presence.cursor != 0) cursor_raw else null,
        .cursor_text = if (presence & protocol.text_v1.presentation_presence.cursor_text != 0) cursor_text_raw else null,
        .selection_background = if (presence & protocol.text_v1.presentation_presence.selection_background != 0) selection_background_raw else null,
        .selection_foreground = if (presence & protocol.text_v1.presentation_presence.selection_foreground != 0) selection_foreground_raw else null,
    };
}

const text_cell_attribute_bytes = protocol.text_v1.cell_header_bytes - 1;

comptime {
    if (text_cell_attribute_bytes != 34)
        @compileError("rich cell attribute compare must track frozen text_v1 header width");
}

fn sameCellAttributes(
    left: *const [text_cell_attribute_bytes]u8,
    right: *const [text_cell_attribute_bytes]u8,
) bool {
    // Byte identity is endian-neutral; align(1) keeps these native word loads
    // valid for arbitrary record offsets without paying a generic slice loop.
    return unalignedValue(u64, left[0..8]) == unalignedValue(u64, right[0..8]) and
        unalignedValue(u64, left[8..16]) == unalignedValue(u64, right[8..16]) and
        unalignedValue(u64, left[16..24]) == unalignedValue(u64, right[16..24]) and
        unalignedValue(u64, left[24..32]) == unalignedValue(u64, right[24..32]) and
        unalignedValue(u16, left[32..34]) == unalignedValue(u16, right[32..34]);
}

fn unalignedValue(comptime T: type, bytes: []const u8) T {
    std.debug.assert(bytes.len == @sizeOf(T));
    // zig-audit: acknowledge ptr_cast
    // reason: The explicit align(1) load preserves arbitrary record offsets while bytes.len proves exactly one T is available.
    const value: *align(1) const T = @ptrCast(bytes.ptr);
    return value.*;
}

/// Validates and owns one row; referenced link bits commit only after success.
pub fn decodeRow(
    allocator: std.mem.Allocator,
    columns: u16,
    payload: []const u8,
    referenced: *[protocol.text_v1.maximum_hyperlinks + 1]bool,
) Error!Row {
    if (payload.len > protocol.maximum_text_snapshot_bytes) return error.SnapshotTooLarge;
    if (payload.len < protocol.text_v1.row_header_bytes or payload[0] > 1 or
        payload[1] > 3 or readU16(payload[2..4]) != columns)
        return error.InvalidSnapshot;
    const fixed_cells_bytes = std.math.mul(
        usize,
        columns,
        protocol.text_v1.cell_header_bytes,
    ) catch return error.InvalidSnapshot;
    const fixed_payload_bytes = std.math.add(
        usize,
        protocol.text_v1.row_header_bytes,
        fixed_cells_bytes,
    ) catch return error.InvalidSnapshot;
    if (payload.len < fixed_payload_bytes) return error.InvalidSnapshot;
    const scalar_bytes_total = payload.len - fixed_payload_bytes;
    if (scalar_bytes_total % @sizeOf(u32) != 0) return error.InvalidSnapshot;
    const scalar_count_total = scalar_bytes_total / @sizeOf(u32);
    if (scalar_count_total > @as(usize, columns) * protocol.text_v1.maximum_cell_scalars)
        return error.InvalidSnapshot;
    const cells = try allocator.alloc(Cell, columns);
    errdefer allocator.free(cells);
    const scalar_storage = try allocator.alloc(u32, scalar_count_total);
    errdefer allocator.free(scalar_storage);
    var scalar_used: usize = 0;

    var offset: usize = protocol.text_v1.row_header_bytes;
    var previous_attributes: ?*const [text_cell_attribute_bytes]u8 = null;
    var column: u16 = 0;
    while (column < columns) : (column += 1) {
        if (payload.len - offset < protocol.text_v1.cell_header_bytes) return error.InvalidSnapshot;
        const encoded = payload[offset..][0..protocol.text_v1.cell_header_bytes];
        const scalar_count = encoded[0];
        if (scalar_count > protocol.text_v1.maximum_cell_scalars) return error.InvalidSnapshot;
        const attributes: *const [text_cell_attribute_bytes]u8 = encoded[1..];
        var decoded: Cell = undefined;
        if (previous_attributes) |previous| {
            if (sameCellAttributes(attributes, previous)) {
                decoded = cells[column - 1];
            } else {
                decoded = try decodeCellAttributes(encoded);
            }
        } else {
            decoded = try decodeCellAttributes(encoded);
        }
        previous_attributes = attributes;

        offset += protocol.text_v1.cell_header_bytes;
        const scalar_bytes = @as(usize, scalar_count) * 4;
        if (payload.len - offset < scalar_bytes) return error.InvalidSnapshot;
        if ((decoded.x != 0 or decoded.y != 0) and scalar_count != 0) return error.InvalidSnapshot;
        if (scalar_count > scalar_storage.len - scalar_used) return error.InvalidSnapshot;
        const scalars = scalar_storage[scalar_used .. scalar_used + scalar_count];
        for (scalars, 0..) |*value, index| {
            value.* = readU32(payload[offset + index * 4 ..][0..4]);
            if (value.* > 0x10ffff or value.* >= 0xd800 and value.* <= 0xdfff)
                return error.InvalidSnapshot;
        }
        scalar_used += scalar_count;
        decoded.scalars = scalars;
        cells[column] = decoded;
        offset += scalar_bytes;
    }
    if (offset != payload.len or scalar_used != scalar_storage.len) return error.InvalidSnapshot;
    for (cells) |cell| if (cell.link_id != 0) {
        referenced[cell.link_id] = true;
    };
    return .{
        .wrapped = payload[0] == 1,
        .line_geometry = payload[1],
        .cells = cells,
        .scalar_storage = scalar_storage,
    };
}

fn decodeCellAttributes(
    encoded: *const [protocol.text_v1.cell_header_bytes]u8,
) Error!Cell {
    if (encoded[1] == 0 or encoded[2] == 0 or encoded[3] >= encoded[1] or encoded[4] >= encoded[2] or
        encoded[5] > 15 or encoded[6] > 15 or encoded[7] > 3 or encoded[8] > 3 or
        encoded[9] > 1 or encoded[10] > 15 or encoded[11] > 2 or encoded[12] > 4 or encoded[13] > 2)
        return error.InvalidSnapshot;
    const style_bits = readU16(encoded[14..16]);
    if (style_bits & ~protocol.text_v1.style.known != 0) return error.InvalidSnapshot;
    const foreground = try decodeColor(encoded[16..21]);
    const background = try decodeColor(encoded[21..26]);
    const underline_color = try decodeColor(encoded[26..31]);
    const link_id = readU32(encoded[31..35]);
    if (link_id > protocol.text_v1.maximum_hyperlinks) return error.InvalidSnapshot;
    return .{
        .scalars = &.{},
        .width = encoded[1],
        .height = encoded[2],
        .x = encoded[3],
        .y = encoded[4],
        .subscale_n = encoded[5],
        .subscale_d = encoded[6],
        .vertical_align = encoded[7],
        .horizontal_align = encoded[8],
        .semantic_width = encoded[9] == 1,
        .font = encoded[10],
        .baseline = encoded[11],
        .underline_style = encoded[12],
        .protection = encoded[13],
        .style_bits = style_bits,
        .foreground = foreground,
        .background = background,
        .underline_color = underline_color,
        .link_id = link_id,
    };
}

/// Copies one referenced URI; resolution commits only after successful allocation.
pub fn decodeHyperlink(
    allocator: std.mem.Allocator,
    payload: []const u8,
    referenced: *[protocol.text_v1.maximum_hyperlinks + 1]bool,
    resolved: *[protocol.text_v1.maximum_hyperlinks + 1]bool,
) Error!Hyperlink {
    if (payload.len < protocol.text_v1.hyperlink_header_bytes) return error.InvalidSnapshot;
    const link_id = readU32(payload[0..4]);
    const uri_len = readU16(payload[4..6]);
    if (link_id == 0 or link_id > protocol.text_v1.maximum_hyperlinks or
        uri_len == 0 or uri_len > protocol.text_v1.maximum_hyperlink_uri_bytes or
        payload.len != protocol.text_v1.hyperlink_header_bytes + uri_len or
        !referenced[link_id] or resolved[link_id])
        return error.InvalidSnapshot;
    const uri_bytes = try allocator.dupe(u8, payload[protocol.text_v1.hyperlink_header_bytes..]);
    resolved[link_id] = true;
    return .{
        .link_id = link_id,
        .uri_bytes = uri_bytes,
    };
}

fn decodeColor(bytes: []const u8) Error!protocol.TextColor {
    if (bytes.len != protocol.text_v1.color_bytes) return error.InvalidSnapshot;
    var encoded: [protocol.text_v1.color_bytes]u8 = undefined;
    @memcpy(&encoded, bytes);
    return protocol.decodeTextColor(&encoded);
}

fn rgba(bytes: []const u8) Rgba {
    std.debug.assert(bytes.len == 4);
    return .{ .r = bytes[0], .g = bytes[1], .b = bytes[2], .a = bytes[3] };
}

fn readU16(bytes: []const u8) u16 {
    std.debug.assert(bytes.len >= 2);
    return (@as(u16, bytes[0]) << 8) | bytes[1];
}

fn readU32(bytes: []const u8) u32 {
    std.debug.assert(bytes.len >= 4);
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        bytes[3];
}

fn readU64(bytes: []const u8) u64 {
    std.debug.assert(bytes.len >= 8);
    var value: u64 = 0;
    for (bytes[0..8]) |byte| value = (value << 8) | byte;
    return value;
}

/// Releases cell/scalar allocations in these rows, retaining the row slice itself.
pub fn deinitRows(allocator: std.mem.Allocator, rows: []const Row) void {
    for (rows) |row| {
        if (row.scalar_storage.len != 0) {
            allocator.free(row.scalar_storage);
        } else {
            for (row.cells) |cell| if (cell.scalars.len != 0) allocator.free(cell.scalars);
        }
        allocator.free(row.cells);
    }
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

test "rich graphics owns visible image identities and placements" {
    const begin = Geometry{ .rows = 2, .columns = 3 };
    var payload: [
        protocol.graphics_v2.manifest_header_bytes +
            protocol.graphics_v2.image_bytes + protocol.graphics_v2.placement_bytes
    ]u8 = undefined;
    var header: [protocol.graphics_v2.manifest_header_bytes]u8 = undefined;
    protocol.encodeSnapshotGraphicsHeader(&header, .{
        .generation = 11,
        .content_generation = 10,
        .cell_pixel_width = 10,
        .cell_pixel_height = 20,
        .image_count = 1,
        .placement_count = 1,
    });
    @memcpy(payload[0..header.len], &header);
    var offset: usize = header.len;
    var image: [protocol.graphics_v2.image_bytes]u8 = undefined;
    protocol.encodeSnapshotImage(&image, .{
        .image_id = 7,
        .generation = 9,
        .width = 4,
        .height = 3,
    });
    @memcpy(payload[offset..][0..image.len], &image);
    offset += image.len;
    var placement: [protocol.graphics_v2.placement_bytes]u8 = undefined;
    protocol.encodeSnapshotImagePlacement(&placement, .{
        .image_id = 7,
        .generation = 12,
        .row = 1,
        .column = 2,
        .source_x = 1,
        .source_y = 1,
        .source_width = 3,
        .source_height = 2,
        .cell_x = 2,
        .cell_y = 3,
        .pixel_width = 30,
        .pixel_height = 20,
        .z = -4,
    });
    @memcpy(payload[offset..][0..placement.len], &placement);

    var graphics = try decodeGraphics(std.testing.allocator, begin, &payload);
    defer graphics.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 11), graphics.generation);
    try std.testing.expectEqual(@as(u64, 10), graphics.content_generation);
    try std.testing.expectEqual(@as(usize, 1), graphics.images.len);
    try std.testing.expectEqual(@as(u32, 7), graphics.images[0].image_id);
    try std.testing.expectEqual(@as(u64, 9), graphics.images[0].generation);
    try std.testing.expectEqual(@as(usize, 1), graphics.placements.len);
    try std.testing.expectEqual(@as(u16, 1), graphics.placements[0].row);
    try std.testing.expectEqual(@as(u16, 2), graphics.placements[0].column);
    try std.testing.expectEqual(@as(i32, -4), graphics.placements[0].z);

    var bad = payload;
    // A source crop extending beyond the advertised image must fail closed.
    bad[protocol.graphics_v2.manifest_header_bytes + protocol.graphics_v2.image_bytes + 27] = 4;
    try std.testing.expectError(
        error.InvalidSnapshot,
        decodeGraphics(std.testing.allocator, begin, &bad),
    );
}

test "rich row preserves typed style color and grapheme state" {
    const columns: u16 = 1;
    var payload: [protocol.text_v1.row_header_bytes + protocol.text_v1.cell_header_bytes + 8]u8 = @splat(0);
    payload[0] = 1;
    payload[1] = 2;
    encodeU16(payload[2..4], 1);
    const cell = payload[4 .. 4 + protocol.text_v1.cell_header_bytes];
    cell[0] = 2;
    cell[1] = 1;
    cell[2] = 1;
    cell[5] = 1;
    cell[6] = 2;
    cell[7] = 1;
    cell[8] = 2;
    cell[9] = 1;
    cell[10] = 3;
    cell[11] = 1;
    cell[12] = 2;
    cell[13] = 1;
    encodeU16(cell[14..16], protocol.text_v1.style.bold | protocol.text_v1.style.italic | protocol.text_v1.style.underline);
    var color: [protocol.text_v1.color_bytes]u8 = undefined;
    try protocol.encodeTextColor(&color, .{ .kind = .rgb, .value = 0x112233 });
    @memcpy(cell[16..21], &color);
    try protocol.encodeTextColor(&color, .{ .kind = .indexed, .value = 4 });
    @memcpy(cell[21..26], &color);
    try protocol.encodeTextColor(&color, .{ .kind = .rgb, .value = 0x445566 });
    @memcpy(cell[26..31], &color);
    encodeU32(cell[31..35], 7);
    encodeU32(payload[payload.len - 8 .. payload.len - 4], 'e');
    encodeU32(payload[payload.len - 4 ..], 0x0301);

    var referenced: [protocol.text_v1.maximum_hyperlinks + 1]bool = @splat(false);
    const row = try decodeRow(std.testing.allocator, columns, &payload, &referenced);
    defer deinitRows(std.testing.allocator, &.{row});
    const decoded = row.cells[0];
    try std.testing.expect(row.wrapped);
    try std.testing.expectEqual(@as(u8, 2), row.line_geometry);
    try std.testing.expectEqualSlices(u32, &.{ 'e', 0x0301 }, decoded.scalars);
    try std.testing.expect(decoded.style_bits & protocol.text_v1.style.bold != 0);
    try std.testing.expectEqual(protocol.TextColorKind.rgb, decoded.foreground.kind);
    try std.testing.expectEqual(@as(u32, 0x112233), decoded.foreground.value);
    try std.testing.expectEqual(protocol.TextColorKind.indexed, decoded.background.kind);
    try std.testing.expectEqual(@as(u32, 4), decoded.background.value);
    try std.testing.expectEqual(@as(u32, 7), decoded.link_id);
    try std.testing.expect(referenced[7]);
}

test "rich row reuses identical validated attributes without aliasing scalars" {
    const columns: u16 = 2;
    var payload: [protocol.text_v1.row_header_bytes + 2 * protocol.text_v1.cell_header_bytes + 8]u8 = @splat(0);
    encodeU16(payload[2..4], 2);
    var at: usize = protocol.text_v1.row_header_bytes;
    const first = payload[at..][0..protocol.text_v1.cell_header_bytes];
    first[0] = 1;
    first[1] = 1;
    first[2] = 1;
    encodeU32(first[31..35], 7);
    at += protocol.text_v1.cell_header_bytes;
    encodeU32(payload[at..][0..4], 'A');
    at += 4;
    const second = payload[at..][0..protocol.text_v1.cell_header_bytes];
    second[0] = 1;
    @memcpy(second[1..], first[1..]);
    at += protocol.text_v1.cell_header_bytes;
    encodeU32(payload[at..][0..4], 'B');
    at += 4;
    try std.testing.expectEqual(payload.len, at);

    var referenced: [protocol.text_v1.maximum_hyperlinks + 1]bool = @splat(false);
    const row = try decodeRow(std.testing.allocator, columns, &payload, &referenced);
    defer deinitRows(std.testing.allocator, &.{row});
    try std.testing.expectEqualSlices(u32, &.{'A'}, row.cells[0].scalars);
    try std.testing.expectEqualSlices(u32, &.{'B'}, row.cells[1].scalars);
    try std.testing.expectEqual(row.cells[0].foreground, row.cells[1].foreground);
    try std.testing.expectEqual(row.cells[0].link_id, row.cells[1].link_id);
    try std.testing.expect(referenced[7]);
}

test "rich row repeated attributes cannot hide continuation scalars" {
    const columns: u16 = 2;
    var payload: [protocol.text_v1.row_header_bytes + 2 * protocol.text_v1.cell_header_bytes + 4]u8 = @splat(0);
    encodeU16(payload[2..4], 2);
    var at: usize = protocol.text_v1.row_header_bytes;
    const first = payload[at..][0..protocol.text_v1.cell_header_bytes];
    first[0] = 0;
    first[1] = 2;
    first[2] = 1;
    first[3] = 1;
    at += protocol.text_v1.cell_header_bytes;
    const second = payload[at..][0..protocol.text_v1.cell_header_bytes];
    second[0] = 1;
    @memcpy(second[1..], first[1..]);
    at += protocol.text_v1.cell_header_bytes;
    encodeU32(payload[at..][0..4], 'X');

    var referenced: [protocol.text_v1.maximum_hyperlinks + 1]bool = @splat(false);
    try std.testing.expectError(
        error.InvalidSnapshot,
        decodeRow(std.testing.allocator, columns, &payload, &referenced),
    );
}

test "rich hyperlink preserves arbitrary URI bytes exactly" {
    var payload: [protocol.text_v1.hyperlink_header_bytes + 4]u8 = undefined;
    encodeU32(payload[0..4], 2);
    encodeU16(payload[4..6], 4);
    payload[6] = 'A';
    payload[7] = 0;
    payload[8] = 0xff;
    payload[9] = 'Z';
    var referenced: [protocol.text_v1.maximum_hyperlinks + 1]bool = @splat(false);
    var resolved: [protocol.text_v1.maximum_hyperlinks + 1]bool = @splat(false);
    referenced[2] = true;
    const link = try decodeHyperlink(std.testing.allocator, &payload, &referenced, &resolved);
    defer std.testing.allocator.free(link.uri_bytes);
    try std.testing.expectEqualSlices(u8, &.{ 'A', 0, 0xff, 'Z' }, link.uri_bytes);
    try std.testing.expect(resolved[2]);
}

fn testRowPayload() [protocol.text_v1.row_header_bytes + protocol.text_v1.cell_header_bytes + 8]u8 {
    var bytes: [protocol.text_v1.row_header_bytes + protocol.text_v1.cell_header_bytes + 8]u8 = @splat(0);
    encodeU16(bytes[2..4], 1);
    bytes[4] = 2;
    bytes[5] = 1;
    bytes[6] = 1;
    encodeU32(bytes[4 + 31 ..][0..4], 7);
    encodeU32(bytes[bytes.len - 8 ..][0..4], 'e');
    encodeU32(bytes[bytes.len - 4 ..][0..4], 0x0301);
    return bytes;
}

fn testOwnedRowAllocation(allocator: std.mem.Allocator) !void {
    const bytes = testRowPayload();
    var referenced: [protocol.text_v1.maximum_hyperlinks + 1]bool = @splat(false);
    const row = decodeRow(allocator, 1, &bytes, &referenced) catch |err| {
        try std.testing.expect(!referenced[7]);
        return err;
    };
    defer deinitRows(allocator, &.{row});
    try std.testing.expect(referenced[7]);
    try std.testing.expectEqualSlices(u32, &.{ 'e', 0x0301 }, row.cells[0].scalars);
}

fn testOwnedHyperlinkAllocation(allocator: std.mem.Allocator) !void {
    const bytes = [_]u8{ 0, 0, 0, 2, 0, 4, 'A', 0, 0xff, 'Z' };
    var referenced: [protocol.text_v1.maximum_hyperlinks + 1]bool = @splat(false);
    var resolved: [protocol.text_v1.maximum_hyperlinks + 1]bool = @splat(false);
    referenced[2] = true;
    const link = decodeHyperlink(allocator, &bytes, &referenced, &resolved) catch |err| {
        try std.testing.expect(!resolved[2]);
        return err;
    };
    defer allocator.free(link.uri_bytes);
    try std.testing.expect(resolved[2]);
    try std.testing.expectEqualSlices(u8, bytes[6..], link.uri_bytes);
}

test "row and hyperlink allocation failure preserves bookkeeping and owns no partial state" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testOwnedRowAllocation, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testOwnedHyperlinkAllocation, .{});
}

test "malformed row shape is rejected before allocation and reference mutation" {
    var storage: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var referenced: [protocol.text_v1.maximum_hyperlinks + 1]bool = @splat(false);
    const short = [_]u8{ 0, 0, 0, 40 };
    try std.testing.expectError(error.InvalidSnapshot, decodeRow(fixed.allocator(), 40, &short, &referenced));
    var padded: [
        protocol.text_v1.row_header_bytes + protocol.text_v1.cell_header_bytes +
            (protocol.text_v1.maximum_cell_scalars + 1) * 4
    ]u8 = @splat(0);
    encodeU16(padded[2..4], 1);
    try std.testing.expectError(error.InvalidSnapshot, decodeRow(fixed.allocator(), 1, &padded, &referenced));
    for (referenced) |bit| try std.testing.expect(!bit);
}

test "late malformed scalar does not commit a row reference" {
    var bytes = testRowPayload();
    encodeU32(bytes[bytes.len - 4 ..][0..4], 0xd800);
    var referenced: [protocol.text_v1.maximum_hyperlinks + 1]bool = @splat(false);
    try std.testing.expectError(error.InvalidSnapshot, decodeRow(std.testing.allocator, 1, &bytes, &referenced));
    try std.testing.expect(!referenced[7]);
}

test "empty viewport retains an empty graphics manifest and empty row grammar" {
    var payload: [protocol.graphics_v2.manifest_header_bytes]u8 = undefined;
    protocol.encodeSnapshotGraphicsHeader(&payload, .{
        .generation = 0,
        .content_generation = 0,
        .cell_pixel_width = 1,
        .cell_pixel_height = 1,
        .image_count = 0,
        .placement_count = 0,
    });
    var graphics = try decodeGraphics(std.testing.allocator, .{ .rows = 0, .columns = 0 }, &payload);
    defer graphics.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), graphics.images.len);
    try std.testing.expectEqual(@as(usize, 0), graphics.placements.len);
    var referenced: [protocol.text_v1.maximum_hyperlinks + 1]bool = @splat(false);
    const row = try decodeRow(std.testing.allocator, 0, &.{ 0, 0, 0, 0 }, &referenced);
    defer deinitRows(std.testing.allocator, &.{row});
    try std.testing.expectEqual(@as(usize, 0), row.cells.len);
}
