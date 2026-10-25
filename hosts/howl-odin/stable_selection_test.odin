package main

import "core:testing"

stable_test_selection :: proc() -> Instance_View {
    return {
        rows = 20,
        columns = 80,
        history_count = 100,
        history_row_base = 50,
        selection_active = true,
        selection_anchor_row = 70,
        selection_anchor_column = 3,
        selection_focus_row = 95,
        selection_focus_column = 7,
        selection_columns = 80,
        selection_alternate_screen = false,
    }
}

@(test)
selection_stable_row_maps_live_history_and_alternate :: proc(t: ^testing.T) {
    row, ok := selection_stable_row(4, 20, 100, 50, false)
    testing.expect(t, ok)
    testing.expect_value(t, row, i32(134))

    alt_row, alt_ok := selection_stable_row(4, 0, 0, 0, true)
    testing.expect(t, alt_ok)
    testing.expect_value(t, alt_row, i32(4))

    _, invalid := selection_stable_row(0, 101, 100, 50, false)
    testing.expect(t, !invalid)
}

@(test)
selection_context_survives_live_output_while_endpoints_are_retained :: proc(t: ^testing.T) {
    view := stable_test_selection()
    validate_selection_context_locked(&view, 80, 20, 120, 50, false)
    testing.expect(t, view.selection_active)
    testing.expect_value(t, view.selection_anchor_row, i32(70))
    testing.expect_value(t, view.selection_focus_row, i32(95))
}

@(test)
selection_context_survives_vertical_geometry_change :: proc(t: ^testing.T) {
    view := stable_test_selection()
    validate_selection_context_locked(&view, 80, 32, 100, 50, false)
    testing.expect(t, view.selection_active)
}

@(test)
selection_context_expires_on_eviction_reflow_or_bank_change :: proc(t: ^testing.T) {
    evicted := stable_test_selection()
    validate_selection_context_locked(&evicted, 80, 20, 80, 71, false)
    testing.expect(t, !evicted.selection_active)

    reflowed := stable_test_selection()
    validate_selection_context_locked(&reflowed, 79, 20, 100, 50, false)
    testing.expect(t, !reflowed.selection_active)

    alternate := stable_test_selection()
    validate_selection_context_locked(&alternate, 80, 20, 0, 0, true)
    testing.expect(t, !alternate.selection_active)
}

@(test)
manual_history_navigation_preserves_stable_selection :: proc(t: ^testing.T) {
    view := stable_test_selection()
    view.history_target_offset = 20
    view.history_anchor_top_row = 130
    view.history_anchor_valid = true

    testing.expect(t, scroll_history_rows(&view, 10))
    testing.expect(t, view.selection_active)
    testing.expect(t, set_history_offset(&view, 5))
    testing.expect(t, view.selection_active)
}

@(test)
return_live_navigation_preserves_selection_but_input_policy_clears_it :: proc(t: ^testing.T) {
    navigation := stable_test_selection()
    navigation.history_target_offset = 20
    navigation.history_anchor_top_row = 130
    navigation.history_anchor_valid = true
    testing.expect(t, return_history_live_navigation(&navigation))
    testing.expect(t, navigation.selection_active)

    input := stable_test_selection()
    input.history_target_offset = 20
    input.history_anchor_top_row = 130
    input.history_anchor_valid = true
    testing.expect(t, return_history_live(&input))
    testing.expect(t, !input.selection_active)
}

@(test)
selection_presentation_without_a_frame_has_no_phantom_span :: proc(t: ^testing.T) {
    first, last := u16(12), u16(40)
    visible := render_selection_span(nil, 70, 3, 72, 7, 80, 0, 0, &first, &last)
    testing.expect_value(t, visible, u8(0))
    testing.expect_value(t, first, u16(0))
    testing.expect_value(t, last, u16(0))
}

@(test)
selection_edge_scroll_direction_respects_bands_and_bounds :: proc(t: ^testing.T) {
    testing.expect_value(
        t,
        selection_edge_scroll_direction(110, 100, 500, 20, true, false),
        i8(1),
    )
    testing.expect_value(
        t,
        selection_edge_scroll_direction(490, 100, 500, 20, false, true),
        i8(-1),
    )
    testing.expect_value(
        t,
        selection_edge_scroll_direction(300, 100, 500, 20, true, true),
        i8(0),
    )
    testing.expect_value(
        t,
        selection_edge_scroll_direction(110, 100, 500, 20, false, true),
        i8(0),
    )
    testing.expect_value(
        t,
        selection_edge_scroll_direction(490, 100, 500, 20, true, false),
        i8(0),
    )
}

@(test)
clearing_selection_disarms_edge_scroll :: proc(t: ^testing.T) {
    view := stable_test_selection()
    view.selection_dragging = true
    view.selection_edge_scroll_rows = 1
    view.selection_pointer_x = 44
    view.selection_pointer_y = 12
    clear_selection_locked(&view)
    testing.expect(t, !view.selection_active)
    testing.expect(t, !view.selection_dragging)
    testing.expect_value(t, view.selection_edge_scroll_rows, i8(0))
    testing.expect_value(t, view.selection_pointer_x, f32(0))
    testing.expect_value(t, view.selection_pointer_y, f32(0))
}

@(test)
selection_expansion_range_applies_stable_endpoints :: proc(t: ^testing.T) {
    view := stable_test_selection()
    info := Selection_Range_Info{
        start_row = 123,
        end_row = 124,
        start_column = 7,
        end_column = 11,
        columns = 80,
        found = 1,
        alternate_screen = 0,
    }
    testing.expect(t, apply_selection_range(&view, info))
    testing.expect(t, view.selection_active)
    testing.expect(t, !view.selection_dragging)
    testing.expect_value(t, view.selection_anchor_row, i32(123))
    testing.expect_value(t, view.selection_focus_row, i32(124))
    testing.expect_value(t, view.selection_anchor_column, u16(7))
    testing.expect_value(t, view.selection_focus_column, u16(11))
}

@(test)
selection_expansion_no_match_clears_existing_range :: proc(t: ^testing.T) {
    view := stable_test_selection()
    testing.expect(t, !apply_selection_range(&view, Selection_Range_Info{}))
    testing.expect(t, !view.selection_active)
}
