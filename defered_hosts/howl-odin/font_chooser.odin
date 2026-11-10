package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import SDL "vendor:sdl3"
import TTF "vendor:sdl3/ttf"

MAX_FONT_CHOOSER_FAMILIES :: 256
FONT_CHOOSER_NAME_BYTES :: 128
FONT_CHOOSER_PATH_BYTES :: 512
FONT_CHOOSER_QUERY_BYTES :: 128
FONT_CHOOSER_VISIBLE_ROWS :: 10

Font_Chooser_Family :: struct {
	name: [FONT_CHOOSER_NAME_BYTES]u8,
	name_len: int,
	regular: [FONT_CHOOSER_PATH_BYTES]u8,
	regular_len: int,
	regular_score: u8,
}

Font_Chooser_State :: struct {
	open: bool,
	loaded: bool,
	families: [MAX_FONT_CHOOSER_FAMILIES]Font_Chooser_Family,
	family_count: int,
	results: [MAX_FONT_CHOOSER_FAMILIES]u16,
	result_count: int,
	selection: int,
	query: [FONT_CHOOSER_QUERY_BYTES]u8,
	query_len: int,
	original_overrides: Desktop_Fonts,
	preview_applied: bool,
	sample_font: ^TTF.Font,
	error: [192]u8,
	error_len: int,
}

font_chooser_family_name :: proc(entry: ^Font_Chooser_Family) -> string {
	if entry == nil || entry.name_len <= 0 do return ""
	return string(entry.name[:entry.name_len])
}

font_chooser_family_regular :: proc(entry: ^Font_Chooser_Family) -> string {
	if entry == nil || entry.regular_len <= 0 do return ""
	return string(entry.regular[:entry.regular_len])
}

font_chooser_set_error :: proc(state: ^Font_Chooser_State, message: string) {
	if state == nil do return
	state.error_len = min(len(message), len(state.error))
	if state.error_len != 0 do copy(state.error[:state.error_len], transmute([]u8)message[:state.error_len])
}

font_chooser_ascii_less :: proc(left, right: string) -> bool {
	count := min(len(left), len(right))
	for index in 0..<count {
		l := ascii_fold_byte(left[index])
		r := ascii_fold_byte(right[index])
		if l < r do return true
		if l > r do return false
	}
	return len(left) < len(right)
}

font_chooser_family_index :: proc(state: ^Font_Chooser_State, name: string) -> int {
	if state == nil || len(name) == 0 do return -1
	for index in 0..<state.family_count {
		if strings.equal_fold(font_chooser_family_name(&state.families[index]), name) do return index
	}
	return -1
}

font_chooser_style_score :: proc(style: string) -> u8 {
	if style == "Regular" do return 4
	if strings.contains(style, "Italic") || strings.contains(style, "Oblique") ||
	   strings.contains(style, "Bold") || strings.contains(style, "Black") ||
	   strings.contains(style, "ExtraBold") {
		return 0
	}
	if strings.contains(style, "Regular") do return 3
	if strings.contains(style, "Medium") || strings.contains(style, "Book") || strings.contains(style, "Retina") do return 2
	return 1
}

font_chooser_add_family :: proc(state: ^Font_Chooser_State, name, style, path: string) {
	if state == nil || len(name) == 0 || len(name) >= FONT_CHOOSER_NAME_BYTES do return
	index := font_chooser_family_index(state, name)
	if index < 0 {
		if state.family_count >= MAX_FONT_CHOOSER_FAMILIES do return
		index = state.family_count
		entry := &state.families[index]
		copy(entry.name[:len(name)], transmute([]u8)name)
		entry.name_len = len(name)
		state.family_count += 1
	}
	score := font_chooser_style_score(style)
	entry := &state.families[index]
	if score > entry.regular_score && len(path) > 0 && len(path) < FONT_CHOOSER_PATH_BYTES && os.exists(path) {
		copy(entry.regular[:len(path)], transmute([]u8)path)
		entry.regular_len = len(path)
		entry.regular_score = score
	}
}

font_chooser_sort_families :: proc(state: ^Font_Chooser_State) {
	if state == nil do return
	for index in 1..<state.family_count {
		value := state.families[index]
		cursor := index
		for cursor > 0 && font_chooser_ascii_less(font_chooser_family_name(&value), font_chooser_family_name(&state.families[cursor - 1])) {
			state.families[cursor] = state.families[cursor - 1]
			cursor -= 1
		}
		state.families[cursor] = value
	}
}

font_chooser_terminal_spacing :: proc(value: string) -> bool {
	return value == "90" || value == "100"
}

font_chooser_parse_catalogue :: proc(state: ^Font_Chooser_State, text: string) -> bool {
	if state == nil do return false
	state.family_count = 0
	start := 0
	for start < len(text) {
		stop := start
		for stop < len(text) && text[stop] != '\n' do stop += 1
		if stop > start {
			line := text[start:stop]
			first := strings.index_byte(line, '\t')
			if first > 0 {
				rest := line[first + 1:]
				second := strings.index_byte(rest, '\t')
				if second >= 0 {
					spacing := rest[:second]
					if font_chooser_terminal_spacing(spacing) {
						after_spacing := rest[second + 1:]
						third := strings.index_byte(after_spacing, '\t')
						if third >= 0 {
							family := line[:first]
							style := after_spacing[:third]
							path := after_spacing[third + 1:]
							font_chooser_add_family(state, family, style, path)
						}
					}
				}
			}
		}
		start = stop + 1
	}
	font_chooser_sort_families(state)
	return state.family_count != 0
}

font_chooser_load_catalogue :: proc(state: ^Font_Chooser_State) -> bool {
	if state == nil do return false
	if state.loaded do return state.family_count != 0
	state.error_len = 0
	when ODIN_OS == .Windows {
		font_chooser_set_error(state, "Installed-font family discovery is not wired on Windows yet")
		return false
	} else {
		command := []string{"fc-list", "-f", "%{family[0]}\t%{spacing}\t%{style[0]}\t%{file}\n"}
		process, stdout, _, err := os.process_exec(
			os.Process_Desc{command = command},
			context.temp_allocator,
		)
		if err != nil || !process.success {
			font_chooser_set_error(state, "fontconfig catalogue query failed")
			return false
		}
		if !font_chooser_parse_catalogue(state, string(stdout)) {
			font_chooser_set_error(state, "fontconfig returned no terminal-width families")
			return false
		}
		state.loaded = true
		return true
	}
}

font_chooser_subsequence_match :: proc(name, query: string) -> bool {
	if len(query) == 0 do return true
	cursor := 0
	for byte in transmute([]u8)name {
		if cursor < len(query) && ascii_fold_byte(byte) == ascii_fold_byte(query[cursor]) {
			cursor += 1
			if cursor == len(query) do return true
		}
	}
	return false
}

font_chooser_query :: proc(state: ^Font_Chooser_State) -> string {
	if state == nil || state.query_len <= 0 do return ""
	return string(state.query[:state.query_len])
}

font_chooser_result_contains :: proc(state: ^Font_Chooser_State, family_index: int) -> bool {
	for index in 0..<state.result_count {
		if int(state.results[index]) == family_index do return true
	}
	return false
}

font_chooser_refresh :: proc(state: ^Font_Chooser_State) {
	if state == nil do return
	state.result_count = 0
	query := font_chooser_query(state)

	// Strong matches first, preserving the alphabetic catalogue order.
	for family_index in 0..<state.family_count {
		name := font_chooser_family_name(&state.families[family_index])
		if len(query) == 0 || contains_ascii_fold(name, query) {
			state.results[state.result_count] = u16(family_index)
			state.result_count += 1
		}
	}
	// Then fuzzy subsequence matches such as "jbmono" without disturbing strong matches.
	if len(query) != 0 {
		for family_index in 0..<state.family_count {
			if state.result_count >= len(state.results) do break
			if font_chooser_result_contains(state, family_index) do continue
			name := font_chooser_family_name(&state.families[family_index])
			if font_chooser_subsequence_match(name, query) {
				state.results[state.result_count] = u16(family_index)
				state.result_count += 1
			}
		}
	}
	state.selection = clamp(state.selection, 0, max(0, state.result_count - 1))
}

font_chooser_select_current_family :: proc(app: ^App) {
	if app == nil || app.font_chooser == nil do return
	state := app.font_chooser
	current := effective_terminal_primary_font(&app.terminal_fonts, &app.terminal_font_overrides)
	if len(current) == 0 do return
	for result_index in 0..<state.result_count {
		entry := &state.families[int(state.results[result_index])]
		if font_chooser_family_regular(entry) == current {
			state.selection = result_index
			return
		}
	}
}

font_chooser_selected_entry :: proc(state: ^Font_Chooser_State) -> ^Font_Chooser_Family {
	if state == nil || state.result_count == 0 || state.selection < 0 || state.selection >= state.result_count do return nil
	index := int(state.results[state.selection])
	if index < 0 || index >= state.family_count do return nil
	return &state.families[index]
}

font_chooser_is_open :: proc(app: ^App) -> bool {
	return app != nil && app.font_chooser != nil && app.font_chooser.open
}

font_chooser_close_sample_font :: proc(app: ^App) {
	if app == nil || app.font_chooser == nil || app.font_chooser.sample_font == nil do return
	TTF.CloseFont(app.font_chooser.sample_font)
	app.font_chooser.sample_font = nil
}

font_chooser_update_sample_font :: proc(app: ^App) {
	if app == nil || app.font_chooser == nil do return
	font_chooser_close_sample_font(app)
	entry := font_chooser_selected_entry(app.font_chooser)
	if entry == nil || entry.regular_len == 0 do return
	font := TTF.OpenFont(cstring(raw_data(entry.regular[:])), 22)
	if font == nil do return
	if !set_font_display_scale(font, 22, app.text_scale) {
		TTF.CloseFont(font)
		return
	}
	app.font_chooser.sample_font = font
}

font_chooser_resolve_family :: proc(app: ^App, family: string, output: ^Desktop_Fonts) -> bool {
	if app == nil || output == nil || len(family) == 0 do return false
	result := app.font_chooser.original_overrides

	when ODIN_OS == .Windows {
		return false
	} else {
		regular, regular_ok := fontconfig_result(family)
		if !regular_ok do return false
		result.primary_len = 0
		result.italic_len = 0
		result.bold_len = 0
		result.bold_italic_len = 0
		if !copy_optional_font_path(result.primary[:], &result.primary_len, regular) do return false

		if path, ok := fontconfig_style_result(family, "Italic"); ok {
			if !copy_optional_font_path(result.italic[:], &result.italic_len, path) do return false
		} else if path, ok := fontconfig_style_result(family, "Oblique"); ok {
			if !copy_optional_font_path(result.italic[:], &result.italic_len, path) do return false
		}
		if path, ok := fontconfig_style_result(family, "Bold"); ok {
			if !copy_optional_font_path(result.bold[:], &result.bold_len, path) do return false
		}
		if path, ok := fontconfig_style_result(family, "Bold Italic"); ok {
			if !copy_optional_font_path(result.bold_italic[:], &result.bold_italic_len, path) do return false
		} else if path, ok := fontconfig_style_result(family, "Bold Oblique"); ok {
			if !copy_optional_font_path(result.bold_italic[:], &result.bold_italic_len, path) do return false
		}
	}
	output^ = result
	return true
}

font_chooser_apply_selected :: proc(app: ^App, persist: bool) -> bool {
	if app == nil || app.font_chooser == nil do return false
	entry := font_chooser_selected_entry(app.font_chooser)
	if entry == nil do return false
	family := font_chooser_family_name(entry)
	candidate: Desktop_Fonts
	if !font_chooser_resolve_family(app, family, &candidate) {
		font_chooser_set_error(app.font_chooser, "Selected family could not resolve an exact regular face")
		return false
	}

	previous := app.terminal_font_overrides
	app.terminal_font_overrides = candidate
	if !reload_terminal_ttf(app) {
		app.terminal_font_overrides = previous
		font_chooser_set_error(app.font_chooser, "Selected regular face could not be opened")
		return false
	}
	restart_all_font_renderers(app)
	app.font_chooser^.preview_applied = true
	app.font_chooser^.error_len = 0
	if persist {
		app.font_chooser.original_overrides = candidate
		save_user_config(app)
	}
	return true
}

font_chooser_restore :: proc(app: ^App) -> bool {
	if app == nil || app.font_chooser == nil do return false
	if !app.font_chooser^.preview_applied do return true
	preview := app.terminal_font_overrides
	app.terminal_font_overrides = app.font_chooser.original_overrides
	if !reload_terminal_ttf(app) {
		app.terminal_font_overrides = preview
		font_chooser_set_error(app.font_chooser, "Original regular face could not be restored")
		return false
	}
	restart_all_font_renderers(app)
	app.font_chooser^.preview_applied = false
	return true
}

open_font_chooser :: proc(app: ^App) -> bool {
	if app == nil do return false
	if app.font_chooser == nil {
		app.font_chooser = new(Font_Chooser_State)
		if app.font_chooser == nil {
			set_settings_notice(app, "Font chooser allocation failed")
			return false
		}
	}
	state := app.font_chooser
	if !font_chooser_load_catalogue(state) {
		set_settings_notice(app, state.error_len > 0 ? string(state.error[:state.error_len]) : "Font catalogue unavailable")
		return false
	}
	state.open = true
	state.query_len = 0
	state.selection = 0
	state.original_overrides = app.terminal_font_overrides
	state.preview_applied = false
	state.error_len = 0
	font_chooser_refresh(state)
	font_chooser_select_current_family(app)
	font_chooser_update_sample_font(app)
	clear_ime_preedit(app)
	return true
}

close_font_chooser :: proc(app: ^App, commit: bool) {
	if !font_chooser_is_open(app) do return
	if !commit {
		if !font_chooser_restore(app) do return
	} else {
		app.font_chooser^.preview_applied = false
	}
	font_chooser_close_sample_font(app)
	app.font_chooser.open = false
	app.font_chooser.query_len = 0
	app.font_chooser^.result_count = 0
	app.font_chooser^.error_len = 0
	clear_ime_preedit(app)
}

destroy_font_chooser :: proc(app: ^App) {
	if app == nil || app.font_chooser == nil do return
	font_chooser_close_sample_font(app)
	free(app.font_chooser)
	app.font_chooser = nil
}

font_chooser_append_query :: proc(app: ^App, text: string) -> bool {
	if !font_chooser_is_open(app) || len(text) == 0 do return false
	state := app.font_chooser
	if state.query_len + len(text) >= len(state.query) do return false
	copy(state.query[state.query_len:state.query_len + len(text)], transmute([]u8)text)
	state.query_len += len(text)
	state.selection = 0
	font_chooser_refresh(state)
	font_chooser_update_sample_font(app)
	return true
}

font_chooser_backspace_query :: proc(app: ^App) -> bool {
	if !font_chooser_is_open(app) || app.font_chooser.query_len == 0 do return false
	state := app.font_chooser
	next := state.query_len - 1
	for next > 0 && state.query[next] & 0xc0 == 0x80 do next -= 1
	state.query_len = next
	state.selection = 0
	font_chooser_refresh(state)
	font_chooser_update_sample_font(app)
	return true
}

font_chooser_move_selection :: proc(app: ^App, delta: int) {
	if !font_chooser_is_open(app) || app.font_chooser^.result_count == 0 || delta == 0 do return
	state := app.font_chooser
	state.selection = clamp(state.selection + delta, 0, state.result_count - 1)
	font_chooser_update_sample_font(app)
}

font_chooser_handle_key :: proc(app: ^App, event: ^SDL.Event) -> bool {
	if !font_chooser_is_open(app) || event == nil do return false
	if event.type != .KEY_DOWN do return true
	switch event.key.key {
	case SDL.K_ESCAPE:
		close_font_chooser(app, false)
	case SDL.K_UP:
		font_chooser_move_selection(app, -1)
	case SDL.K_DOWN:
		font_chooser_move_selection(app, 1)
	case SDL.K_PAGEUP:
		font_chooser_move_selection(app, -FONT_CHOOSER_VISIBLE_ROWS)
	case SDL.K_PAGEDOWN:
		font_chooser_move_selection(app, FONT_CHOOSER_VISIBLE_ROWS)
	case SDL.K_HOME:
		app.font_chooser^.selection = 0
		font_chooser_update_sample_font(app)
	case SDL.K_END:
		app.font_chooser^.selection = max(0, app.font_chooser^.result_count - 1)
		font_chooser_update_sample_font(app)
	case SDL.K_BACKSPACE:
		_ = font_chooser_backspace_query(app)
	case SDL.K_RIGHT:
		_ = font_chooser_apply_selected(app, false)
	case SDL.K_LEFT:
		_ = font_chooser_restore(app)
	case SDL.K_RETURN:
		if font_chooser_apply_selected(app, true) {
			close_font_chooser(app, true)
			set_settings_notice(app, "Font family saved")
		}
	case:
		// TEXT_INPUT owns printable search text.
	}
	return true
}

font_chooser_rect :: proc(width, height: f32) -> SDL.FRect {
	w := min(f32(900), max(f32(620), width - 80))
	h := min(f32(590), max(f32(440), height - 90))
	return {(width - w) / 2, (height - h) / 2, w, h}
}

font_chooser_search_rect :: proc(box: SDL.FRect) -> SDL.FRect {
	return {box.x + 18, box.y + 52, box.w - 36, 40}
}

font_chooser_list_rect :: proc(box: SDL.FRect) -> SDL.FRect {
	return {box.x + 18, box.y + 110, min(f32(400), box.w * 0.48), box.h - 170}
}

font_chooser_preview_rect :: proc(box, list: SDL.FRect) -> SDL.FRect {
	x := list.x + list.w + 18
	return {x, list.y, box.x + box.w - 18 - x, list.h}
}

font_chooser_result_window :: proc(state: ^Font_Chooser_State) -> (first, count: int) {
	if state == nil || state.result_count == 0 do return 0, 0
	count = min(FONT_CHOOSER_VISIBLE_ROWS, state.result_count)
	first = clamp(state.selection - count / 2, 0, max(0, state.result_count - count))
	return
}

font_chooser_row_rect :: proc(list: SDL.FRect, visible_index: int) -> SDL.FRect {
	return {list.x, list.y + f32(visible_index) * 34, list.w, 31}
}

font_chooser_handle_pointer :: proc(app: ^App, event: ^SDL.Event, width, height: f32) -> bool {
	if !font_chooser_is_open(app) || event == nil do return false
	if event.type != .MOUSE_BUTTON_UP || event.button.button != SDL.BUTTON_LEFT do return true
	box := font_chooser_rect(width, height)
	list := font_chooser_list_rect(box)
	first, count := font_chooser_result_window(app.font_chooser)
	for visible_index in 0..<count {
		if inside(event.button.x, event.button.y, font_chooser_row_rect(list, visible_index)) {
			app.font_chooser^.selection = first + visible_index
			font_chooser_update_sample_font(app)
			return true
		}
	}
	preview := font_chooser_preview_rect(box, list)
	button_row := SDL.FRect{preview.x, preview.y + preview.h - 40, preview.w, 32}
	if inside(event.button.x, event.button.y, settings_button_rect(button_row, 0, 3)) {
		_ = font_chooser_apply_selected(app, false)
		return true
	}
	if inside(event.button.x, event.button.y, settings_button_rect(button_row, 1, 3)) {
		if font_chooser_apply_selected(app, true) {
			close_font_chooser(app, true)
			set_settings_notice(app, "Font family saved")
		}
		return true
	}
	if inside(event.button.x, event.button.y, settings_button_rect(button_row, 2, 3)) {
		close_font_chooser(app, false)
		return true
	}
	return true
}

draw_font_chooser :: proc(app: ^App, width, height: f32) {
	if !font_chooser_is_open(app) do return
	box := font_chooser_rect(width, height)
	draw_fill(app.renderer, box, palette.title_bg)
	draw_outline(app.renderer, box, palette.accent)
	draw_text(app, app.ui_font, "Choose terminal font", box.x + 18, box.y + 18, palette.text)

	search := font_chooser_search_rect(box)
	draw_fill(app.renderer, search, palette.terminal_bg)
	draw_outline(app.renderer, search, palette.accent)
	query := font_chooser_query(app.font_chooser)
	if len(query) == 0 {
		search_storage: [96]u8
		placeholder := fmt.bprintf(search_storage[:], "Search %d terminal font families…", app.font_chooser^.family_count)
		settings_clipped_text(app, {search.x + 10, search.y + 10, search.w - 20, 22}, placeholder, palette.text_muted)
	} else {
		settings_clipped_text(app, {search.x + 10, search.y + 10, search.w - 20, 22}, query, palette.text)
	}

	list := font_chooser_list_rect(box)
	preview := font_chooser_preview_rect(box, list)
	first, count := font_chooser_result_window(app.font_chooser)
	for visible_index in 0..<count {
		result_index := first + visible_index
		entry := &app.font_chooser^.families[int(app.font_chooser^.results[result_index])]
		row := font_chooser_row_rect(list, visible_index)
		selected := result_index == app.font_chooser^.selection
		if selected do draw_fill(app.renderer, row, palette.tab_active)
		draw_outline(app.renderer, row, selected ? palette.accent : palette.border)
		settings_clipped_text(app, {row.x + 8, row.y + 6, row.w - 16, 22}, font_chooser_family_name(entry),
		                          selected ? palette.accent : palette.text)
	}

	draw_outline(app.renderer, preview, palette.border)
	entry := font_chooser_selected_entry(app.font_chooser)
	if entry != nil {
		settings_clipped_text(app, {preview.x + 14, preview.y + 14, preview.w - 28, 24},
		                      font_chooser_family_name(entry), palette.text)
		sample := "Ag 0O 1Il  {} [] ()  !=  ->  =>  ~/src/howl"
		sample_font := app.font_chooser.sample_font
		if sample_font != nil {
			had_clip := SDL.RenderClipEnabled(app.renderer)
			previous: SDL.Rect
			_ = SDL.GetRenderClipRect(app.renderer, &previous)
			sample_clip := SDL.Rect{
				c.int(preview.x + 12),
				c.int(preview.y + 52),
				c.int(max(f32(1), preview.w - 24)),
				70,
			}
			_ = SDL.SetRenderClipRect(app.renderer, &sample_clip)
			draw_text(app, sample_font, sample, preview.x + 14, preview.y + 76, palette.text)
			if had_clip do _ = SDL.SetRenderClipRect(app.renderer, &previous)
			else do _ = SDL.SetRenderClipRect(app.renderer, nil)
		}
		regular := font_chooser_family_regular(entry)
		if len(regular) != 0 {
			settings_clipped_text(app, {preview.x + 14, preview.y + 166, preview.w - 28, 42}, regular, palette.text_muted)
		}
	}
	if app.font_chooser^.preview_applied {
		settings_clipped_text(app, {preview.x + 14, preview.y + preview.h - 82, preview.w - 28, 22},
		                      "Live terminal preview active", palette.accent)
	}
	if app.font_chooser^.error_len != 0 {
		settings_clipped_text(app, {preview.x + 14, preview.y + preview.h - 108, preview.w - 28, 22},
		                      string(app.font_chooser^.error[:app.font_chooser^.error_len]), palette.accent)
	}

	button_row := SDL.FRect{preview.x, preview.y + preview.h - 40, preview.w, 32}
	settings_draw_button(app, settings_button_rect(button_row, 0, 3), "Preview")
	settings_draw_button(app, settings_button_rect(button_row, 1, 3), "Use")
	settings_draw_button(app, settings_button_rect(button_row, 2, 3), "Cancel")

	status_storage: [96]u8
	status := fmt.bprintf(status_storage[:], "%d matches · Right preview · Left restore · Enter use · Esc cancel", app.font_chooser^.result_count)
	settings_clipped_text(app, {box.x + 18, box.y + box.h - 26, box.w - 36, 20}, status, palette.text_muted)
}
