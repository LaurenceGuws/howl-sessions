//! One bounded CLI error context so failures remain machine-readable.

const std = @import("std");
const client = @import("server_client").terminal;

/// Copied, bounded diagnostics for the current CLI operation.
pub const Context = struct {
    operation: []const u8 = "unknown",
    connect_stage: ?client.ConnectStage = null,
    os_error: i32 = 0,
    route_message: [512]u8 = undefined,
    route_message_len: usize = 0,

    /// Clears previous diagnostics and borrows the new operation label.
    pub fn reset(self: *Context, operation: []const u8) void {
        self.* = .{ .operation = operation };
    }

    /// Copies the transport diagnostic into this bounded context.
    pub fn captureConnect(self: *Context, diagnostic: *const client.ConnectDiagnostic) void {
        self.connect_stage = diagnostic.stage;
        self.os_error = diagnostic.os_error;
        const count = @min(diagnostic.route_message_len, self.route_message.len);
        if (count != 0) @memcpy(self.route_message[0..count], diagnostic.route_message[0..count]);
        self.route_message_len = count;
    }

    /// Writes a JSON failure to stderr, falling back to its error name if output fails.
    pub fn emit(self: *const Context, init: std.process.Init, failure_name: []const u8) void {
        var buffer: [2048]u8 = undefined;
        var stderr = std.Io.File.stderr().writerStreaming(init.io, &buffer);
        const writer = &stderr.interface;
        writer.writeAll("{\"schema\":\"howl.error/v1\",\"operation\":") catch return fallback(failure_name);
        std.json.Stringify.value(self.operation, .{}, writer) catch return fallback(failure_name);
        writer.writeAll(",\"code\":") catch return fallback(failure_name);
        std.json.Stringify.value(failure_name, .{}, writer) catch return fallback(failure_name);
        writer.writeAll(",\"failure\":") catch return fallback(failure_name);
        std.json.Stringify.value(failure_name, .{}, writer) catch return fallback(failure_name);
        if (self.connect_stage) |stage| {
            writer.writeAll(",\"connect_stage\":") catch return fallback(failure_name);
            std.json.Stringify.value(@tagName(stage), .{}, writer) catch return fallback(failure_name);
        }
        if (self.os_error != 0) {
            writer.print(",\"os_error\":{d}", .{self.os_error}) catch return fallback(failure_name);
        }
        if (self.route_message_len != 0) {
            writer.writeAll(",\"route_message\":") catch return fallback(failure_name);
            std.json.Stringify.value(self.route_message[0..self.route_message_len], .{}, writer) catch return fallback(failure_name);
        }
        writer.writeAll("}\n") catch return fallback(failure_name);
        writer.flush() catch return fallback(failure_name);
    }
};

fn fallback(failure_name: []const u8) void {
    std.debug.print("howl: {s}\n", .{failure_name});
}
