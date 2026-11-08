use super::{Palette, Style};
use slint::Color;

fn palette() -> Palette {
    Palette {
        background: Color::from_rgb_u8(0x11, 0x16, 0x1c),
        chrome: Color::from_rgb_u8(0x1b, 0x22, 0x2b),
        sidebar: Color::from_rgb_u8(0x17, 0x1e, 0x26),
        terminal: Color::from_rgb_u8(0x10, 0x15, 0x1b),
        row: Color::from_rgb_u8(0x1c, 0x26, 0x30),
        hover: Color::from_rgb_u8(0x22, 0x2e, 0x39),
        selected: Color::from_rgb_u8(0x26, 0x3c, 0x41),
        selected_border: Color::from_rgb_u8(0x55, 0x8b, 0x86),
        border: Color::from_rgb_u8(0x2a, 0x36, 0x41),
        text: Color::from_rgb_u8(0xe8, 0xee, 0xf4),
        secondary: Color::from_rgb_u8(0xa6, 0xb3, 0xbf),
        muted: Color::from_rgb_u8(0x8f, 0xa2, 0xb4),
        accent: Color::from_rgb_u8(0x8a, 0xc1, 0xb4),
        warning: Color::from_rgb_u8(0xe0, 0xbb, 0x82),
        badge: Color::from_rgb_u8(0x29, 0x31, 0x3a),
    }
}

// Logical pixels; Slint applies the display scale. All sizes share the body scale.
pub fn defaults() -> Style {
    let body = 14.0;
    Style {
        palette: palette(),
        font_family: "sans-serif".into(),
        mono_family: "monospace".into(),
        body_size: body,
        small_size: body * 0.85,
        caption_size: body * 0.8,
        title_size: body * 1.4,
        subtitle_size: body * 1.2,
        symbol_size: body * 2.0,
        medium_weight: 600,
        bold_weight: 700,
        brand_weight: 800,
        padding: body,
        compact_padding: body / 2.0,
        spacing: body / 2.0,
        wide_spacing: body,
        tight_spacing: body / 4.0,
        radius: body / 2.0,
        stroke: 1.0,
    }
}
