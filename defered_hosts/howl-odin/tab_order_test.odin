package main

import "core:testing"
import SDL "vendor:sdl3"

@(test)
tab_move_preserves_order_and_active_identity :: proc(t: ^testing.T) {
    app: App
    app.tab_count = 4
    app.active_tab = 1
    app.tabs[0].title = "A"
    app.tabs[1].title = "B"
    app.tabs[2].title = "C"
    app.tabs[3].title = "D"

    testing.expect(t, move_tab(&app, 1, 3))
    testing.expect_value(t, app.tabs[0].title, "A")
    testing.expect_value(t, app.tabs[1].title, "C")
    testing.expect_value(t, app.tabs[2].title, "D")
    testing.expect_value(t, app.tabs[3].title, "B")
    testing.expect_value(t, app.active_tab, 3)

    testing.expect(t, move_tab(&app, 0, 2))
    testing.expect_value(t, app.tabs[0].title, "C")
    testing.expect_value(t, app.tabs[1].title, "D")
    testing.expect_value(t, app.tabs[2].title, "A")
    testing.expect_value(t, app.tabs[3].title, "B")
    testing.expect_value(t, app.active_tab, 3)

    testing.expect(t, move_tab(&app, 3, 1))
    testing.expect_value(t, app.tabs[0].title, "C")
    testing.expect_value(t, app.tabs[1].title, "B")
    testing.expect_value(t, app.tabs[2].title, "D")
    testing.expect_value(t, app.tabs[3].title, "A")
    testing.expect_value(t, app.active_tab, 1)
}

@(test)
tab_reorder_target_tracks_nearest_tab_center :: proc(t: ^testing.T) {
    testing.expect_value(t, tab_reorder_target(TAB_X, 4), 0)
    testing.expect_value(t, tab_reorder_target(TAB_X + TAB_STEP * 0.6, 4), 1)
    testing.expect_value(t, tab_reorder_target(TAB_X + TAB_STEP * 1.6, 4), 2)
    testing.expect_value(t, tab_reorder_target(-1000, 4), 0)
    testing.expect_value(t, tab_reorder_target(10000, 4), 3)
}

@(test)
numeric_tab_selection_is_explicit_parameterized_mapping :: proc(t: ^testing.T) {
    found := 0
    for definition in KEY_MAPPING_DEFINITIONS {
        if definition.target.kind != .Select_Tab do continue
        testing.expect(t, definition.target.value >= 0 && definition.target.value < MAX_TABS)
        found += 1
    }
    testing.expect_value(t, found, MAX_TABS)
}

@(test)
close_last_single_pane_requests_window_shutdown :: proc(t: ^testing.T) {
    app: App
    app.running = true
    app.tab_count = 1
    app.active_tab = 0
    app.tabs[0].pane_count = 1
    close_active_pane(&app)
    testing.expect(t, !app.running)
    testing.expect_value(t, app.tab_count, 1)
}


@(test)
tab_drag_follows_grab_before_crossing_a_reorder_threshold :: proc(t: ^testing.T) {
    app: App
    app.tab_count = 2
    app.active_tab = 0
    app.tabs[0].title = "A"
    app.tabs[1].title = "B"
    first, second: Instance_View
    app.tabs[0].panes[0] = &first
    app.tabs[1].panes[0] = &second
    testing.expect(t, begin_tab_drag(&app, 0, TAB_X + 10))
    testing.expect_value(t, app.tab_drag_grab_x, f32(10))
    testing.expect(t, update_tab_drag_at_width(&app, TAB_X + 40, 1920))
    testing.expect_value(t, tab_drag_rect(&app, 1920).x, TAB_X + 30)
    testing.expect_value(t, app.active_tab, 0)
    testing.expect_value(t, app.tabs[0].title, "A")
    testing.expect(t, !update_tab_drag_at_width(&app, TAB_X + 40, 1920))
    testing.expect(t, update_tab_drag_at_width(&app, TAB_X + TAB_STEP + 10, 1920))
    testing.expect_value(t, app.tab_drag_index, 1)
    testing.expect_value(t, app.active_tab, 1)
    testing.expect_value(t, app.tabs[1].title, "A")
    testing.expect_value(t, app.tabs[1].panes[0], &first)
    testing.expect_value(t, app.tabs[0].panes[0], &second)
    testing.expect_value(t, app.tab_drag_grab_x, f32(10))
    testing.expect(t, finish_tab_drag(&app))
    testing.expect(t, !app.tab_dragging)
    testing.expect_value(t, app.tab_drag_index, -1)
    testing.expect_value(t, app.tab_drag_grab_x, f32(0))
    testing.expect_value(t, tab_drag_rect(&app, 1920).w, f32(0))
    testing.expect(t, !update_tab_drag_at_width(&app, 500, 1920))
}

@(test)
dragged_chip_stays_inside_tab_slots_at_all_supported_widths :: proc(t: ^testing.T) {
    widths := [4]f32{640, 820, 960, 1920}
    for width in widths {
        for count in 1..=MAX_TABS {
            app: App
            app.client_chrome = true
            app.tab_count = count
            app.active_tab = 0
            app.tab_dragging = true
            app.tab_drag_index = 0
            app.tab_drag_grab_x = 3
            _ = update_tab_drag_at_width(&app, -10000, width)
            first := tab_drag_rect(&app, width)
            testing.expect_value(t, first.x, TAB_X)
            _ = update_tab_drag_at_width(&app, 10000, width)
            last := tab_drag_rect(&app, width)
            expected := tab_rect_for_index(count - 1, count, width, true)
            testing.expect_value(t, last.x, expected.x)
            testing.expect_value(t, last.w, expected.w)
            plus, _, _ := tab_controls(count, width, true)
            testing.expect(t, last.x + last.w <= plus.x)
        }
    }
}

@(test)
keyboard_tab_and_overlay_interruption_retire_old_pointer_intent :: proc(t: ^testing.T) {
    keys := [2]SDL.Keycode{SDL.K_TAB, SDL.K_COMMA}
    for key in keys {
        first := Instance_View{rows = 25, columns = 40, history_count = 500}
        second: Instance_View
        app: App
        app.running = true
        app.tab_count = 2
        app.active_tab = 0
        app.tabs[0].pane_count = 1
        app.tabs[0].panes[0] = &first
        app.tabs[1].pane_count = 1
        app.tabs[1].panes[0] = &second
        testing.expect(t, initialize_key_mappings(&app))
        pane := SDL.FRect{0, HEADER_HEIGHT, 500, 700}
        geometry, ok := history_scrollbar_geometry_for_surface(pane, terminal_content_rect(pane), first.history_target_offset, first.history_count, u32(first.rows), first.alternate_screen)
        testing.expect(t, ok)
        testing.expect(t, begin_history_scrollbar_drag_geometry(&first, geometry, geometry.hit.x + 2,
                                                    geometry.track.y + geometry.track.h / 2))
        testing.expect(t, history_scrollbar_drag_active(&first))
        testing.expect(t, begin_tab_drag(&app, 0, TAB_X + 4))
        stopped := first.history_target_offset
        event: SDL.Event
        event.type = .KEY_DOWN
        event.key.key = key
        event.key.scancode = SDL.Scancode(43)
        event.key.mod = {.LCTRL}
        handle_event(&app, &event)
        testing.expect(t, !app.tab_dragging)
        testing.expect(t, !history_scrollbar_drag_active(&first))
        testing.expect_value(t, first.history_target_offset, stopped)
        testing.expect(t, app.discard_local_drag_release)
        if key == SDL.K_TAB {
            testing.expect_value(t, app.active_tab, 1)
        } else {
            testing.expect(t, app.settings_open)
        }
        testing.expect(t, !update_history_scrollbar_drag(&first, pane, 0))
        testing.expect_value(t, second.history_target_offset, u32(0))
        event.type = .MOUSE_BUTTON_UP
        event.button.button = SDL.BUTTON_LEFT
        testing.expect(t, handle_local_drag_interruption(&app, &event))
        testing.expect(t, !app.discard_local_drag_release)
    }
}

@(test)
interrupted_local_drag_consumes_only_its_old_left_release :: proc(t: ^testing.T) {
    view := Instance_View{rows = 25, columns = 80, history_count = 500}
    app: App
    app.tab_count = 1
    app.active_tab = 0
    app.tabs[0].panes[0] = &view
    view.history_scrollbar_dragging = true
    event: SDL.Event
    event.type = .KEY_DOWN
    testing.expect(t, !handle_local_drag_interruption(&app, &event))
    testing.expect(t, !history_scrollbar_drag_active(&view))
    testing.expect(t, app.discard_local_drag_release)
    event.type = .MOUSE_MOTION
    testing.expect(t, !handle_local_drag_interruption(&app, &event))
    event.type = .MOUSE_BUTTON_UP
    event.button.button = SDL.BUTTON_RIGHT
    testing.expect(t, !handle_local_drag_interruption(&app, &event))
    testing.expect(t, app.discard_local_drag_release)
    event.button.button = SDL.BUTTON_LEFT
    testing.expect(t, handle_local_drag_interruption(&app, &event))
    testing.expect(t, !app.discard_local_drag_release)
    testing.expect(t, !handle_local_drag_interruption(&app, &event))
}

@(test)
interrupted_drag_does_not_claim_a_fresh_click_or_terminal_mouse_release :: proc(t: ^testing.T) {
    app: App
    app.discard_local_drag_release = true
    event: SDL.Event
    event.type = .MOUSE_BUTTON_DOWN
    event.button.button = SDL.BUTTON_LEFT
    testing.expect(t, !handle_local_drag_interruption(&app, &event))
    testing.expect(t, !app.discard_local_drag_release)
    event.type = .MOUSE_BUTTON_UP
    testing.expect(t, !handle_local_drag_interruption(&app, &event))
    view := Instance_View{terminal_mouse_captured = true}
    app.tab_count = 1
    app.active_tab = 0
    app.tabs[0].panes[0] = &view
    event.type = .KEY_DOWN
    testing.expect(t, !handle_local_drag_interruption(&app, &event))
    testing.expect(t, view.terminal_mouse_captured)
    testing.expect(t, !app.discard_local_drag_release)
    app.discard_local_drag_release = true
    event.type = .WINDOW_FOCUS_LOST
    testing.expect(t, !handle_local_drag_interruption(&app, &event))
    testing.expect(t, !app.discard_local_drag_release)
}
