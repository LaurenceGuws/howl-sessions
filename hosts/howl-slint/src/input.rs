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
    #[cfg(target_os = "android")]
    {
        Err(format!(
            "Android requires an explicit font file path; named family {pattern} is not configured"
        ))
    }
    #[cfg(not(target_os = "android"))]
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
    let named = [
        SlintKey::Return,
        SlintKey::Tab,
        SlintKey::Backspace,
        SlintKey::Escape,
        SlintKey::UpArrow,
        SlintKey::DownArrow,
        SlintKey::LeftArrow,
        SlintKey::RightArrow,
        SlintKey::Insert,
        SlintKey::Delete,
        SlintKey::Home,
        SlintKey::End,
        SlintKey::PageUp,
        SlintKey::PageDown,
    ]
    .iter()
    .position(|k| char::from(*k) == ch)
    .map(|i| i as u8 + 1)
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
