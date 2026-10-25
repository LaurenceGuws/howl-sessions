//! Optional Server-client-owned native semantic projection and named operations.
//! C header composition imports VT schemas only, never a live parser/Instance/renderer.
const std = @import("std");
const client = @import("server_client");
const terminal = client.terminal;
const protocol = terminal.protocol;
const owner = @import("terminal_owner");
const vt_codec = @import("howl_vt_codec");
/// Exact owned C declarations shared with the native artifact.
pub const c = @import("native_abi_types");
/// Native snapshot queries and independently owned text/cache capabilities.
pub const queries = @import("queries.zig");
/// Server authority alongside VT-owned native request facts.
pub const RequestInfo = c.hsc_request_info;
/// Native arguments and coherent client-response failures.
pub const Error = terminal.consequences.Error || terminal.state.Error || queries.Error || error{InvalidArgument};
comptime {
    std.debug.assert(c.HSC_MAX_CLIPBOARD_REPLY_BYTES == protocol.maximum_request_payload_bytes - protocol.payload_bytes.consequence_reply_header);
    std.debug.assert(c.HSC_MAX_POINTER_REPLY_BYTES == protocol.consequence_small_payload_bytes);
    std.debug.assert(c.HSC_MAX_ICON_TITLE_REPLY_BYTES == protocol.consequence_small_payload_bytes);
}

/// Owns immutable transported payload and its copied native descriptor.
pub const RequestSnapshot = struct {
    value: terminal.consequences.Snapshot,
    info: RequestInfo,
    /// Frees the independent snapshot after every payload borrow ends.
    pub fn deinit(self: *RequestSnapshot) void {
        self.value.deinit();
        self.* = undefined;
    }
};

/// Validates and copies terminal facts; encoded Server metadata stays private.
pub fn describeRequest(snapshot: *const terminal.consequences.Snapshot, output: *RequestInfo) Error!void {
    output.* = std.mem.zeroes(RequestInfo);
    var validated: [protocol.payload_bytes.consequence_begin]u8 = undefined;
    try protocol.encodeConsequenceBegin(&validated, snapshot.begin);
    if (snapshot.payload.len != snapshot.begin.payload_len or snapshot.payload.len > c.HVT_MAX_REQUEST_PAYLOAD_BYTES) return error.InvalidSnapshot;
    const begin = snapshot.begin;
    const metadata = begin.metadata;
    output.authority_client_id = begin.authority_client_id;
    output.request.occurrence_id = begin.generation;
    output.request.terminal_revision = begin.terminal_revision;
    output.request.payload_len = begin.payload_len;
    output.request.reply_required = @intFromBool(begin.reply_required);
    switch (begin.kind) {
        .none => output.request.kind = c.HVT_REQUEST_NONE,
        .clipboard => {
            const family = std.enums.fromInt(protocol.ConsequenceClipboardProtocol, metadata[0]).?;
            const operation = std.enums.fromInt(protocol.ConsequenceClipboardKind, metadata[1]).?;
            switch (family) {
                .osc52 => {
                    const parsed = vt_codec.parseClipboardRequest(snapshot.payload) orelse return error.InvalidSnapshot;
                    if (parsed.selection.len != metadata[2] or !std.mem.eql(u8, parsed.selection, metadata[4..][0..metadata[2]])) return error.InvalidSnapshot;
                    const expected: protocol.ConsequenceClipboardKind = switch (parsed.kind) {
                        .set => .set,
                        .query => .query,
                    };
                    if (operation != expected) return error.InvalidSnapshot;
                },
                .kitty_5522 => if (operation != .packet or metadata[2] != 0 or begin.reply_required) return error.InvalidSnapshot,
            }
            output.request.kind = c.HVT_REQUEST_CLIPBOARD;
            output.request.data.clipboard.protocol = switch (std.enums.fromInt(protocol.ConsequenceClipboardProtocol, metadata[0]).?) {
                .osc52 => c.HVT_CLIPBOARD_OSC52,
                .kitty_5522 => c.HVT_CLIPBOARD_KITTY_5522,
            };
            output.request.data.clipboard.operation = switch (std.enums.fromInt(protocol.ConsequenceClipboardKind, metadata[1]).?) {
                .set => c.HVT_CLIPBOARD_SET,
                .query => c.HVT_CLIPBOARD_QUERY,
                .packet => c.HVT_CLIPBOARD_PACKET,
            };
            output.request.data.clipboard.selection_len = metadata[2];
        },
        .notification => {
            output.request.kind = c.HVT_REQUEST_NOTIFICATION;
            output.request.data.notification.kind = switch (std.enums.fromInt(protocol.ConsequenceNotificationKind, metadata[0]).?) {
                .message => c.HVT_NOTIFICATION_MESSAGE,
                .steal_focus => c.HVT_NOTIFICATION_STEAL_FOCUS,
                .request_attention => c.HVT_NOTIFICATION_REQUEST_ATTENTION,
            };
            output.request.data.notification.command = std.mem.readInt(u16, metadata[2..4], .big);
        },
        .pointer_shape => {
            const query = snapshot.payload.len != 0 and snapshot.payload[0] == '?';
            if (begin.reply_required != query) return error.InvalidSnapshot;
            output.request.kind = c.HVT_REQUEST_POINTER_SHAPE;
            output.request.reply_required = 0;
            output.request.data.pointer_shape.reset_generation = std.mem.readInt(u64, metadata[0..8], .big);
            output.request.data.pointer_shape.alternate_screen = metadata[8];
            output.request.data.pointer_shape.query_requested = @intFromBool(query);
        },
        .file_transfer => {
            output.request.kind = c.HVT_REQUEST_FILE_TRANSFER;
            output.request.data.file_transfer.protocol = switch (std.enums.fromInt(protocol.ConsequenceFileTransferProtocol, metadata[0]).?) {
                .iterm2_1337 => c.HVT_FILE_ITERM2_1337,
                .kitty_5113 => c.HVT_FILE_KITTY_5113,
            };
        },
        .drag_drop => {
            output.request.kind = c.HVT_REQUEST_DRAG_DROP;
            output.request.data.drag_drop.kind = switch (std.enums.fromInt(protocol.ConsequenceDragDropKind, metadata[0]).?) {
                .enable => c.HVT_DRAG_ENABLE,
                .disable => c.HVT_DRAG_DISABLE,
                .accept => c.HVT_DRAG_ACCEPT,
                .request => c.HVT_DRAG_REQUEST,
                .complete => c.HVT_DRAG_COMPLETE,
                .query => c.HVT_DRAG_QUERY,
                .continuation => c.HVT_DRAG_CONTINUATION,
                .unsupported => c.HVT_DRAG_UNSUPPORTED,
            };
            output.request.data.drag_drop.command = metadata[1];
            output.request.data.drag_drop.more = @intFromBool(metadata[2] & 1 != 0);
            output.request.data.drag_drop.remote = @intFromBool(metadata[2] & 2 != 0);
            output.request.data.drag_drop.has_client_id = @intFromBool(metadata[2] & 4 != 0);
            output.request.data.drag_drop.has_operation = @intFromBool(metadata[2] & 8 != 0);
            output.request.data.drag_drop.has_index = @intFromBool(metadata[2] & 16 != 0);
            output.request.data.drag_drop.client_id = std.mem.readInt(u32, metadata[4..8], .big);
            output.request.data.drag_drop.operation = std.mem.readInt(u32, metadata[8..12], .big);
            output.request.data.drag_drop.index = std.mem.readInt(u32, metadata[12..16], .big);
        },
        .container => {
            output.request.kind = c.HVT_REQUEST_CONTAINER;
            const request = std.enums.fromInt(protocol.ConsequenceContainerKind, metadata[0]).?;
            output.request.data.container.operation = switch (request) {
                .deiconify => c.HVT_CONTAINER_DEICONIFY,
                .iconify => c.HVT_CONTAINER_ICONIFY,
                .move => c.HVT_CONTAINER_MOVE,
                .resize_pixels => c.HVT_CONTAINER_RESIZE_PIXELS,
                .raise => c.HVT_CONTAINER_RAISE,
                .lower => c.HVT_CONTAINER_LOWER,
                .resize_rows => c.HVT_CONTAINER_RESIZE_ROWS,
                .resize_columns => c.HVT_CONTAINER_RESIZE_COLUMNS,
                .resize_cells => c.HVT_CONTAINER_RESIZE_CELLS,
                .report_state => c.HVT_CONTAINER_REPORT_STATE,
                .report_position => c.HVT_CONTAINER_REPORT_POSITION,
                .report_screen_cells => c.HVT_CONTAINER_REPORT_SCREEN_CELLS,
                .report_icon_title => c.HVT_CONTAINER_REPORT_ICON_TITLE,
            };
            const first = std.mem.readInt(u32, metadata[4..8], .big);
            const second = std.mem.readInt(u32, metadata[8..12], .big);
            switch (request) {
                .move => {
                    output.request.data.container.x = first;
                    output.request.data.container.y = second;
                },
                .resize_pixels => {
                    output.request.data.container.height = first;
                    output.request.data.container.width = second;
                },
                .resize_rows => output.request.data.container.rows = first,
                .resize_columns => output.request.data.container.columns = first,
                .resize_cells => {
                    output.request.data.container.rows = first;
                    output.request.data.container.columns = second;
                },
                else => {},
            }
        },
        .color_preference => output.request.kind = c.HVT_REQUEST_COLOR_PREFERENCE,
        .media_copy => {
            output.request.kind = c.HVT_REQUEST_MEDIA_COPY;
            output.request.data.media_copy.is_private = metadata[0];
            output.request.data.media_copy.parameter = std.mem.readInt(u16, metadata[2..4], .big);
        },
        .bell => output.request.kind = c.HVT_REQUEST_BELL,
        .legacy_control => {
            output.request.kind = c.HVT_REQUEST_LEGACY_CONTROL;
            output.request.data.legacy_control.operation = switch (std.enums.fromInt(protocol.ConsequenceLegacyControlKind, metadata[0]).?) {
                .tek_point_plot => c.HVT_LEGACY_TEK_POINT_PLOT,
                .tek_graph => c.HVT_LEGACY_TEK_GRAPH,
                .tek_incremental_plot => c.HVT_LEGACY_TEK_INCREMENTAL_PLOT,
                .tek_alpha => c.HVT_LEGACY_TEK_ALPHA,
                .tek_copy => c.HVT_LEGACY_TEK_COPY,
                .tek_special_point_plot => c.HVT_LEGACY_TEK_SPECIAL_POINT_PLOT,
                .tek_write_thru_short_dashed => c.HVT_LEGACY_TEK_WRITE_THRU_SHORT_DASHED,
                .hp_memory_lock => c.HVT_LEGACY_HP_MEMORY_LOCK,
            };
        },
        .dcs => {
            output.request.kind = c.HVT_REQUEST_DCS;
            output.request.data.dcs.operation = switch (std.enums.fromInt(protocol.ConsequenceDcsKind, metadata[0]).?) {
                .xtsettcap => c.HVT_DCS_XTSETTCAP,
                .decudk => c.HVT_DCS_DECUDK,
                .decaupss => c.HVT_DCS_DECAUPSS,
                .iterm_tmux_hook => c.HVT_DCS_ITERM_TMUX_HOOK,
                .iterm_ssh_hook => c.HVT_DCS_ITERM_SSH_HOOK,
                .iterm_tmux_wrap => c.HVT_DCS_ITERM_TMUX_WRAP,
                .kitty_remote_command => c.HVT_DCS_KITTY_REMOTE_COMMAND,
                .kitty_overlay_ready => c.HVT_DCS_KITTY_OVERLAY_READY,
                .kitty_result => c.HVT_DCS_KITTY_RESULT,
                .kitty_print => c.HVT_DCS_KITTY_PRINT,
                .kitty_echo => c.HVT_DCS_KITTY_ECHO,
                .kitty_ssh => c.HVT_DCS_KITTY_SSH,
                .kitty_askpass => c.HVT_DCS_KITTY_ASKPASS,
                .kitty_clone => c.HVT_DCS_KITTY_CLONE,
                .kitty_edit => c.HVT_DCS_KITTY_EDIT,
            };
        },
        .string_control => {
            output.request.kind = c.HVT_REQUEST_STRING_CONTROL;
            output.request.data.string_control.operation = switch (std.enums.fromInt(protocol.ConsequenceStringKind, metadata[0]).?) {
                .apc => c.HVT_STRING_APC,
                .pm => c.HVT_STRING_PM,
                .sos => c.HVT_STRING_SOS,
            };
        },
    }
}

/// Observes without claiming authority; malformed native semantic projection retires the stream.
pub fn observeRequests(connection: *terminal.Connection, allocator: std.mem.Allocator) Error!RequestSnapshot {
    var snapshot = try terminal.consequences.observe(connection, allocator);
    errdefer snapshot.deinit();
    var info: RequestInfo = undefined;
    describeRequest(&snapshot, &info) catch |failure| {
        owner.retire(connection);
        return failure;
    };
    return .{ .value = snapshot, .info = info };
}
/// Explicit authority claim belongs to this exact dedicated attachment.
pub const acquireRequests = terminal.consequences.acquire;
/// Acknowledges one exact consumable occurrence while holding Server authority.
pub const consumeRequest = terminal.consequences.consume;

fn replyBytes(connection: *terminal.Connection, id: u64, kind: terminal.consequences.ReplyKind, bytes: []const u8) Error!void {
    const maximum: usize = switch (kind) {
        .clipboard => c.HSC_MAX_CLIPBOARD_REPLY_BYTES,
        .pointer_shape => c.HSC_MAX_POINTER_REPLY_BYTES,
        .container_icon_title => c.HSC_MAX_ICON_TITLE_REPLY_BYTES,
        else => protocol.maximum_request_payload_bytes - protocol.payload_bytes.consequence_reply_header,
    };
    if (bytes.len > maximum) return error.PayloadTooLarge;
    try terminal.consequences.reply(connection, id, kind, bytes);
}
/// Sends a bounded clipboard value through the client-owned Server codec.
pub fn replyClipboard(connection: *terminal.Connection, id: u64, bytes: []const u8) Error!void {
    try replyBytes(connection, id, .clipboard, bytes);
}
/// Sends a bounded pointer value through the client-owned Server codec.
pub fn replyPointerShape(connection: *terminal.Connection, id: u64, bytes: []const u8) Error!void {
    try replyBytes(connection, id, .pointer_shape, bytes);
}
/// Validates native preference before any connection I/O.
pub fn replyColorPreference(connection: *terminal.Connection, id: u64, preference: u32) Error!void {
    const value: u8 = switch (preference) {
        c.HVT_COLOR_DARK => 1,
        c.HVT_COLOR_LIGHT => 2,
        else => return error.InvalidArgument,
    };
    try replyBytes(connection, id, .color_preference, &.{value});
}
/// Validates native window state before any connection I/O.
pub fn replyContainerState(connection: *terminal.Connection, id: u64, state: u32) Error!void {
    const value: u8 = switch (state) {
        c.HVT_CONTAINER_STATE_NORMAL => 1,
        c.HVT_CONTAINER_STATE_ICONIFIED => 2,
        else => return error.InvalidArgument,
    };
    try replyBytes(connection, id, .container_state, &.{value});
}
/// Encodes native position values inside the owned Server client.
pub fn replyContainerPosition(connection: *terminal.Connection, id: u64, x: u32, y: u32) Error!void {
    var body: [8]u8 = undefined;
    std.mem.writeInt(u32, body[0..4], x, .big);
    std.mem.writeInt(u32, body[4..8], y, .big);
    try replyBytes(connection, id, .container_position, &body);
}
/// Encodes native screen dimensions inside the owned Server client.
pub fn replyContainerScreenCells(connection: *terminal.Connection, id: u64, rows: u32, columns: u32) Error!void {
    var body: [8]u8 = undefined;
    std.mem.writeInt(u32, body[0..4], rows, .big);
    std.mem.writeInt(u32, body[4..8], columns, .big);
    try replyBytes(connection, id, .container_screen_cells, &body);
}
/// Sends a bounded title while preserving canonical Server reply identity checks.
pub fn replyContainerIconTitle(connection: *terminal.Connection, id: u64, bytes: []const u8) Error!void {
    try replyBytes(connection, id, .container_icon_title, bytes);
}
/// Declines when the host has no truthful container reply value.
pub fn declineContainer(connection: *terminal.Connection, id: u64) Error!void {
    try replyBytes(connection, id, .container_decline, &.{});
}

/// Copies stable native interaction facts from one coherent Server observation.
pub fn interaction(connection: *terminal.Connection) Error!c.hvt_interaction {
    const value = try terminal.state.get(connection);
    return .{
        .terminal_revision = value.terminal_revision,
        .flags = (if (value.alternate_scroll) @as(u32, c.HVT_INTERACTION_ALTERNATE_SCROLL) else 0) | (if (value.focus_reporting) @as(u32, c.HVT_INTERACTION_FOCUS_REPORTING) else 0),
        .mouse_tracking = switch (value.mouse_tracking) {
            .off => c.HVT_TRACK_OFF,
            .x10 => c.HVT_TRACK_X10,
            .normal => c.HVT_TRACK_NORMAL,
            .button_event => c.HVT_TRACK_BUTTON_EVENT,
            .any_event => c.HVT_TRACK_ANY_EVENT,
        },
        .mouse_protocol = switch (value.mouse_protocol) {
            .none => c.HVT_MOUSE_NONE_PROTOCOL,
            .utf8 => c.HVT_MOUSE_UTF8,
            .sgr => c.HVT_MOUSE_SGR,
            .sgr_pixel => c.HVT_MOUSE_SGR_PIXEL,
            .urxvt => c.HVT_MOUSE_URXVT,
        },
        .pointer_mode = value.pointer_mode,
    };
}

const Fixture = struct {
    connection: *terminal.Connection,
    peer: std.posix.fd_t,
    fn init() !Fixture {
        var pair: [2]std.posix.fd_t = undefined;
        const result = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair);
        if (std.posix.errno(result) != .SUCCESS) return error.TestSocketFailed;
        errdefer closeFd(pair[0]);
        errdefer closeFd(pair[1]);
        return .{ .connection = try owner.create(std.testing.allocator, .{ .fd = pair[0] }, .{ .server_id = 1, .session_id = 1, .instance_id = 1, .tree_revision = 1, .client_id = 7 }), .peer = pair[1] };
    }
    fn deinit(self: *Fixture) void {
        self.connection.deinit();
        closeFd(self.peer);
    }
    fn send(self: *Fixture, kind: protocol.Kind, payload: []const u8) !void {
        var header: [protocol.header_bytes]u8 = undefined;
        try protocol.encodeHeader(&header, .{ .kind = kind, .payload_len = @intCast(payload.len) });
        try writeAll(self.peer, &header);
        try writeAll(self.peer, payload);
    }
};
fn closeFd(fd: std.posix.fd_t) void {
    const result = std.posix.system.close(fd);
    std.debug.assert(std.posix.errno(result) == .SUCCESS or std.posix.errno(result) == .INTR);
}
fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const result = std.posix.system.write(fd, bytes[offset..].ptr, bytes.len - offset);
        switch (std.posix.errno(result)) {
            .SUCCESS => {
                const count = std.math.cast(usize, result) orelse return error.TestWriteFailed;
                if (count == 0 or count > bytes.len - offset) return error.TestWriteFailed;
                offset += count;
            },
            .INTR => continue,
            else => return error.TestWriteFailed,
        }
    }
}

test "native request decoder copies typed values and rejects contradictory payload metadata" {
    var metadata: [protocol.consequence_metadata_bytes]u8 = @splat(0);
    metadata[0] = @backingInt(protocol.ConsequenceContainerKind.resize_cells);
    std.mem.writeInt(u32, metadata[4..8], 23, .big);
    std.mem.writeInt(u32, metadata[8..12], 91, .big);
    var snapshot = terminal.consequences.Snapshot{ .allocator = std.testing.allocator, .payload = &.{}, .begin = .{ .terminal_revision = 8, .authority_client_id = 7, .generation = 12, .payload_len = 0, .kind = .container, .reply_required = false, .metadata = metadata } };
    var info: RequestInfo = undefined;
    try describeRequest(&snapshot, &info);
    try std.testing.expect(info.authority_client_id == 7 and info.request.occurrence_id == 12 and info.request.kind == c.HVT_REQUEST_CONTAINER and info.request.data.container.rows == 23 and info.request.data.container.columns == 91);
    var pointer_payload = [_]u8{'?'};
    snapshot.payload = &pointer_payload;
    snapshot.begin.kind = .pointer_shape;
    snapshot.begin.payload_len = 1;
    snapshot.begin.reply_required = true;
    snapshot.begin.metadata = @splat(0);
    try describeRequest(&snapshot, &info);
    try std.testing.expect(info.request.reply_required == 0 and info.request.data.pointer_shape.query_requested == 1);
    snapshot.begin.reply_required = false;
    try std.testing.expectError(error.InvalidSnapshot, describeRequest(&snapshot, &info));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(RequestInfo));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(RequestInfo, "authority_client_id"));
}

test "malformed interaction and mismatched request end retire the stream" {
    if (comptime @import("builtin").os.tag == .windows) return;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var bad: [protocol.payload_bytes.interaction_state_snapshot]u8 = @splat(0);
    bad[19] = 1;
    try fixture.send(.interaction_state_snapshot, &bad);
    try std.testing.expectError(error.InvalidPayload, interaction(fixture.connection));
    try std.testing.expectError(error.ConnectionRetired, fixture.connection.readinessFd());
    var request_fixture = try Fixture.init();
    defer request_fixture.deinit();
    var begin: [protocol.payload_bytes.consequence_begin]u8 = undefined;
    try protocol.encodeConsequenceBegin(&begin, .{ .terminal_revision = 8, .authority_client_id = 7, .generation = 12, .payload_len = 0, .kind = .bell, .reply_required = false, .metadata = @splat(0) });
    var end: [protocol.payload_bytes.consequence_end]u8 = undefined;
    protocol.encodeConsequenceEnd(&end, 13);
    try request_fixture.send(.consequence_begin, &begin);
    try request_fixture.send(.consequence_end, &end);
    try std.testing.expectError(error.InvalidSnapshot, observeRequests(request_fixture.connection, std.testing.allocator));
    try std.testing.expectError(error.ConnectionRetired, request_fixture.connection.readinessFd());
}

test "request allocation failure after begin retires unread response storage" {
    if (comptime @import("builtin").os.tag == .windows) return;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var metadata: [protocol.consequence_metadata_bytes]u8 = @splat(0);
    metadata[0] = @backingInt(protocol.ConsequenceNotificationKind.message);
    var begin: [protocol.payload_bytes.consequence_begin]u8 = undefined;
    try protocol.encodeConsequenceBegin(&begin, .{ .terminal_revision = 8, .authority_client_id = 7, .generation = 12, .payload_len = 1, .kind = .notification, .reply_required = false, .metadata = metadata });
    try fixture.send(.consequence_begin, &begin);
    try fixture.send(.consequence_data, "x");
    var end: [protocol.payload_bytes.consequence_end]u8 = undefined;
    protocol.encodeConsequenceEnd(&end, 12);
    try fixture.send(.consequence_end, &end);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, observeRequests(fixture.connection, failing.allocator()));
    try std.testing.expectError(error.ConnectionRetired, fixture.connection.readinessFd());
}

test "complete Server request rejection and native argument rejection preserve connection" {
    if (comptime @import("builtin").os.tag == .windows) return;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try std.testing.expectError(error.InvalidArgument, replyColorPreference(fixture.connection, 12, 0));
    var result: [protocol.payload_bytes.result]u8 = undefined;
    protocol.encodeResult(&result, .{ .request_kind = .consequence_observe, .code = .rejected });
    try fixture.send(.result, &result);
    try std.testing.expectError(error.ServerRejected, observeRequests(fixture.connection, std.testing.allocator));
    protocol.encodeResult(&result, .{ .request_kind = .assign_consequence_leader, .code = .ok });
    try fixture.send(.result, &result);
    try acquireRequests(fixture.connection);
    try std.testing.expect((try fixture.connection.readinessFd()) >= 0);
}

fn readAll(fd: std.posix.fd_t, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const result = std.posix.system.read(fd, bytes[offset..].ptr, bytes.len - offset);
        switch (std.posix.errno(result)) {
            .SUCCESS => {
                const count = std.math.cast(usize, result) orelse return error.TestReadFailed;
                if (count == 0 or count > bytes.len - offset) return error.TestReadFailed;
                offset += count;
            },
            .INTR => continue,
            else => return error.TestReadFailed,
        }
    }
}
test "named native screen reply encodes exact Server body privately" {
    if (comptime @import("builtin").os.tag == .windows) return;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var result: [protocol.payload_bytes.result]u8 = undefined;
    protocol.encodeResult(&result, .{ .request_kind = .consequence_reply, .code = .ok });
    try fixture.send(.result, &result);
    try replyContainerScreenCells(fixture.connection, 12, 23, 91);
    var header: [protocol.header_bytes]u8 = undefined;
    try readAll(fixture.peer, &header);
    const decoded = try protocol.decodeHeader(&header);
    try std.testing.expectEqual(protocol.Kind.consequence_reply, decoded.kind);
    var payload: [protocol.payload_bytes.consequence_reply_header + 8]u8 = undefined;
    try std.testing.expectEqual(payload.len, decoded.payload_len);
    try readAll(fixture.peer, &payload);
    const reply = try protocol.decodeConsequenceReply(&payload);
    try std.testing.expectEqual(@as(u64, 12), reply.generation);
    try std.testing.expectEqual(protocol.ConsequenceReplyKind.container_screen_cells, reply.kind);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 23, 0, 0, 0, 91 }, reply.body);
}

test "native request vocabulary covers every transported family without Server metadata escape" {
    const Case = struct { kind: protocol.ConsequenceKind, native_kind: u8 };
    const cases = [_]Case{
        .{ .kind = .none, .native_kind = c.HVT_REQUEST_NONE },
        .{ .kind = .clipboard, .native_kind = c.HVT_REQUEST_CLIPBOARD },
        .{ .kind = .notification, .native_kind = c.HVT_REQUEST_NOTIFICATION },
        .{ .kind = .pointer_shape, .native_kind = c.HVT_REQUEST_POINTER_SHAPE },
        .{ .kind = .file_transfer, .native_kind = c.HVT_REQUEST_FILE_TRANSFER },
        .{ .kind = .drag_drop, .native_kind = c.HVT_REQUEST_DRAG_DROP },
        .{ .kind = .container, .native_kind = c.HVT_REQUEST_CONTAINER },
        .{ .kind = .color_preference, .native_kind = c.HVT_REQUEST_COLOR_PREFERENCE },
        .{ .kind = .media_copy, .native_kind = c.HVT_REQUEST_MEDIA_COPY },
        .{ .kind = .bell, .native_kind = c.HVT_REQUEST_BELL },
        .{ .kind = .legacy_control, .native_kind = c.HVT_REQUEST_LEGACY_CONTROL },
        .{ .kind = .dcs, .native_kind = c.HVT_REQUEST_DCS },
        .{ .kind = .string_control, .native_kind = c.HVT_REQUEST_STRING_CONTROL },
    };
    for (cases) |case| {
        var metadata: [protocol.consequence_metadata_bytes]u8 = @splat(0);
        var payload_storage = [_]u8{ 'c', ';', '?' };
        var payload: []u8 = payload_storage[0..0];
        switch (case.kind) {
            .clipboard => {
                metadata[0] = @backingInt(protocol.ConsequenceClipboardProtocol.osc52);
                metadata[1] = @backingInt(protocol.ConsequenceClipboardKind.query);
                metadata[2] = 1;
                metadata[4] = 'c';
                payload = &payload_storage;
            },
            .notification => metadata[0] = @backingInt(protocol.ConsequenceNotificationKind.request_attention),
            .file_transfer => metadata[0] = @backingInt(protocol.ConsequenceFileTransferProtocol.kitty_5113),
            .drag_drop => metadata[0] = @backingInt(protocol.ConsequenceDragDropKind.query),
            .container => metadata[0] = @backingInt(protocol.ConsequenceContainerKind.deiconify),
            .legacy_control => metadata[0] = @backingInt(protocol.ConsequenceLegacyControlKind.hp_memory_lock),
            .dcs => metadata[0] = @backingInt(protocol.ConsequenceDcsKind.kitty_clone),
            .string_control => metadata[0] = @backingInt(protocol.ConsequenceStringKind.sos),
            else => {},
        }
        const snapshot = terminal.consequences.Snapshot{ .allocator = std.testing.allocator, .payload = payload, .begin = .{ .terminal_revision = 8, .authority_client_id = 7, .generation = if (case.kind == .none) 0 else 12, .payload_len = @intCast(payload.len), .kind = case.kind, .reply_required = case.kind == .clipboard or case.kind == .color_preference, .metadata = metadata } };
        var info: RequestInfo = undefined;
        try describeRequest(&snapshot, &info);
        try std.testing.expectEqual(case.native_kind, info.request.kind);
        try std.testing.expectEqual(@as(u64, 7), info.authority_client_id);
        try std.testing.expectEqual(@as(u64, 8), info.request.terminal_revision);
        try std.testing.expectEqual(@as(u16, 0), info.request._reserved);
    }
}

test "contradictory clipboard facts retire after complete transported body" {
    if (comptime @import("builtin").os.tag == .windows) return;
    const Case = struct { family: protocol.ConsequenceClipboardProtocol = .osc52, operation: protocol.ConsequenceClipboardKind, selector: u8 = 'c', body: []const u8 };
    const cases = [_]Case{
        .{ .operation = .query, .body = "c;SG93bA==" },
        .{ .operation = .set, .body = "c;?" },
        .{ .operation = .query, .selector = 'x', .body = "x;?" },
        .{ .operation = .query, .body = "c?" },
        .{ .operation = .set, .body = "c;!!!!" },
        .{ .operation = .set, .body = "c;A===" },
        .{ .family = .kitty_5522, .operation = .query, .body = "c;?" },
        .{ .family = .kitty_5522, .operation = .set, .body = "c;SG93bA==" },
        .{ .family = .kitty_5522, .operation = .packet, .body = "c;SG93bA==" },
        .{ .operation = .packet, .body = "c;SG93bA==" },
    };
    for (cases) |case| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        var metadata: [protocol.consequence_metadata_bytes]u8 = @splat(0);
        metadata[0] = @backingInt(case.family);
        metadata[1] = @backingInt(case.operation);
        metadata[2] = 1;
        metadata[4] = case.selector;
        var begin: [protocol.payload_bytes.consequence_begin]u8 = undefined;
        try protocol.encodeConsequenceBegin(&begin, .{ .terminal_revision = 8, .authority_client_id = 7, .generation = 12, .payload_len = @intCast(case.body.len), .kind = .clipboard, .reply_required = case.operation == .query, .metadata = metadata });
        var end: [protocol.payload_bytes.consequence_end]u8 = undefined;
        protocol.encodeConsequenceEnd(&end, 12);
        try fixture.send(.consequence_begin, &begin);
        try fixture.send(.consequence_data, case.body);
        try fixture.send(.consequence_end, &end);
        try std.testing.expectError(error.InvalidSnapshot, observeRequests(fixture.connection, std.testing.allocator));
        try std.testing.expectError(error.ConnectionRetired, fixture.connection.readinessFd());
    }
}

test "canonical clipboard query set and Kitty packet retain native identities" {
    const Case = struct { family: protocol.ConsequenceClipboardProtocol, operation: protocol.ConsequenceClipboardKind, body: []const u8, selector_len: u8, expected: u8 };
    const cases = [_]Case{
        .{ .family = .osc52, .operation = .query, .body = "c;?", .selector_len = 1, .expected = c.HVT_CLIPBOARD_QUERY },
        .{ .family = .osc52, .operation = .set, .body = "c;SG93bA==", .selector_len = 1, .expected = c.HVT_CLIPBOARD_SET },
        .{ .family = .osc52, .operation = .set, .body = ";", .selector_len = 0, .expected = c.HVT_CLIPBOARD_SET },
        .{ .family = .kitty_5522, .operation = .packet, .body = "type=write", .selector_len = 0, .expected = c.HVT_CLIPBOARD_PACKET },
    };
    var storage: [16]u8 = undefined;
    for (cases) |case| {
        var metadata: [protocol.consequence_metadata_bytes]u8 = @splat(0);
        metadata[0] = @backingInt(case.family);
        metadata[1] = @backingInt(case.operation);
        metadata[2] = case.selector_len;
        if (case.selector_len != 0) metadata[4] = 'c';
        @memcpy(storage[0..case.body.len], case.body);
        const snapshot = terminal.consequences.Snapshot{ .allocator = std.testing.allocator, .payload = storage[0..case.body.len], .begin = .{ .terminal_revision = 8, .authority_client_id = 7, .generation = 12, .payload_len = @intCast(case.body.len), .kind = .clipboard, .reply_required = case.operation == .query, .metadata = metadata } };
        var info: RequestInfo = undefined;
        try describeRequest(&snapshot, &info);
        try std.testing.expectEqual(case.expected, info.request.data.clipboard.operation);
        try std.testing.expectEqual(@as(u32, case.selector_len), info.request.data.clipboard.selection_len);
        try std.testing.expectEqual(@as(u8, if (case.family == .osc52) c.HVT_CLIPBOARD_OSC52 else c.HVT_CLIPBOARD_KITTY_5522), info.request.data.clipboard.protocol);
    }
}

test "oversized native replies perform no socket I/O and leave the same stream reusable" {
    if (comptime @import("builtin").os.tag == .windows) return;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const body: [c.HSC_MAX_CLIPBOARD_REPLY_BYTES + 1]u8 = @splat('x');
    try std.testing.expectError(error.PayloadTooLarge, replyClipboard(fixture.connection, 12, &body));
    try std.testing.expectError(error.PayloadTooLarge, replyPointerShape(fixture.connection, 12, body[0 .. c.HSC_MAX_POINTER_REPLY_BYTES + 1]));
    try std.testing.expectError(error.PayloadTooLarge, replyContainerIconTitle(fixture.connection, 12, body[0 .. c.HSC_MAX_ICON_TITLE_REPLY_BYTES + 1]));
    var pending = [_]std.posix.pollfd{.{ .fd = fixture.peer, .events = std.posix.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(c_int, 0), std.posix.system.poll(&pending, 1, 0));
    var result: [protocol.payload_bytes.result]u8 = undefined;
    protocol.encodeResult(&result, .{ .request_kind = .assign_consequence_leader, .code = .ok });
    try fixture.send(.result, &result);
    try acquireRequests(fixture.connection);
    try std.testing.expect((try fixture.connection.readinessFd()) >= 0);
    var header: [protocol.header_bytes]u8 = undefined;
    try readAll(fixture.peer, &header);
    try std.testing.expectEqual(protocol.Kind.assign_consequence_leader, (try protocol.decodeHeader(&header)).kind);
}

test "complete interaction rejection preserves a subsequent coherent interaction request" {
    if (comptime @import("builtin").os.tag == .windows) return;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var result: [protocol.payload_bytes.result]u8 = undefined;
    protocol.encodeResult(&result, .{ .request_kind = .interaction_state, .code = .rejected });
    try fixture.send(.result, &result);
    try std.testing.expectError(error.ServerRejected, interaction(fixture.connection));
    var state: [protocol.payload_bytes.interaction_state_snapshot]u8 = undefined;
    var coherent = std.mem.zeroes(protocol.InteractionStateSnapshot);
    coherent.terminal_revision = 99;
    coherent.focus_reporting = true;
    protocol.encodeInteractionStateSnapshot(&state, coherent);
    try fixture.send(.interaction_state_snapshot, &state);
    const value = try interaction(fixture.connection);
    try std.testing.expectEqual(@as(u64, 99), value.terminal_revision);
    try std.testing.expect(value.flags & c.HVT_INTERACTION_FOCUS_REPORTING != 0);
    try std.testing.expect((try fixture.connection.readinessFd()) >= 0);
}

test {
    std.testing.refAllDecls(queries);
}
