// Executable-only fixture: default SIGPIPE belongs here, never in the library.
const std = @import("std");
const transport = @import("client_transport");
const posix = std.posix;
/// Runs the isolated default-SIGPIPE transport fixture.
pub fn main() !void {
    const action: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.DFL }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(.PIPE, &action, null);
    for ([_]bool{ false, true }) |established| {
        var pair: [2]posix.fd_t = undefined;
        if (posix.errno(posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &pair)) != .SUCCESS) return error.SocketPair;
        var diagnostic: transport.ConnectDiagnostic = .{};
        var stream = try transport.Stream.adopt(pair[0], &diagnostic, null);
        defer stream.deinit();
        if (posix.errno(posix.system.close(pair[1])) != .SUCCESS) return error.Close;
        if (established) try stream.finishHandshake(&diagnostic);
        stream.write("must return EPIPE without signal") catch |err| {
            if (err == error.ConnectionClosed) continue;
            return err;
        };
        return error.ExpectedClosed;
    }
    std.debug.print("default SIGPIPE: setup and established writes returned ConnectionClosed\n", .{});
}
