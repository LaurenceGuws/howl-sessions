mod input;
mod sessions;
mod settings;

use slint::ComponentHandle;

slint::include_modules!();

pub fn run() -> Result<(), slint::PlatformError> {
    run_window(App::new()?, settings::desktop_path())
}

fn run_window(
    app: App,
    settings_path: Result<std::path::PathBuf, String>,
) -> Result<(), slint::PlatformError> {
    let sessions = std::rc::Rc::new(sessions::Sessions::attach(&app));
    let profile_sessions = sessions.clone();
    settings::attach(&app, settings_path, move |profiles| {
        profile_sessions.refresh_profiles(profiles);
    });
    app.run()
}

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
fn android_main(app: slint::android::AndroidApp) {
    use slint::android::android_activity::{MainEvent, PollEvent};
    use std::{cell::RefCell, rc::Rc};
    // NativeActivity events and the Slint callbacks share this UI thread. Keep
    // only a weak window reference; pausing detaches, never closes Server jobs.
    let settings_path = app
        .internal_data_path()
        .map(|path| path.join("settings.json"))
        .ok_or_else(|| "Android app-private settings directory is unavailable".to_owned());
    let window = Rc::new(RefCell::new(None::<slint::Weak<App>>));
    let lifecycle_window = window.clone();
    slint::android::init_with_event_listener(app, move |event| {
        if matches!(
            event,
            PollEvent::Main(MainEvent::Pause | MainEvent::Stop | MainEvent::Destroy)
        ) && let Some(app) = lifecycle_window
            .borrow()
            .as_ref()
            .and_then(|weak| weak.upgrade())
        {
            app.invoke_disconnect_server();
        }
    })
    .expect("Android platform initialization failed");
    let app = App::new().expect("Howl Sessions window creation failed");
    input::configure_android_fonts(&app);
    *window.borrow_mut() = Some(app.as_weak());
    run_window(app, settings_path).expect("Howl Sessions UI failed");
}
