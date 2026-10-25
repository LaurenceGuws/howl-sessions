//! Private real-runtime host for the independent C consumer.
const std = @import("std");
const runtime_mod = @import("server_runtime");
extern fn hsc_external_probe(endpoint: [*]const u8, length: usize, server_id: u64) c_int;
extern fn hsc_queries_probe(endpoint: [*]const u8, length: usize, server_id: u64) c_int;

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

test "external C consumer exercises independent client artifact against private Server" {
    var runtime = try runtime_mod.Runtime.init(std.testing.allocator, std.testing.io, std.testing.environ, .{ .tcp_loopback = 0 }, 0xc11ab1);
    defer runtime.deinit();
    var storage: [64]u8 = undefined;
    const endpoint = try runtime.endpointText(&storage);
    var pump = Pump{ .runtime = &runtime };
    const worker = try std.Thread.spawn(.{}, Pump.run, .{&pump});
    defer {
        pump.stop.store(true, .release);
        worker.join();
        std.debug.assert(!pump.failed.load(.acquire));
    }
    try std.testing.expectEqual(@as(c_int, 0), hsc_external_probe(endpoint.ptr, endpoint.len, 0xc11ab1));
    try std.testing.expectEqual(@as(c_int, 0), hsc_queries_probe(endpoint.ptr, endpoint.len, 0xc11ab1));
}
