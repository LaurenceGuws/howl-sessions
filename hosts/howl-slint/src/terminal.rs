//! One local horse. The worker exclusively owns Howl; the UI receives owned pixels.
//! This bounded CPU presentation is a proof, not the eventual GPU backend.
use crate::App;
use slint::{ComponentHandle, Model, Rgba8Pixel, SharedPixelBuffer, Timer, TimerMode};
use std::{
    ffi::{CString, c_char, c_void},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, SyncSender},
    },
    thread::{self, JoinHandle},
};

unsafe extern "C" {
    fn proof_open(
        fonts: *const *const c_char,
        fallbacks: *const *const c_char,
        fallback_count: usize,
        home: *const c_char,
        pixel_size: u16,
        out: *mut *mut c_void,
    ) -> u32;
    fn proof_close(owner: *mut c_void) -> u32;
    fn proof_key(owner: *mut c_void, key: u8, scalar: u32, action: u8, mods: u8) -> u32;
    fn proof_resize(owner: *mut c_void, width: u32, height: u32) -> u32;
    fn proof_step(
        owner: *mut c_void,
        pixels: *mut *const u8,
        width: *mut u32,
        height: *mut u32,
        exited: *mut i32,
    ) -> u32;
}
// Constructed and destroyed on the worker; deliberately not Send or Sync.
struct Local(*mut c_void);
impl Drop for Local {
    fn drop(&mut self) {
        // Frame endpoint is closed before its parent; no native borrow escapes step().
        let status = unsafe { proof_close(self.0) };
        if status != 0 {
            eprintln!("Howl close failed: {status}");
        }
    }
}
struct Frame {
    pixels: Vec<u8>,
    width: u32,
    height: u32,
}
#[derive(Clone, Copy)]
struct Key {
    named: u8,
    scalar: u32,
    action: u8,
    modifiers: u8,
}
#[derive(Default)]
struct Mailbox {
    frame: Option<Frame>,
    size: Option<(u32, u32)>,
    status: Option<String>,
}

pub struct Terminal {
    stop: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
    _timer: Timer,
}
impl Drop for Terminal {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(worker) = self.worker.take()
            && worker.join().is_err()
        {
            eprintln!("Howl terminal worker panicked");
        }
    }
}
impl Terminal {
    pub fn attach(app: &App) -> Self {
        let mailbox = Arc::new(Mutex::new(Mailbox::default()));
        let stop = Arc::new(AtomicBool::new(false));
        let (tx, rx) = mpsc::sync_channel::<Key>(64);
        let shared = mailbox.clone();
        let stopping = stop.clone();
        // The view and native terminal share Style; Howl owns text rasterization.
        let style = app.get_style();
        let patterns = [
            style.terminal_regular,
            style.terminal_italic,
            style.terminal_bold,
            style.terminal_bold_italic,
        ]
        .map(|v| v.to_string());
        let fallback_patterns: Vec<String> = style
            .terminal_fallbacks
            .iter()
            .map(|v| v.to_string())
            .collect();
        let pixel_size = style.terminal_font_size.round().clamp(1.0, u16::MAX as f32) as u16;
        let worker = thread::spawn(move || {
            run(
                shared,
                stopping,
                rx,
                patterns,
                fallback_patterns,
                pixel_size,
            );
        });
        let weak = app.as_weak();
        app.on_terminal_key(move |event, released| {
            let Some(key) = key(event, released) else {
                return;
            };
            send(&tx, key, &weak);
        });
        let shared = mailbox.clone();
        app.on_terminal_resize(move |w, h| {
            shared.lock().unwrap().size = Some((w.max(0) as u32, h.max(0) as u32));
        });
        let timer = Timer::default();
        let weak = app.as_weak();
        timer.start(
            TimerMode::Repeated,
            std::time::Duration::from_millis(16),
            move || {
                let Some(app) = weak.upgrade() else { return };
                let (frame, status) = {
                    let mut mailbox = mailbox.lock().unwrap();
                    (mailbox.frame.take(), mailbox.status.take())
                };
                if let Some(frame) = frame {
                    let buffer = SharedPixelBuffer::<Rgba8Pixel>::clone_from_slice(
                        &frame.pixels,
                        frame.width,
                        frame.height,
                    );
                    app.set_terminal_frame(slint::Image::from_rgba8(buffer));
                }
                if let Some(status) = status {
                    app.set_terminal_status(status.into());
                }
            },
        );
        app.set_terminal_enabled(true);
        app.set_sessions(slint::ModelRc::new(slint::VecModel::from(vec![
            slint::SharedString::from("Local Bash"),
        ])));
        app.set_selected_title("Local Bash".into());
        Self {
            stop,
            worker: Some(worker),
            _timer: timer,
        }
    }
}
// Only this thread enters Howl. Size/frame/status are latest-value mailboxes;
// keys retain order in a bounded queue. No native pointer crosses into the UI.
fn run(
    shared: Arc<Mutex<Mailbox>>,
    stopping: Arc<AtomicBool>,
    rx: Receiver<Key>,
    patterns: [String; 4],
    fallback_patterns: Vec<String>,
    pixel_size: u16,
) {
    let result = (|| -> Result<(), String> {
        let variables = [
            "HOWL_FONT",
            "HOWL_ITALIC_FONT",
            "HOWL_BOLD_FONT",
            "HOWL_BOLD_ITALIC_FONT",
        ];
        let fonts: Vec<Option<CString>> = patterns
            .iter()
            .zip(variables)
            .map(|(pattern, variable)| {
                if let Ok(path) = std::env::var(variable) {
                    return resolve_font(&path).map(Some);
                }
                if pattern.is_empty() {
                    return Ok(None);
                }
                resolve_font(pattern).map(Some)
            })
            .collect::<Result<_, String>>()?;
        if fonts[0].is_none() {
            return Err("A regular terminal font is required".into());
        }
        if fallback_patterns.len() > 24 {
            return Err("Howl allows at most 24 fallback fonts".into());
        }
        let fallbacks = fallback_patterns
            .iter()
            .map(|p| resolve_font(p))
            .collect::<Result<Vec<_>, _>>()?;
        let font_ptrs: Vec<_> = fonts
            .iter()
            .map(|f| f.as_ref().map_or(std::ptr::null(), |f| f.as_ptr()))
            .collect();
        let fallback_ptrs: Vec<_> = fallbacks.iter().map(|f| f.as_ptr()).collect();
        let home = CString::new(std::env::var("HOME").map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
        let mut raw = std::ptr::null_mut();
        check(unsafe {
            proof_open(
                font_ptrs.as_ptr(),
                fallback_ptrs.as_ptr(),
                fallback_ptrs.len(),
                home.as_ptr(),
                pixel_size,
                &mut raw,
            )
        })
        .map_err(|e| format!("open: {e}"))?;
        let local = Local(raw);
        shared.lock().unwrap().status = Some("Local Bash · CPU proof".into());
        while !stopping.load(Ordering::Relaxed) {
            for _ in 0..64 {
                let Ok(k) = rx.try_recv() else { break };
                check(unsafe { proof_key(local.0, k.named, k.scalar, k.action, k.modifiers) })?;
            }
            let size = shared.lock().unwrap().size.take();
            if let Some((w, h)) = size {
                check(unsafe { proof_resize(local.0, w, h) })
                    .map_err(|e| format!("resize: {e}"))?;
            }
            let (mut pixels, mut width, mut height, mut exited) = (std::ptr::null(), 0, 0, 0);
            check(unsafe {
                proof_step(local.0, &mut pixels, &mut width, &mut height, &mut exited)
            })
            .map_err(|e| format!("service/frame: {e}"))?;
            if !pixels.is_null() {
                // Native storage remains valid until this worker's next call.
                let pixels = unsafe {
                    std::slice::from_raw_parts(pixels, width as usize * height as usize * 4)
                }
                .to_vec();
                shared.lock().unwrap().frame = Some(Frame {
                    pixels,
                    width,
                    height,
                });
            }
            if exited != 0 {
                shared.lock().unwrap().status = Some("Local shell exited".into());
                break;
            }
        }
        Ok(())
    })();
    if let Err(error) = result {
        shared.lock().unwrap().status = Some(error);
    }
}

fn resolve_font(pattern: &str) -> Result<CString, String> {
    if pattern.starts_with('/') {
        if !std::path::Path::new(pattern).is_file() {
            return Err(format!("Font file missing: {pattern}"));
        }
        return CString::new(pattern).map_err(|e| e.to_string());
    }
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

fn check(status: u32) -> Result<(), String> {
    if status == 0 {
        Ok(())
    } else {
        Err(format!("Howl native error {status}"))
    }
}
fn send(tx: &SyncSender<Key>, key: Key, app: &slint::Weak<App>) {
    if let Err(error) = tx.try_send(key)
        && let Some(app) = app.upgrade()
    {
        app.set_terminal_status(format!("Input rejected: {error}").into());
    }
}
fn key(event: slint::language::KeyEvent, released: bool) -> Option<Key> {
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

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn missing_named_font_is_not_silently_substituted() {
        assert!(resolve_font("Howl deliberately absent font face 935710").is_err());
    }
    #[test]
    fn local_shell_publishes_owned_frame_and_closes() {
        let font = resolve_font("monospace").unwrap();
        let font_ptrs = [font.as_ptr(); 4];
        let fallback_ptrs: [*const c_char; 0] = [];
        let pixel_size = 14; // Exercise a size distinct from the UI default.
        let home = CString::new(std::env::var("HOME").unwrap()).unwrap();
        let mut raw = std::ptr::null_mut();
        assert_eq!(
            unsafe {
                proof_open(
                    font_ptrs.as_ptr(),
                    fallback_ptrs.as_ptr(),
                    fallback_ptrs.len(),
                    home.as_ptr(),
                    pixel_size,
                    &mut raw,
                )
            },
            0,
            "open"
        );
        let local = Local(raw);
        assert_eq!(unsafe { proof_resize(local.0, 680, 540) }, 0, "resize");
        let mut frames = 0;
        for _ in 0..20 {
            let (mut pixels, mut width, mut height, mut exited) = (std::ptr::null(), 0, 0, 0);
            assert_eq!(
                unsafe { proof_step(local.0, &mut pixels, &mut width, &mut height, &mut exited) },
                0,
                "step"
            );
            if !pixels.is_null() {
                assert!(width > 0 && height > 0);
                frames += 1;
            }
        }
        assert!(frames > 0);
        for scalar in "exit".chars() {
            assert_eq!(unsafe { proof_key(local.0, 0, scalar as u32, 1, 0) }, 0);
        }
        assert_eq!(unsafe { proof_key(local.0, 1, 0, 1, 0) }, 0);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
        loop {
            let (mut pixels, mut width, mut height, mut exited) = (std::ptr::null(), 0, 0, 0);
            assert_eq!(
                unsafe { proof_step(local.0, &mut pixels, &mut width, &mut height, &mut exited) },
                0,
                "exit step"
            );
            if exited != 0 {
                break;
            }
            assert!(std::time::Instant::now() < deadline, "shell did not exit");
        }
        let local = std::mem::ManuallyDrop::new(local);
        assert_eq!(unsafe { proof_close(local.0) }, 0, "close");
    }
}
