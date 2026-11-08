mod state;
mod ui;

use slint::{ComponentHandle, ModelRc, SharedString, VecModel};
use state::ShellState;
use std::cell::RefCell;
use ui::App;

fn main() -> Result<(), slint::PlatformError> {
    let app = App::new()?;
    app.set_style(ui::style::defaults());
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
            app.set_show_sessions(false);
        }
    });
    app.run()
}
