package main

import "core:testing"

@(test)
desktop_file_drop_quotes_one_shell_argument_and_separator :: proc(t: ^testing.T) {
	buffer: [256]u8
	value, ok := quote_dropped_file("/tmp/Howl notes.txt", buffer[:])
	testing.expect(t, ok)
	testing.expect_value(t, value, "'/tmp/Howl notes.txt' ")
}

@(test)
desktop_file_drop_escapes_single_quotes_without_interpreting_shell :: proc(t: ^testing.T) {
	buffer: [256]u8
	value, ok := quote_dropped_file("/tmp/captain's $(touch nope)", buffer[:])
	testing.expect(t, ok)
	testing.expect_value(t, value, "'/tmp/captain'\\''s $(touch nope)' ")
}

@(test)
desktop_file_drop_rejects_nul_invalid_utf8_and_small_output :: proc(t: ^testing.T) {
	nul_bytes := [3]u8{'a', 0, 'b'}
	bad_bytes := [1]u8{0xff}
	nul := transmute(string)nul_bytes[:]
	bad := transmute(string)bad_bytes[:]
	short: [2]u8
	_, nul_ok := quote_dropped_file(nul, short[:])
	_, bad_ok := quote_dropped_file(bad, short[:])
	_, short_ok := quote_dropped_file("abc", short[:])
	testing.expect(t, !nul_ok)
	testing.expect(t, !bad_ok)
	testing.expect(t, !short_ok)
}
