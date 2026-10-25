package main

import "core:os"
import "core:path/filepath"
import "core:strings"

FONT_PATH_BYTES :: 4096

Desktop_Fonts :: struct {
	primary: [FONT_PATH_BYTES]u8,
	primary_len: int,
	italic: [FONT_PATH_BYTES]u8,
	italic_len: int,
	bold: [FONT_PATH_BYTES]u8,
	bold_len: int,
	bold_italic: [FONT_PATH_BYTES]u8,
	bold_italic_len: int,
	fallback: [FONT_PATH_BYTES]u8,
	fallback_len: int,
	secondary: [FONT_PATH_BYTES]u8,
	secondary_len: int,
}

User_Font_Config :: struct {
	regular: string `json:"regular"`,
	italic: string `json:"italic"`,
	bold: string `json:"bold"`,
	bold_italic: string `json:"bold_italic"`,
	fallback: string `json:"fallback"`,
	secondary_fallback: string `json:"secondary_fallback"`,
}

font_path :: proc(storage: []u8, used: int) -> string {
	if used <= 0 || used > len(storage) do return ""
	return string(storage[:used])
}

terminal_primary_font :: proc(fonts: ^Desktop_Fonts) -> string {
	if fonts == nil do return ""
	return font_path(fonts.primary[:], fonts.primary_len)
}

terminal_italic_font :: proc(fonts: ^Desktop_Fonts) -> string {
	if fonts == nil do return ""
	return font_path(fonts.italic[:], fonts.italic_len)
}

terminal_bold_font :: proc(fonts: ^Desktop_Fonts) -> string {
	if fonts == nil do return ""
	return font_path(fonts.bold[:], fonts.bold_len)
}

terminal_bold_italic_font :: proc(fonts: ^Desktop_Fonts) -> string {
	if fonts == nil do return ""
	return font_path(fonts.bold_italic[:], fonts.bold_italic_len)
}

terminal_fallback_font :: proc(fonts: ^Desktop_Fonts) -> string {
	if fonts == nil do return ""
	return font_path(fonts.fallback[:], fonts.fallback_len)
}

terminal_secondary_fallback_font :: proc(fonts: ^Desktop_Fonts) -> string {
	if fonts == nil do return ""
	return font_path(fonts.secondary[:], fonts.secondary_len)
}

copy_optional_font_path :: proc(output: []u8, used: ^int, path: string) -> bool {
	if used == nil || len(path) >= len(output) do return false
	if len(path) == 0 {
		used^ = 0
		if len(output) != 0 do output[0] = 0
		return true
	}
	if !filepath.is_abs(path) || !os.exists(path) do return false
	copy(output[:len(path)], transmute([]u8)path)
	output[len(path)] = 0
	used^ = len(path)
	return true
}

load_font_overrides :: proc(output: ^Desktop_Fonts, config: User_Font_Config) -> (message: string, ok: bool) {
	if output == nil do return "font override storage unavailable", false
	output^ = {}
	if !copy_optional_font_path(output.primary[:], &output.primary_len, config.regular) do return "font.regular must be an existing absolute path within the path limit", false
	if !copy_optional_font_path(output.italic[:], &output.italic_len, config.italic) do return "font.italic must be an existing absolute path within the path limit", false
	if !copy_optional_font_path(output.bold[:], &output.bold_len, config.bold) do return "font.bold must be an existing absolute path within the path limit", false
	if !copy_optional_font_path(output.bold_italic[:], &output.bold_italic_len, config.bold_italic) do return "font.bold_italic must be an existing absolute path within the path limit", false
	if !copy_optional_font_path(output.fallback[:], &output.fallback_len, config.fallback) do return "font.fallback must be an existing absolute path within the path limit", false
	if !copy_optional_font_path(output.secondary[:], &output.secondary_len, config.secondary_fallback) do return "font.secondary_fallback must be an existing absolute path within the path limit", false
	return "", true
}

font_config_from_overrides :: proc(fonts: ^Desktop_Fonts) -> User_Font_Config {
	if fonts == nil do return {}
	return {
		regular = terminal_primary_font(fonts),
		italic = terminal_italic_font(fonts),
		bold = terminal_bold_font(fonts),
		bold_italic = terminal_bold_italic_font(fonts),
		fallback = terminal_fallback_font(fonts),
		secondary_fallback = terminal_secondary_fallback_font(fonts),
	}
}

effective_terminal_primary_font :: proc(defaults, overrides: ^Desktop_Fonts) -> string {
	if overrides != nil && overrides.primary_len != 0 do return terminal_primary_font(overrides)
	return terminal_primary_font(defaults)
}

effective_terminal_italic_font :: proc(defaults, overrides: ^Desktop_Fonts) -> string {
	if overrides != nil && overrides.italic_len != 0 do return terminal_italic_font(overrides)
	if overrides != nil && overrides.primary_len != 0 do return ""
	return terminal_italic_font(defaults)
}

effective_terminal_bold_font :: proc(defaults, overrides: ^Desktop_Fonts) -> string {
	if overrides != nil && overrides.bold_len != 0 do return terminal_bold_font(overrides)
	if overrides != nil && overrides.primary_len != 0 do return ""
	return terminal_bold_font(defaults)
}

effective_terminal_bold_italic_font :: proc(defaults, overrides: ^Desktop_Fonts) -> string {
	if overrides != nil && overrides.bold_italic_len != 0 do return terminal_bold_italic_font(overrides)
	if overrides != nil && overrides.primary_len != 0 do return ""
	return terminal_bold_italic_font(defaults)
}

effective_terminal_fallback_font :: proc(defaults, overrides: ^Desktop_Fonts) -> string {
	if overrides != nil && overrides.fallback_len != 0 do return terminal_fallback_font(overrides)
	return terminal_fallback_font(defaults)
}

effective_terminal_secondary_fallback_font :: proc(defaults, overrides: ^Desktop_Fonts) -> string {
	if overrides != nil && overrides.secondary_len != 0 do return terminal_secondary_fallback_font(overrides)
	return terminal_secondary_fallback_font(defaults)
}

copy_font_path :: proc(output: []u8, used: ^int, path: string) -> bool {
	if used == nil || len(path) == 0 || len(path) >= len(output) || !os.exists(path) {
		return false
	}
	copy(output[:len(path)], transmute([]u8)path)
	output[len(path)] = 0
	used^ = len(path)
	return true
}

fontconfig_output_path :: proc(text, family: string) -> (path: string, ok: bool) {
	if len(text) == 0 || len(family) == 0 {
		return "", false
	}
	first_break := strings.index_byte(text, '\n')
	if first_break <= 0 {
		return "", false
	}
	family_line := text[:first_break]
	if !strings.contains(family_line, family) {
		return "", false
	}
	rest := text[first_break + 1:]
	second_break := strings.index_byte(rest, '\n')
	path = second_break < 0 ? rest : rest[:second_break]
	return path, len(path) != 0
}

fontconfig_result :: proc(family: string) -> (path: string, ok: bool) {
	command := []string{"fc-match", "-f", "%{family}\n%{file}\n", family}
	state, stdout, _, err := os.process_exec(
		os.Process_Desc{command = command},
		context.temp_allocator,
	)
	if err != nil || !state.success {
		return "", false
	}
	resolved, parsed := fontconfig_output_path(string(stdout), family)
	if !parsed || !os.exists(resolved) {
		return "", false
	}
	return resolved, true
}

windows_font_result :: proc(family: string) -> (path: string, ok: bool) {
	root := os.get_env("WINDIR", context.temp_allocator)
	if len(root) == 0 {
		root = os.get_env("SystemRoot", context.temp_allocator)
	}
	if len(root) == 0 do return "", false

	candidates: []string
	if family == "JetBrainsMono Nerd Font" {
		candidates = []string{"CascadiaMono.ttf", "CascadiaCode.ttf", "consola.ttf"}
	} else if family == "Noto Sans Arabic" {
		candidates = []string{"arial.ttf", "segoeui.ttf", "consola.ttf"}
	} else if family == "Noto Sans CJK JP" {
		candidates = []string{"YuGothM.ttc", "msgothic.ttc", "msyh.ttc", "malgun.ttf", "segoeui.ttf", "consola.ttf"}
	} else {
		return "", false
	}

	for candidate in candidates {
		resolved, err := filepath.join([]string{root, "Fonts", candidate}, allocator=context.temp_allocator)
		if err == nil && os.exists(resolved) {
			return resolved, true
		}
	}
	return "", false
}

fontconfig_style_output_path :: proc(text, family, style: string) -> (path: string, ok: bool) {
	if len(text) == 0 || len(family) == 0 || len(style) == 0 do return "", false
	first := strings.index_byte(text, '\n')
	if first <= 0 || !strings.contains(text[:first], family) do return "", false
	rest := text[first + 1:]
	second := strings.index_byte(rest, '\n')
	if second <= 0 || rest[:second] != style do return "", false
	path_text := rest[second + 1:]
	third := strings.index_byte(path_text, '\n')
	path = third < 0 ? path_text : path_text[:third]
	return path, len(path) != 0
}

fontconfig_style_result :: proc(family, style: string) -> (path: string, ok: bool) {
	pattern := strings.concatenate({family, ":style=", style}, context.temp_allocator)
	command := []string{"fc-match", "-f", "%{family}\n%{style}\n%{file}\n", pattern}
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = command}, context.temp_allocator)
	if err != nil || !state.success do return "", false
	resolved, parsed := fontconfig_style_output_path(string(stdout), family, style)
	if !parsed || !os.exists(resolved) do return "", false
	return resolved, true
}

windows_style_font_result :: proc(primary, style: string) -> (path: string, ok: bool) {
	root := os.get_env("WINDIR", context.temp_allocator)
	if len(root) == 0 do root = os.get_env("SystemRoot", context.temp_allocator)
	if len(root) == 0 do return "", false
	candidate := ""
	if strings.contains(primary, "CascadiaMono.ttf") {
		switch style {
		case "Italic":      candidate = "CascadiaMonoItalic.ttf"
		case "Bold":        candidate = "CascadiaMonoBold.ttf"
		case "Bold Italic": candidate = "CascadiaMonoBoldItalic.ttf"
		}
	} else if strings.contains(primary, "CascadiaCode.ttf") {
		switch style {
		case "Italic":      candidate = "CascadiaCodeItalic.ttf"
		case "Bold":        candidate = "CascadiaCodeBold.ttf"
		case "Bold Italic": candidate = "CascadiaCodeBoldItalic.ttf"
		}
	} else if strings.contains(primary, "consola.ttf") {
		switch style {
		case "Italic":      candidate = "consolai.ttf"
		case "Bold":        candidate = "consolab.ttf"
		case "Bold Italic": candidate = "consolaz.ttf"
		}
	}
	if len(candidate) == 0 do return "", false
	resolved, err := filepath.join([]string{root, "Fonts", candidate}, allocator=context.temp_allocator)
	return resolved, err == nil && os.exists(resolved)
}

configured_style_font :: proc(variable, family, style, primary: string, discover: bool) -> (path: string, ok: bool, configured: bool) {
	override := os.get_env(variable, context.temp_allocator)
	if len(override) != 0 do return override, os.exists(override), true
	if !discover do return "", false, false
	when ODIN_OS == .Windows {
		path, ok = windows_style_font_result(primary, style)
	} else {
		path, ok = fontconfig_style_result(family, style)
	}
	return path, ok, false
}

configured_font :: proc(variable, family: string) -> (string, bool) {
	configured := os.get_env(variable, context.temp_allocator)
	if len(configured) != 0 {
		return configured, os.exists(configured)
	}
	when ODIN_OS == .Windows {
		return windows_font_result(family)
	}
	return fontconfig_result(family)
}

resolve_desktop_fonts :: proc(fonts: ^Desktop_Fonts) -> (message: string, ok: bool) {
	if fonts == nil do return "font_storage", false
	fonts^ = {}
	primary_override := os.get_env("HOWL_FONT", context.temp_allocator)
	primary, primary_ok := configured_font("HOWL_FONT", "JetBrainsMono Nerd Font")
	if !primary_ok || !copy_font_path(fonts.primary[:], &fonts.primary_len, primary) {
		return "primary_font_missing", false
	}
	discover_styles := len(primary_override) == 0
	italic, italic_ok, italic_configured := configured_style_font("HOWL_ITALIC_FONT", "JetBrainsMono Nerd Font", "Italic", primary, discover_styles)
	if italic_configured && !italic_ok do return "italic_font_missing", false
	if italic_ok && !copy_font_path(fonts.italic[:], &fonts.italic_len, italic) do return "italic_font_missing", false
	bold, bold_ok, bold_configured := configured_style_font("HOWL_BOLD_FONT", "JetBrainsMono Nerd Font", "Bold", primary, discover_styles)
	if bold_configured && !bold_ok do return "bold_font_missing", false
	if bold_ok && !copy_font_path(fonts.bold[:], &fonts.bold_len, bold) do return "bold_font_missing", false
	bold_italic, bold_italic_ok, bold_italic_configured := configured_style_font("HOWL_BOLD_ITALIC_FONT", "JetBrainsMono Nerd Font", "Bold Italic", primary, discover_styles)
	if bold_italic_configured && !bold_italic_ok do return "bold_italic_font_missing", false
	if bold_italic_ok && !copy_font_path(fonts.bold_italic[:], &fonts.bold_italic_len, bold_italic) do return "bold_italic_font_missing", false
	fallback, fallback_ok := configured_font("HOWL_FALLBACK_FONT", "Noto Sans Arabic")
	if !fallback_ok || !copy_font_path(fonts.fallback[:], &fonts.fallback_len, fallback) {
		return "fallback_font_missing", false
	}
	secondary, secondary_ok := configured_font("HOWL_SECONDARY_FALLBACK_FONT", "Noto Sans CJK JP")
	if !secondary_ok || !copy_font_path(fonts.secondary[:], &fonts.secondary_len, secondary) {
		return "secondary_fallback_font_missing", false
	}
	return "", true
}
