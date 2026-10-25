package main

import "core:c"
import "core:unicode/utf8"
import SDL "vendor:sdl3"

DROP_FILE_BYTES :: 4096
DROP_TEXT_BYTES :: 64 * 1024

// File drops are terminal text, not shell execution. Quote one path using the
// ordinary POSIX single-quote spelling and leave one trailing separator so a
// multi-file drop naturally composes into adjacent arguments. Text drops are
// pasted byte-for-byte instead and never pass through this quoting lane.
quote_dropped_file :: proc(path: string, output: []u8) -> (string, bool) {
	if len(path) == 0 || len(path) > DROP_FILE_BYTES || !utf8.valid_string(path) {
		return "", false
	}
	needed := 3 // opening quote, closing quote, trailing space
	for byte in transmute([]u8)path {
		if byte == 0 do return "", false
		if byte == '\'' {
			needed += 4
		} else {
			needed += 1
		}
	}
	if needed > len(output) do return "", false
	index := 0
	output[index] = '\''
	index += 1
	for byte in transmute([]u8)path {
		if byte == '\'' {
			output[index + 0] = '\''
			output[index + 1] = '\\'
			output[index + 2] = '\''
			output[index + 3] = '\''
			index += 4
		} else {
			output[index] = byte
			index += 1
		}
	}
	output[index] = '\''
	output[index + 1] = ' '
	index += 2
	return string(output[:index]), true
}

drop_into_active_terminal :: proc(app: ^App, data: cstring, file: bool) -> bool {
	if app == nil || data == nil || !active_tab_is_instance(app) ||
	   app.profile_menu_open || app.palette_open || app.settings_open || app.search_open {
		return false
	}
	view := active_instance_view(app)
	if view == nil || view.control == nil || !instance_interactive(view) do return false
	raw := string(data)
	if len(raw) == 0 do return false

	payload := raw
	quoted: [DROP_FILE_BYTES * 4 + 3]u8
	if file {
		value, ok := quote_dropped_file(raw, quoted[:])
		if !ok do return false
		payload = value
	} else if len(raw) > DROP_TEXT_BYTES || !utf8.valid_string(raw) {
		return false
	}

	_ = return_history_live(view)
	result := queue_text(view, raw_data(payload), c.size_t(len(payload)), true)
	if control_queue_result_failed(view, result) do return false
	return true
}
