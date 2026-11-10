package main

import "core:c"
import "core:testing"
import SDL "vendor:sdl3"

@(test)
integer_canvas_command_containment_matches_clip_contract :: proc(t: ^testing.T) {
    command: Canvas_Command_Info
    command.destination_x = 106
    command.destination_y = 102
    command.destination_width = 11
    command.destination_height = 24
    command.clip_x = 106
    command.clip_y = 102
    command.clip_width = 11
    command.clip_height = 24
    testing.expect(t, canvas_command_inside_clip(command))

    command.destination_x = 105
    testing.expect(t, !canvas_command_inside_clip(command))
    command.destination_x = 106
    command.destination_width = 12
    testing.expect(t, !canvas_command_inside_clip(command))
}

@(test)
gl_renderers_bound_canvas_geometry_submission_queue :: proc(t: ^testing.T) {
    testing.expect(t, renderer_needs_bounded_geometry_queue("opengl"))
    testing.expect(t, renderer_needs_bounded_geometry_queue("opengles2"))
    testing.expect(t, !renderer_needs_bounded_geometry_queue("direct3d11"))
    testing.expect(t, !renderer_needs_bounded_geometry_queue("vulkan"))
    testing.expect(t, !renderer_needs_bounded_geometry_queue("gpu"))
    testing.expect(t, !renderer_needs_bounded_geometry_queue("software"))
}

@(test)
contained_texture_quads_share_pane_scissor_without_changing_geometry :: proc(t: ^testing.T) {
    pane := SDL.Rect{0, 46, 960, 700}
    cell := SDL.Rect{106, 102, 11, 24}
    cases := [4]SDL.FRect{
        {107, 103, 9, 22}, {106, 102, 11, 24},
        {106.25, 102.5, 10.5, 23}, {106, 102, 0, 0},
    }
    for destination in cases {
        testing.expect_value(t, canvas_effective_clip(destination, cell, pane), pane)
    }
}

@(test)
overhanging_glyphs_and_cropped_images_keep_their_requested_scissor :: proc(t: ^testing.T) {
    pane := SDL.Rect{0, 46, 960, 700}
    clip := SDL.Rect{106, 102, 11, 24}
    cases := [5]SDL.FRect{
        {105.5, 102, 11, 24}, {106, 101.5, 11, 24},
        {106, 102, 11.5, 24}, {106, 102, 11, 24.5},
        {-100, 46, 640, 400},
    }
    for destination in cases {
        testing.expect_value(t, canvas_effective_clip(destination, clip, pane), clip)
    }
}

@(test)
canvas_reset_can_preserve_failure_diagnostic :: proc(t: ^testing.T) {
    view: Instance_View
    set_canvas_error(&view, "boom")
    testing.expect_value(t, view.canvas_error_len, 4)

    reset_canvas(&view, false)
    testing.expect_value(t, string(view.canvas_error[:view.canvas_error_len]), "boom")

    reset_canvas(&view)
    testing.expect_value(t, view.canvas_error_len, 0)
}

@(test)
canvas_renderer_restart_keeps_only_last_accepted_frame :: proc(t: ^testing.T) {
    view: Instance_View
    view.canvas_commands = make([]Canvas_Command_Info, 1)
    view.canvas_scale = 1
    view.canvas_frame_font_pixels = 15
    view.canvas_frame_background_rgba = 0x112233ff
    view.canvas_surface_width = 640
    view.canvas_surface_height = 480
    view.canvas_frame_revision = 9
    view.canvas_font_pixels = 15
    view.canvas_worker_has_frame = true

    testing.expect(t, canvas_frame_available(&view))
    restart_canvas_renderer(&view)

    testing.expect(t, canvas_frame_available(&view))
    testing.expect_value(t, len(view.canvas_commands), 1)
    testing.expect_value(t, view.canvas_scale, f32(1))
    testing.expect_value(t, view.canvas_frame_font_pixels, u16(15))
    testing.expect_value(t, view.canvas_frame_background_rgba, u32(0x112233ff))
    testing.expect_value(t, view.canvas_surface_width, u16(640))
    testing.expect_value(t, view.canvas_surface_height, u16(480))
    testing.expect_value(t, view.canvas_frame_revision, u64(9))
    testing.expect_value(t, view.canvas_font_pixels, u16(0))
    testing.expect(t, !view.canvas_worker_has_frame)
    testing.expect(t, !canvas_frame_current(&view))

    reset_canvas(&view)
    testing.expect(t, !canvas_frame_available(&view))
    testing.expect_value(t, len(view.canvas_commands), 0)
    testing.expect_value(t, view.canvas_surface_width, u16(0))
    testing.expect_value(t, view.canvas_surface_height, u16(0))
}

@(test)
canvas_geometry_builds_exact_textured_quad :: proc(t: ^testing.T) {
    scratch := new(Canvas_Geometry_Scratch)
    testing.expect(t, scratch != nil)
    defer if scratch != nil do free(scratch)
    count := 0
    command := Canvas_Command_Info{
        color_rgba = 0x80402010,
        source_x = 16,
        source_y = 8,
        source_width = 16,
        source_height = 8,
        resource_width = 64,
        resource_height = 32,
        tag = 1,
    }
    destination := SDL.FRect{10, 20, 30, 40}

    canvas_geometry_append(command, destination, scratch, &count)

    testing.expect_value(t, count, 1)
    testing.expect_value(t, scratch.vertices[0].position, SDL.FPoint{10, 20})
    testing.expect_value(t, scratch.vertices[1].position, SDL.FPoint{40, 20})
    testing.expect_value(t, scratch.vertices[2].position, SDL.FPoint{40, 60})
    testing.expect_value(t, scratch.vertices[3].position, SDL.FPoint{10, 60})
    testing.expect_value(t, scratch.vertices[0].tex_coord, SDL.FPoint{0.25, 0.25})
    testing.expect_value(t, scratch.vertices[2].tex_coord, SDL.FPoint{0.5, 0.5})
    testing.expect_value(t, scratch.vertices[0].color, SDL.FColor{16.0 / 255.0, 32.0 / 255.0, 64.0 / 255.0, 128.0 / 255.0})
    testing.expect_value(t, scratch.indices[0], c.int(0))
    testing.expect_value(t, scratch.indices[1], c.int(1))
    testing.expect_value(t, scratch.indices[2], c.int(2))
    testing.expect_value(t, scratch.indices[3], c.int(0))
    testing.expect_value(t, scratch.indices[4], c.int(2))
    testing.expect_value(t, scratch.indices[5], c.int(3))
}

@(test)
canvas_solid_geometry_fills_bounded_scratch_with_finite_untextured_quads :: proc(t: ^testing.T) {
    scratch := new(Canvas_Geometry_Scratch)
    testing.expect(t, scratch != nil)
    defer if scratch != nil do free(scratch)
    count := 0
    command := Canvas_Command_Info{tag = 0, color_rgba = 0x80402010}
    destination := SDL.FRect{-1.5, 2.25, 3.5, 4.75}
    for _ in 0..<CANVAS_GEOMETRY_QUADS {
        canvas_geometry_append(command, destination, scratch, &count)
    }
    testing.expect_value(t, count, CANVAS_GEOMETRY_QUADS)
    untextured := true
    for vertex in scratch.vertices {
        untextured = untextured && vertex.tex_coord.x == 0 && vertex.tex_coord.y == 0
    }
    testing.expect(t, untextured)
    testing.expect_value(t, scratch.vertices[0].color, SDL.FColor{16.0 / 255.0, 32.0 / 255.0, 64.0 / 255.0, 128.0 / 255.0})
    testing.expect_value(t, scratch.vertices[len(scratch.vertices) - 1].position, SDL.FPoint{-1.5, 7})
    testing.expect_value(t, scratch.indices[len(scratch.indices) - 1], c.int(len(scratch.vertices) - 1))
}
