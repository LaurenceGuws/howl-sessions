//! Complete bounded terminal-property snapshot. All slices borrow their packet.
//! This is wire vocabulary, not a renderer, shell policy, or parallel VT owner.
const std = @import("std");

/// Number of independently length-bounded string fields.
pub const field_count: usize = 6;
/// Maximum retained bytes in one canonical property field.
pub const maximum_field_bytes: usize = 1024;
/// Fixed encoded prefix before the six concatenated strings.
pub const header_bytes: usize = 36;
/// Complete property packet ceiling.
pub const maximum_bytes: usize = header_bytes + field_count * maximum_field_bytes;
/// Malformed state/packet or insufficient caller-owned output.
pub const Error = error{ InvalidProperties, OutputTooSmall };
/// Whether reported directory bytes represent a URI or a path.
pub const DirectoryKind = enum(u8) { uri = 1, path = 2 };
/// Retained OSC 9;4 state; values match its numeric command states.
pub const ProgressKind = enum(u8) { none = 0, normal = 1, failure = 2, indeterminate = 3, paused = 4 };
/// Copies a normalized task indicator without scheduling policy.
pub const Progress = struct { kind: ProgressKind = .none, value: u8 = 0 };
/// Borrows exact directory bytes and their canonical interpretation.
pub const Directory = struct { kind: DirectoryKind, value: []const u8 };
/// Borrows optional shell identity with the reported integration version.
pub const Shell = struct { version: u32, name: ?[]const u8 = null };
/// Copies ordered shell-mark identity, optional exit status and metadata.
pub const Mark = struct { generation: u64 = 0, kind: u8 = 0, status: ?i32 = null, metadata: []const u8 = "" };

/// Optional strings distinguish absence from an explicitly empty report. String
/// bytes are preserved, including invalid UTF-8; hosts must safely project text.
pub const View = struct {
    title: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    directory: ?Directory = null,
    remote_host: ?[]const u8 = null,
    shell: ?Shell = null,
    mark: Mark = .{},
    progress: Progress = .{},
};

fn fields(value: View) [field_count]?[]const u8 {
    return .{ value.title, value.icon, if (value.directory) |v| v.value else null, value.remote_host, if (value.shell) |v| v.name else null, value.mark.metadata };
}

/// Validates all scalar/byte bounds before returning the exact packet size.
pub fn encodedSize(value: View) Error!usize {
    if (value.progress.value > 100 or
        ((value.progress.kind == .none or value.progress.kind == .indeterminate) and value.progress.value != 0))
        return error.InvalidProperties;
    if (value.mark.kind == 0) {
        if (value.mark.generation != 0 or value.mark.status != null or value.mark.metadata.len != 0)
            return error.InvalidProperties;
    } else if (value.mark.kind < 'A' or value.mark.kind > 'D' or value.mark.generation == 0 or
        (value.mark.status != null and value.mark.kind != 'D'))
        return error.InvalidProperties;
    var size: usize = header_bytes;
    for (fields(value)) |maybe| if (maybe) |bytes| {
        if (bytes.len > maximum_field_bytes) return error.InvalidProperties;
        size += bytes.len;
    };
    return size;
}

/// Writes one canonical packet after validating the complete value and capacity.
pub fn encode(output: []u8, value: View) Error!usize {
    const size = try encodedSize(value);
    if (output.len < size) return error.OutputTooSmall;
    const bytes = output[0..size];
    @memset(bytes[0..header_bytes], 0);
    bytes[0] = 1;
    var flags: u8 = 0;
    const strings = fields(value);
    for (strings[0..5], 0..) |field, index| if (field != null) {
        const bit: u3 = @intCast(if (index == 4) 5 else index);
        flags |= @as(u8, 1) << bit;
    };
    if (value.shell != null) flags |= 1 << 4;
    if (value.mark.status != null) flags |= 1 << 6;
    bytes[1] = flags;
    bytes[2] = if (value.directory) |v| @backingInt(v.kind) else 0;
    bytes[3] = value.mark.kind;
    std.mem.writeInt(u32, bytes[4..8], if (value.shell) |v| v.version else 0, .big);
    std.mem.writeInt(u64, bytes[8..16], value.mark.generation, .big);
    std.mem.writeInt(i32, bytes[16..20], value.mark.status orelse 0, .big);
    bytes[20] = @backingInt(value.progress.kind);
    bytes[21] = value.progress.value;
    var offset: usize = header_bytes;
    for (strings, 0..) |field, index| {
        const data = field orelse "";
        std.mem.writeInt(u16, bytes[24 + index * 2 ..][0..2], @intCast(data.len), .big);
        @memcpy(bytes[offset..][0..data.len], data);
        offset += data.len;
    }
    std.debug.assert(offset == size);
    return size;
}

/// Validates one complete packet and borrows its exact property bytes.
pub fn decode(bytes: []const u8) Error!View {
    if (bytes.len < header_bytes or bytes.len > maximum_bytes or bytes[0] != 1 or
        bytes[1] & 0x80 != 0 or bytes[22] != 0 or bytes[23] != 0 or bytes[20] > 4)
        return error.InvalidProperties;
    const flags = bytes[1];
    var strings: [field_count]?[]const u8 = @splat(null);
    var offset: usize = header_bytes;
    for (&strings, 0..) |*field, index| {
        const count = std.mem.readInt(u16, bytes[24 + index * 2 ..][0..2], .big);
        if (count > maximum_field_bytes or count > bytes.len - offset) return error.InvalidProperties;
        const present = if (index == 5) true else flags & (@as(u8, 1) << @as(u3, @intCast(if (index == 4) 5 else index))) != 0;
        if (!present and count != 0) return error.InvalidProperties;
        field.* = if (present) bytes[offset..][0..count] else null;
        offset += count;
    }
    if (offset != bytes.len or (flags & (1 << 2) == 0 and bytes[2] != 0) or
        (flags & (1 << 4) == 0 and (flags & (1 << 5) != 0 or std.mem.readInt(u32, bytes[4..8], .big) != 0)) or
        (flags & (1 << 6) == 0 and std.mem.readInt(i32, bytes[16..20], .big) != 0))
        return error.InvalidProperties;
    const directory: ?Directory = if (strings[2]) |data| .{
        .kind = switch (bytes[2]) {
            1 => .uri,
            2 => .path,
            else => return error.InvalidProperties,
        },
        .value = data,
    } else null;
    const value = View{
        .title = strings[0],
        .icon = strings[1],
        .directory = directory,
        .remote_host = strings[3],
        .shell = if (flags & (1 << 4) != 0) .{ .version = std.mem.readInt(u32, bytes[4..8], .big), .name = strings[4] } else null,
        .mark = .{ .generation = std.mem.readInt(u64, bytes[8..16], .big), .kind = bytes[3], .status = if (flags & (1 << 6) != 0) std.mem.readInt(i32, bytes[16..20], .big) else null, .metadata = strings[5].? },
        .progress = .{ .kind = @fromBackingInt(@intCast(bytes[20])), .value = bytes[21] },
    };
    if (try encodedSize(value) != bytes.len) return error.InvalidProperties;
    return value;
}

test "properties packet retains all typed state and exact optional bytes" {
    const input = View{ .title = "héllo", .icon = "", .directory = .{ .kind = .uri, .value = "file:///home/test" }, .remote_host = "test@example", .shell = .{ .version = 7, .name = "bash" }, .mark = .{ .kind = 'D', .generation = 42, .status = -1, .metadata = "id=7" }, .progress = .{ .kind = .normal, .value = 63 } };
    var bytes: [maximum_bytes]u8 = undefined;
    const used = try encode(&bytes, input);
    try std.testing.expectEqualDeep(input, try decode(bytes[0..used]));
    try std.testing.expectEqual(@as(u8, 1), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x7f), bytes[1]);
    try std.testing.expectError(error.OutputTooSmall, encode(bytes[0 .. used - 1], input));
    const empty_used = try encode(&bytes, .{});
    try std.testing.expectEqual(header_bytes, empty_used);
    try std.testing.expectEqualDeep(View{}, try decode(bytes[0..empty_used]));
}

test "properties packet refuses malformed framing lengths and invalid state" {
    var bytes: [maximum_bytes + 1]u8 = @splat(0);
    const used = try encode(&bytes, .{ .title = "x" });
    const good = bytes;
    for (0..used) |size| try std.testing.expectError(error.InvalidProperties, decode(bytes[0..size]));
    for ([_]usize{ 0, 1, 2, 3, 4, 8, 16, 20, 21, 22, 23, 24, 25 }) |index| {
        bytes = good;
        bytes[index] = 255;
        try std.testing.expectError(error.InvalidProperties, decode(bytes[0..used]));
    }
    bytes = good;
    try std.testing.expectError(error.InvalidProperties, decode(bytes[0 .. used + 1]));
    try std.testing.expectError(error.InvalidProperties, decode(&bytes));
    try std.testing.expectError(error.InvalidProperties, encodedSize(.{ .title = bytes[0 .. maximum_field_bytes + 1] }));
}

test "properties packet preserves non-UTF8 bytes rather than silently rewriting title" {
    var bytes: [128]u8 = undefined;
    const used = try encode(&bytes, .{ .title = &.{ 0xff, 0, 0x1b } });
    const value = try decode(bytes[0..used]);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0, 0x1b }, value.title.?);
    try std.testing.expect(value.icon == null);
}
