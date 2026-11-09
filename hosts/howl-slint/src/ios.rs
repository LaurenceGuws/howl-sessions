//! Small public-API iOS boundary. UIKit and Slint share the main thread.
use crate::App;
use slint::ComponentHandle;
use std::{
    ffi::{CStr, c_char, c_void},
    path::PathBuf,
};

unsafe extern "C" {
    fn howl_ios_settings_directory() -> *mut c_char;
    fn howl_ios_font_path() -> *mut c_char;
    fn howl_ios_free_string(value: *mut c_char);
    fn howl_ios_observe_lifecycle(
        callback: extern "C" fn(*mut c_void),
        context: *mut c_void,
    ) -> *mut c_void;
    fn howl_ios_remove_lifecycle(handle: *mut c_void);
}

fn owned_path(pointer: *mut c_char, unavailable: &str) -> Result<PathBuf, String> {
    if pointer.is_null() {
        return Err(unavailable.into());
    }
    // The bridge returns an owned, terminated UTF-8 filesystem path. Copy it
    // before releasing the allocation, including on invalid UTF-8.
    let path = unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map(PathBuf::from)
        .map_err(|error| format!("Invalid iOS filesystem path: {error}"));
    unsafe { howl_ios_free_string(pointer) };
    path.and_then(|path| {
        if path.is_absolute() {
            Ok(path)
        } else {
            Err("iOS returned a non-absolute filesystem path".into())
        }
    })
}

pub(crate) fn settings_path() -> Result<PathBuf, String> {
    owned_path(
        unsafe { howl_ios_settings_directory() },
        "iOS Application Support directory is unavailable",
    )
    .map(|path| path.join("howl-sessions/settings.json"))
}

pub(crate) fn configure_fonts(app: &App) -> Result<(), String> {
    let path = owned_path(
        unsafe { howl_ios_font_path() },
        "iOS has no readable CoreText monospace font at collection face zero",
    )?;
    if !path.is_file() {
        return Err(format!("iOS font file is unavailable: {}", path.display()));
    }
    let mut style = app.get_style();
    style.terminal_regular = path.to_string_lossy().as_ref().into();
    style.terminal_italic = "".into();
    style.terminal_bold = "".into();
    style.terminal_bold_italic = "".into();
    style.terminal_fallbacks =
        slint::ModelRc::new(slint::VecModel::<slint::SharedString>::default());
    app.set_style(style);
    app.set_font_note("iOS system monospace · limited coverage".into());
    Ok(())
}

// The Box makes the weak reference address stable until the observer is removed.
// Weak<App> also keeps this owner !Send, matching UIKit's main-thread contract.
pub(crate) struct Lifecycle {
    handle: *mut c_void,
    _window: Box<slint::Weak<App>>,
}

impl Lifecycle {
    pub(crate) fn attach(app: &App) -> Self {
        extern "C" fn suspend(context: *mut c_void) {
            // No panic may unwind through Objective-C. Disconnect failure must
            // not leave an invisible live attachment running.
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let weak = unsafe { &*context.cast::<slint::Weak<App>>() };
                if let Some(app) = weak.upgrade() {
                    app.invoke_disconnect_server();
                }
            }));
            if result.is_err() {
                std::process::abort();
            }
        }
        let mut window = Box::new(app.as_weak());
        let handle = unsafe {
            howl_ios_observe_lifecycle(suspend, (&mut *window as *mut slint::Weak<App>).cast())
        };
        Self {
            handle,
            _window: window,
        }
    }
}

impl Drop for Lifecycle {
    fn drop(&mut self) {
        // Remove the observer before its callback context is released.
        unsafe { howl_ios_remove_lifecycle(self.handle) };
    }
}
