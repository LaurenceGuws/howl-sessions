#[cfg(not(feature = "terminal-proof"))]
mod state;
#[cfg(feature = "terminal-proof")]
mod terminal;

use slint::ComponentHandle;

slint::include_modules!();

pub fn run() -> Result<(), slint::PlatformError> {
    let app = App::new()?;
    #[cfg(not(feature = "terminal-proof"))]
    configure_preview(&app);
    #[cfg(feature = "terminal-proof")]
    let _terminal = terminal::Terminal::attach(&app);
    app.run()
}

#[cfg(not(feature = "terminal-proof"))]
fn configure_preview(app: &App) {
    use slint::{ModelRc, SharedString, VecModel};
    use state::ShellState;
    use std::cell::RefCell;

    let state = RefCell::new(ShellState::default());
    app.set_sessions(ModelRc::new(VecModel::from(
        state
            .borrow()
            .sessions
            .iter()
            .map(|name| SharedString::from(*name))
            .collect::<Vec<_>>(),
    )));
    app.set_selected_title(state.borrow().selected_title().into());

    let weak = app.as_weak();
    app.on_select_session(move |index| {
        let Ok(index) = usize::try_from(index) else {
            return;
        };
        let mut state = state.borrow_mut();
        if state.select(index)
            && let Some(app) = weak.upgrade()
        {
            app.set_selected_index(index as i32);
            app.set_selected_title(state.selected_title().into());
        }
    });
}

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
fn android_main(app: slint::android::AndroidApp) {
    slint::android::init(app).expect("Android platform initialization failed");
    run().expect("Howl Sessions UI failed");
}
