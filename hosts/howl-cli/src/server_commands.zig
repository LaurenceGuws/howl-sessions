//! CLI projection of Server -> Sessions -> Instances orchestration.

const std = @import("std");
const server_client = @import("server_client");
const server_runtime = @import("server_runtime");
const failure = @import("failure.zig");

/// Dispatches Server management commands and reports their connection context.
pub fn run(
    init: std.process.Init,
    args: []const [*:0]const u8,
    context: *failure.Context,
) !void {
    if (args.len == 0) return error.InvalidArguments;
    const action = std.mem.span(args[0]);
    if (isHelp(action)) return printHelp(init);

    if (std.mem.eql(u8, action, "run")) {
        context.reset("server.run");
        if (args.len >= 2 and isHelp(std.mem.span(args[1]))) return printRunHelp(init);
        if (args.len != 2) return error.InvalidArguments;
        return runServer(init, std.mem.span(args[1]));
    }
    if (std.mem.eql(u8, action, "status")) {
        context.reset("server.status");
        if (args.len >= 2 and isHelp(std.mem.span(args[1]))) return printStatusHelp(init);
        if (args.len != 2) return error.InvalidArguments;
        return statusCommand(init, std.mem.span(args[1]), context);
    }
    if (std.mem.eql(u8, action, "tree")) {
        context.reset("server.tree");
        if (args.len >= 2 and isHelp(std.mem.span(args[1]))) return printTreeHelp(init);
        if (args.len != 2) return error.InvalidArguments;
        return treeCommand(init, std.mem.span(args[1]), context);
    }
    if (std.mem.eql(u8, action, "session"))
        return sessionCommand(init, args[1..], context);
    if (std.mem.eql(u8, action, "instance"))
        return instanceCommand(init, args[1..], context);
    return error.InvalidArguments;
}

fn sessionCommand(
    init: std.process.Init,
    args: []const [*:0]const u8,
    context: *failure.Context,
) !void {
    if (args.len == 0) {
        context.reset("server.session");
        return error.InvalidArguments;
    }
    if (isHelp(std.mem.span(args[0]))) return printSessionHelp(init);
    const action = std.mem.span(args[0]);
    if (std.mem.eql(u8, action, "create")) {
        context.reset("server.session.create");
        if (args.len >= 2 and isHelp(std.mem.span(args[1]))) return printSessionCreateHelp(init);
        if (args.len != 3) return error.InvalidArguments;
        return createSession(init, std.mem.span(args[1]), std.mem.span(args[2]), context);
    }
    if (std.mem.eql(u8, action, "close")) {
        context.reset("server.session.close");
        if (args.len >= 2 and isHelp(std.mem.span(args[1]))) return printSessionCloseHelp(init);
        if (args.len != 3) return error.InvalidArguments;
        const id = parseIdentity(std.mem.span(args[2])) catch return error.InvalidArguments;
        return closeSession(init, std.mem.span(args[1]), id, context);
    }
    context.reset("server.session");
    return error.InvalidArguments;
}

fn instanceCommand(
    init: std.process.Init,
    args: []const [*:0]const u8,
    context: *failure.Context,
) !void {
    if (args.len == 0) {
        context.reset("server.instance");
        return error.InvalidArguments;
    }
    if (isHelp(std.mem.span(args[0]))) return printInstanceHelp(init);
    const action = std.mem.span(args[0]);
    if (std.mem.eql(u8, action, "create")) {
        context.reset("server.instance.create");
        if (args.len >= 2 and isHelp(std.mem.span(args[1]))) return printInstanceCreateHelp(init);
        if (args.len < 4) return error.InvalidArguments;
        const session_id = parseIdentity(std.mem.span(args[2])) catch return error.InvalidArguments;
        return createInstance(init, std.mem.span(args[1]), session_id, args[3..], context);
    }
    if (std.mem.eql(u8, action, "close")) {
        context.reset("server.instance.close");
        if (args.len >= 2 and isHelp(std.mem.span(args[1]))) return printInstanceCloseHelp(init);
        if (args.len != 4) return error.InvalidArguments;
        const session_id = parseIdentity(std.mem.span(args[2])) catch return error.InvalidArguments;
        const instance_id = parseIdentity(std.mem.span(args[3])) catch return error.InvalidArguments;
        return closeInstance(init, std.mem.span(args[1]), .{
            .session_id = session_id,
            .instance_id = instance_id,
        }, context);
    }
    context.reset("server.instance");
    return error.InvalidArguments;
}

fn runServer(init: std.process.Init, listen: []const u8) !void {
    const spec = try server_runtime.parseListener(listen);
    var termination = try Termination.init();
    defer termination.deinit();
    var runtime = try server_runtime.Runtime.initFresh(
        init.gpa,
        init.io,
        init.minimal.environ,
        spec,
    );
    defer runtime.deinit();

    var endpoint_buffer: [256]u8 = undefined;
    const endpoint = try runtime.endpointText(&endpoint_buffer);
    var output_buffer: [1024]u8 = undefined;
    var stdout = stdoutWriter(init, &output_buffer);
    const writer = &stdout.interface;
    try writer.writeAll("{\"schema\":\"howl.server.run/v1\",\"server_id\":");
    try writeIdentity(writer, runtime.serverId());
    try writer.writeAll(",\"endpoint\":");
    try std.json.Stringify.value(endpoint, .{}, writer);
    try writer.writeAll("}\n");
    try writer.flush();

    while (!termination_requested.load(.acquire)) try runtime.turn();
}

// Foreground host policy only. The handler publishes intent; ordinary control
// flow performs all allocator, descriptor and process teardown. A runtime turn
// returns on an interrupted aggregate wait, rather than restarting its timeout.
var termination_requested = std.atomic.Value(bool).init(false);

fn requestTermination(_: std.os.linux.SIG) callconv(.c) void {
    termination_requested.store(true, .release);
}

const Termination = struct {
    interrupt: std.os.linux.Sigaction,
    terminate: std.os.linux.Sigaction,

    fn init() !Termination {
        const linux = std.os.linux;
        termination_requested.store(false, .release);
        const action: linux.Sigaction = .{
            .handler = .{ .handler = requestTermination },
            .mask = linux.sigemptyset(),
            .flags = 0,
        };
        var value: Termination = undefined;
        if (linux.errno(linux.sigaction(linux.SIG.INT, &action, &value.interrupt)) != .SUCCESS)
            return error.SignalSetupFailed;
        errdefer restore(linux.SIG.INT, &value.interrupt);
        if (linux.errno(linux.sigaction(linux.SIG.TERM, &action, &value.terminate)) != .SUCCESS)
            return error.SignalSetupFailed;
        return value;
    }

    fn restore(signal: std.os.linux.SIG, action: *const std.os.linux.Sigaction) void {
        const linux = std.os.linux;
        const result = linux.sigaction(signal, action, null);
        std.debug.assert(linux.errno(result) == .SUCCESS);
    }

    fn deinit(self: *Termination) void {
        restore(std.os.linux.SIG.TERM, &self.terminate);
        restore(std.os.linux.SIG.INT, &self.interrupt);
    }
};

fn connect(
    init: std.process.Init,
    endpoint: []const u8,
    context: *failure.Context,
) !*server_client.Connection {
    var diagnostic: server_client.ConnectDiagnostic = .{};
    return server_client.Connection.connectDiagnosed(init.gpa, endpoint, &diagnostic) catch |problem| {
        context.captureConnect(&diagnostic);
        return problem;
    };
}

fn statusCommand(init: std.process.Init, endpoint: []const u8, context: *failure.Context) !void {
    var connection = try connect(init, endpoint, context);
    defer connection.deinit();
    const value = try connection.status();
    var buffer: [2048]u8 = undefined;
    var stdout = stdoutWriter(init, &buffer);
    const writer = &stdout.interface;
    try writer.writeAll("{\"schema\":\"howl.server.status/v1\",\"server_id\":");
    try writeIdentity(writer, value.server_id);
    try writer.writeAll(",\"tree_revision\":");
    try writeIdentity(writer, value.tree_revision);
    try writer.print(",\"session_count\":{d},\"instance_count\":{d},\"session_capacity\":{d},\"instances_per_session\":{d}}}\n", .{
        value.session_count,
        value.instance_count,
        value.session_capacity,
        value.instances_per_session,
    });
    try writer.flush();
}

fn treeCommand(init: std.process.Init, endpoint: []const u8, context: *failure.Context) !void {
    var connection = try connect(init, endpoint, context);
    defer connection.deinit();
    var tree = try connection.observeTree(0);
    defer tree.deinit();
    var buffer: [16 * 1024]u8 = undefined;
    var stdout = stdoutWriter(init, &buffer);
    const writer = &stdout.interface;
    try writer.writeAll("{\"schema\":\"howl.server.tree/v1\",\"server_id\":");
    try writeIdentity(writer, tree.status.server_id);
    try writer.writeAll(",\"tree_revision\":");
    try writeIdentity(writer, tree.status.tree_revision);
    try writer.writeAll(",\"sessions\":[");
    for (tree.sessions, 0..) |session, session_index| {
        if (session_index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"session_id\":");
        try writeIdentity(writer, session.id);
        try writer.writeAll(",\"name\":");
        try std.json.Stringify.value(session.name, .{}, writer);
        try writer.writeAll(",\"instances\":[");
        for (session.instances, 0..) |instance, instance_index| {
            if (instance_index != 0) try writer.writeByte(',');
            try writer.writeAll("{\"instance_id\":");
            try writeIdentity(writer, instance.instance_id);
            try writer.writeAll(",\"state\":");
            try std.json.Stringify.value(@tagName(instance.state), .{}, writer);
            try writer.writeByte('}');
        }
        try writer.writeAll("]}");
    }
    try writer.writeAll("]}\n");
    try writer.flush();
}

fn createSession(
    init: std.process.Init,
    endpoint: []const u8,
    name: []const u8,
    context: *failure.Context,
) !void {
    var connection = try connect(init, endpoint, context);
    defer connection.deinit();
    const id = try connection.createSession(name);
    try emitSessionReceipt(init, "create", id, connection.treeRevision());
}

fn closeSession(
    init: std.process.Init,
    endpoint: []const u8,
    id: u64,
    context: *failure.Context,
) !void {
    var connection = try connect(init, endpoint, context);
    defer connection.deinit();
    try connection.closeSession(id);
    try emitSessionReceipt(init, "close", id, connection.treeRevision());
}

fn createInstance(
    init: std.process.Init,
    endpoint: []const u8,
    session_id: u64,
    args: []const [*:0]const u8,
    context: *failure.Context,
) !void {
    var shell: ?[]const u8 = null;
    var command: ?[]const u8 = null;
    var cwd: ?[]const u8 = null;
    var rows: u16 = 24;
    var columns: u16 = 80;
    var history_rows: u16 = 4096;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = std.mem.span(args[index]);
        if (std.mem.eql(u8, arg, "--shell")) {
            index += 1;
            if (index == args.len or shell != null) return error.InvalidArguments;
            shell = std.mem.span(args[index]);
        } else if (std.mem.eql(u8, arg, "--command")) {
            index += 1;
            if (index == args.len or command != null) return error.InvalidArguments;
            command = std.mem.span(args[index]);
        } else if (std.mem.eql(u8, arg, "--cwd")) {
            index += 1;
            if (index == args.len or cwd != null) return error.InvalidArguments;
            cwd = std.mem.span(args[index]);
        } else if (std.mem.eql(u8, arg, "--rows")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            rows = parseU16(std.mem.span(args[index])) catch return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--columns")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            columns = parseU16(std.mem.span(args[index])) catch return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--history-rows")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            history_rows = parseU16(std.mem.span(args[index])) catch return error.InvalidArguments;
        } else return error.InvalidArguments;
    }
    const shell_value = shell orelse return error.InvalidArguments;
    var connection = try connect(init, endpoint, context);
    defer connection.deinit();
    const identity = try connection.createInstance(.{
        .session_id = session_id,
        .shell = shell_value,
        .command = command,
        .cwd = cwd,
        .rows = rows,
        .columns = columns,
        .history_rows = history_rows,
    });
    try emitInstanceReceipt(init, "create", identity, connection.treeRevision());
}

fn closeInstance(
    init: std.process.Init,
    endpoint: []const u8,
    identity: server_client.protocol.InstanceIdentity,
    context: *failure.Context,
) !void {
    var connection = try connect(init, endpoint, context);
    defer connection.deinit();
    try connection.closeInstance(identity);
    try emitInstanceReceipt(init, "close", identity, connection.treeRevision());
}

fn emitSessionReceipt(init: std.process.Init, operation: []const u8, id: u64, revision: u64) !void {
    var buffer: [1024]u8 = undefined;
    var stdout = stdoutWriter(init, &buffer);
    const writer = &stdout.interface;
    try writer.writeAll("{\"schema\":\"howl.server.session/v1\",\"operation\":");
    try std.json.Stringify.value(operation, .{}, writer);
    try writer.writeAll(",\"session_id\":");
    try writeIdentity(writer, id);
    try writer.writeAll(",\"tree_revision\":");
    try writeIdentity(writer, revision);
    try writer.writeAll("}\n");
    try writer.flush();
}

fn emitInstanceReceipt(
    init: std.process.Init,
    operation: []const u8,
    identity: server_client.protocol.InstanceIdentity,
    revision: u64,
) !void {
    var buffer: [1024]u8 = undefined;
    var stdout = stdoutWriter(init, &buffer);
    const writer = &stdout.interface;
    try writer.writeAll("{\"schema\":\"howl.server.instance/v1\",\"operation\":");
    try std.json.Stringify.value(operation, .{}, writer);
    try writer.writeAll(",\"session_id\":");
    try writeIdentity(writer, identity.session_id);
    try writer.writeAll(",\"instance_id\":");
    try writeIdentity(writer, identity.instance_id);
    try writer.writeAll(",\"tree_revision\":");
    try writeIdentity(writer, revision);
    try writer.writeAll("}\n");
    try writer.flush();
}

fn writeIdentity(writer: *std.Io.Writer, value: u64) !void {
    try writer.print("\"{d}\"", .{value});
}

fn parseIdentity(text: []const u8) !u64 {
    const value = try std.fmt.parseInt(u64, text, 10);
    if (value == 0) return error.InvalidIdentity;
    return value;
}

fn parseU16(text: []const u8) !u16 {
    const value = try std.fmt.parseInt(u16, text, 10);
    if (value == 0) return error.InvalidValue;
    return value;
}

fn stdoutWriter(init: std.process.Init, buffer: []u8) std.Io.File.Writer {
    return std.Io.File.stdout().writerStreaming(init.io, buffer);
}

fn isHelp(value: []const u8) bool {
    return std.mem.eql(u8, value, "--help") or std.mem.eql(u8, value, "-h");
}

/// Writes the Server command usage to the caller's output.
pub fn printHelp(init: std.process.Init) !void {
    return printText(init, "usage:\n" ++
        "  howl server status ENDPOINT\n" ++
        "  howl server tree ENDPOINT\n" ++
        "  howl server session create ENDPOINT NAME\n" ++
        "  howl server session close ENDPOINT SESSION_ID\n" ++
        "  howl server instance create ENDPOINT SESSION_ID --shell PATH [--command TEXT] [--cwd PATH] [--rows N] [--columns N] [--history-rows N]\n" ++
        "  howl server instance close ENDPOINT SESSION_ID INSTANCE_ID\n");
}

fn printSessionHelp(init: std.process.Init) !void {
    return printText(init, "usage:\n" ++
        "  howl server session create ENDPOINT NAME\n" ++
        "  howl server session close ENDPOINT SESSION_ID\n");
}

fn printInstanceHelp(init: std.process.Init) !void {
    return printText(init, "usage:\n" ++
        "  howl server instance create ENDPOINT SESSION_ID --shell PATH [--command TEXT] [--cwd PATH] [--rows N] [--columns N] [--history-rows N]\n" ++
        "  howl server instance close ENDPOINT SESSION_ID INSTANCE_ID\n");
}

fn printRunHelp(init: std.process.Init) !void {
    return printText(init, "usage: howl server run unix:/ABSOLUTE/PATH.sock|tcp:PORT|tcp://NUMERIC_IPV4:PORT\n");
}

fn printStatusHelp(init: std.process.Init) !void {
    return printText(init, "usage: howl server status ENDPOINT\n");
}

fn printTreeHelp(init: std.process.Init) !void {
    return printText(init, "usage: howl server tree ENDPOINT\n");
}

fn printSessionCreateHelp(init: std.process.Init) !void {
    return printText(init, "usage: howl server session create ENDPOINT NAME\n");
}

fn printSessionCloseHelp(init: std.process.Init) !void {
    return printText(init, "usage: howl server session close ENDPOINT SESSION_ID\n");
}

fn printInstanceCreateHelp(init: std.process.Init) !void {
    return printText(init, "usage: howl server instance create ENDPOINT SESSION_ID --shell PATH [--command TEXT] [--cwd PATH] [--rows N] [--columns N] [--history-rows N]\n");
}

fn printInstanceCloseHelp(init: std.process.Init) !void {
    return printText(init, "usage: howl server instance close ENDPOINT SESSION_ID INSTANCE_ID\n");
}

fn printText(init: std.process.Init, text: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = stdoutWriter(init, &buffer);
    try stdout.interface.writeAll(text);
    try stdout.interface.flush();
}
