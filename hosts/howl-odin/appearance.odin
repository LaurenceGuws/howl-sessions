package main

App_Theme :: enum u8 {
	Howl_Dark,
	Slate,
	High_Contrast,
}

APP_THEME_COUNT :: 3

app_theme_id :: proc(value: App_Theme) -> string {
	switch value {
	case .Howl_Dark:     return "howl_dark"
	case .Slate:         return "slate"
	case .High_Contrast: return "high_contrast"
	}
	return "howl_dark"
}

app_theme_label :: proc(value: App_Theme) -> string {
	switch value {
	case .Howl_Dark:     return "Howl Dark"
	case .Slate:         return "Slate"
	case .High_Contrast: return "High Contrast"
	}
	return "Howl Dark"
}

parse_app_theme :: proc(value: string) -> (App_Theme, bool) {
	switch value {
	case "howl_dark":     return .Howl_Dark, true
	case "slate":         return .Slate, true
	case "high_contrast": return .High_Contrast, true
	}
	return .Howl_Dark, false
}

next_app_theme :: proc(value: App_Theme, delta: int) -> App_Theme {
	if delta == 0 {
		return value
	}
	index := int(value)
	if delta > 0 {
		index = (index + 1) % APP_THEME_COUNT
	} else {
		index = (index + APP_THEME_COUNT - 1) % APP_THEME_COUNT
	}
	return App_Theme(index)
}

palette_for_theme :: proc(value: App_Theme) -> Palette {
	switch value {
	case .Howl_Dark:
		return {
			window_bg = {14, 17, 22, 255},
			title_bg = {26, 30, 38, 255},
			tab_active = {42, 48, 59, 255},
			tab_idle = {31, 36, 45, 255},
			terminal_bg = {9, 11, 14, 255},
			terminal_panel = {13, 16, 20, 255},
			border = {60, 68, 82, 255},
			text = {220, 226, 234, 255},
			text_muted = {137, 148, 164, 255},
			accent = {96, 165, 250, 255},
		}
	case .Slate:
		return {
			window_bg = {21, 23, 28, 255},
			title_bg = {34, 37, 44, 255},
			tab_active = {52, 57, 68, 255},
			tab_idle = {39, 43, 51, 255},
			terminal_bg = {9, 11, 14, 255},
			terminal_panel = {18, 21, 26, 255},
			border = {76, 84, 98, 255},
			text = {229, 232, 238, 255},
			text_muted = {156, 165, 178, 255},
			accent = {112, 180, 224, 255},
		}
	case .High_Contrast:
		return {
			window_bg = {0, 0, 0, 255},
			title_bg = {0, 0, 0, 255},
			tab_active = {32, 32, 32, 255},
			tab_idle = {8, 8, 8, 255},
			terminal_bg = {9, 11, 14, 255},
			terminal_panel = {0, 0, 0, 255},
			border = {200, 200, 200, 255},
			text = {255, 255, 255, 255},
			text_muted = {200, 200, 200, 255},
			accent = {255, 210, 64, 255},
		}
	}
	return palette_for_theme(.Howl_Dark)
}

adjust_app_theme :: proc(app: ^App, delta: int) -> bool {
	if app == nil || delta == 0 {
		return false
	}
	next := next_app_theme(app.app_theme, delta)
	if next == app.app_theme {
		return false
	}
	app.app_theme = next
	palette = palette_for_theme(next)
	save_user_config(app)
	set_settings_notice(app, "Application theme saved")
	return true
}
