package main

import "core:testing"
import SDL "vendor:sdl3"

@(test)
history_scroll_rows_clamps_and_tracks_anchor :: proc(t: ^testing.T) {
    view := Instance_View{
        history_count = 100,
        history_row_base = 50,
    }

    testing.expect(t, scroll_history_rows(&view, 20))
    testing.expect_value(t, view.history_target_offset, u32(20))
    testing.expect_value(t, view.history_anchor_top_row, u64(130))
    testing.expect(t, view.history_anchor_valid)

    testing.expect(t, scroll_history_rows(&view, -5))
    testing.expect_value(t, view.history_target_offset, u32(15))
    testing.expect_value(t, view.history_anchor_top_row, u64(135))

    testing.expect(t, scroll_history_rows(&view, 1000))
    testing.expect_value(t, view.history_target_offset, u32(100))
    testing.expect_value(t, view.history_anchor_top_row, u64(50))

    testing.expect(t, scroll_history_rows(&view, -1000))
    testing.expect_value(t, view.history_target_offset, u32(0))
    testing.expect_value(t, view.history_anchor_top_row, u64(0))
    testing.expect(t, !view.history_anchor_valid)
}

@(test)
history_follow_live_preserves_absolute_top_row :: proc(t: ^testing.T) {
    view := Instance_View{
        history_count = 100,
        history_row_base = 50,
        history_target_offset = 20,
        history_anchor_top_row = 130,
        history_anchor_valid = true,
    }

    follow_history_locked(&view, 110, 50, false)
    testing.expect_value(t, view.history_target_offset, u32(30))
    testing.expect_value(t, view.history_anchor_top_row, u64(130))
    testing.expect(t, view.history_anchor_valid)
}

@(test)
history_follow_live_clamps_to_oldest_retained_row_after_eviction :: proc(t: ^testing.T) {
    view := Instance_View{
        history_count = 100,
        history_row_base = 50,
        history_target_offset = 20,
        history_anchor_top_row = 130,
        history_anchor_valid = true,
    }

    follow_history_locked(&view, 50, 140, false)
    testing.expect_value(t, view.history_target_offset, u32(50))
    testing.expect_value(t, view.history_anchor_top_row, u64(140))
    testing.expect(t, view.history_anchor_valid)
}

@(test)
history_follow_live_resets_for_alternate_screen :: proc(t: ^testing.T) {
    view := Instance_View{
        history_count = 100,
        history_row_base = 50,
        history_target_offset = 20,
        history_anchor_top_row = 130,
        history_anchor_valid = true,
    }

    follow_history_locked(&view, 100, 50, true)
    testing.expect_value(t, view.history_target_offset, u32(0))
    testing.expect_value(t, view.history_anchor_top_row, u64(0))
    testing.expect(t, !view.history_anchor_valid)
}

@(test)
history_accept_snapshot_uses_server_clamp :: proc(t: ^testing.T) {
    view: Instance_View
    accept_history_snapshot(&view, 150, 100, 40, false, view.history_generation)
    testing.expect_value(t, view.history_target_offset, u32(100))
    testing.expect_value(t, view.history_anchor_top_row, u64(40))
    testing.expect(t, view.history_anchor_valid)

    accept_history_snapshot(&view, 0, 100, 40, false, view.history_generation)
    testing.expect_value(t, view.history_target_offset, u32(0))
    testing.expect(t, !view.history_anchor_valid)
}

@(test)
history_scrollbar_geometry_maps_oldest_middle_and_live :: proc(t: ^testing.T) {
    live_top, height, ok := history_scrollbar_thumb(0, 100, 25, 200)
    testing.expect(t, ok)
    testing.expect_value(t, height, f32(40))
    testing.expect_value(t, live_top, f32(160))

    middle_top, middle_height, middle_ok := history_scrollbar_thumb(50, 100, 25, 200)
    testing.expect(t, middle_ok)
    testing.expect_value(t, middle_height, f32(40))
    testing.expect_value(t, middle_top, f32(80))

    oldest_top, oldest_height, oldest_ok := history_scrollbar_thumb(100, 100, 25, 200)
    testing.expect(t, oldest_ok)
    testing.expect_value(t, oldest_height, f32(40))
    testing.expect_value(t, oldest_top, f32(0))

    testing.expect_value(t, history_offset_for_scrollbar_thumb(0, 200, 40, 100), u32(100))
    testing.expect_value(t, history_offset_for_scrollbar_thumb(80, 200, 40, 100), u32(50))
    testing.expect_value(t, history_offset_for_scrollbar_thumb(160, 200, 40, 100), u32(0))
}

@(test)
history_reset_does_not_steal_pointer_drag_lifecycle :: proc(t: ^testing.T) {
    view := Instance_View{
        history_target_offset = 12,
        history_anchor_top_row = 88,
        history_anchor_valid = true,
        history_scrollbar_dragging = true,
        history_scrollbar_grab_y = 7,
    }
    reset_history_locked(&view)
    testing.expect_value(t, view.history_target_offset, u32(0))
    testing.expect(t, !view.history_anchor_valid)
    testing.expect(t, view.history_scrollbar_dragging)
    testing.expect_value(t, view.history_scrollbar_grab_y, f32(7))
}

@(test)
history_horizontal_geometry_change_returns_to_live :: proc(t: ^testing.T) {
    view := Instance_View{
        columns = 120,
        history_count = 300,
        history_target_offset = 140,
        history_anchor_top_row = 160,
        history_anchor_valid = true,
        history_scrollbar_dragging = true,
    }
    apply_history_geometry_locked(&view, 60)
    testing.expect_value(t, view.history_target_offset, u32(0))
    testing.expect(t, !view.history_anchor_valid)
    testing.expect(t, view.history_scrollbar_dragging)
}

@(test)
history_same_columns_preserve_anchor :: proc(t: ^testing.T) {
    view := Instance_View{
        columns = 120,
        history_target_offset = 140,
        history_anchor_top_row = 160,
        history_anchor_valid = true,
    }
    apply_history_geometry_locked(&view, 120)
    testing.expect_value(t, view.history_target_offset, u32(140))
    testing.expect_value(t, view.history_anchor_top_row, u64(160))
    testing.expect(t, view.history_anchor_valid)
}

@(test)
history_column_change_detection_ignores_unknown_and_same_geometry :: proc(t: ^testing.T) {
    testing.expect(t, !history_columns_changed(0, 80))
    testing.expect(t, !history_columns_changed(80, 80))
    testing.expect(t, history_columns_changed(80, 120))
}

@(test)
history_fractional_wheel_accumulates_whole_rows :: proc(t: ^testing.T) {
    view := Instance_View{
        history_count = 100,
        history_row_base = 50,
    }

    testing.expect(t, !scroll_history_wheel(&view, 0.1))
    testing.expect(t, !scroll_history_wheel(&view, 0.1))
    testing.expect(t, !scroll_history_wheel(&view, 0.1))
    testing.expect_value(t, view.history_target_offset, u32(0))
    testing.expect(t, scroll_history_wheel(&view, 0.1))
    testing.expect_value(t, view.history_target_offset, u32(1))
    testing.expect(t, view.history_wheel_rows > 0 && view.history_wheel_rows < 1)

    testing.expect(t, scroll_history_wheel(&view, 1.0))
    testing.expect_value(t, view.history_target_offset, u32(4))
}

@(test)
history_wheel_clamp_and_discrete_navigation_clear_fraction :: proc(t: ^testing.T) {
    view := Instance_View{
        history_count = 4,
        history_row_base = 10,
        history_target_offset = 3,
        history_anchor_top_row = 11,
        history_anchor_valid = true,
        history_wheel_rows = 0.75,
    }

    testing.expect(t, scroll_history_wheel(&view, 1.0))
    testing.expect_value(t, view.history_target_offset, u32(4))
    testing.expect_value(t, view.history_wheel_rows, f32(0))

    view.history_wheel_rows = 0.75
    testing.expect(t, scroll_history_rows(&view, -1))
    testing.expect_value(t, view.history_target_offset, u32(3))
    testing.expect_value(t, view.history_wheel_rows, f32(0))

    view.history_wheel_rows = -0.5
    testing.expect(t, set_history_offset(&view, 0))
    testing.expect_value(t, view.history_wheel_rows, f32(0))
}


@(test)
history_thumb_drag_does_not_require_explicit_mouse_capture :: proc(t: ^testing.T) {
    // No SDL window exists in this test, so explicit capture cannot succeed.
    // The delivered pointer gesture still owns history until release/cancel.
    view := Instance_View{rows = 25, columns = 80, history_count = 500}
    pane := SDL.FRect{0, HEADER_HEIGHT, 960, 700}
    geometry, ok := history_scrollbar_geometry_for_surface(pane, terminal_content_rect(pane), view.history_target_offset, view.history_count, u32(view.rows), view.alternate_screen)
    testing.expect(t, ok)
    x, y := geometry.thumb.x + 2, geometry.thumb.y + 5
    testing.expect(t, begin_history_scrollbar_drag_geometry(&view, geometry, x, y))
    testing.expect(t, history_scrollbar_drag_active(&view))
    testing.expect_value(t, view.history_scrollbar_grab_y, f32(5))
    testing.expect_value(t, view.history_target_offset, u32(0))
    testing.expect(t, update_history_scrollbar_drag_geometry(&view, geometry, y - 140))
    testing.expect(t, view.history_target_offset > 0)
    testing.expect_value(t, view.history_scrollbar_grab_y, f32(5))
    testing.expect(t, finish_history_scrollbar_drag(&view))
    testing.expect(t, !history_scrollbar_drag_active(&view))
    testing.expect_value(t, view.history_scrollbar_grab_y, f32(0))
    stopped := view.history_target_offset
    testing.expect(t, !update_history_scrollbar_drag_geometry(&view, geometry, -1000))
    testing.expect_value(t, view.history_target_offset, stopped)
    testing.expect(t, !finish_history_scrollbar_drag(&view))
}

@(test)
history_track_seek_continues_dragging_and_clamps_outside_the_pane :: proc(t: ^testing.T) {
    view := Instance_View{rows = 25, columns = 80, history_count = 500}
    pane := SDL.FRect{200, 100, 500, 400}
    geometry, ok := history_scrollbar_geometry_for_surface(pane, terminal_content_rect(pane), view.history_target_offset, view.history_count, u32(view.rows), view.alternate_screen)
    testing.expect(t, ok)
    testing.expect(t, begin_history_scrollbar_drag_geometry(&view, geometry, geometry.hit.x + 2,
                                                geometry.track.y + geometry.track.h / 2))
    middle := view.history_target_offset
    testing.expect(t, middle > 0 && middle < view.history_count)
    testing.expect(t, history_scrollbar_drag_active(&view))
    testing.expect(t, update_history_scrollbar_drag_geometry(&view, geometry, -1000))
    testing.expect_value(t, view.history_target_offset, view.history_count)
    testing.expect(t, update_history_scrollbar_drag_geometry(&view, geometry, 10000))
    testing.expect_value(t, view.history_target_offset, u32(0))
    testing.expect(t, history_scrollbar_drag_active(&view))
    testing.expect(t, finish_history_scrollbar_drag(&view))
}

@(test)
history_drag_is_pane_local_and_focus_loss_cancels_without_changing_offsets :: proc(t: ^testing.T) {
    first := Instance_View{rows = 25, columns = 40, history_count = 500}
    second := Instance_View{rows = 25, columns = 40, history_count = 900}
    pane := SDL.FRect{0, HEADER_HEIGHT, 500, 700}
    geometry, ok := history_scrollbar_geometry_for_surface(pane, terminal_content_rect(pane), first.history_target_offset, first.history_count, u32(first.rows), first.alternate_screen)
    testing.expect(t, ok)
    testing.expect(t, begin_history_scrollbar_drag_geometry(&first, geometry, geometry.hit.x + 2,
                                                geometry.track.y + geometry.track.h / 2))
    testing.expect(t, history_scrollbar_drag_active(&first))
    testing.expect(t, !history_scrollbar_drag_active(&second))
    testing.expect_value(t, second.history_target_offset, u32(0))
    app: App
    app.tab_count = 1
    app.active_tab = 0
    app.tabs[0].pane_count = 2
    app.tabs[0].panes[0] = &first
    app.tabs[0].panes[1] = &second
    stopped := first.history_target_offset
    event: SDL.Event
    event.type = .WINDOW_FOCUS_LOST
    handle_event(&app, &event)
    testing.expect(t, !history_scrollbar_drag_active(&first))
    testing.expect_value(t, first.history_target_offset, stopped)
    testing.expect(t, !update_history_scrollbar_drag(&first, pane, 0))
    testing.expect_value(t, second.history_target_offset, u32(0))
}

@(test)
history_drag_refuses_terminal_cells_empty_history_and_alternate_screen :: proc(t: ^testing.T) {
    view := Instance_View{rows = 25, columns = 80, history_count = 500}
    pane := SDL.FRect{0, HEADER_HEIGHT, 960, 700}
    surface := terminal_content_rect(pane)
    geometry, ok := history_scrollbar_geometry_for_surface(
        pane, surface, view.history_target_offset, view.history_count, u32(view.rows), false,
    )
    testing.expect(t, ok)
    testing.expect(t, !begin_history_scrollbar_drag_geometry(&view, geometry, 6, 100))
    testing.expect(t, !history_scrollbar_drag_active(&view))

    _, empty_ok := history_scrollbar_geometry_for_surface(pane, surface, 0, 0, u32(view.rows), false)
    testing.expect(t, !empty_ok)
    _, alternate_ok := history_scrollbar_geometry_for_surface(pane, surface, 0, view.history_count, u32(view.rows), true)
    testing.expect(t, !alternate_ok)

    testing.expect(t, !begin_history_scrollbar_drag(nil, pane, 953, 100))
    testing.expect(t, !history_scrollbar_drag_active(&view))
}


@(test)
late_history_frame_cannot_overwrite_newer_navigation_or_live_intent :: proc(t: ^testing.T) {
    view := Instance_View{history_count = 200, rows = 20, columns = 40}
    testing.expect(t, set_history_offset(&view, 30))
    issued := view.history_generation
    testing.expect(t, set_history_offset(&view, 70))
    accept_history_snapshot(&view, 30, 200, 0, false, issued)
    testing.expect_value(t, view.history_target_offset, u32(70))
    later := view.history_generation
    testing.expect(t, return_history_live(&view))
    accept_history_snapshot(&view, 70, 200, 0, false, later)
    testing.expect_value(t, view.history_target_offset, u32(0))
    testing.expect(t, !view.history_anchor_valid)
}

@(test)
slow_history_wheel_acceptance_advances_instead_of_replaying_one_offset :: proc(t: ^testing.T) {
    view := Instance_View{
        history_count = 100,
        history_row_base = 50,
    }

    expected_offsets := [3]u32{3, 6, 9}
    for expected in expected_offsets {
        testing.expect(t, scroll_history_wheel(&view, 1))
        testing.expect_value(t, view.history_target_offset, expected)
        generation := view.history_generation

        // This is the metadata of the frame just accepted by the render bridge.
        // The bridge contract deliberately does not expose it until render_accept.
        accept_history_snapshot(&view, expected, 100, 50, false, generation)

        testing.expect_value(t, view.history_target_offset, expected)
        testing.expect_value(t, view.history_anchor_top_row, u64(150 - expected))
        testing.expect(t, view.history_anchor_valid)
    }
}
