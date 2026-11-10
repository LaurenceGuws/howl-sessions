package main

import "core:testing"
import SDL "vendor:sdl3"

@(test)
settings_layout_keeps_toolbar_body_footer_separate :: proc(t: ^testing.T) {
    sizes := [3][2]f32{{1180, 760}, {800, 600}, {700, 480}}
    for size in sizes {
        layout := settings_layout(size[0], size[1])
        testing.expect(t, layout.panel.x >= 0)
        testing.expect(t, layout.panel.x + layout.panel.w <= size[0])
        testing.expect(t, layout.toolbar.y + layout.toolbar.h <= layout.body.y)
        testing.expect(t, layout.body.y + layout.body.h < layout.footer.y)
        testing.expect(t, layout.footer.y + layout.footer.h <= layout.panel.y + layout.panel.h)
        for index in 0..<3 {
            rect := settings_button_rect(layout.toolbar, index, 3)
            testing.expect(t, rect.w > 0)
            testing.expect(t, rect.x >= layout.toolbar.x)
            testing.expect(t, rect.x + rect.w <= layout.toolbar.x + layout.toolbar.w + 0.01)
            if index > 0 {
                previous := settings_button_rect(layout.toolbar, index - 1, 3)
                testing.expect(t, previous.x + previous.w < rect.x)
            }
        }
    }
}

@(test)
settings_stepper_hits_only_painted_arrow_buttons :: proc(t: ^testing.T) {
    rect := SDL.FRect{30, 40, 300, 38}
    left, value, right := settings_stepper_parts(rect)
    testing.expect_value(t, settings_stepper_hit(rect, left.x + 5, left.y + 5), -1)
    testing.expect_value(t, settings_stepper_hit(rect, right.x + 5, right.y + 5), 1)
    testing.expect_value(t, settings_stepper_hit(rect, value.x + 5, value.y + 5), 0)
    testing.expect_value(t, settings_stepper_hit(rect, 10, 45), 0)
    testing.expect_value(t, settings_stepper_hit(rect, right.x + 5, rect.y + rect.h), 0)
    testing.expect_value(t, settings_stepper_hit({}, 0, 0), 0)
}

@(test)
settings_scroll_reveals_keyboard_selection_without_overflow :: proc(t: ^testing.T) {
    testing.expect_value(t, settings_reveal_range(100, 80, 30, 200, 300), f32(80))
    testing.expect_value(t, settings_reveal_range(0, 300, 30, 200, 300), f32(130))
    testing.expect_value(t, settings_reveal_range(50, 100, 30, 200, 300), f32(50))
    testing.expect_value(t, settings_reveal_range(0, 600, 30, 200, 300), f32(300))
    app := App{settings_page = .Profile_Home, settings_scroll_page = .Profile_Home, settings_scroll_y = 999}
    body := SDL.FRect{0, 0, 400, 240}
    testing.expect_value(t, settings_sync_scroll(&app, body), f32(192))
    testing.expect_value(t, app.settings_scroll_y, f32(192))
    app.settings_page = .Startup
    _ = settings_sync_scroll(&app, body)
    testing.expect_value(t, app.settings_scroll_y, f32(0))
}

@(test)
settings_profile_actions_preserve_templates_and_in_use_recipes :: proc(t: ^testing.T) {
    app: App
    testing.expect(t, initialize_builtin_profiles(&app))
    defer destroy_profiles(&app)
    testing.expect(t, profile_ui_action_enabled(&app, .Edit))
    testing.expect(t, profile_ui_action_enabled(&app, .Duplicate))
    testing.expect(t, !profile_ui_action_enabled(&app, .Delete))
    index := duplicate_user_profile(&app, 1)
    testing.expect(t, index >= 0)
    app.settings_profile_selection = index
    testing.expect(t, profile_ui_action_enabled(&app, .Delete))
    app.tab_count = 1
    app.tabs[0].profile = index
    testing.expect(t, !profile_ui_action_enabled(&app, .Delete))
    testing.expect(t, profile_ui_action_enabled(&app, .Edit))
    app.startup_profile = index
    testing.expect(t, !profile_ui_action_enabled(&app, .Default))
    app.settings_profile_editing = true
    testing.expect(t, profile_ui_action_enabled(&app, .Save))
    testing.expect(t, profile_ui_action_enabled(&app, .Cancel))
    testing.expect(t, !profile_ui_action_enabled(&app, .Duplicate))
    testing.expect(t, !profile_ui_action_enabled(&app, .Back))
}

@(test)
settings_profile_field_click_begins_a_real_edit :: proc(t: ^testing.T) {
    app := App{settings_open = true, settings_page = .Profile_Home}
    testing.expect(t, initialize_builtin_profiles(&app))
    defer destroy_profiles(&app)
    index := duplicate_user_profile(&app, 1)
    app.settings_profile_selection = index
    layout := settings_layout(1180, 760)
    rect := settings_profile_value(settings_profile_row(layout.body, 0, 0, true))
    testing.expect(t, settings_control_click(&app, rect.x + 12, rect.y + 12, 1180, 760))
    testing.expect(t, app.settings_profile_editing)
    testing.expect(t, app.settings_profile_select_all)
    testing.expect_value(t, app.settings_profile_edit_field, Profile_Edit_Field.Name)
    testing.expect_value(t, string(app.settings_profile_edit_buffer[:app.settings_profile_edit_len]), "Local shell copy")
}

@(test)
settings_readonly_template_does_not_enter_edit_mode :: proc(t: ^testing.T) {
    app := App{settings_open = true, settings_page = .Profile_Home}
    testing.expect(t, initialize_builtin_profiles(&app))
    defer destroy_profiles(&app)
    layout := settings_layout(1180, 760)
    rect := settings_profile_value(settings_profile_row(layout.body, 0, 0, true))
    testing.expect(t, settings_control_click(&app, rect.x + 12, rect.y + 12, 1180, 760))
    testing.expect(t, !app.settings_profile_editing)
    testing.expect(t, app.settings_notice_len != 0)
}

@(test)
settings_unsaved_field_is_not_discarded_by_other_clicks :: proc(t: ^testing.T) {
    app := App{settings_open = true, settings_page = .Profile_Home}
    testing.expect(t, initialize_builtin_profiles(&app))
    defer destroy_profiles(&app)
    app.settings_profile_selection = duplicate_user_profile(&app, 1)
    testing.expect(t, begin_profile_edit(&app, .Name))
    testing.expect(t, append_profile_edit_text(&app, "Unsaved"))
    layout := settings_layout(1180, 760)
    sidebar := settings_sidebar_row(layout.panel, int(Settings_Page.Appearance))
    handle_click(&app, sidebar.x + 10, sidebar.y + 10, 1180, 760)
    testing.expect(t, app.settings_profile_editing)
    testing.expect_value(t, app.settings_page, Settings_Page.Profile_Home)
    testing.expect_value(t, string(app.settings_profile_edit_buffer[:app.settings_profile_edit_len]), "Unsaved")
}

@(test)
settings_clipped_profile_rows_have_no_invisible_click_target :: proc(t: ^testing.T) {
    app := App{settings_open = true, settings_page = .Profile_Home, settings_scroll_page = .Profile_Home, settings_scroll_y = 80}
    testing.expect(t, initialize_builtin_profiles(&app))
    defer destroy_profiles(&app)
    app.settings_profile_selection = duplicate_user_profile(&app, 1)
    layout := settings_layout(800, 480)
    testing.expect(t, !settings_control_click(&app, layout.body.x + 250, layout.body.y - 3, 800, 480))
    testing.expect(t, !app.settings_profile_editing)
}

@(test)
settings_profile_text_select_all_replace_and_append_remain_utf8_safe :: proc(t: ^testing.T) {
    app: App
    testing.expect(t, initialize_builtin_profiles(&app))
    defer destroy_profiles(&app)
    app.settings_profile_selection = duplicate_user_profile(&app, 1)
    testing.expect(t, begin_profile_edit(&app, .Name))
    testing.expect(t, append_profile_edit_text(&app, "Brommer"))
    testing.expect_value(t, string(app.settings_profile_edit_buffer[:app.settings_profile_edit_len]), "Brommer")
    event: SDL.Event
    event.type = .KEY_DOWN
    event.key.key = SDL.K_A
    event.key.mod = {.LCTRL}
    testing.expect(t, handle_profile_edit_key(&app, &event))
    testing.expect(t, app.settings_profile_select_all)
    testing.expect(t, append_profile_edit_text(&app, "Nu"))
    event.key.key = SDL.K_A
    testing.expect(t, handle_profile_edit_key(&app, &event))
    event.key.key = SDL.K_END
    event.key.mod = {}
    testing.expect(t, handle_profile_edit_key(&app, &event))
    testing.expect(t, !app.settings_profile_select_all)
    testing.expect(t, append_profile_edit_text(&app, " é界"))
    testing.expect(t, backspace_profile_edit(&app))
    testing.expect_value(t, string(app.settings_profile_edit_buffer[:app.settings_profile_edit_len]), "Nu é")
}


@(test)
settings_rejected_replacement_preserves_original_and_selection :: proc(t: ^testing.T) {
    app: App
    testing.expect(t, initialize_builtin_profiles(&app))
    defer destroy_profiles(&app)
    app.settings_profile_selection = duplicate_user_profile(&app, 1)
    testing.expect(t, begin_profile_edit(&app, .Name))
    original := "Local shell copy"
    huge: [PROFILE_NAME_BYTES]u8
    for _, index in huge do huge[index] = 'X'
    testing.expect(t, !append_profile_edit_text(&app, string(huge[:])))
    testing.expect(t, app.settings_profile_select_all)
    testing.expect_value(t, string(app.settings_profile_edit_buffer[:app.settings_profile_edit_len]), original)
}

@(test)
settings_delete_repeat_cannot_confirm_a_destructive_action :: proc(t: ^testing.T) {
    app := App{settings_open = true, settings_page = .Profile_Defaults}
    testing.expect(t, initialize_builtin_profiles(&app))
    defer destroy_profiles(&app)
    app.settings_profile_selection = duplicate_user_profile(&app, 1)
    count := app.profile_count
    app.settings_delete_pending = true
    app.settings_delete_profile = app.settings_profile_selection
    event: SDL.Event
    event.type = .KEY_DOWN
    event.key.key = SDL.K_DELETE
    event.key.repeat = true
    _ = handle_profile_list_key(&app, &event)
    testing.expect_value(t, app.profile_count, count)
}


@(test)
settings_off_panel_controls_cannot_activate_in_a_short_window :: proc(t: ^testing.T) {
    app := App{settings_open = true, settings_page = .Profile_Defaults}
    testing.expect(t, initialize_builtin_profiles(&app))
    defer destroy_profiles(&app)
    app.settings_profile_selection = 1
    app.startup_profile = 0
    layout := settings_layout(700, 180)
    x := layout.footer.x + 12
    y := layout.footer.y + 20
    testing.expect(t, !inside(x, y, layout.panel))
    testing.expect(t, !settings_control_click(&app, x, y, 700, 180))
    testing.expect_value(t, app.startup_profile, 0)
}
