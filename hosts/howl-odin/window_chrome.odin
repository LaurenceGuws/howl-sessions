package main

import "base:runtime"
import "core:c"
import SDL "vendor:sdl3"

HEADER_HEIGHT :: f32(46)
TERMINAL_PADDING :: f32(6)
WINDOW_RESIZE_EDGE :: f32(4)
WINDOW_CONTROL_WIDTH :: f32(42)

Window_Button :: enum { None, Minimize, Maximize, Close }

// Shared terminal allocation for drawing, pointer/selection/search, IME and
// owned PTY size. Outer padding is symmetric; the scrollbar is an overlay lane
// on the right edge and never removes terminal columns. Remaining sub-cell pixels
// stay background while desktop geometry centers the integer cell surface here.
terminal_content_rect :: proc(pane: SDL.FRect) -> SDL.FRect {
    return {pane.x + TERMINAL_PADDING, pane.y + TERMINAL_PADDING,
            max(f32(0), pane.w - 2 * TERMINAL_PADDING),
            max(f32(0), pane.h - 2 * TERMINAL_PADDING)}
}

window_logical_width :: proc(app: ^App) -> f32 {
    if app == nil || app.window == nil do return 0
    w, h: c.int
    if !SDL.GetWindowSize(app.window, &w, &h) do return 0
    return f32(w)
}

header_settings_rect :: proc(width: f32, custom: bool) -> SDL.FRect {
    reserved := custom ? 3 * WINDOW_CONTROL_WIDTH + 8 : f32(0)
    return {width - reserved - 114, 7, 104, 32}
}

window_button_rect :: proc(button: Window_Button, width: f32) -> SDL.FRect {
    if button == .None do return {}
    return {width - f32(4 - int(button)) * WINDOW_CONTROL_WIDTH,
            WINDOW_RESIZE_EDGE, WINDOW_CONTROL_WIDTH, HEADER_HEIGHT - WINDOW_RESIZE_EDGE}
}

window_button_at :: proc(x, y, width: f32) -> Window_Button {
    buttons := [3]Window_Button{.Minimize, .Maximize, .Close}
    for button in buttons {
        if inside(x, y, window_button_rect(button, width)) do return button
    }
    return .None
}

header_drag_rect :: proc(count: int, width: f32, custom: bool) -> SDL.FRect {
    if !custom do return {}
    _, menu, settings := tab_controls(count, width, custom)
    left := menu.x + menu.w + 4
    return {left, WINDOW_RESIZE_EDGE, max(f32(0), settings.x - left - 4), HEADER_HEIGHT - WINDOW_RESIZE_EDGE}
}

// Pure, bounded, allocation-free callback policy. Native SDL/compositor mechanics
// own dragging and resizing; the host never chases window position from motions.
window_hit_region :: proc(x, y, width, height: f32, count: int,
                         custom: bool, flags: SDL.WindowFlags) -> SDL.HitTestResult {
    if !custom || .FULLSCREEN in flags || x < 0 || y < 0 || x >= width || y >= height {
        return .NORMAL
    }
    if .MAXIMIZED not_in flags {
        left, right := x < WINDOW_RESIZE_EDGE, x >= width - WINDOW_RESIZE_EDGE
        top, bottom := y < WINDOW_RESIZE_EDGE, y >= height - WINDOW_RESIZE_EDGE
        if top && left do return .RESIZE_TOPLEFT
        if top && right do return .RESIZE_TOPRIGHT
        if bottom && left do return .RESIZE_BOTTOMLEFT
        if bottom && right do return .RESIZE_BOTTOMRIGHT
        if top do return .RESIZE_TOP
        if bottom do return .RESIZE_BOTTOM
        if left do return .RESIZE_LEFT
        if right do return .RESIZE_RIGHT
    }
    if inside(x, y, header_drag_rect(count, width, custom)) do return .DRAGGABLE
    return .NORMAL
}

window_hit_test :: proc "c" (window: ^SDL.Window, point: ^SDL.Point, user: rawptr) -> SDL.HitTestResult {
    context = runtime.default_context()
    assert(user != nil && point != nil)
    app := (^App)(user)
    // Never steal an in-progress application drag when it crosses the frame.
    if app.tab_dragging || app.pane_resize_node != nil || app.chrome_pressed != .None || app.window_pointer_buttons != 0 do return .NORMAL
    w, h: c.int
    assert(SDL.GetWindowSize(window, &w, &h))
    return window_hit_region(f32(point.x), f32(point.y), f32(w), f32(h),
                             app.tab_count, app.client_chrome, SDL.GetWindowFlags(window))
}

install_window_chrome :: proc(app: ^App) -> bool {
    if !SDL.SetWindowHitTest(app.window, window_hit_test, app) do return false
    if !SDL.SetWindowBordered(app.window, false) {
        _ = SDL.SetWindowHitTest(app.window, nil, nil)
        return false
    }
    app.client_chrome = true
    return true
}

// A release must match the original button. Press-drag-release into the terminal
// cancels rather than closing anything or leaking the release to a TUI.
window_button_release :: proc(pressed, released: Window_Button) -> Window_Button {
    if pressed != .None && pressed == released do return pressed
    return .None
}

window_owns_button_event :: proc(pressed, target: Window_Button, down: bool) -> bool {
    return down ? target != .None : pressed != .None
}

perform_window_button :: proc(app: ^App, button: Window_Button) {
    switch button {
    case .None:
    case .Minimize:
        if !SDL.MinimizeWindow(app.window) do sdl_error("Window minimize failed")
    case .Maximize:
        if .FULLSCREEN in SDL.GetWindowFlags(app.window) do return
        if .MAXIMIZED in SDL.GetWindowFlags(app.window) {
            if !SDL.RestoreWindow(app.window) do sdl_error("Window restore failed")
        } else {
            if !SDL.MaximizeWindow(app.window) do sdl_error("Window maximize failed")
        }
    case .Close:
        // Reuse normal close cleanup, including gesture/focus and owned Instances.
        event: SDL.Event
        event.type = .WINDOW_CLOSE_REQUESTED
        handle_event(app, &event)
    }
}

// Only delivered button cycles are tracked. SDL has already consumed native
// drag/resize starts, while an application drag must retain its final release
// even after crossing the outer resize rim. This main-thread state avoids taking
// a Instance mutex or reading worker-owned selection state inside SDL hit tests.
track_window_pointer_cycle :: proc(app: ^App, event: ^SDL.Event) {
    if app == nil || event == nil do return
    #partial switch event.type {
    case .WINDOW_FOCUS_LOST:
        app.window_pointer_buttons = 0
    case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
        if event.button.button > 0 && event.button.button <= 31 {
            bit := u32(1) << event.button.button
            if event.type == .MOUSE_BUTTON_DOWN {
                app.window_pointer_buttons |= bit
            } else {
                app.window_pointer_buttons &= ~bit
            }
        }
    case:
    }
}

// Only a new right press requests a native menu. A right drag that began in
// the terminal keeps its release even when it ends over the empty header.
window_system_menu_request :: proc(event: ^SDL.Event, drag: SDL.FRect) -> bool {
    return event != nil && event.type == .MOUSE_BUTTON_DOWN &&
           event.button.button == SDL.BUTTON_RIGHT &&
           inside(event.button.x, event.button.y, drag)
}

handle_window_chrome_event :: proc(app: ^App, event: ^SDL.Event) -> bool {
    if app == nil || event == nil || !app.client_chrome do return false
    if event.type == .WINDOW_MOUSE_LEAVE {
        app.chrome_hover = .None
        return false
    }
    width := window_logical_width(app)
    if event.type == .MOUSE_MOTION {
        app.chrome_hover = window_button_at(event.motion.x, event.motion.y, width)
        if app.chrome_pressed != .None do return true
        return false
    }
    if event.type != .MOUSE_BUTTON_DOWN && event.type != .MOUSE_BUTTON_UP do return false
    target := window_button_at(event.button.x, event.button.y, width)
    if event.button.button == SDL.BUTTON_LEFT {
        if !window_owns_button_event(app.chrome_pressed, target, event.type == .MOUSE_BUTTON_DOWN) {
            // A terminal selection/mouse drag released over window controls is
            // still the terminal's release, not a caption action.
            return false
        }
        if event.type == .MOUSE_BUTTON_DOWN && target != .None {
            app.chrome_pressed = target
            return true
        }
        if event.type == .MOUSE_BUTTON_UP && app.chrome_pressed != .None {
            action := window_button_release(app.chrome_pressed, target)
            app.chrome_pressed = .None
            perform_window_button(app, action)
            return true
        }
    }
    if window_system_menu_request(event, header_drag_rect(app.tab_count, width, true)) {
        if !SDL.ShowWindowSystemMenu(app.window, c.int(event.button.x), c.int(event.button.y)) {
            sdl_error("Native window menu unavailable")
        }
        return true
    }
    return false
}

draw_window_controls :: proc(app: ^App, width: f32) {
    if !app.client_chrome do return
    maximized := .MAXIMIZED in SDL.GetWindowFlags(app.window)
    buttons := [3]Window_Button{.Minimize, .Maximize, .Close}
    for button in buttons {
        rect := window_button_rect(button, width)
        color := palette.text_muted
        if app.chrome_hover == button {
            draw_fill(app.renderer, rect, button == .Close ? SDL.Color{184, 46, 56, 255} : palette.tab_active)
            color = palette.text
        }
        x, y := rect.x + rect.w / 2, f32(23)
        set_draw_color(app.renderer, color)
        switch button {
        case .Minimize:
            _ = SDL.RenderLine(app.renderer, x - 5, y + 3, x + 5, y + 3)
        case .Maximize:
            if maximized {
                draw_outline(app.renderer, {x - 3, y - 6, 8, 8}, color)
                draw_fill(app.renderer, {x - 5, y - 4, 8, 8}, palette.title_bg)
            }
            draw_outline(app.renderer, {x - 5, y - 4, 9, 9}, color)
        case .Close:
            _ = SDL.RenderLine(app.renderer, x - 5, y - 5, x + 5, y + 5)
            _ = SDL.RenderLine(app.renderer, x - 5, y + 5, x + 5, y - 5)
        case .None:
        }
    }
}
