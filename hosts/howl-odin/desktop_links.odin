package main

import "core:sync"
import "core:strings"
import "core:unicode/utf8"
import SDL "vendor:sdl3"

HYPERLINK_URI_BYTES :: 2048

browser_uri_allowed :: proc(uri: string) -> bool {
	if len(uri) == 0 || len(uri) > HYPERLINK_URI_BYTES || !utf8.valid_string(uri) {
		return false
	}
	for byte in transmute([]u8)uri {
		if byte <= 0x20 || byte == 0x7f {
			return false
		}
	}
	http := len(uri) > len("http://") && strings.equal_fold(uri[:len("http://")], "http://")
	https := len(uri) > len("https://") && strings.equal_fold(uri[:len("https://")], "https://")
	return http || https
}

open_platform_browser_uri :: proc(uri: string) -> bool {
	if !browser_uri_allowed(uri) {
		return false
	}
	terminated: [HYPERLINK_URI_BYTES + 1]u8
	copy(terminated[:len(uri)], transmute([]u8)uri)
	terminated[len(uri)] = 0
	return SDL.OpenURL(cstring(raw_data(terminated[:])))
}

open_hyperlink_at :: proc(
	app: ^App,
	view: ^Instance_View,
	pane: SDL.FRect,
	x, y: f32,
) -> (handled: bool, opened: bool) {
	if app == nil || view == nil || view.control == nil || view.canvas == nil {
		return false, false
	}
	stable_row, column, columns, alternate, hit := selection_stable_point_at(
		app,
		view,
		pane,
		x,
		y,
	)
	if !hit {
		return false, false
	}
    sync.mutex_lock(&view.mutex)
    generation := view.selection_generation
    sync.mutex_unlock(&view.mutex)
    admitted := queue_control(view, {kind = .Link, history = canvas_history_offset(view),
                                   row = stable_row, column = column, columns = columns,
                                   alternate = alternate ? u8(1) : u8(0), generation = generation}) == 0
    return true, admitted
}
