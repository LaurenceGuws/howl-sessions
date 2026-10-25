package main

import "core:c"
import "core:fmt"
import "core:sync"
import "core:thread"
import SDL "vendor:sdl3"

Server_Browser_State :: enum u8 {
	Closed,
	Loading,
	Ready,
	Error,
}

Server_Fetch_Work :: struct {
	app: ^App,
	generation: u64,
	endpoint: [SERVER_ENDPOINT_BYTES]u8,
	endpoint_len: int,
	interrupt: rawptr,
	output: [SERVER_TREE_JSON_BYTES]u8,
	output_len: c.size_t,
	diagnostic: [SERVER_DIAGNOSTIC_BYTES]u8,
	diagnostic_len: c.size_t,
	code: i32,
}

server_running_instance_count :: proc(tree: ^Server_Tree) -> int {
	if tree == nil do return 0
	count := 0
	for session_index in 0..<tree.session_count {
		session := &tree.sessions[session_index]
		for instance_index in 0..<session.instance_count {
			if session.instances[instance_index].state == .Running do count += 1
		}
	}
	return count
}

server_running_target_at :: proc(tree: ^Server_Tree, selection: int) -> (session_id, instance_id: u64, session_name: string, ok: bool) {
	if tree == nil || selection < 0 do return 0, 0, "", false
	current := 0
	for session_index in 0..<tree.session_count {
		session := &tree.sessions[session_index]
		for instance_index in 0..<session.instance_count {
			instance := &session.instances[instance_index]
			if instance.state != .Running do continue
			if current == selection {
				return session.id, instance.id, server_session_name(session), true
			}
			current += 1
		}
	}
	return 0, 0, "", false
}

server_fetch_worker :: proc(data: rawptr) {
	work := (^Server_Fetch_Work)(data)
	if work == nil || work.app == nil do return
	endpoint := string(work.endpoint[:work.endpoint_len])
	work.code = server_tree(
		raw_data(endpoint),
		c.size_t(len(endpoint)),
		work.interrupt,
		raw_data(work.output[:]),
		c.size_t(len(work.output)),
		&work.output_len,
		raw_data(work.diagnostic[:]),
		c.size_t(len(work.diagnostic)),
		&work.diagnostic_len,
	)
	sync.mutex_lock(&work.app.server_browser_mutex)
	if work.generation == work.app.server_browser_generation {
		work.app.server_browser_fetch_done = true
	}
	sync.mutex_unlock(&work.app.server_browser_mutex)
	notify_instance_update()
}

stop_server_browser_fetch :: proc(app: ^App) {
	if app == nil do return
	if app.server_browser_interrupt != nil do _ = interrupt_cancel(app.server_browser_interrupt)
	if app.server_browser_thread != nil {
		thread.destroy(app.server_browser_thread)
		app.server_browser_thread = nil
	}
	if app.server_browser_interrupt != nil {
		interrupt_destroy(app.server_browser_interrupt)
		app.server_browser_interrupt = nil
	}
	if app.server_browser_work != nil {
		free(app.server_browser_work)
		app.server_browser_work = nil
	}
	app.server_browser_fetch_done = false
}

refresh_server_browser :: proc(app: ^App) -> bool {
	if app == nil || app.server_browser_server < 0 || app.server_browser_server >= app.server_count do return false
	stop_server_browser_fetch(app)
	app.server_browser_generation += 1
	app.server_browser_state = .Loading
	app.server_browser_error_len = 0
	app.server_browser_tree = {}
	app.server_browser_selection = 0
	work := new(Server_Fetch_Work)
	if work == nil {
		app.server_browser_state = .Error
		return false
	}
	endpoint := server_endpoint(&app.servers[app.server_browser_server])
	work.app = app
	work.generation = app.server_browser_generation
	work.endpoint_len = len(endpoint)
	copy(work.endpoint[:work.endpoint_len], transmute([]u8)endpoint)
	work.interrupt = interrupt_create()
	if work.interrupt == nil {
		free(work)
		app.server_browser_state = .Error
		return false
	}
	app.server_browser_work = work
	app.server_browser_interrupt = work.interrupt
	app.server_browser_thread = thread.create_and_start_with_data(rawptr(work), server_fetch_worker, name = "howl-odin-server")
	if app.server_browser_thread == nil {
		interrupt_destroy(work.interrupt)
		app.server_browser_interrupt = nil
		app.server_browser_work = nil
		free(work)
		app.server_browser_state = .Error
		return false
	}
	return true
}

open_server_browser :: proc(app: ^App, server_index: int) -> bool {
	if app == nil || server_index < 0 || server_index >= app.server_count do return false
	app.profile_menu_open = false
	app.palette_open = false
	app.settings_open = false
	app.server_browser_open = true
	app.server_browser_server = server_index
	app.server_browser_selection = 0
	return refresh_server_browser(app)
}

close_server_browser :: proc(app: ^App) {
	if app == nil do return
	app.server_browser_generation += 1
	stop_server_browser_fetch(app)
	app.server_browser_open = false
	app.server_browser_state = .Closed
	app.server_browser_tree = {}
	app.server_browser_error_len = 0
}

service_server_browser :: proc(app: ^App) -> bool {
	if app == nil do return false
	sync.mutex_lock(&app.server_browser_mutex)
	done := app.server_browser_fetch_done
	app.server_browser_fetch_done = false
	sync.mutex_unlock(&app.server_browser_mutex)
	if !done do return false
	work := app.server_browser_work
	if app.server_browser_thread != nil {
		thread.destroy(app.server_browser_thread)
		app.server_browser_thread = nil
	}
	if app.server_browser_interrupt != nil {
		interrupt_destroy(app.server_browser_interrupt)
		app.server_browser_interrupt = nil
	}
	app.server_browser_work = nil
	if work == nil do return false
	defer free(work)
	if work.generation != app.server_browser_generation || !app.server_browser_open do return false
	if work.code != 0 {
		count := min(int(work.diagnostic_len), len(app.server_browser_error))
		copy(app.server_browser_error[:count], work.diagnostic[:count])
		app.server_browser_error_len = count
		app.server_browser_state = .Error
		return true
	}
	tree: Server_Tree
	if !parse_server_tree(work.output[:int(work.output_len)], &tree) {
		message := "Invalid Server tree"
		copy(app.server_browser_error[:len(message)], transmute([]u8)message)
		app.server_browser_error_len = len(message)
		app.server_browser_state = .Error
		return true
	}
	app.server_browser_tree = tree
	app.server_browser_selection = clamp(app.server_browser_selection, 0, max(0, server_running_instance_count(&tree) - 1))
	app.server_browser_state = .Ready
	app.server_browser_error_len = 0
	return true
}


server_browser_rect :: proc(width, height: f32) -> SDL.FRect {
	w := min(f32(620), max(f32(0), width - 48))
	h := min(f32(520), max(f32(0), height - 96))
	return {(width - w) / 2, 58, w, h}
}

server_browser_selection_at :: proc(app: ^App, x, y, width, height: f32) -> (int, bool) {
	if app == nil || app.server_browser_state != .Ready do return 0, false
	box := server_browser_rect(width, height)
	row_y := box.y + 78
	current := 0
	for session_index in 0..<app.server_browser_tree.session_count {
		session := &app.server_browser_tree.sessions[session_index]
		row_y += 30
		for instance_index in 0..<session.instance_count {
			instance := &session.instances[instance_index]
			row := SDL.FRect{box.x + 18, row_y, box.w - 36, 34}
			if instance.state == .Running {
				if inside(x, y, row) do return current, true
				current += 1
			}
			row_y += 38
		}
	}
	return 0, false
}

open_server_browser_selection :: proc(app: ^App) -> bool {
	if app == nil || app.server_browser_server < 0 || app.server_browser_server >= app.server_count do return false
	session_id, instance_id, session_name, ok := server_running_target_at(&app.server_browser_tree, app.server_browser_selection)
	if !ok do return false
	server := &app.servers[app.server_browser_server]
	view := create_server_instance_view(server_endpoint(server), app.server_browser_tree.server_id, session_id, instance_id)
	if view == nil do return false
	view.profile_index = -1
	if !add_instance_tab(app, view, session_name, -1) do return false
	close_server_browser(app)
	return true
}

handle_server_browser_key :: proc(app: ^App, event: ^SDL.Event) -> bool {
	if app == nil || !app.server_browser_open || event.type != .KEY_DOWN do return false
	switch event.key.key {
	case SDL.K_ESCAPE:
		close_server_browser(app)
	case SDL.K_R:
		_ = refresh_server_browser(app)
	case SDL.K_UP:
		count := server_running_instance_count(&app.server_browser_tree)
		if count > 0 do app.server_browser_selection = (app.server_browser_selection + count - 1) % count
	case SDL.K_DOWN, SDL.K_TAB:
		count := server_running_instance_count(&app.server_browser_tree)
		if count > 0 do app.server_browser_selection = (app.server_browser_selection + 1) % count
	case SDL.K_RETURN:
		_ = open_server_browser_selection(app)
	case:
		return false
	}
	return true
}

draw_server_browser :: proc(app: ^App, width, height: f32) {
	if app == nil || !app.server_browser_open do return
	box := server_browser_rect(width, height)
	draw_fill(app.renderer, box, palette.title_bg)
	draw_outline(app.renderer, box, palette.border)
	server_name := "Server"
	endpoint := ""
	if app.server_browser_server >= 0 && app.server_browser_server < app.server_count {
		server := &app.servers[app.server_browser_server]
		server_name = server_label(server)
		endpoint = server_endpoint(server)
	}
	draw_text(app, app.ui_font, server_name, box.x + 18, box.y + 14, palette.text)
	draw_text(app, app.ui_font, endpoint, box.x + 18, box.y + 38, palette.text_muted)
	footer := "Enter/click attach · R refresh · Esc close"
	draw_text(app, app.ui_font, footer, box.x + 18, box.y + box.h - 28, palette.text_muted)
	if app.server_browser_state == .Loading {
		draw_text(app, app.ui_font, "Loading Sessions...", box.x + 18, box.y + 82, palette.text_muted)
		return
	}
	if app.server_browser_state == .Error {
		message := app.server_browser_error_len > 0 ? string(app.server_browser_error[:app.server_browser_error_len]) : "server fetch failed without diagnostic"
		draw_text(app, app.ui_font, message, box.x + 18, box.y + 82, palette.text)
		return
	}
	if app.server_browser_state != .Ready do return
	y := box.y + 78
	selected := 0
	for session_index in 0..<app.server_browser_tree.session_count {
		session := &app.server_browser_tree.sessions[session_index]
		draw_text(app, app.ui_font, server_session_name(session), box.x + 18, y + 5, palette.accent)
		y += 30
		for instance_index in 0..<session.instance_count {
			instance := &session.instances[instance_index]
			row := SDL.FRect{box.x + 18, y, box.w - 36, 34}
			if instance.state == .Running && selected == app.server_browser_selection do draw_fill(app.renderer, row, palette.tab_active)
			label: [128]u8
			state := instance.state == .Running ? "Running" : "Exited"
			text := fmt.bprintf(label[:], "Instance %d · %s", instance.id, state)
			color := instance.state == .Running ? palette.text : palette.text_muted
			draw_text(app, app.ui_font, text, row.x + 10, row.y + 7, color)
			if instance.state == .Running do selected += 1
			y += 38
		}
	}
	if app.server_browser_tree.session_count == 0 {
		draw_text(app, app.ui_font, "No Sessions", box.x + 18, box.y + 82, palette.text_muted)
	}
}
