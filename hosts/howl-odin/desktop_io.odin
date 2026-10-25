package main

import instance_native "../../../howl/mods/howl-instance/bindings/odin"

import "core:c"
import vt_native "../../../howl/mods/howl-vt/bindings/odin"
import "core:sync"
import "core:thread"
import "core:time"
import SDL "vendor:sdl3"

// A pane owns one ordered command worker. Admission is not an acknowledgement:
// failures are published explicitly and no queued input is replayed on reconnect.
// Main-thread code never calls a network operation on the control handle.
BRIDGE_QUERY_DECLINED :: i32(6)
CONTROL_QUEUE_LOCAL_REJECTED :: i32(7)
CONTROL_QUEUE_ITEMS :: 128
CONTROL_QUEUE_BYTES :: 128 * 1024
CONTROL_PAYLOAD_BYTES :: 65535

Control_Kind :: enum u8 { Text, Paste, Named, Unicode, Mouse, Focus, Resize, Expand, Extract, Link, Clipboard }
Control_Task :: struct {
    kind: Control_Kind,
    key, action, modifiers, button, buttons, alternate: u8,
    scalar, pixel_x, pixel_y, history: u32,
    row, end_row: i32,
    column, end_column, columns, rows, cell_width, cell_height: u16,
    generation, request: u64,
    payload: []u8,
}
Control_Result :: struct {
    kind: Control_Kind,
    generation, request: u64,
    range: Selection_Range_Info,
    bytes: []u8,
    length: int,
    code: i32,
}

connect_view_channel :: proc(view: ^Instance_View, token: rawptr) -> rawptr {
    endpoint := instance_endpoint(view)
    diagnostic: [160]u8
    count: c.size_t
    handle := create(desktop_io_runtime, token, u8(view.route_kind),
                     raw_data(endpoint), c.size_t(len(endpoint)), view.server_id, view.session_id, view.instance_id,
                     raw_data(diagnostic[:]), c.size_t(len(diagnostic)), &count)
    if handle == nil {
        publish_initial_error(view, string(diagnostic[:int(count)]))
        notify_instance_update()
    }
    return handle
}

Control_Queue_Admission :: enum u8 {
    Accepted,
    Busy,
    Closed,
    Rejected,
}

control_queue_admission_locked :: proc(
    view: ^Instance_View,
    item_count, payload_bytes: int,
) -> Control_Queue_Admission {
    if view == nil || view.worker_stop || view.control_failed || view.io_failed {
        return .Closed
    }
    if item_count <= 0 || payload_bytes < 0 || payload_bytes > CONTROL_QUEUE_BYTES {
        return .Rejected
    }
    if item_count > CONTROL_QUEUE_ITEMS - view.control_count ||
       payload_bytes > CONTROL_QUEUE_BYTES - view.control_bytes {
        return .Busy
    }
    return .Accepted
}

control_queue_append_locked :: proc(view: ^Instance_View, task: Control_Task) {
    index := (view.control_head + view.control_count) % CONTROL_QUEUE_ITEMS
    view.control_tasks[index] = task
    view.control_count += 1
    view.control_bytes += len(task.payload)
    if view.control_notice_len != 0 {
        view.control_notice_len = 0
        view.ui_dirty = true
    }
}

control_queue_push_locked :: proc(view: ^Instance_View, task: Control_Task) -> bool {
    if len(task.payload) > CONTROL_PAYLOAD_BYTES ||
       control_queue_admission_locked(view, 1, len(task.payload)) != .Accepted {
        return false
    }
    control_queue_append_locked(view, task)
    return true
}

control_queue_pop_locked :: proc(view: ^Instance_View) -> (Control_Task, bool) {
    if view.control_count == 0 do return {}, false
    task := view.control_tasks[view.control_head]
    view.control_tasks[view.control_head] = {}
    view.control_head = (view.control_head + 1) % CONTROL_QUEUE_ITEMS
    view.control_count -= 1
    view.control_bytes -= len(task.payload)
    return task, true
}

queue_control :: proc(view: ^Instance_View, task: Control_Task) -> i32 {
    if view == nil || view.control == nil do return 1
    sync.mutex_lock(&view.mutex)
    admission := Control_Queue_Admission.Accepted
    if len(task.payload) > CONTROL_PAYLOAD_BYTES {
        admission = .Rejected
    } else {
        admission = control_queue_admission_locked(view, 1, len(task.payload))
    }
    if admission == .Accepted do control_queue_append_locked(view, task)
    sync.mutex_unlock(&view.mutex)
    switch admission {
    case .Accepted:
        if view.route_kind == .Local && view.native_terminal != nil {
            native_terminal_wake(view.native_terminal)
        } else {
            sync.cond_signal(&view.control_cond)
        }
        return 0
    case .Busy:
        publish_control_notice(view, "Input queue busy; newest operation dropped")
        return CONTROL_QUEUE_LOCAL_REJECTED
    case .Rejected:
        publish_control_notice(view, "Input operation exceeds the bounded queue contract")
        return CONTROL_QUEUE_LOCAL_REJECTED
    case .Closed:
        return 2
    }
    return 2
}

queue_named_key_cycle :: proc(view: ^Instance_View, key, modifiers: u8) -> i32 {
    if view == nil || view.control == nil do return 1
    press := Control_Task{kind = .Named, key = key, action = u8(Bridge_Key_Action.Press), modifiers = modifiers}
    release := Control_Task{kind = .Named, key = key, action = u8(Bridge_Key_Action.Release), modifiers = modifiers}
    sync.mutex_lock(&view.mutex)
    admission := control_queue_admission_locked(view, 2, 0)
    if admission == .Accepted {
        control_queue_append_locked(view, press)
        control_queue_append_locked(view, release)
    }
    sync.mutex_unlock(&view.mutex)
    switch admission {
    case .Accepted:
        if view.route_kind == .Local && view.native_terminal != nil {
            native_terminal_wake(view.native_terminal)
        } else {
            sync.cond_signal(&view.control_cond)
        }
        return 0
    case .Busy:
        publish_control_notice(view, "Input queue busy; scroll cycle dropped")
        return CONTROL_QUEUE_LOCAL_REJECTED
    case .Rejected:
        return CONTROL_QUEUE_LOCAL_REJECTED
    case .Closed:
        return 2
    }
    return 2
}

control_queue_result_failed :: proc(view: ^Instance_View, result: i32) -> bool {
    if result == 0 do return false
    if result != CONTROL_QUEUE_LOCAL_REJECTED do copy_bridge_error(view)
    return true
}

queue_text :: proc(view: ^Instance_View, data: [^]u8, length: c.size_t, paste: bool = false) -> i32 {
    if length == 0 do return 0
    if length > CONTROL_PAYLOAD_BYTES {
        publish_control_notice(view, "Input text exceeds the bounded queue contract")
        return CONTROL_QUEUE_LOCAL_REJECTED
    }
    bytes := make([]u8, int(length))
    if bytes == nil do return 2
    copy(bytes, data[:int(length)])
    result := queue_control(view, Control_Task{kind = paste ? .Paste : .Text, payload = bytes})
    if result != 0 do delete(bytes)
    return result
}

queue_named_key :: proc(view: ^Instance_View, key, action, modifiers: u8) -> i32 {
    return queue_control(view, {kind = .Named, key = key, action = action, modifiers = modifiers})
}
queue_unicode_key :: proc(view: ^Instance_View, scalar: u32, action, modifiers: u8) -> i32 {
    return queue_control(view, {kind = .Unicode, scalar = scalar, action = action, modifiers = modifiers})
}
queue_mouse :: proc(view: ^Instance_View, kind, button, modifiers, buttons: u8, row: i32, column: u16, pixels: u8, x, y: u32) -> i32 {
    return queue_control(view, {kind = .Mouse, action = kind, button = button, modifiers = modifiers,
                               buttons = buttons, row = row, column = column, alternate = pixels, pixel_x = x, pixel_y = y})
}
queue_focus :: proc(view: ^Instance_View, focus: u8) -> i32 {
    return queue_control(view, {kind = .Focus, action = focus})
}

execute_control :: proc(handle: rawptr, task: Control_Task, result: ^Control_Result) -> i32 {
    switch task.kind {
    case .Text: return send_text(handle, raw_data(task.payload), c.size_t(len(task.payload)))
    case .Paste: return send_paste(handle, raw_data(task.payload), c.size_t(len(task.payload)))
    case .Named: return send_named_key(handle, task.key, task.action, task.modifiers)
    case .Unicode: return send_unicode_key(handle, task.scalar, task.action, task.modifiers)
    case .Mouse: return send_mouse(handle, task.action, task.button, task.modifiers, task.buttons, task.row, task.column, task.alternate, task.pixel_x, task.pixel_y)
    case .Clipboard: return 1 // Serialized platform handoff is handled before this dispatcher.
    case .Focus: return send_focus(handle, task.action)
    case .Resize: return send_resize(handle, task.rows, task.columns, task.cell_width, task.cell_height, task.action)
    case .Expand:
        return selection_expand(handle, task.action, task.history, task.row, task.column, task.columns, task.alternate, &result.range)
    case .Extract, .Link:
        capacity := task.kind == .Extract ? SELECTION_TEXT_BYTES : HYPERLINK_URI_BYTES
        result.bytes = make([]u8, capacity + 1)
        if result.bytes == nil do return 3
        count: c.size_t
        code: i32
        if task.kind == .Extract {
            code = selection_extract(handle, task.row, task.column, task.end_row, task.end_column,
                                     task.columns, task.alternate, raw_data(result.bytes), c.size_t(capacity), &count)
        } else {
            code = hyperlink_copy(handle, task.history, task.row, task.column, task.columns, task.alternate,
                                  raw_data(result.bytes), c.size_t(capacity), &count)
        }
        result.length = int(count)
        result.bytes[result.length] = 0
        return code
    }
    return 1
}


copy_native_terminal_error :: proc(handle: rawptr, output: ^[160]u8, output_len: ^int) {
    output_len^ = 0
    if handle == nil do return
    count: c.size_t
    native_terminal_copy_error(
        handle,
        raw_data(output[:]),
        c.size_t(len(output)),
        &count,
    )
    output_len^ = min(int(count), len(output))
}

execute_native_control :: proc(handle: rawptr, task: Control_Task, result: ^Control_Result) -> i32 {
    switch task.kind {
    case .Text:
        return native_terminal_send_text(handle, raw_data(task.payload), c.size_t(len(task.payload)))
    case .Paste:
        return native_terminal_send_paste(handle, raw_data(task.payload), c.size_t(len(task.payload)))
    case .Named:
        return native_terminal_send_named_key(handle, task.key, task.action, task.modifiers)
    case .Unicode:
        return native_terminal_send_unicode_key(handle, task.scalar, task.action, task.modifiers)
    case .Mouse:
        return native_terminal_send_mouse(
            handle,
            task.action,
            task.button,
            task.modifiers,
            task.buttons,
            task.row,
            task.column,
            task.alternate,
            task.pixel_x,
            task.pixel_y,
        )
    case .Focus:
        return native_terminal_send_focus(handle, task.action)
    case .Resize:
        return native_terminal_send_resize(
            handle,
            task.rows,
            task.columns,
            task.cell_width,
            task.cell_height,
            task.action,
        )
    case .Expand:
        return native_terminal_selection_expand(
            handle,
            task.action,
            task.history,
            task.row,
            task.column,
            task.columns,
            task.alternate,
            &result.range,
        )
    case .Extract, .Link:
        capacity := task.kind == .Extract ? SELECTION_TEXT_BYTES : HYPERLINK_URI_BYTES
        result.bytes = make([]u8, capacity + 1)
        if result.bytes == nil do return 3
        count: c.size_t
        code: i32
        if task.kind == .Extract {
            code = native_terminal_selection_extract(
                handle,
                task.row,
                task.column,
                task.end_row,
                task.end_column,
                task.columns,
                task.alternate,
                raw_data(result.bytes),
                c.size_t(capacity),
                &count,
            )
        } else {
            code = native_terminal_hyperlink_copy(
                handle,
                task.history,
                task.row,
                task.column,
                task.columns,
                task.alternate,
                raw_data(result.bytes),
                c.size_t(capacity),
                &count,
            )
        }
        result.length = int(count)
        result.bytes[result.length] = 0
        return code
    case .Clipboard:
        return 1
    }
    return 1
}

publish_native_control_failure :: proc(view: ^Instance_View, handle: rawptr, prefix: string = "") {
    if view == nil || handle == nil do return
    message: [160]u8
    count := 0
    copy_native_terminal_error(handle, &message, &count)
    if count == 0 {
        fallback := "native_terminal_failed"
        count = min(len(fallback), len(message))
        copy(message[:count], transmute([]u8)fallback[:count])
    }
    sync.mutex_lock(&view.mutex)
    if len(prefix) == 0 {
        n := min(count, len(view.error))
        copy(view.error[:n], message[:n])
        view.error_len = n
    } else {
        p := min(len(prefix), len(view.error))
        copy(view.error[:p], transmute([]u8)prefix[:p])
        n := min(count, len(view.error) - p)
        copy(view.error[p:p+n], message[:n])
        view.error_len = p + n
    }
    view.ui_dirty = true
    sync.mutex_unlock(&view.mutex)
}

apply_native_snapshot :: proc(view: ^Instance_View, handle: rawptr, history_offset: u32) -> bool {
    if view == nil || handle == nil do return false
    info: Native_Terminal_Info
    title: [1024]u8
    title_len: c.size_t
    row_shape_count: c.size_t
    rc := native_terminal_snapshot(
        handle,
        history_offset,
        &info,
        raw_data(title[:]),
        c.size_t(len(title)),
        &title_len,
        raw_data(view.native_row_shapes_scratch),
        c.size_t(len(view.native_row_shapes_scratch)),
        &row_shape_count,
    )
    if rc != 0 {
        publish_native_control_failure(view, handle)
        sync.mutex_lock(&view.mutex)
        view.io_failed = true
        view.control_failed = true
        sync.mutex_unlock(&view.mutex)
        return false
    }

    interaction := Interaction_State_Info{
        terminal_revision = info.terminal_revision,
        flags = info.interaction_flags,
        mouse_tracking = info.mouse_tracking,
        mouse_protocol = info.mouse_protocol,
        pointer_mode = info.pointer_mode,
    }
    sync.mutex_lock(&view.mutex)
    changed := view.revision != info.revision ||
               view.terminal_revision != info.terminal_revision ||
               view.rows != info.rows ||
               view.columns != info.columns ||
               view.cursor_row != info.cursor_row ||
               view.cursor_column != info.cursor_column ||
               view.cursor_visible != (info.cursor_visible != 0) ||
               view.cursor_shape != info.cursor_shape ||
               view.history_count != info.history_count ||
               view.history_row_base != info.history_row_base ||
               view.alternate_screen != (info.alternate_screen != 0) ||
               view.stream_closed != (info.stream_closed != 0) ||
               view.child_exited != (info.child_exited != 0) ||
               view.task_progress != info.task_progress ||
               view.display_title_len != int(title_len) ||
               string(view.display_title[:view.display_title_len]) != string(title[:int(title_len)])

    validate_selection_context_locked(
        view,
        info.columns,
        info.rows,
        info.history_count,
        info.history_row_base,
        info.alternate_screen != 0,
    )
    apply_history_geometry_locked(view, info.columns)
    view.interaction_state = interaction
    view.interaction_state_valid = true
    view.revision = info.revision
    view.terminal_revision = info.terminal_revision
    view.rows = info.rows
    view.columns = info.columns
    view.cursor_row = info.cursor_row
    view.cursor_column = info.cursor_column
    view.cursor_visible = info.cursor_visible != 0
    view.cursor_shape = info.cursor_shape
    follow_history_locked(
        view,
        info.history_count,
        info.history_row_base,
        info.alternate_screen != 0,
    )
    view.history_count = info.history_count
    view.history_row_base = info.history_row_base
    view.alternate_screen = info.alternate_screen != 0
    view.stream_closed = info.stream_closed != 0
    view.child_exited = info.child_exited != 0
    copy(view.display_title[:int(title_len)], title[:int(title_len)])
    view.display_title_len = int(title_len)
    view.task_progress = info.task_progress
    view.native_row_shape_count = int(row_shape_count)
    copy(
        view.native_row_shapes[:view.native_row_shape_count],
        view.native_row_shapes_scratch[:view.native_row_shape_count],
    )
    view.native_row_shape_terminal_revision = info.terminal_revision
    if info.alternate_screen != 0 {
        view.native_row_shape_history_offset = 0
    } else {
        view.native_row_shape_history_offset = min(history_offset, info.history_count)
    }
    view.ui_dirty = view.ui_dirty || changed
    if !view.control_failed && !view.io_failed do view.error_len = 0
    validate_search_result_locked(view)
    sync.mutex_unlock(&view.mutex)
    return changed
}

process_native_search :: proc(view: ^Instance_View, handle: rawptr) -> bool {
    local_query: [SEARCH_QUERY_BYTES]u8
    sync.mutex_lock(&view.mutex)
    if !view.search_pending || view.search_running {
        sync.mutex_unlock(&view.mutex)
        return false
    }
    generation := view.search_generation
    query_len := view.search_query_len
    copy(local_query[:query_len], view.search_query[:query_len])
    reverse := view.search_reverse
    origin_present := view.search_origin_present
    origin_row := view.search_origin_row
    origin_column := view.search_origin_column
    view.search_pending = false
    view.search_running = true
    view.search_running_generation = generation
    sync.mutex_unlock(&view.mutex)

    result: Search_Match_Info
    rc := native_terminal_search_find(
        handle,
        raw_data(local_query[:]),
        c.size_t(query_len),
        reverse ? u8(1) : u8(0),
        origin_present ? u8(1) : u8(0),
        origin_row,
        origin_column,
        &result,
    )
    error_message: [160]u8
    error_len := 0
    if rc != 0 do copy_native_terminal_error(handle, &error_message, &error_len)

    sync.mutex_lock(&view.mutex)
    view.search_running = false
    view.ui_dirty = true
    if !view.worker_stop && generation == view.search_generation {
        view.search_last_reverse = reverse
        view.search_last_complete = rc == 0 && result.complete != 0
        view.search_error_len = 0
        if rc != 0 {
            count := min(error_len, len(view.search_error))
            copy(view.search_error[:count], error_message[:count])
            view.search_error_len = count
            view.search_state = .Error
            view.search_failed = true
        } else if result.found == 0 {
            view.search_state = .Not_Found
        } else if apply_search_result_locked(view, result) {
            view.search_state = .Found
        } else {
            message := "search_result_stale"
            copy(view.search_error[:len(message)], transmute([]u8)message)
            view.search_error_len = len(message)
            view.search_state = .Error
            view.search_result_active = false
        }
    }
    sync.mutex_unlock(&view.mutex)
    notify_instance_update()
    return true
}

process_native_presentation :: proc(view: ^Instance_View, handle: rawptr) -> bool {
    if view == nil || handle == nil do return false
    sync.mutex_lock(&view.mutex)
    request, admitted := begin_native_presentation(&view.native_presentation)
    if !admitted {
        sync.mutex_unlock(&view.mutex)
        return false
    }
    sync.mutex_unlock(&view.mutex)

    code := native_terminal_reconfigure_presentation(
        handle,
        raw_data(request.font[:request.font_len]), c.size_t(request.font_len),
        raw_data(request.italic[:request.italic_len]), c.size_t(request.italic_len),
        raw_data(request.bold[:request.bold_len]), c.size_t(request.bold_len),
        raw_data(request.bold_italic[:request.bold_italic_len]), c.size_t(request.bold_italic_len),
        raw_data(request.fallback[:request.fallback_len]), c.size_t(request.fallback_len),
        raw_data(request.secondary_fallback[:request.secondary_fallback_len]), c.size_t(request.secondary_fallback_len),
        request.font_pixels,
    )

    sync.mutex_lock(&view.mutex)
    current := finish_native_presentation(
        &view.native_presentation,
        request.generation,
        code,
    )
    if current {
        view.ui_dirty = true
    }
    sync.mutex_unlock(&view.mutex)
    if code != 0 && current {
        message: [160]u8
        count := 0
        copy_native_terminal_error(handle, &message, &count)
        if count != 0 {
            publish_control_notice(view, string(message[:count]))
        } else {
            publish_control_notice(view, "Terminal presentation reconfigure failed")
        }
    }
    notify_instance_update()
    return true
}

process_native_consequences :: proc(view: ^Instance_View, handle: rawptr) -> bool {
    if view == nil || handle == nil do return false
    changed := false
    for {
        info: vt_native.Request_Info
        if native_terminal_request_head(handle, &info) != 0 {
            publish_control_notice(view, "Host consequence policy observation failed")
            return changed
        }
        if vt_native.Request_Kind(info.kind) == .None do return changed
        action := request_action_for(info)
        ok := true
        switch action {
        case .Consume:
            ok = native_terminal_request_consume(handle, info.occurrence_id) == 0
        case .Attention:
            ok = native_terminal_request_consume(handle, info.occurrence_id) == 0
            if ok {
                sync.mutex_lock(&view.mutex)
                view.native_attention_pending = true
                view.ui_dirty = true
                sync.mutex_unlock(&view.mutex)
                notify_instance_update()
            }
        case .Reply_Clipboard_Empty:
            dummy: [1]u8
            ok = native_terminal_reply_clipboard(handle, info.occurrence_id, raw_data(dummy[:]), 0) == 0
        case .Reply_Pointer_Default:
            body := []u8{'d','e','f','a','u','l','t'}
            ok = native_terminal_reply_pointer_shape(handle, info.occurrence_id, raw_data(body), c.size_t(len(body))) == 0
        case .Reply_Color_Dark:
            ok = native_terminal_reply_color_preference(handle, info.occurrence_id, u8(vt_native.Color_Preference.Dark)) == 0
        case .Reply_Container_Screen:
            sync.mutex_lock(&view.mutex)
            rows, columns := view.rows, view.columns
            sync.mutex_unlock(&view.mutex)
            ok = native_terminal_reply_container_screen_cells(handle, info.occurrence_id, u32(rows), u32(columns)) == 0
        case .Reply_Container_Decline:
            ok = native_terminal_decline_container(handle, info.occurrence_id) == 0
        }
        if !ok {
            publish_control_notice(view, "Host consequence policy failed")
            return changed
        }
        changed = true
    }
}

process_native_control :: proc(view: ^Instance_View, handle: rawptr) -> (worked: bool, fatal: bool) {
    sync.mutex_lock(&view.mutex)
    if view.control_count == 0 || view.control_result_ready {
        sync.mutex_unlock(&view.mutex)
        return false, false
    }
    task, ok := control_queue_pop_locked(view)
    sync.mutex_unlock(&view.mutex)
    if !ok do return false, false

    if task.kind == .Resize {
        sync.mutex_lock(&view.mutex)
        current := size_task_current(&view.size_control, task)
        if !current {
            view.size_control.pending = false
            view.ui_dirty = true
        }
        sync.mutex_unlock(&view.mutex)
        if !current {
            if task.payload != nil do delete(task.payload)
            notify_instance_update()
            return true, false
        }
    }

    result := Control_Result{kind = task.kind, generation = task.generation, request = task.request}
    clipboard_failed := false
    if task.kind == .Clipboard {
        sync.mutex_lock(&view.mutex)
        view.control_result = result
        view.control_result_ready = true
        sync.mutex_unlock(&view.mutex)
        notify_instance_update()
        sync.mutex_lock(&view.mutex)
        for !view.worker_stop && view.control_result_ready do sync.cond_wait(&view.control_cond, &view.mutex)
        reply := view.clipboard_reply
        view.clipboard_reply = nil
        reply_code := view.clipboard_reply_code
        stopped := view.worker_stop
        sync.mutex_unlock(&view.mutex)
        if stopped {
            if reply != nil do delete(reply)
            if task.payload != nil do delete(task.payload)
            return true, true
        }
        if reply_code != 0 {
            clipboard_failed = true
            result.code = BRIDGE_QUERY_DECLINED
            publish_control_notice(view, "Paste not sent: preceding copy did not complete")
        } else if len(reply) != 0 {
            result.code = native_terminal_send_paste(handle, raw_data(reply), c.size_t(len(reply)))
        }
        if reply != nil do delete(reply)
    } else {
        result.code = execute_native_control(handle, task, &result)
    }
    if task.payload != nil do delete(task.payload)

    size_result_current := true
    if task.kind == .Resize {
        sync.mutex_lock(&view.mutex)
        size_result_current = size_task_current(&view.size_control, task)
        _ = finish_size_task(&view.size_control, task, result.code)
        view.ui_dirty = true
        sync.mutex_unlock(&view.mutex)
        notify_instance_update()
    }

    failed_fatal := control_failure_is_fatal(task.kind, result.code)
    if result.code != 0 && !failed_fatal && !clipboard_failed && size_result_current {
        if task.kind == .Resize {
            publish_control_notice(view, "Instance rejected the size; auto-sizing stopped here")
        } else {
            message: [160]u8
            count := 0
            copy_native_terminal_error(handle, &message, &count)
            if count != 0 do publish_control_notice(view, string(message[:count]))
        }
    }
    if failed_fatal {
        if !clipboard_failed {
            prefix := ""
            if task.kind != .Expand && task.kind != .Extract && task.kind != .Link {
                prefix = "Input failed/unconfirmed; not replayed: "
            }
            publish_native_control_failure(
                view,
                handle,
                prefix,
            )
        }
        sync.mutex_lock(&view.mutex)
        view.control_failed = true
        sync.mutex_unlock(&view.mutex)
    }
    if task.kind == .Expand || task.kind == .Extract || task.kind == .Link {
        sync.mutex_lock(&view.mutex)
        view.control_result = result
        view.control_result_ready = true
        sync.mutex_unlock(&view.mutex)
        notify_instance_update()
    }
    return true, failed_fatal
}

native_terminal_instance :: proc(data: rawptr) {
    view := (^Instance_View)(data)
    diagnostic: [160]u8
    count: c.size_t
    handle := native_terminal_claim(
        desktop_io_runtime,
        view.instance_id,
        raw_data(diagnostic[:]),
        c.size_t(len(diagnostic)),
        &count,
    )
    if handle == nil {
        sync.mutex_lock(&view.mutex)
        view.control_connect_done = true
        view.control_connect_applied = true
        view.control_failed = true
        view.io_failed = true
        n := min(int(count), len(view.error))
        copy(view.error[:n], diagnostic[:n])
        view.error_len = n
        view.ui_dirty = true
        sync.mutex_unlock(&view.mutex)
        notify_instance_update()
        return
    }
    sync.mutex_lock(&view.mutex)
    view.native_terminal = handle
    view.control = handle
    view.control_connect_done = true
    view.control_connect_applied = true
    view.control_failed = false
    view.io_failed = false
    sync.mutex_unlock(&view.mutex)
    notify_instance_update()

    defer {
        sync.mutex_lock(&view.mutex)
        view.control = nil
        orphaned := view.native_frame_pending
        view.native_frame_pending = nil
        view.native_terminal = nil
        sync.mutex_unlock(&view.mutex)
        if orphaned != nil do instance_native.frame_close(&orphaned)
        native_terminal_release(handle)
    }

    published_history: u32 = 0
    _ = native_terminal_wait(handle, 0)
    for {
        sync.mutex_lock(&view.mutex)
        stop := view.worker_stop
        requested_history := view.history_target_offset
        sync.mutex_unlock(&view.mutex)
        if stop do break

        worked := false
        if requested_history != published_history {
            if native_terminal_publish_history(handle, requested_history) != 0 {
                publish_native_control_failure(view, handle)
                sync.mutex_lock(&view.mutex)
                view.control_failed = true
                view.io_failed = true
                sync.mutex_unlock(&view.mutex)
                notify_instance_update()
                break
            }
            published_history = requested_history
            worked = true
        }

        sync.mutex_lock(&view.mutex)
        open_frame := view.native_frame_requested
        sync.mutex_unlock(&view.mutex)
        if open_frame {
            endpoint := native_terminal_frame_open(handle)
            sync.mutex_lock(&view.mutex)
            view.native_frame_requested = false
            view.native_frame_pending = endpoint
            view.native_frame_failed = endpoint == nil
            sync.mutex_unlock(&view.mutex)
            notify_instance_update()
            worked = true
        }
        if process_native_presentation(view, handle) do worked = true

        control_worked, fatal := process_native_control(view, handle)
        worked = worked || control_worked
        if fatal do break
        if process_native_search(view, handle) do worked = true
        if process_native_consequences(view, handle) do worked = true

        if worked {
            if native_terminal_wait(handle, 0) != 0 {
                publish_native_control_failure(view, handle)
                break
            }
        }

        sync.mutex_lock(&view.mutex)
        snapshot_history := view.history_target_offset
        sync.mutex_unlock(&view.mutex)
        _ = apply_native_snapshot(view, handle, snapshot_history)
        notify_instance_update()

        if !worked {
            if native_terminal_wait(handle, -1) != 0 {
                sync.mutex_lock(&view.mutex)
                stopped := view.worker_stop
                sync.mutex_unlock(&view.mutex)
                if !stopped do publish_native_control_failure(view, handle)
                break
            }
        }
    }
}

control_instance :: proc(data: rawptr) {
    view := (^Instance_View)(data)
    handle := connect_view_channel(view, view.control_interrupt)
    sync.mutex_lock(&view.mutex)
    view.control_pending_handle = handle
    view.control_connect_done = true
    view.control_failed = handle == nil
    sync.mutex_unlock(&view.mutex)
    notify_instance_update()
    if handle == nil do return
    // Handle remains owned by this pane until main cancels and joins the worker.
    for {
        sync.mutex_lock(&view.mutex)
        for !view.worker_stop && (view.control_count == 0 || view.control_result_ready) {
            sync.cond_wait(&view.control_cond, &view.mutex)
        }
        if view.worker_stop { sync.mutex_unlock(&view.mutex); break }
        task, ok := control_queue_pop_locked(view)
        sync.mutex_unlock(&view.mutex)
        if !ok do continue
        if task.kind == .Resize {
            sync.mutex_lock(&view.mutex)
            current := size_task_current(&view.size_control, task)
            if !current {
                view.size_control.pending = false
                view.ui_dirty = true // A newer Take may now schedule its one task.
            }
            sync.mutex_unlock(&view.mutex)
            if !current { notify_instance_update(); continue }
        }
        result := Control_Result{kind = task.kind, generation = task.generation, request = task.request}
        clipboard_failed := false
        if task.kind == .Clipboard {
            // Paste immediately after asynchronous Copy waits for that exact
            // copy's platform completion, rather than sending the old clipboard.
            sync.mutex_lock(&view.mutex)
            view.control_result = result
            view.control_result_ready = true
            sync.mutex_unlock(&view.mutex)
            notify_instance_update()
            sync.mutex_lock(&view.mutex)
            for !view.worker_stop && view.control_result_ready do sync.cond_wait(&view.control_cond, &view.mutex)
            reply := view.clipboard_reply
            view.clipboard_reply = nil
            reply_code := view.clipboard_reply_code
            stopped := view.worker_stop
            sync.mutex_unlock(&view.mutex)
            if stopped { if reply != nil do delete(reply); break }
            if reply_code != 0 {
                clipboard_failed = true
                result.code = BRIDGE_QUERY_DECLINED
                publish_control_notice(view, "Paste not sent: preceding copy did not complete")
            } else if len(reply) != 0 {
                result.code = send_paste(handle, raw_data(reply), c.size_t(len(reply)))
            }
            if reply != nil do delete(reply)
        } else {
            result.code = execute_control(handle, task, &result)
        }
        if task.payload != nil do delete(task.payload)
        size_result_current := true
        if task.kind == .Resize {
            sync.mutex_lock(&view.mutex)
            size_result_current = size_task_current(&view.size_control, task)
            accepted := finish_size_task(&view.size_control, task, result.code)
            view.ui_dirty = true
            sync.mutex_unlock(&view.mutex)
            if accepted && task.action == 1 && view.ownership == .Attached {
                publish_control_notice(view, "Size control acquired; this pane now resizes the Instance")
            }
            notify_instance_update()
        }
        fatal := control_failure_is_fatal(task.kind, result.code)
        if result.code != 0 && !fatal && !clipboard_failed && size_result_current {
            message: [160]u8
            count: c.size_t
            copy_error(handle, raw_data(message[:]), c.size_t(len(message)), &count)
            if task.kind == .Resize {
                message := "Instance rejected the size; auto-sizing stopped here"
                if result.code == BRIDGE_SIZE_NOT_LEADER do message = "Size control changed; use Take Instance size control to resize again"
                publish_control_notice(view, message)
            } else {
                publish_control_notice(view, string(message[:int(count)]))
            }
        }
        if fatal {
            if !clipboard_failed do publish_bridge_error(view, handle)
            sync.mutex_lock(&view.mutex)
            view.control_failed = true
            // A failed mutating transaction is not permission to replay it.
            // Keep the exact bridge error after an explicit delivery warning.
            if task.kind != .Expand && task.kind != .Extract && task.kind != .Link {
                original := view.error
                original_len := view.error_len
                prefix := "Input failed/unconfirmed; not replayed: "
                count := min(original_len, len(view.error) - len(prefix))
                copy(view.error[:], transmute([]u8)prefix)
                copy(view.error[len(prefix):][:count], original[:count])
                view.error_len = len(prefix) + count
            }
            sync.mutex_unlock(&view.mutex)
        }
        if task.kind == .Expand || task.kind == .Extract || task.kind == .Link {
            sync.mutex_lock(&view.mutex)
            view.control_result = result
            view.control_result_ready = true
            sync.mutex_unlock(&view.mutex)
            notify_instance_update()
        }
        if fatal { notify_instance_update(); break }
    }
}

// Called only by the graphical thread. Result buffers transfer here once; a
// closed/replaced pane cannot deliver a stale clipboard, selection or URL action.
apply_control_completions :: proc(app: ^App) {
    for tab_index in 0..<app.tab_count {
        for view in app.tabs[tab_index].panes {
            if view == nil do continue
            sync.mutex_lock(&view.mutex)
            if view.control_connect_done && !view.control_connect_applied {
                view.control = view.control_pending_handle
                view.control_connect_applied = true
                view.ui_dirty = true
            }
            ready := view.control_result_ready
            result := view.control_result
            current := control_result_current(result.code, result.generation, view.selection_generation, active_instance_view(app) == view)
            copy_current := result.code == 0 && view.copy_pending &&
                            clipboard_request_current(result.request, app.clipboard_request, view.copy_pending_request)
            copied := view.copy_completed && clipboard_request_current(result.request, app.clipboard_request, view.copy_completed_request)
            sync.mutex_unlock(&view.mutex)
            if !ready do continue
            copy_applied := false
            clipboard_reply: []u8
            clipboard_code: i32
            if result.kind == .Clipboard {
                if copied && SDL.HasClipboardText() {
                    if raw := SDL.GetClipboardText(); raw != nil {
                        text := string(cstring(raw))
                        if len(text) <= CONTROL_PAYLOAD_BYTES {
                            clipboard_reply = make([]u8, len(text))
                            copy(clipboard_reply, transmute([]u8)text)
                        } else { clipboard_code = 2 }
                        SDL.free(rawptr(raw))
                    } else { clipboard_code = 2 }
                } else { clipboard_code = 2 }
            } else if result.kind == .Extract {
                if copy_current && result.length > 0 && SDL.SetClipboardText(cstring(raw_data(result.bytes))) {
                    copy_applied = true
                    // Typing or a newer selection can retire the visual range
                    // without changing the earlier explicit Copy request.
                    if current do clear_selection(view)
                }
            } else if current {
                switch result.kind {
                case .Expand: _ = apply_selection_range(view, result.range)
                case .Link:
                    if result.length > 0 do _ = open_platform_browser_uri(string(result.bytes[:result.length]))
                case .Text, .Paste, .Named, .Unicode, .Mouse, .Focus, .Resize, .Clipboard, .Extract:
                }
            }
            if result.bytes != nil do delete(result.bytes)
            sync.mutex_lock(&view.mutex)
            if result.kind == .Extract {
                view.copy_completed = copy_applied
                view.copy_completed_request = result.request
                if view.copy_pending_request == result.request do view.copy_pending = false
            }
            if result.kind == .Clipboard {
                view.clipboard_reply = clipboard_reply
                view.clipboard_reply_code = clipboard_code
            }
            view.control_result = {}
            view.control_result_ready = false
            view.ui_dirty = true
            sync.mutex_unlock(&view.mutex)
            sync.cond_signal(&view.control_cond)
        }
    }
}

control_result_current :: proc(code: i32, result_generation, current_generation: u64, view_is_active: bool) -> bool {
    return code == 0 && result_generation == current_generation && view_is_active
}

// A worker wake can mean only "new work is available". Schedule it and paint
// only a newly accepted frame or changed UI metadata, not the old frame followed
// by the new one. Input/resize/expose events still invalidate normally.
service_desktop_io :: proc(app: ^App) -> bool {
    changed := service_server_browser(app)
    if app.active_tab >= 0 && app.active_tab < app.tab_count {
        width, height: c.int
        _ = SDL.GetWindowSize(app.window, &width, &height)
        tab := &app.tabs[app.active_tab]
        layout := pane_layout(tab, terminal_inset(f32(width), f32(height)))
        for i in 0..<layout.entry_count {
            view := tab_pane_view(tab, layout.entries[i].pane_index)
            if view == nil do continue
            before := view.canvas_instance_revision
            old_history := view.canvas_history_offset
            old_error := view.canvas_error_len
            had_canvas := view.canvas != nil
            _ = update_canvas(app, view)
            changed = changed || before != view.canvas_instance_revision || old_history != view.canvas_history_offset ||
                      old_error != view.canvas_error_len || had_canvas != (view.canvas != nil)
        }
    }
    for i in 0..<app.tab_count {
        for view in app.tabs[i].panes {
            if view == nil do continue
            if i != app.active_tab do _ = release_view_pending_rich_loan(view)
            sync.mutex_lock(&view.mutex)
            changed = changed || view.ui_dirty
            view.ui_dirty = false
            sync.mutex_unlock(&view.mutex)
        }
    }
    return changed
}

// Clipboard requests have their own application-wide order. A visual selection
// can be cleared by later typing, but an older tab's late Copy cannot overwrite
// a newer Copy request from another tab.
clipboard_request_current :: proc(request, newest_request, owned_request: u64) -> bool {
    return request != 0 && request == newest_request && request == owned_request
}

control_failure_is_fatal :: proc(kind: Control_Kind, code: i32) -> bool {
    if code == 0 do return false
    if kind == .Resize && (code == BRIDGE_SIZE_NOT_LEADER || code == BRIDGE_SIZE_REJECTED) do return false
    query := kind == .Expand || kind == .Extract || kind == .Link || kind == .Clipboard
    return !(query && code == BRIDGE_QUERY_DECLINED)
}

publish_control_notice :: proc(view: ^Instance_View, message: string) {
    sync.mutex_lock(&view.mutex)
    view.control_notice_len = min(len(message), len(view.control_notice))
    copy(view.control_notice[:view.control_notice_len], transmute([]u8)message[:view.control_notice_len])
    view.ui_dirty = true
    sync.mutex_unlock(&view.mutex)
    notify_instance_update()
}

draw_control_notice :: proc(app: ^App, view: ^Instance_View, pane: SDL.FRect) {
    sync.mutex_lock(&view.mutex)
    bytes := view.control_notice
    count := view.control_notice_len
    failed := view.io_failed || view.control_failed
    sync.mutex_unlock(&view.mutex)
    if count == 0 || failed do return
    box := SDL.FRect{pane.x + 6, pane.y + pane.h - 28, max(f32(0), pane.w - 22), 22}
    clip := SDL.Rect{c.int(box.x), c.int(box.y), c.int(box.w), c.int(box.h)}
    _ = SDL.SetRenderClipRect(app.renderer, &clip)
    draw_fill(app.renderer, box, palette.title_bg)
    draw_text(app, app.ui_font, string(bytes[:count]), box.x + 5, box.y + 3, palette.text_muted)
    _ = SDL.SetRenderClipRect(app.renderer, nil)
}
