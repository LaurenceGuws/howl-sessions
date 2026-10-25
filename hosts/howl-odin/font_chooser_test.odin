package main

import "core:testing"

font_chooser_test_query :: proc(state: ^Font_Chooser_State, value: string) {
	state.query_len = len(value)
	copy(state.query[:len(value)], transmute([]u8)value)
}

@(test)
font_chooser_catalogue_deduplicates_and_sorts_family_names :: proc(t: ^testing.T) {
	state: Font_Chooser_State
	text := "Zulu Mono\t100\tRegular\t/missing/z.ttf\nJetBrains Mono\t100\tBold\t/missing/jb.ttf\nAlpha Mono\t90\tRegular\t/missing/a.ttf\nJetBrains Mono\t100\tRegular\t/missing/jr.ttf\nIgnored Propo\t\tRegular\t/missing/p.ttf\nIgnored Variable\t0\tRegular\t/missing/v.ttf\n"
	testing.expect(t, font_chooser_parse_catalogue(&state, text))
	testing.expect_value(t, state.family_count, 3)
	testing.expect_value(t, font_chooser_family_name(&state.families[0]), "Alpha Mono")
	testing.expect_value(t, font_chooser_family_name(&state.families[1]), "JetBrains Mono")
	testing.expect_value(t, font_chooser_family_name(&state.families[2]), "Zulu Mono")
}

@(test)
font_chooser_filter_prefers_substring_then_fuzzy_subsequence :: proc(t: ^testing.T) {
	state: Font_Chooser_State
	font_chooser_add_family(&state, "Fira Code", "Regular", "")
	font_chooser_add_family(&state, "JetBrains Mono", "Regular", "")
	font_chooser_add_family(&state, "JetBrainsMono Nerd Font", "Regular", "")
	font_chooser_add_family(&state, "Monoid", "Regular", "")
	font_chooser_sort_families(&state)

	font_chooser_test_query(&state, "jetbra")
	font_chooser_refresh(&state)
	testing.expect_value(t, state.result_count, 2)
	first := &state.families[int(state.results[0])]
	second := &state.families[int(state.results[1])]
	testing.expect(t, contains_ascii_fold(font_chooser_family_name(first), "jetbra"))
	testing.expect(t, contains_ascii_fold(font_chooser_family_name(second), "jetbra"))

	font_chooser_test_query(&state, "jbmono")
	font_chooser_refresh(&state)
	testing.expect(t, state.result_count >= 1)
	testing.expect(t, font_chooser_subsequence_match(
		font_chooser_family_name(&state.families[int(state.results[0])]),
		"jbmono",
	))
}

@(test)
font_chooser_result_window_keeps_selection_visible :: proc(t: ^testing.T) {
	state: Font_Chooser_State
	state.result_count = 30
	for index in 0..<state.result_count do state.results[index] = u16(index)
	state.selection = 20
	first, count := font_chooser_result_window(&state)
	testing.expect_value(t, count, FONT_CHOOSER_VISIBLE_ROWS)
	testing.expect(t, first <= state.selection)
	testing.expect(t, first + count > state.selection)
}

@(test)
font_chooser_style_scoring_prefers_regular_nonitalic_faces :: proc(t: ^testing.T) {
	testing.expect(t, font_chooser_style_score("Regular") > font_chooser_style_score("Medium"))
	testing.expect(t, font_chooser_style_score("Medium") > font_chooser_style_score("Italic"))
	testing.expect_value(t, font_chooser_style_score("Bold Italic"), u8(0))
}


@(test)
font_chooser_accepts_dual_and_mono_spacing_only :: proc(t: ^testing.T) {
	testing.expect(t, font_chooser_terminal_spacing("90"))
	testing.expect(t, font_chooser_terminal_spacing("100"))
	testing.expect(t, !font_chooser_terminal_spacing(""))
	testing.expect(t, !font_chooser_terminal_spacing("0"))
	testing.expect(t, !font_chooser_terminal_spacing("80"))
}
