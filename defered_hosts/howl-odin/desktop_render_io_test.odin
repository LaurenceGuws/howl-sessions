package main

import "core:testing"

@(test)
hidden_ready_frame_releases_process_lane_for_visible_work :: proc(t: ^testing.T) {
    dispatcher: Render_Dispatcher
    hidden := Render_Work{ready = true, dispatcher = &dispatcher}
    visible := Render_Work{pending = true, dispatcher = &dispatcher}
    dispatcher.works[0] = &hidden
    dispatcher.works[1] = &visible
    dispatcher.work_count = 2

    set_render_work_suspended(&hidden, true)
    testing.expect(t, hidden.suspended)
    testing.expect(t, !hidden.ready)

    selected := next_render_work_locked(&dispatcher)
    testing.expect(t, selected == &visible)
    testing.expect(t, visible.busy)
}

@(test)
render_dispatcher_rotates_between_actionable_visible_works :: proc(t: ^testing.T) {
    dispatcher: Render_Dispatcher
    first := Render_Work{pending = true, dispatcher = &dispatcher}
    second := Render_Work{pending = true, dispatcher = &dispatcher}
    dispatcher.works[0] = &first
    dispatcher.works[1] = &second
    dispatcher.work_count = 2

    selected := next_render_work_locked(&dispatcher)
    testing.expect(t, selected == &first)
    first.busy = false

    selected = next_render_work_locked(&dispatcher)
    testing.expect(t, selected == &second)
    testing.expect(t, second.busy)
}

@(test)
suspended_render_work_does_not_consume_latest_view :: proc(t: ^testing.T) {
    byte: u8
    owned := rawptr(&byte)
    view := Instance_View{reusable_view = owned}
    work := Render_Work{suspended = true}

    request_render(&work, &view, 7, 0, 0)

    testing.expect(t, !work.pending)
    testing.expect_value(t, work.offered_view, rawptr(nil))
    testing.expect_value(t, view.reusable_view, owned)
}

@(test)
render_visibility_suspends_only_hidden_tabs :: proc(t: ^testing.T) {
    visible_work: Render_Work
    hidden_work := Render_Work{ready = true}
    visible_view := Instance_View{render_work = &visible_work}
    hidden_view := Instance_View{render_work = &hidden_work}
    app := App{tab_count = 2, active_tab = 0}
    app.tabs[0].pane_count = 1
    app.tabs[0].panes[0] = &visible_view
    app.tabs[1].pane_count = 1
    app.tabs[1].panes[0] = &hidden_view

    sync_render_visibility(&app)

    testing.expect(t, !visible_work.suspended)
    testing.expect(t, hidden_work.suspended)
    testing.expect(t, !hidden_work.ready)
}

@(test)
render_request_preserves_offer_ownership_kind :: proc(t: ^testing.T) {
    byte: u8
    offer := rawptr(&byte)
    view := Instance_View{reusable_view = offer, reusable_view_kind = .Owned_View}
    work: Render_Work

    request_render(&work, &view, 9, 0, 0)

    testing.expect(t, work.pending)
    testing.expect_value(t, work.offered_view, offer)
    testing.expect_value(t, work.offered_kind, Render_Offer_Kind.Owned_View)
    testing.expect_value(t, view.reusable_view, rawptr(nil))
    testing.expect_value(t, view.reusable_view_kind, Render_Offer_Kind.None)
}

@(test)
locked_rich_loan_detach_does_not_publish_release_before_bridge_release :: proc(t: ^testing.T) {
    byte: u8
    loan := rawptr(&byte)
    view := Instance_View{
        reusable_view = loan,
        reusable_view_kind = .Rich_Loan,
        render_offer_outstanding = true,
    }

    detached := detach_view_rich_loan_locked(&view)

    testing.expect_value(t, detached, loan)
    testing.expect_value(t, view.reusable_view, rawptr(nil))
    testing.expect_value(t, view.reusable_view_kind, Render_Offer_Kind.None)
    testing.expect(t, view.render_offer_outstanding)
}
