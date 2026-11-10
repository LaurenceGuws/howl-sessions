const std = @import("std");
const protocol = @import("server_client").terminal.protocol;
const client = @import("server_client").terminal;

/// Reports invalid command-line key, modifier, focus or signal vocabulary.
pub const Error = error{
    InvalidKey,
    InvalidKeyAction,
    InvalidModifiers,
    InvalidFocus,
    InvalidSignal,
};

/// Machine-readable confirmation of one successful semantic action.
pub const Receipt = struct {
    schema: []const u8 = "howl.action/v1",
    operation: []const u8,
    result: []const u8 = "ok",
};

/// Writes one action receipt followed by a newline; forwards output failures.
pub fn emitReceipt(writer: *std.Io.Writer, operation: []const u8) !void {
    try std.json.Stringify.value(Receipt{ .operation = operation }, .{}, writer);
    try writer.writeByte('\n');
}

/// Sends committed text through the shared client action owner.
pub const committedText = client.actions.committedText;
/// Sends a paste through the shared client action owner.
pub const paste = client.actions.paste;
/// Sends a named physical key through the shared client action owner.
pub const namedKey = client.actions.namedKey;
/// Sends a Unicode physical key through the shared client action owner.
pub const unicodeKey = client.actions.unicodeKey;
/// Sends an explicit focus transition through the shared client action owner.
pub const focus = client.actions.focus;
/// Requests explicit terminal geometry through the shared client action owner.
pub const resize = client.actions.resize;
/// Requests a child signal through the shared client action owner.
pub const signal = client.actions.signal;

/// A named protocol key or validated Unicode scalar.
pub const PhysicalKey = union(enum) {
    named: protocol.InputKeyName,
    unicode: u32,
};

/// Parses a protocol key name or U+ hexadecimal Unicode scalar.
pub fn parseKey(text: []const u8) Error!PhysicalKey {
    if (std.mem.startsWith(u8, text, "U+") or std.mem.startsWith(u8, text, "u+")) {
        if (text.len <= 2 or text.len > 8) return error.InvalidKey;
        const scalar = std.fmt.parseInt(u32, text[2..], 16) catch return error.InvalidKey;
        if (scalar > 0x10ffff or scalar >= 0xd800 and scalar <= 0xdfff) return error.InvalidKey;
        return .{ .unicode = scalar };
    }
    if (text.len == 0 or text.len > 31) return error.InvalidKey;
    var normalized: [32]u8 = undefined;
    for (text, 0..) |byte, index| normalized[index] = if (byte == '-') '_' else byte;
    return .{ .named = std.meta.stringToEnum(protocol.InputKeyName, normalized[0..text.len]) orelse
        return error.InvalidKey };
}

/// Parses only the frozen protocol key-action vocabulary.
pub fn parseKeyAction(text: []const u8) Error!protocol.InputKeyAction {
    return std.meta.stringToEnum(protocol.InputKeyAction, text) orelse error.InvalidKeyAction;
}

/// Parses unique + separated modifier names into protocol bits.
pub fn parseModifiers(text: []const u8) Error!u8 {
    if (text.len == 0) return 0;
    var result: u8 = 0;
    var parts = std.mem.splitScalar(u8, text, '+');
    while (parts.next()) |part| {
        const bit: u8 = if (std.mem.eql(u8, part, "shift"))
            protocol.typed_input.modifiers.shift
        else if (std.mem.eql(u8, part, "alt"))
            protocol.typed_input.modifiers.alt
        else if (std.mem.eql(u8, part, "ctrl") or std.mem.eql(u8, part, "control"))
            protocol.typed_input.modifiers.control
        else if (std.mem.eql(u8, part, "super"))
            protocol.typed_input.modifiers.super
        else if (std.mem.eql(u8, part, "hyper"))
            protocol.typed_input.modifiers.hyper
        else if (std.mem.eql(u8, part, "meta"))
            protocol.typed_input.modifiers.meta
        else if (std.mem.eql(u8, part, "caps-lock") or std.mem.eql(u8, part, "caps_lock"))
            protocol.typed_input.modifiers.caps_lock
        else if (std.mem.eql(u8, part, "num-lock") or std.mem.eql(u8, part, "num_lock"))
            protocol.typed_input.modifiers.num_lock
        else
            return error.InvalidModifiers;
        if (result & bit != 0) return error.InvalidModifiers;
        result |= bit;
    }
    return result;
}

/// Parses in or out as an explicit focus transition.
pub fn parseFocus(text: []const u8) Error!protocol.InputFocus {
    if (std.mem.eql(u8, text, "in")) return .in;
    if (std.mem.eql(u8, text, "out")) return .out;
    return error.InvalidFocus;
}

/// Parses only the supported child signal names.
pub fn parseSignal(text: []const u8) Error!protocol.Signal {
    if (std.mem.eql(u8, text, "hangup")) return .hangup;
    if (std.mem.eql(u8, text, "interrupt")) return .interrupt;
    if (std.mem.eql(u8, text, "resize-notify") or std.mem.eql(u8, text, "resize_notify")) return .resize_notify;
    if (std.mem.eql(u8, text, "kill")) return .kill;
    if (std.mem.eql(u8, text, "terminate")) return .terminate;
    return error.InvalidSignal;
}

test "CLI key and modifier names map only to frozen protocol vocabulary" {
    try std.testing.expectEqual(protocol.InputKeyName.page_up, (try parseKey("page-up")).named);
    try std.testing.expectEqual(protocol.InputKeyName.keypad_enter, (try parseKey("keypad_enter")).named);
    try std.testing.expectEqual(@as(u32, 'a'), (try parseKey("U+0061")).unicode);
    try std.testing.expectError(error.InvalidKey, parseKey("U+D800"));
    try std.testing.expectError(error.InvalidKey, parseKey("c"));
    try std.testing.expectEqual(
        protocol.typed_input.modifiers.control | protocol.typed_input.modifiers.shift,
        try parseModifiers("ctrl+shift"),
    );
    try std.testing.expectError(error.InvalidModifiers, parseModifiers("ctrl+ctrl"));
    try std.testing.expectError(error.InvalidModifiers, parseModifiers("banana"));
}
