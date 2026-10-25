package main

import SDL "vendor:sdl3"

// The palette uses the same bounded visible rows for paint and hit-testing.
// Selection reveals a page without a retained widget tree or idle timer.
Palette_Layout :: struct {
    box: SDL.FRect,
    first, count: int,
}

palette_layout :: proc(width, height: f32, selection: int) -> Palette_Layout {
    available_height := max(f32(0), height - 32)
    count := min(len(PALETTE_ACTIONS), max(0, int((available_height - 102) / 36)))
    box_height := min(available_height, f32(102 + count * 36))
    box_width := min(f32(580), max(f32(0), width - 32))
    first := 0
    if count > 0 {
        selected := clamp(selection, 0, len(PALETTE_ACTIONS) - 1)
        first = min((selected / count) * count, max(0, len(PALETTE_ACTIONS) - count))
    }
    return {{max(f32(0), (width - box_width) / 2), min(f32(92), max(f32(0), (height - box_height) / 2)), box_width, box_height}, first, count}
}

palette_row_rect :: proc(layout: Palette_Layout, visible_index: int) -> SDL.FRect {
    if visible_index < 0 || visible_index >= layout.count do return {}
    return {layout.box.x + 18, layout.box.y + 62 + f32(visible_index) * 36, max(f32(0), layout.box.w - 36), 34}
}
