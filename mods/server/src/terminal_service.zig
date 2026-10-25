//! Optional Server terminal interaction service for one existing Howl Instance.
//!
//! Service borrows Instance lifetime and owns only bounded adopted client streams,
//! request decoding, publication scratch and client-local backpressure. It creates no
//! listener, endpoint, process, Session or Server. A slow client cannot pace canonical
//! Instance progress.

const std = @import("std");
const builtin = @import("builtin");
const native_windows = builtin.os.tag == .windows;
const windows = std.os.windows;
const posix = if (native_windows) struct {} else std.posix;
const linux = if (native_windows) struct {} else std.os.linux;
const howl = @import("howl_instance");
const server_protocol = @import("server_protocol");
const protocol = server_protocol.terminal;
const codec = @import("howl_vt_codec");
const vt_encoder = codec.encoder.Encoder(howl.Terminal.Observation);
const terminalProperties = vt_encoder.properties;
const countSnapshotGraphics = vt_encoder.countGraphics;
const encodeSnapshotGraphics = vt_encoder.encodeGraphics;
const imageVisible = vt_encoder.imageVisible;

/// Owns the Windows service side of one listener-free in-process Server terminal duplex stream.
pub const WindowsAdoptedStream = struct {
    read: windows.HANDLE,
    write: windows.HANDLE,
    peer_read_event: windows.HANDLE,
};

/// Target-native connected byte stream transferred into one Service client slot.
pub const AdoptedStream = if (native_windows) WindowsAdoptedStream else std.posix.fd_t;

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
extern "kernel32" fn SetEvent(event: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn SetNamedPipeHandleState(
    pipe: windows.HANDLE,
    mode: ?*u32,
    maximum_collection_count: ?*u32,
    collect_data_timeout: ?*u32,
) callconv(.winapi) windows.BOOL;

const pipe_nowait: u32 = 0x0000_0001;

// One polished desktop view currently owns bounded control, observer, render,
// and consequence-policy connections. Keep enough explicit slots for the
// product's eight-view ceiling without embedding one 64 KiB request buffer in
// every empty slot; Client.input is allocated only for accepted connections.
const maximum_clients: usize = 32;
const maximum_request_payload: usize = protocol.maximum_request_payload_bytes;
const input_buffer_bytes: usize = protocol.header_bytes + maximum_request_payload;
const client_send_buffer_bytes: c_int = 64 * 1024;
// Retain ordinary snapshot/result output across request cycles without letting
// one unusually large response permanently multiply by every client slot.
const client_output_retain_bytes: usize = 512 * 1024;
const lifecycle_poll_ms: i32 = 100;
// Windows anonymous pipes are bounded byte streams. Keep each nonblocking
// service write comfortably below the 64 KiB Local pair capacity so a large
// multi-frame snapshot can drain incrementally instead of requiring one
// all-or-nothing write to fit at once.
const windows_pipe_write_chunk_bytes: usize = 16 * 1024;
// A connected host-consequence authority gets one bounded opportunity to answer
// a reply-bearing terminal query. Match synchronized-output's existing one-second
// fail-open policy: host integration may enrich behavior, but cannot indefinitely
// hold canonical child progress.
const consequence_reply_timeout_ns: u64 = std.time.ns_per_s;
// Match Foot's bounded application synchronized-update hold. Canonical VT
// progress continues during the hold; only observer publication waits. A stuck
// application fails open rather than freezing presentation indefinitely.
const synchronized_output_timeout_ns: u64 = std.time.ns_per_s;
// Unbracketed terminal apps often emit one logical screen update as a dense
// cluster of tiny PTY writes. Wait briefly for that microburst to go quiet so
// observers see the completed cut rather than arbitrary read boundaries.
const burst_publication_quiet_ns: u64 = 1 * std.time.ns_per_ms;
// In-place text/cursor updates may publish fast enough to feed high-refresh
// native observers. Once a burst mutates the viewport, retain the wider bound
// so scrolling bulk output stays coalesced.
const burst_publication_fast_max_ns: u64 = 2 * std.time.ns_per_ms;
const burst_publication_scroll_max_ns: u64 = 8 * std.time.ns_per_ms;
// Snapshot graphics resources are fetched in a second request after their
// manifest is observed. One client therefore retains exactly the resources
// named by its most recently delivered snapshot until that client advances to
// another snapshot. Control-only clients retain no image bytes.
const snapshot_image_bytes: usize = howl.Terminal.maximum_image_storage_bytes;
const snapshot_image_entries: usize = howl.Terminal.maximum_images;

const BurstPublicationGate = struct {
    started_ns: ?u64 = null,
    last_change_ns: ?u64 = null,
    max_ns: u64 = 0,

    fn note(self: *BurstPublicationGate, now_ns: u64, max_ns: u64) void {
        std.debug.assert(max_ns >= burst_publication_quiet_ns);
        if (self.started_ns == null) {
            self.started_ns = now_ns;
            self.max_ns = max_ns;
        } else {
            self.max_ns = @max(self.max_ns, max_ns);
        }
        self.last_change_ns = now_ns;
    }

    fn reset(self: *BurstPublicationGate) void {
        self.started_ns = null;
        self.last_change_ns = null;
        self.max_ns = 0;
    }

    fn ready(self: *BurstPublicationGate, now_ns: u64) bool {
        const started_ns = self.started_ns orelse return false;
        const last_change_ns = self.last_change_ns orelse return false;
        std.debug.assert(self.max_ns != 0);
        if (now_ns -| last_change_ns < burst_publication_quiet_ns and
            now_ns -| started_ns < self.max_ns)
            return false;
        self.reset();
        return true;
    }

    fn waitMs(self: *const BurstPublicationGate, now_ns: u64) ?u32 {
        const started_ns = self.started_ns orelse return null;
        const last_change_ns = self.last_change_ns orelse return null;
        const quiet_remaining = burst_publication_quiet_ns -| (now_ns -| last_change_ns);
        std.debug.assert(self.max_ns != 0);
        const max_remaining = self.max_ns -| (now_ns -| started_ns);
        const remaining = @min(quiet_remaining, max_remaining);
        if (remaining == 0) return 0;
        return @intCast((remaining + std.time.ns_per_ms - 1) / std.time.ns_per_ms);
    }
};

fn consequenceRequiresReply(value: howl.Consequence) bool {
    return switch (value) {
        .clipboard => |request| request.kind == .query,
        .pointer_shape => |request| request.payload.len != 0 and request.payload[0] == '?',
        .container => |occurrence| switch (occurrence.request) {
            .report_state, .report_position, .report_screen_cells, .report_icon_title => true,
            else => false,
        },
        .color_preference_query => true,
        else => false,
    };
}

const ConsequenceExpiry = struct {
    authority_client_id: protocol.ClientId = protocol.no_client,
    authority_revision: u64 = 0,
    generation: u64 = 0,
    started_ns: ?u64 = null,

    fn reset(self: *ConsequenceExpiry) void {
        self.* = .{};
    }

    fn sync(
        self: *ConsequenceExpiry,
        authority_client_id: ?protocol.ClientId,
        authority_revision: u64,
        consequence: ?howl.Consequence,
        now_ns: u64,
    ) void {
        const authority = authority_client_id orelse {
            self.reset();
            return;
        };
        const current = consequence orelse {
            self.reset();
            return;
        };
        if (!consequenceRequiresReply(current)) {
            self.reset();
            return;
        }
        if (self.started_ns != null and
            self.authority_client_id == authority and
            self.authority_revision == authority_revision and
            self.generation == current.id())
            return;
        self.authority_client_id = authority;
        self.authority_revision = authority_revision;
        self.generation = current.id();
        self.started_ns = now_ns;
    }

    fn waitMs(self: *const ConsequenceExpiry, now_ns: u64) ?u32 {
        const started_ns = self.started_ns orelse return null;
        const elapsed_ns = now_ns -| started_ns;
        const remaining_ns = consequence_reply_timeout_ns -| elapsed_ns;
        if (remaining_ns == 0) return 0;
        return @intCast(@min(
            (remaining_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms,
            std.math.maxInt(u32),
        ));
    }

    fn due(self: *const ConsequenceExpiry, now_ns: u64) bool {
        const started_ns = self.started_ns orelse return false;
        return now_ns -| started_ns >= consequence_reply_timeout_ns;
    }
};

const TerminalPublication = enum { none, burst_fast, burst_scroll, immediate };

fn boundedPollTimeout(
    timeout_ms: i32,
    animation_wait_ms: ?u32,
    publication_wait_ms: ?u32,
    consequence_wait_ms: ?u32,
) i32 {
    var result = if (timeout_ms < 0 or timeout_ms > lifecycle_poll_ms)
        lifecycle_poll_ms
    else
        timeout_ms;
    if (animation_wait_ms) |wait_ms| {
        const animation_timeout: i32 = @intCast(@min(
            wait_ms,
            @as(u32, @intCast(lifecycle_poll_ms)),
        ));
        result = @min(result, animation_timeout);
    }
    if (publication_wait_ms) |wait_ms| {
        const publication_timeout: i32 = @intCast(@min(
            wait_ms,
            @as(u32, @intCast(lifecycle_poll_ms)),
        ));
        result = @min(result, publication_timeout);
    }
    if (consequence_wait_ms) |wait_ms| {
        const consequence_timeout: i32 = @intCast(@min(
            wait_ms,
            @as(u32, @intCast(lifecycle_poll_ms)),
        ));
        result = @min(result, consequence_timeout);
    }
    return result;
}

// File map:
//   - bounded adopted-client storage
//   - one borrowed Instance and nonblocking client/service loop
//   - typed input adapters and renderer-complete snapshot publication
//   - one in-process byte-stream harness and service behavior proofs

const CachedImage = struct {
    id: u32,
    generation: u64,
    width: u32,
    height: u32,
    pixels: []u8,
};

const ImageResourceCache = struct {
    entries: std.ArrayList(CachedImage) = .empty,
    bytes: usize = 0,

    fn deinit(self: *ImageResourceCache, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| allocator.free(entry.pixels);
        self.entries.deinit(allocator);
        self.* = .{};
    }

    fn find(self: *const ImageResourceCache, id: u32, generation: u64) ?howl.Terminal.Image {
        for (self.entries.items) |entry| {
            if (entry.id != id or entry.generation != generation) continue;
            return .{
                .id = entry.id,
                .generation = entry.generation,
                .width = entry.width,
                .height = entry.height,
                .pixels = entry.pixels,
            };
        }
        return null;
    }

    fn captureVisible(
        allocator: std.mem.Allocator,
        images: *const howl.Terminal.Images,
    ) !ImageResourceCache {
        var result: ImageResourceCache = .{};
        errdefer result.deinit(allocator);
        var index: usize = 0;
        while (index < images.imageCount()) : (index += 1) {
            const image = images.image(index) orelse return error.InvalidSnapshot;
            if (!imageVisible(images, image.id)) continue;
            if (image.pixels.len > howl.Terminal.maximum_image_bytes or
                result.entries.items.len >= snapshot_image_entries or
                result.bytes > snapshot_image_bytes - image.pixels.len)
                return error.InvalidSnapshot;

            const pixels = try allocator.dupe(u8, image.pixels);
            errdefer allocator.free(pixels);
            try result.entries.append(allocator, .{
                .id = image.id,
                .generation = image.generation,
                .width = image.width,
                .height = image.height,
                .pixels = pixels,
            });
            result.bytes += pixels.len;
        }
        return result;
    }
};

comptime {
    if (howl.maximum_cell_scalars != protocol.text_v1.maximum_cell_scalars)
        @compileError("text_v1 scalar bound must match canonical VT grapheme bound");
    if (howl.Terminal.maximum_hyperlinks != protocol.text_v1.maximum_hyperlinks)
        @compileError("text_v1 hyperlink identity bound must match canonical VT bound");
    if (howl.Terminal.maximum_hyperlink_uri_bytes != protocol.text_v1.maximum_hyperlink_uri_bytes)
        @compileError("text_v1 hyperlink URI bound must match canonical VT bound");
    if (howl.Terminal.maximum_image_bytes != protocol.graphics_v2.maximum_image_bytes)
        @compileError("graphics image byte bound must match canonical VT bound");
    if (howl.Terminal.maximum_image_dimension != protocol.graphics_v2.maximum_dimension)
        @compileError("graphics image dimension bound must match canonical VT bound");
    if (howl.Terminal.maximum_images != protocol.graphics_v2.maximum_images)
        @compileError("graphics image count must match canonical VT bound");
    if (howl.Terminal.maximum_image_placements != protocol.graphics_v2.maximum_placements)
        @compileError("graphics placement count must match canonical VT bound");
    if (howl.maximum_key_text_bytes != protocol.typed_input.maximum_key_text_bytes)
        @compileError("typed key committed-text bound must match canonical VT bound");
    if (howl.maximum_legacy_key_bytes != protocol.typed_input.maximum_legacy_key_bytes)
        @compileError("typed key legacy-text bound must match canonical VT scratch bound");
}

/// Server-selected occurrence and catalogue revision used for one attachment.
pub const AttachContext = struct {
    server_id: u64,
    session_id: u64,
    instance_id: u64,
    tree_revision: u64,
};

const ObserveMode = enum { compressed, raw, delta, packed_text };

const Client = struct {
    stream: AdoptedStream,
    id: protocol.ClientId,
    input: []u8 = &.{},
    input_len: usize = 0,
    output: std.ArrayList(u8) = .empty,
    output_offset: usize = 0,
    observe: ?protocol.Observe = null,
    observe_mode: ObserveMode = .compressed,
    snapshot_images: ImageResourceCache = .{},

    fn outputPending(self: *const Client) bool {
        return self.output_offset < self.output.items.len;
    }

    fn resetOutput(self: *Client, allocator: std.mem.Allocator) void {
        if (self.output.capacity > client_output_retain_bytes) {
            self.output.deinit(allocator);
            self.output = .empty;
        } else {
            self.output.clearRetainingCapacity();
        }
        self.output_offset = 0;
    }

    fn deinit(self: *Client, allocator: std.mem.Allocator) void {
        closeAdoptedStream(self.stream);
        if (self.input.len != 0) allocator.free(self.input);
        self.output.deinit(allocator);
        self.snapshot_images.deinit(allocator);
        self.* = undefined;
    }
};

// =============================================================================
// Canonical Instance service
// =============================================================================

/// Owns bounded Server terminal interaction state around one borrowed PTY+VT Instance.
pub const Service = struct {
    // -------------------------------------------------------------------------
    // Retained interaction owners
    // -------------------------------------------------------------------------

    // Borrowed Instance lifetime and interaction-service state.
    allocator: std.mem.Allocator,
    io: std.Io,
    instance: *howl.Instance,
    // Bounded client table, identity issuance, and geometry authority.
    clients: [maximum_clients]?Client = @splat(null),
    next_client_id: protocol.ClientId = 1,
    authority: protocol.ResizeAuthority = .{},
    consequence_authority: protocol.ConsequenceAuthority = .{},
    consequence_expiry: ConsequenceExpiry = .{},
    // Instance observation, child lifecycle, and pending PTY output.
    observation_revision: u64 = 1,
    terminal_revision: u64,
    stream_closed: bool = false,
    child_exited: bool = false,
    pty_write_pending: bool = false,
    animation_wait_ms: ?u32 = null,
    synchronized_output_started_ns: ?u64 = null,
    synchronized_output_timed_out: bool = false,
    synchronized_output_pending: bool = false,
    burst_publication: BurstPublicationGate = .{},
    // Rich snapshots are serialized synchronously on the service turn, so
    // retain bounded scratch across observer cuts instead of returning the
    // same hot allocations to the allocator every frame.
    // Optional codec retains live generations or exact historical cells only
    // for delta observations; Server separately names the delivered predecessor.
    delta_rows: vt_encoder.DeltaCache = .{},
    delta_revision: u64 = 0,
    snapshot_body: std.ArrayList(u8) = .empty,
    text_compressor: codec.text.Compressor,

    // -------------------------------------------------------------------------
    // Construction and lifecycle loop
    // -------------------------------------------------------------------------

    fn initImpl(
        allocator: std.mem.Allocator,
        io: std.Io,
        instance: *howl.Instance,
    ) !Service {
        const text_compressor = try codec.text.Compressor.init(allocator);

        return .{
            .allocator = allocator,
            .io = io,
            .instance = instance,
            .terminal_revision = howl.terminal(instance).semanticSequence(),
            .text_compressor = text_compressor,
        };
    }

    /// Exact construction failures for one Instance interaction service.
    pub const InitError = @typeInfo(
        @typeInfo(@TypeOf(initImpl)).@"fn".return_type.?,
    ).error_union.error_set;

    /// Constructs client-stream service around one already-owned Instance.
    /// The caller retains Instance lifetime ownership and must deinit Service first.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        instance: *howl.Instance,
    ) InitError!Service {
        return initImpl(allocator, io, instance);
    }

    /// Releases attached clients and publication scratch, never the borrowed Instance.
    pub fn deinit(self: *Service) void {
        for (&self.clients) |*client| {
            if (client.*) |*active| active.deinit(self.allocator);
            client.* = null;
        }
        self.delta_rows.deinit(self.allocator);
        self.snapshot_body.deinit(self.allocator);
        self.text_compressor.deinit();
        self.* = undefined;
    }

    fn turnImpl(self: *Service, timeout_ms: i32) !void {
        if (comptime native_windows) return self.turnWindows(timeout_ms);
        return self.turnPosix(timeout_ms);
    }

    fn turnPosix(self: *Service, timeout_ms: i32) !void {
        try self.materializeObservers();
        try self.processBufferedRequests();

        var descriptors: [1 + maximum_clients]posix.pollfd = undefined;
        var pty_poll_events: i16 = 0;
        if (!self.stream_closed) pty_poll_events |= posix.POLL.IN | posix.POLL.HUP;
        if (self.pty_write_pending) pty_poll_events |= posix.POLL.OUT;
        descriptors[0] = .{
            .fd = if (self.stream_closed and !self.pty_write_pending) -1 else try howl.descriptor(self.instance),
            .events = pty_poll_events,
            .revents = 0,
        };
        for (self.clients, 0..) |client, index| {
            var client_poll_events: i16 = posix.POLL.HUP | posix.POLL.ERR;
            if (client) |active| {
                client_poll_events |= if (active.outputPending()) posix.POLL.OUT else posix.POLL.IN;
            }
            descriptors[1 + index] = if (client) |active| .{
                .fd = active.stream,
                .events = client_poll_events,
                .revents = 0,
            } else .{ .fd = -1, .events = 0, .revents = 0 };
        }

        const poll_now_ns = nowNs(self.io);
        self.syncConsequenceExpiry(poll_now_ns);
        const output_buffered = howl.bufferedOutputPending(self.instance);
        const poll_timeout = boundedPollTimeout(
            if (output_buffered and !self.pty_write_pending) 0 else timeout_ms,
            self.animation_wait_ms,
            self.burst_publication.waitMs(poll_now_ns),
            self.consequence_expiry.waitMs(poll_now_ns),
        );
        const ready_count = try posix.poll(&descriptors, poll_timeout);
        std.debug.assert(ready_count <= descriptors.len);

        const pty_events = descriptors[0].revents;
        const pty_present = descriptors[0].fd >= 0;
        const pty_read_ready = pty_present and pty_events & (posix.POLL.IN | posix.POLL.HUP) != 0;
        const service_now_ns = nowNs(self.io);
        self.expireConsequenceAuthority(service_now_ns);
        const result = try howl.serviceWithConsequencePolicy(
            self.instance,
            pty_read_ready,
            pty_present and pty_events & posix.POLL.OUT != 0,
            service_now_ns,
            self.consequencePolicy(),
        );
        self.applyServiceResult(result, service_now_ns, pty_read_ready or output_buffered);
        self.syncConsequenceExpiry(service_now_ns);

        var index: usize = 0;
        while (index < self.clients.len) : (index += 1) {
            const events = descriptors[1 + index].revents;
            if (events == 0 or self.clients[index] == null) continue;
            if (events & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0) {
                self.closeClient(index);
                continue;
            }
            if (events & posix.POLL.OUT != 0) if (self.writeClient(index)) {};
            if (self.clients[index] != null and events & posix.POLL.IN != 0)
                if (self.readClient(index)) {};
        }

        try self.processBufferedRequests();
        try self.materializeObservers();
        self.syncConsequenceExpiry(nowNs(self.io));
    }

    fn turnWindows(self: *Service, timeout_ms: i32) !void {
        try self.materializeObservers();
        try self.processBufferedRequests();

        var progressed = false;
        var index: usize = 0;
        while (index < self.clients.len) : (index += 1) {
            progressed = self.writeClient(index) or progressed;
            if (self.clients[index] != null)
                progressed = self.readClient(index) or progressed;
        }
        try self.processBufferedRequests();

        const service_now_ns = nowNs(self.io);
        self.expireConsequenceAuthority(service_now_ns);
        const previous_stream_closed = self.stream_closed;
        const previous_child_exited = self.child_exited;
        const previous_write_pending = self.pty_write_pending;
        const result = try howl.serviceWithConsequencePolicy(
            self.instance,
            true,
            true,
            service_now_ns,
            self.consequencePolicy(),
        );
        self.applyServiceResult(result, service_now_ns, true);
        progressed = progressed or result.changed or
            previous_stream_closed != self.stream_closed or
            previous_child_exited != self.child_exited or
            previous_write_pending != self.pty_write_pending;
        self.syncConsequenceExpiry(service_now_ns);

        try self.processBufferedRequests();
        try self.materializeObservers();
        index = 0;
        while (index < self.clients.len) : (index += 1)
            progressed = self.writeClient(index) or progressed;
        self.syncConsequenceExpiry(nowNs(self.io));

        if (!progressed and !(howl.bufferedOutputPending(self.instance) and !self.pty_write_pending)) {
            const wait_ms = boundedPollTimeout(
                timeout_ms,
                self.animation_wait_ms,
                self.burst_publication.waitMs(nowNs(self.io)),
                self.consequence_expiry.waitMs(nowNs(self.io)),
            );
            if (wait_ms > 0)
                std.Io.sleep(self.io, .fromMilliseconds(@intCast(wait_ms)), .awake) catch
                    return error.ServiceWaitFailed;
        }
    }

    /// Exact failures from one interaction service turn.
    pub const TurnError = @typeInfo(
        @typeInfo(@TypeOf(turnImpl)).@"fn".return_type.?,
    ).error_union.error_set;

    /// Services one bounded service/PTY/client turn.
    pub fn turn(self: *Service, timeout_ms: i32) TurnError!void {
        return self.turnImpl(timeout_ms);
    }

    /// Read-only lifecycle facts already owned by this interaction envelope.
    pub const Lifecycle = struct {
        stream_closed: bool,
        child_exited: bool,
    };

    /// Returns the current immutable interaction lifecycle envelope.
    pub fn lifecycle(self: *const Service) Lifecycle {
        return .{
            .stream_closed = self.stream_closed,
            .child_exited = self.child_exited,
        };
    }

    /// Returns the bounded number of currently attached Server terminal client streams.
    pub fn clientCount(self: *const Service) u16 {
        var count: u16 = 0;
        for (self.clients) |client| {
            if (client != null) count += 1;
        }
        return count;
    }

    /// True when this service must receive a turn even if its PTY is not ready.
    /// Runtime may otherwise wait on the PTY descriptor directly.
    pub fn requiresTurnWithoutPtyReadiness(self: *const Service) bool {
        // Once the stream closes, service turns still own child-exit reconciliation.
        if (self.stream_closed and !self.child_exited) return true;
        if (howl.bufferedOutputPending(self.instance) or self.pty_write_pending or self.clientCount() != 0) return true;
        if (self.animation_wait_ms != null) return true;
        if (self.synchronized_output_started_ns != null or self.synchronized_output_pending) return true;
        if (self.burst_publication.started_ns != null) return true;
        if (self.consequence_expiry.started_ns != null) return true;
        if (howl.consequenceHead(self.instance) != null) return true;
        return false;
    }

    /// Returns the PTY fd only when Runtime may safely sleep on PTY readiness
    /// instead of scheduling unconditional service turns.
    pub fn waitDescriptor(self: *const Service) error{NotStarted}!?howl.Descriptor {
        if (comptime native_windows) return null;
        if (self.stream_closed or self.requiresTurnWithoutPtyReadiness()) return null;
        return try howl.descriptor(self.instance);
    }

    /// True while an exited interaction envelope still needs service turns.
    pub fn hasRetainedWork(self: *const Service) bool {
        if (!self.child_exited) return true;
        if (!self.stream_closed or self.pty_write_pending) return true;
        return self.requiresTurnWithoutPtyReadiness();
    }

    /// Exact admission failures for an already-connected client stream.
    pub const AdoptError = std.mem.Allocator.Error || server_protocol.PayloadError || error{
        ClientCapacity,
        InitialInputTooLarge,
        PayloadTooLarge,
        SocketOptionFailed,
    };

    /// Adopts one exact attachment and queues its complete Server-ready response.
    /// On success this service owns the stream; failure leaves it with the caller.
    /// Buffered terminal input is parsed only after attachment-ready has drained.
    pub fn adoptClient(
        self: *Service,
        stream: AdoptedStream,
        initial_input: []const u8,
        context: AttachContext,
    ) AdoptError!void {
        if (initial_input.len > input_buffer_bytes) return error.InitialInputTooLarge;
        const slot = self.freeClientSlot() orelse return error.ClientCapacity;
        const ready = server_protocol.AttachReady{
            .server_id = context.server_id,
            .session_id = context.session_id,
            .instance_id = context.instance_id,
            .tree_revision = context.tree_revision,
            .client_id = self.next_client_id,
        };
        var preface: [server_protocol.header_bytes + server_protocol.payload_bytes.attach_ready]u8 = undefined;
        try server_protocol.encodeAttachReady(preface[server_protocol.header_bytes..], ready);
        try server_protocol.encodeHeader(preface[0..server_protocol.header_bytes], .{ .kind = .attach_ready, .payload_len = server_protocol.payload_bytes.attach_ready });

        const input = try self.allocator.alloc(u8, input_buffer_bytes);
        errdefer self.allocator.free(input);
        @memcpy(input[0..initial_input.len], initial_input);
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        try output.appendSlice(self.allocator, &preface);
        try configureAdoptedStream(stream);
        const id = self.nextClientId();
        std.debug.assert(id == ready.client_id);
        self.clients[slot] = .{
            .stream = stream,
            .id = id,
            .input = input,
            .input_len = initial_input.len,
            .output = output,
        };
    }

    fn consequencePolicy(self: *const Service) howl.ConsequencePolicy {
        return if (self.consequence_authority.leader() != null) .retain else .headless;
    }

    fn syncConsequenceExpiry(self: *Service, now_ns: u64) void {
        self.consequence_expiry.sync(
            self.consequence_authority.leader(),
            self.consequence_authority.revision,
            howl.consequenceHead(self.instance),
            now_ns,
        );
    }

    fn expireConsequenceAuthority(self: *Service, now_ns: u64) void {
        if (!self.consequence_expiry.due(now_ns)) return;
        const authority = self.consequence_authority.leader() orelse {
            self.consequence_expiry.reset();
            return;
        };
        const current = howl.consequenceHead(self.instance) orelse {
            self.consequence_expiry.reset();
            return;
        };
        if (authority != self.consequence_expiry.authority_client_id or
            self.consequence_authority.revision != self.consequence_expiry.authority_revision or
            current.id() != self.consequence_expiry.generation or
            !consequenceRequiresReply(current))
        {
            self.syncConsequenceExpiry(now_ns);
            return;
        }
        const revoked = self.consequence_authority.assign(protocol.no_client);
        std.debug.assert(revoked);
        self.consequence_expiry.reset();
        self.burst_publication.reset();
    }

    // -------------------------------------------------------------------------
    // Client acceptance and byte-stream I/O
    // -------------------------------------------------------------------------

    fn freeClientSlot(self: *Service) ?usize {
        for (self.clients, 0..) |client, index| if (client == null) return index;
        return null;
    }

    fn nextClientId(self: *Service) protocol.ClientId {
        const id = self.next_client_id;
        self.next_client_id = std.math.add(protocol.ClientId, id, 1) catch 1;
        if (self.next_client_id == protocol.no_client) self.next_client_id = 1;
        return id;
    }

    fn readClient(self: *Service, index: usize) bool {
        if (comptime native_windows) return self.readClientWindows(index);
        const client = if (self.clients[index]) |*active| active else return false;
        if (client.outputPending() or client.input_len == client.input.len) return false;
        const room = client.input[client.input_len..];
        const result = linux.read(client.stream, room.ptr, room.len);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0 or result > room.len) {
                    self.closeClient(index);
                    return true;
                }
                client.input_len += result;
                return true;
            },
            .AGAIN, .INTR => return false,
            else => {
                self.closeClient(index);
                return true;
            },
        }
    }

    fn writeClient(self: *Service, index: usize) bool {
        if (comptime native_windows) return self.writeClientWindows(index);
        const client = if (self.clients[index]) |*active| active else return false;
        if (!client.outputPending()) return false;
        const bytes = client.output.items[client.output_offset..];
        const result = linux.write(client.stream, bytes.ptr, bytes.len);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0 or result > bytes.len) {
                    self.closeClient(index);
                    return true;
                }
                client.output_offset += result;
                if (!client.outputPending()) client.resetOutput(self.allocator);
                return true;
            },
            .AGAIN, .INTR => return false,
            .PIPE, .CONNRESET => {
                self.closeClient(index);
                return true;
            },
            else => {
                self.closeClient(index);
                return true;
            },
        }
    }

    fn readClientWindows(self: *Service, index: usize) bool {
        const client = if (self.clients[index]) |*active| active else return false;
        if (client.outputPending() or client.input_len == client.input.len) return false;
        const room = client.input[client.input_len..];
        var available: u32 = 0;
        if (!PeekNamedPipe(client.stream.read, null, 0, null, &available, null).toBool()) {
            self.closeClient(index);
            return true;
        }
        if (available == 0) return false;
        const count: u32 = @intCast(@min(
            @min(room.len, @as(usize, available)),
            @as(usize, std.math.maxInt(u32)),
        ));
        var read_count: u32 = 0;
        // zig-audit: acknowledge ptr_cast
        // reason: ReadFile writes at most count bytes into this already-bounded live output slice and retains no borrowed pointer.
        if (!ReadFile(client.stream.read, @ptrCast(room.ptr), count, &read_count, null).toBool()) {
            switch (windows.GetLastError()) {
                .NO_DATA => return false,
                else => {
                    self.closeClient(index);
                    return true;
                },
            }
        }
        if (read_count == 0) {
            self.closeClient(index);
            return true;
        }
        client.input_len += read_count;
        return true;
    }

    fn writeClientWindows(self: *Service, index: usize) bool {
        const client = if (self.clients[index]) |*active| active else return false;
        if (!client.outputPending()) return false;
        const bytes = client.output.items[client.output_offset..];
        const count: u32 = @intCast(@min(
            bytes.len,
            @min(windows_pipe_write_chunk_bytes, @as(usize, std.math.maxInt(u32))),
        ));
        var written: u32 = 0;
        // zig-audit: acknowledge ptr_cast
        // reason: WriteFile borrows count bytes from this already-bounded live input slice and retains no pointer after the synchronous call.
        if (!WriteFile(client.stream.write, @ptrCast(bytes.ptr), count, &written, null).toBool()) {
            switch (windows.GetLastError()) {
                .NO_DATA => return false,
                else => {
                    self.closeClient(index);
                    return true;
                },
            }
        }
        if (written == 0) return false;
        client.output_offset += written;
        if (!SetEvent(client.stream.peer_read_event).toBool()) {
            self.closeClient(index);
            return true;
        }
        if (!client.outputPending()) client.resetOutput(self.allocator);
        return true;
    }

    // -------------------------------------------------------------------------
    // Request framing and dispatch
    // -------------------------------------------------------------------------

    fn processBufferedRequests(self: *Service) !void {
        var index: usize = 0;
        while (index < self.clients.len) : (index += 1) {
            while (self.clients[index]) |*client| {
                if (client.outputPending() or client.observe != null) break;
                if (client.input_len < protocol.header_bytes) break;
                var header_bytes: [protocol.header_bytes]u8 = undefined;
                @memcpy(&header_bytes, client.input[0..protocol.header_bytes]);
                const header = protocol.decodeHeader(&header_bytes) catch {
                    self.closeClient(index);
                    break;
                };
                if (header.payload_len > maximum_request_payload) {
                    self.closeClient(index);
                    break;
                }
                const frame_len = protocol.header_bytes + @as(usize, header.payload_len);
                if (client.input_len < frame_len) break;
                var payload: [maximum_request_payload]u8 = undefined;
                @memcpy(payload[0..header.payload_len], client.input[protocol.header_bytes..frame_len]);
                const remaining = client.input_len - frame_len;
                std.mem.copyForwards(u8, client.input[0..remaining], client.input[frame_len..client.input_len]);
                client.input_len = remaining;
                self.handleFrame(index, header.kind, payload[0..header.payload_len]) catch |err| {
                    // Only response construction is tagged client-local. Canonical
                    // PTY/VT service failures retain their outward error channel.
                    if (err != error.ClientResponseOutOfMemory) return err;
                    self.closeClient(index);
                    break;
                };
            }
        }
    }

    fn handleFrame(self: *Service, index: usize, kind: protocol.Kind, payload: []const u8) !void {
        const client = if (self.clients[index]) |*active| active else return;
        switch (kind) {
            .observe, .observe_raw, .observe_delta, .observe_packed => {
                const request = protocol.decodeObserve(payload) catch {
                    try self.queueResult(client, kind, .malformed);
                    return;
                };
                if (request.after_revision > self.observation_revision) {
                    try self.queueResult(client, kind, .malformed);
                    return;
                }
                client.observe = request;
                client.observe_mode = switch (kind) {
                    .observe => .compressed,
                    .observe_raw => .raw,
                    .observe_delta => .delta,
                    .observe_packed => .packed_text,
                    // zig-audit: acknowledge unreachable
                    // reason: The enclosing request-kind arm admits only observe, observe_raw, observe_delta and observe_packed; kind is unchanged here.
                    else => unreachable,
                };
            },
            .input => try self.handleInput(client, payload),
            .assign_leader => try self.handleAssignLeader(client, payload),
            .assign_consequence_leader => try self.handleAssignConsequenceLeader(client, payload),
            .consequence_observe => try self.handleConsequenceObserve(client, payload),
            .consequence_consume => try self.handleConsequenceConsume(client, payload),
            .consequence_reply => try self.handleConsequenceReply(client, payload),
            .resize => try self.handleResize(client, payload),
            .signal => try self.handleSignal(client, payload),
            .interaction_state => try self.handleInteractionState(client, payload),
            .text_extract => try self.handleTextExtract(client, payload),
            .image_request => try self.handleImageRequest(client, payload),
            else => try self.queueResult(client, kind, .unsupported),
        }
    }

    // -------------------------------------------------------------------------
    // Semantic input and interaction state
    // -------------------------------------------------------------------------

    fn handleInput(self: *Service, client: *Client, payload: []const u8) !void {
        if (payload.len == 0) return self.queueResult(client, .input, .malformed);
        const kind: protocol.InputKind = switch (payload[0]) {
            @backingInt(protocol.InputKind.bytes) => .bytes,
            @backingInt(protocol.InputKind.paste) => .paste,
            @backingInt(protocol.InputKind.key) => .key,
            @backingInt(protocol.InputKind.mouse) => .mouse,
            @backingInt(protocol.InputKind.focus) => .focus,
            else => return self.queueResult(client, .input, .unsupported),
        };
        const event: howl.Input = switch (kind) {
            .bytes => .{ .bytes = payload[1..] },
            .paste => .{ .paste = payload[1..] },
            .key => blk: {
                const value = protocol.decodeKeyInput(payload[1..]) catch
                    return self.queueResult(client, .input, .malformed);
                const key: howl.Key = switch (value.kind) {
                    .named => .{ .named = typedKeyName(value.key_value) orelse
                        return self.queueResult(client, .input, .malformed) },
                    .unicode => howl.Key.initUnicode(@intCast(value.key_value)) catch
                        return self.queueResult(client, .input, .malformed),
                };
                break :blk .{ .key = .{
                    .key = key,
                    .mods = typedModifiers(value.modifiers),
                    .action = typedKeyAction(value.action),
                    .shifted = if (value.shifted) |scalar| @intCast(scalar) else null,
                    .alternate = if (value.alternate) |scalar| @intCast(scalar) else null,
                    .legacy_text = value.legacy_text,
                    .text = value.text,
                } };
            },
            .mouse => blk: {
                const value = protocol.decodeMouseInput(payload[1..]) catch
                    return self.queueResult(client, .input, .malformed);
                break :blk .{ .mouse = .{
                    .kind = typedMouseKind(value.kind),
                    .button = typedMouseButton(value.button),
                    .row = value.row,
                    .col = value.column,
                    .pixel_x = value.pixel_x,
                    .pixel_y = value.pixel_y,
                    .mod = typedModifiers(value.modifiers),
                    .buttons_down = value.buttons_down,
                } };
            },
            .focus => blk: {
                const value = protocol.decodeFocusInput(payload[1..]) catch
                    return self.queueResult(client, .input, .malformed);
                break :blk .{ .focus = switch (value) {
                    .in => .in,
                    .out => .out,
                } };
            },
        };
        howl.input(self.instance, event) catch return self.queueResult(client, .input, .rejected);
        const service_now_ns = nowNs(self.io);
        const serviced = try howl.serviceWithConsequencePolicy(
            self.instance,
            false,
            true,
            service_now_ns,
            self.consequencePolicy(),
        );
        self.applyServiceResult(serviced, service_now_ns, false);
        try self.queueResult(client, .input, .ok);
    }

    fn handleInteractionState(self: *Service, client: *Client, payload: []const u8) !void {
        if (payload.len != protocol.payload_bytes.interaction_state)
            return self.queueResult(client, .interaction_state, .malformed);
        const state = howl.terminal(self.instance).interactionState();
        var encoded: [protocol.payload_bytes.interaction_state_snapshot]u8 = undefined;
        protocol.encodeInteractionStateSnapshot(&encoded, .{
            .terminal_revision = howl.terminal(self.instance).semanticSequence(),
            .keyboard_action_mode = state.keyboard_action_mode,
            .auto_repeat = state.auto_repeat,
            .newline_mode = state.newline_mode,
            .application_cursor_keys = state.application_cursor_keys,
            .application_keypad = state.application_keypad,
            .meta_sends_escape = state.meta_sends_escape,
            .report_key_up = state.report_key_up,
            .bracketed_paste = state.bracketed_paste,
            .focus_reporting = state.focus_reporting,
            .termios_signals = state.termios_signals,
            .alternate_scroll = state.alternate_scroll,
            .paste_events = state.paste_events,
            .inband_resize_notifications = state.inband_resize_notifications,
            .mouse_tracking = switch (state.mouse_tracking) {
                .off => .off,
                .x10 => .x10,
                .normal => .normal,
                .button_event => .button_event,
                .any_event => .any_event,
            },
            .mouse_protocol = switch (state.mouse_protocol) {
                .none => .none,
                .utf8 => .utf8,
                .sgr => .sgr,
                .sgr_pixel => .sgr_pixel,
                .urxvt => .urxvt,
            },
            .modify_other_keys = state.modify_other_keys,
            .kitty_keyboard_flags = state.kitty_keyboard_flags,
            .key_format_resource_4 = state.key_format_resource_4,
            .pointer_mode = state.pointer_mode,
        });
        try self.queueFrame(client, .interaction_state_snapshot, &encoded);
    }

    fn handleTextExtract(self: *Service, client: *Client, payload: []const u8) !void {
        const request = protocol.decodeTextExtract(payload) catch
            return self.queueResult(client, .text_extract, .malformed);
        const machine = howl.terminal(self.instance);
        const current = machine.semanticView(0);
        if (request.columns != current.cols or request.alternate_screen != current.is_alternate_screen)
            return self.queueResult(client, .text_extract, .rejected);
        const text = machine.copyText(
            self.allocator,
            .{
                .start = .{ .row = request.start.row, .col = request.start.column },
                .end = .{ .row = request.end.row, .col = request.end.column },
            },
            protocol.maximum_payload_bytes,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.ClientResponseOutOfMemory,
            else => return self.queueResult(client, .text_extract, .rejected),
        };
        defer self.allocator.free(text);
        try self.queueFrame(client, .text_extract_data, text);
    }

    fn handleImageRequest(self: *Service, client: *Client, payload: []const u8) !void {
        const request = protocol.decodeImageRequest(payload) catch
            return self.queueResult(client, .image_request, .malformed);
        const image = terminalImage(howl.terminal(self.instance), request.image_id, request.generation) orelse
            client.snapshot_images.find(request.image_id, request.generation) orelse
            return self.queueResult(client, .image_request, .rejected);
        const expected = std.math.mul(u64, image.width, image.height) catch
            return self.queueResult(client, .image_request, .rejected);
        const rgba_bytes = std.math.mul(u64, expected, 4) catch
            return self.queueResult(client, .image_request, .rejected);
        if (rgba_bytes != image.pixels.len or rgba_bytes > protocol.graphics_v2.maximum_image_bytes)
            return self.queueResult(client, .image_request, .rejected);

        const data_frames = std.math.divCeil(
            usize,
            image.pixels.len,
            protocol.image_data_chunk_bytes,
        ) catch return self.queueResult(client, .image_request, .rejected);
        const total_bound = protocol.header_bytes + protocol.payload_bytes.image_begin +
            data_frames * protocol.header_bytes + image.pixels.len +
            protocol.header_bytes + protocol.payload_bytes.image_end;

        client.resetOutput(self.allocator);
        errdefer client.resetOutput(self.allocator);
        client.output.ensureTotalCapacity(self.allocator, total_bound) catch return error.ClientResponseOutOfMemory;
        var begin: [protocol.payload_bytes.image_begin]u8 = undefined;
        protocol.encodeImageBegin(&begin, .{
            .image_id = image.id,
            .generation = image.generation,
            .width = image.width,
            .height = image.height,
            .byte_count = @intCast(image.pixels.len),
        });
        try self.appendFrame(&client.output, .image_begin, &begin);
        var offset: usize = 0;
        while (offset < image.pixels.len) {
            const count = @min(protocol.image_data_chunk_bytes, image.pixels.len - offset);
            try self.appendFrame(&client.output, .image_data, image.pixels[offset..][0..count]);
            offset += count;
        }
        var end: [protocol.payload_bytes.image_end]u8 = undefined;
        protocol.encodeImageEnd(&end, .{ .image_id = image.id, .generation = image.generation });
        try self.appendFrame(&client.output, .image_end, &end);
        std.debug.assert(client.output.items.len == total_bound);
        client.output_offset = 0;
    }

    const ConsequenceWire = struct {
        generation: u64 = 0,
        kind: protocol.ConsequenceKind = .none,
        reply_required: bool = false,
        metadata: [protocol.consequence_metadata_bytes]u8 = @splat(0),
        payload: []const u8 = &.{},
    };

    fn writeMetadataU16(output: []u8, value: u16) void {
        std.debug.assert(output.len == 2);
        output[0] = @truncate(value >> 8);
        output[1] = @truncate(value);
    }

    fn writeMetadataU32(output: []u8, value: u32) void {
        std.debug.assert(output.len == 4);
        output[0] = @truncate(value >> 24);
        output[1] = @truncate(value >> 16);
        output[2] = @truncate(value >> 8);
        output[3] = @truncate(value);
    }

    fn writeMetadataU64(output: []u8, value: u64) void {
        std.debug.assert(output.len == 8);
        for (0..8) |index| output[index] = @truncate(value >> @intCast((7 - index) * 8));
    }

    fn consequenceClipboardProtocol(value: howl.Consequence) protocol.ConsequenceClipboardProtocol {
        return switch (value.clipboard.protocol) {
            .osc52 => .osc52,
            .kitty_5522 => .kitty_5522,
        };
    }

    fn consequenceClipboardKind(value: howl.Consequence) protocol.ConsequenceClipboardKind {
        return switch (value.clipboard.kind) {
            .set => .set,
            .query => .query,
            .packet => .packet,
        };
    }

    fn consequenceWire(value: ?howl.Consequence) !ConsequenceWire {
        const consequence = value orelse return .{};
        var result: ConsequenceWire = .{
            .generation = consequence.id(),
            .reply_required = consequenceRequiresReply(consequence),
        };
        switch (consequence) {
            .clipboard => |request| {
                if (request.selection.len > protocol.consequence_clipboard_selection_bytes)
                    return error.InvalidConsequence;
                result.kind = .clipboard;
                result.metadata[0] = @backingInt(consequenceClipboardProtocol(consequence));
                result.metadata[1] = @backingInt(consequenceClipboardKind(consequence));
                result.metadata[2] = @intCast(request.selection.len);
                @memcpy(result.metadata[4..][0..request.selection.len], request.selection);
                result.payload = request.payload;
            },
            .notification => |notification| {
                result.kind = .notification;
                result.metadata[0] = @backingInt(switch (notification.kind) {
                    .message => protocol.ConsequenceNotificationKind.message,
                    .steal_focus => .steal_focus,
                    .request_attention => .request_attention,
                });
                writeMetadataU16(result.metadata[2..4], notification.command);
                result.payload = notification.payload;
            },
            .pointer_shape => |request| {
                result.kind = .pointer_shape;
                writeMetadataU64(result.metadata[0..8], request.reset_generation);
                result.metadata[8] = @intFromBool(request.alternate_screen);
                result.payload = request.payload;
            },
            .file_transfer => |packet| {
                result.kind = .file_transfer;
                result.metadata[0] = @backingInt(switch (packet.protocol) {
                    .iterm2_1337 => protocol.ConsequenceFileTransferProtocol.iterm2_1337,
                    .kitty_5113 => .kitty_5113,
                });
                result.payload = packet.payload;
            },
            .drag_drop => |command| {
                result.kind = .drag_drop;
                result.metadata[0] = @backingInt(switch (command.kind) {
                    .enable => protocol.ConsequenceDragDropKind.enable,
                    .disable => .disable,
                    .accept => .accept,
                    .request => .request,
                    .complete => .complete,
                    .query => .query,
                    .continuation => .continuation,
                    .unsupported => .unsupported,
                });
                result.metadata[1] = command.command;
                var flags: u8 = 0;
                if (command.more) flags |= 0x01;
                if (command.remote) flags |= 0x02;
                if (command.client_id) |id| {
                    flags |= 0x04;
                    writeMetadataU32(result.metadata[4..8], id);
                }
                if (command.operation) |operation| {
                    flags |= 0x08;
                    writeMetadataU32(result.metadata[8..12], operation);
                }
                if (command.index) |index| {
                    flags |= 0x10;
                    writeMetadataU32(result.metadata[12..16], index);
                }
                result.metadata[2] = flags;
                result.payload = command.payload;
            },
            .container => |occurrence| {
                result.kind = .container;
                result.metadata[0] = @backingInt(switch (occurrence.request) {
                    .deiconify => protocol.ConsequenceContainerKind.deiconify,
                    .iconify => .iconify,
                    .move => .move,
                    .resize_pixels => .resize_pixels,
                    .raise => .raise,
                    .lower => .lower,
                    .resize_rows => .resize_rows,
                    .resize_columns => .resize_columns,
                    .resize_cells => .resize_cells,
                    .report_state => .report_state,
                    .report_position => .report_position,
                    .report_screen_cells => .report_screen_cells,
                    .report_icon_title => .report_icon_title,
                });
                switch (occurrence.request) {
                    .move => |request| {
                        writeMetadataU32(result.metadata[4..8], request.x);
                        writeMetadataU32(result.metadata[8..12], request.y);
                    },
                    .resize_pixels => |request| {
                        writeMetadataU32(result.metadata[4..8], request.height);
                        writeMetadataU32(result.metadata[8..12], request.width);
                    },
                    .resize_rows => |rows| writeMetadataU32(result.metadata[4..8], rows),
                    .resize_columns => |columns| writeMetadataU32(result.metadata[4..8], @backingInt(columns)),
                    .resize_cells => |request| {
                        writeMetadataU32(result.metadata[4..8], request.rows);
                        writeMetadataU32(result.metadata[8..12], request.cols);
                    },
                    else => {},
                }
            },
            .color_preference_query => {
                result.kind = .color_preference;
            },
            .media_copy => |occurrence| {
                result.kind = .media_copy;
                result.metadata[0] = @intFromBool(occurrence.request.private);
                writeMetadataU16(result.metadata[2..4], occurrence.request.parameter);
            },
            .bell => result.kind = .bell,
            .legacy_control => |occurrence| {
                result.kind = .legacy_control;
                result.metadata[0] = @backingInt(switch (occurrence.kind) {
                    .tek_point_plot => protocol.ConsequenceLegacyControlKind.tek_point_plot,
                    .tek_graph => .tek_graph,
                    .tek_incremental_plot => .tek_incremental_plot,
                    .tek_alpha => .tek_alpha,
                    .tek_copy => .tek_copy,
                    .tek_special_point_plot => .tek_special_point_plot,
                    .tek_write_thru_short_dashed => .tek_write_thru_short_dashed,
                    .hp_memory_lock => .hp_memory_lock,
                });
            },
            .dcs => |occurrence| {
                result.kind = .dcs;
                result.metadata[0] = @backingInt(switch (occurrence.kind) {
                    .xtsettcap => protocol.ConsequenceDcsKind.xtsettcap,
                    .decudk => .decudk,
                    .decaupss => .decaupss,
                    .iterm_tmux_hook => .iterm_tmux_hook,
                    .iterm_ssh_hook => .iterm_ssh_hook,
                    .iterm_tmux_wrap => .iterm_tmux_wrap,
                    .kitty_remote_command => .kitty_remote_command,
                    .kitty_overlay_ready => .kitty_overlay_ready,
                    .kitty_result => .kitty_result,
                    .kitty_print => .kitty_print,
                    .kitty_echo => .kitty_echo,
                    .kitty_ssh => .kitty_ssh,
                    .kitty_askpass => .kitty_askpass,
                    .kitty_clone => .kitty_clone,
                    .kitty_edit => .kitty_edit,
                });
                result.payload = occurrence.payload;
            },
            .string_control => |occurrence| {
                result.kind = .string_control;
                result.metadata[0] = @backingInt(switch (occurrence.kind) {
                    .apc => protocol.ConsequenceStringKind.apc,
                    .pm => .pm,
                    .sos => .sos,
                });
                result.payload = occurrence.payload;
            },
        }
        if (result.payload.len > protocol.maximum_consequence_payload_bytes)
            return error.InvalidConsequence;
        return result;
    }

    fn handleConsequenceObserve(self: *Service, client: *Client, payload: []const u8) !void {
        if (payload.len != protocol.payload_bytes.consequence_observe)
            return self.queueResult(client, .consequence_observe, .malformed);
        if (client.outputPending()) return error.ResponseAlreadyPending;
        const snapshot = try consequenceWire(howl.consequenceHead(self.instance));
        const data_frames = std.math.divCeil(
            usize,
            snapshot.payload.len,
            protocol.consequence_data_chunk_bytes,
        ) catch return error.PayloadTooLarge;
        const total_bound = protocol.header_bytes + protocol.payload_bytes.consequence_begin +
            data_frames * protocol.header_bytes + snapshot.payload.len +
            protocol.header_bytes + protocol.payload_bytes.consequence_end;
        client.resetOutput(self.allocator);
        errdefer client.resetOutput(self.allocator);
        client.output.ensureTotalCapacity(self.allocator, total_bound) catch return error.ClientResponseOutOfMemory;
        var begin: [protocol.payload_bytes.consequence_begin]u8 = undefined;
        try protocol.encodeConsequenceBegin(&begin, .{
            .terminal_revision = howl.terminal(self.instance).semanticSequence(),
            .authority_client_id = self.consequence_authority.leader() orelse protocol.no_client,
            .generation = snapshot.generation,
            .payload_len = @intCast(snapshot.payload.len),
            .kind = snapshot.kind,
            .reply_required = snapshot.reply_required,
            .metadata = snapshot.metadata,
        });
        try self.appendFrame(&client.output, .consequence_begin, &begin);
        var offset: usize = 0;
        while (offset < snapshot.payload.len) {
            const count = @min(protocol.consequence_data_chunk_bytes, snapshot.payload.len - offset);
            try self.appendFrame(&client.output, .consequence_data, snapshot.payload[offset..][0..count]);
            offset += count;
        }
        var end: [protocol.payload_bytes.consequence_end]u8 = undefined;
        protocol.encodeConsequenceEnd(&end, snapshot.generation);
        try self.appendFrame(&client.output, .consequence_end, &end);
        std.debug.assert(client.output.items.len == total_bound);
        client.output_offset = 0;
    }

    fn handleConsequenceConsume(self: *Service, client: *Client, payload: []const u8) !void {
        if (!self.consequence_authority.mayHandle(client.id))
            return self.queueResult(client, .consequence_consume, .not_leader);
        const generation = protocol.decodeConsequenceIdentity(payload) catch
            return self.queueResult(client, .consequence_consume, .malformed);
        howl.consumeConsequence(self.instance, generation) catch
            return self.queueResult(client, .consequence_consume, .rejected);
        try self.queueResult(client, .consequence_consume, .ok);
    }

    fn handleConsequenceReply(self: *Service, client: *Client, payload: []const u8) !void {
        if (!self.consequence_authority.mayHandle(client.id))
            return self.queueResult(client, .consequence_reply, .not_leader);
        const reply = protocol.decodeConsequenceReply(payload) catch
            return self.queueResult(client, .consequence_reply, .malformed);
        switch (reply.kind) {
            .clipboard => {
                const replied = howl.replyClipboard(self.instance, reply.generation, reply.body) catch
                    return self.queueResult(client, .consequence_reply, .rejected);
                if (!replied) return self.queueResult(client, .consequence_reply, .rejected);
            },
            .pointer_shape => howl.replyPointerShape(self.instance, reply.generation, reply.body) catch
                return self.queueResult(client, .consequence_reply, .rejected),
            .color_preference => howl.replyColorPreference(
                self.instance,
                reply.generation,
                if (reply.body[0] == 1) .dark else .light,
            ) catch return self.queueResult(client, .consequence_reply, .rejected),
            .container_state => howl.replyContainer(
                self.instance,
                reply.generation,
                .{ .state = if (reply.body[0] == 1) .normal else .iconified },
            ) catch return self.queueResult(client, .consequence_reply, .rejected),
            .container_position => howl.replyContainer(
                self.instance,
                reply.generation,
                .{ .position = .{ .x = readU32(reply.body[0..4]), .y = readU32(reply.body[4..8]) } },
            ) catch return self.queueResult(client, .consequence_reply, .rejected),
            .container_screen_cells => howl.replyContainer(
                self.instance,
                reply.generation,
                .{ .screen_cells = .{ .rows = readU32(reply.body[0..4]), .cols = readU32(reply.body[4..8]) } },
            ) catch return self.queueResult(client, .consequence_reply, .rejected),
            .container_icon_title => howl.replyContainer(
                self.instance,
                reply.generation,
                .{ .icon_title = reply.body },
            ) catch return self.queueResult(client, .consequence_reply, .rejected),
            .container_decline => howl.declineContainerQuery(self.instance, reply.generation) catch
                return self.queueResult(client, .consequence_reply, .rejected),
        }
        const service_now_ns = nowNs(self.io);
        const serviced = try howl.serviceWithConsequencePolicy(
            self.instance,
            false,
            true,
            service_now_ns,
            self.consequencePolicy(),
        );
        self.applyServiceResult(serviced, service_now_ns, false);
        try self.queueResult(client, .consequence_reply, .ok);
    }

    // -------------------------------------------------------------------------
    // Leadership, resize, and signals
    // -------------------------------------------------------------------------

    fn handleAssignLeader(self: *Service, client: *Client, payload: []const u8) !void {
        const request = protocol.decodeAssignLeader(payload) catch
            return self.queueResult(client, .assign_leader, .malformed);
        if (request.client_id != protocol.no_client and !self.hasClient(request.client_id))
            return self.queueResult(client, .assign_leader, .no_such_client);
        if (self.authority.assign(request.client_id)) {
            self.burst_publication.reset();
            self.bumpObservation();
        }
        try self.queueResult(client, .assign_leader, .ok);
    }

    fn handleAssignConsequenceLeader(self: *Service, client: *Client, payload: []const u8) !void {
        const request = protocol.decodeAssignLeader(payload) catch
            return self.queueResult(client, .assign_consequence_leader, .malformed);
        if (request.client_id != protocol.no_client and !self.hasClient(request.client_id))
            return self.queueResult(client, .assign_consequence_leader, .no_such_client);
        if (self.consequence_authority.assign(request.client_id)) {
            self.burst_publication.reset();
        }
        try self.queueResult(client, .assign_consequence_leader, .ok);
    }

    fn handleResize(self: *Service, client: *Client, payload: []const u8) !void {
        if (!self.authority.mayResize(client.id)) return self.queueResult(client, .resize, .not_leader);
        const request = protocol.decodeResize(payload) catch return self.queueResult(client, .resize, .malformed);
        howl.resizeGeometry(self.instance, request.rows, request.columns, request.cell_pixel_width, request.cell_pixel_height) catch
            return self.queueResult(client, .resize, .rejected);
        self.refreshObservation();
        try self.queueResult(client, .resize, .ok);
    }

    fn handleSignal(self: *Service, client: *Client, payload: []const u8) !void {
        const requested = protocol.decodeSignal(payload) catch return self.queueResult(client, .signal, .malformed);
        const native: howl.Signal = switch (requested) {
            .hangup => .hangup,
            .interrupt => .interrupt,
            .resize_notify => .resize_notify,
            .kill => .kill,
            .terminate => .terminate,
        };
        const result = howl.signal(self.instance, native);
        try self.queueResult(client, .signal, if (result == .delivered) .ok else .rejected);
    }

    // -------------------------------------------------------------------------
    // Client teardown and observation lifecycle
    // -------------------------------------------------------------------------

    fn hasClient(self: *Service, id: protocol.ClientId) bool {
        for (self.clients) |client| if (client) |active| if (active.id == id) return true;
        return false;
    }

    fn closeClient(self: *Service, index: usize) void {
        const client = if (self.clients[index]) |*active| active else return;
        const id = client.id;
        client.deinit(self.allocator);
        self.clients[index] = null;
        if (self.authority.disconnected(id)) {
            self.burst_publication.reset();
            self.bumpObservation();
        }
        if (self.consequence_authority.disconnected(id)) {
            self.burst_publication.reset();
        }
    }

    fn refreshObservation(self: *Service) void {
        const current = howl.terminal(self.instance).semanticSequence();
        if (current == self.terminal_revision) return;
        self.terminal_revision = current;
        self.burst_publication.reset();
        self.bumpObservation();
    }

    fn terminalPublication(
        self: *Service,
        terminal_changed: bool,
        burst_eligible: bool,
        viewport_changed: bool,
        synchronized_output: howl.Terminal.SynchronizedOutputProgress,
        now_ns: u64,
    ) TerminalPublication {
        // A drain can contain end -> begin. A new held frame must not inherit
        // an older frame's fail-open permission, nor publish that partial cut.
        if (synchronized_output.ended) {
            self.synchronized_output_started_ns = null;
            self.synchronized_output_timed_out = false;
        }
        if (!howl.terminal(self.instance).synchronizedOutput()) {
            const release_pending = self.synchronized_output_pending or synchronized_output.ended;
            self.synchronized_output_started_ns = null;
            self.synchronized_output_timed_out = false;
            self.synchronized_output_pending = false;
            if (release_pending and !synchronized_output.trailing_effect) return .immediate;
            if (!terminal_changed and !release_pending) return .none;
            if (!burst_eligible) return .immediate;
            return if (viewport_changed) .burst_scroll else .burst_fast;
        }

        if (self.synchronized_output_timed_out)
            return if (terminal_changed) .immediate else .none;

        if (self.synchronized_output_started_ns == null)
            self.synchronized_output_started_ns = now_ns;
        const started_ns = self.synchronized_output_started_ns.?;
        const elapsed_ns = now_ns -| started_ns;
        if (elapsed_ns < synchronized_output_timeout_ns) {
            self.synchronized_output_pending = self.synchronized_output_pending or terminal_changed;
            return .none;
        }

        self.synchronized_output_started_ns = null;
        self.synchronized_output_timed_out = true;
        const release_pending = self.synchronized_output_pending;
        self.synchronized_output_pending = false;
        return if (terminal_changed or release_pending) .immediate else .none;
    }

    fn applyServiceResult(self: *Service, result: howl.Service, now_ns: u64, burst_eligible: bool) void {
        if (result.retained_consequence_fallback and
            self.consequence_authority.assign(protocol.no_client))
        {
            self.burst_publication.reset();
        }
        const next_stream_closed = result.stream_closed;
        const next_child_exited = result.child_exit != null;
        const lifecycle_changed = self.stream_closed != next_stream_closed or
            self.child_exited != next_child_exited;
        self.pty_write_pending = result.write_pending;
        self.animation_wait_ms = result.animation_wait_ms;
        self.stream_closed = next_stream_closed;
        self.child_exited = next_child_exited;

        const current_terminal_revision = howl.terminal(self.instance).semanticSequence();
        const terminal_changed = current_terminal_revision != self.terminal_revision;
        if (terminal_changed) self.terminal_revision = current_terminal_revision;

        var publish = false;
        switch (self.terminalPublication(
            terminal_changed,
            burst_eligible,
            result.viewport_changed,
            result.synchronized_output,
            now_ns,
        )) {
            .none => {},
            .burst_fast => self.burst_publication.note(now_ns, burst_publication_fast_max_ns),
            .burst_scroll => self.burst_publication.note(now_ns, burst_publication_scroll_max_ns),
            .immediate => {
                self.burst_publication.reset();
                publish = true;
            },
        }
        if (howl.terminal(self.instance).synchronizedOutput() and !self.synchronized_output_timed_out)
            self.burst_publication.reset();
        if (!publish and self.burst_publication.ready(now_ns)) publish = true;
        if (lifecycle_changed) {
            self.burst_publication.reset();
            publish = true;
        }
        if (publish) self.bumpObservation();
    }

    fn bumpObservation(self: *Service) void {
        self.observation_revision = std.math.add(u64, self.observation_revision, 1) catch
            // zig-audit: acknowledge panic
            // reason: This process-lifetime identity/revision space is deliberately non-wrapping; exhaustion is an unrecoverable invariant breach.
            @panic("Instance observation revision exhausted");
    }

    // -------------------------------------------------------------------------
    // Observation and snapshot materialization
    // -------------------------------------------------------------------------

    fn materializeObservers(self: *Service) !void {
        var index: usize = 0;
        while (index < self.clients.len) : (index += 1) {
            const client = if (self.clients[index]) |*active| active else continue;
            const request = client.observe orelse continue;
            if (client.outputPending()) continue;
            if (request.after_revision != 0 and request.after_revision >= self.observation_revision) continue;
            const mode = client.observe_mode;
            self.queueSnapshot(client, request, mode) catch |err| {
                // Materialization borrows const canonical state; its failures
                // belong to this observer, never the PTY/VT owner.
                if (err != error.SnapshotTooLarge) {
                    self.closeClient(index);
                    continue;
                }
                client.observe = null;
                client.observe_mode = .compressed;
                const request_kind: protocol.Kind = switch (mode) {
                    .compressed => .observe,
                    .raw => .observe_raw,
                    .delta => .observe_delta,
                    .packed_text => .observe_packed,
                };
                self.queueResult(client, request_kind, .rejected) catch |failure| {
                    if (failure != error.ClientResponseOutOfMemory) return failure;
                    self.closeClient(index);
                };
                continue;
            };
            client.observe = null;
            client.observe_mode = .compressed;
        }
    }

    // -------------------------------------------------------------------------
    // Rich text snapshot construction
    // -------------------------------------------------------------------------

    fn queueSnapshot(
        self: *Service,
        client: *Client,
        request: protocol.Observe,
        mode: ObserveMode,
    ) !void {
        return self.queueTextSnapshot(client, request, mode);
    }

    fn queueTextSnapshot(
        self: *Service,
        client: *Client,
        request: protocol.Observe,
        mode: ObserveMode,
    ) !void {
        const machine = howl.terminal(self.instance);
        const terminal_view = machine.semanticView(request.history_offset);
        const terminal_revision = machine.semanticSequence();
        const raw = mode == .raw or mode == .delta;
        const delta = mode == .delta;
        const packed_mode = mode == .packed_text;
        var graphics = machine.images(terminal_view.history_offset);
        const graphics_counts = try countSnapshotGraphics(&graphics);
        const observed_ns = nowNs(self.io);
        const cursor_age_ns = if (terminal_view.cursor_movement_timestamp_ns == 0)
            protocol.text_v1.no_cursor_movement_age_ns
        else
            observed_ns -| terminal_view.cursor_movement_timestamp_ns;
        // Delivery correlation stays here; the optional codec owns row reuse.
        // Any failure, including graphics/framing/output allocation after encoding,
        // revokes the provisional text cut and its Server predecessor identity.
        errdefer if (delta) {
            self.delta_rows.invalidate();
            self.delta_revision = 0;
        };
        self.snapshot_body.clearRetainingCapacity();
        const body = &self.snapshot_body;
        const delta_reuse_allowed = if (delta)
            (try self.delta_rows.appendText(
                self.allocator,
                body,
                machine,
                request.history_offset,
                cursor_age_ns,
                request.after_revision != 0 and request.after_revision == self.delta_revision,
            )) == .delta
        else blk: {
            const geometry = try vt_encoder.appendText(
                self.allocator,
                body,
                machine,
                request.history_offset,
                cursor_age_ns,
            );
            std.debug.assert(geometry.rows == terminal_view.rows and geometry.columns == terminal_view.cols);
            break :blk false;
        };
        const body_bytes = body.items.len;
        if (body_bytes == 0 or body_bytes > protocol.maximum_text_snapshot_bytes or
            body_bytes > std.math.maxInt(u32))
            return error.SnapshotTooLarge;

        const compressed: ?codec.text.Compressed = if (raw)
            null
        else
            try self.text_compressor.compress(if (packed_mode) .packed_zlib else .zlib, body.items);
        const encoded_bytes = if (compressed) |*value| value.size() else body_bytes;
        const data_frames = std.math.divCeil(
            usize,
            encoded_bytes,
            protocol.maximum_payload_bytes,
        ) catch return error.SnapshotTooLarge;
        var property_payload: [protocol.properties.maximum_bytes]u8 = undefined;
        const property_bytes = try protocol.properties.encode(&property_payload, terminalProperties(machine));
        const total_bound = protocol.header_bytes + protocol.payload_bytes.snapshot_begin +
            data_frames * protocol.header_bytes + encoded_bytes +
            protocol.header_bytes + property_bytes +
            protocol.header_bytes + graphics_counts.payload_bytes +
            protocol.header_bytes + protocol.payload_bytes.snapshot_end;
        if (total_bound > protocol.maximum_observation_bytes) return error.SnapshotTooLarge;

        var snapshot_images = try ImageResourceCache.captureVisible(self.allocator, &graphics);
        errdefer snapshot_images.deinit(self.allocator);
        client.resetOutput(self.allocator);
        errdefer client.resetOutput(self.allocator);
        client.output.ensureTotalCapacity(self.allocator, total_bound) catch return error.ClientResponseOutOfMemory;

        var begin_payload: [protocol.payload_bytes.snapshot_begin]u8 = undefined;
        protocol.encodeSnapshotBegin(&begin_payload, .{
            .revision = self.observation_revision,
            .terminal = vt_encoder.metadata(terminal_view, terminal_revision),
            .stream_closed = self.stream_closed,
            .child_exited = self.child_exited,
            .leader_present = self.authority.leader() != null,
            .you_are_leader = self.authority.mayResize(client.id),
        });
        try self.appendFrame(&client.output, .snapshot_begin, &begin_payload);

        if (raw) {
            try self.appendSnapshotRawData(
                &client.output,
                body.items,
                if (delta_reuse_allowed) .snapshot_delta_data else .snapshot_raw_data,
            );
        } else {
            try self.appendSnapshotCompressedData(
                &client.output,
                compressed.?.prefix(),
                compressed.?.data,
                if (packed_mode) .snapshot_packed_data else .snapshot_data,
            );
        }

        const graphics_payload = try self.allocator.alloc(u8, graphics_counts.payload_bytes);
        defer self.allocator.free(graphics_payload);
        try encodeSnapshotGraphics(&graphics, graphics_counts, graphics_payload);
        try self.appendFrame(&client.output, .snapshot_graphics, graphics_payload);
        try self.appendFrame(&client.output, .snapshot_properties, property_payload[0..property_bytes]);

        var end_payload: [protocol.payload_bytes.snapshot_end]u8 = undefined;
        protocol.encodeSnapshotEnd(&end_payload, .{ .revision = self.observation_revision });
        try self.appendFrame(&client.output, .snapshot_end, &end_payload);
        std.debug.assert(client.output.items.len == total_bound);
        client.output_offset = 0;
        client.snapshot_images.deinit(self.allocator);
        client.snapshot_images = snapshot_images;
        if (delta) self.delta_revision = self.observation_revision;
    }

    fn appendSnapshotCompressedData(
        self: *Service,
        output: *std.ArrayList(u8),
        prefix: []const u8,
        compressed: []const u8,
        kind: protocol.Kind,
    ) !void {
        std.debug.assert(kind == .snapshot_data or kind == .snapshot_packed_data);
        std.debug.assert(
            (kind == .snapshot_data and prefix.len == protocol.text_v1.compressed_header_bytes) or
                (kind == .snapshot_packed_data and prefix.len == protocol.text_pack_v1.compressed_header_bytes),
        );
        var prefix_offset: usize = 0;
        var compressed_offset: usize = 0;
        while (prefix_offset < prefix.len or compressed_offset < compressed.len) {
            const prefix_left = prefix.len - prefix_offset;
            const payload_capacity: usize = protocol.maximum_payload_bytes;
            const prefix_count = @min(prefix_left, payload_capacity);
            const compressed_count = @min(
                compressed.len - compressed_offset,
                payload_capacity - prefix_count,
            );
            const payload_len = prefix_count + compressed_count;
            var header: [protocol.header_bytes]u8 = undefined;
            try protocol.encodeHeader(&header, .{
                .kind = kind,
                .payload_len = @intCast(payload_len),
            });
            try output.appendSlice(self.allocator, &header);
            try output.appendSlice(
                self.allocator,
                prefix[prefix_offset .. prefix_offset + prefix_count],
            );
            try output.appendSlice(
                self.allocator,
                compressed[compressed_offset .. compressed_offset + compressed_count],
            );
            prefix_offset += prefix_count;
            compressed_offset += compressed_count;
        }
    }

    fn appendSnapshotRawData(
        self: *Service,
        output: *std.ArrayList(u8),
        body: []const u8,
        kind: protocol.Kind,
    ) !void {
        std.debug.assert(kind == .snapshot_raw_data or kind == .snapshot_delta_data);
        if (body.len == 0 or body.len > protocol.maximum_text_snapshot_bytes)
            return error.SnapshotTooLarge;
        var offset: usize = 0;
        while (offset < body.len) {
            const count = @min(
                body.len - offset,
                @as(usize, protocol.maximum_payload_bytes),
            );
            try self.appendFrame(
                output,
                kind,
                body[offset .. offset + count],
            );
            offset += count;
        }
    }

    // -------------------------------------------------------------------------
    // Response framing
    // -------------------------------------------------------------------------

    fn queueResult(self: *Service, client: *Client, request_kind: protocol.Kind, code: protocol.ResultCode) !void {
        var payload: [protocol.payload_bytes.result]u8 = undefined;
        protocol.encodeResult(&payload, .{ .request_kind = request_kind, .code = code });
        try self.queueFrame(client, .result, &payload);
    }

    fn queueFrame(self: *Service, client: *Client, kind: protocol.Kind, payload: []const u8) !void {
        if (client.outputPending()) return error.ResponseAlreadyPending;
        client.resetOutput(self.allocator);
        errdefer client.resetOutput(self.allocator);
        try self.appendFrame(&client.output, kind, payload);
        client.output_offset = 0;
    }

    fn appendFrame(self: *Service, output: *std.ArrayList(u8), kind: protocol.Kind, payload: []const u8) !void {
        if (payload.len > protocol.maximum_payload_bytes) return error.PayloadTooLarge;
        var header: [protocol.header_bytes]u8 = undefined;
        try protocol.encodeHeader(&header, .{ .kind = kind, .payload_len = @intCast(payload.len) });
        output.appendSlice(self.allocator, &header) catch return error.ClientResponseOutOfMemory;
        output.appendSlice(self.allocator, payload) catch return error.ClientResponseOutOfMemory;
    }
};

// =============================================================================
// Terminal input and rich snapshot adapters
// =============================================================================

fn terminalImage(
    machine: *const howl.Terminal.Observation,
    image_id: u32,
    generation: u64,
) ?howl.Terminal.Image {
    var images = machine.images(0);
    var index: usize = 0;
    while (index < images.imageCount()) : (index += 1) {
        const candidate = images.image(index) orelse continue;
        if (candidate.id == image_id and candidate.generation == generation)
            return candidate;
    }
    return null;
}

fn typedKeyName(value: u32) ?howl.KeyName {
    return switch (value) {
        @backingInt(protocol.InputKeyName.enter) => .enter,
        @backingInt(protocol.InputKeyName.tab) => .tab,
        @backingInt(protocol.InputKeyName.backspace) => .backspace,
        @backingInt(protocol.InputKeyName.escape) => .escape,
        @backingInt(protocol.InputKeyName.up) => .up,
        @backingInt(protocol.InputKeyName.down) => .down,
        @backingInt(protocol.InputKeyName.left) => .left,
        @backingInt(protocol.InputKeyName.right) => .right,
        @backingInt(protocol.InputKeyName.insert) => .insert,
        @backingInt(protocol.InputKeyName.delete) => .delete,
        @backingInt(protocol.InputKeyName.home) => .home,
        @backingInt(protocol.InputKeyName.end) => .end,
        @backingInt(protocol.InputKeyName.page_up) => .page_up,
        @backingInt(protocol.InputKeyName.page_down) => .page_down,
        @backingInt(protocol.InputKeyName.left_shift) => .left_shift,
        @backingInt(protocol.InputKeyName.right_shift) => .right_shift,
        @backingInt(protocol.InputKeyName.left_control) => .left_control,
        @backingInt(protocol.InputKeyName.right_control) => .right_control,
        @backingInt(protocol.InputKeyName.left_alt) => .left_alt,
        @backingInt(protocol.InputKeyName.right_alt) => .right_alt,
        @backingInt(protocol.InputKeyName.left_super) => .left_super,
        @backingInt(protocol.InputKeyName.right_super) => .right_super,
        @backingInt(protocol.InputKeyName.left_hyper) => .left_hyper,
        @backingInt(protocol.InputKeyName.right_hyper) => .right_hyper,
        @backingInt(protocol.InputKeyName.left_meta) => .left_meta,
        @backingInt(protocol.InputKeyName.right_meta) => .right_meta,
        @backingInt(protocol.InputKeyName.caps_lock) => .caps_lock,
        @backingInt(protocol.InputKeyName.num_lock) => .num_lock,
        @backingInt(protocol.InputKeyName.f1) => .f1,
        @backingInt(protocol.InputKeyName.f2) => .f2,
        @backingInt(protocol.InputKeyName.f3) => .f3,
        @backingInt(protocol.InputKeyName.f4) => .f4,
        @backingInt(protocol.InputKeyName.f5) => .f5,
        @backingInt(protocol.InputKeyName.f6) => .f6,
        @backingInt(protocol.InputKeyName.f7) => .f7,
        @backingInt(protocol.InputKeyName.f8) => .f8,
        @backingInt(protocol.InputKeyName.f9) => .f9,
        @backingInt(protocol.InputKeyName.f10) => .f10,
        @backingInt(protocol.InputKeyName.f11) => .f11,
        @backingInt(protocol.InputKeyName.f12) => .f12,
        @backingInt(protocol.InputKeyName.keypad_0) => .keypad_0,
        @backingInt(protocol.InputKeyName.keypad_1) => .keypad_1,
        @backingInt(protocol.InputKeyName.keypad_2) => .keypad_2,
        @backingInt(protocol.InputKeyName.keypad_3) => .keypad_3,
        @backingInt(protocol.InputKeyName.keypad_4) => .keypad_4,
        @backingInt(protocol.InputKeyName.keypad_5) => .keypad_5,
        @backingInt(protocol.InputKeyName.keypad_6) => .keypad_6,
        @backingInt(protocol.InputKeyName.keypad_7) => .keypad_7,
        @backingInt(protocol.InputKeyName.keypad_8) => .keypad_8,
        @backingInt(protocol.InputKeyName.keypad_9) => .keypad_9,
        @backingInt(protocol.InputKeyName.keypad_decimal) => .keypad_decimal,
        @backingInt(protocol.InputKeyName.keypad_add) => .keypad_add,
        @backingInt(protocol.InputKeyName.keypad_subtract) => .keypad_subtract,
        @backingInt(protocol.InputKeyName.keypad_multiply) => .keypad_multiply,
        @backingInt(protocol.InputKeyName.keypad_divide) => .keypad_divide,
        @backingInt(protocol.InputKeyName.keypad_separator) => .keypad_separator,
        @backingInt(protocol.InputKeyName.keypad_equal) => .keypad_equal,
        @backingInt(protocol.InputKeyName.keypad_enter) => .keypad_enter,
        else => null,
    };
}

fn typedKeyAction(value: protocol.InputKeyAction) howl.KeyAction {
    return switch (value) {
        .press => .press,
        .repeat => .repeat,
        .release => .release,
    };
}

fn typedModifiers(value: u8) howl.InputModifier {
    return .{
        .shift = value & protocol.typed_input.modifiers.shift != 0,
        .alt = value & protocol.typed_input.modifiers.alt != 0,
        .control = value & protocol.typed_input.modifiers.control != 0,
        .super = value & protocol.typed_input.modifiers.super != 0,
        .hyper = value & protocol.typed_input.modifiers.hyper != 0,
        .meta = value & protocol.typed_input.modifiers.meta != 0,
        .caps_lock = value & protocol.typed_input.modifiers.caps_lock != 0,
        .num_lock = value & protocol.typed_input.modifiers.num_lock != 0,
    };
}

fn typedMouseKind(value: protocol.InputMouseKind) howl.MouseEventKind {
    return switch (value) {
        .press => .press,
        .release => .release,
        .move => .move,
        .wheel => .wheel,
    };
}

fn typedMouseButton(value: protocol.InputMouseButton) howl.MouseButton {
    return switch (value) {
        .none => .none,
        .left => .left,
        .middle => .middle,
        .right => .right,
        .wheel_up => .wheel_up,
        .wheel_down => .wheel_down,
    };
}

fn configureAdoptedStream(stream: AdoptedStream) error{SocketOptionFailed}!void {
    if (comptime native_windows) {
        var mode = pipe_nowait;
        if (!SetNamedPipeHandleState(stream.read, &mode, null, null).toBool())
            return error.SocketOptionFailed;
        mode = pipe_nowait;
        if (!SetNamedPipeHandleState(stream.write, &mode, null, null).toBool())
            return error.SocketOptionFailed;
        return;
    }
    return configureAdoptedClientFd(stream);
}

fn configureAdoptedClientFd(fd: posix.fd_t) error{SocketOptionFailed}!void {
    try setSendBuffer(fd, client_send_buffer_bytes);
    try setCloseOnExec(fd);
    try setNonblocking(fd);
}

fn setCloseOnExec(fd: posix.fd_t) error{SocketOptionFailed}!void {
    const result = linux.fcntl(fd, linux.F.SETFD, @as(usize, linux.FD_CLOEXEC));
    if (linux.errno(result) != .SUCCESS) return error.SocketOptionFailed;
}

fn setNonblocking(fd: posix.fd_t) error{SocketOptionFailed}!void {
    const current = linux.fcntl(fd, linux.F.GETFL, @as(usize, 0));
    if (linux.errno(current) != .SUCCESS) return error.SocketOptionFailed;
    const nonblocking: usize = @intCast(@as(u32, @bitCast(linux.O{ .NONBLOCK = true })));
    const updated = linux.fcntl(fd, linux.F.SETFL, @as(usize, @intCast(current)) | nonblocking);
    if (linux.errno(updated) != .SUCCESS) return error.SocketOptionFailed;
}

fn setSendBuffer(fd: posix.fd_t, bytes: c_int) !void {
    const result = linux.setsockopt(
        fd,
        linux.SOL.SOCKET,
        linux.SO.SNDBUF,
        std.mem.asBytes(&bytes).ptr,
        @sizeOf(c_int),
    );
    if (linux.errno(result) != .SUCCESS) return error.SocketOptionFailed;
}

fn closeFd(fd: posix.fd_t) void {
    const result = linux.close(fd);
    const errno = linux.errno(result);
    std.debug.assert(errno == .SUCCESS or errno == .INTR);
}

fn closeAdoptedStream(stream: AdoptedStream) void {
    if (comptime native_windows) {
        windows.CloseHandle(stream.read);
        windows.CloseHandle(stream.write);
        windows.CloseHandle(stream.peer_read_event);
        return;
    }
    closeFd(stream);
}

fn nowNs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).toNanoseconds());
}

fn readU32(input: []const u8) u32 {
    std.debug.assert(input.len == 4);
    return (@as(u32, input[0]) << 24) |
        (@as(u32, input[1]) << 16) |
        (@as(u32, input[2]) << 8) |
        @as(u32, input[3]);
}

fn encodeU32(output: []u8, value: u32) void {
    std.debug.assert(output.len == 4);
    output[0] = @truncate(value >> 24);
    output[1] = @truncate(value >> 16);
    output[2] = @truncate(value >> 8);
    output[3] = @truncate(value);
}

const TestFrame = struct {
    kind: protocol.Kind,
    payload: []u8,

    fn deinit(self: *TestFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        self.* = undefined;
    }
};

const TestPeer = struct {
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    incoming: std.ArrayList(u8) = .empty,

    fn adopt(allocator: std.mem.Allocator, service: *Service) !TestPeer {
        var pair: [2]posix.fd_t = undefined;
        const result = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &pair);
        if (posix.errno(result) != .SUCCESS) return error.TestSocketCreateFailed;
        errdefer closeFd(pair[0]);
        errdefer closeFd(pair[1]);
        try setNonblocking(pair[1]);
        try service.adoptClient(pair[0], &.{}, .{ .server_id = 1, .session_id = 1, .instance_id = 1, .tree_revision = 1 });
        return .{ .allocator = allocator, .fd = pair[1] };
    }

    fn deinit(self: *TestPeer) void {
        if (self.fd >= 0) closeFd(self.fd);
        self.incoming.deinit(self.allocator);
        self.* = undefined;
    }

    fn sendFrame(self: *TestPeer, service: *Service, kind: protocol.Kind, payload: []const u8) !void {
        var header: [protocol.header_bytes]u8 = undefined;
        try protocol.encodeHeader(&header, .{ .kind = kind, .payload_len = @intCast(payload.len) });
        try self.sendAll(service, &header);
        try self.sendAll(service, payload);
    }

    fn sendAll(self: *TestPeer, service: *Service, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const result = linux.write(self.fd, bytes[offset..].ptr, bytes.len - offset);
            switch (linux.errno(result)) {
                .SUCCESS => {
                    if (result == 0 or result > bytes.len - offset) return error.TestSocketWriteFailed;
                    offset += result;
                },
                .INTR => continue,
                .AGAIN => try service.turn(0),
                else => return error.TestSocketWriteFailed,
            }
        }
    }

    fn readAvailable(self: *TestPeer) !void {
        var scratch: [4096]u8 = undefined;
        while (true) {
            const result = linux.read(self.fd, &scratch, scratch.len);
            switch (linux.errno(result)) {
                .SUCCESS => {
                    if (result == 0) return error.TestPeerClosed;
                    if (result > scratch.len) return error.TestSocketReadFailed;
                    try self.incoming.appendSlice(self.allocator, scratch[0..result]);
                },
                .INTR => continue,
                .AGAIN => return,
                else => return error.TestSocketReadFailed,
            }
        }
    }

    fn popFrame(self: *TestPeer) !?TestFrame {
        if (self.incoming.items.len < protocol.header_bytes) return null;
        var encoded: [protocol.header_bytes]u8 = undefined;
        @memcpy(&encoded, self.incoming.items[0..protocol.header_bytes]);
        const header = try protocol.decodeHeader(&encoded);
        const frame_bytes = protocol.header_bytes + @as(usize, header.payload_len);
        if (self.incoming.items.len < frame_bytes) return null;
        const payload = try self.allocator.dupe(u8, self.incoming.items[protocol.header_bytes..frame_bytes]);
        const remaining = self.incoming.items.len - frame_bytes;
        std.mem.copyForwards(u8, self.incoming.items[0..remaining], self.incoming.items[frame_bytes..]);
        self.incoming.shrinkRetainingCapacity(remaining);
        return .{ .kind = header.kind, .payload = payload };
    }
};

fn awaitAttachReady(peer: *TestPeer, service: *Service) !server_protocol.AttachReady {
    const size = server_protocol.header_bytes + server_protocol.payload_bytes.attach_ready;
    for (0..10_000) |_| {
        try peer.readAvailable();
        if (peer.incoming.items.len >= size) {
            const header = try server_protocol.decodeHeader(peer.incoming.items[0..server_protocol.header_bytes]);
            try std.testing.expectEqual(server_protocol.Kind.attach_ready, header.kind);
            try std.testing.expectEqual(@as(u32, server_protocol.payload_bytes.attach_ready), header.payload_len);
            const ready = try server_protocol.decodeAttachReady(peer.incoming.items[server_protocol.header_bytes..size]);
            const remaining = peer.incoming.items.len - size;
            std.mem.copyForwards(u8, peer.incoming.items[0..remaining], peer.incoming.items[size..]);
            peer.incoming.shrinkRetainingCapacity(remaining);
            return ready;
        }
        try service.turn(1);
    }
    return error.TestTimeout;
}

fn expectAttachReady(peer: *TestPeer, service: *Service) !void {
    const ready = try awaitAttachReady(peer, service);
    try std.testing.expect(ready.client_id != protocol.no_client);
}

fn awaitTestFrame(peer: *TestPeer, service: *Service) !TestFrame {
    var turns: usize = 0;
    while (turns < 10_000) : (turns += 1) {
        try peer.readAvailable();
        if (try peer.popFrame()) |frame| return frame;
        try service.turn(1);
    }
    return error.TestTimeout;
}

fn semanticViewContains(view: howl.Terminal.SemanticView, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var row: u16 = 0;
    while (row < view.rows) : (row += 1) {
        if (view.cols < needle.len) continue;
        var start: usize = 0;
        while (start + needle.len <= view.cols) : (start += 1) {
            var matched = true;
            for (needle, 0..) |byte, offset| {
                if (view.cellInfoAt(row, @intCast(start + offset)).codepoint != byte) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
    }
    return false;
}

test "live delta uses row generations and reuses unchanged rows" {
    const allocator = std.testing.allocator;
    const instance = try howl.init(allocator, std.testing.environ, .{
        .shell = "/bin/sh",
        .command = "cat",
        .rows = 4,
        .columns = 24,
        .history_rows = 16,
    });
    defer howl.deinit(instance);
    var service = try Service.init(allocator, std.testing.io, instance);
    defer service.deinit();
    var peer = try TestPeer.adopt(allocator, &service);
    defer peer.deinit();

    try expectAttachReady(&peer, &service);

    var observe: [protocol.payload_bytes.observe]u8 = undefined;
    protocol.encodeObserve(&observe, .{ .after_revision = 0, .history_offset = 0 });
    try peer.sendFrame(&service, .observe_delta, &observe);

    var baseline_revision: u64 = 0;
    var saw_raw = false;
    var baseline_complete = false;
    for (0..64) |_| {
        var frame = try awaitTestFrame(&peer, &service);
        defer frame.deinit(allocator);
        switch (frame.kind) {
            .snapshot_begin => baseline_revision = (try protocol.decodeSnapshotBegin(frame.payload)).revision,
            .snapshot_raw_data => saw_raw = true,
            .snapshot_end => {
                try std.testing.expectEqual(baseline_revision, (try protocol.decodeSnapshotEnd(frame.payload)).revision);
                baseline_complete = true;
                break;
            },
            .snapshot_graphics, .snapshot_properties => {},
            else => return error.TestUnexpectedFrame,
        }
    }
    try std.testing.expect(baseline_complete and saw_raw and baseline_revision != 0);
    try std.testing.expectEqual(baseline_revision, service.delta_revision);

    var input_payload = [_]u8{ @backingInt(protocol.InputKind.bytes), 'X' };
    try peer.sendFrame(&service, .input, &input_payload);
    var input_result = try awaitTestFrame(&peer, &service);
    defer input_result.deinit(allocator);
    try std.testing.expectEqual(protocol.Kind.result, input_result.kind);
    try std.testing.expectEqual(protocol.ResultCode.ok, (try protocol.decodeResult(input_result.payload)).code);

    var turns: usize = 0;
    while (turns < 2_000 and service.observation_revision <= baseline_revision) : (turns += 1)
        try service.turn(1);
    try std.testing.expect(service.observation_revision > baseline_revision);

    protocol.encodeObserve(&observe, .{ .after_revision = baseline_revision, .history_offset = 0 });
    try peer.sendFrame(&service, .observe_delta, &observe);
    var delta_body: std.ArrayList(u8) = .empty;
    defer delta_body.deinit(allocator);
    var saw_delta = false;
    var saw_delta_raw = false;
    var delta_complete = false;
    for (0..64) |_| {
        var frame = try awaitTestFrame(&peer, &service);
        defer frame.deinit(allocator);
        switch (frame.kind) {
            .snapshot_begin => try std.testing.expect((try protocol.decodeSnapshotBegin(frame.payload)).revision > baseline_revision),
            .snapshot_delta_data => {
                saw_delta = true;
                try delta_body.appendSlice(allocator, frame.payload);
            },
            .snapshot_raw_data => saw_delta_raw = true,
            .snapshot_graphics, .snapshot_properties => {},
            .snapshot_end => {
                delta_complete = true;
                break;
            },
            else => return error.TestUnexpectedFrame,
        }
    }
    try std.testing.expect(delta_complete and saw_delta and !saw_delta_raw);
    try std.testing.expect(service.delta_revision > baseline_revision);

    var offset: usize = 0;
    var row_records: usize = 0;
    var reused_rows: usize = 0;
    var row_shift_records: usize = 0;
    while (offset < delta_body.items.len) {
        if (delta_body.items.len - offset < protocol.text_v1.record_header_bytes)
            return error.TestUnexpectedFrame;
        var encoded_header: [protocol.text_v1.record_header_bytes]u8 = undefined;
        @memcpy(&encoded_header, delta_body.items[offset..][0..protocol.text_v1.record_header_bytes]);
        const header = try protocol.decodeTextRecordHeader(&encoded_header);
        const record_len = protocol.text_v1.record_header_bytes + @as(usize, header.payload_len);
        if (record_len > delta_body.items.len - offset) return error.TestUnexpectedFrame;
        switch (header.kind) {
            .row => {
                row_records += 1;
                if (header.payload_len == 0) reused_rows += 1;
            },
            .row_shift => row_shift_records += 1,
            else => {},
        }
        offset += record_len;
    }
    try std.testing.expectEqual(delta_body.items.len, offset);
    try std.testing.expectEqual(@as(usize, 4), row_records);
    try std.testing.expectEqual(@as(usize, 1), row_shift_records);
    try std.testing.expect(reused_rows >= 1);
}

test "adopted Server terminal stream drives one borrowed Instance without owning its lifetime" {
    const instance = try howl.init(std.testing.allocator, std.testing.environ, .{
        .shell = "/bin/sh",
        .command = "cat",
        .rows = 4,
        .columns = 24,
        .history_rows = 16,
    });
    defer howl.deinit(instance);

    var service = try Service.init(std.testing.allocator, std.testing.io, instance);
    var service_live = true;
    defer if (service_live) service.deinit();
    var peer = try TestPeer.adopt(std.testing.allocator, &service);
    defer peer.deinit();

    const welcome = try awaitAttachReady(&peer, &service);
    try std.testing.expect(welcome.client_id != protocol.no_client);

    const text = "SERVICE_OK\n";
    var input_payload: [1 + text.len]u8 = undefined;
    input_payload[0] = @backingInt(protocol.InputKind.bytes);
    @memcpy(input_payload[1..], text);
    try peer.sendFrame(&service, .input, &input_payload);
    var result_frame = try awaitTestFrame(&peer, &service);
    defer result_frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.Kind.result, result_frame.kind);
    const result = try protocol.decodeResult(result_frame.payload);
    try std.testing.expectEqual(protocol.Kind.input, result.request_kind);
    try std.testing.expectEqual(protocol.ResultCode.ok, result.code);

    var turns: usize = 0;
    while (turns < 2_000 and !semanticViewContains(howl.terminal(instance).semanticView(0), "SERVICE_OK")) : (turns += 1)
        try service.turn(1);
    try std.testing.expect(semanticViewContains(howl.terminal(instance).semanticView(0), "SERVICE_OK"));

    const before = howl.terminal(instance).semanticSequence();
    service.deinit();
    service_live = false;
    try std.testing.expectEqual(before, howl.terminal(instance).semanticSequence());
}

test "packed observation reconstructs one coherent complete text_v1 cut" {
    const allocator = std.testing.allocator;
    const instance = try howl.init(allocator, std.testing.environ, .{
        .shell = "/bin/sh",
        .command = "cat",
        .rows = 4,
        .columns = 24,
        .history_rows = 16,
    });
    defer howl.deinit(instance);
    var service = try Service.init(allocator, std.testing.io, instance);
    defer service.deinit();
    var peer = try TestPeer.adopt(allocator, &service);
    defer peer.deinit();

    try expectAttachReady(&peer, &service);

    var observe: [protocol.payload_bytes.observe]u8 = undefined;
    protocol.encodeObserve(&observe, .{ .after_revision = 0, .history_offset = 0 });
    try peer.sendFrame(&service, .observe_packed, &observe);

    var begin: ?protocol.SnapshotBegin = null;
    var packed_envelope: std.ArrayList(u8) = .empty;
    defer packed_envelope.deinit(allocator);
    var saw_packed = false;
    var saw_graphics = false;
    var saw_properties = false;
    var complete = false;
    for (0..64) |_| {
        var frame = try awaitTestFrame(&peer, &service);
        defer frame.deinit(allocator);
        switch (frame.kind) {
            .snapshot_begin => begin = try protocol.decodeSnapshotBegin(frame.payload),
            .snapshot_packed_data => {
                saw_packed = true;
                try packed_envelope.appendSlice(allocator, frame.payload);
            },
            .snapshot_graphics => saw_graphics = true,
            .snapshot_properties => saw_properties = true,
            .snapshot_end => {
                const end = try protocol.decodeSnapshotEnd(frame.payload);
                try std.testing.expect(begin != null);
                try std.testing.expectEqual(begin.?.revision, end.revision);
                complete = true;
                break;
            },
            else => return error.TestUnexpectedFrame,
        }
        if (complete) break;
    }
    try std.testing.expect(complete);
    try std.testing.expect(saw_packed);
    try std.testing.expect(saw_graphics);
    try std.testing.expect(saw_properties);
    try std.testing.expectEqual(@as(u16, 4), begin.?.terminal.rows);
    try std.testing.expectEqual(@as(u16, 24), begin.?.terminal.columns);
    try std.testing.expect(packed_envelope.items.len > protocol.text_pack_v1.compressed_header_bytes);

    const text_len = readU32(packed_envelope.items[0..4]);
    const packed_len = readU32(packed_envelope.items[4..8]);
    try std.testing.expect(text_len != 0 and text_len <= protocol.maximum_text_snapshot_bytes);
    try std.testing.expect(packed_len != 0 and packed_len <= protocol.text_pack_v1.maximum_body_bytes);
    const packed_body = try allocator.alloc(u8, packed_len);
    defer allocator.free(packed_body);
    var packed_output: std.Io.Writer = .fixed(packed_body);
    var packed_input: std.Io.Reader = .fixed(packed_envelope.items[protocol.text_pack_v1.compressed_header_bytes..]);
    const work = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(work);
    var decompressor: std.compress.flate.Decompress = .init(&packed_input, .zlib, work);
    const decoded_count = try decompressor.reader.streamRemaining(&packed_output);
    try std.testing.expectEqual(@as(usize, packed_len), decoded_count);
    try std.testing.expectEqual(@as(usize, packed_len), packed_output.buffered().len);
    try std.testing.expectEqual(packed_input.end, packed_input.seek);
    try std.testing.expectEqual(std.hash.Adler32.hash(packed_body), decompressor.container_metadata.zlib.adler);

    var text_body: std.ArrayList(u8) = .empty;
    defer text_body.deinit(allocator);
    try protocol.unpackTextV1(allocator, packed_body, text_len, &text_body);
    try std.testing.expectEqual(@as(usize, text_len), text_body.items.len);
    var offset: usize = 0;
    var presentations: usize = 0;
    var rows: usize = 0;
    while (offset < text_body.items.len) {
        try std.testing.expect(text_body.items.len - offset >= protocol.text_v1.record_header_bytes);
        var encoded_header: [protocol.text_v1.record_header_bytes]u8 = undefined;
        @memcpy(&encoded_header, text_body.items[offset..][0..protocol.text_v1.record_header_bytes]);
        const header = try protocol.decodeTextRecordHeader(&encoded_header);
        const record_len = protocol.text_v1.record_header_bytes + @as(usize, header.payload_len);
        try std.testing.expect(record_len <= text_body.items.len - offset);
        switch (header.kind) {
            .presentation => presentations += 1,
            .row => rows += 1,
            .hyperlink => {},
            .row_shift => return error.TestUnexpectedFrame,
        }
        offset += record_len;
    }
    try std.testing.expectEqual(@as(usize, 1), presentations);
    try std.testing.expectEqual(@as(usize, 4), rows);
}

test "failed client adoption retains caller stream ownership" {
    const instance = try howl.init(std.testing.allocator, std.testing.environ, .{
        .shell = "/bin/sh",
        .command = "cat",
        .rows = 2,
        .columns = 8,
    });
    defer howl.deinit(instance);
    var service = try Service.init(std.testing.allocator, std.testing.io, instance);
    defer service.deinit();

    var pair: [2]posix.fd_t = undefined;
    const socket_result = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &pair);
    try std.testing.expectEqual(posix.E.SUCCESS, posix.errno(socket_result));
    defer closeFd(pair[0]);
    defer closeFd(pair[1]);

    var oversized: [input_buffer_bytes + 1]u8 = @splat(0);
    try std.testing.expectError(
        error.InitialInputTooLarge,
        service.adoptClient(pair[0], &oversized, .{ .server_id = 1, .session_id = 1, .instance_id = 1, .tree_revision = 1 }),
    );
    const flags = linux.fcntl(pair[0], linux.F.GETFD, @as(usize, 0));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(flags));
}

test "attachment admission allocation failures preserve caller fd and client identity" {
    const instance = try howl.init(std.testing.allocator, std.testing.environ, .{
        .shell = "/bin/sh",
        .command = "cat",
        .rows = 2,
        .columns = 8,
    });
    defer howl.deinit(instance);
    var service = try Service.init(std.testing.allocator, std.testing.io, instance);
    defer service.deinit();

    // Both allocations precede ownership transfer: the input buffer, then the
    // output containing the complete ready message. Neither commits a slot/ID.
    for (0..2) |failure_index| {
        var pair: [2]posix.fd_t = undefined;
        const result = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &pair);
        try std.testing.expectEqual(posix.E.SUCCESS, posix.errno(result));
        defer closeFd(pair[0]);
        defer closeFd(pair[1]);
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = failure_index });
        service.allocator = failing.allocator();
        defer service.allocator = std.testing.allocator;
        try std.testing.expectError(error.OutOfMemory, service.adoptClient(pair[0], &.{}, .{
            .server_id = 1,
            .session_id = 1,
            .instance_id = 1,
            .tree_revision = 1,
        }));
        try std.testing.expectEqual(@as(u16, 0), service.clientCount());
        try std.testing.expectEqual(@as(protocol.ClientId, 1), service.next_client_id);
        const flags = linux.fcntl(pair[0], linux.F.GETFD, @as(usize, 0));
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(flags));
    }
}

test "quiescent exited Instance sleeps until a client attaches" {
    const instance = try howl.init(std.testing.allocator, std.testing.environ, .{
        .shell = "/bin/sh",
        .command = "exit 0",
        .rows = 2,
        .columns = 8,
    });
    defer howl.deinit(instance);
    var service = try Service.init(std.testing.allocator, std.testing.io, instance);
    defer service.deinit();

    var turns: usize = 0;
    while (turns < 10_000 and service.hasRetainedWork()) : (turns += 1)
        try service.turn(1);
    try std.testing.expect(service.lifecycle().child_exited);
    try std.testing.expect(service.lifecycle().stream_closed);
    try std.testing.expect(!service.hasRetainedWork());

    var peer = try TestPeer.adopt(std.testing.allocator, &service);
    try std.testing.expect(service.hasRetainedWork());
    peer.deinit();

    turns = 0;
    while (turns < 10_000 and service.hasRetainedWork()) : (turns += 1)
        try service.turn(1);
    try std.testing.expect(!service.hasRetainedWork());
}

test "response and snapshot allocation failures retire only the affected Server terminal client" {
    // The canonical owner uses its own allocator here, so every injected failure
    // is provably response/materialization-local rather than a PTY/VT failure.
    const instance = try howl.init(std.testing.allocator, std.testing.environ, .{
        .shell = "/bin/sh",
        .command = "cat",
        .rows = 4,
        .columns = 24,
        .history_rows = 16,
    });
    defer howl.deinit(instance);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var service = try Service.init(failing.allocator(), std.testing.io, instance);
    defer service.deinit();
    var good = try TestPeer.adopt(std.testing.allocator, &service);
    defer good.deinit();
    const good_id = (try awaitAttachReady(&good, &service)).client_id;

    // Each observation materializer fails independently, with a healthy client retained.
    for ([_]ObserveMode{ .raw, .compressed, .delta, .packed_text }) |encoding| {
        var bad = try TestPeer.adopt(std.testing.allocator, &service);
        defer bad.deinit();
        try expectAttachReady(&bad, &service);
        {
            var request: [protocol.payload_bytes.observe]u8 = undefined;
            protocol.encodeObserve(&request, .{ .after_revision = 0, .history_offset = 0 });
            try bad.sendFrame(&service, switch (encoding) {
                .raw => .observe_raw,
                .compressed => .observe,
                .delta => .observe_delta,
                .packed_text => .observe_packed,
            }, &request);
            // Force a fresh materialization allocation even after a previous mode
            // retained scratch capacity. No canonical storage is touched.
            service.snapshot_body.clearAndFree(failing.allocator());
        }
        failing.has_induced_failure = false;
        failing.fail_index = failing.alloc_index;
        try service.turn(0);
        try std.testing.expect(failing.has_induced_failure);
        failing.fail_index = std.math.maxInt(usize);
        try std.testing.expectEqual(@as(usize, 1), service.clientCount());
        try std.testing.expect(service.hasClient(good_id));
        try std.testing.expectError(error.TestPeerClosed, bad.readAvailable());
        if (encoding == .delta) {
            try std.testing.expectEqual(@as(u64, 0), service.delta_revision);
            try std.testing.expect(!service.delta_rows.complete);
            for (service.delta_rows.entries) |entry| try std.testing.expect(!entry.valid);
        }
    }

    var observe: [protocol.payload_bytes.observe]u8 = undefined;
    protocol.encodeObserve(&observe, .{ .after_revision = 0, .history_offset = 0 });
    try good.sendFrame(&service, .observe_raw, &observe);
    var snapshot_complete = false;
    for (0..64) |_| {
        var frame = try awaitTestFrame(&good, &service);
        defer frame.deinit(std.testing.allocator);
        if (frame.kind == .snapshot_end) {
            snapshot_complete = true;
            break;
        }
    }
    try std.testing.expect(snapshot_complete);

    const text = "OOM_SURVIVOR\n";
    try good.sendFrame(&service, .input, &([_]u8{@backingInt(protocol.InputKind.bytes)} ++ text.*));
    var result = try awaitTestFrame(&good, &service);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.ResultCode.ok, (try protocol.decodeResult(result.payload)).code);
    var turns: usize = 0;
    while (turns < 2_000 and !semanticViewContains(howl.terminal(instance).semanticView(0), "OOM_SURVIVOR")) : (turns += 1)
        try service.turn(1);
    try std.testing.expect(semanticViewContains(howl.terminal(instance).semanticView(0), "OOM_SURVIVOR"));
}

test "failed Server output queuing revokes provisional codec rows and delivery revision" {
    const instance = try howl.init(std.testing.allocator, std.testing.environ, .{
        .shell = "/bin/sh",
        .command = "cat",
        .rows = 4,
        .columns = 24,
        .history_rows = 16,
    });
    defer howl.deinit(instance);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var service = try Service.init(failing.allocator(), std.testing.io, instance);
    defer service.deinit();
    var peer = try TestPeer.adopt(std.testing.allocator, &service);
    defer peer.deinit();
    const client = &service.clients[0].?;
    try service.queueTextSnapshot(client, .{ .after_revision = 0, .history_offset = 0 }, .delta);
    try std.testing.expect(service.delta_rows.complete);
    const baseline = service.delta_revision;
    try std.testing.expect(baseline != 0);
    // Retain the text/row capacity but force allocation only when Server output
    // is reserved, after a complete delta body has already been encoded.
    client.output.clearAndFree(failing.allocator());
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.ClientResponseOutOfMemory, service.queueTextSnapshot(
        client,
        .{ .after_revision = baseline, .history_offset = 0 },
        .delta,
    ));
    try std.testing.expect(failing.has_induced_failure);
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(@as(usize, 0), client.output.items.len);
    try std.testing.expectEqual(@as(u64, 0), service.delta_revision);
    try std.testing.expect(!service.delta_rows.complete);
    for (service.delta_rows.entries) |entry| try std.testing.expect(!entry.valid);
    var record: [protocol.text_v1.record_header_bytes]u8 = undefined;
    const shift_offset = protocol.text_v1.record_header_bytes + protocol.text_v1.presentation_bytes;
    @memcpy(&record, service.snapshot_body.items[shift_offset..][0..record.len]);
    try std.testing.expectEqual(protocol.TextRecordKind.row_shift, (try protocol.decodeTextRecordHeader(&record)).kind);
    const row_offset = shift_offset + record.len + codec.text_delta_v2.row_shift_bytes;
    @memcpy(&record, service.snapshot_body.items[row_offset..][0..record.len]);
    try std.testing.expectEqual(@as(u32, 0), (try protocol.decodeTextRecordHeader(&record)).payload_len);
    // Even the formerly correct Server revision now produces a complete body.
    try service.queueTextSnapshot(client, .{ .after_revision = baseline, .history_offset = 0 }, .delta);
    @memcpy(&record, service.snapshot_body.items[shift_offset..][0..record.len]);
    const first_row = try protocol.decodeTextRecordHeader(&record);
    try std.testing.expectEqual(protocol.TextRecordKind.row, first_row.kind);
    try std.testing.expect(first_row.payload_len != 0);
    try std.testing.expectEqual(service.observation_revision, service.delta_revision);
}

test "canonical VT allocation failure still escapes the client containment boundary" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const instance = try howl.init(failing.allocator(), std.testing.environ, .{
        .shell = "/bin/sh",
        .command = "read line; printf '\x1b]2;owner-allocation\x07'; exec cat",
        .rows = 2,
        .columns = 24,
        .history_rows = 2,
    });
    defer howl.deinit(instance);
    var service = try Service.init(std.testing.allocator, std.testing.io, instance);
    defer service.deinit();
    var peer = try TestPeer.adopt(std.testing.allocator, &service);
    defer peer.deinit();
    try expectAttachReady(&peer, &service);

    failing.fail_index = failing.alloc_index;
    try howl.input(instance, .{ .bytes = "go\n" });
    var escaped = false;
    var turns: usize = 0;
    while (turns < 2_000) : (turns += 1) {
        service.turn(1) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            escaped = true;
            break;
        };
    }
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(escaped);
    try std.testing.expectEqual(@as(u16, 1), service.clientCount());
}

test "complete synchronized frame publishes without fallback quiet hold" {
    const instance = try howl.init(std.testing.allocator, std.testing.environ, .{
        .shell = "/bin/sh",
        .command = "printf '\\033[?2026hSYNC_READY\\033[?2026l'; exec sleep 30",
        .rows = 2,
        .columns = 24,
        .history_rows = 2,
    });
    defer howl.deinit(instance);
    var service = try Service.init(std.testing.allocator, std.testing.io, instance);
    defer service.deinit();
    const before = service.observation_revision;
    var turns: usize = 0;
    while (turns < 2_000) : (turns += 1) {
        try service.turn(1);
        if (semanticViewContains(howl.terminal(instance).semanticView(0), "SYNC_READY") and
            !howl.terminal(instance).synchronizedOutput()) break;
    }
    try std.testing.expect(turns < 2_000);
    try std.testing.expectEqual(before + 1, service.observation_revision);
    try std.testing.expect(service.burst_publication.started_ns == null);
}

test "unbracketed output retains quiet and bounded burst publication" {
    var gate: BurstPublicationGate = .{};
    gate.note(10, burst_publication_fast_max_ns);
    try std.testing.expect(!gate.ready(10 + burst_publication_quiet_ns - 1));
    try std.testing.expect(gate.ready(10 + burst_publication_quiet_ns));
    try std.testing.expect(gate.waitMs(10 + burst_publication_quiet_ns) == null);
    gate.note(10, burst_publication_fast_max_ns);
    gate.note(10 + burst_publication_fast_max_ns - 1, burst_publication_fast_max_ns);
    try std.testing.expect(gate.ready(10 + burst_publication_fast_max_ns));
    gate.note(10, burst_publication_fast_max_ns);
    gate.note(10 + burst_publication_fast_max_ns - 1, burst_publication_scroll_max_ns);
    try std.testing.expect(!gate.ready(10 + burst_publication_fast_max_ns));
    gate.note(10 + burst_publication_scroll_max_ns - 1, burst_publication_scroll_max_ns);
    try std.testing.expect(gate.ready(10 + burst_publication_scroll_max_ns));

    const instance = try howl.init(std.testing.allocator, std.testing.environ, .{
        .shell = "/bin/sh",
        .command = "printf RAW_READY; exec sleep 30",
        .rows = 2,
        .columns = 24,
        .history_rows = 2,
    });
    defer howl.deinit(instance);
    var service = try Service.init(std.testing.allocator, std.testing.io, instance);
    defer service.deinit();
    const before = service.observation_revision;
    var turns: usize = 0;
    while (turns < 2_000 and !semanticViewContains(howl.terminal(instance).semanticView(0), "RAW_READY")) : (turns += 1)
        try service.turn(1);
    try std.testing.expect(turns < 2_000);
    try std.testing.expectEqual(before, service.observation_revision);
    try std.testing.expect(service.burst_publication.started_ns != null);
    try std.testing.expectEqual(TerminalPublication.burst_fast, service.terminalPublication(true, true, false, .{ .ended = false }, 1));
    try std.testing.expectEqual(TerminalPublication.burst_scroll, service.terminalPublication(true, true, true, .{ .ended = false }, 1));
    try std.testing.expectEqual(TerminalPublication.immediate, service.terminalPublication(true, false, false, .{ .ended = false }, 1));
}

test "synchronized release publishes before a new held frame renews timeout protection" {
    const instance = try howl.init(std.testing.allocator, std.testing.environ, .{
        .shell = "/bin/sh",
        .command = "printf '\\033[?2026hA\\033[?2026l\\033[?2026hB'; exec sleep 30",
        .rows = 2,
        .columns = 24,
        .history_rows = 2,
    });
    defer howl.deinit(instance);
    var service = try Service.init(std.testing.allocator, std.testing.io, instance);
    defer service.deinit();
    const before = service.observation_revision;
    var turns: usize = 0;
    while (turns < 2_000 and service.observation_revision == before) : (turns += 1)
        try service.turn(1);
    try std.testing.expect(turns < 2_000);
    try std.testing.expect(!howl.terminal(instance).synchronizedOutput());
    try std.testing.expect(semanticViewContains(howl.terminal(instance).semanticView(0), "A"));
    try std.testing.expect(!semanticViewContains(howl.terminal(instance).semanticView(0), "AB"));
    if (howl.bufferedOutputPending(instance)) {
        try std.testing.expect(service.requiresTurnWithoutPtyReadiness());
        try std.testing.expect(try service.waitDescriptor() == null);
    }
    turns = 0;
    while (turns < 2_000 and !semanticViewContains(howl.terminal(instance).semanticView(0), "AB")) : (turns += 1)
        try service.turn(1);
    try std.testing.expect(turns < 2_000);
    try std.testing.expect(howl.terminal(instance).synchronizedOutput());
    try std.testing.expectEqual(before + 1, service.observation_revision);
    try std.testing.expect(service.synchronized_output_pending);
    try std.testing.expect(service.burst_publication.started_ns == null);

    // Controlled monotonic time proves the boundary, not a wall-clock sleep.
    try std.testing.expectEqual(TerminalPublication.none, service.terminalPublication(true, true, false, .{ .ended = true }, 100));
    try std.testing.expectEqual(TerminalPublication.none, service.terminalPublication(false, true, false, .{ .ended = false }, 100 + synchronized_output_timeout_ns - 1));
    try std.testing.expectEqual(TerminalPublication.immediate, service.terminalPublication(false, true, false, .{ .ended = false }, 100 + synchronized_output_timeout_ns));
    try std.testing.expect(service.synchronized_output_timed_out);
    try std.testing.expectEqual(TerminalPublication.none, service.terminalPublication(false, true, false, .{ .ended = false }, 101 + synchronized_output_timeout_ns));
    try std.testing.expectEqual(TerminalPublication.immediate, service.terminalPublication(true, true, false, .{ .ended = false }, 102 + synchronized_output_timeout_ns));
    // A later real end -> begin gives the new frame its own bounded hold.
    try std.testing.expectEqual(TerminalPublication.none, service.terminalPublication(true, true, false, .{ .ended = true }, 200 + synchronized_output_timeout_ns));
    try std.testing.expect(!service.synchronized_output_timed_out);
    try std.testing.expectEqual(@as(?u64, 200 + synchronized_output_timeout_ns), service.synchronized_output_started_ns);
}

test "raw tail after synchronized release retains fallback burst protection" {
    const instance = try howl.init(std.testing.allocator, std.testing.environ, .{
        .shell = "/bin/sh",
        .command = "printf '\\033[?2026hA\\033[?2026lRAW_PART'; exec sleep 30",
        .rows = 2,
        .columns = 24,
        .history_rows = 2,
    });
    defer howl.deinit(instance);
    var service = try Service.init(std.testing.allocator, std.testing.io, instance);
    defer service.deinit();
    const before = service.observation_revision;
    var turns: usize = 0;
    while (turns < 2_000 and !semanticViewContains(howl.terminal(instance).semanticView(0), "RAW_PART")) : (turns += 1)
        try service.turn(1);
    try std.testing.expect(turns < 2_000);
    try std.testing.expect(!howl.terminal(instance).synchronizedOutput());
    try std.testing.expectEqual(before + 1, service.observation_revision);
    try std.testing.expect(service.burst_publication.started_ns != null);
}

test "held frame release with a raw tail preserves batching across PTY turns" {
    const instance = try howl.init(std.testing.allocator, std.testing.environ, .{
        .shell = "/bin/sh",
        .command = "stty -echo; printf '\\033[?2026hHELD'; read line; " ++
            "printf '\\033[?2026lRAW_PART'; exec sleep 30",
        .rows = 2,
        .columns = 24,
        .history_rows = 2,
    });
    defer howl.deinit(instance);
    var service = try Service.init(std.testing.allocator, std.testing.io, instance);
    defer service.deinit();
    const before = service.observation_revision;
    var turns: usize = 0;
    while (turns < 2_000 and !semanticViewContains(howl.terminal(instance).semanticView(0), "HELD")) : (turns += 1)
        try service.turn(1);
    try std.testing.expect(turns < 2_000);
    try std.testing.expect(service.synchronized_output_pending);
    try std.testing.expectEqual(before, service.observation_revision);
    try howl.input(instance, .{ .bytes = "go\n" });
    service.pty_write_pending = true;
    turns = 0;
    while (turns < 2_000 and !semanticViewContains(howl.terminal(instance).semanticView(0), "RAW_PART")) : (turns += 1)
        try service.turn(1);
    try std.testing.expect(turns < 2_000);
    try std.testing.expect(!howl.terminal(instance).synchronizedOutput());
    try std.testing.expectEqual(before + 1, service.observation_revision);
    try std.testing.expect(service.burst_publication.started_ns != null);
}

test "stalled observer cannot stop canonical synchronized frames or final lifecycle release" {
    const instance = try howl.init(std.testing.allocator, std.testing.environ, .{
        .shell = "/bin/sh",
        .command = "stty -echo; printf READY; read line; i=0; " ++
            "while [ $i -lt 100 ]; do printf '\\033[?2026h\\033[HCANONICAL_%03d\\033[?2026l' $i; i=$((i+1)); done; " ++
            "printf '\\033[?2026h\\033[HFINAL_HELD'; exit 0",
        .rows = 47,
        .columns = 192,
        .history_rows = 2,
    });
    defer howl.deinit(instance);
    var service = try Service.init(std.testing.allocator, std.testing.io, instance);
    defer service.deinit();
    var peer = try TestPeer.adopt(std.testing.allocator, &service);
    defer peer.deinit();
    try expectAttachReady(&peer, &service);
    var turns: usize = 0;
    while (turns < 2_000 and !semanticViewContains(howl.terminal(instance).semanticView(0), "READY")) : (turns += 1)
        try service.turn(1);
    try std.testing.expect(turns < 2_000);
    var observe: [protocol.payload_bytes.observe]u8 = undefined;
    protocol.encodeObserve(&observe, .{ .after_revision = 0, .history_offset = 0 });
    try peer.sendFrame(&service, .observe_raw, &observe);
    // Deliberately never drain this peer's large snapshot again.
    for (0..10) |_| try service.turn(0);
    const before = service.observation_revision;
    try std.testing.expect(service.clients[0].?.outputPending());
    try howl.input(instance, .{ .bytes = "go\n" });
    service.pty_write_pending = true;
    turns = 0;
    while (turns < 2_000 and !(service.stream_closed and service.child_exited)) : (turns += 1)
        try service.turn(1);
    try std.testing.expect(turns < 2_000);
    try std.testing.expect(semanticViewContains(howl.terminal(instance).semanticView(0), "FINAL_HELD"));
    try std.testing.expect(service.observation_revision > before);
    try std.testing.expectEqual(@as(u16, 1), service.clientCount());
    try std.testing.expect(service.clients[0].?.outputPending());
}

test "DCS frame with pending-wrap-only tail retains burst protection" {
    const instance = try howl.init(std.testing.allocator, std.testing.environ, .{
        .shell = "/bin/sh",
        .command = "printf '\\033P=1s\\033\\\\A\\033P=2s\\033\\\\\\033[?6l'; exec sleep 30",
        .rows = 2,
        .columns = 1,
        .history_rows = 2,
    });
    defer howl.deinit(instance);
    var service = try Service.init(std.testing.allocator, std.testing.io, instance);
    defer service.deinit();
    const before = service.observation_revision;
    var turns: usize = 0;
    while (turns < 2_000) : (turns += 1) {
        try service.turn(1);
        if (howl.terminal(instance).semanticView(0).cellAt(0, 0) == 'A' and
            !howl.terminal(instance).synchronizedOutput() and
            service.burst_publication.started_ns != null) break;
    }
    try std.testing.expect(turns < 2_000);
    try std.testing.expectEqual(before + 1, service.observation_revision);
    try std.testing.expect(service.burst_publication.started_ns != null);
}
