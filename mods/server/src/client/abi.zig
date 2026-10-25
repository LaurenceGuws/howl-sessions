//! Versioned optional native client façade. No runtime, renderer or live VT owner.
const std = @import("std");
const client = @import("server_client");
const terminal = client.terminal;
const view = terminal.view;
const c = @import("native_abi_types");
const native = @import("client_native");
const queries = native.queries;
const heap = std.heap.c_allocator;
const OwnedTree = struct { value: client.Tree };
const OwnedImage = struct { value: terminal.images.Resource };
const OwnedRequest = struct { value: native.RequestSnapshot };

// zig-audit: acknowledge anytype
// reason: This one private conversion accepts only matching C/client opaque pointer families at fixed exported call sites.
fn convert(comptime T: type, value: anytype) T {
    // zig-audit: acknowledge ptr_cast
    // reason: C opaque handles preserve the exact matching client or view allocation; exported functions never cast records, enums, unions or slices across the ABI.
    // zig-audit: acknowledge align_cast
    // reason: Every live opaque handle retains the native alignment of its original matching owner allocation.
    return @ptrCast(@alignCast(value));
}

const Error = client.Error || terminal.actions.Error || terminal.rich.Error ||
    terminal.images.Error || view.Error || native.Error;

fn failure(err: Error) u32 {
    return switch (err) {
        error.OutOfMemory => c.HSC_OUT_OF_MEMORY,
        error.ConnectionCanceled => c.HSC_CANCELLED,
        error.SocketConnectTimedOut => c.HSC_TIMEOUT,
        error.ConnectionClosed => c.HSC_CLOSED,
        error.ConnectionRetired => c.HSC_RETIRED,
        error.StaleServerIncarnation => c.HSC_STALE_SERVER,
        error.InvalidEndpoint, error.SocketPathTooLong, error.InvalidText, error.InvalidResize, error.InvalidArgument, error.InvalidPoint, error.InvalidQuery => c.HSC_INVALID_ARGUMENT,
        error.PayloadTooLarge, error.SnapshotTooLarge, error.ViewTooLarge, error.RequestTooLarge, error.RowTooLarge, error.CoordinatesTooLarge => c.HSC_RESOURCE_LIMIT,
        error.SessionNotFound => c.HSC_SESSION_NOT_FOUND,
        error.InstanceNotFound => c.HSC_INSTANCE_NOT_FOUND,
        error.NameExists => c.HSC_NAME_EXISTS,
        error.SessionCapacity => c.HSC_SESSION_CAPACITY,
        error.InstanceCapacity => c.HSC_INSTANCE_CAPACITY,
        error.CreateFailed => c.HSC_CREATE_FAILED,
        error.Internal, error.ObservationPending => c.HSC_INTERNAL,
        error.Unavailable => c.HSC_UNAVAILABLE,
        error.Unsupported => c.HSC_UNSUPPORTED,
        error.NotGeometryLeader => c.HSC_NOT_LEADER,
        error.NotAuthority => c.HSC_NOT_AUTHORITY,
        error.ServerRejected, error.SelectionRejected, error.ContextChanged => c.HSC_REJECTED,
        error.BufferTooSmall => c.HSC_BUFFER_TOO_SMALL,
        error.Malformed => c.HSC_INVALID_ARGUMENT,
        error.InvalidUtf8, error.InvalidMagic, error.UnsupportedFramingVersion, error.InvalidReservedBits, error.UnknownKind, error.InvalidPayload, error.UnexpectedFrame, error.UnexpectedHandshakeFrame, error.InvalidSnapshot, error.InvalidRichSnapshot, error.InvalidResource, error.DeltaBaselineMismatch => c.HSC_PROTOCOL_ERROR,
        error.SocketCreateFailed, error.SocketDuplicateFailed, error.SocketConnectFailed, error.SocketOptionFailed, error.SocketReadFailed, error.SocketShutdownFailed, error.SocketWriteFailed => c.HSC_TRANSPORT_ERROR,
    };
}

fn bytes(ptr: ?[*]const u8, len: usize, maximum: usize) ?[]const u8 {
    if (len > maximum) return null;
    if (ptr) |p| return p[0..len];
    return if (len == 0) "" else null;
}

fn tag(comptime T: type, value: u32) ?T {
    inline for (@typeInfo(T).@"enum".field_values) |valid| {
        if (value == valid) return @fromBackingInt(@intCast(value));
    }
    return null;
}

fn statusCopy(value: client.protocol.Status) c.hsc_server_status {
    return .{ .server_id = value.server_id, .tree_revision = value.tree_revision, .session_count = value.session_count, .instance_count = value.instance_count, .session_capacity = value.session_capacity, .instances_per_session = value.instances_per_session };
}

/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_abi_version() u32 {
    return c.HSC_ABI_VERSION;
}

/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_interrupt_create(version: u32, out: ?*?*c.hsc_interrupt) u32 {
    if (version != c.HSC_ABI_VERSION) return c.HSC_VERSION_MISMATCH;
    const slot = out orelse return c.HSC_INVALID_ARGUMENT;
    if (slot.* != null) return c.HSC_INVALID_ARGUMENT;
    const token = client.Interrupt.init(heap) catch |err| return failure(err);
    slot.* = convert(*c.hsc_interrupt, token);
    return c.HSC_OK;
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_interrupt_cancel(raw: ?*c.hsc_interrupt) u32 {
    const token = raw orelse return c.HSC_INVALID_ARGUMENT;
    convert(*client.Interrupt, token).cancel() catch |err| return failure(err);
    return c.HSC_OK;
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_interrupt_release(out: ?*?*c.hsc_interrupt) void {
    const slot = out orelse return;
    const raw = slot.* orelse return;
    slot.* = null;
    convert(*client.Interrupt, raw).deinit();
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_control_open(version: u32, endpoint: ?[*]const u8, len: usize, interrupt: ?*c.hsc_interrupt, out: ?*?*c.hsc_control) u32 {
    if (version != c.HSC_ABI_VERSION) return c.HSC_VERSION_MISMATCH;
    const slot = out orelse return c.HSC_INVALID_ARGUMENT;
    if (slot.* != null) return c.HSC_INVALID_ARGUMENT;
    const target = bytes(endpoint, len, 1024) orelse return c.HSC_INVALID_ARGUMENT;
    if (target.len == 0) return c.HSC_INVALID_ARGUMENT;
    var diagnostic: client.ConnectDiagnostic = .{};
    const token: ?*client.Interrupt = if (interrupt) |p| convert(*client.Interrupt, p) else null;
    const control = client.Connection.connectCancelable(heap, target, &diagnostic, token) catch |err| return failure(err);
    slot.* = convert(*c.hsc_control, control);
    return c.HSC_OK;
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_control_release(out: ?*?*c.hsc_control) void {
    const slot = out orelse return;
    const raw = slot.* orelse return;
    slot.* = null;
    convert(*client.Connection, raw).deinit();
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_control_status(raw: ?*c.hsc_control, out: ?*c.hsc_server_status) u32 {
    const control = raw orelse return c.HSC_INVALID_ARGUMENT;
    const result = out orelse return c.HSC_INVALID_ARGUMENT;
    const value = convert(*client.Connection, control).status() catch |err| return failure(err);
    result.* = statusCopy(value);
    return c.HSC_OK;
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_control_tree(raw: ?*c.hsc_control, after: u64, out: ?*?*c.hsc_tree) u32 {
    const control = raw orelse return c.HSC_INVALID_ARGUMENT;
    const slot = out orelse return c.HSC_INVALID_ARGUMENT;
    if (slot.* != null) return c.HSC_INVALID_ARGUMENT;
    const owner = heap.create(OwnedTree) catch |err| return failure(err);
    owner.value = convert(*client.Connection, control).observeTree(after) catch |err| {
        heap.destroy(owner);
        return failure(err);
    };
    slot.* = convert(*c.hsc_tree, owner);
    return c.HSC_OK;
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_tree_release(out: ?*?*c.hsc_tree) void {
    const slot = out orelse return;
    const raw = slot.* orelse return;
    slot.* = null;
    const owner = convert(*OwnedTree, raw);
    owner.value.deinit();
    heap.destroy(owner);
}
fn treeOwner(raw: *const c.hsc_tree) *const OwnedTree {
    return convert(*const OwnedTree, raw);
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_tree_status(raw: ?*const c.hsc_tree, out: ?*c.hsc_server_status) u32 {
    const tree = raw orelse return c.HSC_INVALID_ARGUMENT;
    const result = out orelse return c.HSC_INVALID_ARGUMENT;
    result.* = statusCopy(treeOwner(tree).value.status);
    return c.HSC_OK;
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_tree_session(raw: ?*const c.hsc_tree, index: usize, out: ?*c.hsc_session) u32 {
    const tree = raw orelse return c.HSC_INVALID_ARGUMENT;
    const result = out orelse return c.HSC_INVALID_ARGUMENT;
    const sessions = treeOwner(tree).value.sessions;
    if (index >= sessions.len) return c.HSC_INVALID_ARGUMENT;
    const value = sessions[index];
    result.* = .{ .id = value.id, .name = value.name.ptr, .name_len = value.name.len, .instance_count = value.instances.len };
    return c.HSC_OK;
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_tree_instance(raw: ?*const c.hsc_tree, session: usize, instance: usize, out: ?*c.hsc_instance) u32 {
    const tree = raw orelse return c.HSC_INVALID_ARGUMENT;
    const result = out orelse return c.HSC_INVALID_ARGUMENT;
    const sessions = treeOwner(tree).value.sessions;
    if (session >= sessions.len or instance >= sessions[session].instances.len) return c.HSC_INVALID_ARGUMENT;
    const value = sessions[session].instances[instance];
    result.* = .{ .id = value.instance_id, .state = @backingInt(value.state) };
    return c.HSC_OK;
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_session_create(raw: ?*c.hsc_control, name: ?[*]const u8, len: usize, out: ?*u64) u32 {
    const control = raw orelse return c.HSC_INVALID_ARGUMENT;
    const result = out orelse return c.HSC_INVALID_ARGUMENT;
    const text = bytes(name, len, client.protocol.maximum_session_name_bytes) orelse return c.HSC_INVALID_ARGUMENT;
    client.protocol.validateSessionName(text) catch return c.HSC_INVALID_ARGUMENT;
    result.* = convert(*client.Connection, control).createSession(text) catch |err| return failure(err);
    return c.HSC_OK;
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_session_close(raw: ?*c.hsc_control, id: u64) u32 {
    const control = raw orelse return c.HSC_INVALID_ARGUMENT;
    if (id == 0) return c.HSC_INVALID_ARGUMENT;
    convert(*client.Connection, control).closeSession(id) catch |err| return failure(err);
    return c.HSC_OK;
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_instance_create(raw: ?*c.hsc_control, request: ?*const c.hsc_launch, out: ?*c.hsc_identity) u32 {
    const control = raw orelse return c.HSC_INVALID_ARGUMENT;
    const value = request orelse return c.HSC_INVALID_ARGUMENT;
    const result = out orelse return c.HSC_INVALID_ARGUMENT;
    if (value.reserved != 0) return c.HSC_INVALID_ARGUMENT;
    const shell = bytes(value.shell, value.shell_len, client.protocol.maximum_shell_bytes) orelse return c.HSC_INVALID_ARGUMENT;
    const command = bytes(value.command, value.command_len, client.protocol.maximum_command_bytes) orelse return c.HSC_INVALID_ARGUMENT;
    const cwd = bytes(value.cwd, value.cwd_len, client.protocol.maximum_cwd_bytes) orelse return c.HSC_INVALID_ARGUMENT;
    const launch: client.Connection.InstanceLaunch = .{ .session_id = value.session_id, .shell = shell, .command = if (value.command == null) null else command, .cwd = if (value.cwd == null) null else cwd, .rows = value.rows, .columns = value.columns, .history_rows = value.history_rows };
    const encoded_size = client.protocol.createInstanceEncodedBytes(.{ .session_id = launch.session_id, .shell = launch.shell, .command = launch.command, .cwd = launch.cwd, .rows = launch.rows, .columns = launch.columns, .history_rows = launch.history_rows }) catch return c.HSC_INVALID_ARGUMENT;
    if (encoded_size > client.protocol.maximum_request_payload_bytes) return c.HSC_INVALID_ARGUMENT;
    const identity = convert(*client.Connection, control).createInstance(launch) catch |err| return failure(err);
    result.* = .{ .session_id = identity.session_id, .instance_id = identity.instance_id };
    return c.HSC_OK;
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_instance_close(raw: ?*c.hsc_control, id: c.hsc_identity) u32 {
    const control = raw orelse return c.HSC_INVALID_ARGUMENT;
    if (id.session_id == 0 or id.instance_id == 0) return c.HSC_INVALID_ARGUMENT;
    convert(*client.Connection, control).closeInstance(.{ .session_id = id.session_id, .instance_id = id.instance_id }) catch |err| return failure(err);
    return c.HSC_OK;
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_attachment_open(version: u32, endpoint: ?[*]const u8, len: usize, server: u64, session: u64, instance: u64, interrupt: ?*c.hsc_interrupt, out: ?*?*c.hsc_attachment) u32 {
    if (version != c.HSC_ABI_VERSION) return c.HSC_VERSION_MISMATCH;
    const slot = out orelse return c.HSC_INVALID_ARGUMENT;
    if (slot.* != null) return c.HSC_INVALID_ARGUMENT;
    const target = bytes(endpoint, len, 1024) orelse return c.HSC_INVALID_ARGUMENT;
    if (target.len == 0 or server == 0 or session == 0 or instance == 0) return c.HSC_INVALID_ARGUMENT;
    const token: ?*client.Interrupt = if (interrupt) |p| convert(*client.Interrupt, p) else null;
    var diagnostic: client.ConnectDiagnostic = .{};
    const connection = client.attach(heap, .{ .endpoint = target, .server_id = server, .session_id = session, .instance_id = instance }, &diagnostic, token) catch |err| return failure(err);
    slot.* = convert(*c.hsc_attachment, connection);
    return c.HSC_OK;
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_attachment_release(out: ?*?*c.hsc_attachment) void {
    const slot = out orelse return;
    const raw = slot.* orelse return;
    slot.* = null;
    convert(*terminal.Connection, raw).deinit();
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_attachment_identity(raw: ?*const c.hsc_attachment, out: ?*c.hsc_ready) u32 {
    const connection = raw orelse return c.HSC_INVALID_ARGUMENT;
    const result = out orelse return c.HSC_INVALID_ARGUMENT;
    const value = convert(*const terminal.Connection, connection).identity();
    result.* = .{ .server_id = value.server_id, .session_id = value.session_id, .instance_id = value.instance_id, .tree_revision = value.tree_revision, .client_id = value.client_id };
    return c.HSC_OK;
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_text(raw: ?*c.hsc_attachment, text: ?[*]const u8, len: usize, paste: u32) u32 {
    const connection = raw orelse return c.HSC_INVALID_ARGUMENT;
    const value = bytes(text, len, terminal.protocol.maximum_request_payload_bytes - 1) orelse return c.HSC_INVALID_ARGUMENT;
    if (paste > 1) return c.HSC_INVALID_ARGUMENT;
    const attachment = convert(*terminal.Connection, connection);
    if (paste == 1) terminal.actions.paste(attachment, value) catch |err| return failure(err) else terminal.actions.committedText(attachment, value) catch |err| return failure(err);
    return c.HSC_OK;
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_named_key(raw: ?*c.hsc_attachment, key: u32, action: u32, modifiers: u32) u32 {
    const connection = raw orelse return c.HSC_INVALID_ARGUMENT;
    const k = tag(terminal.protocol.InputKeyName, key) orelse return c.HSC_INVALID_ARGUMENT;
    const a = tag(terminal.protocol.InputKeyAction, action) orelse return c.HSC_INVALID_ARGUMENT;
    if (modifiers > 255) return c.HSC_INVALID_ARGUMENT;
    terminal.actions.namedKey(convert(*terminal.Connection, connection), k, a, @intCast(modifiers)) catch |err| return failure(err);
    return c.HSC_OK;
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_unicode_key(raw: ?*c.hsc_attachment, scalar: u32, action: u32, modifiers: u32) u32 {
    const connection = raw orelse return c.HSC_INVALID_ARGUMENT;
    const a = tag(terminal.protocol.InputKeyAction, action) orelse return c.HSC_INVALID_ARGUMENT;
    if (modifiers > 255 or scalar > 0x10ffff or (scalar >= 0xd800 and scalar <= 0xdfff)) return c.HSC_INVALID_ARGUMENT;
    terminal.actions.unicodeKey(convert(*terminal.Connection, connection), scalar, a, @intCast(modifiers)) catch |err| return failure(err);
    return c.HSC_OK;
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_focus(raw: ?*c.hsc_attachment, focus: u32) u32 {
    const connection = raw orelse return c.HSC_INVALID_ARGUMENT;
    const value = tag(terminal.protocol.InputFocus, focus) orelse return c.HSC_INVALID_ARGUMENT;
    terminal.actions.focus(convert(*terminal.Connection, connection), value) catch |err| return failure(err);
    return c.HSC_OK;
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_resize(raw: ?*c.hsc_attachment, rows: u16, columns: u16, acquire: u32) u32 {
    const connection = raw orelse return c.HSC_INVALID_ARGUMENT;
    if (acquire > 1) return c.HSC_INVALID_ARGUMENT;
    const attachment = convert(*terminal.Connection, connection);
    if (acquire == 1) terminal.actions.resize(attachment, rows, columns) catch |err| return failure(err) else terminal.actions.resizeOwned(attachment, rows, columns) catch |err| return failure(err);
    return c.HSC_OK;
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_signal(raw: ?*c.hsc_attachment, signal: u32) u32 {
    const connection = raw orelse return c.HSC_INVALID_ARGUMENT;
    const value = tag(terminal.protocol.Signal, signal) orelse return c.HSC_INVALID_ARGUMENT;
    terminal.actions.signal(convert(*terminal.Connection, connection), value) catch |err| return failure(err);
    return c.HSC_OK;
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_observe(raw: ?*c.hsc_attachment, after: u64, offset: u32, out: ?*?*c.hsc_snapshot) u32 {
    const connection = raw orelse return c.HSC_INVALID_ARGUMENT;
    const slot = out orelse return c.HSC_INVALID_ARGUMENT;
    if (slot.* != null) return c.HSC_INVALID_ARGUMENT;
    var source = terminal.rich.requestPacked(convert(*terminal.Connection, connection), heap, after, offset) catch |err| return failure(err);
    defer source.deinit();
    const snapshot = view.project(heap, &source) catch |err| return failure(err);
    slot.* = convert(*c.hsc_snapshot, snapshot);
    return c.HSC_OK;
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_snapshot_release(out: ?*?*c.hsc_snapshot) void {
    const slot = out orelse return;
    const raw = slot.* orelse return;
    slot.* = null;
    view.deinit(convert(*view.Snapshot, raw));
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_snapshot_metadata(raw: ?*const c.hsc_snapshot, out: ?*c.hsc_metadata) u32 {
    const snapshot = raw orelse return c.HSC_INVALID_ARGUMENT;
    const result = out orelse return c.HSC_INVALID_ARGUMENT;
    const value = convert(*const view.Snapshot, snapshot);
    const meta = view.metadata(value);
    const begin = view.begin(value);
    result.* = .{ .delivery_revision = begin.revision, .terminal_revision = meta.revision, .history_offset = meta.history_offset, .history_count = meta.history_count, .history_row_base = meta.history_row_base, .row_count = @intCast(view.rows(value).len), .cell_count = @intCast(view.cells(value).len), .scalar_count = @intCast(view.scalars(value).len), .hyperlink_count = @intCast(view.hyperlinks(value).len), .rows = meta.rows, .columns = meta.columns, .cursor_row = meta.cursor_row, .cursor_column = meta.cursor_column, .cursor_shape = @backingInt(view.cursorShapeFromValue(meta.cursor_shape)), .flags = @as(u32, @intFromBool(meta.cursor_visible)) | (@as(u32, @intFromBool(meta.cursor_blink)) << 1) |
        (@as(u32, @intFromBool(meta.alternate_screen)) << 2) | (@as(u32, @intFromBool(begin.child_exited)) << 3) |
        (@as(u32, @intFromBool(begin.stream_closed)) << 4) | (@as(u32, @intFromBool(begin.leader_present)) << 5) | (@as(u32, @intFromBool(begin.you_are_leader)) << 6) };
    return c.HSC_OK;
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_snapshot_row(raw: ?*const c.hsc_snapshot, index: usize, out: ?*c.hsc_row) u32 {
    const snapshot = raw orelse return c.HSC_INVALID_ARGUMENT;
    const result = out orelse return c.HSC_INVALID_ARGUMENT;
    const rows = view.rows(convert(*const view.Snapshot, snapshot));
    if (index >= rows.len) return c.HSC_INVALID_ARGUMENT;
    const value = rows[index];
    result.* = .{ .cell_offset = value.cell_offset, .cell_count = value.cell_count, .wrapped = @intFromBool(value.wrapped), .geometry = @backingInt(view.lineGeometry(value)) };
    return c.HSC_OK;
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_snapshot_cells(raw: ?*const c.hsc_snapshot, start: usize, output: ?[*]c.hsc_cell, capacity: usize, written: ?*usize) u32 {
    const snapshot = raw orelse return c.HSC_INVALID_ARGUMENT;
    const count = written orelse return c.HSC_INVALID_ARGUMENT;
    count.* = 0;
    const cells = view.cells(convert(*const view.Snapshot, snapshot));
    if (start > cells.len or (capacity != 0 and output == null)) return c.HSC_INVALID_ARGUMENT;
    const length = @min(capacity, cells.len - start);
    if (length == 0) return c.HSC_OK;
    for (cells[start..][0..length], output.?[0..length]) |value, *dest| {
        const style = view.cellStyle(value);
        dest.* = .{ .scalar_offset = value.scalar_offset, .scalar_count = value.scalar_count, .link_id = value.link_id, .style = @as(u32, @intFromBool(style.bold)) | (@as(u32, @intFromBool(style.dim)) << 1) |
            (@as(u32, @intFromBool(style.italic)) << 2) | (@as(u32, @intFromBool(style.blink)) << 3) |
            (@as(u32, @intFromBool(style.blink_fast)) << 4) | (@as(u32, @intFromBool(style.reverse)) << 5) |
            (@as(u32, @intFromBool(style.invisible)) << 6) | (@as(u32, @intFromBool(style.underline)) << 7) |
            (@as(u32, @intFromBool(style.strikethrough)) << 8), .foreground = .{ .kind = @backingInt(value.foreground.kind), .value = value.foreground.value }, .background = .{ .kind = @backingInt(value.background.kind), .value = value.background.value }, .underline_color = .{ .kind = @backingInt(value.underline_color.kind), .value = value.underline_color.value }, .width = value.width, .height = value.height, .x = value.x, .y = value.y, .subscale_n = value.subscale_n, .subscale_d = value.subscale_d, .vertical_align = value.vertical_align, .horizontal_align = value.horizontal_align, .semantic_width = @intFromBool(value.semantic_width), .font = value.font, .baseline = value.baseline, .underline_style = value.underline_style, .protection = value.protection, .reserved = @splat(0) };
    }
    count.* = length;
    return c.HSC_OK;
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_snapshot_scalars(raw: ?*const c.hsc_snapshot, out: ?*?[*]const u32, length: ?*usize) u32 {
    const snapshot = raw orelse return c.HSC_INVALID_ARGUMENT;
    const result = out orelse return c.HSC_INVALID_ARGUMENT;
    const count = length orelse return c.HSC_INVALID_ARGUMENT;
    const values = view.scalars(convert(*const view.Snapshot, snapshot));
    result.* = if (values.len == 0) null else values.ptr;
    count.* = values.len;
    return c.HSC_OK;
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_snapshot_hyperlink(raw: ?*const c.hsc_snapshot, index: usize, out: ?*c.hsc_hyperlink) u32 {
    const snapshot = raw orelse return c.HSC_INVALID_ARGUMENT;
    const result = out orelse return c.HSC_INVALID_ARGUMENT;
    const value = convert(*const view.Snapshot, snapshot);
    const links = view.hyperlinks(value);
    if (index >= links.len) return c.HSC_INVALID_ARGUMENT;
    const link = links[index];
    const uri = view.uris(value)[link.uri_offset..][0..link.uri_len];
    result.* = .{ .link_id = link.link_id, .uri = uri.ptr, .uri_len = uri.len };
    return c.HSC_OK;
}
fn rgba(value: terminal.rich.Rgba) c.hsc_rgba {
    return .{ .r = value.r, .g = value.g, .b = value.b, .a = value.a };
}
/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_snapshot_presentation(raw: ?*const c.hsc_snapshot, out: ?*c.hsc_presentation) u32 {
    const snapshot = raw orelse return c.HSC_INVALID_ARGUMENT;
    const result = out orelse return c.HSC_INVALID_ARGUMENT;
    const value = view.presentation(convert(*const view.Snapshot, snapshot));
    result.* = std.mem.zeroes(c.hsc_presentation);
    result.cursor_age_ns = value.cursor_age_ns orelse 0;
    result.present = @as(u32, @intFromBool(value.cursor_age_ns != null)) | (@as(u32, @intFromBool(value.cursor != null)) << 1) |
        (@as(u32, @intFromBool(value.cursor_text != null)) << 2) | (@as(u32, @intFromBool(value.selection_background != null)) << 3) |
        (@as(u32, @intFromBool(value.selection_foreground != null)) << 4);
    result.reverse_screen = @intFromBool(value.reverse_screen);
    result.foreground = rgba(value.foreground);
    result.background = rgba(value.background);
    if (value.cursor) |v| result.cursor = rgba(v);
    if (value.cursor_text) |v| result.cursor_text = rgba(v);
    if (value.selection_background) |v| result.selection_background = rgba(v);
    if (value.selection_foreground) |v| result.selection_foreground = rgba(v);
    for (value.palette, &result.palette) |v, *dest| dest.* = rgba(v);
    return c.HSC_OK;
}

/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_mouse_input(raw: ?*c.hsc_attachment, input: ?*const c.hsc_mouse) u32 {
    const connection = raw orelse return c.HSC_INVALID_ARGUMENT;
    const value = input orelse return c.HSC_INVALID_ARGUMENT;
    const kind = tag(terminal.protocol.InputMouseKind, value.kind) orelse return c.HSC_INVALID_ARGUMENT;
    const button = tag(terminal.protocol.InputMouseButton, value.button) orelse return c.HSC_INVALID_ARGUMENT;
    if (value.reserved != 0 or value.modifiers > 255 or value.buttons_down > 7 or
        value.has_pixels > 1 or (value.has_pixels == 0 and (value.pixel_x != 0 or value.pixel_y != 0)))
        return c.HSC_INVALID_ARGUMENT;
    terminal.actions.mouse(convert(*terminal.Connection, connection), .{
        .kind = kind,
        .button = button,
        .modifiers = @intCast(value.modifiers),
        .buttons_down = @intCast(value.buttons_down),
        .row = value.row,
        .column = value.column,
        .pixel_x = if (value.has_pixels == 1) value.pixel_x else null,
        .pixel_y = if (value.has_pixels == 1) value.pixel_y else null,
    }) catch |err| return failure(err);
    return c.HSC_OK;
}

/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_resize_geometry(raw: ?*c.hsc_attachment, input: ?*const c.hsc_geometry, acquire: u32) u32 {
    const connection = raw orelse return c.HSC_INVALID_ARGUMENT;
    const value = input orelse return c.HSC_INVALID_ARGUMENT;
    if (acquire > 1) return c.HSC_INVALID_ARGUMENT;
    const geometry: terminal.protocol.Resize = .{
        .rows = value.rows,
        .columns = value.columns,
        .cell_pixel_width = value.cell_pixel_width,
        .cell_pixel_height = value.cell_pixel_height,
    };
    const attachment = convert(*terminal.Connection, connection);
    if (acquire == 1) terminal.actions.resizeGeometry(attachment, geometry) catch |err| return failure(err) else terminal.actions.resizeGeometryOwned(attachment, geometry) catch |err| return failure(err);
    return c.HSC_OK;
}

fn borrowed(value: []const u8) c.hsc_bytes {
    return .{ .bytes = if (value.len == 0) null else value.ptr, .length = value.len };
}

/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_snapshot_properties(raw: ?*const c.hsc_snapshot, out: ?*c.hsc_properties) u32 {
    const snapshot = raw orelse return c.HSC_INVALID_ARGUMENT;
    const result = out orelse return c.HSC_INVALID_ARGUMENT;
    const value = view.properties(convert(*const view.Snapshot, snapshot));
    result.* = std.mem.zeroes(c.hsc_properties);
    if (value.title) |v| {
        result.present |= 1;
        result.title = borrowed(v);
    }
    if (value.icon) |v| {
        result.present |= 2;
        result.icon = borrowed(v);
    }
    if (value.directory) |v| {
        result.present |= 4;
        result.directory_kind = @backingInt(v.kind);
        result.directory = borrowed(v.value);
    }
    if (value.remote_host) |v| {
        result.present |= 8;
        result.remote_host = borrowed(v);
    }
    if (value.shell) |v| {
        result.present |= 16;
        result.shell_version = v.version;
        if (v.name) |name| {
            result.present |= 32;
            result.shell_name = borrowed(name);
        }
    }
    result.mark_generation = value.mark.generation;
    result.mark_kind = value.mark.kind;
    result.mark_metadata = borrowed(value.mark.metadata);
    if (value.mark.status) |v| {
        result.present |= 64;
        result.mark_status = v;
    }
    result.progress_kind = @backingInt(value.progress.kind);
    result.progress_value = value.progress.value;
    return c.HSC_OK;
}

/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_snapshot_graphics(raw: ?*const c.hsc_snapshot, out: ?*c.hsc_graphics) u32 {
    const snapshot = raw orelse return c.HSC_INVALID_ARGUMENT;
    const result = out orelse return c.HSC_INVALID_ARGUMENT;
    const value = view.graphics(convert(*const view.Snapshot, snapshot));
    result.* = .{
        .generation = value.generation,
        .content_generation = value.content_generation,
        .cell_pixel_width = value.cell_pixel_width,
        .cell_pixel_height = value.cell_pixel_height,
        .image_count = @intCast(value.images.len),
        .placement_count = @intCast(value.placements.len),
    };
    return c.HSC_OK;
}

/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_snapshot_image(raw: ?*const c.hsc_snapshot, index: usize, out: ?*c.hsc_image_identity) u32 {
    const snapshot = raw orelse return c.HSC_INVALID_ARGUMENT;
    const result = out orelse return c.HSC_INVALID_ARGUMENT;
    const values = view.graphics(convert(*const view.Snapshot, snapshot)).images;
    if (index >= values.len) return c.HSC_INVALID_ARGUMENT;
    const value = values[index];
    result.* = .{ .generation = value.generation, .image_id = value.image_id, .width = value.width, .height = value.height, .reserved = 0 };
    return c.HSC_OK;
}

/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_snapshot_placement(raw: ?*const c.hsc_snapshot, index: usize, out: ?*c.hsc_placement) u32 {
    const snapshot = raw orelse return c.HSC_INVALID_ARGUMENT;
    const result = out orelse return c.HSC_INVALID_ARGUMENT;
    const values = view.graphics(convert(*const view.Snapshot, snapshot)).placements;
    if (index >= values.len) return c.HSC_INVALID_ARGUMENT;
    const value = values[index];
    result.* = .{ .generation = value.generation, .image_id = value.image_id, .row = value.row, .column = value.column, .source_x = value.source_x, .source_y = value.source_y, .source_width = value.source_width, .source_height = value.source_height, .cell_x = value.cell_x, .cell_y = value.cell_y, .pixel_width = value.pixel_width, .pixel_height = value.pixel_height, .z = value.z, .reserved = 0 };
    return c.HSC_OK;
}

/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_image_fetch(raw: ?*c.hsc_attachment, id: u32, generation: u64, out: ?*?*c.hsc_image) u32 {
    const connection = raw orelse return c.HSC_INVALID_ARGUMENT;
    const slot = out orelse return c.HSC_INVALID_ARGUMENT;
    if (slot.* != null or id == 0 or generation == 0) return c.HSC_INVALID_ARGUMENT;
    const owner = heap.create(OwnedImage) catch |err| return failure(err);
    owner.value = terminal.images.request(convert(*terminal.Connection, connection), heap, id, generation) catch |err| {
        heap.destroy(owner);
        return failure(err);
    };
    slot.* = convert(*c.hsc_image, owner);
    return c.HSC_OK;
}

/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_image_release(out: ?*?*c.hsc_image) void {
    const slot = out orelse return;
    const raw = slot.* orelse return;
    slot.* = null;
    const owner = convert(*OwnedImage, raw);
    owner.value.deinit();
    heap.destroy(owner);
}

/// Implements the version-1 C client contract in howl_server_client.h.
pub export fn hsc_image_data(raw: ?*const c.hsc_image, out: ?*c.hsc_image_identity, pixels: ?*?[*]const u8, length: ?*usize) u32 {
    const image = raw orelse return c.HSC_INVALID_ARGUMENT;
    const result = out orelse return c.HSC_INVALID_ARGUMENT;
    const buffer = pixels orelse return c.HSC_INVALID_ARGUMENT;
    const count = length orelse return c.HSC_INVALID_ARGUMENT;
    const value = &convert(*const OwnedImage, image).value;
    result.* = .{ .generation = value.generation, .image_id = value.image_id, .width = value.width, .height = value.height, .reserved = 0 };
    buffer.* = value.pixels.ptr;
    count.* = value.pixels.len;
    return c.HSC_OK;
}

/// Copies coherent native interaction facts through the exact owned client graph.
pub export fn hsc_interaction(raw: ?*c.hsc_attachment, out: ?*c.hvt_interaction) u32 {
    const result = out orelse return c.HSC_INVALID_ARGUMENT;
    result.* = std.mem.zeroes(c.hvt_interaction);
    const owner = raw orelse return c.HSC_INVALID_ARGUMENT;
    result.* = native.interaction(convert(*terminal.Connection, owner)) catch |err| return failure(err);
    return c.HSC_OK;
}
/// Explicitly claims request authority for this exact attachment.
pub export fn hsc_request_acquire(raw: ?*c.hsc_attachment) u32 {
    const owner = raw orelse return c.HSC_INVALID_ARGUMENT;
    native.acquireRequests(convert(*terminal.Connection, owner)) catch |err| return failure(err);
    return c.HSC_OK;
}
/// Owns one independent immutable request view; publication happens only after success.
pub export fn hsc_request_observe(raw: ?*c.hsc_attachment, out: ?*?*c.hsc_request_view) u32 {
    const slot = out orelse return c.HSC_INVALID_ARGUMENT;
    if (slot.* != null) return c.HSC_INVALID_ARGUMENT;
    const owner = raw orelse return c.HSC_INVALID_ARGUMENT;
    const value = heap.create(OwnedRequest) catch return c.HSC_OUT_OF_MEMORY;
    value.value = native.observeRequests(convert(*terminal.Connection, owner), heap) catch |err| {
        heap.destroy(value);
        return failure(err);
    };
    slot.* = convert(*c.hsc_request_view, value);
    return c.HSC_OK;
}
/// Ends every payload borrow and clears the caller-owned view slot.
pub export fn hsc_request_view_release(out: ?*?*c.hsc_request_view) void {
    const slot = out orelse return;
    const raw = slot.* orelse return;
    slot.* = null;
    const value = convert(*OwnedRequest, raw);
    value.value.deinit();
    heap.destroy(value);
}
/// Copies Server authority and VT-native terminal facts from an immutable view.
pub export fn hsc_request_view_info(raw: ?*const c.hsc_request_view, out: ?*c.hsc_request_info) u32 {
    const result = out orelse return c.HSC_INVALID_ARGUMENT;
    result.* = std.mem.zeroes(c.hsc_request_info);
    const owner = raw orelse return c.HSC_INVALID_ARGUMENT;
    result.* = convert(*const OwnedRequest, owner).value.info;
    return c.HSC_OK;
}
/// Borrows exact immutable request bytes until the matching independent view release.
pub export fn hsc_request_view_payload(raw: ?*const c.hsc_request_view, out: ?*?[*]const u8, length: ?*usize) u32 {
    if (out) |ptr| ptr.* = null;
    if (length) |ptr| ptr.* = 0;
    const ptr = out orelse return c.HSC_INVALID_ARGUMENT;
    const count = length orelse return c.HSC_INVALID_ARGUMENT;
    const owner = raw orelse return c.HSC_INVALID_ARGUMENT;
    const payload = convert(*const OwnedRequest, owner).value.value.payload;
    ptr.* = payload.ptr;
    count.* = payload.len;
    return c.HSC_OK;
}
/// Acknowledges one exact consumable Server-owned occurrence under explicit authority.
pub export fn hsc_request_consume(raw: ?*c.hsc_attachment, id: u64) u32 {
    const owner = raw orelse return c.HSC_INVALID_ARGUMENT;
    native.consumeRequest(convert(*terminal.Connection, owner), id) catch |err| return failure(err);
    return c.HSC_OK;
}

/// Performs one named native operation; Server framing remains client-owned.
pub export fn hsc_reply_clipboard(raw: ?*c.hsc_attachment, id: u64, ptr: ?[*]const u8, len: usize) u32 {
    const owner = raw orelse return c.HSC_INVALID_ARGUMENT;
    if (len > c.HSC_MAX_CLIPBOARD_REPLY_BYTES) return c.HSC_RESOURCE_LIMIT;
    const text = bytes(ptr, len, c.HSC_MAX_CLIPBOARD_REPLY_BYTES) orelse return c.HSC_INVALID_ARGUMENT;
    native.replyClipboard(convert(*terminal.Connection, owner), id, text) catch |err| return failure(err);
    return c.HSC_OK;
}

/// Performs one named native operation; Server framing remains client-owned.
pub export fn hsc_reply_pointer_shape(raw: ?*c.hsc_attachment, id: u64, ptr: ?[*]const u8, len: usize) u32 {
    const owner = raw orelse return c.HSC_INVALID_ARGUMENT;
    if (len > c.HSC_MAX_POINTER_REPLY_BYTES) return c.HSC_RESOURCE_LIMIT;
    const text = bytes(ptr, len, c.HSC_MAX_POINTER_REPLY_BYTES) orelse return c.HSC_INVALID_ARGUMENT;
    native.replyPointerShape(convert(*terminal.Connection, owner), id, text) catch |err| return failure(err);
    return c.HSC_OK;
}

/// Performs one named native operation; Server framing remains client-owned.
pub export fn hsc_reply_color_preference(raw: ?*c.hsc_attachment, id: u64, preference: u32) u32 {
    const owner = raw orelse return c.HSC_INVALID_ARGUMENT;
    native.replyColorPreference(convert(*terminal.Connection, owner), id, preference) catch |err| return failure(err);
    return c.HSC_OK;
}

/// Performs one named native operation; Server framing remains client-owned.
pub export fn hsc_reply_container_state(raw: ?*c.hsc_attachment, id: u64, state: u32) u32 {
    const owner = raw orelse return c.HSC_INVALID_ARGUMENT;
    native.replyContainerState(convert(*terminal.Connection, owner), id, state) catch |err| return failure(err);
    return c.HSC_OK;
}

/// Performs one named native operation; Server framing remains client-owned.
pub export fn hsc_reply_container_position(raw: ?*c.hsc_attachment, id: u64, x: u32, y: u32) u32 {
    const owner = raw orelse return c.HSC_INVALID_ARGUMENT;
    native.replyContainerPosition(convert(*terminal.Connection, owner), id, x, y) catch |err| return failure(err);
    return c.HSC_OK;
}

/// Performs one named native operation; Server framing remains client-owned.
pub export fn hsc_reply_container_screen_cells(raw: ?*c.hsc_attachment, id: u64, rows: u32, columns: u32) u32 {
    const owner = raw orelse return c.HSC_INVALID_ARGUMENT;
    native.replyContainerScreenCells(convert(*terminal.Connection, owner), id, rows, columns) catch |err| return failure(err);
    return c.HSC_OK;
}

/// Performs one named native operation; Server framing remains client-owned.
pub export fn hsc_reply_container_icon_title(raw: ?*c.hsc_attachment, id: u64, ptr: ?[*]const u8, len: usize) u32 {
    const owner = raw orelse return c.HSC_INVALID_ARGUMENT;
    if (len > c.HSC_MAX_ICON_TITLE_REPLY_BYTES) return c.HSC_RESOURCE_LIMIT;
    const text = bytes(ptr, len, c.HSC_MAX_ICON_TITLE_REPLY_BYTES) orelse return c.HSC_INVALID_ARGUMENT;
    native.replyContainerIconTitle(convert(*terminal.Connection, owner), id, text) catch |err| return failure(err);
    return c.HSC_OK;
}

/// Performs one named native operation; Server framing remains client-owned.
pub export fn hsc_decline_container(raw: ?*c.hsc_attachment, id: u64) u32 {
    const owner = raw orelse return c.HSC_INVALID_ARGUMENT;
    native.declineContainer(convert(*terminal.Connection, owner), id) catch |err| return failure(err);
    return c.HSC_OK;
}

fn queryBytes(ptr: ?[*]const u8, len: usize) Error![]const u8 {
    if (len > c.HSC_MAX_SEARCH_QUERY_BYTES) return error.RequestTooLarge;
    return bytes(ptr, len, c.HSC_MAX_SEARCH_QUERY_BYTES) orelse error.InvalidArgument;
}

/// Searches one immutable row without attachment I/O or retained-history paging.
pub export fn hsc_snapshot_search_row(raw: ?*const c.hsc_snapshot, ptr: ?[*]const u8, len: usize, row: u16, column: u16, reverse: u32, out: ?*c.hvt_search_match) u32 {
    const result = out orelse return c.HSC_INVALID_ARGUMENT;
    result.* = std.mem.zeroes(c.hvt_search_match);
    const snapshot = raw orelse return c.HSC_INVALID_ARGUMENT;
    if (reverse > 1) return c.HSC_INVALID_ARGUMENT;
    const query = queryBytes(ptr, len) catch |err| return failure(err);
    queries.searchRow(convert(*const view.Snapshot, snapshot), heap, query, row, column, reverse == 1, result) catch |err| return failure(err);
    return c.HSC_OK;
}

/// Searches only the supplied immutable viewport, with row-local matching.
pub export fn hsc_snapshot_search(raw: ?*const c.hsc_snapshot, ptr: ?[*]const u8, len: usize, row: u16, reverse: u32, out: ?*c.hvt_search_match) u32 {
    const result = out orelse return c.HSC_INVALID_ARGUMENT;
    result.* = std.mem.zeroes(c.hvt_search_match);
    const snapshot = raw orelse return c.HSC_INVALID_ARGUMENT;
    if (reverse > 1) return c.HSC_INVALID_ARGUMENT;
    const query = queryBytes(ptr, len) catch |err| return failure(err);
    queries.search(convert(*const view.Snapshot, snapshot), heap, query, row, reverse == 1, result) catch |err| return failure(err);
    return c.HSC_OK;
}

/// Copies canonical client word/visual-row endpoints and painted final width.
pub export fn hsc_snapshot_expand_selection(raw: ?*const c.hsc_snapshot, kind: u32, row: u16, column: u16, out: ?*c.hvt_selection_range) u32 {
    const result = out orelse return c.HSC_INVALID_ARGUMENT;
    result.* = std.mem.zeroes(c.hvt_selection_range);
    const snapshot = raw orelse return c.HSC_INVALID_ARGUMENT;
    queries.expandSelection(convert(*const view.Snapshot, snapshot), kind, row, column, result) catch |err| return failure(err);
    return c.HSC_OK;
}

/// Distinguishes valid, context-changed and evicted copied ranges.
pub export fn hsc_snapshot_selection_validity(raw: ?*const c.hsc_snapshot, input: ?*const c.hvt_selection_range, out: ?*u32) u32 {
    const result = out orelse return c.HSC_INVALID_ARGUMENT;
    result.* = 0;
    const snapshot = raw orelse return c.HSC_INVALID_ARGUMENT;
    const range = input orelse return c.HSC_INVALID_ARGUMENT;
    result.* = queries.selectionValidity(convert(*const view.Snapshot, snapshot), range) catch |err| return failure(err);
    return c.HSC_OK;
}

/// Copies a same-snapshot text-shaped selection intersection.
pub export fn hsc_snapshot_selection_span(raw: ?*const c.hsc_snapshot, input: ?*const c.hvt_selection_range, row: u16, out: ?*c.hsc_selection_span) u32 {
    const result = out orelse return c.HSC_INVALID_ARGUMENT;
    result.* = std.mem.zeroes(c.hsc_selection_span);
    const snapshot = raw orelse return c.HSC_INVALID_ARGUMENT;
    const range = input orelse return c.HSC_INVALID_ARGUMENT;
    queries.selectionSpan(convert(*const view.Snapshot, snapshot), range, row, result) catch |err| return failure(err);
    return c.HSC_OK;
}

/// Copies all advertised row shapes or leaves the caller array untouched.
pub export fn hsc_snapshot_row_shapes(raw: ?*const c.hsc_snapshot, output: ?[*]c.hvt_row_shape, capacity: usize, required: ?*usize) u32 {
    const count = required orelse return c.HSC_INVALID_ARGUMENT;
    count.* = 0;
    const snapshot = raw orelse return c.HSC_INVALID_ARGUMENT;
    if (capacity != 0 and output == null) return c.HSC_INVALID_ARGUMENT;
    const value = convert(*const view.Snapshot, snapshot);
    const extent = @min(capacity, view.rows(value).len);
    queries.copyRowShapes(value, if (output) |p| p[0..extent] else &.{}, count) catch |err| return failure(err);
    return c.HSC_OK;
}

/// Copies exact lead-cell URI bytes without retaining a snapshot borrow.
pub export fn hsc_snapshot_copy_hyperlink(raw: ?*const c.hsc_snapshot, row: u16, column: u16, output: ?[*]u8, capacity: usize, required: ?*usize) u32 {
    const count = required orelse return c.HSC_INVALID_ARGUMENT;
    count.* = 0;
    const snapshot = raw orelse return c.HSC_INVALID_ARGUMENT;
    if (capacity > c.HSC_MAX_SELECTION_BYTES) return c.HSC_RESOURCE_LIMIT;
    if (capacity != 0 and output == null) return c.HSC_INVALID_ARGUMENT;
    queries.copyHyperlink(convert(*const view.Snapshot, snapshot), row, column, if (output) |p| p[0..capacity] else &.{}, count) catch |err| return failure(err);
    return c.HSC_OK;
}

/// Publishes only a complete independently owned canonical text result.
pub export fn hsc_selection_extract(raw: ?*c.hsc_attachment, input: ?*const c.hvt_selection_range, out: ?*?*c.hsc_text_view) u32 {
    const slot = out orelse return c.HSC_INVALID_ARGUMENT;
    if (slot.* != null) return c.HSC_INVALID_ARGUMENT;
    const connection = raw orelse return c.HSC_INVALID_ARGUMENT;
    const range = input orelse return c.HSC_INVALID_ARGUMENT;
    const result = queries.extract(heap, convert(*terminal.Connection, connection), range) catch |err| return failure(err);
    slot.* = convert(*c.hsc_text_view, result);
    return c.HSC_OK;
}

/// Borrows UTF-8 only from the matching independent text result.
pub export fn hsc_text_view_data(raw: ?*const c.hsc_text_view, out: ?*?[*]const u8, length: ?*usize) u32 {
    if (out) |p| p.* = null;
    if (length) |p| p.* = 0;
    const slot = out orelse return c.HSC_INVALID_ARGUMENT;
    const count = length orelse return c.HSC_INVALID_ARGUMENT;
    const text = raw orelse return c.HSC_INVALID_ARGUMENT;
    const data = queries.textBytes(convert(*const queries.Text, text));
    slot.* = if (data.len == 0) null else data.ptr;
    count.* = data.len;
    return c.HSC_OK;
}

/// Clears and releases only the matching text owner.
pub export fn hsc_text_view_release(out: ?*?*c.hsc_text_view) void {
    const slot = out orelse return;
    const text = slot.* orelse return;
    slot.* = null;
    queries.releaseText(convert(*queries.Text, text));
}

/// Creates a cache bound by copied ready facts, with no attachment borrow.
pub export fn hsc_cache_create(version: u32, raw: ?*c.hsc_attachment, out: ?*?*c.hsc_cache) u32 {
    if (version != c.HSC_ABI_VERSION) return c.HSC_VERSION_MISMATCH;
    const slot = out orelse return c.HSC_INVALID_ARGUMENT;
    if (slot.* != null) return c.HSC_INVALID_ARGUMENT;
    const connection = raw orelse return c.HSC_INVALID_ARGUMENT;
    const cache = queries.createCache(heap, convert(*terminal.Connection, connection)) catch |err| return failure(err);
    slot.* = convert(*c.hsc_cache, cache);
    return c.HSC_OK;
}

/// Clears only cache-owned decoding state; prior snapshot owners remain live.
pub export fn hsc_cache_release(out: ?*?*c.hsc_cache) void {
    const slot = out orelse return;
    const cache = slot.* orelse return;
    slot.* = null;
    queries.releaseCache(convert(*queries.Cache, cache));
}

/// Completes one bound raw/delta observation and publishes an independent snapshot.
pub export fn hsc_observe_cached(raw: ?*c.hsc_attachment, cache: ?*c.hsc_cache, after: u64, offset: u32, out: ?*?*c.hsc_snapshot) u32 {
    const slot = out orelse return c.HSC_INVALID_ARGUMENT;
    if (slot.* != null) return c.HSC_INVALID_ARGUMENT;
    const connection = raw orelse return c.HSC_INVALID_ARGUMENT;
    const owner = cache orelse return c.HSC_INVALID_ARGUMENT;
    const snapshot = queries.observeCached(convert(*queries.Cache, owner), convert(*terminal.Connection, connection), heap, after, offset) catch |err| return failure(err);
    slot.* = convert(*c.hsc_snapshot, snapshot);
    return c.HSC_OK;
}

/// Copies change-mask, predecessor and row-shift presence without a cache borrow.
pub export fn hsc_snapshot_changes(raw: ?*const c.hsc_snapshot, out: ?*c.hsc_changes) u32 {
    const result = out orelse return c.HSC_INVALID_ARGUMENT;
    result.* = std.mem.zeroes(c.hsc_changes);
    const snapshot = raw orelse return c.HSC_INVALID_ARGUMENT;
    result.* = queries.changes(convert(*const view.Snapshot, snapshot));
    return c.HSC_OK;
}

/// Copies only the exact known mask, preserving all output bytes on shortage.
pub export fn hsc_snapshot_changed_rows(raw: ?*const c.hsc_snapshot, output: ?[*]u8, capacity: usize, required: ?*usize) u32 {
    const count = required orelse return c.HSC_INVALID_ARGUMENT;
    count.* = 0;
    const snapshot = raw orelse return c.HSC_INVALID_ARGUMENT;
    if (capacity != 0 and output == null) return c.HSC_INVALID_ARGUMENT;
    const value = convert(*const view.Snapshot, snapshot);
    const extent = @min(capacity, if (view.changedRows(value)) |rows| rows.len else 0);
    queries.copyChangedRows(value, if (output) |p| p[0..extent] else &.{}, count) catch |err| return failure(err);
    return c.HSC_OK;
}
