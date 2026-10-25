//! Browser ABI and memory adapter around Server's caller-driven byte client.
//! Web owns buffers, numeric phases, admission budgets and semantic projection.
const std = @import("std");
const client = @import("server_client").terminal;
const byte = @import("server_client_byte");
const p = byte.protocol;
const rich = client.rich;
const limits = @import("limits");

var input: [32768]u8 = undefined;
var packet: [p.header_bytes + p.maximum_payload_bytes]u8 = undefined;
var transcript: [p.maximum_observation_bytes]u8 = undefined;
var arena: [20 * 1024 * 1024]u8 = undefined;
var projection: [65536]u8 = undefined;
var output: [p.header_bytes + 1 + 4096]u8 = undefined;
var storage: byte.Storage = undefined;
var connection: ?*byte.ByteClient = null;
var observed: ?p.SnapshotBegin = null;
var interaction: ?p.InteractionStateSnapshot = null;
var projection_len: usize = 0;
var projection_truncated: bool = false;
var selection_len: usize = 0;
// Legacy private getter survives reset; bytes are sent only after a staged
// operation. The module's outgoing borrow itself is invalidated by reset.
var output_len: usize = 0;
var failure: []const u8 = "";
var last_result_code: u32 = 0;
// Private browser ABI phases; never Server-client product vocabulary.
// 0 closed, 1 await ready, 2 attached, 3 observing, 4 observation ready,
// 5 control pending, 6 result ready, 7 image pending, 8 image ready,
// 9 interaction pending, 10 selection pending, 99 failed.
var phase: u32 = 0;

fn controlReady() bool {
    return if (connection) |value| value.isIdle() else false;
}

fn image() byte.Image {
    return if (connection) |value| value.image() else .{ .bytes = arena[0..0] };
}

fn observationBytes() []const u8 {
    return if (connection) |value| value.observationBytes() else transcript[0..0];
}

export fn hw_input_ptr() usize {
    return @intFromPtr(&input);
}
export fn hw_input_capacity() usize {
    return input.len;
}
export fn hw_output_ptr() usize {
    return @intFromPtr(&output);
}
export fn hw_output_len() usize {
    return output_len;
}
export fn hw_text_ptr() usize {
    return @intFromPtr(&projection);
}
export fn hw_text_len() usize {
    return projection_len;
}
export fn hw_text_truncated() u32 {
    return @intFromBool(projection_truncated);
}
export fn hw_snapshot_ptr() usize {
    return @intFromPtr(&transcript);
}
export fn hw_snapshot_len() usize {
    return observationBytes().len;
}
export fn hw_image_ptr() usize {
    return @intFromPtr(&arena);
}
export fn hw_image_len() usize {
    return image().bytes.len;
}
export fn hw_image_id() u32 {
    return image().image_id;
}
export fn hw_image_generation() u64 {
    return image().generation;
}
export fn hw_image_width() u32 {
    return image().width;
}
export fn hw_image_height() u32 {
    return image().height;
}
export fn hw_selection_ptr() usize {
    return @intFromPtr(&arena);
}
export fn hw_selection_len() usize {
    return selection_len;
}
export fn hw_error_ptr() usize {
    return @intFromPtr(failure.ptr);
}
export fn hw_error_len() usize {
    return failure.len;
}
export fn hw_phase() u32 {
    return phase;
}
export fn hw_identity() u64 {
    return if (connection) |value| if (value.identity()) |ready| ready.client_id else 0 else 0;
}
export fn hw_revision() u64 {
    return if (observed) |value| value.revision else 0;
}
export fn hw_terminal_revision() u64 {
    return if (observed) |value| value.terminal.revision else 0;
}
export fn hw_rows() u32 {
    return if (observed) |value| value.terminal.rows else 0;
}
export fn hw_columns() u32 {
    return if (observed) |value| value.terminal.columns else 0;
}
export fn hw_maximum_rows() u32 {
    return limits.maximum_rows;
}
export fn hw_maximum_columns() u32 {
    return limits.maximum_columns;
}
export fn hw_history_offset() u32 {
    return if (observed) |value| value.terminal.history_offset else 0;
}
export fn hw_history_count() u32 {
    return if (observed) |value| value.terminal.history_count else 0;
}
export fn hw_history_row_base() u32 {
    return if (observed) |value| value.terminal.history_row_base else 0;
}
export fn hw_alternate_screen() u32 {
    return if (observed) |value| @intFromBool(value.terminal.alternate_screen) else 0;
}
export fn hw_leader_present() u32 {
    return if (observed) |value| @intFromBool(value.leader_present) else 0;
}
export fn hw_interaction_terminal_revision() u64 {
    return if (interaction) |value| value.terminal_revision else 0;
}
export fn hw_interaction_alternate_scroll() u32 {
    return if (interaction) |value| @intFromBool(value.alternate_scroll) else 0;
}
export fn hw_interaction_mouse_tracking() u32 {
    return if (interaction) |value| @backingInt(value.mouse_tracking) else 0;
}
export fn hw_interaction_mouse_protocol() u32 {
    return if (interaction) |value| @backingInt(value.mouse_protocol) else 0;
}
export fn hw_interaction_pointer_mode() u32 {
    return if (interaction) |value| value.pointer_mode else 0;
}
export fn hw_last_result_code() u32 {
    return last_result_code;
}
export fn hw_control_ready() u32 {
    return @intFromBool(controlReady());
}

fn fail(message: []const u8) u32 {
    failure = message;
    phase = 99;
    output_len = 0;
    if (connection) |value| value.retire();
    return 0;
}

fn started(next_phase: u32) u32 {
    output_len = connection.?.outgoing().len;
    phase = next_phase;
    return 1;
}

export fn hw_reset() u32 {
    connection = byte.ByteClient.init(&storage, .{
        .packet = &packet,
        .outgoing = &output,
        .observation = &transcript,
        .result = &arena,
    }) catch |err| return fail(@errorName(err));
    connection.?.resetAwaitReady();
    observed = null;
    interaction = null;
    projection_len = 0;
    projection_truncated = false;
    selection_len = 0;
    failure = "";
    last_result_code = 0;
    phase = 1;
    return 1;
}

fn observe(immediate: u32, history: u32, mode: byte.ObservationMode) u32 {
    if (!controlReady()) return 0;
    connection.?.observe(.{
        .after_revision = if (immediate != 0) 0 else hw_revision(),
        .history_offset = history,
    }, mode) catch return fail("ObserveEncodingFailed");
    return started(3);
}

export fn hw_observe(immediate: u32, history: u32) u32 {
    return observe(immediate, history, .collect);
}
export fn hw_observe_live(immediate: u32) u32 {
    return observe(immediate, 0, .live);
}

export fn hw_request_image(id: u32, generation: u64) u32 {
    if ((phase != 2 and phase != 4 and phase != 6 and phase != 8) or id == 0 or generation == 0) return 0;
    connection.?.requestImage(.{ .image_id = id, .generation = generation }) catch return fail("ImageRequestEncodingFailed");
    return started(7);
}

export fn hw_release_image() u32 {
    if (phase != 8) return 0;
    connection.?.releaseImage() catch return 0;
    phase = 2;
    return 1;
}

export fn hw_send_text(length: usize) u32 {
    if (!controlReady() or length == 0 or length > 4096 or
        !std.unicode.utf8ValidateSlice(input[0..length])) return 0;
    connection.?.sendBytes(.bytes, input[0..length]) catch return fail("InputEncodingFailed");
    return started(5);
}
export fn hw_send_paste(length: usize) u32 {
    if (!controlReady() or length == 0 or length > 4096) return 0;
    connection.?.sendBytes(.paste, input[0..length]) catch return fail("InputEncodingFailed");
    return started(5);
}

export fn hw_send_named_key(key: u32, action: u32, modifiers: u32) u32 {
    return sendKey(.named, key, action, modifiers);
}
export fn hw_send_unicode_key(scalar: u32, action: u32, modifiers: u32) u32 {
    return sendKey(.unicode, scalar, action, modifiers);
}
fn sendKey(kind: p.InputKeyKind, key: u32, action: u32, modifiers: u32) u32 {
    if (!controlReady() or action > std.math.maxInt(u8) or modifiers > std.math.maxInt(u8)) return 0;
    const selected = std.enums.fromInt(p.InputKeyAction, @as(u8, @intCast(action))) orelse return 0;
    connection.?.sendKey(.{ .kind = kind, .key_value = key, .action = selected, .modifiers = @intCast(modifiers) }) catch return 0;
    return started(5);
}

export fn hw_send_focus(focus: u32) u32 {
    if (!controlReady() or focus > std.math.maxInt(u8)) return 0;
    const selected = std.enums.fromInt(p.InputFocus, @as(u8, @intCast(focus))) orelse return 0;
    connection.?.sendFocus(selected) catch return 0;
    return started(5);
}

export fn hw_request_interaction_state() u32 {
    if (!controlReady()) return 0;
    connection.?.interactionState() catch return fail("InteractionStateEncodingFailed");
    return started(9);
}

export fn hw_request_text_extract(
    start_row: i32,
    start_column: u32,
    end_row: i32,
    end_column: u32,
    columns: u32,
    alternate: u32,
) u32 {
    if (!controlReady() or start_column > std.math.maxInt(u16) or end_column > std.math.maxInt(u16) or
        columns == 0 or columns > std.math.maxInt(u16) or alternate > 1) return 0;
    connection.?.textExtract(.{
        .start = .{ .row = start_row, .column = @intCast(start_column) },
        .end = .{ .row = end_row, .column = @intCast(end_column) },
        .columns = @intCast(columns),
        .alternate_screen = alternate == 1,
    }) catch return fail("TextExtractEncodingFailed");
    selection_len = 0;
    last_result_code = std.math.maxInt(u32);
    return started(10);
}

export fn hw_send_mouse(
    kind: u32,
    button: u32,
    modifiers: u32,
    buttons: u32,
    row: i32,
    column: u32,
    pixels_present: u32,
    pixel_x: u32,
    pixel_y: u32,
) u32 {
    if (!controlReady() or kind > std.math.maxInt(u8) or button > std.math.maxInt(u8) or
        modifiers > std.math.maxInt(u8) or buttons > std.math.maxInt(u8) or
        column > std.math.maxInt(u16) or pixels_present > 1 or
        (pixels_present == 0 and (pixel_x != 0 or pixel_y != 0))) return 0;
    const selected_kind = std.enums.fromInt(p.InputMouseKind, @as(u8, @intCast(kind))) orelse return 0;
    const selected_button = std.enums.fromInt(p.InputMouseButton, @as(u8, @intCast(button))) orelse return 0;
    connection.?.sendMouse(.{
        .kind = selected_kind,
        .button = selected_button,
        .modifiers = @intCast(modifiers),
        .buttons_down = @intCast(buttons),
        .row = row,
        .column = @intCast(column),
        .pixel_x = if (pixels_present == 1) pixel_x else null,
        .pixel_y = if (pixels_present == 1) pixel_y else null,
    }) catch return 0;
    return started(5);
}

fn resize(rows: u32, columns: u32, claim: bool) u32 {
    if (!controlReady() or rows == 0 or rows > std.math.maxInt(u16) or
        columns == 0 or columns > std.math.maxInt(u16)) return 0;
    connection.?.resize(.{ .rows = @intCast(rows), .columns = @intCast(columns) }, claim) catch
        return fail(if (claim) "ResizeLeaderEncodingFailed" else "ResizeEncodingFailed");
    last_result_code = std.math.maxInt(u32);
    return started(5);
}
export fn hw_send_resize(rows: u32, columns: u32) u32 {
    return resize(rows, columns, true);
}
export fn hw_send_resize_owned(rows: u32, columns: u32) u32 {
    return resize(rows, columns, false);
}

fn decodeSnapshot() (rich.Error || client.view.Error)!void {
    var memory = std.heap.FixedBufferAllocator.init(&arena);
    var snapshot = try rich.decodeFrames(memory.allocator(), observationBytes());
    defer snapshot.deinit();
    const view = try client.view.project(memory.allocator(), &snapshot);
    defer client.view.deinit(view);
    const projected = client.view.writeVisibleText(view, &projection);
    projection_len = projected.bytes_written;
    projection_truncated = projected.truncated;
    observed = snapshot.begin;
}

// The byte client owns transaction correlation. This switch only preserves
// Web's existing rejection/close presentation policy and private phase numbers.
fn acceptResult(result: p.Result) u32 {
    switch (phase) {
        5 => switch (result.request_kind) {
            .input => if (result.code != .ok) return fail("InputRejected"),
            .assign_leader => return fail("ResizeLeaderRejected"),
            .resize => {
                if (result.code != .ok and result.code != .not_leader) return fail("ResizeRejected");
                last_result_code = @backingInt(result.code);
            },
            else => return fail("MissingControlOperation"),
        },
        7 => return fail("ImageRejected"),
        9 => return fail("ExpectedInteractionStateSnapshot"),
        10 => {
            last_result_code = @backingInt(result.code);
            selection_len = 0;
        },
        else => return fail("UnsolicitedFrame"),
    }
    phase = 6;
    return 1;
}

export fn hw_feed(length: usize) u32 {
    if (phase == 0 or phase == 99 or length > input.len) return 0;
    var offset: usize = 0;
    while (offset < length) {
        const received = connection.?.feed(input[offset..length]) catch |err| return fail(switch (err) {
            // The reusable API reports caller capacity accurately. Preserve the
            // legacy private Web strings at this application boundary only.
            error.ResultTooSmall => switch (phase) {
                7 => "ImageIdentityMismatch",
                10 => "InvalidTextExtractData",
                else => @errorName(err),
            },
            else => @errorName(err),
        });
        offset += received.consumed;
        switch (received.event) {
            .progress => {},
            .attached => phase = 2,
            .observation => |begin| {
                if (begin) |value| {
                    projection_len = 0;
                    projection_truncated = false;
                    observed = value;
                } else decodeSnapshot() catch |err| {
                    projection_len = 0;
                    return fail(@errorName(err));
                };
                phase = 4;
            },
            .result => |result| if (acceptResult(result) == 0) return 0,
            .outgoing_followup => |result| {
                output_len = connection.?.outgoing().len;
                last_result_code = @backingInt(result.code);
                if (offset != length) return fail("ControlFollowupRequired");
                return 2;
            },
            .interaction => |value| {
                interaction = value;
                phase = 6;
            },
            .text => |bytes| {
                selection_len = bytes.len;
                last_result_code = @backingInt(p.ResultCode.ok);
                phase = 6;
            },
            .image => phase = 8,
        }
    }
    return 1;
}

export fn hw_finish() u32 {
    if (phase == 99) return 0;
    if (connection) |value| value.finish() catch |err| return fail(@errorName(err));
    phase = 0;
    output_len = 0;
    return 1;
}
