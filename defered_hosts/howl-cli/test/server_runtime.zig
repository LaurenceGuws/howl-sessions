const std = @import("std");
const runtime_mod = @import("server_runtime");
const server_client = @import("server_client");
const howl_client = @import("server_client").terminal;

const Pump = struct {
    runtime: *runtime_mod.Runtime,
    stop: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),

    fn run(self: *Pump) void {
        while (!self.stop.load(.acquire)) {
            self.runtime.turn() catch {
                self.failed.store(true, .release);
                return;
            };
        }
    }
};

fn connectServer(endpoint: []const u8) !*server_client.Connection {
    return server_client.Connection.connect(std.testing.allocator, endpoint);
}

fn attachInstance(
    endpoint: []const u8,
    identity: server_client.protocol.InstanceIdentity,
) !*howl_client.Connection {
    const control = try connectServer(endpoint);
    defer control.deinit();
    var diagnostic: server_client.ConnectDiagnostic = .{};
    return server_client.attach(std.testing.allocator, .{
        .endpoint = endpoint,
        .server_id = control.serverId(),
        .session_id = identity.session_id,
        .instance_id = identity.instance_id,
    }, &diagnostic, null);
}

test "one Server hosts independently-sized Instances without owning a shared grid" {
    var runtime = try runtime_mod.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        std.testing.environ,
        .{ .tcp_loopback = 0 },
        0xa11ce,
    );
    defer runtime.deinit();

    var endpoint_storage: [64]u8 = undefined;
    const endpoint = try runtime.endpointText(&endpoint_storage);

    var pump = Pump{ .runtime = &runtime };
    const worker = try std.Thread.spawn(.{}, Pump.run, .{&pump});
    defer {
        pump.stop.store(true, .release);
        worker.join();
        std.debug.assert(!pump.failed.load(.acquire));
    }

    var control = try connectServer(endpoint);
    defer control.deinit();
    const work = try control.createSession("work");
    const logs = try control.createSession("logs");
    const work_instance = try control.createInstance(.{
        .session_id = work,
        .shell = "/bin/sh",
        .command = "cat",
        .rows = 40,
        .columns = 100,
        .history_rows = 128,
    });
    const logs_instance = try control.createInstance(.{
        .session_id = logs,
        .shell = "/bin/sh",
        .command = "cat",
        .rows = 18,
        .columns = 72,
        .history_rows = 64,
    });

    var work_client = try attachInstance(endpoint, work_instance);
    defer work_client.deinit();
    var work_snapshot = try howl_client.snapshot.request(work_client, std.testing.allocator, 0, 0);
    defer work_snapshot.deinit();
    try std.testing.expectEqual(@as(u16, 40), work_snapshot.begin.terminal.rows);
    try std.testing.expectEqual(@as(u16, 100), work_snapshot.begin.terminal.columns);

    var logs_client = try attachInstance(endpoint, logs_instance);
    defer logs_client.deinit();
    var logs_snapshot = try howl_client.snapshot.request(logs_client, std.testing.allocator, 0, 0);
    defer logs_snapshot.deinit();
    try std.testing.expectEqual(@as(u16, 18), logs_snapshot.begin.terminal.rows);
    try std.testing.expectEqual(@as(u16, 72), logs_snapshot.begin.terminal.columns);

    var tree = try control.observeTree(0);
    defer tree.deinit();
    try std.testing.expectEqual(@as(u16, 2), tree.status.session_count);
    try std.testing.expectEqual(@as(u16, 2), tree.status.instance_count);
    try std.testing.expectEqual(@as(usize, 2), tree.sessions.len);
    // Tree state deliberately contains identity/lifecycle only, never terminal geometry.
    try std.testing.expectEqual(@as(usize, 1), tree.sessions[0].instances.len);
    try std.testing.expectEqual(@as(usize, 1), tree.sessions[1].instances.len);
}

test "quiescent exited Instance reactivates on later exact attach" {
    var runtime = try runtime_mod.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        std.testing.environ,
        .{ .tcp_loopback = 0 },
        0xe71ed,
    );
    defer runtime.deinit();

    var endpoint_storage: [64]u8 = undefined;
    const endpoint = try runtime.endpointText(&endpoint_storage);

    var first_pump = Pump{ .runtime = &runtime };
    const first_worker = try std.Thread.spawn(.{}, Pump.run, .{&first_pump});
    var first_running = true;
    defer if (first_running) {
        first_pump.stop.store(true, .release);
        first_worker.join();
    };

    var control = try connectServer(endpoint);
    const session_id = try control.createSession("retained");
    const identity = try control.createInstance(.{
        .session_id = session_id,
        .shell = "/bin/sh",
        .command = "printf 'EXITED_CANARY\\n'; exit 0",
        .rows = 6,
        .columns = 32,
        .history_rows = 16,
    });

    var exited = false;
    var attempts: usize = 0;
    while (attempts < 1_000 and !exited) : (attempts += 1) {
        var tree = try control.observeTree(0);
        defer tree.deinit();
        if (tree.sessions.len == 1 and tree.sessions[0].instances.len == 1)
            exited = tree.sessions[0].instances[0].state == .exited;
    }
    try std.testing.expect(exited);

    // Each request forces ordinary runtime turns while the control connection is
    // alive, giving trailing PTY/publication work a bounded chance to finish.
    var settle: usize = 0;
    while (settle < 32) : (settle += 1) {
        const status = try control.status();
        try std.testing.expectEqual(@as(u16, 1), status.instance_count);
    }
    control.deinit();

    first_pump.stop.store(true, .release);
    first_worker.join();
    first_running = false;
    try std.testing.expect(!first_pump.failed.load(.acquire));
    try std.testing.expect(runtime.server.instanceRequiresTurn(session_id, identity.instance_id) == false);

    var second_pump = Pump{ .runtime = &runtime };
    const second_worker = try std.Thread.spawn(.{}, Pump.run, .{&second_pump});
    defer {
        second_pump.stop.store(true, .release);
        second_worker.join();
        std.debug.assert(!second_pump.failed.load(.acquire));
    }

    var retained_client = try attachInstance(endpoint, identity);
    defer retained_client.deinit();
    var snapshot = try howl_client.snapshot.request(
        retained_client,
        std.testing.allocator,
        0,
        0,
    );
    defer snapshot.deinit();

    var found = false;
    for (snapshot.lines) |line| {
        if (std.mem.indexOf(u8, line, "EXITED_CANARY") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

const FairInput = struct {
    connection: *howl_client.Connection,
    marker: []const u8,
    failed: *std.atomic.Value(bool),

    fn run(self: FairInput) void {
        howl_client.actions.committedText(self.connection, self.marker) catch {
            self.failed.store(true, .release);
        };
    }
};

test "one Server fairly services several independent live Instances" {
    const count: usize = 8;
    const markers = [_][]const u8{
        "FAIR_0\n",
        "FAIR_1\n",
        "FAIR_2\n",
        "FAIR_3\n",
        "FAIR_4\n",
        "FAIR_5\n",
        "FAIR_6\n",
        "FAIR_7\n",
    };

    var runtime = try runtime_mod.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        std.testing.environ,
        .{ .tcp_loopback = 0 },
        0xfa1f,
    );
    defer runtime.deinit();

    var endpoint_storage: [64]u8 = undefined;
    const endpoint = try runtime.endpointText(&endpoint_storage);
    var pump = Pump{ .runtime = &runtime };
    const worker = try std.Thread.spawn(.{}, Pump.run, .{&pump});
    defer {
        pump.stop.store(true, .release);
        worker.join();
        std.debug.assert(!pump.failed.load(.acquire));
    }

    var control = try connectServer(endpoint);
    defer control.deinit();
    var identities: [count]server_client.protocol.InstanceIdentity = undefined;
    var connections: [count]*howl_client.Connection = undefined;
    var connected: usize = 0;
    defer {
        var index = connected;
        while (index != 0) {
            index -= 1;
            connections[index].deinit();
        }
    }

    for (0..count) |index| {
        var name_storage: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_storage, "fair-{d}", .{index});
        const session_id = try control.createSession(name);
        identities[index] = try control.createInstance(.{
            .session_id = session_id,
            .shell = "/bin/sh",
            .command = "cat",
            .rows = 12,
            .columns = 40,
            .history_rows = 32,
        });
        connections[index] = try attachInstance(endpoint, identities[index]);
        connected += 1;
    }

    var failed: std.atomic.Value(bool) = .init(false);
    var senders: [count]std.Thread = undefined;
    for (0..count) |index| {
        senders[index] = try std.Thread.spawn(.{}, FairInput.run, .{FairInput{
            .connection = connections[index],
            .marker = markers[index],
            .failed = &failed,
        }});
    }
    for (&senders) |*sender| sender.join();
    try std.testing.expect(!failed.load(.acquire));

    const status = try control.status();
    try std.testing.expectEqual(@as(u16, count), status.session_count);
    try std.testing.expectEqual(@as(u16, count), status.instance_count);

    for (0..count) |index| {
        var snapshot = try howl_client.snapshot.request(
            connections[index],
            std.testing.allocator,
            0,
            0,
        );
        defer snapshot.deinit();
        const needle = markers[index][0 .. markers[index].len - 1];
        var found = false;
        for (snapshot.lines) |line| {
            if (std.mem.indexOf(u8, line, needle) != null) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

fn snapshotPid(
    connection: *howl_client.Connection,
    prefix: []const u8,
) !std.posix.pid_t {
    var attempts: usize = 0;
    while (attempts < 1_000) : (attempts += 1) {
        var snapshot = try howl_client.snapshot.request(
            connection,
            std.testing.allocator,
            0,
            0,
        );
        defer snapshot.deinit();
        for (snapshot.lines) |line| {
            const start = std.mem.indexOf(u8, line, prefix) orelse continue;
            var end = start + prefix.len;
            while (end < line.len and line[end] >= '0' and line[end] <= '9') : (end += 1) {}
            if (end == start + prefix.len) continue;
            const value = try std.fmt.parseInt(std.posix.pid_t, line[start + prefix.len .. end], 10);
            if (value > 0) return value;
        }
    }
    return error.TestTimeout;
}

fn expectProcessGroupGone(pid: std.posix.pid_t) !void {
    const linux = std.os.linux;
    const leader = linux.kill(pid, @fromBackingInt(@intCast(0)));
    try std.testing.expectEqual(linux.E.SRCH, linux.errno(leader));
    const group = linux.kill(-pid, @fromBackingInt(@intCast(0)));
    try std.testing.expectEqual(linux.E.SRCH, linux.errno(group));
}

test "destructive close follows Server Session Instance lifetime boundaries" {
    var runtime = try runtime_mod.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        std.testing.environ,
        .{ .tcp_loopback = 0 },
        0xc105e,
    );
    defer runtime.deinit();

    var endpoint_storage: [64]u8 = undefined;
    const endpoint = try runtime.endpointText(&endpoint_storage);
    var pump = Pump{ .runtime = &runtime };
    const worker = try std.Thread.spawn(.{}, Pump.run, .{&pump});
    defer {
        pump.stop.store(true, .release);
        worker.join();
        std.debug.assert(!pump.failed.load(.acquire));
    }

    var control = try connectServer(endpoint);
    defer control.deinit();
    const doomed_session = try control.createSession("doomed");
    const sibling_session = try control.createSession("sibling");
    const doomed = try control.createInstance(.{
        .session_id = doomed_session,
        .shell = "/bin/sh",
        .command = "printf 'DOOMED_PID:%d\\n' \"$$\"; exec cat",
        .rows = 8,
        .columns = 48,
        .history_rows = 32,
    });
    const sibling = try control.createInstance(.{
        .session_id = sibling_session,
        .shell = "/bin/sh",
        .command = "printf 'SIBLING_PID:%d\\n' \"$$\"; exec cat",
        .rows = 8,
        .columns = 48,
        .history_rows = 32,
    });

    var doomed_client = try attachInstance(endpoint, doomed);
    defer doomed_client.deinit();
    var sibling_client = try attachInstance(endpoint, sibling);
    defer sibling_client.deinit();
    const doomed_pid = try snapshotPid(doomed_client, "DOOMED_PID:");
    const sibling_pid = try snapshotPid(sibling_client, "SIBLING_PID:");
    try std.testing.expect(doomed_pid != sibling_pid);

    try control.closeSession(doomed_session);
    try std.testing.expectError(
        error.ConnectionClosed,
        howl_client.snapshot.request(doomed_client, std.testing.allocator, 0, 0),
    );
    try expectProcessGroupGone(doomed_pid);

    // Destruction of one Session must not disturb another Session's live Instance.
    try howl_client.actions.committedText(sibling_client, "SIBLING_OK\\n");
    var sibling_snapshot = try howl_client.snapshot.request(
        sibling_client,
        std.testing.allocator,
        0,
        0,
    );
    defer sibling_snapshot.deinit();
    var sibling_ok = false;
    for (sibling_snapshot.lines) |line| {
        if (std.mem.indexOf(u8, line, "SIBLING_OK") != null) {
            sibling_ok = true;
            break;
        }
    }
    try std.testing.expect(sibling_ok);

    var tree_after_session = try control.observeTree(0);
    defer tree_after_session.deinit();
    try std.testing.expectEqual(@as(usize, 1), tree_after_session.sessions.len);
    try std.testing.expectEqual(sibling_session, tree_after_session.sessions[0].id);
    try std.testing.expectEqual(@as(usize, 1), tree_after_session.sessions[0].instances.len);

    // Instance close owns only that concrete terminal lifetime. Session identity stays.
    try control.closeInstance(sibling);
    try std.testing.expectError(
        error.ConnectionClosed,
        howl_client.snapshot.request(sibling_client, std.testing.allocator, 0, 0),
    );
    try expectProcessGroupGone(sibling_pid);

    var tree_after_instance = try control.observeTree(0);
    defer tree_after_instance.deinit();
    try std.testing.expectEqual(@as(usize, 1), tree_after_instance.sessions.len);
    try std.testing.expectEqual(sibling_session, tree_after_instance.sessions[0].id);
    try std.testing.expectEqual(@as(usize, 0), tree_after_instance.sessions[0].instances.len);
}

const ParkedTreeObserver = struct {
    connection: *server_client.Connection,
    after_revision: u64,
    session_id: u64,
    instance_id: u64,
    completed: *std.atomic.Value(bool),
    failed: *std.atomic.Value(bool),
    saw_exited: *std.atomic.Value(bool),

    fn run(self: ParkedTreeObserver) void {
        var tree = self.connection.observeTree(self.after_revision) catch {
            self.failed.store(true, .release);
            self.completed.store(true, .release);
            return;
        };
        defer tree.deinit();
        for (tree.sessions) |session| {
            if (session.id != self.session_id) continue;
            for (session.instances) |instance| {
                if (instance.instance_id == self.instance_id and instance.state == .exited) {
                    self.saw_exited.store(true, .release);
                }
            }
        }
        self.completed.store(true, .release);
    }
};

fn runtimeTestSleepOneMillisecond() void {
    const linux = std.os.linux;
    const request = linux.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
    switch (linux.errno(linux.nanosleep(&request, null))) {
        .SUCCESS, .INTR => {},
        // zig-audit: acknowledge panic
        // reason: This test fixture retries interruption; any other nanosleep failure aborts its timing proof.
        else => @panic("runtime test nanosleep failed"),
    }
}

test "parked control observer cannot starve dormant PTY readiness or sibling control" {
    var runtime = try runtime_mod.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        std.testing.environ,
        .{ .tcp_loopback = 0 },
        0x10a9,
    );
    defer runtime.deinit();

    var endpoint_storage: [64]u8 = undefined;
    const endpoint = try runtime.endpointText(&endpoint_storage);
    var pump = Pump{ .runtime = &runtime };
    const worker = try std.Thread.spawn(.{}, Pump.run, .{&pump});
    defer {
        pump.stop.store(true, .release);
        worker.join();
        std.debug.assert(!pump.failed.load(.acquire));
    }

    var control = try connectServer(endpoint);
    defer control.deinit();
    const session_id = try control.createSession("dormant");
    const identity = try control.createInstance(.{
        .session_id = session_id,
        .shell = "/bin/sh",
        .command = "sleep 0.20; printf 'DORMANT_WAKE\\n'; exit 0",
        .rows = 6,
        .columns = 32,
        .history_rows = 16,
    });

    var observer = try connectServer(endpoint);
    defer observer.deinit();
    const parked_after = (try observer.status()).tree_revision;
    var completed: std.atomic.Value(bool) = .init(false);
    var failed: std.atomic.Value(bool) = .init(false);
    var saw_exited: std.atomic.Value(bool) = .init(false);
    const observer_worker = try std.Thread.spawn(.{}, ParkedTreeObserver.run, .{ParkedTreeObserver{
        .connection = observer,
        .after_revision = parked_after,
        .session_id = session_id,
        .instance_id = identity.instance_id,
        .completed = &completed,
        .failed = &failed,
        .saw_exited = &saw_exited,
    }});

    // The second control connection must remain responsive while the first is parked.
    const concurrent_status = try control.status();
    try std.testing.expectEqual(@as(u16, 1), concurrent_status.session_count);
    try std.testing.expectEqual(@as(u16, 1), concurrent_status.instance_count);

    var waited: usize = 0;
    while (waited < 2_000 and !completed.load(.acquire)) : (waited += 1)
        runtimeTestSleepOneMillisecond();
    const completed_from_instance_exit = completed.load(.acquire);
    if (!completed_from_instance_exit) {
        // Release a failed long-poll before joining so the test itself cannot hang.
        const release_id = try control.createSession("observer-release");
        try std.testing.expect(release_id != 0);
    }
    observer_worker.join();
    try std.testing.expect(completed_from_instance_exit);
    try std.testing.expect(!failed.load(.acquire));
    try std.testing.expect(saw_exited.load(.acquire));

    // The clientless Instance's final PTY bytes must have been ingested before exit.
    var retained_client = try attachInstance(endpoint, identity);
    defer retained_client.deinit();
    var snapshot = try howl_client.snapshot.request(
        retained_client,
        std.testing.allocator,
        0,
        0,
    );
    defer snapshot.deinit();
    var found = false;
    for (snapshot.lines) |line| {
        if (std.mem.indexOf(u8, line, "DORMANT_WAKE") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}
