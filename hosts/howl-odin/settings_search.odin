package main

import "core:c"
import "core:fmt"
import "core:strings"
import SDL "vendor:sdl3"

SETTINGS_SEARCH_BYTES :: 128
MAX_SETTINGS_SEARCH_RESULTS :: 7 + len(KEY_MAPPING_DEFINITIONS) + MAX_PROFILES

Settings_Search_Result_Kind :: enum u8 {
	Page,
	Mapping,
	Profile,
}

Settings_Search_Result :: struct {
	kind: Settings_Search_Result_Kind,
	page: Settings_Page,
	index: int,
}

Settings_Search_Page_Definition :: struct {
	page: Settings_Page,
	label: string,
	keywords: string,
}

SETTINGS_SEARCH_PAGES :: [7]Settings_Search_Page_Definition{
	{.Startup, "Startup", "default profile instance launch attach startup"},
	{.Interaction, "Interaction", "mouse pointer focus scrollback selection paste interaction"},
	{.Appearance, "Appearance", "font size appearance presentation"},
	{.Color_Schemes, "Color schemes", "color colours theme scheme palette"},
	{.Mappings, "Mappings", "mappings shortcuts keybindings commands actions"},
	{.Profile_Defaults, "Profiles", "profiles recipes launch attach environment"},
	{.Profile_Home, "Profile", "profile recipe editor command cwd endpoint environment"},
}

ascii_fold_byte :: proc(value: u8) -> u8 {
	return value >= 'A' && value <= 'Z' ? value + ('a' - 'A') : value
}

contains_ascii_fold :: proc(haystack, needle: string) -> bool {
	if len(needle) == 0 {
		return true
	}
	if len(needle) > len(haystack) {
		return false
	}
	h := transmute([]u8)haystack
	n := transmute([]u8)needle
	for start in 0..=len(h) - len(n) {
		matched := true
		for offset in 0..<len(n) {
			if ascii_fold_byte(h[start + offset]) != ascii_fold_byte(n[offset]) {
				matched = false
				break
			}
		}
		if matched {
			return true
		}
	}
	return false
}

settings_search_query :: proc(app: ^App) -> string {
	if app == nil || app.settings_search_query_len <= 0 {
		return ""
	}
	return string(app.settings_search_query[:app.settings_search_query_len])
}

settings_search_append_result :: proc(app: ^App, result: Settings_Search_Result) {
	if app == nil || app.settings_search_result_count >= len(app.settings_search_results) {
		return
	}
	app.settings_search_results[app.settings_search_result_count] = result
	app.settings_search_result_count += 1
}

settings_search_refresh :: proc(app: ^App) {
	if app == nil {
		return
	}
	app.settings_search_result_count = 0
	app.settings_search_selection = 0
	query := settings_search_query(app)
	if len(query) == 0 {
		return
	}
	for definition in SETTINGS_SEARCH_PAGES {
		if contains_ascii_fold(definition.label, query) || contains_ascii_fold(definition.keywords, query) {
			settings_search_append_result(app, {.Page, definition.page, -1})
		}
	}
	for definition, index in KEY_MAPPING_DEFINITIONS {
		if contains_ascii_fold(mapping_label(definition), query) || contains_ascii_fold(mapping_id(definition), query) ||
		   contains_ascii_fold(mapping_binding_text(app, index), query) {
			settings_search_append_result(app, {.Mapping, .Mappings, index})
		}
	}
	for index in 0..<app.profile_count {
		profile := app.profiles[index]
		if profile != nil &&
		   (contains_ascii_fold(profile_name(profile), query) || contains_ascii_fold(profile_id(profile), query)) {
			settings_search_append_result(app, {.Profile, .Profile_Home, index})
		}
	}
}

open_settings_search :: proc(app: ^App) {
	if app == nil || !app.settings_open {
		return
	}
	cancel_profile_edit(app)
	app.settings_binding_recording = false
	app.settings_search_open = true
	app.settings_search_query_len = 0
	app.settings_search_result_count = 0
	app.settings_search_selection = 0
	app.settings_content_focus = false
	app.settings_notice_len = 0
	clear_ime_preedit(app)
}

close_settings_search :: proc(app: ^App) {
	if app == nil {
		return
	}
	app.settings_search_open = false
	app.settings_search_query_len = 0
	app.settings_search_result_count = 0
	app.settings_search_selection = 0
	clear_ime_preedit(app)
}

append_settings_search_query :: proc(app: ^App, text: string) -> bool {
	if app == nil || !app.settings_search_open || len(text) == 0 ||
	   app.settings_search_query_len + len(text) >= len(app.settings_search_query) {
		return false
	}
	copy(
		app.settings_search_query[app.settings_search_query_len:app.settings_search_query_len + len(text)],
		transmute([]u8)text,
	)
	app.settings_search_query_len += len(text)
	settings_search_refresh(app)
	return true
}

backspace_settings_search_query :: proc(app: ^App) -> bool {
	if app == nil || !app.settings_search_open || app.settings_search_query_len == 0 {
		return false
	}
	next := app.settings_search_query_len - 1
	for next > 0 && app.settings_search_query[next] & 0xc0 == 0x80 {
		next -= 1
	}
	app.settings_search_query_len = next
	settings_search_refresh(app)
	return true
}

selected_settings_search_result :: proc(app: ^App) -> (Settings_Search_Result, bool) {
	if app == nil || app.settings_search_result_count == 0 ||
	   app.settings_search_selection < 0 || app.settings_search_selection >= app.settings_search_result_count {
		return {}, false
	}
	return app.settings_search_results[app.settings_search_selection], true
}

apply_settings_search_result :: proc(app: ^App, result: Settings_Search_Result) -> bool {
	if app == nil {
		return false
	}
	close_settings_search(app)
	app.settings_page = result.page
	app.settings_content_focus = false
	switch result.kind {
	case .Page:
		return true
	case .Mapping:
		if _, ok := mapping_definition_at(result.index); !ok {
			return false
		}
		app.settings_page = .Mappings
		app.settings_mapping_selection = result.index
		app.settings_content_focus = true
		return true
	case .Profile:
		if profile_at(app, result.index) == nil {
			return false
		}
		app.settings_page = .Profile_Home
		app.settings_profile_selection = result.index
		app.settings_profile_field = int(Profile_Edit_Field.Name)
		app.settings_profile_env_selection = 0
		app.settings_content_focus = true
		return true
	}
	return false
}

handle_settings_search_key :: proc(app: ^App, event: ^SDL.Event) -> bool {
	if app == nil || !app.settings_search_open {
		return false
	}
	if event.type != .KEY_DOWN {
		return true
	}
	switch event.key.key {
	case SDL.K_ESCAPE:
		close_settings_search(app)
	case SDL.K_BACKSPACE:
		_ = backspace_settings_search_query(app)
	case SDL.K_UP:
		if app.settings_search_result_count != 0 {
			app.settings_search_selection = (app.settings_search_selection + app.settings_search_result_count - 1) % app.settings_search_result_count
		}
	case SDL.K_DOWN, SDL.K_TAB:
		if app.settings_search_result_count != 0 {
			app.settings_search_selection = (app.settings_search_selection + 1) % app.settings_search_result_count
		}
	case SDL.K_RETURN:
		if result, ok := selected_settings_search_result(app); ok {
			_ = apply_settings_search_result(app, result)
		}
	case:
		// Printable committed text arrives through TEXT_INPUT.
	}
	return true
}

settings_search_result_label :: proc(app: ^App, result: Settings_Search_Result, storage: []u8) -> string {
	switch result.kind {
	case .Page:
		return settings_page_title(result.page)
	case .Mapping:
		if definition, ok := mapping_definition_at(result.index); ok {
			return fmt.bprintf(storage, "Mapping · %s", mapping_label(definition))
		}
	case .Profile:
		if profile := profile_at(app, result.index); profile != nil {
			return fmt.bprintf(storage, "Profile · %s", profile_name(profile))
		}
	}
	return "Unavailable"
}

SETTINGS_SEARCH_VISIBLE_RESULTS :: 10

settings_search_content_rect :: proc(width, height: f32) -> SDL.FRect {
	panel := settings_panel_rect(width, height)
	return {panel.x + 178, panel.y, panel.w - 178, panel.h}
}

settings_search_input_rect :: proc(width, height: f32) -> SDL.FRect {
	content := settings_search_content_rect(width, height)
	return {content.x + 18, content.y + 18, max(f32(180), content.w - 36), 38}
}

settings_search_visible_start :: proc(app: ^App) -> int {
	if app == nil || app.settings_search_result_count <= SETTINGS_SEARCH_VISIBLE_RESULTS {
		return 0
	}
	start := app.settings_search_selection - SETTINGS_SEARCH_VISIBLE_RESULTS / 2
	return clamp(start, 0, app.settings_search_result_count - SETTINGS_SEARCH_VISIBLE_RESULTS)
}

settings_search_result_rect :: proc(width, height: f32, visible_index: int) -> SDL.FRect {
	field := settings_search_input_rect(width, height)
	return {field.x, field.y + field.h + 12 + f32(visible_index) * 34, field.w, 32}
}

draw_settings_search :: proc(app: ^App, width, height: f32) {
	if app == nil || !app.settings_search_open {
		return
	}
	content := settings_search_content_rect(width, height)
	draw_fill(app.renderer, content, palette.title_bg)
	field := settings_search_input_rect(width, height)
	draw_fill(app.renderer, field, palette.terminal_bg)
	draw_outline(app.renderer, field, palette.accent)
	query := settings_search_query(app)
	query_color := palette.text
	if len(query) == 0 {
		query = "Search Settings"
		query_color = palette.text_muted
	}
	clip := SDL.Rect{c.int(field.x + 8), c.int(field.y), c.int(field.w - 16), c.int(field.h)}
	_ = SDL.SetRenderClipRect(app.renderer, &clip)
	draw_text(app, app.ui_font, query, field.x + 10, field.y + 10, query_color)
	_ = SDL.SetRenderClipRect(app.renderer, nil)

	if app.settings_search_query_len == 0 {
		draw_text(app, app.ui_font, "Pages · actions · profiles", field.x, field.y + 58, palette.text_muted)
		draw_text(app, app.ui_font, "Ctrl+F search · Esc close", field.x, field.y + 84, palette.text_muted)
		return
	}
	if app.settings_search_result_count == 0 {
		draw_text(app, app.ui_font, "No matching settings", field.x, field.y + 58, palette.text_muted)
		return
	}
	start := settings_search_visible_start(app)
	visible_count := min(SETTINGS_SEARCH_VISIBLE_RESULTS, app.settings_search_result_count - start)
	for visible_index in 0..<visible_count {
		result_index := start + visible_index
		result := app.settings_search_results[result_index]
		row := settings_search_result_rect(width, height, visible_index)
		if result_index == app.settings_search_selection {
			draw_fill(app.renderer, row, palette.tab_active)
		}
		label_storage: [192]u8
		label := settings_search_result_label(app, result, label_storage[:])
		color := result_index == app.settings_search_selection ? palette.accent : palette.text
		draw_text(app, app.ui_font, label, row.x + 10, row.y + 7, color)
	}
	footer_y := field.y + field.h + 18 + f32(visible_count) * 34
	draw_text(app, app.ui_font, "Enter open · ↑/↓ select · Esc close", field.x, footer_y, palette.text_muted)
	if app.settings_search_result_count > visible_count {
		count_storage: [64]u8
		count_text := fmt.bprintf(count_storage[:], "%d results", app.settings_search_result_count)
		draw_text(app, app.ui_font, count_text, field.x + field.w - 92, footer_y, palette.text_muted)
	}
}

settings_search_result_at :: proc(app: ^App, x, y, width, height: f32) -> (Settings_Search_Result, bool) {
	if app == nil || !app.settings_search_open || app.settings_search_result_count == 0 {
		return {}, false
	}
	start := settings_search_visible_start(app)
	visible_count := min(SETTINGS_SEARCH_VISIBLE_RESULTS, app.settings_search_result_count - start)
	for visible_index in 0..<visible_count {
		if inside(x, y, settings_search_result_rect(width, height, visible_index)) {
			return app.settings_search_results[start + visible_index], true
		}
	}
	return {}, false
}
