//! Owns Howl Web's loopback origin, exact Server attach, then protocol-blind Server terminal byte bridge.
const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const server_client = @import("server_client");

const max_http_connections: u8 = 8;
const max_websockets: u8 = 6;
const max_http_header_bytes: usize = 32 * 1024;
const max_static_bytes: usize = 4 * 1024 * 1024;
const max_ws_message_bytes: usize = 64 * 1024;
const upstream_chunk_bytes: usize = 16 * 1024;
const max_host_bytes: usize = 255;
const max_origin_bytes: usize = 512;
const max_path_bytes: usize = 4096;

const Config = struct {
    listen_port: u16,
    server_port: u16,
    server_id: u64,
    session_id: u64,
    instance_id: u64,
    expected_host: []const u8,
    expected_origin: []const u8,
    site_dir: []const u8,
    wire_wasm: []const u8,
    require_access: bool,
};

const Headers = struct {
    host: ?[]const u8 = null,
    origin: ?[]const u8 = null,
    connection: ?[]const u8 = null,
    upgrade: ?[]const u8 = null,
    websocket_version: ?[]const u8 = null,
    websocket_key: ?[]const u8 = null,
    access_assertion: ?[]const u8 = null,
    duplicate_security_header: bool = false,
};

const ProxyEnd = enum {
    browser_closed,
    upstream_closed,
    browser_invalid,
    io_failure,
};

const StaticAsset = struct {
    relative_path: []const u8,
    content_type: []const u8,
};

const csp = "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; connect-src 'self'; style-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'";

/// Runs the bounded loopback HTTP/WebSocket gateway.
pub fn main(init: std.process.Init) !void {
    const config = parseArgs(init.minimal.args.vector) catch return usage(init);
    try serve(init, config);
}

fn usage(init: std.process.Init) void {
    var buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(init.io, &buffer);
    stderr.interface.writeAll(
        "usage: howl-web-gateway LISTEN_PORT SERVER_PORT SERVER_ID SESSION_ID INSTANCE_ID EXPECTED_HOST EXPECTED_ORIGIN SITE_DIR WIRE_WASM [--require-access]\n",
    ) catch return;
    stderr.interface.flush() catch return;
}

fn parseArgs(argv: []const [*:0]const u8) error{InvalidArguments}!Config {
    if (argv.len != 10 and argv.len != 11) return error.InvalidArguments;
    const listen_port = parsePort(std.mem.span(argv[1])) catch return error.InvalidArguments;
    const server_port = parsePort(std.mem.span(argv[2])) catch return error.InvalidArguments;
    const server_id = parseIdentity(std.mem.span(argv[3])) catch return error.InvalidArguments;
    const session_id = parseIdentity(std.mem.span(argv[4])) catch return error.InvalidArguments;
    const instance_id = parseIdentity(std.mem.span(argv[5])) catch return error.InvalidArguments;
    const expected_host = std.mem.span(argv[6]);
    const expected_origin = std.mem.span(argv[7]);
    const site_dir = std.mem.span(argv[8]);
    const wire_wasm = std.mem.span(argv[9]);
    if (expected_host.len == 0 or expected_host.len > max_host_bytes or
        expected_origin.len == 0 or expected_origin.len > max_origin_bytes or
        site_dir.len == 0 or site_dir.len > max_path_bytes or
        wire_wasm.len == 0 or wire_wasm.len > max_path_bytes or
        std.mem.indexOfAny(u8, expected_host, "\r\n\t ") != null or
        std.mem.indexOfAny(u8, expected_origin, "\r\n\t ") != null)
    {
        return error.InvalidArguments;
    }
    const require_access = if (argv.len == 11) blk: {
        if (!std.mem.eql(u8, std.mem.span(argv[10]), "--require-access")) return error.InvalidArguments;
        break :blk true;
    } else false;
    return .{
        .listen_port = listen_port,
        .server_port = server_port,
        .server_id = server_id,
        .session_id = session_id,
        .instance_id = instance_id,
        .expected_host = expected_host,
        .expected_origin = expected_origin,
        .site_dir = site_dir,
        .wire_wasm = wire_wasm,
        .require_access = require_access,
    };
}

fn parsePort(value: []const u8) error{InvalidPort}!u16 {
    const port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidPort;
    if (port == 0) return error.InvalidPort;
    return port;
}

fn parseIdentity(value: []const u8) error{InvalidIdentity}!u64 {
    const identity = std.fmt.parseInt(u64, value, 10) catch return error.InvalidIdentity;
    if (identity == 0) return error.InvalidIdentity;
    return identity;
}

fn serve(init: std.process.Init, config: Config) !void {
    const address = Io.net.IpAddress.parse("127.0.0.1", config.listen_port) catch return error.InvalidArguments;
    var listener = try address.listen(init.io, .{ .reuse_address = true });
    defer listener.deinit(init.io);
    var group: Io.Group = .init;
    defer group.cancel(init.io);
    var active_http = std.atomic.Value(u8).init(0);
    var active_ws = std.atomic.Value(u8).init(0);

    while (true) {
        var stream = try listener.accept(init.io);
        if (!admit(&active_http, max_http_connections)) {
            stream.close(init.io);
            continue;
        }
        group.concurrent(init.io, connectionTask, .{ init, config, stream, &active_http, &active_ws }) catch {
            release(&active_http);
            stream.close(init.io);
            continue;
        };
    }
}

fn setTcpNoDelay(fd: posix.socket_t) posix.SetSockOptError!void {
    const enabled: c_int = 1;
    try posix.setsockopt(
        fd,
        posix.IPPROTO.TCP,
        posix.TCP.NODELAY,
        std.mem.asBytes(&enabled),
    );
}

fn connectionTask(
    init: std.process.Init,
    config: Config,
    stream_value: Io.net.Stream,
    active_http: *std.atomic.Value(u8),
    active_ws: *std.atomic.Value(u8),
) Io.Cancelable!void {
    defer release(active_http);
    var stream = stream_value;
    defer stream.close(init.io);
    // zig-audit: acknowledge empty_catch
    // reason: Each failed connection is retired by the surrounding stream/slot defers; this task isolates one peer failure from the listener.
    handleConnection(init, config, &stream, active_ws) catch {};
}

fn handleConnection(init: std.process.Init, config: Config, stream: *Io.net.Stream, active_ws: *std.atomic.Value(u8)) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    var input_buffer: [max_http_header_bytes + max_ws_message_bytes + 32]u8 = undefined;
    var output_buffer: [32 * 1024]u8 = undefined;
    var input = stream.reader(init.io, &input_buffer);
    var output = stream.writer(init.io, &output_buffer);
    var server = std.http.Server.init(&input.interface, &output.interface);
    var request = server.receiveHead() catch return;
    if (request.head_buffer.len > max_http_header_bytes)
        return respondText(&request, .request_header_fields_too_large, "headers too large\n", "text/plain; charset=utf-8");
    if (request.head.method != .GET) return respondText(&request, .method_not_allowed, "GET only\n", "text/plain; charset=utf-8");

    const headers = collectHeaders(&request);
    if (headers.duplicate_security_header or headers.host == null or
        !std.mem.eql(u8, headers.host.?, config.expected_host))
    {
        return respondText(&request, .forbidden, "unexpected host\n", "text/plain; charset=utf-8");
    }
    if (config.require_access and (headers.access_assertion == null or headers.access_assertion.?.len == 0)) {
        return respondText(&request, .forbidden, "access assertion required\n", "text/plain; charset=utf-8");
    }

    if (std.mem.eql(u8, request.head.target, "/socket")) {
        try setTcpNoDelay(stream.socket.handle);
        return handleWebSocket(init, config, &request, headers, active_ws);
    }
    if (std.mem.eql(u8, request.head.target, "/health")) {
        return respondText(&request, .ok, "{\"status\":\"ok\"}\n", "application/json");
    }
    const asset = staticAsset(request.head.target) orelse
        return respondText(&request, .not_found, "not found\n", "text/plain; charset=utf-8");
    const source_path = if (std.mem.eql(u8, asset.relative_path, "@wire"))
        config.wire_wasm
    else
        try std.fs.path.join(allocator, &.{ config.site_dir, asset.relative_path });
    const bytes = Io.Dir.cwd().readFileAlloc(init.io, source_path, allocator, .limited(max_static_bytes)) catch
        return respondText(&request, .service_unavailable, "asset unavailable\n", "text/plain; charset=utf-8");
    return respondText(&request, .ok, bytes, asset.content_type);
}

fn collectHeaders(request: *const std.http.Server.Request) Headers {
    var out: Headers = .{};
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "host")) {
            captureHeader(&out.host, header.value, &out.duplicate_security_header);
        } else if (std.ascii.eqlIgnoreCase(header.name, "origin")) {
            captureHeader(&out.origin, header.value, &out.duplicate_security_header);
        } else if (std.ascii.eqlIgnoreCase(header.name, "connection")) {
            captureHeader(&out.connection, header.value, &out.duplicate_security_header);
        } else if (std.ascii.eqlIgnoreCase(header.name, "upgrade")) {
            captureHeader(&out.upgrade, header.value, &out.duplicate_security_header);
        } else if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-version")) {
            captureHeader(&out.websocket_version, header.value, &out.duplicate_security_header);
        } else if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-key")) {
            captureHeader(&out.websocket_key, header.value, &out.duplicate_security_header);
        } else if (std.ascii.eqlIgnoreCase(header.name, "cf-access-jwt-assertion")) {
            captureHeader(&out.access_assertion, header.value, &out.duplicate_security_header);
        }
    }
    return out;
}

fn captureHeader(slot: *?[]const u8, value: []const u8, duplicate: *bool) void {
    if (slot.* != null) {
        duplicate.* = true;
        return;
    }
    slot.* = value;
}

fn handleWebSocket(
    init: std.process.Init,
    config: Config,
    request: *std.http.Server.Request,
    headers: Headers,
    active_ws: *std.atomic.Value(u8),
) !void {
    if (request.head.version != .@"HTTP/1.1" or request.head.expect != null or
        request.head.content_length != null or request.head.transfer_encoding != .none or
        headers.origin == null or !std.mem.eql(u8, headers.origin.?, config.expected_origin) or
        headers.connection == null or !containsToken(headers.connection.?, "upgrade") or
        headers.upgrade == null or !std.ascii.eqlIgnoreCase(headers.upgrade.?, "websocket") or
        headers.websocket_version == null or !std.mem.eql(u8, headers.websocket_version.?, "13") or
        headers.websocket_key == null)
    {
        return respondText(request, .forbidden, "websocket policy rejected\n", "text/plain; charset=utf-8");
    }
    const key = headers.websocket_key.?;
    if (!validWebSocketKey(key)) return respondText(request, .bad_request, "invalid websocket key\n", "text/plain; charset=utf-8");
    if (!admit(active_ws, max_websockets)) return respondText(request, .service_unavailable, "websocket capacity\n", "text/plain; charset=utf-8");
    defer release(active_ws);

    // Do not connect to Server control until HTTP origin/authentication and the
    // complete WebSocket upgrade contract have passed. After exact attach, the same
    // fd is ordinary Server terminal and this gateway returns to protocol-blind byte pumping.
    var endpoint_storage: [64]u8 = undefined;
    const endpoint = std.fmt.bufPrint(
        &endpoint_storage,
        "tcp://127.0.0.1:{d}",
        .{config.server_port},
    ) catch return respondText(request, .service_unavailable, "upstream unavailable\n", "text/plain; charset=utf-8");
    var diagnostic: server_client.ConnectDiagnostic = .{};
    var attached = server_client.attach(init.gpa, .{
        .endpoint = endpoint,
        .server_id = config.server_id,
        .session_id = config.session_id,
        .instance_id = config.instance_id,
    }, &diagnostic, null) catch return respondText(request, .service_unavailable, "upstream unavailable\n", "text/plain; charset=utf-8");
    defer attached.deinit();
    // zig-audit: acknowledge catch_unreachable
    // reason: The fixed 127.0.0.1 literal is valid IPv4 and the port is already a u16; parsing cannot reject either.
    const upstream_address = Io.net.IpAddress.parse("127.0.0.1", config.server_port) catch unreachable;
    var upstream = Io.net.Stream{ .socket = .{
        .handle = try attached.readinessFd(),
        .address = upstream_address,
    } };

    var ws = request.respondWebSocket(.{ .key = key, .extra_headers = &.{
        .{ .name = "cache-control", .value = "no-store" },
    } }) catch return;
    try ws.flush();
    // Forward the same accepted ready state; the browser sends no second hello.
    const protocol = server_client.protocol;
    var ready_frame: [protocol.header_bytes + protocol.payload_bytes.attach_ready]u8 = undefined;
    try protocol.encodeHeader(ready_frame[0..protocol.header_bytes], .{ .kind = .attach_ready, .payload_len = protocol.payload_bytes.attach_ready });
    try protocol.encodeAttachReady(ready_frame[protocol.header_bytes..], attached.identity());
    try ws.writeMessage(&ready_frame, .binary);
    try ws.flush();
    var upstream_write_buffer: [upstream_chunk_bytes]u8 = undefined;
    var upstream_writer = upstream.writer(init.io, &upstream_write_buffer);

    const Completion = union(enum) { browser: ProxyEnd, upstream: ProxyEnd };
    var completions: [2]Completion = undefined;
    var select: Io.Select(Completion) = .init(init.io, &completions);
    defer select.cancelDiscard();
    select.concurrent(.browser, browserToUpstream, .{ &ws, &upstream_writer.interface }) catch return;
    select.concurrent(.upstream, upstreamToBrowser, .{ init.io, &upstream, &ws }) catch return;
    const completed = select.await() catch return;
    select.cancelDiscard();
    switch (completed) {
        .browser, .upstream => {},
    }
}

fn browserToUpstream(ws: *std.http.Server.WebSocket, upstream: *Io.Writer) ProxyEnd {
    while (true) {
        const message = ws.readSmallMessage() catch |failure| return switch (failure) {
            error.ConnectionClose, error.EndOfStream => .browser_closed,
            error.MessageOversize, error.MissingMaskBit, error.UnexpectedOpCode => .browser_invalid,
            error.ReadFailed => .io_failure,
        };
        if (message.opcode != .binary or message.data.len > max_ws_message_bytes) return .browser_invalid;
        upstream.writeAll(message.data) catch return .io_failure;
        upstream.flush() catch return .io_failure;
    }
}

fn upstreamToBrowser(io: Io, upstream: *Io.net.Stream, ws: *std.http.Server.WebSocket) ProxyEnd {
    var chunk: [upstream_chunk_bytes]u8 = undefined;
    while (true) {
        var buffers: [1][]u8 = .{&chunk};
        // Zig 0.17.0 Stream.read incorrectly destructures the named ReadResult.
        // This entry point performs the same read with an empty control buffer.
        const received = upstream.readWithControl(io, &buffers, &.{}) catch return .io_failure;
        const count = received.data_len;
        if (count == 0) return .upstream_closed;
        ws.writeMessage(chunk[0..count], .binary) catch return .io_failure;
    }
}

fn containsToken(value: []const u8, wanted: []const u8) bool {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), wanted)) return true;
    }
    return false;
}

fn validWebSocketKey(value: []const u8) bool {
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(value) catch return false;
    if (decoded_len != 16) return false;
    var decoded: [16]u8 = undefined;
    std.base64.standard.Decoder.decode(&decoded, value) catch return false;
    return true;
}

fn staticAsset(target: []const u8) ?StaticAsset {
    const Entry = struct { target: []const u8, asset: StaticAsset };
    const entries = [_]Entry{
        .{ .target = "/", .asset = .{ .relative_path = "index.html", .content_type = "text/html; charset=utf-8" } },
        .{ .target = "/host.mjs", .asset = .{ .relative_path = "host.mjs", .content_type = "text/javascript; charset=utf-8" } },
        .{ .target = "/frame_v3.mjs", .asset = .{ .relative_path = "frame_v3.mjs", .content_type = "text/javascript; charset=utf-8" } },
        .{ .target = "/frame_v4.mjs", .asset = .{ .relative_path = "frame_v4.mjs", .content_type = "text/javascript; charset=utf-8" } },
        .{ .target = "/webgl_backend.mjs", .asset = .{ .relative_path = "webgl_backend.mjs", .content_type = "text/javascript; charset=utf-8" } },
        .{ .target = "/webgl_backend_v3.mjs", .asset = .{ .relative_path = "webgl_backend_v3.mjs", .content_type = "text/javascript; charset=utf-8" } },
        .{ .target = "/webgl_backend_v4.mjs", .asset = .{ .relative_path = "webgl_backend_v4.mjs", .content_type = "text/javascript; charset=utf-8" } },
        .{ .target = "/input.mjs", .asset = .{ .relative_path = "input.mjs", .content_type = "text/javascript; charset=utf-8" } },
        .{ .target = "/pointer_input.mjs", .asset = .{ .relative_path = "pointer_input.mjs", .content_type = "text/javascript; charset=utf-8" } },
        .{ .target = "/history.mjs", .asset = .{ .relative_path = "history.mjs", .content_type = "text/javascript; charset=utf-8" } },
        .{ .target = "/selection.mjs", .asset = .{ .relative_path = "selection.mjs", .content_type = "text/javascript; charset=utf-8" } },
        .{ .target = "/control_queue.mjs", .asset = .{ .relative_path = "control_queue.mjs", .content_type = "text/javascript; charset=utf-8" } },
        .{ .target = "/telemetry.mjs", .asset = .{ .relative_path = "telemetry.mjs", .content_type = "text/javascript; charset=utf-8" } },
        .{ .target = "/frame_scheduler.mjs", .asset = .{ .relative_path = "frame_scheduler.mjs", .content_type = "text/javascript; charset=utf-8" } },
        .{ .target = "/display_schedule.mjs", .asset = .{ .relative_path = "display_schedule.mjs", .content_type = "text/javascript; charset=utf-8" } },
        .{ .target = "/resize_policy.mjs", .asset = .{ .relative_path = "resize_policy.mjs", .content_type = "text/javascript; charset=utf-8" } },
        .{ .target = "/lifecycle_policy.mjs", .asset = .{ .relative_path = "lifecycle_policy.mjs", .content_type = "text/javascript; charset=utf-8" } },
        .{ .target = "/style.css", .asset = .{ .relative_path = "style.css", .content_type = "text/css; charset=utf-8" } },
        .{ .target = "/runtime.mjs", .asset = .{ .relative_path = "runtime.mjs", .content_type = "text/javascript; charset=utf-8" } },
        .{ .target = "/render.wasm", .asset = .{ .relative_path = "render.wasm", .content_type = "application/wasm" } },
        .{ .target = "/font.bin", .asset = .{ .relative_path = "font.bin", .content_type = "application/octet-stream" } },
        .{ .target = "/fallback-font.bin", .asset = .{ .relative_path = "fallback-font.bin", .content_type = "application/octet-stream" } },
        .{ .target = "/nerd-font.bin", .asset = .{ .relative_path = "nerd-font.bin", .content_type = "application/octet-stream" } },
        .{ .target = "/wire.wasm", .asset = .{ .relative_path = "@wire", .content_type = "application/wasm" } },
        .{ .target = "/manifest.webmanifest", .asset = .{ .relative_path = "manifest.webmanifest", .content_type = "application/manifest+json" } },
        .{ .target = "/sw.js", .asset = .{ .relative_path = "sw.js", .content_type = "text/javascript; charset=utf-8" } },
        .{ .target = "/icon.png", .asset = .{ .relative_path = "icon.png", .content_type = "image/png" } },
        .{ .target = "/font-licences.txt", .asset = .{ .relative_path = "font-licences.txt", .content_type = "text/plain; charset=utf-8" } },
        .{ .target = "/nerd-font-license.txt", .asset = .{ .relative_path = "nerd-font-license.txt", .content_type = "text/plain; charset=utf-8" } },
        .{ .target = "/dependencies.txt", .asset = .{ .relative_path = "dependencies.txt", .content_type = "text/plain; charset=utf-8" } },
    };
    for (entries) |entry| if (std.mem.eql(u8, target, entry.target)) return entry.asset;
    return null;
}

fn respondText(request: *std.http.Server.Request, status: std.http.Status, body: []const u8, content_type: []const u8) !void {
    request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = content_type },
            .{ .name = "cache-control", .value = "no-store" },
            .{ .name = "content-security-policy", .value = csp },
            .{ .name = "x-content-type-options", .value = "nosniff" },
            .{ .name = "referrer-policy", .value = "no-referrer" },
        },
    }) catch return error.WriteFailed;
}

fn admit(active: *std.atomic.Value(u8), maximum: u8) bool {
    var observed = active.load(.acquire);
    while (observed < maximum) {
        if (active.cmpxchgWeak(observed, observed + 1, .acq_rel, .acquire)) |changed| {
            observed = changed;
            continue;
        }
        return true;
    }
    return false;
}

fn release(active: *std.atomic.Value(u8)) void {
    const previous = active.fetchSub(1, .release);
    std.debug.assert(previous > 0);
}

test "strict CLI bounds ports host and access mode" {
    const ok = [_][*:0]const u8{
        "gateway", "43129", "43130", "91", "7", "3", "howl.example.test", "https://howl.example.test", "/tmp/site", "/tmp/wire.wasm", "--require-access",
    };
    const config = try parseArgs(&ok);
    try std.testing.expectEqual(@as(u16, 43129), config.listen_port);
    try std.testing.expectEqual(@as(u16, 43130), config.server_port);
    try std.testing.expectEqual(@as(u64, 91), config.server_id);
    try std.testing.expectEqual(@as(u64, 7), config.session_id);
    try std.testing.expectEqual(@as(u64, 3), config.instance_id);
    try std.testing.expect(config.require_access);
    const bad_port = [_][*:0]const u8{ "gateway", "0", "43130", "91", "7", "3", "h", "https://h", "s", "w" };
    try std.testing.expectError(error.InvalidArguments, parseArgs(&bad_port));
    const bad_identity = [_][*:0]const u8{ "gateway", "1", "2", "91", "0", "3", "h", "https://h", "s", "w" };
    try std.testing.expectError(error.InvalidArguments, parseArgs(&bad_identity));
    const stale_grammar = [_][*:0]const u8{ "gateway", "1", "2", "7", "3", "h", "https://h", "s", "w" };
    try std.testing.expectError(error.InvalidArguments, parseArgs(&stale_grammar));
    const bad_mode = [_][*:0]const u8{ "gateway", "1", "2", "91", "7", "3", "h", "https://h", "s", "w", "--open" };
    try std.testing.expectError(error.InvalidArguments, parseArgs(&bad_mode));
}

test "connection and websocket admission is bounded and reusable" {
    var active = std.atomic.Value(u8).init(0);
    var count: u8 = 0;
    while (count < max_websockets) : (count += 1) try std.testing.expect(admit(&active, max_websockets));
    try std.testing.expect(!admit(&active, max_websockets));
    release(&active);
    try std.testing.expect(admit(&active, max_websockets));
    while (active.load(.acquire) != 0) release(&active);
}

test "websocket token and key validation fail closed" {
    try std.testing.expect(containsToken("keep-alive, Upgrade", "upgrade"));
    try std.testing.expect(!containsToken("keep-alive", "upgrade"));
    try std.testing.expect(validWebSocketKey("dGhlIHNhbXBsZSBub25jZQ=="));
    try std.testing.expect(!validWebSocketKey("not-base64"));
    try std.testing.expect(!validWebSocketKey("YQ=="));
}

test "static routes are closed and do not traverse the site root" {
    try std.testing.expectEqualStrings("index.html", staticAsset("/").?.relative_path);
    try std.testing.expectEqualStrings("@wire", staticAsset("/wire.wasm").?.relative_path);
    try std.testing.expectEqualStrings("fallback-font.bin", staticAsset("/fallback-font.bin").?.relative_path);
    try std.testing.expectEqualStrings("history.mjs", staticAsset("/history.mjs").?.relative_path);
    try std.testing.expectEqualStrings("lifecycle_policy.mjs", staticAsset("/lifecycle_policy.mjs").?.relative_path);
    try std.testing.expectEqualStrings("pointer_input.mjs", staticAsset("/pointer_input.mjs").?.relative_path);
    try std.testing.expectEqualStrings("webgl_backend.mjs", staticAsset("/webgl_backend.mjs").?.relative_path);
    try std.testing.expectEqualStrings("frame_v3.mjs", staticAsset("/frame_v3.mjs").?.relative_path);
    try std.testing.expectEqualStrings("frame_v4.mjs", staticAsset("/frame_v4.mjs").?.relative_path);
    try std.testing.expectEqualStrings("webgl_backend_v3.mjs", staticAsset("/webgl_backend_v3.mjs").?.relative_path);
    try std.testing.expectEqualStrings("webgl_backend_v4.mjs", staticAsset("/webgl_backend_v4.mjs").?.relative_path);
    try std.testing.expectEqualStrings("nerd-font.bin", staticAsset("/nerd-font.bin").?.relative_path);
    try std.testing.expectEqualStrings("nerd-font-license.txt", staticAsset("/nerd-font-license.txt").?.relative_path);
    try std.testing.expect(staticAsset("/../secret") == null);
    try std.testing.expect(staticAsset("/?x=1") == null);
}
