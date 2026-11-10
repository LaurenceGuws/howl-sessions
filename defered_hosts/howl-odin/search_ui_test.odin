package main

import "core:testing"

@(test)
search_result_centers_canonical_row_in_history :: proc(t: ^testing.T) {
    view := Instance_View{
        rows = 20,
        columns = 80,
        history_count = 100,
        history_row_base = 50,
    }
    result := Search_Match_Info{
        found = 1,
        row = 100,
        start_column = 4,
        end_column = 8,
        columns = 80,
    }
    testing.expect(t, apply_search_result_locked(&view, result))
    testing.expect_value(t, view.history_target_offset, u32(60))
    testing.expect_value(t, view.history_anchor_top_row, u64(90))
    testing.expect(t, view.history_anchor_valid)
    testing.expect(t, view.search_result_active)
}

@(test)
search_result_expires_when_retained_row_is_evicted :: proc(t: ^testing.T) {
    view := Instance_View{
        rows = 20,
        columns = 80,
        history_count = 100,
        history_row_base = 50,
        search_result_active = true,
        search_state = .Found,
        search_result = {
            found = 1,
            row = 60,
            start_column = 2,
            end_column = 5,
            columns = 80,
        },
    }
    view.history_row_base = 61
    validate_search_result_locked(&view)
    testing.expect(t, !view.search_result_active)
    testing.expect_value(t, view.search_state, Search_State.Stale)
}

@(test)
search_result_expires_on_column_reflow :: proc(t: ^testing.T) {
    view := Instance_View{
        rows = 20,
        columns = 79,
        history_count = 100,
        history_row_base = 50,
        search_result_active = true,
        search_state = .Found,
        search_result = {
            found = 1,
            row = 100,
            start_column = 2,
            end_column = 5,
            columns = 80,
        },
    }
    validate_search_result_locked(&view)
    testing.expect(t, !view.search_result_active)
    testing.expect_value(t, view.search_state, Search_State.Stale)
}

@(test)
search_backspace_removes_one_utf8_scalar :: proc(t: ^testing.T) {
    app: App
    bytes := []u8{'a', 0xe7, 0x95, 0x8c}
    copy(app.search_query[:len(bytes)], bytes)
    app.search_query_len = len(bytes)
    testing.expect(t, backspace_search_query(&app))
    testing.expect_value(t, app.search_query_len, 1)
    testing.expect_value(t, app.search_query[0], u8('a'))
}

@(test)
obsolete_running_search_is_not_currently_running :: proc(t: ^testing.T) {
    view := Instance_View{
        search_running = true,
        search_running_generation = 4,
        search_generation = 5,
    }
    current := view.search_running && view.search_running_generation == view.search_generation
    testing.expect(t, !current)
}
