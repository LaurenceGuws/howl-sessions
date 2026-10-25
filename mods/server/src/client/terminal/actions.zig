//! Canonical client-side Instance operations.
//!
//! These functions serialize existing Howl Instance requests only. Terminal input
//! encoding remains owned by howl-vt on the Instance side.

const std = @import("std");
const protocol = @import("server_protocol").terminal;
const client = @import("terminal_owner");

/// Reports local validation, transport, framing, and server action failures.
pub const Error = client.Error || std.mem.Allocator.Error || protocol.PayloadError || error{
    InvalidText,
    InvalidResize,
    RequestTooLarge,
    UnexpectedFrame,
    ServerRejected,
    NotGeometryLeader,
};

/// Sends one validated committed UTF-8 text input event.
pub fn committedText(connection: *client.Connection, bytes: []const u8) Error!void {
    if (bytes.len == 0 or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidText;
    try sendBytesInput(connection, .bytes, bytes);
    try expectOk(connection, .input);
}

/// Sends one nonempty paste payload for terminal-side paste semantics.
pub fn paste(connection: *client.Connection, bytes: []const u8) Error!void {
    if (bytes.len == 0) return error.InvalidText;
    try sendBytesInput(connection, .paste, bytes);
    try expectOk(connection, .input);
}

/// Sends one named physical-key transition with exact modifier bits.
pub fn namedKey(
    connection: *client.Connection,
    key: protocol.InputKeyName,
    action: protocol.InputKeyAction,
    modifiers: u8,
) Error!void {
    var body_storage: [protocol.typed_input.key_header_bytes]u8 = undefined;
    const body = protocol.encodeKeyInput(&body_storage, .{
        .kind = .named,
        .key_value = @backingInt(key),
        .action = action,
        .modifiers = modifiers,
    }) catch |failure| switch (failure) {
        // zig-audit: acknowledge unreachable
        // reason: body_storage is exactly protocol.typed_input.key_header_bytes, the encoder's required fixed size.
        error.OutputTooSmall => unreachable,
        else => |err| return err,
    };
    var payload: [1 + protocol.typed_input.key_header_bytes]u8 = undefined;
    payload[0] = @backingInt(protocol.InputKind.key);
    @memcpy(payload[1 .. 1 + body.len], body);
    try connection.send(.input, payload[0 .. 1 + body.len]);
    try expectOk(connection, .input);
}

/// Sends one Unicode physical-key transition with exact modifier bits.
pub fn unicodeKey(
    connection: *client.Connection,
    scalar: u32,
    action: protocol.InputKeyAction,
    modifiers: u8,
) Error!void {
    var body_storage: [protocol.typed_input.key_header_bytes]u8 = undefined;
    const body = protocol.encodeKeyInput(&body_storage, .{
        .kind = .unicode,
        .key_value = scalar,
        .action = action,
        .modifiers = modifiers,
    }) catch |failure| switch (failure) {
        // zig-audit: acknowledge unreachable
        // reason: body_storage is exactly protocol.typed_input.key_header_bytes, the encoder's required fixed size.
        error.OutputTooSmall => unreachable,
        else => |err| return err,
    };
    var payload: [1 + protocol.typed_input.key_header_bytes]u8 = undefined;
    payload[0] = @backingInt(protocol.InputKind.key);
    @memcpy(payload[1 .. 1 + body.len], body);
    try connection.send(.input, payload[0 .. 1 + body.len]);
    try expectOk(connection, .input);
}

/// Sends one canonical terminal mouse input event.
pub fn mouse(connection: *client.Connection, value: protocol.MouseInput) Error!void {
    var body: [protocol.typed_input.mouse_bytes]u8 = undefined;
    try protocol.encodeMouseInput(&body, value);
    var payload: [1 + protocol.typed_input.mouse_bytes]u8 = undefined;
    payload[0] = @backingInt(protocol.InputKind.mouse);
    @memcpy(payload[1..], &body);
    try connection.send(.input, &payload);
    try expectOk(connection, .input);
}

/// Sends one canonical terminal focus transition.
pub fn focus(connection: *client.Connection, value: protocol.InputFocus) Error!void {
    var body: [protocol.typed_input.focus_bytes]u8 = undefined;
    protocol.encodeFocusInput(&body, value);
    var payload: [1 + protocol.typed_input.focus_bytes]u8 = undefined;
    payload[0] = @backingInt(protocol.InputKind.focus);
    @memcpy(payload[1..], &body);
    try connection.send(.input, &payload);
    try expectOk(connection, .input);
}

/// Acquires geometry authority and applies rows/columns with unchanged cell pixels.
pub fn resize(connection: *client.Connection, rows: u16, columns: u16) Error!void {
    return resizeGeometry(connection, .{ .rows = rows, .columns = columns });
}

/// Explicitly acquires geometry authority, then applies cell/pixel dimensions.
pub fn resizeGeometry(connection: *client.Connection, geometry: protocol.Resize) Error!void {
    if (geometry.rows == 0 or geometry.columns == 0 or
        (geometry.cell_pixel_width == 0) != (geometry.cell_pixel_height == 0))
        return error.InvalidResize;
    var leader_payload: [protocol.payload_bytes.assign_leader]u8 = undefined;
    protocol.encodeAssignLeader(&leader_payload, .{ .client_id = connection.identity().client_id });
    try connection.send(.assign_leader, &leader_payload);
    try expectOk(connection, .assign_leader);
    try resizeGeometryOwned(connection, geometry);
}

/// Resizes only while this exact connection already owns geometry authority.
/// Unlike `resize`, this never assigns or steals leadership first.
pub fn resizeOwned(connection: *client.Connection, rows: u16, columns: u16) Error!void {
    return resizeGeometryOwned(connection, .{ .rows = rows, .columns = columns });
}

/// Applies v8 cell/pixel geometry without acquiring or stealing leadership.
pub fn resizeGeometryOwned(connection: *client.Connection, geometry: protocol.Resize) Error!void {
    if (geometry.rows == 0 or geometry.columns == 0 or
        (geometry.cell_pixel_width == 0) != (geometry.cell_pixel_height == 0))
        return error.InvalidResize;
    var resize_payload: [protocol.payload_bytes.resize]u8 = undefined;
    protocol.encodeResize(&resize_payload, geometry);
    try connection.send(.resize, &resize_payload);
    try expectOk(connection, .resize);
}

/// Sends one process-group signal request to the attached Instance.
pub fn signal(connection: *client.Connection, value: protocol.Signal) Error!void {
    var payload: [protocol.payload_bytes.signal]u8 = undefined;
    protocol.encodeSignal(&payload, value);
    try connection.send(.signal, &payload);
    try expectOk(connection, .signal);
}

fn sendBytesInput(
    connection: *client.Connection,
    kind: protocol.InputKind,
    bytes: []const u8,
) Error!void {
    if (bytes.len + 1 > protocol.maximum_request_payload_bytes) return error.RequestTooLarge;
    const payload = try client.ownerAllocator(connection).alloc(u8, bytes.len + 1);
    defer client.ownerAllocator(connection).free(payload);
    payload[0] = @backingInt(kind);
    @memcpy(payload[1..], bytes);
    try connection.send(.input, payload);
}

fn expectOk(connection: *client.Connection, expected: protocol.Kind) Error!void {
    var completed = false;
    defer if (!completed) client.retire(connection);
    var frame = try connection.receive();
    defer frame.deinit();
    if (frame.kind != .result) return error.UnexpectedFrame;
    const result = try protocol.decodeResult(frame.payload);
    if (result.request_kind != expected) return error.UnexpectedFrame;
    completed = true;
    try checkResult(expected, result);
}

// Authority loss is a completed, nonfatal resize response, not a broken stream.
// Preserve that distinction without weakening other action acknowledgements.
fn checkResult(expected: protocol.Kind, result: protocol.Result) Error!void {
    if (result.request_kind != expected) return error.UnexpectedFrame;
    if (expected == .resize and result.code == .not_leader) return error.NotGeometryLeader;
    if (result.code != .ok) return error.ServerRejected;
}

test "resize distinguishes authority loss from rejection and malformed acknowledgements" {
    try checkResult(.resize, .{ .request_kind = .resize, .code = .ok });
    try std.testing.expectError(error.NotGeometryLeader, checkResult(.resize, .{ .request_kind = .resize, .code = .not_leader }));
    try std.testing.expectError(error.ServerRejected, checkResult(.resize, .{ .request_kind = .resize, .code = .rejected }));
    try std.testing.expectError(error.UnexpectedFrame, checkResult(.resize, .{ .request_kind = .input, .code = .not_leader }));
    try std.testing.expectError(error.ServerRejected, checkResult(.input, .{ .request_kind = .input, .code = .not_leader }));
}
