//! Host key vocabulary and explicit file/family discovery, for the Server view.
use std::ffi::CString;

#[derive(Clone, Copy)]
pub(crate) struct Key {
    pub named: u8,
    pub scalar: u32,
    pub action: u8,
    pub modifiers: u8,
}

pub(crate) fn resolve_font(pattern: &str) -> Result<CString, String> {
    if pattern.starts_with('/') {
        if !std::path::Path::new(pattern).is_file() {
            return Err(format!("Font file missing: {pattern}"));
        }
        return CString::new(pattern).map_err(|e| e.to_string());
    }
    #[cfg(any(target_os = "android", target_os = "ios"))]
    {
        Err(format!(
            "Mobile requires an explicit font file path; named family {pattern} is not configured"
        ))
    }
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    {
        let output = std::process::Command::new("fc-match")
            .args(["--format=%{family}\n%{style}\n%{file}", "--", pattern])
            .output()
            .map_err(|e| format!("Font discovery: {e}"))?;
        if !output.status.success() {
            return Err(format!("Font discovery failed: {pattern}"));
        }
        let result = String::from_utf8(output.stdout).map_err(|e| e.to_string())?;
        let mut fields = result.splitn(3, '\n');
        let family = fields.next().unwrap_or("");
        let style = fields.next().unwrap_or("");
        let path = fields.next().unwrap_or("");
        let (requested_family, requested_style) =
            pattern.split_once(":style=").unwrap_or((pattern, ""));
        // Fontconfig silently substitutes missing families. Named slots must not
        // pretend that a substitute supplies their advertised glyphs or face style.
        if requested_family != "monospace" && !family.split(',').any(|f| f == requested_family) {
            return Err(format!(
                "Font missing: {pattern} (Fontconfig offered {family})"
            ));
        }
        if !requested_style.is_empty() && !style.split(',').any(|s| s == requested_style) {
            return Err(format!("Font style missing: {pattern} (offered {style})"));
        }
        if !path.starts_with('/') {
            return Err(format!("No font file for {pattern}"));
        }
        CString::new(path).map_err(|e| e.to_string())
    }
}

pub(crate) fn key(event: slint::language::KeyEvent, released: bool) -> Option<Key> {
    use slint::platform::Key as SlintKey;
    let ch = event.text.chars().next()?;
    // Slint uses C0 scalar values for modifier-key identities. Forward them as
    // named physical keys so Howl owns legacy suppression and Kitty reporting;
    // treating ControlR (U+0016) as text turns it into Ctrl-V in Neovim.
    let named = [
        (SlintKey::Return, 1),
        (SlintKey::Tab, 2),
        (SlintKey::Backspace, 3),
        (SlintKey::Escape, 4),
        (SlintKey::UpArrow, 5),
        (SlintKey::DownArrow, 6),
        (SlintKey::LeftArrow, 7),
        (SlintKey::RightArrow, 8),
        (SlintKey::Insert, 9),
        (SlintKey::Delete, 10),
        (SlintKey::Home, 11),
        (SlintKey::End, 12),
        (SlintKey::PageUp, 13),
        (SlintKey::PageDown, 14),
        (SlintKey::Shift, 15),
        (SlintKey::ShiftR, 16),
        (SlintKey::Control, 17),
        (SlintKey::ControlR, 18),
        (SlintKey::Alt, 19),
        (SlintKey::AltGr, 20),
        (SlintKey::Meta, 21),
        (SlintKey::MetaR, 22),
        (SlintKey::CapsLock, 27),
    ]
    .iter()
    .find(|(key, _)| char::from(*key) == ch)
    .map(|(_, named)| *named)
    .unwrap_or(0);
    if named == 0 && ('\u{e000}'..='\u{f8ff}').contains(&ch) {
        return None;
    }
    let modifiers = u8::from(event.modifiers.shift)
        | (u8::from(event.modifiers.alt) * 2)
        | (u8::from(event.modifiers.control) * 4)
        | (u8::from(event.modifiers.meta) * 8);
    Some(Key {
        named,
        scalar: ch as u32,
        action: if released {
            3
        } else if event.repeat {
            2
        } else {
            1
        },
        modifiers,
    })
}

// Android system-font policy, deliberately not a substitute claimed to match the
// desktop's four Iosevka faces. Actual file paths avoid Fontconfig assumptions.
#[cfg(target_os = "android")]
pub(crate) fn configure_android_fonts(app: &crate::App) {
    let mut style = app.get_style();
    style.terminal_regular = "/system/fonts/DroidSansMono.ttf".into();
    style.terminal_italic = "".into();
    style.terminal_bold = "".into();
    style.terminal_bold_italic = "".into();
    let fallbacks = [
        "/system/fonts/NotoNaskhArabic-Regular.ttf",
        "/system/fonts/NotoSansCJK-Regular.ttc",
        "/system/fonts/NotoColorEmoji.ttf",
    ]
    .into_iter()
    .filter(|path| std::path::Path::new(path).is_file())
    .map(slint::SharedString::from)
    .collect::<Vec<_>>();
    style.terminal_fallbacks = slint::ModelRc::new(slint::VecModel::from(fallbacks));
    app.set_style(style);
    app.set_font_note("Android system fonts · limited coverage".into());
}

#[cfg(test)]
mod tests {
    use super::key;
    use slint::{language::KeyEvent, platform::Key as SlintKey};

    fn event(ch: char, modifiers: u8, repeat: bool) -> KeyEvent {
        let mut event = KeyEvent::default();
        event.text = ch.to_string().into();
        event.modifiers.shift = modifiers & 1 != 0;
        event.modifiers.alt = modifiers & 2 != 0;
        event.modifiers.control = modifiers & 4 != 0;
        event.modifiers.meta = modifiers & 8 != 0;
        event.repeat = repeat;
        event
    }

    #[test]
    fn modifiers_are_named_keys_not_control_text() {
        for (slint, named) in [
            (SlintKey::Shift, 15),
            (SlintKey::ShiftR, 16),
            (SlintKey::Control, 17),
            (SlintKey::ControlR, 18),
            (SlintKey::Alt, 19),
            (SlintKey::AltGr, 20),
            (SlintKey::Meta, 21),
            (SlintKey::MetaR, 22),
            (SlintKey::CapsLock, 27),
        ] {
            for modifiers in 0..16 {
                for (repeat, released, action) in
                    [(false, false, 1), (true, false, 2), (false, true, 3)]
                {
                    let key = key(event(slint.into(), modifiers, repeat), released).unwrap();
                    assert_eq!(key.named, named, "Slint key {slint:?}");
                    assert_eq!(key.modifiers, modifiers);
                    assert_eq!(key.action, action);
                }
            }
        }
    }

    #[test]
    fn modifier_chords_preserve_text_and_transitions() {
        for ch in ['c', 'v', 'q', 'V', ' ', '[', 'é'] {
            for modifiers in 0..16 {
                for (repeat, released, action) in
                    [(false, false, 1), (true, false, 2), (false, true, 3)]
                {
                    let key = key(event(ch, modifiers, repeat), released).unwrap();
                    assert_eq!(key.named, 0);
                    assert_eq!(key.scalar, ch as u32);
                    assert_eq!(key.modifiers, modifiers);
                    assert_eq!(key.action, action);
                }
            }
        }
    }

    #[test]
    fn supported_navigation_keys_and_unknown_symbols_are_unchanged() {
        for (slint, named) in [
            (SlintKey::Return, 1),
            (SlintKey::Tab, 2),
            (SlintKey::Backspace, 3),
            (SlintKey::Escape, 4),
            (SlintKey::UpArrow, 5),
            (SlintKey::DownArrow, 6),
            (SlintKey::LeftArrow, 7),
            (SlintKey::RightArrow, 8),
            (SlintKey::Insert, 9),
            (SlintKey::Delete, 10),
            (SlintKey::Home, 11),
            (SlintKey::End, 12),
            (SlintKey::PageUp, 13),
            (SlintKey::PageDown, 14),
        ] {
            let key = key(event(slint.into(), 4, false), false).unwrap();
            assert_eq!(key.named, named);
            assert_eq!(key.modifiers, 4);
        }
        assert!(key(KeyEvent::default(), false).is_none());
        assert!(key(event('\u{e000}', 0, false), false).is_none());
    }
}
