package main

import "core:testing"
import "core:math"
import SDL "vendor:sdl3"

@(test)
attached_size_stays_fixed_until_explicit_take :: proc(t: ^testing.T) {
    state: Instance_Size_Control
    shape := Pane_Geometry{30, 106, 11, 24}
    _, automatic := next_size_task(&state, shape)
    testing.expect(t, !automatic)
    set_size_intent(&state, true)
    first, ok := next_size_task(&state, shape)
    testing.expect(t, ok)
    testing.expect_value(t, first.action, u8(1))
    testing.expect_value(t, state.applied, Pane_Geometry{})
    _, duplicate := next_size_task(&state, {40, 120, 11, 24})
    testing.expect(t, !duplicate)
    testing.expect(t, finish_size_task(&state, first, 0))
    testing.expect_value(t, state.mode, Instance_Size_Mode.Following)
    testing.expect_value(t, state.applied, shape)
    _, unchanged := next_size_task(&state, shape)
    testing.expect(t, !unchanged)
    next, resized := next_size_task(&state, {40, 120, 11, 24})
    testing.expect(t, resized)
    testing.expect_value(t, next.action, u8(0))
}

@(test)
size_authority_loss_is_nonfatal_and_never_reclaims_automatically :: proc(t: ^testing.T) {
    state := Instance_Size_Control{mode = .Following}
    task, ok := next_size_task(&state, {40, 120, 11, 24})
    testing.expect(t, ok)
    testing.expect_value(t, task.action, u8(0))
    testing.expect(t, !finish_size_task(&state, task, BRIDGE_SIZE_NOT_LEADER))
    testing.expect(t, !control_failure_is_fatal(.Resize, BRIDGE_SIZE_NOT_LEADER))
    testing.expect(t, !control_failure_is_fatal(.Resize, BRIDGE_SIZE_REJECTED))
    testing.expect(t, control_failure_is_fatal(.Resize, 2))
    testing.expect(t, control_failure_is_fatal(.Text, BRIDGE_SIZE_NOT_LEADER))
    _, retry := next_size_task(&state, {40, 120, 11, 24})
    testing.expect(t, !retry)
    set_size_intent(&state, true)
    explicit, retaken := next_size_task(&state, {40, 120, 11, 24})
    testing.expect(t, retaken)
    testing.expect_value(t, explicit.action, u8(1))
}

@(test)
stopped_size_intent_survives_queued_and_inflight_old_completions :: proc(t: ^testing.T) {
    state := Instance_Size_Control{mode = .Taking}
    task, ok := next_size_task(&state, {30, 106, 11, 24})
    testing.expect(t, ok)
    set_size_intent(&state, false)
    testing.expect(t, !size_task_current(&state, task))
    testing.expect(t, !finish_size_task(&state, task, 0))
    testing.expect_value(t, state.mode, Instance_Size_Mode.Fixed)
    testing.expect(t, !state.pending)
    testing.expect_value(t, state.applied, Pane_Geometry{})
    set_size_intent(&state, true)
    older, _ := next_size_task(&state, {30, 106, 11, 24})
    set_size_intent(&state, false)
    set_size_intent(&state, true)
    testing.expect(t, !finish_size_task(&state, older, BRIDGE_SIZE_NOT_LEADER))
    newer, admitted := next_size_task(&state, {40, 130, 11, 24})
    testing.expect(t, admitted)
    testing.expect_value(t, newer.action, u8(1))
    testing.expect(t, newer.generation != older.generation)
}

@(test)
size_reset_for_new_font_does_not_reacquire_or_forget_pending_owner :: proc(t: ^testing.T) {
    state := Instance_Size_Control{mode = .Following, applied = {30, 106, 11, 24}}
    task, ok := next_size_task(&state, {30, 106, 12, 26})
    testing.expect(t, ok)
    state.applied = {}
    _, duplicate := next_size_task(&state, {28, 96, 12, 26})
    testing.expect(t, !duplicate)
    testing.expect(t, finish_size_task(&state, task, 0))
    next, changed := next_size_task(&state, {28, 96, 12, 26})
    testing.expect(t, changed)
    testing.expect_value(t, next.action, u8(0))
}

@(test)
pane_size_uses_backing_pixels_and_rejects_invalid_geometry :: proc(t: ^testing.T) {
    geometry, ok := pane_geometry(1166, 720, 1, 11, 24)
    testing.expect(t, ok)
    testing.expect_value(t, geometry, Pane_Geometry{30, 106, 11, 24})
    scaled, scaled_ok := pane_geometry(700, 400, 1.7, 12, 27)
    testing.expect(t, scaled_ok)
    testing.expect_value(t, scaled, Pane_Geometry{25, 99, 12, 27})
    _, zero := pane_geometry(700, 400, 0, 12, 27)
    _, nan := pane_geometry(math.nan_f32(), 400, 1, 12, 27)
    _, inf := pane_geometry(700, math.inf_f32(1), 1, 12, 27)
    _, missing := pane_geometry(700, 400, 1, 0, 27)
    testing.expect(t, !zero && !nan && !inf && !missing)
}

@(test)
local_resize_waits_for_the_accepted_presentation_lattice :: proc(t: ^testing.T) {
    view := Instance_View{
        route_kind = .Local,
        canvas_font_pixels = 15,
        canvas_render_scale = 1,
    }

    testing.expect(t, local_canvas_resize_ready(&view, 15, 1))
    testing.expect(t, !local_canvas_resize_ready(&view, 26, 1.7))

    view.native_presentation.pending = true
    view.canvas_font_pixels = 26
    view.canvas_render_scale = 1.7
    testing.expect(t, !local_canvas_resize_ready(&view, 26, 1.7))

    view.native_presentation.pending = false
    view.native_presentation.inflight = true
    testing.expect(t, !local_canvas_resize_ready(&view, 26, 1.7))

    view.native_presentation.inflight = false
    view.native_presentation.waiting = true
    testing.expect(t, !local_canvas_resize_ready(&view, 26, 1.7))

    view.native_presentation.waiting = false
    testing.expect(t, local_canvas_resize_ready(&view, 26, 1.7))
}

@(test)
size_actions_are_rebindable_without_hardcoded_shortcuts :: proc(t: ^testing.T) {
    app: App
    testing.expect(t, initialize_key_mappings(&app))
    testing.expect_value(t, action_binding_text(&app, .Take_Size_Control), "")
    testing.expect_value(t, set_action_binding(&app, .Take_Size_Control, "Ctrl+Shift+G"), Binding_Update_Result.Applied)
    testing.expect_value(t, action_binding_text(&app, .Take_Size_Control), "Ctrl+Shift+G")
    testing.expect(t, !action_enabled(&app, .Take_Size_Control))
    testing.expect(t, !action_enabled(&app, .Stop_Resizing))
}

@(test)
terminal_surface_centers_integer_cell_extent_in_available_content :: proc(t: ^testing.T) {
    centered, ok := centered_terminal_surface({10, 20, 101, 51}, 1, 90, 40)
    testing.expect(t, ok)
    testing.expect_value(t, centered, SDL.FRect{15, 25, 90, 40})

    scaled, scaled_ok := centered_terminal_surface({3, 4, 100, 50}, 2, 190, 90)
    testing.expect(t, scaled_ok)
    testing.expect_value(t, scaled, SDL.FRect{5.5, 6.5, 95, 45})

    oversized, oversized_ok := centered_terminal_surface({7, 9, 80, 40}, 1, 100, 50)
    testing.expect(t, oversized_ok)
    testing.expect_value(t, oversized, SDL.FRect{7, 9, 80, 40})

    _, zero := centered_terminal_surface({0, 0, 80, 40}, 1, 0, 20)
    _, bad_scale := centered_terminal_surface({0, 0, 80, 40}, 0, 40, 20)
    testing.expect(t, !zero && !bad_scale)
}
