mod state;

use slint::{ComponentHandle, ModelRc, SharedString, VecModel};
use state::ShellState;
use std::cell::RefCell;

slint::include_modules!();

fn main() -> Result<(), slint::PlatformError> {
    let app = App::new()?;
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
    app.run()
}
