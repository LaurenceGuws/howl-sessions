const std = @import("std");
const cli = @import("howl_cli");
const client = @import("server_client").terminal;
const protocol = @import("server_client").terminal.protocol;
const server_client = @import("server_client");
const failure = @import("failure.zig");
const server_commands = @import("server_commands.zig");

/// Runs the CLI and reports bounded machine-readable failures.
pub fn main(init: std.process.Init) void {
    var context: failure.Context = .{};
    run(init, &context) catch |problem| {
        context.emit(init, @errorName(problem));
        std.process.exit(if (problem == error.InvalidArguments) 64 else 1);
    };
}

fn run(init: std.process.Init, context: *failure.Context) !void {
    const argv = init.minimal.args.vector;
    if (argv.len < 2) return error.InvalidArguments;
    const operation = std.mem.span(argv[1]);
    context.reset(operation);

    if (std.mem.eql(u8, operation, "--help") or std.mem.eql(u8, operation, "-h"))
        return printRootHelp(init);
    if (std.mem.eql(u8, operation, "help")) {
        if (argv.len == 2) return printRootHelp(init);
        if (argv.len != 3) return error.InvalidArguments;
        const topic = std.mem.span(argv[2]);
        if (std.mem.eql(u8, topic, "instance")) return printInstanceHelp(init);
        if (std.mem.eql(u8, topic, "server")) return server_commands.printHelp(init);
        return error.InvalidArguments;
    }
    if (std.mem.eql(u8, operation, "version")) {
        context.reset("version");
        if (argv.len != 2) return error.InvalidArguments;
        return versionCommand(init);
    }
    if (std.mem.eql(u8, operation, "server")) {
        context.reset("server");
        return server_commands.run(init, argv[2..], context);
    }
    if (!std.mem.eql(u8, operation, "instance")) return error.InvalidArguments;
    if (argv.len < 3) return error.InvalidArguments;
    if (isHelp(std.mem.span(argv[2]))) return printInstanceHelp(init);

    const action = std.mem.span(argv[2]);
    context.reset(instanceOperation(action) orelse return error.InvalidArguments);
    if (argv.len >= 4 and isHelp(std.mem.span(argv[3])))
        return printInstanceOperationHelp(init, action);
    if (argv.len < 4) return error.InvalidArguments;
    const parsed = try parseInstanceTarget(argv[3..]);

    if (std.mem.eql(u8, action, "snapshot")) return snapshotCommand(init, parsed.target, parsed.args, context);
    if (std.mem.eql(u8, action, "state")) return stateCommand(init, parsed.target, parsed.args, context);
    if (std.mem.eql(u8, action, "type")) return bytesCommand(init, parsed.target, parsed.args, false, context);
    if (std.mem.eql(u8, action, "paste")) return bytesCommand(init, parsed.target, parsed.args, true, context);
    if (std.mem.eql(u8, action, "key")) return keyCommand(init, parsed.target, parsed.args, context);
    if (std.mem.eql(u8, action, "focus")) return focusCommand(init, parsed.target, parsed.args, context);
    if (std.mem.eql(u8, action, "resize")) return resizeCommand(init, parsed.target, parsed.args, context);
    if (std.mem.eql(u8, action, "signal")) return signalCommand(init, parsed.target, parsed.args, context);
    return error.InvalidArguments;
}

fn instanceOperation(action: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, action, "snapshot")) return "instance.snapshot";
    if (std.mem.eql(u8, action, "state")) return "instance.state";
    if (std.mem.eql(u8, action, "type")) return "instance.type";
    if (std.mem.eql(u8, action, "paste")) return "instance.paste";
    if (std.mem.eql(u8, action, "key")) return "instance.key";
    if (std.mem.eql(u8, action, "focus")) return "instance.focus";
    if (std.mem.eql(u8, action, "resize")) return "instance.resize";
    if (std.mem.eql(u8, action, "signal")) return "instance.signal";
    return null;
}

fn isHelp(value: []const u8) bool {
    return std.mem.eql(u8, value, "--help") or std.mem.eql(u8, value, "-h");
}

fn versionCommand(init: std.process.Init) !void {
    const Version = struct {
        schema: []const u8 = cli.version_schema,
        name: []const u8 = "howl",
        version: []const u8 = cli.version,
    };
    var output_buffer: [256]u8 = undefined;
    var stdout = stdoutWriter(init, &output_buffer);
    try std.json.Stringify.value(Version{}, .{}, &stdout.interface);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}

const InstanceTarget = server_client.Target;

const ParsedInstanceTarget = struct {
    target: InstanceTarget,
    args: []const [*:0]const u8,
};

fn parseInstanceTarget(args: []const [*:0]const u8) error{InvalidArguments}!ParsedInstanceTarget {
    if (args.len < 5 or !std.mem.eql(u8, std.mem.span(args[0]), "--server")) return error.InvalidArguments;
    const server_id = parseNonzeroIdentity(std.mem.span(args[2])) catch return error.InvalidArguments;
    const session_id = parseNonzeroIdentity(std.mem.span(args[3])) catch return error.InvalidArguments;
    const instance_id = parseNonzeroIdentity(std.mem.span(args[4])) catch return error.InvalidArguments;
    return .{
        .target = .{
            .endpoint = std.mem.span(args[1]),
            .server_id = server_id,
            .session_id = session_id,
            .instance_id = instance_id,
        },
        .args = args[5..],
    };
}

fn parseNonzeroIdentity(text: []const u8) error{InvalidIdentity}!u64 {
    const value = std.fmt.parseInt(u64, text, 10) catch return error.InvalidIdentity;
    if (value == 0) return error.InvalidIdentity;
    return value;
}

fn connect(
    init: std.process.Init,
    target: InstanceTarget,
    context: *failure.Context,
) !*client.Connection {
    var diagnostic: server_client.ConnectDiagnostic = .{};
    const attached = server_client.attach(init.gpa, target, &diagnostic, null) catch |problem| {
        captureServerConnect(context, &diagnostic);
        return problem;
    };
    return attached;
}

fn captureServerConnect(
    context: *failure.Context,
    diagnostic: *const server_client.ConnectDiagnostic,
) void {
    context.connect_stage = std.meta.stringToEnum(client.ConnectStage, @tagName(diagnostic.stage));
    context.os_error = diagnostic.os_error;
    const count = @min(diagnostic.route_message_len, context.route_message.len);
    if (count != 0)
        @memcpy(context.route_message[0..count], diagnostic.route_message[0..count]);
    context.route_message_len = count;
}

fn stdoutWriter(init: std.process.Init, buffer: []u8) std.Io.File.Writer {
    return std.Io.File.stdout().writerStreaming(init.io, buffer);
}

fn snapshotCommand(init: std.process.Init, target: InstanceTarget, args: []const [*:0]const u8, context: *failure.Context) !void {
    var after_revision: u64 = 0;
    var history_offset: u32 = 0;
    var format: enum { compact, text, rich } = .compact;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = std.mem.span(args[index]);
        if (std.mem.eql(u8, arg, "--text")) {
            if (format != .compact) return usage();
            format = .text;
        } else if (std.mem.eql(u8, arg, "--rich")) {
            if (format != .compact) return usage();
            format = .rich;
        } else if (std.mem.eql(u8, arg, "--after")) {
            index += 1;
            if (index == args.len) return usage();
            after_revision = std.fmt.parseInt(u64, std.mem.span(args[index]), 10) catch return usage();
        } else if (std.mem.eql(u8, arg, "--history-offset")) {
            index += 1;
            if (index == args.len) return usage();
            history_offset = std.fmt.parseInt(u32, std.mem.span(args[index]), 10) catch return usage();
        } else return usage();
    }
    var connection = try connect(init, target, context);
    defer connection.deinit();
    var output_buffer: [16 * 1024]u8 = undefined;
    var stdout = stdoutWriter(init, &output_buffer);
    if (format == .rich) {
        try cli.snapshot.requestRich(init.gpa, connection, &stdout.interface, after_revision, history_offset);
    } else {
        var value = try cli.snapshot.request(connection, init.gpa, after_revision, history_offset);
        defer value.deinit();
        if (format == .text)
            try cli.snapshot.emitText(&stdout.interface, &value)
        else
            try cli.snapshot.emitCompact(&stdout.interface, &value);
    }
    try stdout.interface.flush();
}

fn stateCommand(init: std.process.Init, target: InstanceTarget, args: []const [*:0]const u8, context: *failure.Context) !void {
    if (args.len != 0) return usage();
    var connection = try connect(init, target, context);
    defer connection.deinit();
    var output_buffer: [4096]u8 = undefined;
    var stdout = stdoutWriter(init, &output_buffer);
    try cli.state.emit(connection, &stdout.interface);
    try stdout.interface.flush();
}

fn bytesCommand(init: std.process.Init, target: InstanceTarget, args: []const [*:0]const u8, is_paste: bool, context: *failure.Context) !void {
    if (args.len != 1) return usage();
    const argument = std.mem.span(args[0]);
    var owned: ?[]u8 = null;
    defer if (owned) |bytes| init.gpa.free(bytes);
    const bytes: []const u8 = if (std.mem.eql(u8, argument, "--stdin")) blk: {
        var input_buffer: [4096]u8 = undefined;
        var stdin = std.Io.File.stdin().readerStreaming(init.io, &input_buffer);
        const value = try stdin.interface.allocRemaining(
            init.gpa,
            .limited(protocol.maximum_request_payload_bytes - 1),
        );
        owned = value;
        break :blk value;
    } else argument;

    var connection = try connect(init, target, context);
    defer connection.deinit();
    if (is_paste)
        try cli.actions.paste(connection, bytes)
    else
        try cli.actions.committedText(connection, bytes);
    try emitActionReceipt(init, if (is_paste) "paste" else "type");
}

fn keyCommand(init: std.process.Init, target: InstanceTarget, args: []const [*:0]const u8, context: *failure.Context) !void {
    if (args.len == 0) return usage();
    const key = try cli.actions.parseKey(std.mem.span(args[0]));
    var action: protocol.InputKeyAction = .press;
    var modifiers: u8 = 0;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = std.mem.span(args[index]);
        if (std.mem.eql(u8, arg, "--action")) {
            index += 1;
            if (index == args.len) return usage();
            action = try cli.actions.parseKeyAction(std.mem.span(args[index]));
        } else if (std.mem.eql(u8, arg, "--mods")) {
            index += 1;
            if (index == args.len) return usage();
            modifiers = try cli.actions.parseModifiers(std.mem.span(args[index]));
        } else return usage();
    }
    var connection = try connect(init, target, context);
    defer connection.deinit();
    switch (key) {
        .named => |value| try cli.actions.namedKey(connection, value, action, modifiers),
        .unicode => |value| try cli.actions.unicodeKey(connection, value, action, modifiers),
    }
    try emitActionReceipt(init, "key");
}

fn focusCommand(init: std.process.Init, target: InstanceTarget, args: []const [*:0]const u8, context: *failure.Context) !void {
    if (args.len != 1) return usage();
    var connection = try connect(init, target, context);
    defer connection.deinit();
    try cli.actions.focus(connection, try cli.actions.parseFocus(std.mem.span(args[0])));
    try emitActionReceipt(init, "focus");
}

fn resizeCommand(init: std.process.Init, target: InstanceTarget, args: []const [*:0]const u8, context: *failure.Context) !void {
    if (args.len != 2) return usage();
    const rows = std.fmt.parseInt(u16, std.mem.span(args[0]), 10) catch return usage();
    const columns = std.fmt.parseInt(u16, std.mem.span(args[1]), 10) catch return usage();
    var connection = try connect(init, target, context);
    defer connection.deinit();
    try cli.actions.resize(connection, rows, columns);
    try emitActionReceipt(init, "resize");
}

fn signalCommand(init: std.process.Init, target: InstanceTarget, args: []const [*:0]const u8, context: *failure.Context) !void {
    if (args.len != 1) return usage();
    var connection = try connect(init, target, context);
    defer connection.deinit();
    try cli.actions.signal(connection, try cli.actions.parseSignal(std.mem.span(args[0])));
    try emitActionReceipt(init, "signal");
}

fn emitActionReceipt(init: std.process.Init, operation: []const u8) !void {
    var output_buffer: [512]u8 = undefined;
    var stdout = stdoutWriter(init, &output_buffer);
    try cli.actions.emitReceipt(&stdout.interface, operation);
    try stdout.interface.flush();
}

fn usage() error{InvalidArguments} {
    return error.InvalidArguments;
}

fn printRootHelp(init: std.process.Init) !void {
    return printHelp(init, "Howl native terminal client\n\n" ++
        "usage:\n" ++
        "  howl instance COMMAND ...\n" ++
        "  howl server COMMAND ...\n" ++
        "  howl version\n" ++
        "  howl help instance\n" ++
        "  howl help server\n");
}

fn printInstanceHelp(init: std.process.Init) !void {
    return printHelp(init, "usage:\n" ++
        "  howl instance snapshot TARGET [--after REVISION] [--history-offset ROWS] [--text|--rich]\n" ++
        "  howl instance state TARGET\n" ++
        "  howl instance type TARGET TEXT|--stdin\n" ++
        "  howl instance paste TARGET TEXT|--stdin\n" ++
        "  howl instance key TARGET KEY|U+XXXX [--action press|repeat|release] [--mods ctrl+shift+...]\n" ++
        "  howl instance focus TARGET in|out\n" ++
        "  howl instance resize TARGET ROWS COLUMNS\n" ++
        "  howl instance signal TARGET hangup|interrupt|resize-notify|kill|terminate\n" ++
        "\n" ++
        "TARGET:\n" ++
        "  --server SERVER_ENDPOINT SERVER_ID SESSION_ID INSTANCE_ID\n");
}

fn printInstanceOperationHelp(init: std.process.Init, operation: []const u8) !void {
    const text = if (std.mem.eql(u8, operation, "snapshot"))
        "usage: howl instance snapshot TARGET [--after REVISION] [--history-offset ROWS] [--text|--rich]\n"
    else if (std.mem.eql(u8, operation, "state"))
        "usage: howl instance state TARGET\n"
    else if (std.mem.eql(u8, operation, "type"))
        "usage: howl instance type TARGET TEXT|--stdin\n"
    else if (std.mem.eql(u8, operation, "paste"))
        "usage: howl instance paste TARGET TEXT|--stdin\n"
    else if (std.mem.eql(u8, operation, "key"))
        "usage: howl instance key TARGET KEY|U+XXXX [--action press|repeat|release] [--mods ctrl+shift+...]\n"
    else if (std.mem.eql(u8, operation, "focus"))
        "usage: howl instance focus TARGET in|out\n"
    else if (std.mem.eql(u8, operation, "resize"))
        "usage: howl instance resize TARGET ROWS COLUMNS\n"
    else if (std.mem.eql(u8, operation, "signal"))
        "usage: howl instance signal TARGET hangup|interrupt|resize-notify|kill|terminate\n"
    else
        return error.InvalidArguments;
    try printHelp(init, text);
    return printHelp(init, "TARGET: --server SERVER_ENDPOINT SERVER_ID SESSION_ID INSTANCE_ID\n");
}

fn printHelp(init: std.process.Init, text: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = stdoutWriter(init, &buffer);
    try stdout.interface.writeAll(text);
    try stdout.interface.flush();
}
