package main

import "core:fmt"
import SDL "vendor:sdl3"
import TTF "vendor:sdl3/ttf"

Font_Edit_Field :: enum u8 {
	Regular,
	Italic,
	Bold,
	Bold_Italic,
	Fallback,
	Secondary_Fallback,
}

FONT_EDIT_FIELD_COUNT :: 6
FONT_SETTINGS_ITEM_COUNT :: 1 + FONT_EDIT_FIELD_COUNT

font_edit_field_at :: proc(index: int) -> (Font_Edit_Field, bool) {
	if index < 0 || index >= FONT_EDIT_FIELD_COUNT do return .Regular, false
	return Font_Edit_Field(index), true
}

font_field_label :: proc(field: Font_Edit_Field) -> string {
	switch field {
	case .Regular:            return "Regular"
	case .Italic:             return "Italic"
	case .Bold:               return "Bold"
	case .Bold_Italic:        return "Bold italic"
	case .Fallback:           return "Fallback 1"
	case .Secondary_Fallback: return "Fallback 2"
	}
	return ""
}

font_override_value :: proc(app: ^App, field: Font_Edit_Field) -> string {
	if app == nil do return ""
	switch field {
	case .Regular:            return terminal_primary_font(&app.terminal_font_overrides)
	case .Italic:             return terminal_italic_font(&app.terminal_font_overrides)
	case .Bold:               return terminal_bold_font(&app.terminal_font_overrides)
	case .Bold_Italic:        return terminal_bold_italic_font(&app.terminal_font_overrides)
	case .Fallback:           return terminal_fallback_font(&app.terminal_font_overrides)
	case .Secondary_Fallback: return terminal_secondary_fallback_font(&app.terminal_font_overrides)
	}
	return ""
}

font_effective_value :: proc(app: ^App, field: Font_Edit_Field) -> string {
	if app == nil do return ""
	switch field {
	case .Regular:
		return effective_terminal_primary_font(&app.terminal_fonts, &app.terminal_font_overrides)
	case .Italic:
		return effective_terminal_italic_font(&app.terminal_fonts, &app.terminal_font_overrides)
	case .Bold:
		return effective_terminal_bold_font(&app.terminal_fonts, &app.terminal_font_overrides)
	case .Bold_Italic:
		return effective_terminal_bold_italic_font(&app.terminal_fonts, &app.terminal_font_overrides)
	case .Fallback:
		return effective_terminal_fallback_font(&app.terminal_fonts, &app.terminal_font_overrides)
	case .Secondary_Fallback:
		return effective_terminal_secondary_fallback_font(&app.terminal_fonts, &app.terminal_font_overrides)
	}
	return ""
}

font_field_display_value :: proc(app: ^App, field: Font_Edit_Field, storage: []u8) -> string {
	override := font_override_value(app, field)
	if len(override) != 0 do return override

	if (field == .Italic || field == .Bold || field == .Bold_Italic) &&
	   app.terminal_font_overrides.primary_len != 0 {
		return "Use regular"
	}
	effective := font_effective_value(app, field)
	if len(effective) == 0 do return "Use regular"
	return fmt.bprintf(storage, "Inherit · %s", effective)
}

font_family_choice_row :: proc(body: SDL.FRect, scroll: f32) -> SDL.FRect {
	return {body.x, body.y + 82 - scroll, max(f32(0), body.w - 8), 44}
}

font_settings_row :: proc(body: SDL.FRect, scroll: f32, index: int) -> SDL.FRect {
	return {body.x, body.y + 142 + f32(index) * 48 - scroll, max(f32(0), body.w - 8), 44}
}

font_settings_value :: proc(row: SDL.FRect) -> SDL.FRect {
	return settings_profile_value(row)
}

font_editor_input_rect :: proc(app: ^App, width, height: f32) -> (SDL.FRect, bool) {
	if app == nil || !app.settings_open || app.settings_page != .Appearance || !app.settings_font_editing {
		return {}, false
	}
	body := settings_layout(width, height).body
	index := int(app.settings_font_edit_field)
	if index < 0 || index >= FONT_EDIT_FIELD_COUNT do return {}, false
	rect := font_settings_value(font_settings_row(body, app.settings_scroll_y, index))
	return rect, rect.y >= body.y && rect.y + rect.h <= body.y + body.h
}

begin_font_edit :: proc(app: ^App, field: Font_Edit_Field) -> bool {
	if app == nil do return false
	source := font_override_value(app, field)
	if len(source) >= len(app.settings_font_edit_buffer) {
		set_settings_notice(app, "Font path exceeds editor bound")
		return false
	}
	app.settings_font_edit_len = len(source)
	if len(source) != 0 do copy(app.settings_font_edit_buffer[:len(source)], transmute([]u8)source)
	app.settings_font_edit_field = field
	app.settings_font_editing = true
	app.settings_font_select_all = len(source) != 0
	app.settings_notice_len = 0
	clear_ime_preedit(app)
	return true
}

append_font_edit_text :: proc(app: ^App, text: string) -> bool {
	if app == nil || !app.settings_font_editing || len(text) == 0 do return false
	used := app.settings_font_select_all ? 0 : app.settings_font_edit_len
	if used + len(text) >= len(app.settings_font_edit_buffer) {
		set_settings_notice(app, "Font path limit reached")
		return false
	}
	app.settings_font_edit_len = used
	app.settings_font_select_all = false
	copy(
		app.settings_font_edit_buffer[used:used + len(text)],
		transmute([]u8)text,
	)
	app.settings_font_edit_len += len(text)
	return true
}

backspace_font_edit :: proc(app: ^App) -> bool {
	if app == nil || !app.settings_font_editing || app.settings_font_edit_len == 0 do return false
	if app.settings_font_select_all {
		app.settings_font_edit_len = 0
		app.settings_font_select_all = false
		return true
	}
	next := app.settings_font_edit_len - 1
	for next > 0 && app.settings_font_edit_buffer[next] & 0xc0 == 0x80 do next -= 1
	app.settings_font_edit_len = next
	return true
}

cancel_font_edit :: proc(app: ^App) {
	if app == nil do return
	app.settings_font_editing = false
	app.settings_font_select_all = false
	app.settings_font_edit_len = 0
	clear_ime_preedit(app)
}

set_font_override_field :: proc(fonts: ^Desktop_Fonts, field: Font_Edit_Field, value: string) -> bool {
	if fonts == nil do return false
	switch field {
	case .Regular:
		return copy_optional_font_path(fonts.primary[:], &fonts.primary_len, value)
	case .Italic:
		return copy_optional_font_path(fonts.italic[:], &fonts.italic_len, value)
	case .Bold:
		return copy_optional_font_path(fonts.bold[:], &fonts.bold_len, value)
	case .Bold_Italic:
		return copy_optional_font_path(fonts.bold_italic[:], &fonts.bold_italic_len, value)
	case .Fallback:
		return copy_optional_font_path(fonts.fallback[:], &fonts.fallback_len, value)
	case .Secondary_Fallback:
		return copy_optional_font_path(fonts.secondary[:], &fonts.secondary_len, value)
	}
	return false
}

restart_all_font_renderers :: proc(app: ^App) {
	if app == nil do return
	for tab_index in 0..<app.tab_count {
		for view in app.tabs[tab_index].panes {
			if view != nil do refresh_terminal_presentation(app, view)
		}
	}
}

reload_terminal_ttf :: proc(app: ^App) -> bool {
	if app == nil || app.terminal_font == nil do return false
	path := effective_terminal_primary_font(&app.terminal_fonts, &app.terminal_font_overrides)
	if len(path) == 0 do return false
	replacement := TTF.OpenFont(cstring(raw_data(path)), f32(app.terminal_font_pixels))
	if replacement == nil do return false
	if !set_font_display_scale(replacement, f32(app.terminal_font_pixels), app.text_scale) {
		TTF.CloseFont(replacement)
		return false
	}
	previous := app.terminal_font
	app.terminal_font = replacement
	TTF.CloseFont(previous)
	return true
}

commit_font_edit :: proc(app: ^App) -> bool {
	if app == nil || !app.settings_font_editing do return false
	value := string(app.settings_font_edit_buffer[:app.settings_font_edit_len])
	field := app.settings_font_edit_field
	previous := app.terminal_font_overrides
	if !set_font_override_field(&app.terminal_font_overrides, field, value) {
		set_settings_notice(app, "Font path must be absolute, exist, or be blank to inherit")
		return false
	}
	if field == .Regular && !reload_terminal_ttf(app) {
		app.terminal_font_overrides = previous
		set_settings_notice(app, "Regular font could not be opened")
		return false
	}
	restart_all_font_renderers(app)
	cancel_font_edit(app)
	save_user_config(app)
	set_settings_notice(app, "Font recipe saved · live panes rebuilding")
	return true
}

handle_font_edit_key :: proc(app: ^App, event: ^SDL.Event) -> bool {
	if app == nil || !app.settings_font_editing do return false
	if event.type != .KEY_DOWN do return true
	if event.key.key == SDL.K_A && (.LCTRL in event.key.mod || .RCTRL in event.key.mod) {
		app.settings_font_select_all = true
		return true
	}
	switch event.key.key {
	case SDL.K_ESCAPE:
		cancel_font_edit(app)
		set_settings_notice(app, "Font edit canceled")
	case SDL.K_RETURN:
		_ = commit_font_edit(app)
	case SDL.K_BACKSPACE:
		_ = backspace_font_edit(app)
	case SDL.K_END, SDL.K_RIGHT:
		app.settings_font_select_all = false
	case SDL.K_DELETE:
		if app.settings_font_select_all do _ = backspace_font_edit(app)
	case:
		// TEXT_INPUT owns printable committed text while the editor is active.
	}
	return true
}

handle_font_settings_key :: proc(app: ^App, event: ^SDL.Event) -> bool {
	if app == nil || event.type != .KEY_DOWN do return false
	app.settings_font_field = clamp(app.settings_font_field, 0, FONT_SETTINGS_ITEM_COUNT - 1)
	switch event.key.key {
	case SDL.K_TAB:
		app.settings_content_focus = false
	case SDL.K_UP:
		app.settings_font_field = (app.settings_font_field + FONT_SETTINGS_ITEM_COUNT - 1) % FONT_SETTINGS_ITEM_COUNT
		settings_reveal_selection(app)
	case SDL.K_DOWN:
		app.settings_font_field = (app.settings_font_field + 1) % FONT_SETTINGS_ITEM_COUNT
		settings_reveal_selection(app)
	case SDL.K_RETURN:
		if app.settings_font_field == 0 {
			_ = open_font_chooser(app)
		} else if field, ok := font_edit_field_at(app.settings_font_field - 1); ok {
			_ = begin_font_edit(app, field)
		}
	case:
		return true
	}
	return true
}

draw_font_settings :: proc(app: ^App, body: SDL.FRect) {
	if app == nil do return

	family_row := font_family_choice_row(body, app.settings_scroll_y)
	family_selected := app.settings_content_focus && app.settings_font_field == 0
	if family_selected do draw_fill(app.renderer, family_row, palette.tab_active)
	settings_clipped_text(
		app,
		{family_row.x + 10, family_row.y + 13, min(f32(174), family_row.w * 0.46) - 18, 22},
		"Font family",
		palette.text_muted,
	)
	family_value := settings_profile_value(family_row)
	settings_draw_button(app, family_value, "Choose family…", true, family_selected)

	settings_clipped_text(
		app,
		{body.x + 10, body.y + 126 - app.settings_scroll_y, max(f32(0), body.w - 20), 18},
		"Advanced exact paths",
		palette.text_muted,
	)

	for index in 0..<FONT_EDIT_FIELD_COUNT {
		field, _ := font_edit_field_at(index)
		row := font_settings_row(body, app.settings_scroll_y, index)
		selected := app.settings_content_focus && app.settings_font_field == index + 1
		if selected do draw_fill(app.renderer, row, palette.tab_active)
		value_rect := font_settings_value(row)
		settings_clipped_text(
			app,
			{row.x + 10, row.y + 13, max(f32(0), value_rect.x - row.x - 18), 22},
			font_field_label(field),
			palette.text_muted,
		)
		editing := app.settings_font_editing && app.settings_font_edit_field == field
		draw_fill(app.renderer, value_rect, editing && app.settings_font_select_all ? palette.tab_active : palette.terminal_bg)
		draw_outline(app.renderer, value_rect, editing ? palette.accent : palette.border)
		storage: [FONT_PATH_BYTES + 32]u8
		value := font_field_display_value(app, field, storage[:])
		if editing do value = string(app.settings_font_edit_buffer[:app.settings_font_edit_len])
		settings_clipped_text(
			app,
			{value_rect.x + 7, value_rect.y + 8, max(f32(0), value_rect.w - 14), value_rect.h - 8},
			value,
			palette.text,
		)
	}
}
