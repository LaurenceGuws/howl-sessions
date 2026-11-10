package main

import SDL "vendor:sdl3"

// Cell-level scissors break otherwise adjacent SDL texture batches. When the
// complete quad is already inside its requested clip, the pane scissor is
// sufficient. Overhanging glyphs and cropped images retain their exact clip;
// no source coordinates, pixels, colors or drawing order are changed.
canvas_effective_clip :: proc(destination: SDL.FRect, clip, pane: SDL.Rect) -> SDL.Rect {
    if destination.x >= f32(clip.x) && destination.y >= f32(clip.y) &&
       destination.x + destination.w <= f32(clip.x + clip.w) &&
       destination.y + destination.h <= f32(clip.y + clip.h) {
        return pane
    }
    return clip
}
