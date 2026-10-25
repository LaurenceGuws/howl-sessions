package main

import "core:testing"
import SDL "vendor:sdl3"

@(test)
overlay_pointer_reaches_settings_sidebar_instead_of_terminal :: proc(t: ^testing.T) {
    app := App{settings_open = true, settings_page = .Startup}
    panel := settings_panel_rect(1180, 760)
    event: SDL.Event
    event.type = .MOUSE_BUTTON_UP
    event.button.button = SDL.BUTTON_LEFT
    event.button.x = panel.x + 30
    event.button.y = panel.y + 130
    testing.expect(t, handle_overlay_pointer(&app, &event, 1180, 760))
    testing.expect_value(t, app.settings_page, Settings_Page.Appearance)
}

@(test)
overlay_pointer_press_and_other_buttons_do_not_activate :: proc(t: ^testing.T) {
    app := App{settings_open = true, settings_page = .Startup}
    panel := settings_panel_rect(1180, 760)
    event: SDL.Event
    event.type = .MOUSE_BUTTON_DOWN
    event.button.button = SDL.BUTTON_LEFT
    event.button.x = panel.x + 30
    event.button.y = panel.y + 130
    testing.expect(t, handle_overlay_pointer(&app, &event, 1180, 760))
    testing.expect_value(t, app.settings_page, Settings_Page.Startup)
    event.type = .MOUSE_BUTTON_UP
    event.button.button = SDL.BUTTON_RIGHT
    testing.expect(t, handle_overlay_pointer(&app, &event, 1180, 760))
    testing.expect_value(t, app.settings_page, Settings_Page.Startup)
}

@(test)
overlay_pointer_click_outside_menu_dismisses_without_terminal_fallthrough :: proc(t: ^testing.T) {
    app := App{profile_menu_open = true}
    event: SDL.Event
    event.type = .MOUSE_BUTTON_UP
    event.button.button = SDL.BUTTON_LEFT
    event.button.x = 1000
    event.button.y = 600
    testing.expect(t, handle_overlay_pointer(&app, &event, 1180, 760))
    testing.expect(t, !app.profile_menu_open)
}

@(test)
overlay_pointer_leaves_uncovered_terminal_and_non_pointer_events_alone :: proc(t: ^testing.T) {
    app: App
    event: SDL.Event
    event.type = .MOUSE_BUTTON_DOWN
    testing.expect(t, !handle_overlay_pointer(&app, &event, 1180, 760))
    app.settings_open = true
    event.type = .KEY_DOWN
    testing.expect(t, !handle_overlay_pointer(&app, &event, 1180, 760))
    testing.expect(t, !handle_overlay_pointer(nil, &event, 1180, 760))
    testing.expect(t, !handle_overlay_pointer(&app, nil, 1180, 760))
}
