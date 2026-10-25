package main

import "core:testing"

@(test)
server_connection_config_validation :: proc(t: ^testing.T) {
	server: Server_Connection
	testing.expect(t, server_connection_from_config({label = "Colt", endpoint = "tcp://100.96.0.7:43150"}, &server))
	testing.expect_value(t, server_label(&server), "Colt")
	testing.expect_value(t, server_endpoint(&server), "tcp://100.96.0.7:43150")
	testing.expect(t, !server_connection_from_config({label = "", endpoint = "tcp://100.96.0.7:43150"}, &server))
	testing.expect(t, !server_connection_from_config({label = "bad", endpoint = "https://example.invalid"}, &server))
}

@(test)
server_connection_load_is_all_or_nothing :: proc(t: ^testing.T) {
	app: App
	good := [1]User_Server_Config{{label = "Colt", endpoint = "tcp://100.96.0.7:43150"}}
	testing.expect(t, load_server_connections(&app, good[:]))
	testing.expect_value(t, app.server_count, 1)

	app.config_notice_len = 0
	duplicate := [2]User_Server_Config{
		{label = "Colt", endpoint = "tcp://100.96.0.7:43150"},
		{label = "Duplicate", endpoint = "tcp://100.96.0.7:43150"},
	}
	testing.expect(t, !load_server_connections(&app, duplicate[:]))
	testing.expect_value(t, app.server_count, 0)
	testing.expect_value(t, string(app.config_notice[:app.config_notice_len]), "servers[1]: duplicate endpoint")

	app.config_notice_len = 0
	bad := [1]User_Server_Config{{label = "Bad", endpoint = "https://example.invalid"}}
	testing.expect(t, !load_server_connections(&app, bad[:]))
	testing.expect_value(t, app.server_count, 0)
	testing.expect_value(t, string(app.config_notice[:app.config_notice_len]), "servers[0]: invalid server")
}

@(test)
server_tree_parse_exact_identities :: proc(t: ^testing.T) {
	text: string = `{"schema":"howl.server.tree/v1","server_id":"18446744073709551614","tree_revision":"9","sessions":[{"session_id":"7","name":"work","instances":[{"instance_id":"3","state":"running"},{"instance_id":"8","state":"exited"}]}]}`
	data := transmute([]u8)text
	tree: Server_Tree
	testing.expect(t, parse_server_tree(data, &tree))
	testing.expect_value(t, tree.server_id, u64(18446744073709551614))
	testing.expect_value(t, tree.tree_revision, u64(9))
	testing.expect_value(t, tree.session_count, 1)
	testing.expect_value(t, tree.sessions[0].id, u64(7))
	testing.expect_value(t, server_session_name(&tree.sessions[0]), "work")
	testing.expect_value(t, tree.sessions[0].instance_count, 2)
	testing.expect_value(t, tree.sessions[0].instances[0].id, u64(3))
	testing.expect_value(t, tree.sessions[0].instances[0].state, Server_Instance_State.Running)
	testing.expect_value(t, tree.sessions[0].instances[1].state, Server_Instance_State.Exited)
	testing.expect_value(t, server_running_instance_count(&tree), 1)
	session_id, instance_id, session_name, target_ok := server_running_target_at(&tree, 0)
	testing.expect(t, target_ok)
	testing.expect_value(t, session_id, u64(7))
	testing.expect_value(t, instance_id, u64(3))
	testing.expect_value(t, session_name, "work")
}

@(test)
server_tree_rejects_bad_shape_and_order :: proc(t: ^testing.T) {
	cases := [4]string{
		`{"schema":"wrong","server_id":"1","tree_revision":"1","sessions":[]}`,
		`{"schema":"howl.server.tree/v1","server_id":"0","tree_revision":"1","sessions":[]}`,
		`{"schema":"howl.server.tree/v1","server_id":"1","tree_revision":"1","sessions":[{"session_id":"2","name":"a","instances":[]},{"session_id":"1","name":"b","instances":[]}]}`,
		`{"schema":"howl.server.tree/v1","server_id":"1","tree_revision":"1","sessions":[{"session_id":"1","name":"a","instances":[{"instance_id":"1","state":"unknown"}]}]}`,
	}
	for text in cases {
		tree: Server_Tree
		testing.expect(t, !parse_server_tree(transmute([]u8)text, &tree))
	}
}
