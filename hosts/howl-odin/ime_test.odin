package main

import "core:testing"

@(test)
ime_preedit_is_client_local_bounded_state :: proc(t: ^testing.T) {
    app: App
    testing.expect(t, set_ime_preedit(&app, "compose", 2, 3))
    testing.expect_value(t, app.ime_preedit_len, 7)
    testing.expect(t, string(app.ime_preedit[:app.ime_preedit_len]) == "compose")
    testing.expect_value(t, app.ime_preedit_start, i32(2))
    testing.expect_value(t, app.ime_preedit_length, i32(3))
    clear_ime_preedit(&app)
    testing.expect_value(t, app.ime_preedit_len, 0)
}

@(test)
ime_preedit_rejects_oversized_transient_text :: proc(t: ^testing.T) {
    app: App
    huge: [IME_PREEDIT_BYTES + 1]u8
    for &value in huge {
        value = 'x'
    }
    testing.expect(t, !set_ime_preedit(&app, string(huge[:]), 0, 0))
    testing.expect_value(t, app.ime_preedit_len, 0)
}

@(test)
ime_empty_preedit_clears_existing_composition :: proc(t: ^testing.T) {
    app: App
    testing.expect(t, set_ime_preedit(&app, "abc", 1, 1))
    testing.expect(t, set_ime_preedit(&app, "", 0, 0))
    testing.expect_value(t, app.ime_preedit_len, 0)
}

@(test)
ime_preedit_character_cursor_maps_to_utf8_byte_prefix :: proc(t: ^testing.T) {
    value := "aé界z"
    testing.expect_value(t, ime_preedit_cursor_byte_offset(value, -1), 0)
    testing.expect_value(t, ime_preedit_cursor_byte_offset(value, 0), 0)
    testing.expect_value(t, ime_preedit_cursor_byte_offset(value, 1), 1)
    testing.expect_value(t, ime_preedit_cursor_byte_offset(value, 2), 3)
    testing.expect_value(t, ime_preedit_cursor_byte_offset(value, 3), 6)
    testing.expect_value(t, ime_preedit_cursor_byte_offset(value, 99), len(value))
}
