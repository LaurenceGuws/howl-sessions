// UI preview data, not Server or Session identities. Transport is not connected.
pub struct ShellState {
    pub sessions: [&'static str; 2],
    selected: usize,
}

impl Default for ShellState {
    fn default() -> Self {
        Self {
            sessions: ["Shell preview", "Workspace preview"],
            selected: 0,
        }
    }
}

impl ShellState {
    pub fn select(&mut self, index: usize) -> bool {
        if index >= self.sessions.len() {
            return false;
        }
        self.selected = index;
        true
    }

    pub fn selected_title(&self) -> &'static str {
        self.sessions[self.selected]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selection_is_local_and_bounded() {
        let mut state = ShellState::default();
        assert_eq!(state.selected_title(), "Shell preview");
        assert!(state.select(1));
        assert_eq!(state.selected_title(), "Workspace preview");
        assert!(!state.select(usize::MAX));
        assert_eq!(state.selected_title(), "Workspace preview");
        assert!(state.select(1));
    }
}
