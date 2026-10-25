package main

import SDL "vendor:sdl3"

// Overlay input belongs to application chrome, not to the terminal behind it.
// Activate on left-button release, like the rest of the desktop controls. Other
// buttons and presses remain consumed without turning into a second click.
handle_overlay_pointer :: proc(app: ^App, event: ^SDL.Event, width, height: f32) -> bool {
    if app == nil || event == nil ||
       (event.type != .MOUSE_BUTTON_DOWN && event.type != .MOUSE_BUTTON_UP) ||
       !(app.settings_open || app.profile_menu_open || app.palette_open || app.search_open) {
        return false
    }
    if event.type == .MOUSE_BUTTON_UP && event.button.button == SDL.BUTTON_LEFT {
        handle_click(app, event.button.x, event.button.y, width, height)
    }
    return true
}
