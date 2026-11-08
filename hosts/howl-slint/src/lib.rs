mod input;
mod sessions;

use slint::ComponentHandle;

slint::include_modules!();

pub fn run() -> Result<(), slint::PlatformError> {
    run_window(App::new()?)
}

fn run_window(app: App) -> Result<(), slint::PlatformError> {
    let _sessions = sessions::Sessions::attach(&app);
    app.run()
}

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
fn android_main(app: slint::android::AndroidApp) {
    use slint::android::android_activity::{MainEvent, PollEvent};
    use std::{cell::RefCell, rc::Rc};
    // NativeActivity events and the Slint callbacks share this UI thread. Keep
    // only a weak window reference; pausing detaches, never closes Server jobs.
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
    run_window(app).expect("Howl Sessions UI failed");
}
