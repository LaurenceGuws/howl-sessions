package main

import "core:sync"
import SDL "vendor:sdl3"

// Labels consume only the accepted canonical title property copied by the
// observer. Absence stays absence; profile metadata is not a substitute source.
tab_property_presentation :: proc(tab: ^Tab, output: []u8) -> (title: string, progress: u16) {
    if tab == nil do return "", 0
    view := tab_pane_view(tab, tab.active_pane)
    if view == nil do return
    sync.mutex_lock(&view.mutex)
    defer sync.mutex_unlock(&view.mutex)
    if view.display_title_len > 0 && view.display_title_len <= len(output) {
        copy(output[:view.display_title_len], view.display_title[:view.display_title_len])
        title = string(output[:view.display_title_len])
    }
    progress = view.task_progress
    return
}

// Indeterminate state is a stationary segment, not an independent animation
// clock. State changes wake the existing observer; a quiet tab stays asleep.
tab_progress_fraction :: proc(progress: u16) -> (offset, width: f32, visible: bool) {
    kind, value := u8(progress >> 8), u8(progress)
    if kind == 0 || kind > 4 || value > 100 do return
    if kind == 3 do return 1.0 / 3.0, 1.0 / 3.0, true
    return 0, f32(value) / 100.0, true
}

tab_progress_track :: proc(rect: SDL.FRect) -> SDL.FRect {
    // Keep a clear gap above the separate active-tab underline at y37.
    return {rect.x + 8, rect.y + rect.h - 6, max(f32(0), rect.w - 16), 2}
}

draw_tab_progress :: proc(app: ^App, rect: SDL.FRect, progress: u16) {
    offset, fraction, visible := tab_progress_fraction(progress)
    if !visible do return
    track := tab_progress_track(rect)
    draw_fill(app.renderer, track, palette.border)
    color := palette.accent
    switch u8(progress >> 8) {
    case 2: color = {248, 113, 113, 255}
    case 4: color = {251, 191, 36, 255}
    case:
    }
    if fraction > 0 {
        draw_fill(app.renderer, {track.x + offset * track.w, track.y, fraction * track.w, track.h}, color)
    } else if u8(progress >> 8) == 2 || u8(progress >> 8) == 4 {
        // A zero-percent failure/pause still has a visible status, not 100% work.
        draw_fill(app.renderer, {track.x, track.y, min(f32(3), track.w), track.h}, color)
    }
}
