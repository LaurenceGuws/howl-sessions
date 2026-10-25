#ifndef HOWL_SERVER_CLIENT_H
#define HOWL_SERVER_CLIENT_H
#include <stddef.h>
#include <stdint.h>
#include "howl_vt_native.h"
#ifdef __cplusplus
extern "C" {
#endif

/* Version 1. Synchronous caller-driven I/O; no library threads.
 * One I/O owner per connection. Interrupt.cancel may run on another thread.
 * Interrupt is borrowed until every connection using it is released.
 * Release only after calls return; releases clear caller slots.
 * Catalogs/snapshots own independent storage and may outlive connections.
 * Borrowed names/scalars/URIs/properties expire with their owning view.
 * Constructor output slots must start NULL; failure leaves them NULL. Every input
 * pointer borrows readable storage for its length for this call only; outputs need
 * writable native-aligned storage. Handles must originate from this library and
 * must not be used after release or as a different handle family.
 * Records use native C layout/endian. Compile against this header version; later
 * incompatible layouts/symbol sets require a different ABI version.
 * Pre-I/O argument errors and recognized complete Server rejections preserve a connection.
 * Transport or malformed/incomplete response failures retire it; release the
 * handle after outstanding calls return. No operation reconnects implicitly. */
#define HSC_ABI_VERSION 1u
#if HVT_NATIVE_VERSION != 1u
#error "Server client ABI v1 incorporates VT native v1; incompatible changes require coordinated review"
#endif
#define HSC_MAX_ENDPOINT_BYTES 1024u
#define HSC_MAX_NAME_BYTES 64u
#define HSC_MAX_SHELL_BYTES 1024u
#define HSC_MAX_COMMAND_BYTES 4096u
#define HSC_MAX_CWD_BYTES 1024u
#define HSC_MAX_TEXT_BYTES 65535u
#define HSC_MAX_PROPERTY_BYTES 1024u
#define HSC_MAX_IMAGE_BYTES 16777216u
typedef struct hsc_control hsc_control;
typedef struct hsc_attachment hsc_attachment;
typedef struct hsc_interrupt hsc_interrupt;
typedef struct hsc_tree hsc_tree;
typedef struct hsc_snapshot hsc_snapshot;
typedef struct hsc_image hsc_image;
typedef struct hsc_request_view hsc_request_view;
/* Server authority is separate from VT-owned native terminal facts. */
/* Outbound body ceilings, distinct from the incoming retained-request limit.
 * Oversize replies return HSC_RESOURCE_LIMIT before allocation or socket I/O. */
enum { HSC_MAX_CLIPBOARD_REPLY_BYTES=65524, HSC_MAX_POINTER_REPLY_BYTES=1024,
    HSC_MAX_ICON_TITLE_REPLY_BYTES=1024 };
typedef struct hsc_request_info { hvt_request request; uint64_t authority_client_id; } hsc_request_info;

enum hsc_status {
    HSC_OK=0, HSC_INVALID_ARGUMENT=1, HSC_VERSION_MISMATCH=2,
    HSC_OUT_OF_MEMORY=3, HSC_CANCELLED=4, HSC_TIMEOUT=5, HSC_CLOSED=6,
    HSC_RETIRED=7, HSC_PROTOCOL_ERROR=8, HSC_STALE_SERVER=9,
    HSC_TRANSPORT_ERROR=10, HSC_BUFFER_TOO_SMALL=11, HSC_UNAVAILABLE=12,
    HSC_RESOURCE_LIMIT=13, HSC_SESSION_NOT_FOUND=20, HSC_INSTANCE_NOT_FOUND=21,
    HSC_NAME_EXISTS=22, HSC_SESSION_CAPACITY=23, HSC_INSTANCE_CAPACITY=24,
    HSC_CREATE_FAILED=25, HSC_INTERNAL=26, HSC_UNSUPPORTED=27, HSC_NOT_LEADER=28,
    HSC_REJECTED=29, HSC_NOT_AUTHORITY=30
};
typedef struct { uint64_t server_id, tree_revision; uint16_t session_count,
    instance_count, session_capacity, instances_per_session; } hsc_server_status;
typedef struct { uint64_t server_id, session_id, instance_id, tree_revision,
    client_id; } hsc_ready;
typedef struct { uint64_t session_id, instance_id; } hsc_identity;
typedef struct { uint64_t session_id; uint16_t rows, columns, history_rows, reserved;
    const uint8_t *shell; size_t shell_len;
    const uint8_t *command; size_t command_len;
    const uint8_t *cwd; size_t cwd_len; } hsc_launch;
typedef struct { uint64_t id; const uint8_t *name; size_t name_len,
    instance_count; } hsc_session;
enum hsc_instance_state { HSC_INSTANCE_RUNNING=1, HSC_INSTANCE_EXITED=2 };
typedef struct { uint64_t id; uint32_t state; } hsc_instance;
typedef struct { uint64_t delivery_revision, terminal_revision;
    uint32_t history_offset, history_count, history_row_base;
    uint32_t row_count, cell_count, scalar_count, hyperlink_count;
    uint16_t rows, columns, cursor_row, cursor_column;
    uint32_t cursor_shape, flags; } hsc_metadata;
/* Metadata flags: cursor visible=1, blink=2, alternate=4, child exited=8,
 * stream closed=16, leader present=32, this client is leader=64. Cursor shape: block=0, underline=1,
 * bar=2, none=3. Row geometry: single=0, double-width=1, top=2, bottom=3. */
typedef struct { uint32_t cell_offset, cell_count, wrapped, geometry; } hsc_row;
/* Color kind: default=0, palette index=1, RGB=2 (value=0xRRGGBB). */
typedef struct { uint32_t kind, value; } hsc_color;
/* Style flags: bold=1, dim=2, italic=4, blink=8, fast blink=16,
 * reverse=32, invisible=64, underline=128, strikethrough=256. */
typedef struct { uint32_t scalar_offset, scalar_count, link_id, style;
    hsc_color foreground, background, underline_color;
    uint8_t width, height, x, y, subscale_n, subscale_d, vertical_align,
    horizontal_align, semantic_width, font, baseline, underline_style, protection;
    uint8_t reserved[3]; } hsc_cell;
typedef struct { uint32_t link_id; const uint8_t *uri; size_t uri_len; } hsc_hyperlink;
typedef struct { uint8_t r,g,b,a; } hsc_rgba;
typedef struct { uint64_t cursor_age_ns; uint32_t present, reverse_screen;
    hsc_rgba foreground, background, cursor, cursor_text,
        selection_background, selection_foreground;
    hsc_rgba palette[256]; } hsc_presentation;
/* Presentation present: cursor age=1, cursor=2, cursor text=4,
 * selection background=8, selection foreground=16. */
/* Length-delimited property bytes preserve absence versus an empty report and
 * may contain invalid UTF-8. No returned string is NUL-terminated by contract. */
typedef struct { const uint8_t *bytes; size_t length; } hsc_bytes;
typedef struct { uint64_t mark_generation; uint32_t present, directory_kind,
    shell_version, mark_kind; int32_t mark_status;
    uint32_t progress_kind, progress_value;
    hsc_bytes title, icon, directory, remote_host, shell_name, mark_metadata;
} hsc_properties;
/* Property present: title=1, icon=2, directory=4, remote host=8, shell=16,
 * shell name=32, mark status=64. Directory: URI=1, path=2.
 * Mark kind is ASCII A..D or zero; progress: none=0, normal=1, failure=2,
 * indeterminate=3, paused=4. */
typedef struct { uint64_t generation, content_generation;
    uint32_t cell_pixel_width, cell_pixel_height, image_count, placement_count;
} hsc_graphics;
typedef struct { uint64_t generation; uint32_t image_id, width, height, reserved;
} hsc_image_identity;
typedef struct { uint64_t generation; uint32_t image_id; uint16_t row, column;
    uint32_t source_x, source_y, source_width, source_height,
        cell_x, cell_y, pixel_width, pixel_height;
    int32_t z; uint32_t reserved;
} hsc_placement;
typedef struct { int32_t row; uint16_t column, reserved;
    uint32_t kind, button, modifiers, buttons_down, has_pixels, pixel_x, pixel_y;
} hsc_mouse;
typedef struct { uint16_t rows, columns, cell_pixel_width, cell_pixel_height;
} hsc_geometry;
/* Geometry: a zero pixel pair preserves the current lattice; a nonzero pair
 * sets exact cell pixels. Mouse pixel coordinates must be supplied as a pair. */
enum hsc_key_action { HSC_KEY_PRESS=1, HSC_KEY_REPEAT=2, HSC_KEY_RELEASE=3 };
enum hsc_focus { HSC_FOCUS_IN=1, HSC_FOCUS_OUT=2 };
enum hsc_modifier { HSC_MOD_SHIFT=1, HSC_MOD_ALT=2, HSC_MOD_CONTROL=4,
    HSC_MOD_SUPER=8, HSC_MOD_HYPER=16, HSC_MOD_META=32,
    HSC_MOD_CAPS_LOCK=64, HSC_MOD_NUM_LOCK=128 };
enum hsc_mouse_kind { HSC_MOUSE_PRESS=1, HSC_MOUSE_RELEASE=2,
    HSC_MOUSE_MOVE=3, HSC_MOUSE_WHEEL=4 };
enum hsc_mouse_button { HSC_MOUSE_NONE=0, HSC_MOUSE_LEFT=1, HSC_MOUSE_MIDDLE=2,
    HSC_MOUSE_RIGHT=3, HSC_MOUSE_WHEEL_UP=4, HSC_MOUSE_WHEEL_DOWN=5 };
enum hsc_signal { HSC_SIGNAL_HANGUP=1, HSC_SIGNAL_INTERRUPT=2,
    HSC_SIGNAL_RESIZE_NOTIFY=3, HSC_SIGNAL_KILL=9, HSC_SIGNAL_TERMINATE=15 };
enum hsc_key_name {
    HSC_KEY_ENTER=1,
    HSC_KEY_TAB=2,
    HSC_KEY_BACKSPACE=3,
    HSC_KEY_ESCAPE=4,
    HSC_KEY_UP=5,
    HSC_KEY_DOWN=6,
    HSC_KEY_LEFT=7,
    HSC_KEY_RIGHT=8,
    HSC_KEY_INSERT=9,
    HSC_KEY_DELETE=10,
    HSC_KEY_HOME=11,
    HSC_KEY_END=12,
    HSC_KEY_PAGE_UP=13,
    HSC_KEY_PAGE_DOWN=14,
    HSC_KEY_LEFT_SHIFT=15,
    HSC_KEY_RIGHT_SHIFT=16,
    HSC_KEY_LEFT_CONTROL=17,
    HSC_KEY_RIGHT_CONTROL=18,
    HSC_KEY_LEFT_ALT=19,
    HSC_KEY_RIGHT_ALT=20,
    HSC_KEY_LEFT_SUPER=21,
    HSC_KEY_RIGHT_SUPER=22,
    HSC_KEY_LEFT_HYPER=23,
    HSC_KEY_RIGHT_HYPER=24,
    HSC_KEY_LEFT_META=25,
    HSC_KEY_RIGHT_META=26,
    HSC_KEY_CAPS_LOCK=27,
    HSC_KEY_NUM_LOCK=28,
    HSC_KEY_F1=29,
    HSC_KEY_F2=30,
    HSC_KEY_F3=31,
    HSC_KEY_F4=32,
    HSC_KEY_F5=33,
    HSC_KEY_F6=34,
    HSC_KEY_F7=35,
    HSC_KEY_F8=36,
    HSC_KEY_F9=37,
    HSC_KEY_F10=38,
    HSC_KEY_F11=39,
    HSC_KEY_F12=40,
    HSC_KEY_KEYPAD_0=41,
    HSC_KEY_KEYPAD_1=42,
    HSC_KEY_KEYPAD_2=43,
    HSC_KEY_KEYPAD_3=44,
    HSC_KEY_KEYPAD_4=45,
    HSC_KEY_KEYPAD_5=46,
    HSC_KEY_KEYPAD_6=47,
    HSC_KEY_KEYPAD_7=48,
    HSC_KEY_KEYPAD_8=49,
    HSC_KEY_KEYPAD_9=50,
    HSC_KEY_KEYPAD_DECIMAL=51,
    HSC_KEY_KEYPAD_ADD=52,
    HSC_KEY_KEYPAD_SUBTRACT=53,
    HSC_KEY_KEYPAD_MULTIPLY=54,
    HSC_KEY_KEYPAD_DIVIDE=55,
    HSC_KEY_KEYPAD_SEPARATOR=56,
    HSC_KEY_KEYPAD_EQUAL=57,
    HSC_KEY_KEYPAD_ENTER=58,
};
uint32_t hsc_abi_version(void);
uint32_t hsc_interrupt_create(uint32_t version, hsc_interrupt **out);
uint32_t hsc_interrupt_cancel(hsc_interrupt *interrupt);
void hsc_interrupt_release(hsc_interrupt **slot);
uint32_t hsc_control_open(uint32_t version, const uint8_t *endpoint, size_t length,
    hsc_interrupt *interrupt, hsc_control **out);
void hsc_control_release(hsc_control **slot);
uint32_t hsc_control_status(hsc_control *, hsc_server_status *);
uint32_t hsc_control_tree(hsc_control *, uint64_t after_revision, hsc_tree **out);
void hsc_tree_release(hsc_tree **slot);
uint32_t hsc_tree_status(const hsc_tree *, hsc_server_status *);
uint32_t hsc_tree_session(const hsc_tree *, size_t index, hsc_session *);
uint32_t hsc_tree_instance(const hsc_tree *, size_t session, size_t instance, hsc_instance *);
uint32_t hsc_session_create(hsc_control *, const uint8_t *name, size_t length, uint64_t *out);
uint32_t hsc_session_close(hsc_control *, uint64_t session);
uint32_t hsc_instance_create(hsc_control *, const hsc_launch *, hsc_identity *out);
uint32_t hsc_instance_close(hsc_control *, hsc_identity);
uint32_t hsc_attachment_open(uint32_t version, const uint8_t *endpoint, size_t length,
    uint64_t server, uint64_t session, uint64_t instance,
    hsc_interrupt *interrupt, hsc_attachment **out);
void hsc_attachment_release(hsc_attachment **slot);
uint32_t hsc_attachment_identity(const hsc_attachment *, hsc_ready *);
uint32_t hsc_text(hsc_attachment *, const uint8_t *bytes, size_t length, uint32_t paste);
/* Stable semantic vocabulary; input encoding remains in the Server-side VT. */
uint32_t hsc_named_key(hsc_attachment *, uint32_t key, uint32_t action, uint32_t modifiers);
uint32_t hsc_unicode_key(hsc_attachment *, uint32_t scalar, uint32_t action, uint32_t modifiers);
uint32_t hsc_focus(hsc_attachment *, uint32_t focus);
uint32_t hsc_interaction(hsc_attachment *, hvt_interaction *out);
/* Request views own immutable body storage independent of the connection.
 * Opening/observing never claims authority. Acquire is explicit for this exact
 * attachment; closing it clears authority only if it still owns it.
 * Named replies encode Server framing privately; caller supplies native facts.
 * Complete server rejections preserve the stream; malformed/incomplete replies
 * retire it. No reconnect, worker, clock or platform handler is introduced. */
uint32_t hsc_request_acquire(hsc_attachment *);
uint32_t hsc_request_observe(hsc_attachment *, hsc_request_view **out);
void hsc_request_view_release(hsc_request_view **owner);
uint32_t hsc_request_view_info(const hsc_request_view *, hsc_request_info *out);
uint32_t hsc_request_view_payload(const hsc_request_view *, const uint8_t **out, size_t *length);
uint32_t hsc_request_consume(hsc_attachment *, uint64_t occurrence_id);
uint32_t hsc_reply_clipboard(hsc_attachment *, uint64_t occurrence_id, const uint8_t *bytes, size_t length);
uint32_t hsc_reply_pointer_shape(hsc_attachment *, uint64_t occurrence_id, const uint8_t *bytes, size_t length);
uint32_t hsc_reply_color_preference(hsc_attachment *, uint64_t occurrence_id, uint32_t preference);
uint32_t hsc_reply_container_state(hsc_attachment *, uint64_t occurrence_id, uint32_t state);
uint32_t hsc_reply_container_position(hsc_attachment *, uint64_t occurrence_id, uint32_t x, uint32_t y);
uint32_t hsc_reply_container_screen_cells(hsc_attachment *, uint64_t occurrence_id, uint32_t rows, uint32_t columns);
uint32_t hsc_reply_container_icon_title(hsc_attachment *, uint64_t occurrence_id, const uint8_t *bytes, size_t length);
uint32_t hsc_decline_container(hsc_attachment *, uint64_t occurrence_id);
uint32_t hsc_resize(hsc_attachment *, uint16_t rows, uint16_t columns, uint32_t acquire_leadership);
uint32_t hsc_signal(hsc_attachment *, uint32_t signal);
uint32_t hsc_mouse_input(hsc_attachment *, const hsc_mouse *);
uint32_t hsc_resize_geometry(hsc_attachment *, const hsc_geometry *, uint32_t acquire_leadership);
/* after_revision=0 requests immediate complete observation. Snapshot output is owned.
 * Rows/cells copy into C records; scalar/URI arrays are immutable borrows. */
uint32_t hsc_observe(hsc_attachment *, uint64_t after_revision, uint32_t history_offset, hsc_snapshot **out);
void hsc_snapshot_release(hsc_snapshot **slot);
uint32_t hsc_snapshot_metadata(const hsc_snapshot *, hsc_metadata *);
uint32_t hsc_snapshot_row(const hsc_snapshot *, size_t index, hsc_row *);
uint32_t hsc_snapshot_cells(const hsc_snapshot *, size_t start,
    hsc_cell *buffer, size_t capacity, size_t *written);
uint32_t hsc_snapshot_scalars(const hsc_snapshot *, const uint32_t **out, size_t *length);
uint32_t hsc_snapshot_hyperlink(const hsc_snapshot *, size_t index, hsc_hyperlink *);
uint32_t hsc_snapshot_presentation(const hsc_snapshot *, hsc_presentation *);
uint32_t hsc_snapshot_properties(const hsc_snapshot *, hsc_properties *);
uint32_t hsc_snapshot_graphics(const hsc_snapshot *, hsc_graphics *);
uint32_t hsc_snapshot_image(const hsc_snapshot *, size_t index, hsc_image_identity *);
uint32_t hsc_snapshot_placement(const hsc_snapshot *, size_t index, hsc_placement *);
/* Fetches one exact manifest generation. Image storage is independent of both
 * snapshot and connection; pixel bytes are an immutable RGBA8 borrow. */
uint32_t hsc_image_fetch(hsc_attachment *, uint32_t image_id, uint64_t generation, hsc_image **out);
void hsc_image_release(hsc_image **slot);
uint32_t hsc_image_data(const hsc_image *, hsc_image_identity *, const uint8_t **pixels, size_t *length);
/* Additive v1 native query and reusable observation contracts. */
#define HSC_MAX_SEARCH_QUERY_BYTES HVT_MAX_SEARCH_QUERY_BYTES
#define HSC_MAX_SELECTION_BYTES (1024u * 1024u)
typedef struct hsc_cache hsc_cache;
typedef struct hsc_text_view hsc_text_view;
enum hsc_selection_validity {
    HSC_SELECTION_VALID=1, HSC_SELECTION_CONTEXT_CHANGED=2, HSC_SELECTION_EVICTED=3
};
typedef struct hsc_selection_span {
    uint16_t first, last;
    uint8_t found, reserved[3];
} hsc_selection_span;
enum hsc_change_flags {
    HSC_CHANGED_ROWS_PRESENT=1, HSC_CHANGE_BASE_PRESENT=2, HSC_ROW_SHIFT_PRESENT=4
};
typedef struct hsc_changes {
    uint64_t base_revision;
    uint32_t row_count;
    uint16_t row_shift;
    uint8_t flags, reserved;
} hsc_changes;

/* Pure queries on one immutable snapshot. No request, poll or mutation.
 * Search is exact UTF-8 and row-local. hsc_snapshot_search_row searches exactly
 * one projected row. hsc_snapshot_search begins at start_row and visits viewport
 * rows forward (reverse=0) or backward (reverse=1). Neither operation fetches
 * or pages retained history outside the supplied immutable snapshot.
 * hvt_search_match is a copied coordinate record that remains usable after
 * snapshot release; it conveys no handle or authority.
 * complete=1 names that immutable domain, never all retained history.
 * No substring match crosses a row boundary, including a soft wrap.
 * cut_revision is terminal_revision; scanned_snapshots=1.
 * Range inputs require found=1, positive columns, in-column nonnegative points,
 * binary bank and zero reserved fields. Outputs are initialized before work. */
uint32_t hsc_snapshot_search_row(const hsc_snapshot *, const uint8_t *, size_t,
    uint16_t row, uint16_t column_bound, uint32_t reverse, hvt_search_match *);
uint32_t hsc_snapshot_search(const hsc_snapshot *, const uint8_t *, size_t,
    uint16_t start_row, uint32_t reverse, hvt_search_match *);
uint32_t hsc_snapshot_expand_selection(const hsc_snapshot *, uint32_t kind,
    uint16_t row, uint16_t column, hvt_selection_range *);
uint32_t hsc_snapshot_selection_validity(const hsc_snapshot *,
    const hvt_selection_range *, uint32_t *out);
uint32_t hsc_snapshot_selection_span(const hsc_snapshot *,
    const hvt_selection_range *, uint16_t viewport_row, hsc_selection_span *out);
/* Short output writes no array/bytes and reports the exact required extent;
 * oversized capacity writes only actual extent. URI capacity <= SELECTION_BYTES.
 * Copy results survive snapshot release. No hyperlink has required=0. */
uint32_t hsc_snapshot_row_shapes(const hsc_snapshot *, hvt_row_shape *,
    size_t capacity, size_t *required);
uint32_t hsc_snapshot_copy_hyperlink(const hsc_snapshot *, uint16_t row,
    uint16_t column, uint8_t *, size_t capacity, size_t *required);

/* Canonical live extraction. Null owner slot required; failure preserves it.
 * A complete recognized rejection preserves attachment. Malformed/incomplete
 * responses retire it. Valid result bytes borrow only the independent text view,
 * remain valid after snapshot/cache/attachment release, and are not NUL-terminated.
 * Release is serialized against use and clears the slot; NULL is a no-op. */
uint32_t hsc_selection_extract(hsc_attachment *, const hvt_selection_range *,
    hsc_text_view **out);
uint32_t hsc_text_view_data(const hsc_text_view *, const uint8_t **out, size_t *length);
void hsc_text_view_release(hsc_text_view **);

/* Cache copies the complete accepted ready record (Server/Session/Instance/tree/client); borrows no connection
 * or Interrupt. Different/reconnected attachment is rejected before I/O. Release
 * may follow attachment release. Serialize every use of a cache.
 * Cached observe is one complete synchronous request. Nonzero after must match
 * accepted delivery revision/window; mismatch is pre-I/O INVALID_ARGUMENT.
 * Zero is immediate resync. Returned snapshot is an independent immutable owner.
 * Later cache advance/failure/release never invalidates earlier snapshots.
 * Post-complete projection OOM resets cache and preserves stream: retry with zero.
 * No zero-copy guarantee, implicit reconnect or library thread. */
uint32_t hsc_cache_create(uint32_t version, hsc_attachment *, hsc_cache **out);
void hsc_cache_release(hsc_cache **);
uint32_t hsc_observe_cached(hsc_attachment *, hsc_cache *, uint64_t after_revision,
    uint32_t history_offset, hsc_snapshot **out);
/* Known mask differs from absent mask (all rows potentially changed).
 * base_revision uses delivery revision. Absent fields are zero; row_count is
 * the exact known-mask extent, or zero when absent. Copy mask as 0/1 bytes,
 * all-or-none with required extent; oversized capacity writes only actual rows. */
uint32_t hsc_snapshot_changes(const hsc_snapshot *, hsc_changes *out);
uint32_t hsc_snapshot_changed_rows(const hsc_snapshot *, uint8_t *,
    size_t capacity, size_t *required);

#ifdef __cplusplus
}
#endif
#endif
