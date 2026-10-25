package main

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"

MAX_SERVERS :: 16
MAX_SERVER_SESSIONS :: 16
MAX_SERVER_INSTANCES :: 16
SERVER_LABEL_BYTES :: 80
SERVER_ENDPOINT_BYTES :: 512
SERVER_SESSION_NAME_BYTES :: 80
SERVER_TREE_JSON_BYTES :: 64 * 1024
SERVER_DIAGNOSTIC_BYTES :: 256

Server_Connection :: struct {
	label: [SERVER_LABEL_BYTES]u8,
	label_len: int,
	endpoint: [SERVER_ENDPOINT_BYTES]u8,
	endpoint_len: int,
}

User_Server_Config :: struct {
	label: string `json:"label"`,
	endpoint: string `json:"endpoint"`,
}

Server_Instance_State :: enum u8 {
	Running,
	Exited,
}

Server_Instance :: struct {
	id: u64,
	state: Server_Instance_State,
}

Server_Session :: struct {
	id: u64,
	name: [SERVER_SESSION_NAME_BYTES]u8,
	name_len: int,
	instances: [MAX_SERVER_INSTANCES]Server_Instance,
	instance_count: int,
}

Server_Tree :: struct {
	server_id: u64,
	tree_revision: u64,
	sessions: [MAX_SERVER_SESSIONS]Server_Session,
	session_count: int,
}

Raw_Server_Instance :: struct {
	instance_id: string `json:"instance_id"`,
	state: string `json:"state"`,
}

Raw_Server_Session :: struct {
	session_id: string `json:"session_id"`,
	name: string `json:"name"`,
	instances: []Raw_Server_Instance `json:"instances"`,
}

Raw_Server_Tree :: struct {
	schema: string `json:"schema"`,
	server_id: string `json:"server_id"`,
	tree_revision: string `json:"tree_revision"`,
	sessions: []Raw_Server_Session `json:"sessions"`,
}

server_connection_text :: proc(buffer: []u8, count: int) -> string {
	if count <= 0 do return ""
	return string(buffer[:min(count, len(buffer))])
}

server_label :: proc(server: ^Server_Connection) -> string {
	return server == nil ? "" : server_connection_text(server.label[:], server.label_len)
}

server_endpoint :: proc(server: ^Server_Connection) -> string {
	return server == nil ? "" : server_connection_text(server.endpoint[:], server.endpoint_len)
}

server_session_name :: proc(session: ^Server_Session) -> string {
	return session == nil ? "" : server_connection_text(session.name[:], session.name_len)
}

valid_server_label :: proc(value: string) -> bool {
	return len(value) > 0 && len(value) < SERVER_LABEL_BYTES && strings.index_byte(value, 0) < 0
}

valid_server_endpoint :: proc(value: string) -> bool {
	if len(value) == 0 || len(value) >= SERVER_ENDPOINT_BYTES || strings.index_byte(value, 0) >= 0 {
		return false
	}
	return strings.has_prefix(value, "tcp://") || strings.has_prefix(value, "unix:")
}

server_connection_from_config :: proc(config: User_Server_Config, output: ^Server_Connection) -> bool {
	if output == nil || !valid_server_label(config.label) || !valid_server_endpoint(config.endpoint) {
		return false
	}
	output^ = {}
	copy(output.label[:len(config.label)], transmute([]u8)config.label)
	output.label_len = len(config.label)
	copy(output.endpoint[:len(config.endpoint)], transmute([]u8)config.endpoint)
	output.endpoint_len = len(config.endpoint)
	return true
}

load_server_connections :: proc(app: ^App, configs: []User_Server_Config) -> bool {
    if app == nil do return false
    app.server_count = 0
    for config, config_index in configs {
        if app.server_count >= MAX_SERVERS {
            buffer: [192]u8
            set_config_notice(app, fmt.bprintf(buffer[:], "servers[%d]: server limit", config_index))
            app.server_count = 0
            return false
        }
        server: Server_Connection
        if !server_connection_from_config(config, &server) {
            buffer: [192]u8
            set_config_notice(app, fmt.bprintf(buffer[:], "servers[%d]: invalid server", config_index))
            app.server_count = 0
            return false
        }
        for index in 0..<app.server_count {
            if server_endpoint(&app.servers[index]) == server_endpoint(&server) {
                buffer: [192]u8
                set_config_notice(app, fmt.bprintf(buffer[:], "servers[%d]: duplicate endpoint", config_index))
                app.server_count = 0
                return false
            }
        }
        app.servers[app.server_count] = server
        app.server_count += 1
    }
    return true
}

parse_server_identity :: proc(value: string) -> (u64, bool) {
	parsed, ok := strconv.parse_u64_of_base(value, 10)
	return parsed, ok && parsed != 0
}

parse_server_tree :: proc(data: []u8, output: ^Server_Tree) -> bool {
	if output == nil || len(data) == 0 || len(data) > SERVER_TREE_JSON_BYTES {
		return false
	}
	raw: Raw_Server_Tree
	if json.unmarshal(data, &raw, allocator=context.temp_allocator) != nil ||
	   raw.schema != "howl.server.tree/v1" ||
	   len(raw.sessions) > MAX_SERVER_SESSIONS {
		return false
	}
	server_id, server_ok := parse_server_identity(raw.server_id)
	revision, revision_ok := parse_server_identity(raw.tree_revision)
	if !server_ok || !revision_ok {
		return false
	}
	result := Server_Tree{server_id = server_id, tree_revision = revision}
	previous_session: u64
	for raw_session in raw.sessions {
		if !valid_server_label(raw_session.name) || len(raw_session.instances) > MAX_SERVER_INSTANCES {
			return false
		}
		session_id, session_ok := parse_server_identity(raw_session.session_id)
		if !session_ok || session_id <= previous_session {
			return false
		}
		session := &result.sessions[result.session_count]
		session.id = session_id
		copy(session.name[:len(raw_session.name)], transmute([]u8)raw_session.name)
		session.name_len = len(raw_session.name)
		previous_instance: u64
		for raw_instance in raw_session.instances {
			instance_id, instance_ok := parse_server_identity(raw_instance.instance_id)
			if !instance_ok || instance_id <= previous_instance {
				return false
			}
			state: Server_Instance_State
			switch raw_instance.state {
			case "running": state = .Running
			case "exited":  state = .Exited
			case:           return false
			}
			session.instances[session.instance_count] = {id = instance_id, state = state}
			session.instance_count += 1
			previous_instance = instance_id
		}
		result.session_count += 1
		previous_session = session_id
	}
	output^ = result
	return true
}
