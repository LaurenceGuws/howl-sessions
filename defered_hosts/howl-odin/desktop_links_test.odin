package main

import "core:testing"

@(test)
browser_uri_policy_accepts_only_http_and_https :: proc(t: ^testing.T) {
	accepted := [4]string{
		"https://howl.example/path?q=1",
		"HTTP://example.com",
		"http://127.0.0.1:8080/x",
		"https://例.example/界",
	}
	for value in accepted {
		testing.expect(t, browser_uri_allowed(value))
	}
	rejected := [8]string{
		"",
		"https://",
		"file:///tmp/secret",
		"mailto:user@example.com",
		"javascript:alert(1)",
		"https://example.com/has space",
		"https://example.com/line\nbreak",
		"custom://example.com",
	}
	for value in rejected {
		testing.expect(t, !browser_uri_allowed(value))
	}
}

@(test)
browser_uri_policy_rejects_nul_and_invalid_utf8 :: proc(t: ^testing.T) {
	nul_bytes := [11]u8{'h','t','t','p','s',':','/','/','x',0,'y'}
	bad_bytes := [9]u8{'h','t','t','p','s',':','/','/',0xff}
	nul := transmute(string)nul_bytes[:]
	bad := transmute(string)bad_bytes[:]
	testing.expect(t, !browser_uri_allowed(nul))
	testing.expect(t, !browser_uri_allowed(bad))
}
