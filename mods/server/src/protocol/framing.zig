//! One Server frame envelope; phase-specific tag sets reject cross-phase input.
const std = @import("std");

/// Complete Server wire compatibility boundary.
pub const version: u8 = 2;
/// Exact shared Server envelope width.
pub const header_bytes: usize = 12;
const magic = [4]u8{ 'S', 'R', 'V', 'R' };

/// Framing failures rejected before payload allocation.
pub const Error = error{
    InvalidMagic,
    UnsupportedFramingVersion,
    InvalidReservedBits,
    UnknownKind,
    PayloadTooLarge,
};

/// Header typed to one permitted connection phase.
pub fn Header(comptime Kind: type) type {
    return struct { kind: Kind, payload_len: u32 };
}

/// Writes one exact Server envelope under its phase payload bound.
pub fn encode(comptime Kind: type, comptime maximum: u32, output: *[header_bytes]u8, value: Header(Kind)) error{PayloadTooLarge}!void {
    if (value.payload_len > maximum) return error.PayloadTooLarge;
    output.* = @splat(0);
    @memcpy(output[0..4], &magic);
    output[4] = version;
    output[5] = @backingInt(value.kind);
    std.mem.writeInt(u32, output[8..12], value.payload_len, .big);
}

/// Validates magic, version, reserved bytes, phase tag and payload bound.
pub fn decode(comptime Kind: type, comptime maximum: u32, input: *const [header_bytes]u8) Error!Header(Kind) {
    if (!std.mem.eql(u8, input[0..4], &magic)) return error.InvalidMagic;
    if (input[4] != version) return error.UnsupportedFramingVersion;
    if (input[6] != 0 or input[7] != 0) return error.InvalidReservedBits;
    const kind = kind: {
        inline for (@typeInfo(Kind).@"enum".field_values) |value| {
            if (input[5] == value) break :kind @as(Kind, @fromBackingInt(@intCast(value)));
        }
        return error.UnknownKind;
    };
    const payload_len = std.mem.readInt(u32, input[8..12], .big);
    if (payload_len > maximum) return error.PayloadTooLarge;
    return .{ .kind = kind, .payload_len = payload_len };
}
