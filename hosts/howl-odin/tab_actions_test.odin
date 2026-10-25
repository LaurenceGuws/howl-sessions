package main

import "core:testing"
import SDL "vendor:sdl3"

@(test)
tab_actions_wrap_navigation_without_reordering :: proc(t: ^testing.T) {
    app := App{tab_count = 3, active_tab = 2, running = true}
    app.tabs[0].title = "first"
    app.tabs[1].title = "second"
    app.tabs[2].title = "third"
    execute_action(&app, .Next_Tab)
    testing.expect_value(t, app.active_tab, 0)
    execute_action(&app, .Previous_Tab)
    testing.expect_value(t, app.active_tab, 2)
    testing.expect_value(t, app.tabs[0].title, "first")
    testing.expect_value(t, app.tabs[2].title, "third")
}

@(test)
tab_actions_move_identity_and_disable_at_edges :: proc(t: ^testing.T) {
    app := App{tab_count = 3, active_tab = 0}
    app.tabs[0].title = "moving"
    app.tabs[1].title = "second"
    testing.expect(t, !action_enabled(&app, .Move_Tab_Left))
    execute_action(&app, .Move_Tab_Right)
    testing.expect_value(t, app.active_tab, 1)
    testing.expect_value(t, app.tabs[1].title, "moving")
    testing.expect_value(t, app.tabs[0].title, "second")
    execute_action(&app, .Move_Tab_Right)
    testing.expect(t, !action_enabled(&app, .Move_Tab_Right))
    execute_action(&app, .Move_Tab_Right)
    testing.expect_value(t, app.active_tab, 2)
}

@(test)
close_entire_tab_is_distinct_from_close_pane :: proc(t: ^testing.T) {
    app := App{tab_count = 2, active_tab = 0, running = true}
    app.tabs[0].pane_count = 2
    app.tabs[1].title = "survivor"
    execute_action(&app, .Close_Tab)
    testing.expect(t, app.running)
    testing.expect_value(t, app.tab_count, 1)
    testing.expect_value(t, app.tabs[0].title, "survivor")
    app.tabs[0].pane_count = 2
    execute_action(&app, .Close_Tab)
    testing.expect(t, !app.running)
    // Final-tab close requests ordinary app teardown, not a one-pane collapse.
    testing.expect_value(t, app.tabs[0].pane_count, 2)
}

@(test)
tab_actions_have_no_impossible_empty_or_single_tab_effect :: proc(t: ^testing.T) {
    app: App
    testing.expect(t, !action_enabled(&app, .Next_Tab))
    testing.expect(t, !action_enabled(&app, .Previous_Tab))
    testing.expect(t, !action_enabled(&app, .Close_Tab))
    app.tab_count = 1
    testing.expect(t, !action_enabled(&app, .Next_Tab))
    testing.expect(t, action_enabled(&app, .Close_Tab))
    execute_action(&app, .Next_Tab)
    testing.expect_value(t, app.active_tab, 0)
}

@(test)
tab_actions_rebind_to_kitty_chords_and_release_old_defaults :: proc(t: ^testing.T) {
    app := App{tab_count = 2}
    testing.expect(t, initialize_key_mappings(&app))
    overrides := [3]User_Key_Mapping_Config{
        {action = "next_tab", shortcut = "Ctrl+Shift+Right"},
        {action = "previous_tab", shortcut = "Ctrl+Shift+Left"},
        {action = "new_tab", shortcut = "Ctrl+Shift+T"},
    }
    testing.expect(t, apply_user_keybindings(&app, overrides[:]))
    event: SDL.Event
    event.type = .KEY_DOWN
    event.key.mod = {.LCTRL, .LSHIFT}
    event.key.key = SDL.K_RIGHT
    event.key.scancode = SDL.Scancode(79)
    testing.expect(t, handle_registered_mapping(&app, &event))
    testing.expect_value(t, app.active_tab, 1)
    testing.expect(t, app.mapping_keys_owned[79])
    event.key.repeat = true
    testing.expect(t, consume_owned_mapping_key(&app, &event))
    testing.expect_value(t, app.active_tab, 1)
    event.type = .KEY_UP
    event.key.mod = {} // Ownership survives releasing a modifier first.
    testing.expect(t, consume_owned_mapping_key(&app, &event))
    event.type = .KEY_DOWN
    event.key.repeat = false
    event.key.mod = {.LCTRL}
    event.key.key = SDL.K_TAB
    _, old_tab := action_for_shortcut_event(&app, &event)
    testing.expect(t, !old_tab)
    event.key.key = SDL.K_T
    _, old_new := action_for_shortcut_event(&app, &event)
    testing.expect(t, !old_new)
    // Full dispatch must not recover the removed hard-coded Ctrl+Tab behavior.
    event.key.key = SDL.K_TAB
    handle_event(&app, &event)
    testing.expect_value(t, app.active_tab, 1)
}

@(test)
tab_actions_conflicts_are_detected_against_navigation_defaults :: proc(t: ^testing.T) {
    app: App
    testing.expect(t, initialize_key_mappings(&app))
    testing.expect_value(t, set_action_binding(&app, .New_Tab, "Ctrl+Tab"), Binding_Update_Result.Conflict)
    testing.expect_value(t, set_action_binding(&app, .Next_Tab, ""), Binding_Update_Result.Applied)
    testing.expect_value(t, set_action_binding(&app, .New_Tab, "Ctrl+Tab"), Binding_Update_Result.Applied)
    testing.expect_value(t, action_default_shortcut(.Close_Tab), "")
    testing.expect_value(t, action_default_shortcut(.Close_Pane), "Ctrl+Shift+W")
}

@(test)
palette_rows_remain_visible_and_hittable_at_short_heights :: proc(t: ^testing.T) {
    sizes := [4][2]f32{{1180, 760}, {800, 480}, {640, 320}, {80, 80}}
    for size in sizes {
        for index in 0..<len(PALETTE_ACTIONS) {
            layout := palette_layout(size[0], size[1], index)
            testing.expect(t, layout.box.x >= 0 && layout.box.y >= 0)
            testing.expect(t, layout.box.x + layout.box.w <= size[0])
            testing.expect(t, layout.box.y + layout.box.h <= size[1])
            if layout.count == 0 do continue
            testing.expect(t, layout.first <= index && index < layout.first + layout.count)
            for row_index in 0..<layout.count {
                row := palette_row_rect(layout, row_index)
                testing.expect(t, row.y >= layout.box.y)
                testing.expect(t, row.y + row.h <= layout.box.y + layout.box.h - 28)
                testing.expect(t, inside(row.x + 1, row.y + 1, row))
            }
            testing.expect_value(t, palette_row_rect(layout, -1).w, f32(0))
            testing.expect_value(t, palette_row_rect(layout, layout.count).w, f32(0))
        }
    }
}
