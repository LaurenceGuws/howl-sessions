package main

import SDL "vendor:sdl3"

// Compositor state is authoritative. No second fullscreen boolean, display-mode
// switch, synchronous compositor wait, or repaint timer lives in the host.
toggle_window_fullscreen :: proc(app: ^App) -> bool {
    if app == nil || app.window == nil do return false
    _ = finish_tab_drag(app)
    _ = finish_pane_resize_drag(app)
    _ = finish_all_terminal_mouse_captures(app)
    _ = finish_all_history_scrollbar_drags(app)
    _ = finish_all_selections(app)
    clear_ime_preedit(app)
    fullscreen := .FULLSCREEN in SDL.GetWindowFlags(app.window)
    if !SDL.SetWindowFullscreen(app.window, !fullscreen) {
        sdl_error("Fullscreen request failed")
        return false
    }
    return true
}

window_presentation_allowed :: proc(flags: SDL.WindowFlags) -> bool {
    // Unfocused is not invisible. An exposed background terminal still paints.
    // Observers and canonical Instances continue while this window is minimized;
    // the restored/exposed event presents their newest state without replay.
    return .MINIMIZED not_in flags && .HIDDEN not_in flags
}

consume_owned_mapping_key :: proc(app: ^App, event: ^SDL.Event) -> bool {
    if app == nil || event == nil || (event.type != .KEY_DOWN && event.type != .KEY_UP) {
        return false
    }
    scancode := int(event.key.scancode)
    if scancode <= 0 || scancode >= len(app.mapping_keys_owned) do return false
    owned := app.mapping_keys_owned[scancode]
    if event.type == .KEY_UP {
        app.mapping_keys_owned[scancode] = false
        return owned
    }
    if event.key.repeat do return owned
    // A fresh press starts a new cycle even when focus loss hid the prior release.
    app.mapping_keys_owned[scancode] = false
    return false
}
