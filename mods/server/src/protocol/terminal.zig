//! Server-owned terminal interaction contract over an ordered byte stream.
//!
//! The wire is request-driven. A client has at most one outstanding observation
//! request (`observe`, `observe_raw`, or `observe_delta`). The endpoint answers
//! with one coherent snapshot at a single
//! revision, then the client asks again from that revision. This deliberately
//! avoids a server-side stream queue per observer: slow clients may see a newer
//! snapshot later, but they never pace PTY or VT progress.
//!
//! An endpoint must copy/materialize the requested snapshot before it emits
//! `snapshot_begin`. PTY/VT work may continue while those copied bytes drain to
//! the client. `snapshot_end.revision` closes that exact cut; the client's next
//! observation `after_revision` starts after it. Revision zero always requests an
//! immediate snapshot, which also gives history scrolling a non-waiting path.

const std = @import("std");
const framing = @import("framing.zig");
const codec = @import("howl_vt_codec");

/// Bounded complete terminal-property payload grammar.
pub const properties = codec.properties;

// File map:
//   - wire framing, attach, observation, and request identities
//   - typed input, signals, and coherent interaction state
//   - command results and host-consequence grammar
//   - renderer-complete text snapshots and fixed payload sizes
//   - geometry and consequence authority
//   - typed payload codecs and framing primitives
//   - frozen byte-grammar and ownership proofs

// =============================================================================
// Wire framing, attach, and observation vocabulary
// =============================================================================

/// Shared Server framing version.
pub const framing_version: u8 = framing.version;
/// Shared Server envelope width.
pub const header_bytes: usize = framing.header_bytes;
/// Hard upper bound admitted for one frame payload.
pub const maximum_payload_bytes: u32 = 1024 * 1024;
/// Hard upper bound the node-local endpoint admits for one client request payload.
pub const maximum_request_payload_bytes: u32 = 64 * 1024;
/// Hard upper bound for one encoded or decoded `text_v1` snapshot body.
pub const maximum_text_snapshot_bytes: usize = codec.maximum_text_snapshot_bytes;
/// Server delivery ceiling for one image resource data frame.
pub const image_data_chunk_bytes: usize = 256 * 1024;
/// Sentinel used only where an optional client identity is serialized.
pub const no_client: ClientId = 0;

/// Stable connection-local identity. Zero means no client/leader.
pub const ClientId = u64;

/// Frames carried unchanged over any ordered byte stream, including Unix or TCP sockets.
pub const Kind = enum(u8) {
    observe = 32,
    snapshot_begin = 33,
    snapshot_data = 34,
    snapshot_end = 35,
    input = 36,
    assign_leader = 37,
    resize = 38,
    signal = 39,
    result = 40,
    interaction_state = 41,
    interaction_state_snapshot = 42,
    assign_consequence_leader = 43,
    consequence_observe = 44,
    consequence_begin = 45,
    consequence_data = 46,
    consequence_end = 47,
    consequence_consume = 48,
    consequence_reply = 49,
    text_extract = 50,
    text_extract_data = 51,
    snapshot_graphics = 52,
    image_request = 53,
    image_begin = 54,
    image_data = 55,
    image_end = 56,
    /// Requests the same rich observation with raw text_v1 record bytes.
    observe_raw = 57,
    /// Carries raw bounded text_v1 record bytes for one `observe_raw` response.
    snapshot_raw_data = 58,
    /// Requests a row-delta observation from `after_revision`, with raw fallback.
    observe_delta = 59,
    /// Carries `text_delta_v2`: explicit row shift plus full or reused rows.
    snapshot_delta_data = 60,
    /// Complete live terminal properties belonging to the same snapshot cut.
    snapshot_properties = 61,
    /// Requests complete text_v1 through lossless row-run transport packing.
    observe_packed = 62,
    /// Carries Huffman-zlib compressed text_pack_v1 bytes for one packed response.
    snapshot_packed_data = 63,
};

/// One fixed framing header. Multi-byte integers are big-endian on the wire.
pub const Header = framing.Header(Kind);

/// Rejects malformed framing before any terminal payload is admitted.
pub const HeaderError = framing.Error;

/// Rejects a fixed message payload whose size or enum values are invalid.
pub const PayloadError = error{InvalidPayload};

/// Long-poll style observation request. Revision zero means initial attach.
pub const Observe = struct {
    after_revision: u64 = 0,
    history_offset: u32 = 0,
};

// =============================================================================
// Typed input, signals, and interaction state
// =============================================================================

/// Input payload family for committed bytes and semantic physical input.
pub const InputKind = enum(u8) {
    bytes = 1,
    paste = 2,
    key = 3,
    mouse = 4,
    focus = 5,
};

/// Distinguishes named physical keys from Unicode physical-key identities.
pub const InputKeyKind = enum(u8) {
    named = 1,
    unicode = 2,
};

/// Stable language-neutral names for physical keys with non-Unicode identity.
pub const InputKeyName = enum(u8) {
    enter = 1,
    tab = 2,
    backspace = 3,
    escape = 4,
    up = 5,
    down = 6,
    left = 7,
    right = 8,
    insert = 9,
    delete = 10,
    home = 11,
    end = 12,
    page_up = 13,
    page_down = 14,
    left_shift = 15,
    right_shift = 16,
    left_control = 17,
    right_control = 18,
    left_alt = 19,
    right_alt = 20,
    left_super = 21,
    right_super = 22,
    left_hyper = 23,
    right_hyper = 24,
    left_meta = 25,
    right_meta = 26,
    caps_lock = 27,
    num_lock = 28,
    f1 = 29,
    f2 = 30,
    f3 = 31,
    f4 = 32,
    f5 = 33,
    f6 = 34,
    f7 = 35,
    f8 = 36,
    f9 = 37,
    f10 = 38,
    f11 = 39,
    f12 = 40,
    keypad_0 = 41,
    keypad_1 = 42,
    keypad_2 = 43,
    keypad_3 = 44,
    keypad_4 = 45,
    keypad_5 = 46,
    keypad_6 = 47,
    keypad_7 = 48,
    keypad_8 = 49,
    keypad_9 = 50,
    keypad_decimal = 51,
    keypad_add = 52,
    keypad_subtract = 53,
    keypad_multiply = 54,
    keypad_divide = 55,
    keypad_separator = 56,
    keypad_equal = 57,
    keypad_enter = 58,
};

/// Stable physical-key transition actions.
pub const InputKeyAction = enum(u8) {
    press = 1,
    repeat = 2,
    release = 3,
};

/// Stable semantic mouse button identities.
pub const InputMouseButton = enum(u8) {
    none = 0,
    left = 1,
    middle = 2,
    right = 3,
    wheel_up = 4,
    wheel_down = 5,
};

/// Stable semantic mouse event classes.
pub const InputMouseKind = enum(u8) {
    press = 1,
    release = 2,
    move = 3,
    wheel = 4,
};

/// Stable semantic focus transitions.
pub const InputFocus = enum(u8) {
    in = 1,
    out = 2,
};

/// One borrowed physical-key payload decoded from the typed-input wire grammar.
pub const KeyInput = struct {
    kind: InputKeyKind,
    key_value: u32,
    action: InputKeyAction,
    modifiers: u8 = 0,
    shifted: ?u32 = null,
    alternate: ?u32 = null,
    legacy_text: []const u8 = "",
    text: []const u8 = "",
};

/// One semantic mouse payload decoded from the typed-input wire grammar.
pub const MouseInput = struct {
    kind: InputMouseKind,
    button: InputMouseButton,
    modifiers: u8 = 0,
    buttons_down: u8 = 0,
    row: i32,
    column: u16,
    pixel_x: ?u32 = null,
    pixel_y: ?u32 = null,
};

/// Frozen byte grammar and bounds for typed physical input.
pub const typed_input = struct {
    /// Fixed physical-key header before bounded legacy and committed-text bytes.
    pub const key_header_bytes: usize = 20;
    /// Maximum exact legacy key bytes while retaining canonical Meta prefix room.
    pub const maximum_legacy_key_bytes: u16 = 511;
    /// Maximum committed UTF-8 text carried by one physical key event.
    pub const maximum_key_text_bytes: u8 = 64;
    /// Fixed semantic mouse payload bytes.
    pub const mouse_bytes: usize = 19;
    /// Fixed focus payload bytes.
    pub const focus_bytes: usize = 1;

    /// Modifier bits, independent of any language's packed-struct layout.
    pub const modifiers = struct {
        /// Shift is held.
        pub const shift: u8 = 1 << 0;
        /// Alt/Option is held.
        pub const alt: u8 = 1 << 1;
        /// Control is held.
        pub const control: u8 = 1 << 2;
        /// Super/Command/Windows is held.
        pub const super: u8 = 1 << 3;
        /// Hyper is held.
        pub const hyper: u8 = 1 << 4;
        /// Meta is held.
        pub const meta: u8 = 1 << 5;
        /// Caps Lock is active.
        pub const caps_lock: u8 = 1 << 6;
        /// Num Lock is active.
        pub const num_lock: u8 = 1 << 7;
        /// Mask of every accepted modifier bit.
        pub const known: u8 = shift | alt | control | super | hyper | meta |
            caps_lock | num_lock;
    };

    /// Optional physical-key scalar fields.
    pub const key_presence = struct {
        /// Shift-produced Unicode identity is present.
        pub const shifted: u8 = 1 << 0;
        /// Alternate-layout Unicode identity is present.
        pub const alternate: u8 = 1 << 1;
        /// Mask of every accepted key-presence bit.
        pub const known: u8 = shifted | alternate;
    };

    /// Optional mouse coordinate fields.
    pub const mouse_presence = struct {
        /// Both pixel coordinates are present.
        pub const pixels: u8 = 1 << 0;
        /// Mask of every accepted mouse-presence bit.
        pub const known: u8 = pixels;
    };
};

/// Signals accepted by the Instance process-group boundary.
pub const Signal = enum(u8) {
    hangup = 1,
    interrupt = 2,
    resize_notify = 3,
    kill = 9,
    terminate = 15,
};

/// Frozen mouse-event selection retained by one interaction-state snapshot.
pub const InteractionMouseTracking = enum(u8) {
    off = 0,
    x10 = 1,
    normal = 2,
    button_event = 3,
    any_event = 4,
};

/// Frozen mouse-report encoding retained by one interaction-state snapshot.
pub const InteractionMouseProtocol = enum(u8) {
    none = 0,
    utf8 = 1,
    sgr = 2,
    sgr_pixel = 3,
    urxvt = 4,
};

/// Coherent mode-directed caller interaction state at one terminal revision.
pub const InteractionStateSnapshot = struct {
    terminal_revision: u64,
    keyboard_action_mode: bool,
    auto_repeat: bool,
    newline_mode: bool,
    application_cursor_keys: bool,
    application_keypad: bool,
    meta_sends_escape: bool,
    report_key_up: bool,
    bracketed_paste: bool,
    focus_reporting: bool,
    termios_signals: bool,
    alternate_scroll: bool,
    paste_events: bool,
    inband_resize_notifications: bool,
    mouse_tracking: InteractionMouseTracking,
    mouse_protocol: InteractionMouseProtocol,
    modify_other_keys: i8,
    kitty_keyboard_flags: u8,
    key_format_resource_4: u16,
    pointer_mode: u2,
};

/// Bit positions in the fixed interaction-state flags word.
pub const interaction_state_flags = struct {
    /// Keyboard action mode suppresses ordinary key encoding.
    pub const keyboard_action_mode: u32 = 1 << 0;
    /// Physical key repeat transitions are currently admitted.
    pub const auto_repeat: u32 = 1 << 1;
    /// Enter uses CRLF rather than CR when legacy encoding applies.
    pub const newline_mode: u32 = 1 << 2;
    /// Cursor keys use application-cursor encoding.
    pub const application_cursor_keys: u32 = 1 << 3;
    /// Keypad keys use application-keypad encoding.
    pub const application_keypad: u32 = 1 << 4;
    /// Alt-modified legacy bytes receive an Escape prefix.
    pub const meta_sends_escape: u32 = 1 << 5;
    /// Legacy key-release reporting is enabled.
    pub const report_key_up: u32 = 1 << 6;
    /// Semantic paste is wrapped in bracketed-paste delimiters.
    pub const bracketed_paste: u32 = 1 << 7;
    /// Focus in/out input is reported to the child.
    pub const focus_reporting: u32 = 1 << 8;
    /// Matching control bytes may be delivered as foreground termios signals.
    pub const termios_signals: u32 = 1 << 9;
    /// Alternate-screen wheel input uses alternate-scroll behavior.
    pub const alternate_scroll: u32 = 1 << 10;
    /// Kitty paste-event exchange is enabled.
    pub const paste_events: u32 = 1 << 11;
    /// Resize commits generate in-band terminal resize notification bytes.
    pub const inband_resize_notifications: u32 = 1 << 12;
    /// Mask of every defined interaction-state flag bit.
    pub const known: u32 = (1 << 13) - 1;
};

// =============================================================================
// Command results and host-consequence grammar
// =============================================================================

/// Bounded request outcome without transporting host-specific errno values.
pub const ResultCode = enum(u8) {
    ok = 0,
    malformed = 1,
    unsupported = 2,
    no_such_client = 3,
    not_leader = 4,
    rejected = 5,
};

/// Correlates one command response by its request kind.
pub const Result = struct {
    request_kind: Kind,
    code: ResultCode,
};

/// Maximum exact raw payload retained by one host consequence snapshot.
pub const maximum_consequence_payload_bytes: u32 = 1024 * 1024;
/// Consequence raw data is segmented so one large VT payload never approaches the frame ceiling.
pub const consequence_data_chunk_bytes: usize = 64 * 1024;
/// Fixed bytes reserved for consequence-kind metadata in `consequence_begin`.
pub const consequence_metadata_bytes: usize = 32;
/// Maximum exact OSC 52 selection bytes copied into consequence metadata.
pub const consequence_clipboard_selection_bytes: usize = 12;
/// Maximum payload for notification, pointer, and generic string consequences.
pub const consequence_small_payload_bytes: u32 = 1024;
/// Maximum retained Kitty/file-transfer packet payload.
pub const consequence_packet_payload_bytes: u32 = 8 * 1024;
/// Maximum retained Kitty drag/drop packet payload.
pub const consequence_drag_drop_payload_bytes: u32 = 4 * 1024;
/// Maximum retained delegated DCS payload.
pub const consequence_dcs_payload_bytes: u32 = 2 * 1024;

/// Stable host-consequence family carried by one consequence snapshot.
pub const ConsequenceKind = enum(u8) {
    none = 0,
    clipboard = 1,
    notification = 2,
    pointer_shape = 3,
    file_transfer = 4,
    drag_drop = 5,
    container = 6,
    color_preference = 7,
    media_copy = 8,
    bell = 9,
    legacy_control = 10,
    dcs = 11,
    string_control = 12,
};

/// Stable clipboard operation class in consequence metadata.
pub const ConsequenceClipboardKind = enum(u8) { set = 1, query = 2, packet = 3 };
/// Stable clipboard framing family in consequence metadata.
pub const ConsequenceClipboardProtocol = enum(u8) { osc52 = 1, kitty_5522 = 2 };
/// Stable notification operation class in consequence metadata.
pub const ConsequenceNotificationKind = enum(u8) { message = 1, steal_focus = 2, request_attention = 3 };
/// Stable file-transfer framing family in consequence metadata.
pub const ConsequenceFileTransferProtocol = enum(u8) { iterm2_1337 = 1, kitty_5113 = 2 };
/// Stable incoming Kitty drag/drop command class in consequence metadata.
pub const ConsequenceDragDropKind = enum(u8) {
    enable = 1,
    disable = 2,
    accept = 3,
    request = 4,
    complete = 5,
    query = 6,
    continuation = 7,
    unsupported = 8,
};
/// Stable container/window request class in consequence metadata.
pub const ConsequenceContainerKind = enum(u8) {
    deiconify = 1,
    iconify = 2,
    move = 3,
    resize_pixels = 4,
    raise = 5,
    lower = 6,
    resize_rows = 7,
    resize_columns = 8,
    resize_cells = 9,
    report_state = 10,
    report_position = 11,
    report_screen_cells = 12,
    report_icon_title = 13,
};
/// Stable legacy terminal-control class in consequence metadata.
pub const ConsequenceLegacyControlKind = enum(u8) {
    tek_point_plot = 1,
    tek_graph = 2,
    tek_incremental_plot = 3,
    tek_alpha = 4,
    tek_copy = 5,
    tek_special_point_plot = 6,
    tek_write_thru_short_dashed = 7,
    hp_memory_lock = 8,
};
/// Stable caller-directed DCS family in consequence metadata.
pub const ConsequenceDcsKind = enum(u8) {
    xtsettcap = 1,
    decudk = 2,
    decaupss = 3,
    iterm_tmux_hook = 4,
    iterm_ssh_hook = 5,
    iterm_tmux_wrap = 6,
    kitty_remote_command = 7,
    kitty_overlay_ready = 8,
    kitty_result = 9,
    kitty_print = 10,
    kitty_echo = 11,
    kitty_ssh = 12,
    kitty_askpass = 13,
    kitty_clone = 14,
    kitty_edit = 15,
};
/// Stable generic string-control family in consequence metadata.
pub const ConsequenceStringKind = enum(u8) { apc = 1, pm = 2, sos = 3 };

/// Fixed identity and kind metadata opening one host-consequence snapshot.
pub const ConsequenceBegin = struct {
    terminal_revision: u64,
    authority_client_id: ClientId,
    generation: u64,
    payload_len: u32,
    kind: ConsequenceKind,
    reply_required: bool,
    metadata: [consequence_metadata_bytes]u8,
};

/// Reply operation accepted only from the current consequence authority.
pub const ConsequenceReplyKind = enum(u8) {
    clipboard = 1,
    pointer_shape = 2,
    color_preference = 3,
    container_state = 4,
    container_position = 5,
    container_screen_cells = 6,
    container_icon_title = 7,
    container_decline = 8,
};

/// Borrowed, validated consequence reply request body.
pub const ConsequenceReply = struct {
    generation: u64,
    kind: ConsequenceReplyKind,
    body: []const u8,
};

// =============================================================================
// Renderer-complete text snapshot grammar
// =============================================================================

/// Record classes carried inside the compressed renderer-complete snapshot body.
///
/// There is deliberately one complete terminal-text representation: `text_v1`.
/// Ordinary observations wrap it in bounded zlib/DEFLATE; complete-raw
/// observations carry the same records directly. Revision-relative
/// `text_delta_v2` is a separate framing-v7 transport and never masquerades as
/// a standalone `text_v1` body.
/// Every decompressed record starts with one fixed eight-byte header so clients
/// can validate the body without depending on Zig struct layout.
/// VT-owned semantic payload vocabulary.
pub const TextRecordKind = codec.TextRecordKind;
/// VT-owned semantic payload vocabulary.
pub const TextRecordHeader = codec.TextRecordHeader;
/// VT-owned semantic payload vocabulary.
pub const TextColorKind = codec.TextColorKind;
/// VT-owned semantic payload vocabulary.
pub const TextColor = codec.TextColor;
/// VT-owned semantic payload vocabulary.
pub const text_v1 = codec.text_v1;
/// VT-owned semantic payload vocabulary.
pub const text_delta_v2 = codec.text_delta_v2;
/// VT-owned semantic payload vocabulary.
pub const text_pack_v1 = codec.text_pack_v1;
/// VT-owned semantic payload vocabulary.
pub const graphics_v2 = codec.graphics_v2;
/// VT-owned semantic payload vocabulary.
pub const SnapshotGraphicsHeader = codec.SnapshotGraphicsHeader;
/// VT-owned semantic payload vocabulary.
pub const SnapshotImage = codec.SnapshotImage;
/// VT-owned semantic payload vocabulary.
pub const SnapshotImagePlacement = codec.SnapshotImagePlacement;

comptime {
    if (graphics_v2.maximum_manifest_bytes > maximum_payload_bytes)
        @compileError("graphics manifest exceeds one frame payload");
    if (image_data_chunk_bytes == 0 or image_data_chunk_bytes > maximum_payload_bytes)
        @compileError("graphics image chunk exceeds one frame payload");
}

/// Requests one exact immutable image generation named by a snapshot manifest.
pub const ImageRequest = struct {
    image_id: u32,
    generation: u64,
};

/// Starts one exact RGBA8 image resource response.
pub const ImageBegin = struct {
    image_id: u32,
    generation: u64,
    width: u32,
    height: u32,
    byte_count: u32,
};

/// Closes one exact RGBA8 image resource response.
pub const ImageEnd = struct {
    image_id: u32,
    generation: u64,
};

// =============================================================================
// Snapshot lifecycle and fixed payload sizes
// =============================================================================

/// Starts one coherent snapshot. All following data/end frames share revision.
pub const SnapshotBegin = struct {
    /// Endpoint observation revision covering VT, lifecycle, and authority state.
    revision: u64,
    /// Terminal-only facts owned and encoded by the optional VT codec.
    terminal: codec.Metadata,
    stream_closed: bool,
    child_exited: bool,
    leader_present: bool,
    you_are_leader: bool,
};

/// Completes one snapshot and makes its revision valid for the next observe.
pub const SnapshotEnd = struct {
    revision: u64,
};

/// Explicit geometry request. The endpoint accepts it only from the leader.
pub const Resize = struct {
    rows: u16,
    columns: u16,
    /// Zero pair preserves the accepted lattice; nonzero pair supplies exact
    /// pixels per cell. Mixed zero/nonzero is malformed.
    cell_pixel_width: u16 = 0,
    cell_pixel_height: u16 = 0,
};

/// Stable projected terminal cell used by bounded selected-text extraction.
pub const TextPoint = struct {
    row: i32,
    column: u16,
};

/// Inclusive selected-text extraction range. Selection state itself remains client-local.
pub const TextExtract = struct {
    start: TextPoint,
    end: TextPoint,
    columns: u16,
    alternate_screen: bool,
};

/// Explicit leader assignment. `no_client` clears leadership.
pub const AssignLeader = struct {
    client_id: ClientId,
};

/// Exact fixed payload widths for v1 messages.
pub const payload_bytes = struct {
    /// `Observe` payload bytes.
    pub const observe: usize = 12;
    /// `SnapshotBegin` payload bytes.
    pub const snapshot_begin: usize = 8 + codec.metadata.bytes;
    /// `SnapshotEnd` payload bytes.
    pub const snapshot_end: usize = 8;
    /// `AssignLeader` payload bytes.
    pub const assign_leader: usize = 8;
    /// `Resize` payload bytes.
    pub const resize: usize = 8;
    /// `Signal` payload bytes.
    pub const signal: usize = 1;
    /// `Result` payload bytes.
    pub const result: usize = 2;
    /// `interaction_state` request payload bytes.
    pub const interaction_state: usize = 0;
    /// `interaction_state_snapshot` payload bytes.
    pub const interaction_state_snapshot: usize = 20;
    /// `assign_consequence_leader` payload bytes; identical to resize leadership assignment.
    pub const assign_consequence_leader: usize = 8;
    /// `consequence_observe` request payload bytes.
    pub const consequence_observe: usize = 0;
    /// Fixed `consequence_begin` payload bytes.
    pub const consequence_begin: usize = 64;
    /// `consequence_end` payload bytes.
    pub const consequence_end: usize = 8;
    /// `consequence_consume` payload bytes.
    pub const consequence_consume: usize = 8;
    /// Fixed header bytes before one typed consequence-reply body.
    pub const consequence_reply_header: usize = 12;
    /// Two stable points plus expected columns and screen-bank identity.
    pub const text_extract: usize = 16;
    /// Exact image resource request identity.
    pub const image_request: usize = 12;
    /// Fixed image resource response prefix.
    pub const image_begin: usize = 24;
    /// Exact image resource response suffix.
    pub const image_end: usize = 12;
};

/// Maximum `snapshot_data` frame count under the frozen 4 MiB text-body bound.
pub const maximum_snapshot_data_frames: usize = std.math.divCeil(
    usize,
    maximum_text_snapshot_bytes,
    @as(usize, maximum_payload_bytes),
    // zig-audit: acknowledge catch_unreachable
    // reason: This compile-time frame count divides the fixed 4 MiB bound by a nonzero fixed payload limit; both constants fit usize.
) catch unreachable;

/// Hard upper bound for one complete v10 observation response.
///
/// This includes the bounded text transport body, all possible compressed,
/// raw, delta, or packed data-frame headers, one complete `graphics_v2` manifest, one
/// bounded `properties_v1` packet, and the begin/end envelopes.
/// Demand-fetched RGBA image resources are separate transactions and do not
/// consume this budget.
pub const maximum_observation_bytes: usize =
    header_bytes + payload_bytes.snapshot_begin +
    maximum_snapshot_data_frames * header_bytes + maximum_text_snapshot_bytes +
    header_bytes + graphics_v2.maximum_manifest_bytes +
    header_bytes + properties.maximum_bytes +
    header_bytes + payload_bytes.snapshot_end;

// =============================================================================
// Geometry and host-consequence authority
// =============================================================================

/// Owns only geometry authority. Client discovery/rosters remain endpoint policy.
pub const ResizeAuthority = struct {
    leader_client_id: ClientId = no_client,
    revision: u64 = 1,

    /// Returns the current leader, if explicit geometry authority exists.
    pub fn leader(self: ResizeAuthority) ?ClientId {
        return if (self.leader_client_id == no_client) null else self.leader_client_id;
    }

    /// Replaces or clears the leader and reports whether authority changed.
    pub fn assign(self: *ResizeAuthority, client_id: ClientId) bool {
        if (self.leader_client_id == client_id) return false;
        self.leader_client_id = client_id;
        advance(&self.revision);
        return true;
    }

    /// Clears leadership only when the disconnected client currently owns it.
    pub fn disconnected(self: *ResizeAuthority, client_id: ClientId) bool {
        if (client_id == no_client or self.leader_client_id != client_id) return false;
        self.leader_client_id = no_client;
        advance(&self.revision);
        return true;
    }

    /// Reports whether one attached client may mutate canonical geometry.
    pub fn mayResize(self: ResizeAuthority, client_id: ClientId) bool {
        return client_id != no_client and self.leader_client_id == client_id;
    }
};

/// Tracks one explicitly assigned host-consequence authority connection.
pub const ConsequenceAuthority = struct {
    leader_client_id: ClientId = no_client,
    revision: u64 = 1,

    /// Returns the current consequence authority, when explicitly assigned.
    pub fn leader(self: ConsequenceAuthority) ?ClientId {
        return if (self.leader_client_id == no_client) null else self.leader_client_id;
    }

    /// Replaces or clears authority and reports whether ownership changed.
    pub fn assign(self: *ConsequenceAuthority, client_id: ClientId) bool {
        if (self.leader_client_id == client_id) return false;
        self.leader_client_id = client_id;
        advance(&self.revision);
        return true;
    }

    /// Clears authority only when the disconnected connection owns it.
    pub fn disconnected(self: *ConsequenceAuthority, client_id: ClientId) bool {
        if (client_id == no_client or self.leader_client_id != client_id) return false;
        self.leader_client_id = no_client;
        advance(&self.revision);
        return true;
    }

    /// Reports whether one connection may consume or reply to host consequences.
    pub fn mayHandle(self: ConsequenceAuthority, client_id: ClientId) bool {
        return client_id != no_client and self.leader_client_id == client_id;
    }
};

// =============================================================================
// Typed payload codecs
// =============================================================================

// -- Attach, observation, and rich snapshot codecs ---------------------------

/// Encodes one observation request.
pub fn encodeObserve(output: *[payload_bytes.observe]u8, value: Observe) void {
    writeU64(output[0..8], value.after_revision);
    writeU32(output[8..12], value.history_offset);
}

/// Decodes one exact observation request.
pub fn decodeObserve(input: []const u8) PayloadError!Observe {
    if (input.len != payload_bytes.observe) return error.InvalidPayload;
    return .{
        .after_revision = readU64(input[0..8]),
        .history_offset = readU32(input[8..12]),
    };
}

/// Encodes one snapshot metadata boundary.
pub fn encodeSnapshotBegin(output: *[payload_bytes.snapshot_begin]u8, value: SnapshotBegin) void {
    output.* = @splat(0);
    writeU64(output[0..8], value.revision);
    codec.metadata.encode(output[8..38], value.terminal);
    output[37] |= (@as(u8, @intFromBool(value.stream_closed)) << 3) |
        (@as(u8, @intFromBool(value.child_exited)) << 4) |
        (@as(u8, @intFromBool(value.leader_present)) << 5) |
        (@as(u8, @intFromBool(value.you_are_leader)) << 6);
}

/// Decodes one exact snapshot metadata boundary.
pub fn decodeSnapshotBegin(input: []const u8) PayloadError!SnapshotBegin {
    if (input.len != payload_bytes.snapshot_begin) return error.InvalidPayload;
    if (input[37] & 0x80 != 0) return error.InvalidPayload;
    // The legacy envelope shares its last byte with terminal flags. Strip only
    // Server-owned bits before delegating the exact terminal metadata grammar.
    var terminal_bytes: [codec.metadata.bytes]u8 = undefined;
    @memcpy(&terminal_bytes, input[8..38]);
    terminal_bytes[29] &= codec.metadata.flags_mask;
    return .{
        .revision = readU64(input[0..8]),
        .terminal = try codec.metadata.decode(&terminal_bytes),
        .stream_closed = input[37] & (1 << 3) != 0,
        .child_exited = input[37] & (1 << 4) != 0,
        .leader_present = input[37] & (1 << 5) != 0,
        .you_are_leader = input[37] & (1 << 6) != 0,
    };
}

/// Payload validation/packing is owned by the optional VT codec.
pub const TextPackError = codec.TextPackError;
/// Encodes one self-delimiting `text_v1` record header.
pub const encodeTextRecordHeader = codec.encodeTextRecordHeader;
/// Decodes one `text_v1` record header and rejects every reserved bit.
pub const decodeTextRecordHeader = codec.decodeTextRecordHeader;
/// Packs one complete frozen `text_v1` body without changing its semantics.
/// Rows use consecutive exact attribute runs only when that representation is
/// smaller; otherwise the original row payload is carried verbatim.
pub const packTextV1 = codec.packTextV1;
/// Reconstructs the exact frozen `text_v1` body from `text_pack_v1` carriage.
/// The caller supplies the exact expected original byte count from the transport
/// envelope; hostile input cannot grow beyond that bound.
pub const unpackTextV1 = codec.unpackTextV1;
/// Encodes the explicit framing-v7 delta baseline rotation.
pub const encodeTextRowShift = codec.encodeTextRowShift;
/// Decodes the exact two-byte framing-v7 delta baseline rotation.
pub const decodeTextRowShift = codec.decodeTextRowShift;
/// Encodes one semantic `text_v1` terminal color.
pub const encodeTextColor = codec.encodeTextColor;
/// Decodes and validates one semantic `text_v1` terminal color.
pub const decodeTextColor = codec.decodeTextColor;
/// Encodes the fixed prefix of one snapshot graphics manifest.
pub const encodeSnapshotGraphicsHeader = codec.encodeSnapshotGraphicsHeader;
/// Decodes the fixed prefix of one bounded snapshot graphics manifest.
pub const decodeSnapshotGraphicsHeader = codec.decodeSnapshotGraphicsHeader;
/// Encodes one visible image resource descriptor.
pub const encodeSnapshotImage = codec.encodeSnapshotImage;
/// Decodes one visible image resource descriptor.
pub const decodeSnapshotImage = codec.decodeSnapshotImage;
/// Encodes one image placement resolved into the snapshot viewport.
pub const encodeSnapshotImagePlacement = codec.encodeSnapshotImagePlacement;
/// Decodes one image placement resolved into the snapshot viewport.
pub const decodeSnapshotImagePlacement = codec.decodeSnapshotImagePlacement;

/// Encodes one exact image resource request.
pub fn encodeImageRequest(output: *[payload_bytes.image_request]u8, value: ImageRequest) void {
    std.debug.assert(value.image_id != 0 and value.generation != 0);
    writeU32(output[0..4], value.image_id);
    writeU64(output[4..12], value.generation);
}

/// Decodes one exact image resource request.
pub fn decodeImageRequest(input: []const u8) PayloadError!ImageRequest {
    if (input.len != payload_bytes.image_request) return error.InvalidPayload;
    const value = ImageRequest{
        .image_id = readU32(input[0..4]),
        .generation = readU64(input[4..12]),
    };
    if (value.image_id == 0 or value.generation == 0) return error.InvalidPayload;
    return value;
}

/// Encodes one exact RGBA8 image response prefix.
pub fn encodeImageBegin(output: *[payload_bytes.image_begin]u8, value: ImageBegin) void {
    std.debug.assert(validImageExtent(value.image_id, value.generation, value.width, value.height));
    std.debug.assert(value.byte_count == imageByteCount(value.width, value.height).?);
    writeU32(output[0..4], value.image_id);
    writeU64(output[4..12], value.generation);
    writeU32(output[12..16], value.width);
    writeU32(output[16..20], value.height);
    writeU32(output[20..24], value.byte_count);
}

/// Decodes one exact RGBA8 image response prefix.
pub fn decodeImageBegin(input: []const u8) PayloadError!ImageBegin {
    if (input.len != payload_bytes.image_begin) return error.InvalidPayload;
    const value = ImageBegin{
        .image_id = readU32(input[0..4]),
        .generation = readU64(input[4..12]),
        .width = readU32(input[12..16]),
        .height = readU32(input[16..20]),
        .byte_count = readU32(input[20..24]),
    };
    if (!validImageExtent(value.image_id, value.generation, value.width, value.height) or
        imageByteCount(value.width, value.height) != value.byte_count)
        return error.InvalidPayload;
    return value;
}

/// Encodes the exact identity closing one RGBA8 image response.
pub fn encodeImageEnd(output: *[payload_bytes.image_end]u8, value: ImageEnd) void {
    std.debug.assert(value.image_id != 0 and value.generation != 0);
    writeU32(output[0..4], value.image_id);
    writeU64(output[4..12], value.generation);
}

/// Decodes the exact identity closing one RGBA8 image response.
pub fn decodeImageEnd(input: []const u8) PayloadError!ImageEnd {
    if (input.len != payload_bytes.image_end) return error.InvalidPayload;
    const value = ImageEnd{
        .image_id = readU32(input[0..4]),
        .generation = readU64(input[4..12]),
    };
    if (value.image_id == 0 or value.generation == 0) return error.InvalidPayload;
    return value;
}

fn validImageExtent(image_id: u32, generation: u64, width: u32, height: u32) bool {
    return image_id != 0 and generation != 0 and width != 0 and height != 0 and
        width <= graphics_v2.maximum_dimension and height <= graphics_v2.maximum_dimension and
        imageByteCount(width, height) != null;
}

fn imageByteCount(width: u32, height: u32) ?u32 {
    const pixels = std.math.mul(u64, width, height) catch return null;
    const bytes = std.math.mul(u64, pixels, 4) catch return null;
    if (bytes == 0 or bytes > graphics_v2.maximum_image_bytes or bytes > std.math.maxInt(u32))
        return null;
    return @intCast(bytes);
}

// -- Typed input codecs -------------------------------------------------------

/// Reports malformed typed input or insufficient caller-provided encode storage.
pub const InputEncodeError = PayloadError || error{OutputTooSmall};

/// Returns the exact typed-key body bytes after validating its canonical form.
pub fn keyInputBytes(value: KeyInput) PayloadError!usize {
    try validateKeyInput(value);
    return typed_input.key_header_bytes + value.legacy_text.len + value.text.len;
}

/// Encodes one physical-key body after the outer `InputKind.key` byte.
pub fn encodeKeyInput(output: []u8, value: KeyInput) InputEncodeError![]const u8 {
    const needed = try keyInputBytes(value);
    if (output.len < needed) return error.OutputTooSmall;
    const encoded = output[0..needed];
    @memset(encoded[0..typed_input.key_header_bytes], 0);
    encoded[0] = @backingInt(value.kind);
    encoded[1] = @backingInt(value.action);
    encoded[2] = value.modifiers;
    encoded[3] = (@as(u8, @intFromBool(value.shifted != null)) * typed_input.key_presence.shifted) |
        (@as(u8, @intFromBool(value.alternate != null)) * typed_input.key_presence.alternate);
    writeU32(encoded[4..8], value.key_value);
    writeU32(encoded[8..12], value.shifted orelse 0);
    writeU32(encoded[12..16], value.alternate orelse 0);
    writeU16(encoded[16..18], @intCast(value.legacy_text.len));
    writeU16(encoded[18..20], @intCast(value.text.len));
    @memcpy(encoded[20 .. 20 + value.legacy_text.len], value.legacy_text);
    @memcpy(encoded[20 + value.legacy_text.len ..], value.text);
    return encoded;
}

/// Decodes one exact physical-key body and borrows its trailing text slices.
pub fn decodeKeyInput(input: []const u8) PayloadError!KeyInput {
    if (input.len < typed_input.key_header_bytes) return error.InvalidPayload;
    const presence = input[3];
    if (presence & ~typed_input.key_presence.known != 0) return error.InvalidPayload;
    const legacy_len = readU16(input[16..18]);
    const text_len = readU16(input[18..20]);
    if (legacy_len > typed_input.maximum_legacy_key_bytes or
        text_len > typed_input.maximum_key_text_bytes)
        return error.InvalidPayload;
    const expected = std.math.add(
        usize,
        typed_input.key_header_bytes,
        @as(usize, legacy_len) + text_len,
    ) catch return error.InvalidPayload;
    if (input.len != expected) return error.InvalidPayload;
    const shifted_raw = readU32(input[8..12]);
    const alternate_raw = readU32(input[12..16]);
    const value = KeyInput{
        .kind = enumFromInt(InputKeyKind, input[0]) orelse return error.InvalidPayload,
        .action = enumFromInt(InputKeyAction, input[1]) orelse return error.InvalidPayload,
        .modifiers = input[2],
        .key_value = readU32(input[4..8]),
        .shifted = if (presence & typed_input.key_presence.shifted != 0)
            shifted_raw
        else if (shifted_raw == 0)
            null
        else
            return error.InvalidPayload,
        .alternate = if (presence & typed_input.key_presence.alternate != 0)
            alternate_raw
        else if (alternate_raw == 0)
            null
        else
            return error.InvalidPayload,
        .legacy_text = input[20 .. 20 + legacy_len],
        .text = input[20 + legacy_len ..],
    };
    try validateKeyInput(value);
    return value;
}

/// Encodes one semantic mouse body after the outer `InputKind.mouse` byte.
pub fn encodeMouseInput(
    output: *[typed_input.mouse_bytes]u8,
    value: MouseInput,
) PayloadError!void {
    try validateMouseInput(value);
    output.* = @splat(0);
    output[0] = @backingInt(value.kind);
    output[1] = @backingInt(value.button);
    output[2] = value.modifiers;
    output[3] = value.buttons_down;
    writeI32(output[4..8], value.row);
    writeU16(output[8..10], value.column);
    if (value.pixel_x != null) output[10] = typed_input.mouse_presence.pixels;
    writeU32(output[11..15], value.pixel_x orelse 0);
    writeU32(output[15..19], value.pixel_y orelse 0);
}

/// Decodes one exact semantic mouse body.
pub fn decodeMouseInput(input: []const u8) PayloadError!MouseInput {
    if (input.len != typed_input.mouse_bytes or
        input[10] & ~typed_input.mouse_presence.known != 0)
        return error.InvalidPayload;
    const pixels_present = input[10] & typed_input.mouse_presence.pixels != 0;
    const pixel_x = readU32(input[11..15]);
    const pixel_y = readU32(input[15..19]);
    if (!pixels_present and (pixel_x != 0 or pixel_y != 0))
        return error.InvalidPayload;
    const value = MouseInput{
        .kind = enumFromInt(InputMouseKind, input[0]) orelse return error.InvalidPayload,
        .button = enumFromInt(InputMouseButton, input[1]) orelse return error.InvalidPayload,
        .modifiers = input[2],
        .buttons_down = input[3],
        .row = readI32(input[4..8]),
        .column = readU16(input[8..10]),
        .pixel_x = if (pixels_present) pixel_x else null,
        .pixel_y = if (pixels_present) pixel_y else null,
    };
    try validateMouseInput(value);
    return value;
}

/// Encodes one semantic focus body after the outer `InputKind.focus` byte.
pub fn encodeFocusInput(output: *[typed_input.focus_bytes]u8, value: InputFocus) void {
    output[0] = @backingInt(value);
}

/// Decodes one exact semantic focus body.
pub fn decodeFocusInput(input: []const u8) PayloadError!InputFocus {
    if (input.len != typed_input.focus_bytes) return error.InvalidPayload;
    return enumFromInt(InputFocus, input[0]) orelse error.InvalidPayload;
}

fn validateKeyInput(value: KeyInput) PayloadError!void {
    switch (value.kind) {
        .named => {
            const wire_name = std.math.cast(u8, value.key_value) orelse
                return error.InvalidPayload;
            if (enumFromInt(InputKeyName, wire_name) == null) return error.InvalidPayload;
        },
        .unicode => try validateScalar(value.key_value),
    }
    if (value.shifted) |scalar| try validateScalar(scalar);
    if (value.alternate) |scalar| try validateScalar(scalar);
    if (value.legacy_text.len > typed_input.maximum_legacy_key_bytes or
        value.text.len > typed_input.maximum_key_text_bytes or
        !std.unicode.utf8ValidateSlice(value.text))
        return error.InvalidPayload;
}

fn validateMouseInput(value: MouseInput) PayloadError!void {
    if (value.buttons_down & ~@as(u8, 0b111) != 0) return error.InvalidPayload;
    if ((value.pixel_x == null) != (value.pixel_y == null)) return error.InvalidPayload;
}

fn validateScalar(value: u32) PayloadError!void {
    if (value > 0x10ffff or value >= 0xd800 and value <= 0xdfff)
        return error.InvalidPayload;
}

// -- Instance control codecs ---------------------------------------------------

/// Encodes one completed snapshot revision.
pub fn encodeSnapshotEnd(output: *[payload_bytes.snapshot_end]u8, value: SnapshotEnd) void {
    writeU64(output, value.revision);
}

/// Decodes one completed snapshot revision.
pub fn decodeSnapshotEnd(input: []const u8) PayloadError!SnapshotEnd {
    if (input.len != payload_bytes.snapshot_end) return error.InvalidPayload;
    return .{ .revision = readU64(input) };
}

/// Encodes one explicit geometry-leader assignment.
pub fn encodeAssignLeader(output: *[payload_bytes.assign_leader]u8, value: AssignLeader) void {
    writeU64(output, value.client_id);
}

/// Decodes one explicit geometry-leader assignment.
pub fn decodeAssignLeader(input: []const u8) PayloadError!AssignLeader {
    if (input.len != payload_bytes.assign_leader) return error.InvalidPayload;
    return .{ .client_id = readU64(input) };
}

/// Encodes one explicit canonical geometry.
pub fn encodeResize(output: *[payload_bytes.resize]u8, value: Resize) void {
    writeU16(output[0..2], value.rows);
    writeU16(output[2..4], value.columns);
    writeU16(output[4..6], value.cell_pixel_width);
    writeU16(output[6..8], value.cell_pixel_height);
}

/// Decodes one explicit canonical geometry.
pub fn decodeResize(input: []const u8) PayloadError!Resize {
    if (input.len != payload_bytes.resize) return error.InvalidPayload;
    const width = readU16(input[4..6]);
    const height = readU16(input[6..8]);
    if ((width == 0) != (height == 0)) return error.InvalidPayload;
    return .{ .rows = readU16(input[0..2]), .columns = readU16(input[2..4]), .cell_pixel_width = width, .cell_pixel_height = height };
}

/// Encodes one fixed process-group signal.
pub fn encodeSignal(output: *[payload_bytes.signal]u8, value: Signal) void {
    output[0] = @backingInt(value);
}

/// Decodes one fixed process-group signal.
pub fn decodeSignal(input: []const u8) PayloadError!Signal {
    if (input.len != payload_bytes.signal) return error.InvalidPayload;
    return enumFromInt(Signal, input[0]) orelse error.InvalidPayload;
}

/// Encodes one inclusive stable projected terminal-text extraction range.
pub fn encodeTextExtract(output: *[payload_bytes.text_extract]u8, value: TextExtract) void {
    writeI32(output[0..4], value.start.row);
    writeU16(output[4..6], value.start.column);
    writeI32(output[6..10], value.end.row);
    writeU16(output[10..12], value.end.column);
    writeU16(output[12..14], value.columns);
    output[14] = @intFromBool(value.alternate_screen);
    output[15] = 0;
}

/// Decodes one inclusive stable projected terminal-text extraction range.
pub fn decodeTextExtract(input: []const u8) PayloadError!TextExtract {
    if (input.len != payload_bytes.text_extract) return error.InvalidPayload;
    if (input[14] > 1 or input[15] != 0) return error.InvalidPayload;
    const columns = readU16(input[12..14]);
    if (columns == 0) return error.InvalidPayload;
    return .{
        .start = .{ .row = readI32(input[0..4]), .column = readU16(input[4..6]) },
        .end = .{ .row = readI32(input[6..10]), .column = readU16(input[10..12]) },
        .columns = columns,
        .alternate_screen = input[14] == 1,
    };
}

// -- Host-consequence codecs -------------------------------------------------

/// Encodes one exact host-consequence occurrence identity.
pub fn encodeConsequenceIdentity(output: *[payload_bytes.consequence_consume]u8, generation: u64) void {
    writeU64(output, generation);
}

/// Decodes one exact host-consequence occurrence identity.
pub fn decodeConsequenceIdentity(input: []const u8) PayloadError!u64 {
    if (input.len != payload_bytes.consequence_consume) return error.InvalidPayload;
    return readU64(input);
}

/// Encodes one fixed host-consequence snapshot begin payload.
pub fn encodeConsequenceBegin(
    output: *[payload_bytes.consequence_begin]u8,
    value: ConsequenceBegin,
) PayloadError!void {
    if (value.payload_len > maximum_consequence_payload_bytes) return error.InvalidPayload;
    try validateConsequenceMetadata(
        value.kind,
        value.generation,
        value.payload_len,
        value.reply_required,
        &value.metadata,
    );
    output.* = @splat(0);
    writeU64(output[0..8], value.terminal_revision);
    writeU64(output[8..16], value.authority_client_id);
    writeU64(output[16..24], value.generation);
    writeU32(output[24..28], value.payload_len);
    output[28] = @backingInt(value.kind);
    output[29] = @intFromBool(value.reply_required);
    @memcpy(output[32..64], &value.metadata);
}

/// Decodes and validates one fixed host-consequence snapshot begin payload.
pub fn decodeConsequenceBegin(input: []const u8) PayloadError!ConsequenceBegin {
    if (input.len != payload_bytes.consequence_begin or
        input[29] > 1 or input[30] != 0 or input[31] != 0)
        return error.InvalidPayload;
    const kind = enumFromInt(ConsequenceKind, input[28]) orelse return error.InvalidPayload;
    const generation = readU64(input[16..24]);
    const payload_len = readU32(input[24..28]);
    if (payload_len > maximum_consequence_payload_bytes) return error.InvalidPayload;
    var metadata: [consequence_metadata_bytes]u8 = undefined;
    @memcpy(&metadata, input[32..64]);
    const reply_required = input[29] == 1;
    try validateConsequenceMetadata(kind, generation, payload_len, reply_required, &metadata);
    return .{
        .terminal_revision = readU64(input[0..8]),
        .authority_client_id = readU64(input[8..16]),
        .generation = generation,
        .payload_len = payload_len,
        .kind = kind,
        .reply_required = reply_required,
        .metadata = metadata,
    };
}

/// Encodes one host-consequence snapshot end identity.
pub fn encodeConsequenceEnd(output: *[payload_bytes.consequence_end]u8, generation: u64) void {
    writeU64(output, generation);
}

/// Decodes one exact host-consequence snapshot end identity.
pub fn decodeConsequenceEnd(input: []const u8) PayloadError!u64 {
    if (input.len != payload_bytes.consequence_end) return error.InvalidPayload;
    return readU64(input);
}

/// Encodes one typed consequence reply header and exact caller body.
pub fn encodeConsequenceReply(
    output: []u8,
    generation: u64,
    kind: ConsequenceReplyKind,
    body: []const u8,
) PayloadError![]u8 {
    const total = std.math.add(usize, payload_bytes.consequence_reply_header, body.len) catch
        return error.InvalidPayload;
    if (output.len < total or total > maximum_request_payload_bytes) return error.InvalidPayload;
    try validateConsequenceReplyBody(kind, body);
    @memset(output[0..total], 0);
    writeU64(output[0..8], generation);
    output[8] = @backingInt(kind);
    @memcpy(output[payload_bytes.consequence_reply_header..total], body);
    return output[0..total];
}

/// Decodes and validates one typed consequence reply without allocating.
pub fn decodeConsequenceReply(input: []const u8) PayloadError!ConsequenceReply {
    if (input.len < payload_bytes.consequence_reply_header or
        input[9] != 0 or input[10] != 0 or input[11] != 0)
        return error.InvalidPayload;
    const kind = enumFromInt(ConsequenceReplyKind, input[8]) orelse return error.InvalidPayload;
    const body = input[payload_bytes.consequence_reply_header..];
    try validateConsequenceReplyBody(kind, body);
    return .{ .generation = readU64(input[0..8]), .kind = kind, .body = body };
}

fn validateConsequenceReplyBody(kind: ConsequenceReplyKind, body: []const u8) PayloadError!void {
    switch (kind) {
        .clipboard => {},
        .pointer_shape, .container_icon_title => if (body.len > consequence_small_payload_bytes)
            return error.InvalidPayload,
        .color_preference, .container_state => if (body.len != 1 or body[0] < 1 or body[0] > 2)
            return error.InvalidPayload,
        .container_position, .container_screen_cells => if (body.len != 8) return error.InvalidPayload,
        .container_decline => if (body.len != 0) return error.InvalidPayload,
    }
}

fn validateConsequenceMetadata(
    kind: ConsequenceKind,
    generation: u64,
    payload_len: u32,
    reply_required: bool,
    metadata: *const [consequence_metadata_bytes]u8,
) PayloadError!void {
    switch (kind) {
        .none => {
            if (generation != 0 or payload_len != 0 or reply_required or !allZero(metadata))
                return error.InvalidPayload;
        },
        .clipboard => {
            if (enumFromInt(ConsequenceClipboardProtocol, metadata[0]) == null) return error.InvalidPayload;
            const operation = enumFromInt(ConsequenceClipboardKind, metadata[1]) orelse
                return error.InvalidPayload;
            const selection_len: usize = metadata[2];
            if (selection_len > consequence_clipboard_selection_bytes or metadata[3] != 0)
                return error.InvalidPayload;
            if (!allZero(metadata[4 + selection_len ..])) return error.InvalidPayload;
            if (reply_required != (operation == .query)) return error.InvalidPayload;
        },
        .notification => {
            if (enumFromInt(ConsequenceNotificationKind, metadata[0]) == null) return error.InvalidPayload;
            if (payload_len > consequence_small_payload_bytes or metadata[1] != 0 or
                !allZero(metadata[4..]) or reply_required)
                return error.InvalidPayload;
        },
        .pointer_shape => {
            if (payload_len > consequence_small_payload_bytes or metadata[8] > 1 or
                !allZero(metadata[9..]))
                return error.InvalidPayload;
        },
        .file_transfer => {
            if (enumFromInt(ConsequenceFileTransferProtocol, metadata[0]) == null)
                return error.InvalidPayload;
            if (payload_len > consequence_packet_payload_bytes or !allZero(metadata[1..]) or reply_required)
                return error.InvalidPayload;
        },
        .drag_drop => {
            if (enumFromInt(ConsequenceDragDropKind, metadata[0]) == null) return error.InvalidPayload;
            if (payload_len > consequence_drag_drop_payload_bytes) return error.InvalidPayload;
            const flags = metadata[2];
            if (flags & ~@as(u8, 0x1f) != 0 or metadata[3] != 0 or
                !allZero(metadata[16..]) or reply_required)
                return error.InvalidPayload;
            const client_present = flags & 0x04 != 0;
            const operation_present = flags & 0x08 != 0;
            const index_present = flags & 0x10 != 0;
            if (!client_present and readU32(metadata[4..8]) != 0) return error.InvalidPayload;
            const operation = readU32(metadata[8..12]);
            if ((!operation_present and operation != 0) or
                (operation_present and operation > 3))
                return error.InvalidPayload;
            if (!index_present and readU32(metadata[12..16]) != 0) return error.InvalidPayload;
        },
        .container => {
            const request = enumFromInt(ConsequenceContainerKind, metadata[0]) orelse
                return error.InvalidPayload;
            if (!allZero(metadata[1..4]) or !allZero(metadata[12..])) return error.InvalidPayload;
            const first = readU32(metadata[4..8]);
            const second = readU32(metadata[8..12]);
            switch (request) {
                .move, .resize_pixels, .resize_cells => {},
                .resize_rows => if (first > 255 or second != 0) return error.InvalidPayload,
                .resize_columns => if ((first != 80 and first != 132) or second != 0)
                    return error.InvalidPayload,
                else => if (first != 0 or second != 0) return error.InvalidPayload,
            }
            const query = switch (request) {
                .report_state, .report_position, .report_screen_cells, .report_icon_title => true,
                else => false,
            };
            if (reply_required != query or payload_len != 0) return error.InvalidPayload;
        },
        .color_preference => if (!allZero(metadata) or !reply_required or payload_len != 0)
            return error.InvalidPayload,
        .media_copy => {
            if (metadata[0] > 1 or metadata[1] != 0 or !allZero(metadata[4..]) or
                reply_required or payload_len != 0)
                return error.InvalidPayload;
        },
        .bell => if (!allZero(metadata) or reply_required or payload_len != 0)
            return error.InvalidPayload,
        .legacy_control => {
            if (enumFromInt(ConsequenceLegacyControlKind, metadata[0]) == null)
                return error.InvalidPayload;
            if (!allZero(metadata[1..]) or reply_required or payload_len != 0)
                return error.InvalidPayload;
        },
        .dcs => {
            if (enumFromInt(ConsequenceDcsKind, metadata[0]) == null) return error.InvalidPayload;
            if (payload_len > consequence_dcs_payload_bytes or !allZero(metadata[1..]) or reply_required)
                return error.InvalidPayload;
        },
        .string_control => {
            if (enumFromInt(ConsequenceStringKind, metadata[0]) == null) return error.InvalidPayload;
            if (payload_len > consequence_small_payload_bytes or !allZero(metadata[1..]) or reply_required)
                return error.InvalidPayload;
        },
    }
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

// -- Interaction-state and result codecs -------------------------------------

/// Encodes one coherent interaction-state snapshot.
pub fn encodeInteractionStateSnapshot(
    output: *[payload_bytes.interaction_state_snapshot]u8,
    value: InteractionStateSnapshot,
) void {
    output.* = @splat(0);
    writeU64(output[0..8], value.terminal_revision);
    var flags: u32 = 0;
    if (value.keyboard_action_mode) flags |= interaction_state_flags.keyboard_action_mode;
    if (value.auto_repeat) flags |= interaction_state_flags.auto_repeat;
    if (value.newline_mode) flags |= interaction_state_flags.newline_mode;
    if (value.application_cursor_keys) flags |= interaction_state_flags.application_cursor_keys;
    if (value.application_keypad) flags |= interaction_state_flags.application_keypad;
    if (value.meta_sends_escape) flags |= interaction_state_flags.meta_sends_escape;
    if (value.report_key_up) flags |= interaction_state_flags.report_key_up;
    if (value.bracketed_paste) flags |= interaction_state_flags.bracketed_paste;
    if (value.focus_reporting) flags |= interaction_state_flags.focus_reporting;
    if (value.termios_signals) flags |= interaction_state_flags.termios_signals;
    if (value.alternate_scroll) flags |= interaction_state_flags.alternate_scroll;
    if (value.paste_events) flags |= interaction_state_flags.paste_events;
    if (value.inband_resize_notifications) flags |= interaction_state_flags.inband_resize_notifications;
    writeU32(output[8..12], flags);
    output[12] = @backingInt(value.mouse_tracking);
    output[13] = @backingInt(value.mouse_protocol);
    output[14] = @bitCast(value.modify_other_keys);
    output[15] = value.kitty_keyboard_flags;
    writeU16(output[16..18], value.key_format_resource_4);
    output[18] = value.pointer_mode;
}

/// Decodes and validates one coherent interaction-state snapshot.
pub fn decodeInteractionStateSnapshot(input: []const u8) PayloadError!InteractionStateSnapshot {
    if (input.len != payload_bytes.interaction_state_snapshot) return error.InvalidPayload;
    const flags = readU32(input[8..12]);
    if (flags & ~interaction_state_flags.known != 0 or input[19] != 0 or
        input[15] & 0x80 != 0 or input[18] > 3)
        return error.InvalidPayload;
    return .{
        .terminal_revision = readU64(input[0..8]),
        .keyboard_action_mode = flags & interaction_state_flags.keyboard_action_mode != 0,
        .auto_repeat = flags & interaction_state_flags.auto_repeat != 0,
        .newline_mode = flags & interaction_state_flags.newline_mode != 0,
        .application_cursor_keys = flags & interaction_state_flags.application_cursor_keys != 0,
        .application_keypad = flags & interaction_state_flags.application_keypad != 0,
        .meta_sends_escape = flags & interaction_state_flags.meta_sends_escape != 0,
        .report_key_up = flags & interaction_state_flags.report_key_up != 0,
        .bracketed_paste = flags & interaction_state_flags.bracketed_paste != 0,
        .focus_reporting = flags & interaction_state_flags.focus_reporting != 0,
        .termios_signals = flags & interaction_state_flags.termios_signals != 0,
        .alternate_scroll = flags & interaction_state_flags.alternate_scroll != 0,
        .paste_events = flags & interaction_state_flags.paste_events != 0,
        .inband_resize_notifications = flags & interaction_state_flags.inband_resize_notifications != 0,
        .mouse_tracking = enumFromInt(InteractionMouseTracking, input[12]) orelse return error.InvalidPayload,
        .mouse_protocol = enumFromInt(InteractionMouseProtocol, input[13]) orelse return error.InvalidPayload,
        .modify_other_keys = @bitCast(input[14]),
        .kitty_keyboard_flags = input[15],
        .key_format_resource_4 = readU16(input[16..18]),
        .pointer_mode = @intCast(input[18]),
    };
}

/// Encodes one bounded command result.
pub fn encodeResult(output: *[payload_bytes.result]u8, value: Result) void {
    output[0] = @backingInt(value.request_kind);
    output[1] = @backingInt(value.code);
}

/// Decodes one bounded command result.
pub fn decodeResult(input: []const u8) PayloadError!Result {
    if (input.len != payload_bytes.result) return error.InvalidPayload;
    return .{
        .request_kind = enumFromInt(Kind, input[0]) orelse return error.InvalidPayload,
        .code = enumFromInt(ResultCode, input[1]) orelse return error.InvalidPayload,
    };
}

// =============================================================================
// Frame header and integer primitives
// =============================================================================

/// Encodes one fixed header without allocation.
pub fn encodeHeader(output: *[header_bytes]u8, header: Header) error{PayloadTooLarge}!void {
    return framing.encode(Kind, maximum_payload_bytes, output, header);
}

/// Rejects control tags and oversized terminal payloads before allocation.
pub fn decodeHeader(input: *const [header_bytes]u8) HeaderError!Header {
    return framing.decode(Kind, maximum_payload_bytes, input);
}

fn writeU32(output: []u8, value: u32) void {
    std.debug.assert(output.len == 4);
    output[0] = @truncate(value >> 24);
    output[1] = @truncate(value >> 16);
    output[2] = @truncate(value >> 8);
    output[3] = @truncate(value);
}

fn writeI32(output: []u8, value: i32) void {
    writeU32(output, @bitCast(value));
}

fn writeU16(output: []u8, value: u16) void {
    std.debug.assert(output.len == 2);
    output[0] = @truncate(value >> 8);
    output[1] = @truncate(value);
}

fn writeU64(output: []u8, value: u64) void {
    std.debug.assert(output.len == 8);
    var shift: u6 = 56;
    for (output) |*byte| {
        byte.* = @truncate(value >> shift);
        shift -|= 8;
    }
}

fn readU32(input: []const u8) u32 {
    std.debug.assert(input.len == 4);
    return (@as(u32, input[0]) << 24) |
        (@as(u32, input[1]) << 16) |
        (@as(u32, input[2]) << 8) |
        @as(u32, input[3]);
}

fn readI32(input: []const u8) i32 {
    return @bitCast(readU32(input));
}

fn readU16(input: []const u8) u16 {
    std.debug.assert(input.len == 2);
    return (@as(u16, input[0]) << 8) | @as(u16, input[1]);
}

fn readU64(input: []const u8) u64 {
    std.debug.assert(input.len == 8);
    var value: u64 = 0;
    for (input) |byte| value = (value << 8) | @as(u64, byte);
    return value;
}

fn enumFromInt(comptime Enum: type, value: @typeInfo(Enum).@"enum".tag_type) ?Enum {
    const info = @typeInfo(Enum).@"enum";
    inline for (info.field_values) |field_value| {
        if (value == field_value) return @fromBackingInt(@intCast(value));
    }
    return null;
}

fn advance(value: *u64) void {
    // zig-audit: acknowledge panic
    // reason: This process-lifetime identity/revision space is deliberately non-wrapping; exhaustion is an unrecoverable invariant breach.
    value.* = std.math.add(u64, value.*, 1) catch @panic("protocol revision exhausted");
}

// =============================================================================
// Frozen wire and authority proofs
// =============================================================================

// -- Framing and rich snapshot grammar ---------------------------------------

test "header round trips and rejects framing ambiguity" {
    var bytes: [header_bytes]u8 = undefined;
    try encodeHeader(&bytes, .{ .kind = .observe, .payload_len = 1234 });
    const decoded = try decodeHeader(&bytes);
    try std.testing.expectEqual(Kind.observe, decoded.kind);
    try std.testing.expectEqual(@as(u32, 1234), decoded.payload_len);

    var invalid = bytes;
    invalid[6] = 1;
    try std.testing.expectError(error.InvalidReservedBits, decodeHeader(&invalid));
    invalid = bytes;
    invalid[5] = 0xff;
    try std.testing.expectError(error.UnknownKind, decodeHeader(&invalid));
}

test "wire integers round trip beyond one byte" {
    var header_bytes_out: [header_bytes]u8 = undefined;
    try encodeHeader(&header_bytes_out, .{ .kind = .snapshot_data, .payload_len = 0x000f_a2b3 });
    const header = try decodeHeader(&header_bytes_out);
    try std.testing.expectEqual(@as(u32, 0x000f_a2b3), header.payload_len);

    var resize_bytes: [payload_bytes.resize]u8 = undefined;
    encodeResize(&resize_bytes, .{ .rows = 512, .columns = 1025 });
    const resize = try decodeResize(&resize_bytes);
    try std.testing.expectEqual(@as(u16, 512), resize.rows);
    try std.testing.expectEqual(@as(u16, 1025), resize.columns);
}

test "graphics v2 manifest and exact image resource grammar are bounded" {
    var manifest_header: [graphics_v2.manifest_header_bytes]u8 = undefined;
    encodeSnapshotGraphicsHeader(&manifest_header, .{
        .generation = 0x0102_0304_0506_0708,
        .content_generation = 0x1112_1314_1516_1718,
        .cell_pixel_width = 10,
        .cell_pixel_height = 20,
        .image_count = 2,
        .placement_count = 3,
    });
    try std.testing.expectEqualDeep(
        SnapshotGraphicsHeader{
            .generation = 0x0102_0304_0506_0708,
            .content_generation = 0x1112_1314_1516_1718,
            .cell_pixel_width = 10,
            .cell_pixel_height = 20,
            .image_count = 2,
            .placement_count = 3,
        },
        try decodeSnapshotGraphicsHeader(&manifest_header),
    );

    var image: [graphics_v2.image_bytes]u8 = undefined;
    encodeSnapshotImage(&image, .{
        .image_id = 9,
        .generation = 0x2122_2324_2526_2728,
        .width = 2,
        .height = 3,
    });
    try std.testing.expectEqualDeep(
        SnapshotImage{
            .image_id = 9,
            .generation = 0x2122_2324_2526_2728,
            .width = 2,
            .height = 3,
        },
        try decodeSnapshotImage(&image),
    );

    var placement: [graphics_v2.placement_bytes]u8 = undefined;
    encodeSnapshotImagePlacement(&placement, .{
        .image_id = 9,
        .generation = 33,
        .row = 4,
        .column = 5,
        .source_x = 1,
        .source_y = 2,
        .source_width = 3,
        .source_height = 4,
        .cell_x = 5,
        .cell_y = 6,
        .pixel_width = 7,
        .pixel_height = 8,
        .z = -9,
    });
    try std.testing.expectEqualDeep(
        SnapshotImagePlacement{
            .image_id = 9,
            .generation = 33,
            .row = 4,
            .column = 5,
            .source_x = 1,
            .source_y = 2,
            .source_width = 3,
            .source_height = 4,
            .cell_x = 5,
            .cell_y = 6,
            .pixel_width = 7,
            .pixel_height = 8,
            .z = -9,
        },
        try decodeSnapshotImagePlacement(&placement),
    );

    var request: [payload_bytes.image_request]u8 = undefined;
    encodeImageRequest(&request, .{ .image_id = 9, .generation = 33 });
    try std.testing.expectEqualDeep(
        ImageRequest{ .image_id = 9, .generation = 33 },
        try decodeImageRequest(&request),
    );

    var begin: [payload_bytes.image_begin]u8 = undefined;
    encodeImageBegin(&begin, .{
        .image_id = 9,
        .generation = 33,
        .width = 2,
        .height = 2,
        .byte_count = 16,
    });
    try std.testing.expectEqualDeep(
        ImageBegin{
            .image_id = 9,
            .generation = 33,
            .width = 2,
            .height = 2,
            .byte_count = 16,
        },
        try decodeImageBegin(&begin),
    );

    var end: [payload_bytes.image_end]u8 = undefined;
    encodeImageEnd(&end, .{ .image_id = 9, .generation = 33 });
    try std.testing.expectEqualDeep(
        ImageEnd{ .image_id = 9, .generation = 33 },
        try decodeImageEnd(&end),
    );

    var bad_image = image;
    @memset(bad_image[12..20], 0xff);
    try std.testing.expectError(error.InvalidPayload, decodeSnapshotImage(&bad_image));
    var bad_begin = begin;
    bad_begin[23] = 15;
    try std.testing.expectError(error.InvalidPayload, decodeImageBegin(&bad_begin));
    var bad_request = request;
    @memset(bad_request[0..4], 0);
    try std.testing.expectError(error.InvalidPayload, decodeImageRequest(&bad_request));
}

test "selected text extraction range is fixed and signed-row safe" {
    var bytes: [payload_bytes.text_extract]u8 = undefined;
    encodeTextExtract(&bytes, .{
        .start = .{ .row = -123456, .column = 513 },
        .end = .{ .row = 0x1234567, .column = 65535 },
        .columns = 0x1234,
        .alternate_screen = true,
    });
    const decoded = try decodeTextExtract(&bytes);
    try std.testing.expectEqual(@as(i32, -123456), decoded.start.row);
    try std.testing.expectEqual(@as(u16, 513), decoded.start.column);
    try std.testing.expectEqual(@as(i32, 0x1234567), decoded.end.row);
    try std.testing.expectEqual(@as(u16, 65535), decoded.end.column);
    try std.testing.expectEqual(@as(u16, 0x1234), decoded.columns);
    try std.testing.expect(decoded.alternate_screen);
    try std.testing.expectError(error.InvalidPayload, decodeTextExtract(bytes[0 .. bytes.len - 1]));
}

test "snapshot begin bytes stay frozen" {
    var encoded: [payload_bytes.snapshot_begin]u8 = undefined;
    encodeSnapshotBegin(&encoded, .{
        .revision = 0x0102_0304_0506_0708,
        .terminal = .{
            .revision = 0x1112_1314_1516_1718,
            .history_offset = 0x2122_2324,
            .history_count = 0x3132_3334,
            .history_row_base = 0x4142_4344,
            .rows = 0x5152,
            .columns = 0x6162,
            .cursor_row = 0x7172,
            .cursor_column = 0x8182,
            .cursor_shape = 0x91,
            .cursor_visible = true,
            .cursor_blink = true,
            .alternate_screen = true,
        },
        .stream_closed = true,
        .child_exited = true,
        .leader_present = true,
        .you_are_leader = true,
    });
    try std.testing.expectEqualSlices(u8, &.{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
        0x21, 0x22, 0x23, 0x24, 0x31, 0x32, 0x33, 0x34,
        0x41, 0x42, 0x43, 0x44, 0x51, 0x52, 0x61, 0x62,
        0x71, 0x72, 0x81, 0x82, 0x91, 0x7f,
    }, &encoded);
}

test "Server snapshot flags remain outside VT metadata" {
    for (0..128) |flags| {
        var encoded: [payload_bytes.snapshot_begin]u8 = @splat(0);
        writeU64(encoded[0..8], 42);
        writeU64(encoded[8..16], 17);
        encoded[37] = @intCast(flags);
        const value = try decodeSnapshotBegin(&encoded);
        try std.testing.expectEqual(@as(u64, 42), value.revision);
        try std.testing.expectEqual(@as(u64, 17), value.terminal.revision);
        try std.testing.expectEqual(flags & 1 != 0, value.terminal.cursor_visible);
        try std.testing.expectEqual(flags & 2 != 0, value.terminal.cursor_blink);
        try std.testing.expectEqual(flags & 4 != 0, value.terminal.alternate_screen);
        try std.testing.expectEqual(flags & 8 != 0, value.stream_closed);
        try std.testing.expectEqual(flags & 16 != 0, value.child_exited);
        try std.testing.expectEqual(flags & 32 != 0, value.leader_present);
        try std.testing.expectEqual(flags & 64 != 0, value.you_are_leader);
        var round_trip: [payload_bytes.snapshot_begin]u8 = undefined;
        encodeSnapshotBegin(&round_trip, value);
        try std.testing.expectEqualSlices(u8, &encoded, &round_trip);
        var pure: [codec.metadata.bytes]u8 = undefined;
        codec.metadata.encode(&pure, value.terminal);
        try std.testing.expectEqual(@as(u8, @intCast(flags & 7)), pure[29]);
        encoded[37] |= 0x80;
        try std.testing.expectError(error.InvalidPayload, decodeSnapshotBegin(&encoded));
        try std.testing.expectError(error.InvalidPayload, decodeSnapshotBegin(encoded[0 .. encoded.len - 1]));
    }
}

// -- Typed input grammar ------------------------------------------------------

test "typed key grammar is exact and rejects noncanonical payloads" {
    const value = KeyInput{
        .kind = .unicode,
        .key_value = 'a',
        .action = .repeat,
        .modifiers = typed_input.modifiers.shift | typed_input.modifiers.control,
        .shifted = 'A',
        .alternate = 0x00e4,
        .legacy_text = "\x1ba",
        .text = "A",
    };
    var storage: [64]u8 = undefined;
    const encoded = try encodeKeyInput(&storage, value);
    try std.testing.expectEqualSlices(u8, &.{
        0x02, 0x02, 0x05, 0x03,
        0x00, 0x00, 0x00, 0x61,
        0x00, 0x00, 0x00, 0x41,
        0x00, 0x00, 0x00, 0xe4,
        0x00, 0x02, 0x00, 0x01,
        0x1b, 0x61, 0x41,
    }, encoded);
    const decoded = try decodeKeyInput(encoded);
    try std.testing.expectEqual(value.kind, decoded.kind);
    try std.testing.expectEqual(value.key_value, decoded.key_value);
    try std.testing.expectEqual(value.action, decoded.action);
    try std.testing.expectEqual(value.modifiers, decoded.modifiers);
    try std.testing.expectEqual(value.shifted, decoded.shifted);
    try std.testing.expectEqual(value.alternate, decoded.alternate);
    try std.testing.expectEqualStrings(value.legacy_text, decoded.legacy_text);
    try std.testing.expectEqualStrings(value.text, decoded.text);

    var invalid = storage;
    invalid[0] = 0xff;
    try std.testing.expectError(error.InvalidPayload, decodeKeyInput(invalid[0..encoded.len]));
    invalid = storage;
    invalid[1] = 0;
    try std.testing.expectError(error.InvalidPayload, decodeKeyInput(invalid[0..encoded.len]));
    invalid = storage;
    invalid[3] = 0;
    try std.testing.expectError(error.InvalidPayload, decodeKeyInput(invalid[0..encoded.len]));
    invalid = storage;
    invalid[4] = 0;
    invalid[5] = 0;
    invalid[6] = 0xd8;
    invalid[7] = 0x00;
    try std.testing.expectError(error.InvalidPayload, decodeKeyInput(invalid[0..encoded.len]));
    try std.testing.expectError(error.InvalidPayload, decodeKeyInput(encoded[0 .. encoded.len - 1]));

    var named_storage: [typed_input.key_header_bytes]u8 = undefined;
    const named = try encodeKeyInput(&named_storage, .{
        .kind = .named,
        .key_value = @backingInt(InputKeyName.up),
        .action = .press,
    });
    named_storage[7] = 59;
    try std.testing.expectError(error.InvalidPayload, decodeKeyInput(named));

    const bad_text = [_]u8{0xff};
    try std.testing.expectError(error.InvalidPayload, keyInputBytes(.{
        .kind = .unicode,
        .key_value = 'x',
        .action = .press,
        .text = &bad_text,
    }));
    var maximum_legacy: [typed_input.maximum_legacy_key_bytes]u8 = @splat('x');
    try std.testing.expectEqual(
        typed_input.key_header_bytes + maximum_legacy.len,
        try keyInputBytes(.{
            .kind = .unicode,
            .key_value = 'x',
            .action = .press,
            .legacy_text = &maximum_legacy,
        }),
    );
    var oversized_legacy: [typed_input.maximum_legacy_key_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidPayload, keyInputBytes(.{
        .kind = .unicode,
        .key_value = 'x',
        .action = .press,
        .legacy_text = &oversized_legacy,
    }));
    var tiny: [typed_input.key_header_bytes - 1]u8 = undefined;
    try std.testing.expectError(error.OutputTooSmall, encodeKeyInput(&tiny, .{
        .kind = .unicode,
        .key_value = 0,
        .action = .press,
    }));
}

test "typed mouse and focus grammars are exact and hostile-safe" {
    const value = MouseInput{
        .kind = .move,
        .button = .none,
        .modifiers = typed_input.modifiers.alt,
        .buttons_down = 0b101,
        .row = -2,
        .column = 0x1234,
        .pixel_x = 0x0102_0304,
        .pixel_y = 0xa1a2_a3a4,
    };
    var encoded: [typed_input.mouse_bytes]u8 = undefined;
    try encodeMouseInput(&encoded, value);
    try std.testing.expectEqualSlices(u8, &.{
        0x03, 0x00, 0x02, 0x05,
        0xff, 0xff, 0xff, 0xfe,
        0x12, 0x34, 0x01, 0x01,
        0x02, 0x03, 0x04, 0xa1,
        0xa2, 0xa3, 0xa4,
    }, &encoded);
    try std.testing.expectEqualDeep(value, try decodeMouseInput(&encoded));

    var invalid = encoded;
    invalid[0] = 0;
    try std.testing.expectError(error.InvalidPayload, decodeMouseInput(&invalid));
    invalid = encoded;
    invalid[1] = 0xff;
    try std.testing.expectError(error.InvalidPayload, decodeMouseInput(&invalid));
    invalid = encoded;
    invalid[3] = 0x80;
    try std.testing.expectError(error.InvalidPayload, decodeMouseInput(&invalid));
    invalid = encoded;
    invalid[10] = 0;
    try std.testing.expectError(error.InvalidPayload, decodeMouseInput(&invalid));
    try std.testing.expectError(error.InvalidPayload, encodeMouseInput(&encoded, .{
        .kind = .press,
        .button = .left,
        .row = 0,
        .column = 0,
        .pixel_x = 1,
    }));

    var focus: [typed_input.focus_bytes]u8 = undefined;
    encodeFocusInput(&focus, .in);
    try std.testing.expectEqualSlices(u8, &.{1}, &focus);
    try std.testing.expectEqual(InputFocus.in, try decodeFocusInput(&focus));
    focus[0] = 3;
    try std.testing.expectError(error.InvalidPayload, decodeFocusInput(&focus));
}

// -- Host-consequence grammar ------------------------------------------------

test "consequence begin preserves exact clipboard metadata and rejects drift" {
    var metadata: [consequence_metadata_bytes]u8 = @splat(0);
    metadata[0] = @backingInt(ConsequenceClipboardProtocol.osc52);
    metadata[1] = @backingInt(ConsequenceClipboardKind.query);
    metadata[2] = 1;
    metadata[4] = 'c';
    var encoded: [payload_bytes.consequence_begin]u8 = undefined;
    try encodeConsequenceBegin(&encoded, .{
        .terminal_revision = 9,
        .authority_client_id = 7,
        .generation = 11,
        .payload_len = 3,
        .kind = .clipboard,
        .reply_required = true,
        .metadata = metadata,
    });
    const decoded = try decodeConsequenceBegin(&encoded);
    try std.testing.expectEqual(@as(u64, 9), decoded.terminal_revision);
    try std.testing.expectEqual(@as(ClientId, 7), decoded.authority_client_id);
    try std.testing.expectEqual(@as(u64, 11), decoded.generation);
    try std.testing.expectEqual(@as(u32, 3), decoded.payload_len);
    try std.testing.expectEqual(ConsequenceKind.clipboard, decoded.kind);
    try std.testing.expect(decoded.reply_required);
    try std.testing.expectEqual(@as(u8, 1), decoded.metadata[2]);
    try std.testing.expectEqual(@as(u8, 'c'), decoded.metadata[4]);

    var bad = encoded;
    bad[30] = 1;
    try std.testing.expectError(error.InvalidPayload, decodeConsequenceBegin(&bad));
    bad = encoded;
    bad[29] = 0;
    try std.testing.expectError(error.InvalidPayload, decodeConsequenceBegin(&bad));
    bad = encoded;
    bad[35] = 1;
    try std.testing.expectError(error.InvalidPayload, decodeConsequenceBegin(&bad));
}

test "consequence begin enforces family payload ceilings" {
    var metadata: [consequence_metadata_bytes]u8 = @splat(0);
    var encoded: [payload_bytes.consequence_begin]u8 = undefined;

    metadata[0] = @backingInt(ConsequenceNotificationKind.message);
    writeU16(metadata[2..4], 9);
    try std.testing.expectError(error.InvalidPayload, encodeConsequenceBegin(&encoded, .{
        .terminal_revision = 1,
        .authority_client_id = 1,
        .generation = 1,
        .payload_len = consequence_small_payload_bytes + 1,
        .kind = .notification,
        .reply_required = false,
        .metadata = metadata,
    }));

    metadata = @splat(0);
    metadata[0] = @backingInt(ConsequenceFileTransferProtocol.kitty_5113);
    try std.testing.expectError(error.InvalidPayload, encodeConsequenceBegin(&encoded, .{
        .terminal_revision = 1,
        .authority_client_id = 1,
        .generation = 2,
        .payload_len = consequence_packet_payload_bytes + 1,
        .kind = .file_transfer,
        .reply_required = false,
        .metadata = metadata,
    }));

    metadata = @splat(0);
    metadata[0] = @backingInt(ConsequenceDcsKind.kitty_remote_command);
    try std.testing.expectError(error.InvalidPayload, encodeConsequenceBegin(&encoded, .{
        .terminal_revision = 1,
        .authority_client_id = 1,
        .generation = 3,
        .payload_len = consequence_dcs_payload_bytes + 1,
        .kind = .dcs,
        .reply_required = false,
        .metadata = metadata,
    }));
}

test "consequence reply grammar is typed and bounded" {
    var storage: [2048]u8 = undefined;
    const clipboard = try encodeConsequenceReply(&storage, 12, .clipboard, "hello");
    const decoded = try decodeConsequenceReply(clipboard);
    try std.testing.expectEqual(@as(u64, 12), decoded.generation);
    try std.testing.expectEqual(ConsequenceReplyKind.clipboard, decoded.kind);
    try std.testing.expectEqualStrings("hello", decoded.body);

    const color = try encodeConsequenceReply(&storage, 13, .color_preference, &.{1});
    try std.testing.expectEqual(@as(u8, 1), (try decodeConsequenceReply(color)).body[0]);
    try std.testing.expectError(
        error.InvalidPayload,
        encodeConsequenceReply(&storage, 13, .color_preference, &.{3}),
    );
    try std.testing.expectError(
        error.InvalidPayload,
        encodeConsequenceReply(&storage, 13, .container_position, &.{ 0, 1 }),
    );

    const decline = try encodeConsequenceReply(&storage, 14, .container_decline, &.{});
    try std.testing.expectEqual(@as(usize, payload_bytes.consequence_reply_header), decline.len);
    try std.testing.expectError(
        error.InvalidPayload,
        encodeConsequenceReply(&storage, 14, .container_decline, "x"),
    );
}

test "consequence authority is explicit and disconnect safe" {
    var authority: ConsequenceAuthority = .{};
    try std.testing.expect(authority.leader() == null);
    try std.testing.expect(authority.assign(41));
    try std.testing.expect(authority.mayHandle(41));
    try std.testing.expect(!authority.mayHandle(42));
    try std.testing.expect(!authority.disconnected(42));
    try std.testing.expect(authority.disconnected(41));
    try std.testing.expect(authority.leader() == null);
}

// -- Interaction state and authority -----------------------------------------

test "interaction state snapshot is fixed and rejects reserved drift" {
    var encoded: [payload_bytes.interaction_state_snapshot]u8 = undefined;
    encodeInteractionStateSnapshot(&encoded, .{
        .terminal_revision = 0x0102_0304_0506_0708,
        .keyboard_action_mode = true,
        .auto_repeat = false,
        .newline_mode = true,
        .application_cursor_keys = true,
        .application_keypad = true,
        .meta_sends_escape = true,
        .report_key_up = true,
        .bracketed_paste = true,
        .focus_reporting = true,
        .termios_signals = true,
        .alternate_scroll = true,
        .paste_events = true,
        .inband_resize_notifications = true,
        .mouse_tracking = .any_event,
        .mouse_protocol = .sgr_pixel,
        .modify_other_keys = -1,
        .kitty_keyboard_flags = 0x7f,
        .key_format_resource_4 = 0x1234,
        .pointer_mode = 3,
    });
    try std.testing.expectEqualSlices(u8, &.{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x00, 0x00, 0x1f, 0xfd, 0x04, 0x03, 0xff, 0x7f,
        0x12, 0x34, 0x03, 0x00,
    }, &encoded);
    const decoded = try decodeInteractionStateSnapshot(&encoded);
    try std.testing.expect(decoded.keyboard_action_mode);
    try std.testing.expect(!decoded.auto_repeat);
    try std.testing.expect(decoded.bracketed_paste);
    try std.testing.expectEqual(@as(i8, -1), decoded.modify_other_keys);
    try std.testing.expectEqual(InteractionMouseProtocol.sgr_pixel, decoded.mouse_protocol);
    var bad = encoded;
    bad[19] = 1;
    try std.testing.expectError(error.InvalidPayload, decodeInteractionStateSnapshot(&bad));
    bad = encoded;
    bad[15] = 0x80;
    try std.testing.expectError(error.InvalidPayload, decodeInteractionStateSnapshot(&bad));
}

test "resize leadership is explicit and disappears with its client" {
    var authority: ResizeAuthority = .{};
    try std.testing.expect(authority.leader() == null);
    try std.testing.expect(!authority.mayResize(7));

    const before = authority.revision;
    try std.testing.expect(authority.assign(7));
    try std.testing.expectEqual(before + 1, authority.revision);
    try std.testing.expect(authority.mayResize(7));
    try std.testing.expect(!authority.mayResize(8));
    try std.testing.expect(!authority.assign(7));

    try std.testing.expect(!authority.disconnected(8));
    try std.testing.expect(authority.disconnected(7));
    try std.testing.expect(authority.leader() == null);
    try std.testing.expect(!authority.mayResize(7));
}

test "v8 resize has exact pixel pair and rejects old or partial geometry" {
    const geometry = Resize{ .rows = 38, .columns = 81, .cell_pixel_width = 11, .cell_pixel_height = 24 };
    var bytes: [payload_bytes.resize]u8 = undefined;
    encodeResize(&bytes, geometry);
    try std.testing.expectEqualSlices(u8, &.{ 0, 38, 0, 81, 0, 11, 0, 24 }, &bytes);
    try std.testing.expectEqualDeep(geometry, try decodeResize(&bytes));
    try std.testing.expectError(error.InvalidPayload, decodeResize(bytes[0..4]));
    bytes[7] = 0;
    try std.testing.expectError(error.InvalidPayload, decodeResize(&bytes));
    bytes[5] = 0;
    try std.testing.expectEqualDeep(Resize{ .rows = 38, .columns = 81 }, try decodeResize(&bytes));
    try std.testing.expect(graphics_v2.maximum_manifest_bytes < maximum_payload_bytes);
    try std.testing.expectEqual(@as(usize, 16384), graphics_v2.maximum_placements);
}
