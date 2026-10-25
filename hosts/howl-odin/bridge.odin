package main

import "core:c"
import vt_native "../../../howl/mods/howl-vt/bindings/odin"
import server_native "../../mods/server-client/bindings/odin"
import render_native "../../../howl/mods/howl-render/bindings/odin"
import instance_native "../../../howl/mods/howl-instance/bindings/odin"

when ODIN_OS == .Windows {
    foreign import howl_bridge "bridge:howl_odin_bridge.lib"
} else {
    foreign import howl_bridge "bridge:libhowl_odin_bridge.so"
}

@(default_calling_convention="c", link_prefix="howl_odin_bridge_")
foreign howl_bridge {
    version            :: proc() -> u32 ---
    runtime_create :: proc() -> rawptr ---
    runtime_destroy :: proc(runtime: rawptr) ---
    native_local_instance_create :: proc(
        runtime: rawptr,
        shell: [^]u8, shell_len: c.size_t,
        command: [^]u8, command_len: c.size_t,
        cwd: [^]u8, cwd_len: c.size_t,
        rows, columns, history_rows: u16,
        font: [^]u8, font_len: c.size_t,
        italic: [^]u8, italic_len: c.size_t,
        bold: [^]u8, bold_len: c.size_t,
        bold_italic: [^]u8, bold_italic_len: c.size_t,
        fallback: [^]u8, fallback_len: c.size_t,
        secondary_fallback: [^]u8, secondary_fallback_len: c.size_t,
        font_pixels: u16,
        diagnostic: [^]u8, diagnostic_capacity: c.size_t, diagnostic_len: ^c.size_t,
    ) -> u64 ---
    native_local_instance_destroy :: proc(runtime: rawptr, instance_id: u64) -> i32 ---
    native_terminal_claim :: proc(runtime: rawptr, instance_id: u64, diagnostic: [^]u8, diagnostic_capacity: c.size_t, diagnostic_len: ^c.size_t) -> rawptr ---
    native_terminal_release :: proc(handle: rawptr) ---
    native_terminal_service :: proc(handle: rawptr, timestamp_ns: u64) -> i32 ---
    native_terminal_wait :: proc(handle: rawptr, timeout_ms: i32) -> i32 ---
    native_terminal_wake :: proc(handle: rawptr) ---
    native_terminal_request_render :: proc(handle: rawptr) ---
    native_terminal_send_text :: proc(handle: rawptr, bytes: [^]u8, bytes_len: c.size_t) -> i32 ---
    native_terminal_send_paste :: proc(handle: rawptr, bytes: [^]u8, bytes_len: c.size_t) -> i32 ---
    native_terminal_send_named_key :: proc(handle: rawptr, key, action, modifiers: u8) -> i32 ---
    native_terminal_send_unicode_key :: proc(handle: rawptr, scalar: u32, action, modifiers: u8) -> i32 ---
    native_terminal_send_mouse :: proc(handle: rawptr, kind, button, modifiers, buttons_down: u8, row: i32, column: u16, pixels_present: u8, pixel_x, pixel_y: u32) -> i32 ---
    native_terminal_send_focus :: proc(handle: rawptr, focus: u8) -> i32 ---
    native_terminal_send_resize :: proc(handle: rawptr, rows, columns, cell_width, cell_height: u16, claim: u8) -> i32 ---
    native_terminal_selection_expand :: proc(handle: rawptr, kind: u8, history_offset: u32, target_row: i32, target_column: u16, expected_columns: u16, expected_alternate_screen: u8, output: ^Selection_Range_Info) -> i32 ---
    native_terminal_selection_extract :: proc(handle: rawptr, start_row: i32, start_column: u16, end_row: i32, end_column: u16, expected_columns: u16, expected_alternate_screen: u8, output: [^]u8, output_capacity: c.size_t, output_len: ^c.size_t) -> i32 ---
    native_terminal_hyperlink_copy :: proc(handle: rawptr, history_offset: u32, target_row: i32, target_column: u16, expected_columns: u16, expected_alternate_screen: u8, output: [^]u8, output_capacity: c.size_t, output_len: ^c.size_t) -> i32 ---
    native_terminal_search_find :: proc(handle: rawptr, query: [^]u8, query_len: c.size_t, reverse, origin_present: u8, origin_row: i32, origin_column: u16, output: ^Search_Match_Info) -> i32 ---

    native_terminal_request_head :: proc(handle: rawptr, info: ^vt_native.Request_Info) -> i32 ---
    native_terminal_request_consume :: proc(handle: rawptr, occurrence_id: u64) -> i32 ---
    native_terminal_reply_clipboard :: proc(handle: rawptr, occurrence_id: u64, bytes: [^]u8, length: c.size_t) -> i32 ---
    native_terminal_reply_pointer_shape :: proc(handle: rawptr, occurrence_id: u64, bytes: [^]u8, length: c.size_t) -> i32 ---
    native_terminal_reply_color_preference :: proc(handle: rawptr, occurrence_id: u64, preference: u8) -> i32 ---
    native_terminal_reply_container_state :: proc(handle: rawptr, occurrence_id: u64, state: u8) -> i32 ---
    native_terminal_reply_container_position :: proc(handle: rawptr, occurrence_id: u64, x, y: u32) -> i32 ---
    native_terminal_reply_container_screen_cells :: proc(handle: rawptr, occurrence_id: u64, rows, columns: u32) -> i32 ---
    native_terminal_reply_container_icon_title :: proc(handle: rawptr, occurrence_id: u64, bytes: [^]u8, length: c.size_t) -> i32 ---
    native_terminal_decline_container :: proc(handle: rawptr, occurrence_id: u64) -> i32 ---
    native_terminal_copy_error :: proc(handle: rawptr, output: [^]u8, output_capacity: c.size_t, output_len: ^c.size_t) ---
    native_terminal_frame_open :: proc(handle: rawptr) -> rawptr ---
    native_terminal_publish_history :: proc(handle: rawptr, history_offset: u32) -> i32 ---
    native_terminal_reconfigure_presentation :: proc(
        handle: rawptr,
        font: [^]u8, font_len: c.size_t,
        italic: [^]u8, italic_len: c.size_t,
        bold: [^]u8, bold_len: c.size_t,
        bold_italic: [^]u8, bold_italic_len: c.size_t,
        fallback: [^]u8, fallback_len: c.size_t,
        secondary_fallback: [^]u8, secondary_fallback_len: c.size_t,
        font_pixels: u16,
    ) -> i32 ---
    native_canvas_create :: proc(stream: rawptr) -> rawptr ---
    native_canvas_destroy :: proc(handle: rawptr) ---
    native_canvas_prepare :: proc(handle: rawptr) -> i32 ---
    native_canvas_accept :: proc(handle: rawptr) -> i32 ---
    native_canvas_discard :: proc(handle: rawptr) -> i32 ---

    native_canvas_cell_width :: proc(handle: rawptr) -> u16 ---
    native_canvas_cell_height :: proc(handle: rawptr) -> u16 ---

    native_canvas_terminal_revision :: proc(handle: rawptr) -> u64 ---
    native_canvas_history_offset :: proc(handle: rawptr) -> u32 ---
    native_canvas_history_count :: proc(handle: rawptr) -> u32 ---
    native_canvas_history_row_base :: proc(handle: rawptr) -> u32 ---
    native_canvas_alternate_screen :: proc(handle: rawptr) -> u8 ---

    native_canvas_upload_info :: proc(handle: rawptr, index: u32, output: ^Canvas_Resource_Info) -> i32 ---
    native_canvas_removal_info :: proc(handle: rawptr, index: u32, output: ^Canvas_Removal_Info) -> i32 ---
    native_canvas_frame_info :: proc(handle: rawptr, output: ^instance_native.Frame_Info) -> i32 ---
    native_canvas_commands :: proc(handle: rawptr, output: [^]Canvas_Command_Info, capacity: c.size_t) -> i32 ---
    native_canvas_upload_borrow :: proc(handle: rawptr, index: u32, output: ^[^]u8, count: ^c.size_t) -> i32 ---
    native_canvas_copy_error :: proc(handle: rawptr, output: [^]u8, output_capacity: c.size_t, output_len: ^c.size_t) ---
    native_terminal_info_size :: proc() -> u32 ---
    native_terminal_snapshot :: proc(
        handle: rawptr,
        history_offset: u32,
        info: ^Native_Terminal_Info,
        title: [^]u8, title_capacity: c.size_t, title_len: ^c.size_t,
        row_shapes: [^]Native_Row_Shape, row_shape_capacity: c.size_t, row_shape_count: ^c.size_t,
    ) -> i32 ---
    interrupt_create :: proc() -> rawptr ---
    interrupt_cancel :: proc(token: rawptr) -> i32 ---
    interrupt_destroy :: proc(token: rawptr) ---
    create             :: proc(runtime, interrupt: rawptr, route_kind: u8, endpoint: [^]u8, endpoint_len: c.size_t, server_id, session_id, instance_id: u64, diagnostic: [^]u8, diagnostic_capacity: c.size_t, diagnostic_len: ^c.size_t) -> rawptr ---
    destroy            :: proc(handle: rawptr) ---
    consequence_create :: proc(runtime, interrupt: rawptr, route_kind: u8, endpoint: [^]u8, endpoint_len: c.size_t, server_id, session_id, instance_id: u64, diagnostic: [^]u8, diagnostic_capacity: c.size_t, diagnostic_len: ^c.size_t) -> rawptr ---
    consequence_destroy :: proc(handle: rawptr) ---
    consequence_client_id :: proc(handle: rawptr) -> u64 ---
    consequence_acquire :: proc(handle: rawptr) -> i32 ---
    consequence_info_size :: proc() -> u32 ---

    consequence_observe :: proc(handle: rawptr, info: ^Consequence_Info) -> i32 ---
    consequence_consume :: proc(handle: rawptr, generation: u64) -> i32 ---

    consequence_reply_clipboard :: proc(handle: rawptr, occurrence_id: u64, bytes: [^]u8, length: c.size_t) -> i32 ---
    consequence_reply_pointer_shape :: proc(handle: rawptr, occurrence_id: u64, bytes: [^]u8, length: c.size_t) -> i32 ---
    consequence_reply_color_preference :: proc(handle: rawptr, occurrence_id: u64, preference: u8) -> i32 ---
    consequence_reply_container_state :: proc(handle: rawptr, occurrence_id: u64, state: u8) -> i32 ---
    consequence_reply_container_position :: proc(handle: rawptr, occurrence_id: u64, x, y: u32) -> i32 ---
    consequence_reply_container_screen_cells :: proc(handle: rawptr, occurrence_id: u64, rows, columns: u32) -> i32 ---
    consequence_reply_container_icon_title :: proc(handle: rawptr, occurrence_id: u64, bytes: [^]u8, length: c.size_t) -> i32 ---
    consequence_decline_container :: proc(handle: rawptr, occurrence_id: u64) -> i32 ---
    consequence_copy_error :: proc(handle: rawptr, output: [^]u8, output_capacity: c.size_t, output_len: ^c.size_t) ---
    snapshot           :: proc(handle: rawptr, after_revision: u64, history_offset: u32) -> i32 ---
    snapshot_take_rich_loan :: proc(handle: rawptr) -> rawptr ---
    snapshot_release_rich_loan :: proc(handle: rawptr) ---
    snapshot_take_view :: proc(handle: rawptr) -> rawptr ---
    view_destroy       :: proc(view: rawptr) ---
    snapshot_title     :: proc(handle: rawptr, output: [^]u8, capacity: c.size_t) -> c.size_t ---
    snapshot_progress  :: proc(handle: rawptr) -> u16 ---
    search_find        :: proc(handle: rawptr, query: [^]u8, query_len: c.size_t, reverse, origin_present: u8, origin_row: i32, origin_column: u16, output: ^Search_Match_Info) -> i32 ---
    search_match_info_size :: proc() -> u32 ---
    selection_expand   :: proc(handle: rawptr, kind: u8, history_offset: u32, target_row: i32, target_column: u16, expected_columns: u16, expected_alternate_screen: u8, output: ^Selection_Range_Info) -> i32 ---
    hyperlink_copy     :: proc(handle: rawptr, history_offset: u32, target_row: i32, target_column: u16, expected_columns: u16, expected_alternate_screen: u8, output: [^]u8, output_capacity: c.size_t, output_len: ^c.size_t) -> i32 ---
    selection_range_info_size :: proc() -> u32 ---
    interaction_state :: proc(handle: rawptr, output: ^Interaction_State_Info) -> i32 ---
    interaction_state_info_size :: proc() -> u32 ---
    send_text          :: proc(handle: rawptr, bytes: [^]u8, bytes_len: c.size_t) -> i32 ---
    send_paste         :: proc(handle: rawptr, bytes: [^]u8, bytes_len: c.size_t) -> i32 ---
    selection_extract  :: proc(handle: rawptr, start_row: i32, start_column: u16, end_row: i32, end_column: u16, expected_columns: u16, expected_alternate_screen: u8, output: [^]u8, output_capacity: c.size_t, output_len: ^c.size_t) -> i32 ---
    send_named_key     :: proc(handle: rawptr, key, action, modifiers: u8) -> i32 ---
    send_unicode_key   :: proc(handle: rawptr, scalar: u32, action, modifiers: u8) -> i32 ---
    send_mouse         :: proc(handle: rawptr, kind, button, modifiers, buttons_down: u8, row: i32, column: u16, pixels_present: u8, pixel_x, pixel_y: u32) -> i32 ---
    send_focus         :: proc(handle: rawptr, focus: u8) -> i32 ---
    send_resize        :: proc(handle: rawptr, rows, columns, cell_width, cell_height: u16, claim: u8) -> i32 ---
    copy_error         :: proc(handle: rawptr, output: [^]u8, output_capacity: c.size_t, output_len: ^c.size_t) ---
    revision           :: proc(handle: rawptr) -> u64 ---
    terminal_revision  :: proc(handle: rawptr) -> u64 ---
    rows               :: proc(handle: rawptr) -> u16 ---
    columns            :: proc(handle: rawptr) -> u16 ---
    cursor_row         :: proc(handle: rawptr) -> u16 ---
    cursor_column      :: proc(handle: rawptr) -> u16 ---
    cursor_visible     :: proc(handle: rawptr) -> u8 ---
    cursor_shape       :: proc(handle: rawptr) -> u8 ---
    alternate_screen   :: proc(handle: rawptr) -> u8 ---
    stream_closed      :: proc(handle: rawptr) -> u8 ---
    child_exited       :: proc(handle: rawptr) -> u8 ---
    history_offset     :: proc(handle: rawptr) -> u32 ---
    history_count      :: proc(handle: rawptr) -> u32 ---
    history_row_base   :: proc(handle: rawptr) -> u32 ---
    render_create      :: proc(runtime, interrupt: rawptr, route_kind: u8, endpoint: [^]u8, endpoint_len: c.size_t, server_id, session_id, instance_id: u64, font: [^]u8, font_len: c.size_t, italic: [^]u8, italic_len: c.size_t, bold: [^]u8, bold_len: c.size_t, bold_italic: [^]u8, bold_italic_len: c.size_t, fallback: [^]u8, fallback_len: c.size_t, secondary_fallback: [^]u8, secondary_fallback_len: c.size_t, font_pixels: u16, diagnostic: [^]u8, diagnostic_capacity: c.size_t, diagnostic_len: ^c.size_t) -> rawptr ---
    render_destroy     :: proc(handle: rawptr) ---
    render_observe     :: proc(handle: rawptr, history_offset: u32) -> i32 ---
    render_prepare :: proc(handle: rawptr, history_offset: u32) -> i32 ---
    render_prepare_view :: proc(handle, snapshot: rawptr) -> i32 ---
    render_prepare_rich_loan :: proc(handle, loan: rawptr) -> i32 ---
    render_accept :: proc(handle: rawptr) ---
    render_discard :: proc(handle: rawptr) ---
    render_background_rgba :: proc(handle: rawptr) -> u32 ---
    render_surface_width  :: proc(handle: rawptr) -> u16 ---
    render_surface_height :: proc(handle: rawptr) -> u16 ---
    render_cell_width     :: proc(handle: rawptr) -> u16 ---
    render_cell_height    :: proc(handle: rawptr) -> u16 ---
    render_maximum_rows   :: proc() -> u16 ---
    render_maximum_columns :: proc() -> u16 ---
    render_frame_revision :: proc(handle: rawptr) -> u64 ---
    render_instance_revision :: proc(handle: rawptr) -> u64 ---
    render_history_offset :: proc(handle: rawptr) -> u32 ---
    render_history_count :: proc(handle: rawptr) -> u32 ---
    render_history_row_base :: proc(handle: rawptr) -> u32 ---
    render_alternate_screen :: proc(handle: rawptr) -> u8 ---
    render_selection_span :: proc(handle: rawptr, anchor_row: i32, anchor_column: u16, focus_row: i32, focus_column: u16, columns: u16, alternate_screen: u8, viewport_row: u16, first, last: ^u16) -> u8 ---
    render_upload_count  :: proc(handle: rawptr) -> u32 ---
    render_removal_count :: proc(handle: rawptr) -> u32 ---
    render_command_count :: proc(handle: rawptr) -> u32 ---
    render_upload_info    :: proc(handle: rawptr, index: u32, output: ^Canvas_Resource_Info) -> i32 ---
    render_upload_copy    :: proc(handle: rawptr, index: u32, output: [^]u8, output_capacity: c.size_t, output_len: ^c.size_t) -> i32 ---
    render_removal_info   :: proc(handle: rawptr, index: u32, output: ^Canvas_Removal_Info) -> i32 ---
    render_command_info   :: proc(handle: rawptr, index: u32, output: ^Canvas_Command_Info) -> i32 ---
    render_copy_error     :: proc(handle: rawptr, output: [^]u8, output_capacity: c.size_t, output_len: ^c.size_t) ---
    render_resource_info_size :: proc() -> u32 ---
    render_removal_info_size  :: proc() -> u32 ---
    render_command_info_size  :: proc() -> u32 ---
    server_tree       :: proc(endpoint: [^]u8, endpoint_len: c.size_t, interrupt: rawptr, output: [^]u8, output_capacity: c.size_t, output_len: ^c.size_t, diagnostic: [^]u8, diagnostic_capacity: c.size_t, diagnostic_len: ^c.size_t) -> i32 ---
}

Native_Terminal_Info :: struct {
    revision: u64,
    terminal_revision: u64,
    history_count: u32,
    history_row_base: u32,
    interaction_flags: u32,
    rows: u16,
    columns: u16,
    cursor_row: u16,
    cursor_column: u16,
    task_progress: u16,
    cursor_shape: u8,
    cursor_visible: u8,
    alternate_screen: u8,
    stream_closed: u8,
    child_exited: u8,
    mouse_tracking: u8,
    mouse_protocol: u8,
    pointer_mode: u8,
    _reserved: [4]u8,
}

Native_Row_Shape :: vt_native.Row_Shape

Bridge_Route_Kind :: enum u8 {
    Server = 1,
    Local = 2,
}

Consequence_Info :: server_native.Request_Info

Search_Match_Info :: vt_native.Search_Match_Info

Selection_Range_Info :: vt_native.Selection_Range_Info

Interaction_State_Info :: vt_native.Interaction_State_Info

INTERACTION_ALT_SCROLL :: u32(1 << 0)
INTERACTION_FOCUS_REPORTING :: u32(1 << 1)

Bridge_Mouse_Kind :: vt_native.Mouse_Kind

Bridge_Mouse_Button :: vt_native.Mouse_Button

Bridge_Focus :: vt_native.Focus

Bridge_Key :: vt_native.Key

Bridge_Key_Action :: vt_native.Key_Action

BRIDGE_MOD_SHIFT :: vt_native.MOD_SHIFT
BRIDGE_MOD_ALT :: vt_native.MOD_ALT
BRIDGE_MOD_CTRL :: vt_native.MOD_CONTROL
BRIDGE_MOD_SUPER :: vt_native.MOD_SUPER
BRIDGE_MOD_CAPS :: vt_native.MOD_CAPS_LOCK
BRIDGE_MOD_NUM :: vt_native.MOD_NUM_LOCK

Canvas_Resource_Info :: render_native.Resource_Info

Canvas_Removal_Info :: render_native.Removal_Info

Canvas_Command_Info :: render_native.Command_Info
