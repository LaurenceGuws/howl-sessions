package main

import "core:testing"
import SDL "vendor:sdl3"

@(test)
terminal_geometry_has_one_gutter_and_no_outer_mat :: proc(t: ^testing.T) {
    pane := terminal_inset(960, 1036)
    testing.expect_value(t, pane, SDL.FRect{0, HEADER_HEIGHT, 960, 1036 - HEADER_HEIGHT})
    content := terminal_content_rect(pane)
    testing.expect_value(t, content.x, TERMINAL_PADDING)
    testing.expect_value(t, content.y, HEADER_HEIGHT + TERMINAL_PADDING)
    testing.expect_value(t, content.w, f32(948))
    testing.expect_value(t, content.h, f32(978))
    tiny := terminal_content_rect({0, 0, 1, 1})
    testing.expect_value(t, tiny.w, f32(0))
    testing.expect_value(t, tiny.h, f32(0))
}

@(test)
header_controls_do_not_overlap_any_tab_at_supported_widths :: proc(t: ^testing.T) {
    widths := [4]f32{640, 820, 960, 1920}
    for width in widths {
        for count in 1..=MAX_TABS {
            plus, menu, settings := tab_controls(count, width)
            last := tab_rect_for_index(count - 1, count, width)
            testing.expect(t, last.x + last.w <= plus.x)
            testing.expect(t, plus.x + plus.w <= menu.x)
            testing.expect(t, menu.x + menu.w + 24 <= settings.x)
            testing.expect(t, settings.x + settings.w < window_button_rect(.Minimize, width).x)
            for index in 0..<count {
                rect := tab_rect_for_index(index, count, width)
                hit, ok := tab_index_at(rect.x + rect.w / 2, rect.y + 8, count, width)
                testing.expect(t, ok)
                testing.expect_value(t, hit, index)
                testing.expect_value(t, tab_reorder_target(rect.x, count, width), index)
            }
        }
    }
}

@(test)
window_hit_regions_reserve_native_move_resize_and_protect_controls :: proc(t: ^testing.T) {
    testing.expect_value(t, window_hit_region(1, 1, 960, 760, 2, true, {}), SDL.HitTestResult.RESIZE_TOPLEFT)
    testing.expect_value(t, window_hit_region(959, 759, 960, 760, 2, true, {}), SDL.HitTestResult.RESIZE_BOTTOMRIGHT)
    testing.expect_value(t, window_hit_region(2, 300, 960, 760, 2, true, {}), SDL.HitTestResult.RESIZE_LEFT)
    testing.expect_value(t, window_hit_region(2, 300, 960, 760, 2, true, {.MAXIMIZED}), SDL.HitTestResult.NORMAL)
    testing.expect_value(t, window_hit_region(6, 80, 960, 760, 2, true, {}), SDL.HitTestResult.NORMAL)
    testing.expect_value(t, window_hit_region(900, 23, 960, 760, 2, true, {}), SDL.HitTestResult.NORMAL)
    drag := header_drag_rect(2, 960, true)
    testing.expect(t, drag.w >= 24)
    testing.expect_value(t, window_hit_region(drag.x + 2, 23, 960, 760, 2, true, {}), SDL.HitTestResult.DRAGGABLE)
    testing.expect_value(t, window_hit_region(drag.x + 2, 23, 960, 760, 2, true, {.FULLSCREEN}), SDL.HitTestResult.NORMAL)
    testing.expect_value(t, window_hit_region(1, 1, 960, 760, 2, false, {}), SDL.HitTestResult.NORMAL)
    plus, menu, settings := tab_controls(2, 960)
    controls := [3]SDL.FRect{plus, menu, settings}
    for rect in controls {
        testing.expect_value(t, window_hit_region(rect.x + 8, rect.y + 8, 960, 760, 2, true, {}), SDL.HitTestResult.NORMAL)
    }
}

@(test)
window_button_requires_matching_press_and_release :: proc(t: ^testing.T) {
    testing.expect_value(t, window_button_release(.Close, .Close), Window_Button.Close)
    testing.expect_value(t, window_button_release(.Close, .None), Window_Button.None)
    testing.expect_value(t, window_button_release(.Minimize, .Close), Window_Button.None)
    testing.expect_value(t, window_button_release(.None, .Close), Window_Button.None)
    testing.expect_value(t, window_button_at(955, 24, 960), Window_Button.Close)
    testing.expect_value(t, window_button_at(860, 24, 960), Window_Button.Minimize)
    testing.expect_value(t, window_button_at(900, 500, 960), Window_Button.None)
}

@(test)
compact_tabs_have_no_invisible_close_target :: proc(t: ^testing.T) {
    compact := tab_close_rect_for_index(0, 8, 640)
    testing.expect_value(t, compact.w, f32(0))
    ordinary := tab_close_rect_for_index(0, 2, 1920)
    testing.expect(t, ordinary.w > 0)
}


@(test)
application_drag_retains_release_when_crossing_window_resize_edge :: proc(t: ^testing.T) {
    app: App
    event: SDL.Event
    event.type = .MOUSE_BUTTON_DOWN
    event.button.button = SDL.BUTTON_LEFT
    track_window_pointer_cycle(&app, &event)
    testing.expect(t, app.window_pointer_buttons != 0)
    event.type = .MOUSE_MOTION
    track_window_pointer_cycle(&app, &event)
    testing.expect(t, app.window_pointer_buttons != 0)
    event.type = .MOUSE_BUTTON_UP
    event.button.button = SDL.BUTTON_LEFT
    track_window_pointer_cycle(&app, &event)
    testing.expect_value(t, app.window_pointer_buttons, u32(0))
    event.type = .MOUSE_BUTTON_DOWN
    track_window_pointer_cycle(&app, &event)
    event.type = .WINDOW_FOCUS_LOST
    track_window_pointer_cycle(&app, &event)
    testing.expect_value(t, app.window_pointer_buttons, u32(0))
}


@(test)
terminal_allocation_is_symmetric_and_scrollbar_is_overlay_only :: proc(t: ^testing.T) {
    pane := SDL.FRect{0, HEADER_HEIGHT, 960, 760 - HEADER_HEIGHT}
    content := terminal_content_rect(pane)
    testing.expect_value(t, content.x - pane.x, TERMINAL_PADDING)
    testing.expect_value(t, pane.x + pane.w - (content.x + content.w), TERMINAL_PADDING)
    testing.expect(t, content.x >= WINDOW_RESIZE_EDGE)
    testing.expect(t, content.y + content.h <= pane.y + pane.h - WINDOW_RESIZE_EDGE)
}

@(test)
caption_hover_never_owns_a_terminal_drag_release :: proc(t: ^testing.T) {
    testing.expect(t, !window_owns_button_event(.None, .Close, false))
    testing.expect(t, !window_owns_button_event(.None, .Maximize, false))
    testing.expect(t, window_owns_button_event(.Close, .None, false))
    testing.expect(t, window_owns_button_event(.None, .Close, true))
    testing.expect(t, !window_owns_button_event(.None, .None, true))
}


@(test)
window_menu_never_consumes_a_terminal_right_drag_release :: proc(t: ^testing.T) {
    drag := SDL.FRect{100, 4, 120, 42}
    event: SDL.Event
    event.type = .MOUSE_BUTTON_UP
    event.button.button = SDL.BUTTON_RIGHT
    event.button.x, event.button.y = 150, 23
    testing.expect(t, !window_system_menu_request(&event, drag))
    event.type = .MOUSE_BUTTON_DOWN
    testing.expect(t, window_system_menu_request(&event, drag))
    event.button.x = 221
    testing.expect(t, !window_system_menu_request(&event, drag))
    event.button.x = 150
    event.button.button = SDL.BUTTON_LEFT
    testing.expect(t, !window_system_menu_request(&event, drag))
    testing.expect(t, !window_system_menu_request(nil, drag))
}
