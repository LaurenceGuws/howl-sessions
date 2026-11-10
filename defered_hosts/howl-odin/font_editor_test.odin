package main

import "core:testing"

@(test)
font_editor_edits_raw_override_not_effective_inherited_path :: proc(t: ^testing.T) {
	app: App
	font_test_store(app.terminal_fonts.primary[:], &app.terminal_fonts.primary_len, "/fonts/base.ttf")
	testing.expect(t, begin_font_edit(&app, .Regular))
	testing.expect_value(t, app.settings_font_edit_len, 0)
	testing.expect(t, !app.settings_font_select_all)
	testing.expect(t, append_font_edit_text(&app, "/fonts/custom.ttf"))
	testing.expect_value(t, string(app.settings_font_edit_buffer[:app.settings_font_edit_len]), "/fonts/custom.ttf")
	cancel_font_edit(&app)
	testing.expect(t, !app.settings_font_editing)
}

@(test)
font_editor_custom_regular_labels_blank_styles_as_use_regular :: proc(t: ^testing.T) {
	app: App
	font_test_store(app.terminal_fonts.italic[:], &app.terminal_fonts.italic_len, "/fonts/base-italic.ttf")
	font_test_store(app.terminal_font_overrides.primary[:], &app.terminal_font_overrides.primary_len, "/fonts/custom.ttf")
	storage: [FONT_PATH_BYTES + 32]u8
	testing.expect_value(t, font_field_display_value(&app, .Italic, storage[:]), "Use regular")
}
