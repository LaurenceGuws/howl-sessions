package main
import "core:testing"

@(test)
native_presentation_admission_closes_the_worker_gap_without_blocking_replacement :: proc(t: ^testing.T) {
    state := Native_Presentation_Request{
        generation = 4,
        pending = true,
        font_pixels = 18,
        scale = 1,
    }

    admitted, ok := begin_native_presentation(&state)
    testing.expect(t, ok)
    testing.expect_value(t, admitted.generation, u64(4))
    testing.expect(t, !state.pending)
    testing.expect(t, state.inflight)
    testing.expect(t, native_presentation_target_busy(&state, 18, 1))
    testing.expect(t, !native_presentation_target_busy(&state, 31, 1.7))

    // A genuinely newer target may supersede the in-flight generation.
    state.generation = 5
    state.pending = true
    state.waiting = false
    state.failed = false
    state.font_pixels = 31
    state.scale = 1.7
    testing.expect(t, !finish_native_presentation(&state, admitted.generation, 0))
    testing.expect(t, !state.inflight)
    testing.expect(t, state.pending)

    replacement, replacement_ok := begin_native_presentation(&state)
    testing.expect(t, replacement_ok)
    testing.expect_value(t, replacement.generation, u64(5))
    testing.expect(t, state.inflight)
    testing.expect(t, native_presentation_target_busy(&state, 31, 1.7))
    testing.expect(t, finish_native_presentation(&state, replacement.generation, 0))
    testing.expect(t, !state.inflight)
    testing.expect(t, state.waiting)
    testing.expect(t, !state.failed)
}

@(test)
control_queue_is_fifo_bounded_and_does_not_replay_after_stop :: proc(t: ^testing.T) {
    view: Instance_View
    for i in 0..<CONTROL_QUEUE_ITEMS {
        testing.expect(t, control_queue_push_locked(&view, {kind = .Unicode, scalar = u32(i)}))
    }
    testing.expect(t, !control_queue_push_locked(&view, {kind = .Text}))
    for i in 0..<CONTROL_QUEUE_ITEMS {
        task, ok := control_queue_pop_locked(&view)
        testing.expect(t, ok)
        testing.expect_value(t, task.scalar, u32(i))
    }
    _, present := control_queue_pop_locked(&view)
    testing.expect(t, !present)
    view.worker_stop = true
    testing.expect(t, !control_queue_push_locked(&view, {kind = .Named}))
    testing.expect_value(t, view.control_count, 0)
}

@(test)
control_queue_bytes_are_bounded_separately_from_event_count :: proc(t: ^testing.T) {
    view: Instance_View
    payload: [65535]u8
    testing.expect(t, control_queue_push_locked(&view, {kind = .Paste, payload = payload[:]}))
    testing.expect(t, control_queue_push_locked(&view, {kind = .Paste, payload = payload[:]}))
    testing.expect(t, !control_queue_push_locked(&view, {kind = .Paste, payload = payload[:3]}))
    testing.expect_value(t, view.control_bytes, 131070)
    _, removed := control_queue_pop_locked(&view)
    testing.expect(t, removed)
    testing.expect(t, control_queue_push_locked(&view, {kind = .Paste, payload = payload[:3]}))
    view.io_failed = true
    testing.expect(t, !control_queue_push_locked(&view, {kind = .Named}))
}


@(test)
control_queue_backpressure_is_nonfatal_and_key_cycles_are_atomic :: proc(t: ^testing.T) {
    token: u8
    view := Instance_View{control = rawptr(&token)}
    for _ in 0..<CONTROL_QUEUE_ITEMS / 2 {
        testing.expect_value(t, queue_named_key_cycle(&view, u8(Bridge_Key.Down), 0), i32(0))
    }
    testing.expect_value(t, view.control_count, CONTROL_QUEUE_ITEMS)
    result := queue_named_key_cycle(&view, u8(Bridge_Key.Down), 0)
    testing.expect_value(t, result, CONTROL_QUEUE_LOCAL_REJECTED)
    testing.expect_value(t, view.control_count, CONTROL_QUEUE_ITEMS)
    testing.expect(t, !view.control_failed)
    testing.expect(t, !view.io_failed)
    testing.expect_value(t, view.error_len, 0)
    testing.expect(t, view.control_notice_len != 0)

    view = Instance_View{control = rawptr(&token)}
    for i in 0..<CONTROL_QUEUE_ITEMS - 1 {
        testing.expect(t, control_queue_push_locked(&view, {kind = .Unicode, scalar = u32(i)}))
    }
    before := view.control_count
    result = queue_named_key_cycle(&view, u8(Bridge_Key.Down), 0)
    testing.expect_value(t, result, CONTROL_QUEUE_LOCAL_REJECTED)
    testing.expect_value(t, view.control_count, before)
    testing.expect(t, !view.control_failed)
    testing.expect(t, !view.io_failed)
}

@(test)
async_selection_and_clipboard_results_require_current_view_intent :: proc(t: ^testing.T) {
    testing.expect(t, control_result_current(0, 4, 4, true))
    testing.expect(t, !control_result_current(0, 4, 5, true))
    testing.expect(t, !control_result_current(0, 4, 4, false))
    testing.expect(t, !control_result_current(2, 4, 4, true))
}


@(test)
clipboard_requests_are_ordered_independently_from_selection_motion :: proc(t: ^testing.T) {
    testing.expect(t, clipboard_request_current(7, 7, 7))
    testing.expect(t, !clipboard_request_current(7, 8, 7))
    testing.expect(t, !clipboard_request_current(7, 7, 6))
    testing.expect(t, !clipboard_request_current(0, 0, 0))
}


@(test)
completed_query_decline_preserves_input_but_transport_failure_does_not :: proc(t: ^testing.T) {
    kinds := [4]Control_Kind{.Expand, .Extract, .Link, .Clipboard}
    for kind in kinds {
        testing.expect(t, !control_failure_is_fatal(kind, BRIDGE_QUERY_DECLINED))
        testing.expect(t, control_failure_is_fatal(kind, 4))
        testing.expect(t, !control_failure_is_fatal(kind, 0))
    }
    testing.expect(t, control_failure_is_fatal(.Text, BRIDGE_QUERY_DECLINED))
    testing.expect(t, control_failure_is_fatal(.Paste, 2))
}

@(test)
selection_motion_after_copy_does_not_erase_newer_range :: proc(t: ^testing.T) {
    view := Instance_View{selection_generation = 10, selection_focus_row = 3, selection_focus_column = 8}
    issued := view.selection_generation
    testing.expect(t, !extend_selection_focus_locked(&view, 3, 8))
    testing.expect_value(t, view.selection_generation, issued)
    testing.expect(t, extend_selection_focus_locked(&view, 3, 12))
    testing.expect(t, !control_result_current(0, issued, view.selection_generation, true))
    testing.expect(t, clipboard_request_current(7, 7, 7))
    testing.expect_value(t, view.selection_focus_column, u16(12))
}


@(test)
immutable_live_view_moves_only_into_an_available_render_request :: proc(t: ^testing.T) {
    byte: u8
    owned := rawptr(&byte)
    view := Instance_View{reusable_view = owned, reusable_view_kind = .Owned_View}
    work: Render_Work
    request_render(&work, &view, 7, 0, 0)
    testing.expect(t, work.pending)
    testing.expect_value(t, work.offered_view, owned)
    testing.expect_value(t, work.offered_kind, Render_Offer_Kind.Owned_View)
    testing.expect_value(t, view.reusable_view, rawptr(nil))
    view.reusable_view = owned
    request_render(&work, &view, 8, 0, 0)
    testing.expect_value(t, view.reusable_view, owned)
    testing.expect_value(t, work.offered_view, owned)
}

@(test)
history_and_closed_render_jobs_do_not_consume_the_live_view :: proc(t: ^testing.T) {
    byte: u8
    owned := rawptr(&byte)
    view := Instance_View{reusable_view = owned}
    work: Render_Work
    request_render(&work, &view, 7, 4, 2)
    testing.expect(t, work.pending)
    testing.expect_value(t, work.offered_view, rawptr(nil))
    testing.expect_value(t, view.reusable_view, owned)
    work = Render_Work{stop = true}
    request_render(&work, &view, 7, 0, 2)
    testing.expect(t, !work.pending)
    testing.expect_value(t, view.reusable_view, owned)
    work = {}
    request_render(&work, &view, 0, 0, 2)
    testing.expect(t, !work.pending)
    testing.expect_value(t, view.reusable_view, owned)
}

@(test)
instance_update_wake_token_coalesces_until_main_retires_it :: proc(t: ^testing.T) {
    state: u32
    testing.expect(t, claim_instance_update_wake(&state))
    testing.expect(t, !claim_instance_update_wake(&state))
    retire_instance_update_wake(&state)
    testing.expect(t, claim_instance_update_wake(&state))
    retire_instance_update_wake(&state)
}
