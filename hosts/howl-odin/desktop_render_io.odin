package main

import "core:c"
import "core:sync"
import "core:thread"

MAX_RENDER_WORKS :: MAX_TABS * MAX_PANES_PER_TAB

Render_Offer_Kind :: enum u8 {
    None,
    Owned_View,
    Rich_Loan,
}

// One process render lane services every terminal mailbox serially. Each
// terminal still owns its pending/prepared-frame state and render handle, but
// thread lifetime and scheduling are process-owned.
Render_Dispatcher :: struct {
    worker: ^thread.Thread,
    mutex: sync.Mutex,
    cond: sync.Cond,
    stop: bool,
    works: [MAX_RENDER_WORKS]^Render_Work,
    work_count: int,
    next_index: int,
}

// One pending/prepared frame per terminal. The dispatcher cannot overwrite a
// prepared frame before main acknowledges it.
Render_Work :: struct {
    dispatcher: ^Render_Dispatcher,
    owner_view: ^Instance_View,
    route_kind: Bridge_Route_Kind,
    endpoint: [PROFILE_ENDPOINT_BYTES]u8,
    endpoint_len: int,
    server_id: u64,
    session_id: u64,
    instance_id: u64,
    font, italic, bold, bold_italic: [FONT_PATH_BYTES]u8,
    fallback, secondary: [FONT_PATH_BYTES]u8,
    font_len, italic_len, bold_len, bold_italic_len: int,
    fallback_len, secondary_len: int,
    pixels: u16,
    interrupt: rawptr,
    handle: rawptr,
    offered_view: rawptr,
    offered_kind: Render_Offer_Kind,
    mutex: sync.Mutex,
    cond: sync.Cond,
    stop, suspended, created, failed, pending, ready, busy: bool,
    history: u32,
    history_generation: u64,
    code: i32,
    error: [160]u8,
    error_len: int,
}

next_render_work_locked :: proc(dispatcher: ^Render_Dispatcher) -> ^Render_Work {
    if dispatcher == nil || dispatcher.work_count == 0 do return nil
    // One process scratch lane can back exactly one visible prepared frame. A
    // hidden/suspended work must never pin that lane.
    for index in 0..<dispatcher.work_count {
        work := dispatcher.works[index]
        if work == nil do continue
        sync.mutex_lock(&work.mutex)
        blocked := !work.stop && !work.suspended && work.ready
        sync.mutex_unlock(&work.mutex)
        if blocked do return nil
    }
    // Round-robin prevents one hot visible pane from monopolizing the process
    // lane when several panes are requesting frames.
    start := dispatcher.next_index % dispatcher.work_count
    for offset in 0..<dispatcher.work_count {
        index := (start + offset) % dispatcher.work_count
        work := dispatcher.works[index]
        if work == nil do continue
        sync.mutex_lock(&work.mutex)
        actionable := !work.stop && !work.suspended &&
                      (!work.created || (!work.failed && work.pending && !work.ready && !work.busy))
        if actionable {
            work.busy = true
            dispatcher.next_index = (index + 1) % dispatcher.work_count
            sync.mutex_unlock(&work.mutex)
            return work
        }
        sync.mutex_unlock(&work.mutex)
    }
    return nil
}

create_render_handle :: proc(work: ^Render_Work) {
    diagnostic: [160]u8
    count: c.size_t
    handle := render_create(desktop_io_runtime, work.interrupt, u8(work.route_kind),
                            raw_data(work.endpoint[:]), c.size_t(work.endpoint_len), work.server_id, work.session_id, work.instance_id,
                            raw_data(work.font[:]), c.size_t(work.font_len),
                            raw_data(work.italic[:]), c.size_t(work.italic_len),
                            raw_data(work.bold[:]), c.size_t(work.bold_len),
                            raw_data(work.bold_italic[:]), c.size_t(work.bold_italic_len),
                            raw_data(work.fallback[:]), c.size_t(work.fallback_len),
                            raw_data(work.secondary[:]), c.size_t(work.secondary_len), work.pixels,
                            raw_data(diagnostic[:]), c.size_t(len(diagnostic)), &count)
    sync.mutex_lock(&work.mutex)
    work.handle = handle
    work.created = true
    work.failed = handle == nil
    work.error_len = int(count)
    copy(work.error[:int(count)], diagnostic[:int(count)])
    work.busy = false
    sync.cond_broadcast(&work.cond)
    sync.mutex_unlock(&work.mutex)
    notify_instance_update()
}

release_render_offer :: proc(kind: Render_Offer_Kind, offer: rawptr) {
    if offer == nil do return
    switch kind {
    case .Rich_Loan:
        snapshot_release_rich_loan(offer)
    case .Owned_View:
        view_destroy(offer)
    case .None:
    }
}

complete_render_offer :: proc(work: ^Render_Work, kind: Render_Offer_Kind, offer: rawptr) {
    release_render_offer(kind, offer)
    if kind != .Rich_Loan || work == nil || work.owner_view == nil do return
    owner := work.owner_view
    sync.mutex_lock(&owner.mutex)
    owner.render_offer_outstanding = false
    sync.cond_broadcast(&owner.observer_cond)
    sync.mutex_unlock(&owner.mutex)
}

detach_view_rich_loan_locked :: proc(view: ^Instance_View) -> rawptr {
    if view == nil || view.reusable_view_kind != .Rich_Loan || view.reusable_view == nil do return nil
    loan := view.reusable_view
    view.reusable_view = nil
    view.reusable_view_kind = .None
    // Keep render_offer_outstanding set until the bridge loan itself is released.
    // Otherwise the observer may receive again while RawCache is still borrowed.
    return loan
}

finish_view_rich_loan_release :: proc(view: ^Instance_View, loan: rawptr) {
    if view == nil || loan == nil do return
    snapshot_release_rich_loan(loan)
    sync.mutex_lock(&view.mutex)
    view.render_offer_outstanding = false
    sync.cond_broadcast(&view.observer_cond)
    sync.mutex_unlock(&view.mutex)
}

release_view_pending_rich_loan :: proc(view: ^Instance_View) -> bool {
    if view == nil do return false
    sync.mutex_lock(&view.mutex)
    loan := detach_view_rich_loan_locked(view)
    sync.mutex_unlock(&view.mutex)
    if loan != nil do finish_view_rich_loan_release(view, loan)
    return loan != nil
}

prepare_render_frame :: proc(work: ^Render_Work) {
    sync.mutex_lock(&work.mutex)
    if work.stop {
        work.busy = false
        sync.cond_broadcast(&work.cond)
        sync.mutex_unlock(&work.mutex)
        return
    }
    history := work.history
    offered := work.offered_view
    offered_kind := work.offered_kind
    work.offered_view = nil
    work.offered_kind = .None
    work.pending = false
    sync.mutex_unlock(&work.mutex)

    code: i32 = 9
    if offered != nil {
        if offered_kind == .Rich_Loan do code = render_prepare_rich_loan(work.handle, offered)
        else do code = render_prepare_view(work.handle, offered)
        complete_render_offer(work, offered_kind, offered)
    }
    if code == 9 do code = render_prepare(work.handle, history)

    sync.mutex_lock(&work.mutex)
    if work.suspended {
        // The tab became hidden while preparation was in flight. The frame was
        // never presented, so release process scratch without publishing it.
        if code == 0 && work.handle != nil do render_discard(work.handle)
        work.busy = false
        work.ready = false
        work.code = 0
        work.failed = false
        sync.cond_broadcast(&work.cond)
        sync.mutex_unlock(&work.mutex)
        return
    }
    work.busy = false
    work.ready = true
    work.code = code
    work.failed = code != 0
    sync.cond_broadcast(&work.cond)
    sync.mutex_unlock(&work.mutex)
    notify_instance_update()
}

render_dispatcher_worker :: proc(data: rawptr) {
    dispatcher := (^Render_Dispatcher)(data)
    for {
        work: ^Render_Work
        sync.mutex_lock(&dispatcher.mutex)
        for !dispatcher.stop && work == nil {
            work = next_render_work_locked(dispatcher)
            if work == nil do sync.cond_wait(&dispatcher.cond, &dispatcher.mutex)
        }
        stopping := dispatcher.stop
        sync.mutex_unlock(&dispatcher.mutex)
        if stopping do break
        if work == nil do continue

        sync.mutex_lock(&work.mutex)
        stopped := work.stop
        created := work.created
        if stopped {
            work.busy = false
            sync.cond_broadcast(&work.cond)
        }
        sync.mutex_unlock(&work.mutex)
        if stopped do continue
        if !created {
            create_render_handle(work)
        } else {
            prepare_render_frame(work)
        }
    }
}

start_render_dispatcher :: proc() -> ^Render_Dispatcher {
    dispatcher := new(Render_Dispatcher)
    if dispatcher == nil do return nil
    dispatcher.worker = thread.create_and_start_with_data(rawptr(dispatcher), render_dispatcher_worker, name = "howl-odin-render")
    if dispatcher.worker == nil {
        free(dispatcher)
        return nil
    }
    return dispatcher
}

stop_render_dispatcher :: proc(dispatcher: ^Render_Dispatcher) {
    if dispatcher == nil do return
    sync.mutex_lock(&dispatcher.mutex)
    assert(dispatcher.work_count == 0)
    dispatcher.stop = true
    sync.mutex_unlock(&dispatcher.mutex)
    sync.cond_signal(&dispatcher.cond)
    if dispatcher.worker != nil do thread.destroy(dispatcher.worker)
    free(dispatcher)
}

register_render_work :: proc(dispatcher: ^Render_Dispatcher, work: ^Render_Work) -> bool {
    if dispatcher == nil || work == nil do return false
    sync.mutex_lock(&dispatcher.mutex)
    defer sync.mutex_unlock(&dispatcher.mutex)
    if dispatcher.stop || dispatcher.work_count >= len(dispatcher.works) do return false
    dispatcher.works[dispatcher.work_count] = work
    dispatcher.work_count += 1
    work.dispatcher = dispatcher
    sync.cond_signal(&dispatcher.cond)
    return true
}

unregister_render_work :: proc(dispatcher: ^Render_Dispatcher, work: ^Render_Work) {
    if dispatcher == nil || work == nil do return
    sync.mutex_lock(&dispatcher.mutex)
    defer sync.mutex_unlock(&dispatcher.mutex)
    for index in 0..<dispatcher.work_count {
        if dispatcher.works[index] != work do continue
        dispatcher.work_count -= 1
        dispatcher.works[index] = dispatcher.works[dispatcher.work_count]
        dispatcher.works[dispatcher.work_count] = nil
        if dispatcher.work_count == 0 do dispatcher.next_index = 0
        else do dispatcher.next_index %= dispatcher.work_count
        return
    }
}

start_render_worker :: proc(app: ^App, view: ^Instance_View, pixels: u16) -> ^Render_Work {
    if app == nil do return nil
    if app.render_dispatcher == nil {
        app.render_dispatcher = start_render_dispatcher()
        if app.render_dispatcher == nil do return nil
    }
    work := new(Render_Work)
    if work == nil do return nil
    endpoint := instance_endpoint(view)
    font := effective_terminal_primary_font(&app.terminal_fonts, &app.terminal_font_overrides)
    italic := effective_terminal_italic_font(&app.terminal_fonts, &app.terminal_font_overrides)
    bold := effective_terminal_bold_font(&app.terminal_fonts, &app.terminal_font_overrides)
    bold_italic := effective_terminal_bold_italic_font(&app.terminal_fonts, &app.terminal_font_overrides)
    fallback := effective_terminal_fallback_font(&app.terminal_fonts, &app.terminal_font_overrides)
    secondary := effective_terminal_secondary_fallback_font(&app.terminal_fonts, &app.terminal_font_overrides)
    if len(endpoint) >= len(work.endpoint) || len(font) >= len(work.font) ||
       len(italic) >= len(work.italic) || len(bold) >= len(work.bold) ||
       len(bold_italic) >= len(work.bold_italic) || len(fallback) >= len(work.fallback) ||
       len(secondary) >= len(work.secondary) {
        free(work)
        return nil
    }
    work.owner_view = view
    work.route_kind = view.route_kind
    copy(work.endpoint[:], transmute([]u8)endpoint); work.endpoint_len = len(endpoint)
    work.server_id = view.server_id
    work.session_id = view.session_id
    work.instance_id = view.instance_id
    copy(work.font[:], transmute([]u8)font); work.font_len = len(font)
    copy(work.italic[:], transmute([]u8)italic); work.italic_len = len(italic)
    copy(work.bold[:], transmute([]u8)bold); work.bold_len = len(bold)
    copy(work.bold_italic[:], transmute([]u8)bold_italic); work.bold_italic_len = len(bold_italic)
    copy(work.fallback[:], transmute([]u8)fallback); work.fallback_len = len(fallback)
    copy(work.secondary[:], transmute([]u8)secondary); work.secondary_len = len(secondary)
    work.pixels = pixels
    work.interrupt = interrupt_create()
    if work.interrupt == nil { free(work); return nil }
    if !register_render_work(app.render_dispatcher, work) {
        interrupt_destroy(work.interrupt)
        free(work)
        return nil
    }
    return work
}

stop_render_worker :: proc(work: ^Render_Work) {
    if work == nil do return
    dispatcher := work.dispatcher
    if dispatcher != nil {
        sync.mutex_lock(&dispatcher.mutex)
        sync.mutex_lock(&work.mutex)
        work.stop = true
        work.ready = false
        sync.mutex_unlock(&work.mutex)
        sync.cond_signal(&dispatcher.cond)
        sync.mutex_unlock(&dispatcher.mutex)
    } else {
        sync.mutex_lock(&work.mutex)
        work.stop = true
        sync.mutex_unlock(&work.mutex)
    }
    _ = interrupt_cancel(work.interrupt)

    sync.mutex_lock(&work.mutex)
    for work.busy do sync.cond_wait(&work.cond, &work.mutex)
    sync.mutex_unlock(&work.mutex)
    if dispatcher != nil do unregister_render_work(dispatcher, work)

    if work.offered_view != nil do complete_render_offer(work, work.offered_kind, work.offered_view)
    if work.owner_view != nil do _ = release_view_pending_rich_loan(work.owner_view)
    if work.handle != nil do render_destroy(work.handle)
    interrupt_destroy(work.interrupt)
    free(work)
}

release_render_ready :: proc(work: ^Render_Work) {
    if work == nil do return
    sync.mutex_lock(&work.mutex)
    work.ready = false
    dispatcher := work.dispatcher
    sync.mutex_unlock(&work.mutex)
    if dispatcher != nil do sync.cond_signal(&dispatcher.cond)
}

set_render_work_suspended :: proc(work: ^Render_Work, suspended: bool) {
    if work == nil do return
    displaced: rawptr
    displaced_kind: Render_Offer_Kind
    dispatcher := work.dispatcher
    sync.mutex_lock(&work.mutex)
    if work.suspended == suspended {
        sync.mutex_unlock(&work.mutex)
        return
    }
    work.suspended = suspended
    if suspended {
        if work.pending && !work.busy {
            displaced = work.offered_view
            displaced_kind = work.offered_kind
            work.offered_view = nil
            work.offered_kind = .None
            work.pending = false
        }
        if work.ready && !work.busy {
            if work.handle != nil do render_discard(work.handle)
            work.ready = false
            work.code = 0
            work.failed = false
        }
    }
    sync.mutex_unlock(&work.mutex)
    if displaced != nil do complete_render_offer(work, displaced_kind, displaced)
    if suspended && work.owner_view != nil do _ = release_view_pending_rich_loan(work.owner_view)
    if dispatcher != nil do sync.cond_signal(&dispatcher.cond)
}

sync_render_visibility :: proc(app: ^App) {
    if app == nil do return
    for tab, tab_index in app.tabs[:app.tab_count] {
        visible := tab_index == app.active_tab
        for view in tab.panes {
            if view != nil && view.render_work != nil do set_render_work_suspended(view.render_work, !visible)
        }
    }
}

// A completed presentation makes room for one current native frame.
// Hidden panes keep draining their canonical terminal without projecting it.
request_native_frames :: proc(app: ^App, width, height: f32) {
    if app == nil || !active_tab_is_instance(app) do return
    tab := &app.tabs[app.active_tab]
    layout := pane_layout(tab, terminal_inset(width, height))
    for entry in layout.entries[:layout.entry_count] {
        view := tab_pane_view(tab, entry.pane_index)
        if view == nil do continue
        sync.mutex_lock(&view.mutex)
        // The worker clears its handle under this lock before freeing it.
        if view.native_terminal != nil do native_terminal_request_render(view.native_terminal)
        sync.mutex_unlock(&view.mutex)
    }
}

request_render :: proc(work: ^Render_Work, view: ^Instance_View, revision: u64, history: u32, history_generation: u64) {
    if work == nil || revision == 0 do return
    history_loan: rawptr
    sync.mutex_lock(&work.mutex)
    if !work.stop && !work.suspended && !work.failed && !work.ready && !work.busy && !work.pending {
        // Lock order is render mailbox -> pane. Observer only takes the pane lock;
        // process render dispatch never holds the pane lock across bridge work.
        if history == 0 {
            sync.mutex_lock(&view.mutex)
            work.offered_view = view.reusable_view
            work.offered_kind = view.reusable_view_kind
            view.reusable_view = nil
            view.reusable_view_kind = .None
            sync.mutex_unlock(&view.mutex)
        } else {
            sync.mutex_lock(&view.mutex)
            history_loan = detach_view_rich_loan_locked(view)
            sync.mutex_unlock(&view.mutex)
        }
        work.history_generation = history_generation
        work.history = history
        work.pending = true
    }
    dispatcher := work.dispatcher
    sync.mutex_unlock(&work.mutex)
    if history_loan != nil do finish_view_rich_loan_release(view, history_loan)
    if dispatcher != nil do sync.cond_signal(&dispatcher.cond)
}
