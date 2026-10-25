//! Owns one explicit connection to the frozen Howl Instance byte stream.
//!
//! Endpoint selection is supplied by the caller. Ordered-stream mechanics are
//! private to the Server family; terminal frame kinds belong to its attachment phase.

const std = @import("std");
const posix = std.posix;
const server_protocol = @import("server_protocol");
const protocol = server_protocol.terminal;
const transport = @import("client_transport");

/// Exact native transport setup stage used by connection diagnostics.
pub const ConnectStage = transport.ConnectStage;
/// Bounded transport diagnostic retained across Instance handshake setup.
pub const ConnectDiagnostic = transport.ConnectDiagnostic;
/// Independently owned duplicate used to wake one blocked connection receive.
pub const Cancellation = transport.Cancellation;
/// Caller-owned interrupt token that can cancel connection setup and I/O.
pub const Interrupt = transport.Interrupt;
/// Reports allocation, transport, framing, payload, and handshake failures.
pub const Error = std.mem.Allocator.Error || transport.Error || protocol.HeaderError || protocol.PayloadError || error{
    ConnectionRetired,
};

/// Owns one decoded Server terminal frame payload.
pub const Frame = struct {
    allocator: std.mem.Allocator,
    kind: protocol.Kind,
    payload: []u8,

    /// Releases this frame's owned payload bytes.
    pub fn deinit(self: *Frame) void {
        self.allocator.free(self.payload);
        self.* = undefined;
    }
};

/// Opaque owner of one dedicated Server attachment. Calls use one caller-owned
/// I/O thread; an Interrupt may wake it from another thread. Release once after
/// outstanding calls return. Identity survives stream retirement until release.
// zig-audit: acknowledge opaque_type
// reason: Client stream, allocator and attachment identity storage cannot be constructed or mutated through the public handle.
pub const Connection = opaque {
    /// Detaches this client and releases its storage, leaving the Instance alive.
    pub fn deinit(self: *Connection) void {
        const state = stateOf(self);
        const alloc = state.allocator;
        state.retire();
        alloc.destroy(state);
    }

    /// Copies the complete accepted Server/Session/Instance/client identity.
    pub fn identity(self: *const Connection) server_protocol.AttachReady {
        return constStateOf(self).ready;
    }

    /// Borrows the live stream handle for polling or a protocol-blind bridge.
    pub fn readinessFd(self: *const Connection) error{ConnectionRetired}!transport.Handle {
        return constStateOf(self).readinessFd();
    }

    /// Creates a separately owned capability to wake blocked I/O.
    pub fn cancellation(self: *const Connection) error{ ConnectionRetired, SocketDuplicateFailed, SocketOptionFailed }!Cancellation {
        return constStateOf(self).cancellation();
    }

    /// Sends one bounded terminal request; exchange failures retire this stream.
    pub fn send(self: *Connection, kind: protocol.Kind, payload: []const u8) Error!void {
        return stateOf(self).send(kind, payload);
    }

    /// Borrows caller storage for one exact frame; any failure retires the stream.
    pub fn receiveInto(self: *Connection, kind: protocol.Kind, output: []u8) Error!usize {
        return stateOf(self).receiveInto(kind, output);
    }

    /// Returns one independently owned frame; any failure retires the stream.
    pub fn receive(self: *Connection) Error!Frame {
        return stateOf(self).receive();
    }
};

/// Private-module construction after complete, validated Server admission.
/// Success transfers the stream; allocation/validation failure retains caller ownership.
pub fn create(allocator: std.mem.Allocator, stream: transport.Stream, ready: server_protocol.AttachReady) Error!*Connection {
    if (ready.server_id == 0 or ready.session_id == 0 or ready.instance_id == 0 or ready.tree_revision == 0 or ready.client_id == 0)
        return error.InvalidPayload;
    const state = try allocator.create(State);
    state.* = .{ .allocator = allocator, .stream = stream, .ready = ready };
    // zig-audit: acknowledge ptr_cast
    // reason: This exact State allocation is the sole backing storage for the returned opaque Connection handle.
    return @ptrCast(state);
}

/// Borrows internal storage only inside the private client-module graph and proofs.
pub fn stateOf(connection: *Connection) *State {
    // zig-audit: acknowledge ptr_cast
    // reason: Connection originates from create's exact State allocation and remains live until its one deinit.
    // zig-audit: acknowledge align_cast
    // reason: create allocated State with its native alignment; the opaque conversion preserves that address.
    return @ptrCast(@alignCast(connection));
}

fn constStateOf(connection: *const Connection) *const State {
    // zig-audit: acknowledge ptr_cast
    // reason: This const opaque handle borrows the exact State allocation created above without lending mutation.
    // zig-audit: acknowledge align_cast
    // reason: create allocated State at its native alignment and the handle preserves that address.
    return @ptrCast(@alignCast(connection));
}

/// Private allocator access for terminal operations; not exported by the public root.
pub fn ownerAllocator(connection: *const Connection) std.mem.Allocator {
    return constStateOf(connection).allocator;
}

/// Retires invalid terminal exchanges while preserving the handle until release.
pub fn retire(connection: *Connection) void {
    stateOf(connection).retire();
}

/// Owns one established Server terminal connection and its canonical attached client id.
const State = struct {
    allocator: std.mem.Allocator,
    stream: transport.Stream,
    ready: server_protocol.AttachReady,
    live: bool = true,

    /// Closes the ordered stream and invalidates this connection owner.
    pub fn deinit(self: *State) void {
        self.retire();
    }

    fn retire(self: *State) void {
        if (self.live) self.stream.deinit();
        self.live = false;
    }

    /// Borrows the ordered stream descriptor for readiness polling only.
    pub fn readinessFd(self: *const State) error{ConnectionRetired}!transport.Handle {
        if (!self.live) return error.ConnectionRetired;
        return self.stream.readinessFd();
    }

    /// Creates an independently owned duplicate which may wake a blocked receive.
    pub fn cancellation(self: *const State) error{ ConnectionRetired, SocketDuplicateFailed, SocketOptionFailed }!Cancellation {
        if (!self.live) return error.ConnectionRetired;
        return self.stream.cancellation();
    }

    /// Sends one complete bounded Server terminal request frame.
    pub fn send(self: *State, kind: protocol.Kind, payload: []const u8) Error!void {
        if (!self.live) return error.ConnectionRetired;
        if (payload.len > protocol.maximum_request_payload_bytes) return error.PayloadTooLarge;
        var header: [protocol.header_bytes]u8 = undefined;
        try protocol.encodeHeader(&header, .{ .kind = kind, .payload_len = @intCast(payload.len) });
        errdefer self.retire();
        try self.stream.write(&header);
        try self.stream.write(payload);
    }

    /// Receives one nonempty frame of the expected kind into caller storage.
    /// Any error retires the stream; a partial body may already be consumed.
    pub fn receiveInto(self: *State, expected_kind: protocol.Kind, destination: []u8) Error!usize {
        if (!self.live) return error.ConnectionRetired;
        errdefer self.retire();
        var header_bytes: [protocol.header_bytes]u8 = undefined;
        try self.stream.read(&header_bytes);
        const header = try protocol.decodeHeader(&header_bytes);
        if (header.kind != expected_kind or header.payload_len == 0 or
            header.payload_len > destination.len)
            return error.InvalidPayload;
        try self.stream.read(destination[0..header.payload_len]);
        return header.payload_len;
    }

    /// Receives and owns one complete Server terminal frame.
    pub fn receive(self: *State) Error!Frame {
        if (!self.live) return error.ConnectionRetired;
        errdefer self.retire();
        var header_bytes: [protocol.header_bytes]u8 = undefined;
        try self.stream.read(&header_bytes);
        const header = try protocol.decodeHeader(&header_bytes);
        const payload = try self.allocator.alloc(u8, header.payload_len);
        errdefer self.allocator.free(payload);
        try self.stream.read(payload);
        return .{ .allocator = self.allocator, .kind = header.kind, .payload = payload };
    }
};

fn testReady(client_id: u64) server_protocol.AttachReady {
    return .{ .server_id = 1, .session_id = 1, .instance_id = 1, .tree_revision = 1, .client_id = client_id };
}

fn testSocketPair() [2]posix.fd_t {
    var pair: [2]posix.fd_t = undefined;
    const result = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &pair);
    // zig-audit: acknowledge panic
    // reason: This test-only helper cannot construct any meaningful fixture after socketpair creation fails.
    if (posix.errno(result) != .SUCCESS) @panic("test socketpair failed");
    return pair;
}

fn testClose(fd: posix.fd_t) void {
    const result = posix.system.close(fd);
    const status = posix.errno(result);
    std.debug.assert(status == .SUCCESS or status == .INTR);
}

fn testWriteAll(fd: posix.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const result = posix.system.write(fd, bytes[offset..].ptr, bytes.len - offset);
        switch (posix.errno(result)) {
            .SUCCESS => {
                if (result == 0 or result > bytes.len - offset) return error.TestWriteFailed;
                offset += result;
            },
            .INTR => continue,
            else => return error.TestWriteFailed,
        }
    }
}

const CancelReceiveProbe = struct {
    connection: *Connection,
    closed: bool = false,
};

fn testBlockedReceive(probe: *CancelReceiveProbe) void {
    var frame = probe.connection.receive() catch |failure| {
        probe.closed = failure == error.ConnectionClosed;
        return;
    };
    frame.deinit();
}

test "connection cancellation wakes blocked attachment receive while owner retains close" {
    const pair = testSocketPair();
    defer testClose(pair[1]);
    var connection = State{ .allocator = std.testing.allocator, .stream = .{ .fd = pair[0] }, .ready = testReady(72) };
    defer connection.deinit();
    var probe = CancelReceiveProbe{ .connection = &connection };
    const reader = try std.Thread.spawn(.{}, testBlockedReceive, .{&probe});
    var cancellation = try connection.cancellation();
    defer cancellation.deinit();
    try cancellation.cancel();
    reader.join();
    try std.testing.expect(probe.closed);
}

test "receiveInto rejects headers before touching caller storage" {
    const cases = [_]struct { kind: protocol.Kind, size: u32 }{
        .{ .kind = .image_end, .size = 4 },
        .{ .kind = .image_data, .size = 0 },
        .{ .kind = .image_data, .size = 9 },
        .{ .kind = .image_data, .size = protocol.image_data_chunk_bytes + 1 },
    };
    for (cases) |case| {
        const pair = testSocketPair();
        defer testClose(pair[1]);
        var connection = State{
            .allocator = std.testing.failing_allocator,
            .stream = .{ .fd = pair[0] },
            .ready = testReady(1),
        };
        defer connection.deinit();
        var header: [protocol.header_bytes]u8 = undefined;
        try protocol.encodeHeader(&header, .{ .kind = case.kind, .payload_len = case.size });
        try testWriteAll(pair[1], &header);
        var guarded: [10]u8 = @splat(0xa5);
        try std.testing.expectError(error.InvalidPayload, connection.receiveInto(.image_data, guarded[1..9]));
        try std.testing.expectEqualSlices(u8, &@as([10]u8, @splat(0xa5)), &guarded);
    }
}

test "receiveInto preserves protocol header errors without destination writes" {
    for (0..5) |case| {
        const pair = testSocketPair();
        defer testClose(pair[1]);
        var connection = State{
            .allocator = std.testing.failing_allocator,
            .stream = .{ .fd = pair[0] },
            .ready = testReady(1),
        };
        defer connection.deinit();
        var header: [protocol.header_bytes]u8 = undefined;
        try protocol.encodeHeader(&header, .{ .kind = .image_data, .payload_len = 1 });
        const expected: Error = switch (case) {
            0 => value: {
                header[0] = 0;
                break :value error.InvalidMagic;
            },
            1 => value: {
                header[4] = 0;
                break :value error.UnsupportedFramingVersion;
            },
            2 => value: {
                header[6] = 1;
                break :value error.InvalidReservedBits;
            },
            3 => value: {
                header[5] = 255;
                break :value error.UnknownKind;
            },
            else => value: {
                header[8] = 1;
                break :value error.PayloadTooLarge;
            },
        };
        try testWriteAll(pair[1], &header);
        var destination = [_]u8{0xa5};
        try std.testing.expectError(expected, connection.receiveInto(.image_data, &destination));
        try std.testing.expectEqual(@as(u8, 0xa5), destination[0]);
    }
}

const ReceiveIntoProbe = struct {
    connection: *Connection,
    result: ?Error = null,
    received: ?usize = null,
    bytes: [8]u8 = @splat(0xa5),
};

fn testBlockedReceiveInto(probe: *ReceiveIntoProbe) void {
    probe.received = probe.connection.receiveInto(.image_data, &probe.bytes) catch |failure| {
        probe.result = failure;
        return;
    };
}

fn testSetNonblocking(fd: posix.fd_t) !void {
    const current = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    if (posix.errno(current) != .SUCCESS) return error.TestFcntlFailed;
    const flag = @as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK");
    const updated = posix.system.fcntl(fd, posix.F.SETFL, @as(usize, @intCast(current)) | flag);
    if (posix.errno(updated) != .SUCCESS) return error.TestFcntlFailed;
}

test "receiveInto cancellation wakes blocked body and retains owner cleanup" {
    const pair = testSocketPair();
    defer testClose(pair[1]);
    const interrupt = try Interrupt.init(std.testing.allocator);
    defer interrupt.deinit();
    try testSetNonblocking(pair[0]);
    var connection = State{
        .allocator = std.testing.failing_allocator,
        .stream = .{ .fd = pair[0], .interrupt = interrupt },
        .ready = testReady(1),
    };
    defer connection.deinit();
    var header: [protocol.header_bytes]u8 = undefined;
    try protocol.encodeHeader(&header, .{ .kind = .image_data, .payload_len = 8 });
    try testWriteAll(pair[1], &header);
    var probe = ReceiveIntoProbe{ .connection = &connection };
    const worker = try std.Thread.spawn(.{}, testBlockedReceiveInto, .{&probe});
    defer worker.join();
    try std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake);
    try interrupt.cancel();
    try std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake);
    try std.testing.expectEqual(error.ConnectionCanceled, probe.result.?);
    try std.testing.expect(probe.received == null);
    try std.testing.expectEqualSlices(u8, &@as([8]u8, @splat(0xa5)), &probe.bytes);
}

fn testFragmentedFramePeer(fd: posix.fd_t) void {
    defer testClose(fd);
    var header: [protocol.header_bytes]u8 = undefined;
    // zig-audit: acknowledge catch_unreachable
    // reason: header has exactly protocol.header_bytes capacity and the fixed image-data payload length is protocol-valid.
    protocol.encodeHeader(&header, .{ .kind = .image_data, .payload_len = 3 }) catch unreachable;
    for (0..2) |_| {
        for (header) |byte| testWriteAll(fd, &.{byte}) catch return;
        for ("abc") |byte| testWriteAll(fd, &.{byte}) catch return;
    }
}

test "receiveInto accepts fragmented frames without allocation or crossing frame boundary" {
    const pair = testSocketPair();
    var connection = State{
        .allocator = std.testing.failing_allocator,
        .stream = .{ .fd = pair[0] },
        .ready = testReady(1),
    };
    defer connection.deinit();
    const worker = std.Thread.spawn(.{}, testFragmentedFramePeer, .{pair[1]}) catch |failure| {
        testClose(pair[1]);
        return failure;
    };
    defer worker.join();
    for (0..2) |_| {
        var guarded: [10]u8 = @splat(0xa5);
        try std.testing.expectEqual(@as(usize, 3), try connection.receiveInto(.image_data, guarded[1..9]));
        try std.testing.expectEqualStrings("abc", guarded[1..4]);
        try std.testing.expectEqual(@as(u8, 0xa5), guarded[0]);
        for (guarded[4..]) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
    }
    var byte: [1]u8 = undefined;
    try std.testing.expectError(error.ConnectionClosed, connection.receiveInto(.image_data, &byte));
}

test "opaque attachment allocation failure leaves the admitted stream with caller" {
    const pair = testSocketPair();
    defer testClose(pair[0]);
    defer testClose(pair[1]);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, create(failing.allocator(), .{ .fd = pair[0] }, testReady(7)));
    try std.testing.expectEqual(posix.E.SUCCESS, posix.errno(posix.system.fcntl(pair[0], posix.F.GETFD, @as(usize, 0))));
}
