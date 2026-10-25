//! Client for Server control and terminal-interaction streams.

const std = @import("std");
const transport = @import("client_transport");
const terminal_owner = @import("terminal_owner");
/// Terminal operations and observations after exact Server attachment.
pub const terminal = @import("terminal_client");
/// Pure Server control wire shared with the server model.
pub const protocol = @import("server_protocol");

/// Shared transport connection-stage vocabulary.
pub const ConnectStage = transport.ConnectStage;
/// Shared bounded transport connection diagnostic.
pub const ConnectDiagnostic = transport.ConnectDiagnostic;
/// Opaque cancellation wake owner from the shared transport.
pub const Interrupt = transport.Interrupt;
/// Owned cancellation capability from the shared transport.
pub const Cancellation = transport.Cancellation;

/// Reports transport, framing, decoding, connection-lifetime and typed Server rejection failures.
pub const Error = std.mem.Allocator.Error || transport.Error || protocol.HeaderError ||
    protocol.PayloadError || error{
    StaleServerIncarnation,
    ConnectionRetired,
    UnexpectedHandshakeFrame,
    UnexpectedFrame,
    Malformed,
    Unsupported,
    SessionNotFound,
    InstanceNotFound,
    NameExists,
    SessionCapacity,
    InstanceCapacity,
    CreateFailed,
    Unavailable,
    Internal,
};

/// Allocator-owned control frame payload.
pub const Frame = struct {
    allocator: std.mem.Allocator,
    kind: protocol.Kind,
    payload: []u8,

    /// Releases owned payload/storage or stream resources and retires this value.
    pub fn deinit(self: *Frame) void {
        self.allocator.free(self.payload);
        self.* = undefined;
    }
};

/// A selected occurrence, not endpoint discovery or authentication.
pub const Target = struct {
    endpoint: []const u8,
    server_id: u64,
    session_id: u64,
    instance_id: u64,
};

/// Establishes one complete dedicated attachment to an exact Server occurrence.
pub fn attach(allocator: std.mem.Allocator, target: Target, diagnostic: *ConnectDiagnostic, interrupt: ?*Interrupt) Error!*terminal.Connection {
    if (target.server_id == 0 or target.session_id == 0 or target.instance_id == 0) return error.InvalidPayload;
    const stream = try transport.Stream.connectCancelable(target.endpoint, diagnostic, interrupt);
    var server = try negotiateTransport(allocator, stream, diagnostic);
    defer server.deinit();
    return server.attachInstance(target.server_id, .{ .session_id = target.session_id, .instance_id = target.instance_id });
}

/// Owns one negotiated Server control stream and incarnation/revision facts.
const State = struct {
    allocator: std.mem.Allocator,
    stream: transport.Stream,
    server_id: u64,
    tree_revision: u64,
    live: bool = true,

    /// Opens and negotiates one Server control connection.
    pub fn connect(allocator: std.mem.Allocator, endpoint: []const u8) Error!State {
        var diagnostic: ConnectDiagnostic = .{};
        return connectDiagnosed(allocator, endpoint, &diagnostic);
    }

    /// Opens a control connection while recording bounded transport diagnostics.
    pub fn connectDiagnosed(
        allocator: std.mem.Allocator,
        endpoint: []const u8,
        diagnostic: *ConnectDiagnostic,
    ) Error!State {
        const stream = try transport.Stream.connectDiagnosed(endpoint, diagnostic);
        return completeControlTransport(allocator, stream, diagnostic);
    }

    /// Opens a control connection with explicit diagnostics and cancellation.
    pub fn connectCancelable(
        allocator: std.mem.Allocator,
        endpoint: []const u8,
        diagnostic: *ConnectDiagnostic,
        interrupt: ?*Interrupt,
    ) Error!State {
        const stream = try transport.Stream.connectCancelable(endpoint, diagnostic, interrupt);
        return completeControlTransport(allocator, stream, diagnostic);
    }

    /// Releases owned payload/storage or stream resources and retires this value.
    pub fn deinit(self: *State) void {
        self.retire();
    }

    fn retire(self: *State) void {
        if (self.live) self.stream.deinit();
        self.live = false;
    }

    /// Borrows this live control stream's readiness handle.
    pub fn readinessFd(self: *const State) error{ConnectionRetired}!transport.Handle {
        if (!self.live) return error.ConnectionRetired;
        return self.stream.readinessFd();
    }

    /// Creates an owned cancellation capability for this live stream.
    pub fn cancellation(self: *const State) error{ ConnectionRetired, SocketDuplicateFailed, SocketOptionFailed }!Cancellation {
        if (!self.live) return error.ConnectionRetired;
        return self.stream.cancellation();
    }

    /// Requests current Server incarnation and catalogue counts.
    pub fn status(self: *State) Error!protocol.Status {
        try self.controlReady();
        errdefer self.retire();
        try self.send(.status, &.{});
        var frame = try self.receive();
        defer frame.deinit();
        if (frame.kind != .status_snapshot) return error.UnexpectedFrame;
        const value = try protocol.decodeStatus(frame.payload);
        try self.acceptServer(value.server_id, value.tree_revision);
        return value;
    }

    /// Requests an owned catalogue snapshot newer than the supplied revision.
    pub fn observeTree(self: *State, after_revision: u64) Error!Tree {
        try self.controlReady();
        errdefer self.retire();
        var payload: [protocol.payload_bytes.observe_tree]u8 = undefined;
        protocol.encodeObserveTree(&payload, .{ .after_revision = after_revision });
        try self.send(.observe_tree, &payload);
        var frame = try self.receive();
        defer frame.deinit();
        if (frame.kind != .tree_snapshot) return error.UnexpectedFrame;
        var tree = try Tree.decode(self.allocator, frame.payload);
        errdefer tree.deinit();
        try self.acceptServer(tree.status.server_id, tree.status.tree_revision);
        return tree;
    }

    /// Creates a named Session and returns its Server-assigned identity.
    pub fn createSession(self: *State, name: []const u8) Error!u64 {
        var payload: [protocol.payload_bytes.create_session_header + protocol.maximum_session_name_bytes]u8 = undefined;
        const encoded = protocol.encodeCreateSession(&payload, .{ .name = name }) catch |failure| switch (failure) {
            // zig-audit: acknowledge unreachable
            // reason: The fixed Session-name buffer holds the prefix plus the maximum validated name.
            error.OutputTooSmall => unreachable,
            else => |err| return err,
        };
        const result = try self.requestResult(.create_session, encoded);
        return result.session_id;
    }

    /// Requests closure of the exact Session identity.
    pub fn closeSession(self: *State, session_id: u64) Error!void {
        var payload: [protocol.payload_bytes.session_identity]u8 = undefined;
        try protocol.encodeSessionIdentity(&payload, session_id);
        const result = try self.requestResult(.close_session, &payload);
        if (result.session_id != session_id or result.instance_id != 0) {
            self.retire();
            return error.UnexpectedFrame;
        }
    }

    /// Explicit Session selection and process/geometry request for a new Instance.
    pub const InstanceLaunch = struct {
        session_id: u64,
        shell: []const u8,
        command: ?[]const u8 = null,
        cwd: ?[]const u8 = null,
        rows: u16,
        columns: u16,
        history_rows: u16,
    };

    /// Requests one explicitly launched Instance and returns its exact identity.
    pub fn createInstance(self: *State, launch: InstanceLaunch) Error!protocol.InstanceIdentity {
        var payload: [protocol.maximum_request_payload_bytes]u8 = undefined;
        const encoded = protocol.encodeCreateInstance(&payload, .{
            .session_id = launch.session_id,
            .shell = launch.shell,
            .command = launch.command,
            .cwd = launch.cwd,
            .rows = launch.rows,
            .columns = launch.columns,
            .history_rows = launch.history_rows,
        }) catch |failure| switch (failure) {
            // zig-audit: acknowledge unreachable
            // reason: The request buffer is maximum_request_payload_bytes; validated launch fields plus their prefix fit that exact wire bound.
            error.OutputTooSmall => unreachable,
            else => |err| return err,
        };
        const result = try self.requestResult(.create_instance, encoded);
        if (result.session_id != launch.session_id) {
            self.retire();
            return error.UnexpectedFrame;
        }
        return .{ .session_id = result.session_id, .instance_id = result.instance_id };
    }

    /// Requests closure of the exact Session/Instance occurrence.
    pub fn closeInstance(self: *State, identity: protocol.InstanceIdentity) Error!void {
        var payload: [protocol.payload_bytes.instance_identity]u8 = undefined;
        try protocol.encodeInstanceIdentity(&payload, identity);
        const result = try self.requestResult(.close_instance, &payload);
        if (result.session_id != identity.session_id or result.instance_id != identity.instance_id) {
            self.retire();
            return error.UnexpectedFrame;
        }
    }

    /// Successful attach consumes this Connection and returns the same raw stream.
    /// Only local pre-send validation and complete typed rejection leave it usable.
    /// Any other failure after exchange begins retires/closes it; deinit is safe.
    pub fn attachInstance(self: *State, expected_server_id: u64, identity: protocol.InstanceIdentity) Error!*terminal.Connection {
        var payload: [protocol.payload_bytes.instance_identity]u8 = undefined;
        try protocol.encodeInstanceIdentity(&payload, identity);
        if (!self.live) return error.ConnectionRetired;
        if (expected_server_id == 0 or expected_server_id != self.server_id) {
            self.retire();
            return error.StaleServerIncarnation;
        }
        var reusable = false;
        errdefer if (!reusable) self.retire();
        var diagnostic: ConnectDiagnostic = .{};
        try self.stream.beginHandshake(&diagnostic);
        try self.send(.attach_instance, &payload);
        var frame = try self.receive();
        defer frame.deinit();
        if (frame.kind == .result) {
            const result = try protocol.decodeResult(frame.payload);
            if (result.request_kind != .attach_instance) return error.UnexpectedFrame;
            try self.acceptRevision(result.tree_revision);
            if (result.code == .ok) return error.UnexpectedFrame;
            try self.stream.finishHandshake(&diagnostic);
            reusable = true;
            try resultError(result.code);
            // zig-audit: acknowledge unreachable
            // reason: The preceding branch rejected ResultCode.ok; resultError returns an error for every remaining exhaustive result code.
            unreachable;
        }
        if (frame.kind != .attach_ready) return error.UnexpectedFrame;
        const ready = try protocol.decodeAttachReady(frame.payload);
        if (ready.server_id != expected_server_id) return error.StaleServerIncarnation;
        if (ready.session_id != identity.session_id or ready.instance_id != identity.instance_id)
            return error.UnexpectedFrame;
        try self.acceptRevision(ready.tree_revision);
        try self.stream.finishHandshake(&diagnostic);
        const connection = try terminal_owner.create(self.allocator, self.stream, ready);
        self.live = false;
        return connection;
    }

    fn requestResult(self: *State, kind: protocol.Kind, payload: []const u8) Error!protocol.Result {
        try self.controlReady();
        var reusable = false;
        defer if (!reusable) self.retire();
        try self.send(kind, payload);
        var frame = try self.receive();
        defer frame.deinit();
        if (frame.kind != .result) return error.UnexpectedFrame;
        const result = try protocol.decodeResult(frame.payload);
        if (result.request_kind != kind) return error.UnexpectedFrame;
        try self.acceptRevision(result.tree_revision);
        reusable = true;
        try resultError(result.code);
        return result;
    }

    // Choosing a control operation completes Server-only construction. Observe
    // may then long-poll indefinitely; attach completes its setup at attach_ready.
    fn controlReady(self: *State) Error!void {
        if (!self.live) return error.ConnectionRetired;
        var diagnostic: ConnectDiagnostic = .{};
        self.stream.finishHandshake(&diagnostic) catch |err| {
            self.retire();
            return err;
        };
    }

    fn send(self: *State, kind: protocol.Kind, payload: []const u8) Error!void {
        if (!self.live) return error.ConnectionRetired;
        if (payload.len > protocol.maximum_request_payload_bytes) return error.PayloadTooLarge;
        var header: [protocol.header_bytes]u8 = undefined;
        try protocol.encodeHeader(&header, .{ .kind = kind, .payload_len = @intCast(payload.len) });
        errdefer self.retire();
        try self.stream.write(&header);
        try self.stream.write(payload);
    }

    fn receive(self: *State) Error!Frame {
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

    fn acceptServer(self: *State, server_id: u64, revision: u64) Error!void {
        if (server_id != self.server_id or revision == 0) return error.UnexpectedFrame;
        self.tree_revision = revision;
    }

    fn acceptRevision(self: *State, revision: u64) Error!void {
        if (revision == 0) return error.UnexpectedFrame;
        self.tree_revision = revision;
    }
};

/// Opaque Server catalog/CRUD connection. One caller thread owns its I/O and
/// release; caller-owned Interrupt permits cancellation from another thread.
// zig-audit: acknowledge opaque_type
// reason: Control stream, allocator, incarnation and revision storage are private to the client owner.
pub const Connection = opaque {
    /// Validated process-launch inputs for one exact Session.
    pub const InstanceLaunch = State.InstanceLaunch;

    /// Opens a bounded Server control connection, complete at welcome.
    pub fn connect(allocator: std.mem.Allocator, endpoint: []const u8) Error!*Connection {
        return fromState(try State.connect(allocator, endpoint));
    }

    /// Opens control while recording bounded construction diagnostics.
    pub fn connectDiagnosed(allocator: std.mem.Allocator, endpoint: []const u8, diagnostic: *ConnectDiagnostic) Error!*Connection {
        return fromState(try State.connectDiagnosed(allocator, endpoint, diagnostic));
    }

    /// Opens control with a borrowed Interrupt lasting through connection release.
    pub fn connectCancelable(allocator: std.mem.Allocator, endpoint: []const u8, diagnostic: *ConnectDiagnostic, interrupt: ?*Interrupt) Error!*Connection {
        return fromState(try State.connectCancelable(allocator, endpoint, diagnostic, interrupt));
    }

    /// Releases this control connection once all calls have returned.
    pub fn deinit(self: *Connection) void {
        const state = stateOf(self);
        const alloc = state.allocator;
        state.retire();
        alloc.destroy(state);
    }

    /// Copies the negotiated Server incarnation.
    pub fn serverId(self: *const Connection) u64 {
        return constStateOf(self).server_id;
    }

    /// Copies the latest accepted catalog revision.
    pub fn treeRevision(self: *const Connection) u64 {
        return constStateOf(self).tree_revision;
    }

    /// Borrows the live control descriptor for readiness polling.
    pub fn readinessFd(self: *const Connection) error{ConnectionRetired}!transport.Handle {
        return constStateOf(self).readinessFd();
    }

    /// Creates an independent capability to wake blocked I/O.
    pub fn cancellation(self: *const Connection) error{ ConnectionRetired, SocketDuplicateFailed, SocketOptionFailed }!Cancellation {
        return constStateOf(self).cancellation();
    }

    /// Queries current Server status.
    pub fn status(self: *Connection) Error!protocol.Status {
        return stateOf(self).status();
    }

    /// Owns one decoded catalog, independently released with Tree.deinit.
    pub fn observeTree(self: *Connection, after_revision: u64) Error!Tree {
        return stateOf(self).observeTree(after_revision);
    }

    /// Creates a logical Session without starting a terminal.
    pub fn createSession(self: *Connection, name: []const u8) Error!u64 {
        return stateOf(self).createSession(name);
    }

    /// Explicitly closes a Session and its Instance lifetimes.
    pub fn closeSession(self: *Connection, session_id: u64) Error!void {
        return stateOf(self).closeSession(session_id);
    }

    /// Explicitly launches one Instance in an exact Session.
    pub fn createInstance(self: *Connection, launch: InstanceLaunch) Error!protocol.InstanceIdentity {
        return stateOf(self).createInstance(launch);
    }

    /// Explicitly ends one exact Instance lifetime.
    pub fn closeInstance(self: *Connection, identity: protocol.InstanceIdentity) Error!void {
        return stateOf(self).closeInstance(identity);
    }
};

fn fromState(value: State) Error!*Connection {
    var owned = value;
    errdefer owned.retire();
    const state = try owned.allocator.create(State);
    state.* = owned;
    // zig-audit: acknowledge ptr_cast
    // reason: This exact State allocation exclusively backs the returned opaque control handle.
    return @ptrCast(state);
}

/// Private-module storage borrow for construction and hostile integration proofs.
pub fn stateOf(connection: *Connection) *State {
    // zig-audit: acknowledge ptr_cast
    // reason: The opaque Connection preserves fromState's exact live State allocation.
    // zig-audit: acknowledge align_cast
    // reason: fromState allocated State at its native alignment and preserved its address.
    return @ptrCast(@alignCast(connection));
}

fn constStateOf(connection: *const Connection) *const State {
    // zig-audit: acknowledge ptr_cast
    // reason: The const opaque handle borrows fromState's exact allocation without lending mutation.
    // zig-audit: acknowledge align_cast
    // reason: The handle retains the native State alignment supplied by its allocator.
    return @ptrCast(@alignCast(connection));
}

/// Private fixture/setup constructor; consumes the stream on every return path.
pub fn create(allocator: std.mem.Allocator, stream: transport.Stream, server_id: u64, tree_revision: u64) Error!*Connection {
    std.debug.assert(server_id != 0 and tree_revision != 0);
    return fromState(.{ .allocator = allocator, .stream = stream, .server_id = server_id, .tree_revision = tree_revision });
}

/// Private already-owned stream negotiation used by construction proofs.
pub fn connectTransport(allocator: std.mem.Allocator, stream: transport.Stream, diagnostic: *ConnectDiagnostic) Error!*Connection {
    return fromState(try negotiateTransport(allocator, stream, diagnostic));
}

/// Private setup handoff; public catalog handles expose no attachment mutation.
pub fn attachInstance(connection: *Connection, expected_server_id: u64, identity: protocol.InstanceIdentity) Error!*terminal.Connection {
    return stateOf(connection).attachInstance(expected_server_id, identity);
}

/// Allocator-owned decoded Session catalogue.
pub const Tree = struct {
    allocator: std.mem.Allocator,
    status: protocol.Status,
    sessions: []Session,

    /// Borrowed name and Instance slice within an owned Tree.
    pub const Session = struct {
        id: u64,
        name: []u8,
        instances: []protocol.InstanceRecord,
    };

    /// Releases owned payload/storage or stream resources and retires this value.
    pub fn deinit(self: *Tree) void {
        for (self.sessions) |session| {
            self.allocator.free(session.instances);
            self.allocator.free(session.name);
        }
        self.allocator.free(self.sessions);
        self.* = undefined;
    }

    fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!Tree {
        var decoder = try protocol.TreeDecoder.init(bytes);
        const sessions = try allocator.alloc(Session, decoder.header.session_count);
        var initialized: usize = 0;
        errdefer {
            for (sessions[0..initialized]) |session| {
                allocator.free(session.instances);
                allocator.free(session.name);
            }
            allocator.free(sessions);
        }
        while (initialized < sessions.len) : (initialized += 1) {
            const decoded = (try decoder.nextSession()) orelse return error.UnexpectedFrame;
            const name = try allocator.dupe(u8, decoded.name);
            errdefer allocator.free(name);
            const instances = try allocator.alloc(protocol.InstanceRecord, decoded.instance_count);
            errdefer allocator.free(instances);
            for (instances) |*instance| instance.* = try decoder.nextInstance();
            sessions[initialized] = .{
                .id = decoded.session_id,
                .name = name,
                .instances = instances,
            };
        }
        if ((try decoder.nextSession()) != null) return error.UnexpectedFrame;
        return .{ .allocator = allocator, .status = decoder.header, .sessions = sessions };
    }
};

/// Constructs a control Connection from an already-owned transport stream.
fn negotiateTransport(
    allocator: std.mem.Allocator,
    stream_value: transport.Stream,
    diagnostic: *ConnectDiagnostic,
) Error!State {
    var stream = stream_value;
    errdefer stream.deinit();
    try stream.beginHandshake(diagnostic);
    diagnostic.stage = .hello_write;
    var hello: [protocol.header_bytes]u8 = undefined;
    try protocol.encodeHeader(&hello, .{ .kind = .hello, .payload_len = 0 });
    try stream.handshakeWrite(&hello);
    diagnostic.stage = .welcome_read;
    var header_bytes: [protocol.header_bytes]u8 = undefined;
    try stream.handshakeRead(&header_bytes);
    const header = try protocol.decodeHeader(&header_bytes);
    if (header.kind != .welcome) {
        diagnostic.stage = .welcome_kind;
        return error.UnexpectedHandshakeFrame;
    }
    diagnostic.stage = .welcome_payload;
    if (header.payload_len != protocol.payload_bytes.welcome) return error.InvalidPayload;
    var payload: [protocol.payload_bytes.welcome]u8 = undefined;
    try stream.handshakeRead(&payload);
    const status = try protocol.decodeStatus(&payload);
    diagnostic.stage = .ready;
    return .{
        .allocator = allocator,
        .stream = stream,
        .server_id = status.server_id,
        .tree_revision = status.tree_revision,
    };
}

fn completeControlTransport(
    allocator: std.mem.Allocator,
    stream: transport.Stream,
    diagnostic: *ConnectDiagnostic,
) Error!State {
    var connection = try negotiateTransport(allocator, stream, diagnostic);
    errdefer connection.deinit();
    try connection.stream.finishHandshake(diagnostic);
    return connection;
}

test "control construction ends its deadline at welcome instead of the first operation" {
    var fds: [2]std.posix.fd_t = undefined;
    const result = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(result));
    var peer = transport.Stream{ .fd = fds[1] };
    defer peer.deinit();
    var diagnostic: ConnectDiagnostic = .{};
    const stream = try transport.Stream.adopt(fds[0], &diagnostic, null);
    var header: [protocol.header_bytes]u8 = undefined;
    try protocol.encodeHeader(&header, .{ .kind = .welcome, .payload_len = protocol.payload_bytes.welcome });
    var payload: [protocol.payload_bytes.welcome]u8 = undefined;
    try protocol.encodeStatus(&payload, .{
        .server_id = 91,
        .tree_revision = 1,
        .session_count = 0,
        .instance_count = 0,
    });
    try peer.write(&header);
    try peer.write(&payload);
    var connection = try completeControlTransport(std.testing.allocator, stream, &diagnostic);
    defer connection.deinit();
    try std.testing.expectEqual(@as(u64, 91), connection.server_id);
    try std.testing.expect(connection.stream.handshake_deadline_ms == null);
    try std.testing.expectEqual(ConnectStage.ready, diagnostic.stage);
}

fn resultError(code: protocol.ResultCode) Error!void {
    return switch (code) {
        .ok => {},
        .malformed => error.Malformed,
        .unsupported => error.Unsupported,
        .session_not_found => error.SessionNotFound,
        .instance_not_found => error.InstanceNotFound,
        .name_exists => error.NameExists,
        .session_capacity => error.SessionCapacity,
        .instance_capacity => error.InstanceCapacity,
        .create_failed => error.CreateFailed,
        .unavailable => error.Unavailable,
        .internal => error.Internal,
    };
}

test "cancelable Server connect is preempted before transport creation" {
    const interrupt = try Interrupt.init(std.testing.allocator);
    defer interrupt.deinit();
    try interrupt.cancel();
    var diagnostic: ConnectDiagnostic = .{};
    try std.testing.expectError(
        error.ConnectionCanceled,
        Connection.connectCancelable(
            std.testing.allocator,
            "tcp://127.0.0.1:1",
            &diagnostic,
            interrupt,
        ),
    );
    try std.testing.expectEqual(ConnectStage.endpoint, diagnostic.stage);
}

test "opaque control allocation failure closes its already-owned stream" {
    var pair: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair)));
    var peer = transport.Stream{ .fd = pair[1] };
    defer peer.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, create(failing.allocator(), .{ .fd = pair[0] }, 91, 1));
    try std.testing.expectEqual(std.posix.E.BADF, std.posix.errno(std.posix.system.fcntl(pair[0], std.posix.F.GETFD, @as(usize, 0))));
}
