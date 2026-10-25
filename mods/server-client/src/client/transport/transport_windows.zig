//! Windows ordered-byte-stream transport for Howl native clients.
//!
//! Windows admits numeric-IPv4 TCP plus explicitly adopted in-process duplex
//! pipe streams. The public transport contract remains the same as the POSIX
//! backend: bounded construction, exact diagnostics, and caller-owned
//! interruption; TCP additionally owns TCP_NODELAY. Unix-domain endpoints and
//! raw-socket duplication stay explicit unsupported surfaces.

const std = @import("std");
const windows = std.os.windows;
const ws2 = windows.ws2_32;

const tcp_prefix = "tcp://";
const unix_prefix = "unix:";
const setup_timeout_ms: i64 = 15_000;

const SOCKET = usize;
const invalid_socket = std.math.maxInt(SOCKET);
const socket_error: c_int = -1;
const WSAEVENT = ?windows.HANDLE;

const PipeState = struct {
    read: windows.HANDLE,
    write: windows.HANDLE,
    read_event: windows.HANDLE,
};

const SocketState = struct {
    socket: SOCKET,
    event: WSAEVENT,
};

const fd_read: i32 = 1 << 0;
const fd_write: i32 = 1 << 1;
const fd_connect: i32 = 1 << 4;
const fd_close: i32 = 1 << 5;
const fd_all: i32 = fd_read | fd_write | fd_connect | fd_close;
const wsa_wait_event_0: u32 = 0;
const wsa_wait_failed: u32 = 0xFFFF_FFFF;
const wsa_wait_timeout: u32 = 258;
const wsa_infinite: u32 = 0xFFFF_FFFF;
const sd_both: c_int = 2;

const wsaeintr = 10_004;
const wsaewouldblock = 10_035;
const wsaeinprogress = 10_036;
const wsaealready = 10_037;
const wsaeconnreset = 10_054;
const wsaeisconn = 10_056;
const wsaenotconn = 10_057;
const wsaetimedout = 10_060;

const WSADATA = if (@sizeOf(usize) == 8) extern struct {
    version: u16,
    high_version: u16,
    maximum_sockets: u16,
    maximum_datagram: u16,
    vendor_info: ?[*:0]u8,
    description: [257]u8,
    system_status: [129]u8,
} else extern struct {
    version: u16,
    high_version: u16,
    description: [257]u8,
    system_status: [129]u8,
    maximum_sockets: u16,
    maximum_datagram: u16,
    vendor_info: ?[*:0]u8,
};

const NetworkEvents = extern struct {
    events: i32,
    errors: [10]c_int,
};

extern "ws2_32" fn WSAStartup(version: u16, data: *WSADATA) callconv(.winapi) c_int;
extern "ws2_32" fn WSACleanup() callconv(.winapi) c_int;
extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;
extern "ws2_32" fn WSACreateEvent() callconv(.winapi) WSAEVENT;
extern "ws2_32" fn WSACloseEvent(event: WSAEVENT) callconv(.winapi) c_int;
extern "ws2_32" fn WSASetEvent(event: WSAEVENT) callconv(.winapi) c_int;
extern "ws2_32" fn WSAEventSelect(socket_value: SOCKET, event: WSAEVENT, events: i32) callconv(.winapi) c_int;
extern "ws2_32" fn WSAEnumNetworkEvents(socket_value: SOCKET, event: WSAEVENT, events: *NetworkEvents) callconv(.winapi) c_int;
extern "ws2_32" fn WSAWaitForMultipleEvents(
    count: u32,
    events: [*]const WSAEVENT,
    wait_all: c_int,
    timeout_ms: u32,
    alertable: c_int,
) callconv(.winapi) u32;
extern "ws2_32" fn socket(address_family: c_int, socket_type: c_int, protocol: c_int) callconv(.winapi) SOCKET;
extern "ws2_32" fn connect(socket_value: SOCKET, address: *const ws2.sockaddr, address_len: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn recv(socket_value: SOCKET, bytes: [*]u8, length: c_int, flags: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn send(socket_value: SOCKET, bytes: [*]const u8, length: c_int, flags: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn shutdown(socket_value: SOCKET, how: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn closesocket(socket_value: SOCKET) callconv(.winapi) c_int;
extern "ws2_32" fn getsockopt(
    socket_value: SOCKET,
    level: c_int,
    option: c_int,
    value: *c_int,
    length: *c_int,
) callconv(.winapi) c_int;
extern "ws2_32" fn setsockopt(
    socket_value: SOCKET,
    level: c_int,
    option: c_int,
    value: *const c_int,
    length: c_int,
) callconv(.winapi) c_int;
extern "kernel32" fn PeekNamedPipe(
    pipe: windows.HANDLE,
    buffer: ?windows.LPVOID,
    buffer_size: u32,
    bytes_read: ?*u32,
    total_bytes_available: ?*u32,
    bytes_left_this_message: ?*u32,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn ReadFile(
    file: windows.HANDLE,
    buffer: windows.LPVOID,
    bytes_to_read: u32,
    bytes_read: *u32,
    overlapped: ?windows.LPVOID,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WriteFile(
    file: windows.HANDLE,
    buffer: windows.LPCVOID,
    bytes_to_write: u32,
    bytes_written: *u32,
    overlapped: ?windows.LPVOID,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WaitForMultipleObjects(
    count: u32,
    handles: [*]const windows.HANDLE,
    wait_all: windows.BOOL,
    timeout_ms: u32,
) callconv(.winapi) u32;
extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;
extern "kernel32" fn SetNamedPipeHandleState(
    pipe: windows.HANDLE,
    mode: ?*u32,
    maximum_collection_count: ?*u32,
    collect_data_timeout: ?*u32,
) callconv(.winapi) windows.BOOL;

const pipe_nowait: u32 = 0x0000_0001;
const pipe_write_chunk_bytes: usize = 16 * 1024;

/// Platform-native ordered-stream handle used only by callers that integrate
/// transport readiness into an external event loop.
pub const Handle = SOCKET;

/// Enumerates transport construction, cancellation, I/O, and endpoint failures.
pub const Error = error{
    ConnectionCanceled,
    InvalidEndpoint,
    SocketCreateFailed,
    SocketDuplicateFailed,
    SocketConnectFailed,
    SocketConnectTimedOut,
    SocketOptionFailed,
    SocketReadFailed,
    SocketShutdownFailed,
    SocketWriteFailed,
    ConnectionClosed,
    SocketPathTooLong,
};

/// Identifies the exact connection/setup phase for bounded diagnostics.
pub const ConnectStage = enum(u8) {
    start,
    endpoint,
    socket_create,
    file_status_read,
    nonblocking_enable,
    socket_connect,
    socket_poll,
    socket_verify,
    blocking_restore,
    tcp_nodelay,
    close_on_exec,
    hello_write,
    welcome_read,
    welcome_kind,
    welcome_payload,
    ready,
};

/// Retains bounded connection setup diagnostics without owning protocol state.
pub const ConnectDiagnostic = struct {
    stage: ConnectStage = .start,
    os_error: i32 = 0,
    poll_interrupts: u16 = 0,
    route_message: [512]u8 = undefined,
    route_message_len: usize = 0,
};

/// Windows does not expose the POSIX duplicate-fd cancellation helper in this
/// checkpoint. Odin uses Interrupt; callers requiring duplicated readiness
/// ownership receive an explicit construction error.
pub const Cancellation = struct {
    /// Reports that duplicated-socket cancellation is unavailable on this Windows path.
    pub fn cancel(_: *const Cancellation) error{SocketShutdownFailed}!void {
        return error.SocketShutdownFailed;
    }

    /// Releases the empty compatibility cancellation value.
    pub fn deinit(self: *Cancellation) void {
        self.* = undefined;
    }
};

/// Single-use caller-owned wake token. Every blocking Windows transport wait
/// includes this event, so cancellation never depends on a polling interval.
// zig-audit: acknowledge opaque_type
// reason: Callers need only the cancellation lifetime/API; the private Windows event state must remain layout-inaccessible.
pub const Interrupt = opaque {
    /// Creates one independently owned Windows cancellation event.
    pub fn init(allocator: std.mem.Allocator) (std.mem.Allocator.Error || error{ SocketCreateFailed, SocketOptionFailed })!*Interrupt {
        try startWinsock();
        errdefer stopWinsock();
        const event = WSACreateEvent() orelse return error.SocketCreateFailed;
        errdefer closeEvent(event);
        const value = try allocator.create(InterruptState);
        value.* = .{ .allocator = allocator, .event = event };
        // zig-audit: acknowledge ptr_cast
        // reason: Interrupt is the opaque public handle for this exact allocator-owned InterruptState allocation.
        return @ptrCast(value);
    }

    /// Marks the interrupt canceled and signals its wake event.
    pub fn cancel(self: *Interrupt) error{SocketShutdownFailed}!void {
        const value = self.state();
        value.canceled.store(true, .release);
        if (WSASetEvent(value.event) == 0) return error.SocketShutdownFailed;
    }

    /// Releases the Windows event, Winsock lifetime, and opaque owner allocation.
    pub fn deinit(self: *Interrupt) void {
        const value = self.state();
        closeEvent(value.event);
        stopWinsock();
        value.allocator.destroy(value);
    }

    fn state(self: *Interrupt) *InterruptState {
        // zig-audit: acknowledge ptr_cast
        // reason: Every Interrupt originates from an InterruptState allocation in init and retains that exact address.
        // zig-audit: acknowledge align_cast
        // reason: Recovering the concrete owner asserts the alignment guaranteed by the originating InterruptState allocation.
        return @ptrCast(@alignCast(self));
    }
};

const InterruptState = struct {
    allocator: std.mem.Allocator,
    event: WSAEVENT,
    canceled: std.atomic.Value(bool) = .init(false),
};

fn checkInterrupted(interrupt: ?*Interrupt) error{ConnectionCanceled}!void {
    if (interrupt) |token| if (token.state().canceled.load(.acquire))
        return error.ConnectionCanceled;
}

/// Owns one Windows socket or adopted pipe ordered byte stream.
pub const Stream = struct {
    kind: union(enum) {
        socket: SocketState,
        pipe: PipeState,
    },
    interrupt: ?*Interrupt = null,
    handshake_deadline_ms: ?i64 = null,

    /// Connects one supported endpoint while reporting the exact setup stage on failure.
    pub fn connectDiagnosed(endpoint: []const u8, diagnostic: *ConnectDiagnostic) Error!Stream {
        return connectCancelable(endpoint, diagnostic, null);
    }

    /// Connects one supported endpoint with an optional caller-owned interrupt token.
    pub fn connectCancelable(
        endpoint: []const u8,
        diagnostic: *ConnectDiagnostic,
        interrupt: ?*Interrupt,
    ) Error!Stream {
        diagnostic.* = .{ .stage = .endpoint };
        try checkInterrupted(interrupt);
        if (std.mem.startsWith(u8, endpoint, unix_prefix)) return error.InvalidEndpoint;
        if (!std.mem.startsWith(u8, endpoint, tcp_prefix)) return error.InvalidEndpoint;
        const parsed = try tcpEndpoint(endpoint);
        const deadline = (try monotonicMilliseconds()) + setup_timeout_ms;

        try startWinsock();
        errdefer stopWinsock();

        diagnostic.stage = .socket_create;
        const socket_value = socket(ws2.AF.INET, ws2.SOCK.STREAM, ws2.IPPROTO.TCP);
        if (socket_value == invalid_socket) {
            diagnostic.os_error = WSAGetLastError();
            return error.SocketCreateFailed;
        }
        errdefer closeSocket(socket_value);

        const event = WSACreateEvent() orelse {
            diagnostic.os_error = WSAGetLastError();
            return error.SocketCreateFailed;
        };
        errdefer closeEvent(event);

        diagnostic.stage = .nonblocking_enable;
        if (WSAEventSelect(socket_value, event, fd_all) == socket_error) {
            diagnostic.os_error = WSAGetLastError();
            return error.SocketOptionFailed;
        }

        var address = ws2.sockaddr.in{
            .family = ws2.AF.INET,
            .port = std.mem.nativeToBig(u16, parsed.port),
            .addr = @bitCast(parsed.address),
        };
        diagnostic.stage = .socket_connect;
        // zig-audit: acknowledge ptr_cast
        // reason: Winsock connect consumes this live sockaddr.in through the generic sockaddr ABI for exactly this call.
        const connected = connect(socket_value, @ptrCast(&address), @sizeOf(@TypeOf(address)));
        if (connected == socket_error) {
            const failure = WSAGetLastError();
            switch (failure) {
                wsaewouldblock, wsaeinprogress, wsaealready => {
                    diagnostic.stage = .socket_poll;
                    try waitSocketReady(socket_value, event, fd_connect, deadline, interrupt);
                    diagnostic.stage = .socket_verify;
                    try verifySocketConnected(socket_value, diagnostic);
                },
                wsaeisconn => {},
                else => {
                    diagnostic.os_error = failure;
                    return error.SocketConnectFailed;
                },
            }
        }

        diagnostic.stage = .tcp_nodelay;
        try setTcpNoDelay(socket_value);
        return .{
            .kind = .{ .socket = .{ .socket = socket_value, .event = event } },
            .interrupt = interrupt,
            .handshake_deadline_ms = deadline,
        };
    }

    /// Adopts one already-created WinSock stream. This path exists for API
    /// parity but is not used by the Windows Remote product route.
    pub fn adopt(socket_value: Handle, diagnostic: *ConnectDiagnostic, interrupt: ?*Interrupt) Error!Stream {
        try startWinsock();
        errdefer stopWinsock();
        const event = WSACreateEvent() orelse return error.SocketCreateFailed;
        errdefer closeEvent(event);
        diagnostic.stage = .nonblocking_enable;
        if (WSAEventSelect(socket_value, event, fd_all) == socket_error) {
            diagnostic.os_error = WSAGetLastError();
            return error.SocketOptionFailed;
        }
        try checkInterrupted(interrupt);
        return .{
            .kind = .{ .socket = .{ .socket = socket_value, .event = event } },
            .interrupt = interrupt,
            .handshake_deadline_ms = (try monotonicMilliseconds()) + setup_timeout_ms,
        };
    }

    /// Adopts one already-created anonymous-pipe duplex stream. The caller
    /// transfers ownership of both pipe ends and the read-wake event on entry.
    pub fn adoptPipe(
        read_handle: windows.HANDLE,
        write_handle: windows.HANDLE,
        read_event: windows.HANDLE,
        diagnostic: *ConnectDiagnostic,
        interrupt: ?*Interrupt,
    ) Error!Stream {
        errdefer closeHandle(read_handle);
        errdefer closeHandle(write_handle);
        errdefer closeHandle(read_event);
        try checkInterrupted(interrupt);
        diagnostic.stage = .nonblocking_enable;
        try configurePipeNonblocking(read_handle);
        try configurePipeNonblocking(write_handle);
        return .{
            .kind = .{ .pipe = .{
                .read = read_handle,
                .write = write_handle,
                .read_event = read_event,
            } },
            .interrupt = interrupt,
            .handshake_deadline_ms = (try monotonicMilliseconds()) + setup_timeout_ms,
        };
    }

    /// Starts bounded handshake policy for one adopted raw stream.
    pub fn beginHandshake(self: *Stream, diagnostic: *ConnectDiagnostic) Error!void {
        if (self.handshake_deadline_ms != null) return;
        try checkInterrupted(self.interrupt);
        self.handshake_deadline_ms = (try monotonicMilliseconds()) + setup_timeout_ms;
        diagnostic.stage = .nonblocking_enable;
    }

    /// Closes the owned socket or pipe state.
    pub fn deinit(self: *Stream) void {
        switch (self.kind) {
            .socket => |state| {
                closeSocket(state.socket);
                closeEvent(state.event);
                stopWinsock();
            },
            .pipe => |state| {
                closeHandle(state.read);
                closeHandle(state.write);
                closeHandle(state.read_event);
            },
        }
        self.* = undefined;
    }

    /// Borrows the native readiness handle for caller-owned event integration.
    pub fn readinessFd(self: *const Stream) Handle {
        return switch (self.kind) {
            .socket => |state| state.socket,
            .pipe => |state| @intFromPtr(state.read),
        };
    }

    /// Reports that duplicated-socket cancellation is unavailable on this Windows path.
    pub fn cancellation(_: *const Stream) error{ SocketDuplicateFailed, SocketOptionFailed }!Cancellation {
        return error.SocketDuplicateFailed;
    }

    /// Writes one complete handshake payload under the current setup deadline.
    pub fn handshakeWrite(self: *Stream, bytes: []const u8) Error!void {
        return writeInterrupt(self, bytes, self.handshake_deadline_ms);
    }

    /// Reads one complete handshake payload under the current setup deadline.
    pub fn handshakeRead(self: *Stream, output: []u8) Error!void {
        return readInterrupt(self, output, self.handshake_deadline_ms);
    }

    /// Completes setup policy and clears the temporary handshake deadline.
    pub fn finishHandshake(self: *Stream, diagnostic: *ConnectDiagnostic) Error!void {
        try checkInterrupted(self.interrupt);
        self.handshake_deadline_ms = null;
        diagnostic.stage = .ready;
    }

    /// Writes the complete byte slice or returns an exact transport failure.
    pub fn write(self: *Stream, bytes: []const u8) Error!void {
        return writeInterrupt(self, bytes, self.handshake_deadline_ms);
    }

    /// Reads exactly output.len bytes or returns an exact transport failure.
    pub fn read(self: *Stream, output: []u8) Error!void {
        return readInterrupt(self, output, self.handshake_deadline_ms);
    }
};

const TcpEndpoint = struct {
    address: [4]u8,
    port: u16,
};

fn tcpEndpoint(endpoint: []const u8) error{InvalidEndpoint}!TcpEndpoint {
    const text = endpoint[tcp_prefix.len..];
    if (text.len == 0 or std.mem.indexOfAny(u8, text, "/?#") != null)
        return error.InvalidEndpoint;
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return error.InvalidEndpoint;
    if (colon == 0 or colon + 1 >= text.len or std.mem.indexOfScalar(u8, text[0..colon], ':') != null)
        return error.InvalidEndpoint;

    const host = text[0..colon];
    const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return error.InvalidEndpoint;
    if (port == 0) return error.InvalidEndpoint;

    var address: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, host, '.');
    var index: usize = 0;
    while (parts.next()) |part| : (index += 1) {
        if (index >= address.len or part.len == 0) return error.InvalidEndpoint;
        address[index] = std.fmt.parseInt(u8, part, 10) catch return error.InvalidEndpoint;
    }
    if (index != address.len or std.mem.eql(u8, &address, &.{ 0, 0, 0, 0 }))
        return error.InvalidEndpoint;
    return .{ .address = address, .port = port };
}

fn waitSocketReady(
    socket_value: SOCKET,
    socket_event: WSAEVENT,
    desired_events: i32,
    deadline_ms: ?i64,
    interrupt: ?*Interrupt,
) Error!void {
    while (true) {
        try checkInterrupted(interrupt);
        const timeout_ms: u32 = if (deadline_ms) |deadline| blk: {
            const remaining = deadline - try monotonicMilliseconds();
            if (remaining <= 0) return error.SocketConnectTimedOut;
            break :blk @intCast(@min(remaining, @as(i64, std.math.maxInt(u32) - 1)));
        } else wsa_infinite;

        var events = [2]WSAEVENT{
            socket_event,
            if (interrupt) |token| token.state().event else null,
        };
        const event_count: u32 = if (interrupt == null) 1 else 2;
        const result = WSAWaitForMultipleEvents(event_count, &events, 0, timeout_ms, 0);
        if (result == wsa_wait_timeout) return error.SocketConnectTimedOut;
        if (result == wsa_wait_failed) return error.SocketReadFailed;
        if (result == wsa_wait_event_0 + 1 and interrupt != null) {
            try checkInterrupted(interrupt);
            return error.ConnectionCanceled;
        }
        if (result != wsa_wait_event_0) return error.SocketReadFailed;

        var network_events: NetworkEvents = undefined;
        if (WSAEnumNetworkEvents(socket_value, socket_event, &network_events) == socket_error)
            return error.SocketReadFailed;
        try checkInterrupted(interrupt);
        if (network_events.events & (desired_events | fd_close) != 0) return;
    }
}

fn readInterrupt(stream: *Stream, output: []u8, deadline_ms: ?i64) Error!void {
    return switch (stream.kind) {
        .socket => |state| readSocketInterrupt(stream, state, output, deadline_ms),
        .pipe => |state| readPipeInterrupt(stream, state, output, deadline_ms),
    };
}

fn readSocketInterrupt(stream: *Stream, state: SocketState, output: []u8, deadline_ms: ?i64) Error!void {
    var offset: usize = 0;
    while (offset < output.len) {
        try checkInterrupted(stream.interrupt);
        if (deadline_ms) |deadline| if (try monotonicMilliseconds() >= deadline)
            return error.SocketConnectTimedOut;
        const chunk: c_int = @intCast(@min(output.len - offset, @as(usize, std.math.maxInt(c_int))));
        const count = recv(state.socket, output[offset..].ptr, chunk, 0);
        if (count > 0) {
            offset += @intCast(count);
            continue;
        }
        if (count == 0) return error.ConnectionClosed;
        const failure = WSAGetLastError();
        switch (failure) {
            wsaeintr => continue,
            wsaewouldblock => try waitSocketReady(state.socket, state.event, fd_read, deadline_ms, stream.interrupt),
            wsaeconnreset, wsaenotconn => return error.ConnectionClosed,
            wsaetimedout => return error.SocketConnectTimedOut,
            else => return error.SocketReadFailed,
        }
    }
}

fn writeInterrupt(stream: *Stream, bytes: []const u8, deadline_ms: ?i64) Error!void {
    return switch (stream.kind) {
        .socket => |state| writeSocketInterrupt(stream, state, bytes, deadline_ms),
        .pipe => |state| writePipeInterrupt(stream, state, bytes, deadline_ms),
    };
}

fn writeSocketInterrupt(stream: *Stream, state: SocketState, bytes: []const u8, deadline_ms: ?i64) Error!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        try checkInterrupted(stream.interrupt);
        if (deadline_ms) |deadline| if (try monotonicMilliseconds() >= deadline)
            return error.SocketConnectTimedOut;
        const chunk: c_int = @intCast(@min(bytes.len - offset, @as(usize, std.math.maxInt(c_int))));
        const count = send(state.socket, bytes[offset..].ptr, chunk, 0);
        if (count > 0) {
            offset += @intCast(count);
            continue;
        }
        if (count == 0) return error.ConnectionClosed;
        const failure = WSAGetLastError();
        switch (failure) {
            wsaeintr => continue,
            wsaewouldblock => try waitSocketReady(state.socket, state.event, fd_write, deadline_ms, stream.interrupt),
            wsaeconnreset, wsaenotconn => return error.ConnectionClosed,
            wsaetimedout => return error.SocketConnectTimedOut,
            else => return error.SocketWriteFailed,
        }
    }
}

fn readPipeInterrupt(stream: *Stream, state: PipeState, output: []u8, deadline_ms: ?i64) Error!void {
    var offset: usize = 0;
    while (offset < output.len) {
        try checkInterrupted(stream.interrupt);
        if (deadline_ms) |deadline| if (try monotonicMilliseconds() >= deadline)
            return error.SocketConnectTimedOut;

        var available: u32 = 0;
        if (!PeekNamedPipe(state.read, null, 0, null, &available, null).toBool()) {
            return switch (windows.GetLastError()) {
                .BROKEN_PIPE, .PIPE_NOT_CONNECTED => error.ConnectionClosed,
                .OPERATION_ABORTED => error.ConnectionCanceled,
                else => error.SocketReadFailed,
            };
        }
        if (available == 0) {
            try waitPipeReadable(state.read_event, deadline_ms, stream.interrupt);
            continue;
        }

        const count: u32 = @intCast(@min(
            @min(output.len - offset, @as(usize, available)),
            @as(usize, std.math.maxInt(u32)),
        ));
        var read_count: u32 = 0;
        // zig-audit: acknowledge ptr_cast
        // reason: ReadFile accepts an untyped writable buffer; this slice provides count live bytes for exactly this call.
        if (!ReadFile(state.read, @ptrCast(output[offset..].ptr), count, &read_count, null).toBool()) {
            return switch (windows.GetLastError()) {
                .BROKEN_PIPE, .PIPE_NOT_CONNECTED => error.ConnectionClosed,
                .NO_DATA => continue,
                .OPERATION_ABORTED => error.ConnectionCanceled,
                else => error.SocketReadFailed,
            };
        }
        if (read_count == 0) return error.ConnectionClosed;
        offset += read_count;
    }
}

fn writePipeInterrupt(stream: *Stream, state: PipeState, bytes: []const u8, deadline_ms: ?i64) Error!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        try checkInterrupted(stream.interrupt);
        if (deadline_ms) |deadline| if (try monotonicMilliseconds() >= deadline)
            return error.SocketConnectTimedOut;
        const count: u32 = @intCast(@min(
            bytes.len - offset,
            @min(pipe_write_chunk_bytes, @as(usize, std.math.maxInt(u32))),
        ));
        var written: u32 = 0;
        // zig-audit: acknowledge ptr_cast
        // reason: WriteFile accepts an untyped input buffer; this slice provides count live bytes for exactly this call.
        if (!WriteFile(state.write, @ptrCast(bytes[offset..].ptr), count, &written, null).toBool()) {
            switch (windows.GetLastError()) {
                .BROKEN_PIPE, .PIPE_NOT_CONNECTED => return error.ConnectionClosed,
                .NO_DATA => {
                    Sleep(1);
                    continue;
                },
                .OPERATION_ABORTED => return error.ConnectionCanceled,
                else => return error.SocketWriteFailed,
            }
        }
        if (written == 0) {
            Sleep(1);
            continue;
        }
        offset += written;
    }
}

fn waitPipeReadable(
    read_event: windows.HANDLE,
    deadline_ms: ?i64,
    interrupt: ?*Interrupt,
) Error!void {
    try checkInterrupted(interrupt);
    const timeout_ms: u32 = if (deadline_ms) |deadline| blk: {
        const remaining = deadline - try monotonicMilliseconds();
        if (remaining <= 0) return error.SocketConnectTimedOut;
        break :blk @intCast(@min(remaining, @as(i64, std.math.maxInt(u32) - 1)));
    } else wsa_infinite;

    var handles = [2]windows.HANDLE{
        read_event,
        if (interrupt) |token| token.state().event.? else read_event,
    };
    const count: u32 = if (interrupt == null) 1 else 2;
    const result = WaitForMultipleObjects(count, &handles, .FALSE, timeout_ms);
    if (result == wsa_wait_timeout) return error.SocketConnectTimedOut;
    if (result == wsa_wait_failed) return error.SocketReadFailed;
    if (result == wsa_wait_event_0 + 1 and interrupt != null) {
        try checkInterrupted(interrupt);
        return error.ConnectionCanceled;
    }
    if (result != wsa_wait_event_0) return error.SocketReadFailed;
}

fn verifySocketConnected(socket_value: SOCKET, diagnostic: *ConnectDiagnostic) Error!void {
    var socket_failure: c_int = 0;
    var length: c_int = @sizeOf(c_int);
    if (getsockopt(
        socket_value,
        ws2.SOL.SOCKET,
        ws2.SO.ERROR,
        &socket_failure,
        &length,
    ) == socket_error or length != @sizeOf(c_int)) {
        diagnostic.os_error = WSAGetLastError();
        return error.SocketOptionFailed;
    }
    if (socket_failure != 0) {
        diagnostic.os_error = socket_failure;
        return error.SocketConnectFailed;
    }
}

fn setTcpNoDelay(socket_value: SOCKET) error{SocketOptionFailed}!void {
    const enabled: c_int = 1;
    if (setsockopt(
        socket_value,
        ws2.IPPROTO.TCP,
        ws2.TCP.NODELAY,
        &enabled,
        @sizeOf(c_int),
    ) == socket_error) return error.SocketOptionFailed;
}

fn startWinsock() error{SocketCreateFailed}!void {
    var data: WSADATA = undefined;
    const result = WSAStartup(0x0202, &data);
    if (result != 0) return error.SocketCreateFailed;
}

fn stopWinsock() void {
    std.debug.assert(WSACleanup() == 0);
}

fn closeSocket(socket_value: SOCKET) void {
    std.debug.assert(closesocket(socket_value) == 0);
}

fn closeEvent(event: WSAEVENT) void {
    std.debug.assert(WSACloseEvent(event) != 0);
}

fn closeHandle(handle: windows.HANDLE) void {
    windows.CloseHandle(handle);
}

fn configurePipeNonblocking(handle: windows.HANDLE) error{SocketOptionFailed}!void {
    var mode = pipe_nowait;
    if (!SetNamedPipeHandleState(handle, &mode, null, null).toBool())
        return error.SocketOptionFailed;
}

fn monotonicMilliseconds() error{SocketConnectFailed}!i64 {
    var counter: windows.LARGE_INTEGER = 0;
    var frequency: windows.LARGE_INTEGER = 0;
    if (!windows.ntdll.RtlQueryPerformanceCounter(&counter).toBool() or
        !windows.ntdll.RtlQueryPerformanceFrequency(&frequency).toBool() or
        frequency <= 0)
        return error.SocketConnectFailed;
    return @intCast(@divFloor(@as(i128, counter) * std.time.ms_per_s, frequency));
}

test "Windows endpoint parser accepts numeric IPv4 only" {
    const endpoint = try tcpEndpoint("tcp://100.96.0.4:43150");
    try std.testing.expectEqual([4]u8{ 100, 96, 0, 4 }, endpoint.address);
    try std.testing.expectEqual(@as(u16, 43150), endpoint.port);
    try std.testing.expectError(error.InvalidEndpoint, tcpEndpoint("tcp://home:43150"));
    try std.testing.expectError(error.InvalidEndpoint, tcpEndpoint("tcp://0.0.0.0:43150"));
}

test "Windows interruption is sticky before transport construction" {
    const interrupt = try Interrupt.init(std.testing.allocator);
    defer interrupt.deinit();
    try interrupt.cancel();
    try std.testing.expectError(error.ConnectionCanceled, checkInterrupted(interrupt));
}
