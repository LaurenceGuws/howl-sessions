const std = @import("std");
const client = @import("server_client").terminal;

const StateRecord = struct {
    schema: []const u8 = "howl.state/v1",
    terminal_revision: u64,
    keyboard_action_mode: bool,
    auto_repeat: bool,
    newline_mode: bool,
    application_cursor_keys: bool,
    application_keypad: bool,
    meta_sends_escape: bool,
    report_key_up: bool,
    bracketed_paste: bool,
    focus_reporting: bool,
    termios_signals: bool,
    alternate_scroll: bool,
    paste_events: bool,
    inband_resize_notifications: bool,
    mouse_tracking: []const u8,
    mouse_protocol: []const u8,
    modify_other_keys: i8,
    kitty_keyboard_flags: u8,
    key_format_resource_4: u16,
    pointer_mode: u2,
};

/// Requests interaction state and writes one JSON observation.
pub fn emit(connection: *client.Connection, writer: *std.Io.Writer) !void {
    const value = try client.state.get(connection);
    try std.json.Stringify.value(StateRecord{
        .terminal_revision = value.terminal_revision,
        .keyboard_action_mode = value.keyboard_action_mode,
        .auto_repeat = value.auto_repeat,
        .newline_mode = value.newline_mode,
        .application_cursor_keys = value.application_cursor_keys,
        .application_keypad = value.application_keypad,
        .meta_sends_escape = value.meta_sends_escape,
        .report_key_up = value.report_key_up,
        .bracketed_paste = value.bracketed_paste,
        .focus_reporting = value.focus_reporting,
        .termios_signals = value.termios_signals,
        .alternate_scroll = value.alternate_scroll,
        .paste_events = value.paste_events,
        .inband_resize_notifications = value.inband_resize_notifications,
        .mouse_tracking = @tagName(value.mouse_tracking),
        .mouse_protocol = @tagName(value.mouse_protocol),
        .modify_other_keys = value.modify_other_keys,
        .kitty_keyboard_flags = value.kitty_keyboard_flags,
        .key_format_resource_4 = value.key_format_resource_4,
        .pointer_mode = value.pointer_mode,
    }, .{}, writer);
    try writer.writeByte('\n');
}
