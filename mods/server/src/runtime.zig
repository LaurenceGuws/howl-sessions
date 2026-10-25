//! Foreground Server runtime: one listener, one Server tree, many Instances.
//!
//! Runtime owns listener/scheduling only. Server owns orchestration state; Session
//! remains lifecycle identity/labeling; each Instance owns its own PTY/VT geometry
//! Server owns terminal interaction services. Runtime owns no terminal grid or client layout.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const model = @import("server_model");
const control = @import("server_service");

const maximum_accepts_per_turn: usize = 16;
/// Maximum idle poll interval for the Server scheduler.
pub const scheduler_wait_ms: i32 = 20;
const idle_wait_ms: i32 = 1000;
const TcpIpv4 = struct {
    address: [4]u8,
    port: u16,
};

/// Explicit IPv4 TCP or Unix control-listener selection.
pub const ListenerSpec = union(enum) {
    unix: []const u8,
    tcp_loopback: u16,
    tcp_ipv4: TcpIpv4,
};

/// Reports an invalid explicit listener specification.
pub const ParseError = error{InvalidListener};

/// Parses supported explicit IPv4 TCP and Unix listener specifications.
pub fn parseListener(text: []const u8) ParseError!ListenerSpec {
    if (std.mem.startsWith(u8, text, "unix:")) {
        const path = text["unix:".len..];
        if (path.len < 2 or path[0] != '/') return error.InvalidListener;
        return .{ .unix = path };
    }
    if (std.mem.startsWith(u8, text, "tcp://")) {
        const endpoint = try parseTcpIpv4(text["tcp://".len..]);
        return .{ .tcp_ipv4 = endpoint };
    }
    if (std.mem.startsWith(u8, text, "tcp:")) {
        const port_text = text["tcp:".len..];
        if (port_text.len == 0) return error.InvalidListener;
        const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidListener;
        return .{ .tcp_loopback = port };
    }
    return error.InvalidListener;
}

fn parseTcpIpv4(text: []const u8) ParseError!TcpIpv4 {
    if (text.len == 0 or std.mem.indexOfAny(u8, text, "/?#") != null)
        return error.InvalidListener;
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return error.InvalidListener;
    if (colon == 0 or colon + 1 >= text.len or std.mem.indexOfScalar(u8, text[0..colon], ':') != null)
        return error.InvalidListener;
    const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return error.InvalidListener;
    if (port == 0) return error.InvalidListener;

    var address: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, text[0..colon], '.');
    var index: usize = 0;
    while (parts.next()) |part| : (index += 1) {
        if (index >= address.len or part.len == 0) return error.InvalidListener;
        address[index] = std.fmt.parseInt(u8, part, 10) catch return error.InvalidListener;
    }
    if (index != address.len or std.mem.eql(u8, &address, &.{ 0, 0, 0, 0 }))
        return error.InvalidListener;
    return .{ .address = address, .port = port };
}

/// Chooses a nonzero process incarnation identity from caller-owned randomness.
pub fn freshServerId(io: std.Io) u64 {
    while (true) {
        var bytes: [8]u8 = undefined;
        std.Io.random(io, &bytes);
        const value = std.mem.readInt(u64, &bytes, .little);
        if (value != 0) return value;
    }
}

const Listener = struct {
    fd: posix.fd_t,
    unix_path: [108]u8 = @splat(0),
    unix_path_len: u8 = 0,
    tcp_port: ?u16 = null,
    tcp_address: ?[4]u8 = null,
    unix_identity: ?PathIdentity = null,

    fn init(spec: ListenerSpec) !Listener {
        return switch (spec) {
            .unix => |path| blk: {
                if (path.len == 0 or path.len >= 108) return error.SocketPathTooLong;
                break :blk try listenUnix(path);
            },
            .tcp_loopback => |port| blk: {
                const address = [4]u8{ 127, 0, 0, 1 };
                const bound = try listenTcp(address, port);
                break :blk .{ .fd = bound.fd, .tcp_port = bound.port, .tcp_address = address };
            },
            .tcp_ipv4 => |endpoint| blk: {
                const bound = try listenTcp(endpoint.address, endpoint.port);
                break :blk .{
                    .fd = bound.fd,
                    .tcp_port = bound.port,
                    .tcp_address = endpoint.address,
                };
            },
        };
    }

    fn deinit(self: *Listener) void {
        if (self.unix_identity) |identity| identity.unlinkIfOwned(self.unix_path[0..self.unix_path_len]);
        closeFd(self.fd);
        self.* = undefined;
    }

    fn endpointText(self: *const Listener, output: []u8) ![]const u8 {
        if (self.tcp_port) |port| {
            // zig-audit: acknowledge orelse_unreachable
            // reason: Both TCP listener constructors initialize tcp_address and tcp_port together; a published TCP listener cannot lack its address.
            const address = self.tcp_address orelse unreachable;
            return std.fmt.bufPrint(
                output,
                "tcp://{d}.{d}.{d}.{d}:{d}",
                .{ address[0], address[1], address[2], address[3], port },
            );
        }
        return std.fmt.bufPrint(output, "unix:{s}", .{self.unix_path[0..self.unix_path_len]});
    }
};

/// Owns the control listener, optional orchestration model and scheduling lifetime.
pub const Runtime = struct {
    io: std.Io,
    listener: Listener,
    server: *model.Server,
    service: control.Service,
    wait_cursor: usize = 0,
    next_reconcile_ns: i96 = 0,

    /// Creates a listener and model for a caller-specified nonzero Server identity.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        inherited_environment: std.process.Environ,
        listener_spec: ListenerSpec,
        server_id: u64,
    ) !Runtime {
        const server = try model.Server.init(allocator, server_id);
        errdefer server.deinit();
        var listener = try Listener.init(listener_spec);
        errdefer listener.deinit();
        return .{
            .io = io,
            .listener = listener,
            .server = server,
            .service = control.Service.init(allocator, io, inherited_environment, server),
        };
    }

    /// Creates a runtime with a fresh nonzero incarnation identity.
    pub fn initFresh(
        allocator: std.mem.Allocator,
        io: std.Io,
        inherited_environment: std.process.Environ,
        listener_spec: ListenerSpec,
    ) !Runtime {
        return init(allocator, io, inherited_environment, listener_spec, freshServerId(io));
    }

    /// Closes control clients, model and listener resources in ownership order.
    pub fn deinit(self: *Runtime) void {
        self.service.deinit();
        self.listener.deinit();
        self.server.deinit();
        self.* = undefined;
    }

    /// Returns this runtime's Server incarnation identity.
    pub fn serverId(self: *const Runtime) u64 {
        return self.server.identity();
    }

    /// Formats the bound listener into caller-owned output storage.
    pub fn endpointText(self: *const Runtime, output: []u8) ![]const u8 {
        return self.listener.endpointText(output);
    }

    /// One bounded cooperative turn. Socket/PTy readiness shares one aggregate poll;
    /// Server terminal-client work and Instance timer/write work receive direct rotating turns.
    pub fn turn(self: *Runtime) !void {
        self.serviceAggregateReadiness(0) catch |err| switch (err) {
            error.SignalInterrupt => return,
            else => return err,
        };

        const revision_before_drain = self.server.treeRevision();
        try self.turnActiveInstances(0);
        if (self.service.clientCount() != 0 and
            self.server.treeRevision() != revision_before_drain)
            try self.service.turn(0);

        const instance_count: usize = self.server.turnInstanceCount();
        if (instance_count == 0) {
            self.serviceAggregateReadiness(idle_wait_ms) catch |err| switch (err) {
                error.SignalInterrupt => return,
                else => return err,
            };
            return;
        }

        const target = self.wait_cursor % instance_count;
        self.wait_cursor = (target + 1) % instance_count;
        const revision_before_wait = self.server.treeRevision();
        try self.turnNthActiveInstance(target, scheduler_wait_ms);
        if (self.service.clientCount() != 0 and
            self.server.treeRevision() != revision_before_wait)
            try self.service.turn(0);
    }

    /// Services the listener and bounded Instance work until runtime shutdown.
    pub fn run(self: *Runtime) !void {
        while (true) try self.turn();
    }

    const DormantOwner = struct {
        session_id: model.SessionId,
        instance_id: u64,
    };

    fn serviceAggregateReadiness(self: *Runtime, timeout_ms: i32) !void {
        const maximum_dormant = model.maximum_sessions * model.maximum_instances_per_session;
        const maximum_descriptors = 1 + control.Service.maximum_wait_descriptors + maximum_dormant;
        var descriptors: [maximum_descriptors]posix.pollfd = undefined;
        var owners: [maximum_dormant]DormantOwner = undefined;
        var descriptor_count: usize = 1;
        var control_descriptor_count: usize = 0;
        var owner_count: usize = 0;

        descriptors[0] = .{
            .fd = self.listener.fd,
            .events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR,
            .revents = 0,
        };

        var control_storage: [control.Service.maximum_wait_descriptors]control.Service.WaitDescriptor = undefined;
        const control_waits = self.service.snapshotWaitDescriptors(&control_storage);
        for (control_waits) |wait| {
            std.debug.assert(descriptor_count < descriptors.len);
            descriptors[descriptor_count] = .{
                .fd = wait.fd,
                .events = wait.events,
                .revents = 0,
            };
            descriptor_count += 1;
            control_descriptor_count += 1;
        }

        var sessions_storage: [model.maximum_sessions]model.SessionView = undefined;
        const sessions = self.server.snapshotSessions(&sessions_storage);
        for (sessions) |session| {
            var instances_storage: [model.maximum_instances_per_session]model.InstanceView = undefined;
            const instances = self.server.snapshotInstances(session.id, &instances_storage) orelse continue;
            for (instances) |instance| {
                const fd = try self.server.instanceWaitDescriptor(session.id, instance.id) orelse continue;
                std.debug.assert(owner_count < owners.len);
                std.debug.assert(descriptor_count < descriptors.len);
                owners[owner_count] = .{
                    .session_id = session.id,
                    .instance_id = instance.id,
                };
                descriptors[descriptor_count] = .{
                    .fd = fd,
                    .events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR,
                    .revents = 0,
                };
                owner_count += 1;
                descriptor_count += 1;
            }
        }

        const before_poll = std.Io.Clock.awake.now(self.io).toNanoseconds();
        // zig-audit: acknowledge catch_unreachable
        // reason: The positive ns_per_ms divisor and nonnegative bounded remaining duration cannot trigger divCeil's arithmetic errors.
        const remaining_ms = std.math.divCeil(i96, @max(0, self.next_reconcile_ns - before_poll), std.time.ns_per_ms) catch unreachable;
        const wait_ms: i32 = @intCast(@min(timeout_ms, remaining_ms));
        const timeout: posix.timespec = .{
            .sec = @divTrunc(wait_ms, 1000),
            .nsec = @rem(wait_ms, 1000) * std.time.ns_per_ms,
        };
        // Unlike poll's EINTR retry loop, ppoll lets the host observe termination
        // intent immediately. Repeated signals must not restart the idle wait.
        const ready = try posix.ppoll(descriptors[0..descriptor_count], &timeout, null);
        const now = std.Io.Clock.awake.now(self.io).toNanoseconds();
        const reconcile = now >= self.next_reconcile_ns;
        if (reconcile) self.next_reconcile_ns = now + idle_wait_ms * std.time.ns_per_ms;
        std.debug.assert(ready <= descriptor_count);
        // zig-audit: acknowledge unreachable
        // reason: The scheduler retains sole ownership of the live listener fd until run returns; POLLNVAL proves that lifetime was violated.
        if (descriptors[0].revents & posix.POLL.NVAL != 0) unreachable;

        var control_ready = false;
        if (descriptors[0].revents & posix.POLL.IN != 0) {
            self.acceptClients();
            control_ready = true;
        }
        for (descriptors[1 .. 1 + control_descriptor_count]) |descriptor| {
            if (descriptor.revents == 0) continue;
            std.debug.assert(descriptor.revents & posix.POLL.NVAL == 0);
            control_ready = true;
        }

        const revision_before_instances = self.server.treeRevision();
        const instance_base = 1 + control_descriptor_count;
        for (owners[0..owner_count], 0..) |owner, index| {
            const events = descriptors[instance_base + index].revents;
            // Leader exit need not make the PTY readable: a descendant may
            // retain the slave. Reconcile the bounded live set at housekeeping.
            if (events == 0 and !reconcile) continue;
            std.debug.assert(events & posix.POLL.NVAL == 0);
            try self.server.turnInstance(owner.session_id, owner.instance_id, 0);
        }
        const tree_changed = self.server.treeRevision() != revision_before_instances;
        if (self.service.clientCount() != 0 and (control_ready or tree_changed))
            try self.service.turn(0);
    }

    fn acceptClients(self: *Runtime) void {
        var accepted_count: usize = 0;
        while (accepted_count < maximum_accepts_per_turn) : (accepted_count += 1) {
            const raw = linux.accept4(
                self.listener.fd,
                null,
                null,
                linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
            );
            switch (linux.errno(raw)) {
                .SUCCESS => {},
                .AGAIN => return,
                .INTR => continue,
                else => return,
            }
            const fd: posix.fd_t = @intCast(raw);
            if (self.listener.tcp_port != null) setTcpNoDelay(fd) catch {
                closeFd(fd);
                continue;
            };
            self.service.adoptClient(fd, &.{}) catch {
                closeFd(fd);
                continue;
            };
        }
    }

    fn turnActiveInstances(self: *Runtime, timeout_ms: i32) !void {
        var sessions_storage: [model.maximum_sessions]model.SessionView = undefined;
        const sessions = self.server.snapshotSessions(&sessions_storage);
        for (sessions) |session| {
            var instances_storage: [model.maximum_instances_per_session]model.InstanceView = undefined;
            const instances = self.server.snapshotInstances(session.id, &instances_storage) orelse continue;
            for (instances) |instance| {
                if (self.server.instanceRequiresTurn(session.id, instance.id) != true) continue;
                try self.server.turnInstance(session.id, instance.id, timeout_ms);
            }
        }
    }

    fn turnNthActiveInstance(self: *Runtime, target: usize, timeout_ms: i32) !void {
        var seen: usize = 0;
        var sessions_storage: [model.maximum_sessions]model.SessionView = undefined;
        const sessions = self.server.snapshotSessions(&sessions_storage);
        for (sessions) |session| {
            var instances_storage: [model.maximum_instances_per_session]model.InstanceView = undefined;
            const instances = self.server.snapshotInstances(session.id, &instances_storage) orelse continue;
            for (instances) |instance| {
                if (self.server.instanceRequiresTurn(session.id, instance.id) != true) continue;
                if (seen == target) return self.server.turnInstance(session.id, instance.id, timeout_ms);
                seen += 1;
            }
        }
        std.debug.assert(seen <= target);
    }
};

const TcpListener = struct {
    fd: posix.fd_t,
    port: u16,
};

fn listenTcp(address_bytes: [4]u8, requested_port: u16) !TcpListener {
    const raw = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
    if (linux.errno(raw) != .SUCCESS) return error.SocketCreateFailed;
    const fd: posix.fd_t = @intCast(raw);
    errdefer closeFd(fd);
    const enabled: c_int = 1;
    if (linux.errno(linux.setsockopt(
        fd,
        linux.SOL.SOCKET,
        linux.SO.REUSEADDR,
        // zig-audit: acknowledge ptr_cast
        // reason: SO_REUSEADDR consumes this live c_int through the syscall byte-buffer ABI for exactly this call.
        @ptrCast(&enabled),
        @sizeOf(c_int),
    )) != .SUCCESS) return error.SocketOptionFailed;

    var address = ipv4Address(address_bytes, requested_port);
    // zig-audit: acknowledge ptr_cast
    // reason: bind borrows this initialized concrete sockaddr through the generic syscall ABI for the supplied exact address length.
    if (linux.errno(linux.bind(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.in))) != .SUCCESS)
        return error.SocketBindFailed;
    if (linux.errno(linux.listen(fd, maximum_accepts_per_turn)) != .SUCCESS)
        return error.SocketListenFailed;

    var bound: linux.sockaddr.in = undefined;
    var length: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    // zig-audit: acknowledge ptr_cast
    // reason: getsockname writes into live sockaddr.in storage; its exact length and family are checked before publication.
    if (linux.errno(linux.getsockname(fd, @ptrCast(&bound), &length)) != .SUCCESS or
        length != @sizeOf(linux.sockaddr.in) or bound.family != linux.AF.INET)
        return error.SocketNameFailed;
    const expected = ipv4Address(address_bytes, 0);
    if (bound.addr != expected.addr) return error.SocketNameFailed;
    const port = std.mem.bigToNative(u16, bound.port);
    if (port == 0) return error.SocketNameFailed;
    return .{ .fd = fd, .port = port };
}

fn listenUnix(path: []const u8) !Listener {
    return completeUnix(try bindUnix(path));
}

fn bindUnix(path: []const u8) !Listener {
    const raw = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
    if (linux.errno(raw) != .SUCCESS) return error.SocketCreateFailed;
    const fd: posix.fd_t = @intCast(raw);
    errdefer closeFd(fd);

    var address: linux.sockaddr.un = undefined;
    const length = try unixAddress(path, &address);
    // zig-audit: acknowledge ptr_cast
    // reason: bind borrows this initialized concrete sockaddr through the generic syscall ABI for the supplied exact address length.
    if (linux.errno(linux.bind(fd, @ptrCast(&address), length)) != .SUCCESS) return error.SocketBindFailed;
    // If identity cannot be established, fail closed rather than unlinking an
    // entry we cannot prove is ours. The directory must be owner-controlled.
    const identity = try PathIdentity.read(path);
    var value = Listener{ .fd = fd, .unix_path_len = @intCast(path.len), .unix_identity = identity };
    @memcpy(value.unix_path[0..path.len], path);
    return value;
}

// Bound construction already owns both resources, including on chmod/listen
// failure. Completion and ordinary teardown use the same exact ownership test.
fn completeUnix(bound: Listener) !Listener {
    var value = bound;
    errdefer value.deinit();
    // zig-audit: acknowledge ptr_cast
    // reason: Listener construction copied the bounded path into zero-initialized storage, retaining a NUL byte for this chmod call.
    if (linux.errno(linux.chmod(@ptrCast(&value.unix_path), 0o600)) != .SUCCESS) return error.SocketModeFailed;
    if (linux.errno(linux.listen(value.fd, maximum_accepts_per_turn)) != .SUCCESS) return error.SocketListenFailed;
    return value;
}

fn unixAddress(path: []const u8, address: *linux.sockaddr.un) error{SocketPathTooLong}!linux.socklen_t {
    if (path.len == 0 or path.len >= address.path.len) return error.SocketPathTooLong;
    address.family = linux.AF.UNIX;
    @memset(&address.path, 0);
    @memcpy(address.path[0..path.len], path);
    return @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1);
}

fn ipv4Address(bytes: [4]u8, port: u16) linux.sockaddr.in {
    // zig-audit: acknowledge ptr_cast
    // reason: The four owned address bytes are read through an align(1) u32 view; no stronger alignment or longer lifetime is assumed.
    const address: *align(1) const u32 = @ptrCast(&bytes);
    return .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = address.*,
    };
}

// Server TCP is small interactive request/response traffic. Disable Nagle on
// every accepted TCP fd before protocol service ownership; relays/proxies that
// create additional TCP legs must apply the same policy to their own sockets.
fn setTcpNoDelay(fd: posix.fd_t) !void {
    const enabled: c_int = 1;
    if (linux.errno(linux.setsockopt(
        fd,
        linux.IPPROTO.TCP,
        linux.TCP.NODELAY,
        std.mem.asBytes(&enabled).ptr,
        @sizeOf(c_int),
    )) != .SUCCESS) return error.SocketOptionFailed;
}

fn closeFd(fd: posix.fd_t) void {
    const result = linux.close(fd);
    const errno = linux.errno(result);
    std.debug.assert(errno == .SUCCESS or errno == .INTR);
}

// The endpoint's containing directory must be owner-controlled. Identity checks
// protect replacement owners, not hostile rename races in a shared directory.
const PathIdentity = struct {
    device_major: u32,
    device_minor: u32,
    inode: u64,

    fn read(path: []const u8) !PathIdentity {
        var buffer: [109]u8 = @splat(0);
        @memcpy(buffer[0..path.len], path);
        var stat: linux.Statx = undefined;
        // zig-audit: acknowledge ptr_cast
        // reason: The bounded Unix path is copied into zero-initialized byte storage; this syscall borrows its live NUL-terminated address.
        if (linux.errno(linux.statx(linux.AT.FDCWD, @ptrCast(&buffer), linux.AT.SYMLINK_NOFOLLOW, .{ .INO = true, .TYPE = true }, &stat)) != .SUCCESS or
            !stat.mask.INO or !stat.mask.TYPE or stat.mode & linux.S.IFMT != linux.S.IFSOCK)
            return error.SocketIdentityFailed;
        return .{ .device_major = stat.dev_major, .device_minor = stat.dev_minor, .inode = stat.ino };
    }

    fn unlinkIfOwned(self: PathIdentity, path: []const u8) void {
        const current = read(path) catch return;
        if (!std.meta.eql(self, current)) return;
        var buffer: [109]u8 = @splat(0);
        @memcpy(buffer[0..path.len], path);
        // zig-audit: acknowledge ptr_cast
        // reason: The bounded Unix path is copied into zero-initialized byte storage; this syscall borrows its live NUL-terminated address.
        const result = linux.unlink(@ptrCast(&buffer));
        const errno = linux.errno(result);
        std.debug.assert(errno == .SUCCESS or errno == .NOENT);
    }
};

test "listener grammar has no terminal launch vocabulary" {
    try std.testing.expectEqualDeep(ListenerSpec{ .tcp_loopback = 0 }, try parseListener("tcp:0"));
    try std.testing.expectEqualDeep(
        ListenerSpec{ .tcp_ipv4 = .{ .address = .{ 100, 96, 0, 7 }, .port = 43150 } },
        try parseListener("tcp://100.96.0.7:43150"),
    );
    const unix = try parseListener("unix:/tmp/howl-server.sock");
    try std.testing.expectEqualStrings("/tmp/howl-server.sock", unix.unix);
    try std.testing.expectError(error.InvalidListener, parseListener("unix:relative.sock"));
    try std.testing.expectError(error.InvalidListener, parseListener("tcp:"));
    for ([_][]const u8{
        "tcp://0.0.0.0:43150",
        "tcp://100.96.0.7:0",
        "tcp://100.96.0.7",
        "tcp://100.96.0.999:43150",
        "tcp://localhost:43150",
    }) |bad| try std.testing.expectError(error.InvalidListener, parseListener(bad));
    try std.testing.expectError(error.InvalidListener, parseListener("/tmp/howl.sock"));
}

test "runtime owns one TCP listener and reports its resolved endpoint" {
    var runtime = try Runtime.init(
        std.testing.allocator,
        std.testing.io,
        std.testing.environ,
        .{ .tcp_loopback = 0 },
        0x1234,
    );
    defer runtime.deinit();
    var endpoint_buffer: [64]u8 = undefined;
    const endpoint = try runtime.endpointText(&endpoint_buffer);
    try std.testing.expect(std.mem.startsWith(u8, endpoint, "tcp://127.0.0.1:"));
    try std.testing.expectEqual(@as(u64, 0x1234), runtime.serverId());
    try std.testing.expectEqual(@as(u16, 0), runtime.server.sessionCount());
}

test "runtime accepted TCP client disables Nagle before service ownership" {
    var runtime = try Runtime.init(
        std.testing.allocator,
        std.testing.io,
        std.testing.environ,
        .{ .tcp_loopback = 0 },
        0x1234,
    );
    defer runtime.deinit();

    const raw = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(raw));
    const client_fd: posix.fd_t = @intCast(raw);
    defer closeFd(client_fd);
    var address = ipv4Address(.{ 127, 0, 0, 1 }, runtime.listener.tcp_port.?);
    try std.testing.expectEqual(
        linux.E.SUCCESS,
        // zig-audit: acknowledge ptr_cast
        // reason: This test-owned sockaddr is initialized for the exact TCP/Unix connect ABI and remains live throughout the call.
        linux.errno(linux.connect(client_fd, @ptrCast(&address), @sizeOf(linux.sockaddr.in))),
    );

    runtime.acceptClients();
    var descriptors: [control.Service.maximum_wait_descriptors]control.Service.WaitDescriptor = undefined;
    const active = runtime.service.snapshotWaitDescriptors(&descriptors);
    try std.testing.expectEqual(@as(usize, 1), active.len);
    var enabled: c_int = 0;
    var length: linux.socklen_t = @sizeOf(c_int);
    try std.testing.expectEqual(
        linux.E.SUCCESS,
        linux.errno(linux.getsockopt(
            active[0].fd,
            linux.IPPROTO.TCP,
            linux.TCP.NODELAY,
            std.mem.asBytes(&enabled).ptr,
            &length,
        )),
    );
    try std.testing.expectEqual(@as(linux.socklen_t, @sizeOf(c_int)), length);
    try std.testing.expectEqual(@as(c_int, 1), enabled);
}

test "runtime binds one explicit numeric IPv4 listener and reports that endpoint" {
    var runtime = try Runtime.init(
        std.testing.allocator,
        std.testing.io,
        std.testing.environ,
        .{ .tcp_ipv4 = .{ .address = .{ 127, 0, 0, 1 }, .port = 0 } },
        0x1234,
    );
    defer runtime.deinit();
    var endpoint_buffer: [64]u8 = undefined;
    const endpoint = try runtime.endpointText(&endpoint_buffer);
    try std.testing.expect(std.mem.startsWith(u8, endpoint, "tcp://127.0.0.1:"));
}

test "one attachment observation allocation failure cannot escape the multi-Instance runtime" {
    const protocol = @import("server_protocol").terminal;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var runtime = try Runtime.init(failing.allocator(), std.testing.io, std.testing.environ, .{ .tcp_loopback = 0 }, 42);
    defer runtime.deinit();
    const sid = try runtime.server.createSession("oom");
    const first = try runtime.server.createInstance(sid, std.testing.io, std.testing.environ, .{
        .shell = "/bin/sh",
        .command = "cat",
        .rows = 2,
        .columns = 8,
        .history_rows = 2,
    });
    const second = try runtime.server.createInstance(sid, std.testing.io, std.testing.environ, .{
        .shell = "/bin/sh",
        .command = "cat",
        .rows = 2,
        .columns = 8,
        .history_rows = 2,
    });
    var bad: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK, 0, &bad)));
    defer closeFd(bad[1]);
    var adopted = false;
    defer if (!adopted) closeFd(bad[0]);
    var observation: [protocol.header_bytes + protocol.payload_bytes.observe]u8 = undefined;
    try protocol.encodeHeader(observation[0..protocol.header_bytes], .{ .kind = .observe_raw, .payload_len = protocol.payload_bytes.observe });
    protocol.encodeObserve(observation[protocol.header_bytes..], .{});
    try runtime.server.adoptClient(sid, first, bad[0], &observation);
    adopted = true;
    failing.fail_index = failing.alloc_index;
    var failed_turns: usize = 0;
    while (!failing.has_induced_failure and failed_turns < 100) : (failed_turns += 1) try runtime.turn();
    try std.testing.expect(failing.has_induced_failure);
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(@as(u16, 2), runtime.server.instanceCountTotal());
    const wire = @import("server_protocol");
    var bad_ready: [wire.header_bytes + wire.payload_bytes.attach_ready]u8 = undefined;
    var drained: usize = 0;
    for (0..100) |_| {
        if (drained == bad_ready.len) break;
        const raw = linux.read(bad[1], bad_ready[drained..].ptr, bad_ready.len - drained);
        switch (linux.errno(raw)) {
            .SUCCESS => {
                try std.testing.expect(raw > 0 and raw <= bad_ready.len - drained);
                drained += raw;
            },
            .AGAIN, .INTR => try runtime.turn(),
            else => return error.TestReadFailed,
        }
    }
    try std.testing.expectEqual(bad_ready.len, drained);
    try std.testing.expectEqual(first, (try wire.decodeAttachReady(bad_ready[wire.header_bytes..])).instance_id);
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.read(bad[1], &byte, 1));

    var good: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK, 0, &good)));
    defer closeFd(good[1]);
    var good_adopted = false;
    defer if (!good_adopted) closeFd(good[0]);
    try runtime.server.adoptClient(sid, second, good[0], &.{});
    good_adopted = true;
    var frame: [wire.header_bytes + wire.payload_bytes.attach_ready]u8 = undefined;
    var received: usize = 0;
    var turns: usize = 0;
    while (received < frame.len and turns < 100) : (turns += 1) {
        try runtime.turn();
        const raw = linux.read(good[1], frame[received..].ptr, frame.len - received);
        switch (linux.errno(raw)) {
            .SUCCESS => {
                try std.testing.expect(raw > 0 and raw <= frame.len - received);
                received += raw;
            },
            .AGAIN, .INTR => {},
            else => return error.TestReadFailed,
        }
    }
    try std.testing.expectEqual(frame.len, received);
    try std.testing.expectEqual(wire.Kind.attach_ready, (try wire.decodeHeader(frame[0..wire.header_bytes])).kind);
    try std.testing.expectEqual(second, (try wire.decodeAttachReady(frame[wire.header_bytes..])).instance_id);
}

test "post-bind listen failure rolls back only its constructed Unix path" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    // AF_UNIX paths have a 108-byte limit. Keep the test socket names
    // relative to the test cwd so a deep checkout does not exhaust it.
    var path_buffer: [108]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}/u", .{ std.testing.TmpDir.parent_dir_path, &directory.sub_path });
    var peer_buffer: [108]u8 = undefined;
    const peer_path = try std.fmt.bufPrint(&peer_buffer, "{s}/{s}/p", .{ std.testing.TmpDir.parent_dir_path, &directory.sub_path });
    var peer = try listenUnix(peer_path);
    defer peer.deinit();
    var bound = try bindUnix(path);
    var owned = true;
    defer if (owned) bound.deinit();
    // A connected stream cannot become a listener. This forces a real listen
    // failure after successful bind/identity acquisition without a syscall mock.
    var address: linux.sockaddr.un = undefined;
    const length = try unixAddress(peer_path, &address);
    // zig-audit: acknowledge ptr_cast
    // reason: This test-owned sockaddr is initialized for the exact TCP/Unix connect ABI and remains live throughout the call.
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.connect(bound.fd, @ptrCast(&address), length)));
    owned = false; // completeUnix consumes construction, on success or failure.
    try std.testing.expectError(error.SocketListenFailed, completeUnix(bound));
    try std.testing.expectError(error.SocketIdentityFailed, PathIdentity.read(path));
    try std.testing.expectEqual(peer.unix_identity.?, try PathIdentity.read(peer_path));
}

test "Runtime owns one Server allocation with no wrapper allocation" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var runtime = try Runtime.init(counting.allocator(), std.testing.io, std.testing.environ, .{ .tcp_loopback = 0 }, 42);
    defer runtime.deinit();
    try std.testing.expectEqual(@as(usize, 1), counting.alloc_index);
    const view: *const model.Server = runtime.server;
    try std.testing.expectEqual(@as(u64, 42), view.identity());
    try std.testing.expectEqual(@as(u16, 0), view.sessionCount());
}
