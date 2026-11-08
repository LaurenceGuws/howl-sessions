//! Server owns the PTY. One command owner services input/geometry; one observer
//! blocks for snapshots and renders. Both sleep on work, never a polling timer.
use crate::{
    App,
    input::{Key, key, resolve_font},
};
use slint::{ComponentHandle, Model, Rgba8Pixel, SharedPixelBuffer};
use std::{
    cell::RefCell,
    ffi::{CString, c_char, c_void},
    rc::Rc,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, SyncSender},
    },
    thread::{self, JoinHandle},
};

unsafe extern "C" {
    fn hsc_interrupt_create(version: u32, out: *mut *mut c_void) -> u32;
    fn hsc_interrupt_cancel(interrupt: *mut c_void) -> u32;
    fn hsc_interrupt_release(interrupt: *mut *mut c_void);
    fn remote_open(endpoint: *const c_char, interrupt: *mut c_void, out: *mut *mut c_void) -> u32;
    fn remote_count(client: *mut c_void) -> usize;
    fn remote_item(
        client: *mut c_void,
        index: usize,
        name: *mut c_char,
        capacity: usize,
        length: *mut usize,
        server: *mut u64,
        session: *mut u64,
        instance: *mut u64,
    ) -> u32;
    fn remote_attach(
        client: *mut c_void,
        server: u64,
        session: u64,
        instance: u64,
        fonts: *const *const c_char,
        fallbacks: *const *const c_char,
        fallback_count: usize,
        pixel_size: u16,
    ) -> u32;
    fn remote_cell_size(client: *mut c_void, width: *mut u16, height: *mut u16) -> u32;
    fn remote_step(
        client: *mut c_void,
        pixels: *mut *const u8,
        width: *mut u32,
        height: *mut u32,
        exited: *mut i32,
    ) -> u32;
    fn remote_close(client: *mut c_void) -> u32;
    fn remote_actions_open(
        endpoint: *const c_char,
        interrupt: *mut c_void,
        server: u64,
        session: u64,
        instance: u64,
        out: *mut *mut c_void,
    ) -> u32;
    fn remote_actions_close(actions: *mut c_void);
    fn remote_actions_key(actions: *mut c_void, key: u8, scalar: u32, action: u8, mods: u8) -> u32;
    fn remote_actions_resize(
        actions: *mut c_void,
        width: u32,
        height: u32,
        cell_width: u16,
        cell_height: u16,
    ) -> u32;
}

// The Client ABI expressly allows cancellation concurrently with borrowing I/O.
// All other native handles stay on their constructing/owning thread.
struct Interrupt(*mut c_void);
unsafe impl Send for Interrupt {}
unsafe impl Sync for Interrupt {}
impl Interrupt {
    fn new() -> Result<Self, String> {
        let mut raw = std::ptr::null_mut();
        check(unsafe { hsc_interrupt_create(1, &mut raw) })?;
        Ok(Self(raw))
    }
    fn cancel(&self) {
        let status = unsafe { hsc_interrupt_cancel(self.0) };
        if status != 0 {
            eprintln!("Server cancellation failed: {status}");
        }
    }
}
impl Drop for Interrupt {
    fn drop(&mut self) {
        unsafe {
            hsc_interrupt_release(&mut self.0);
        }
    }
}
struct Client(*mut c_void);
impl Drop for Client {
    fn drop(&mut self) {
        let code = unsafe { remote_close(self.0) };
        if code != 0 {
            eprintln!("Server client close failed: {code}");
        }
    }
}
struct Actions(*mut c_void);
impl Drop for Actions {
    fn drop(&mut self) {
        unsafe {
            remote_actions_close(self.0);
        }
    }
}
#[derive(Clone)]
struct Entry {
    name: String,
    server: u64,
    session: u64,
    instance: u64,
}
#[derive(Clone)]
struct Fonts {
    patterns: [String; 4],
    fallbacks: Vec<String>,
    size: u16,
}

#[derive(Default)]
struct Update {
    frame: Option<SharedPixelBuffer<Rgba8Pixel>>,
    catalog: Option<Vec<Entry>>,
    selected: Option<(usize, String)>,
    status: Option<String>,
    clear_frame: bool,
    finished: bool,
}
impl Update {
    fn select(&mut self, index: usize, name: String) {
        self.frame = None;
        self.clear_frame = true;
        self.selected = Some((index, name));
        self.status = Some("Attaching…".into());
    }
}

#[derive(Default)]
struct Mailbox {
    update: Update,
    queued: bool,
}
impl Mailbox {
    fn publish(&mut self, change: impl FnOnce(&mut Update)) -> bool {
        change(&mut self.update);
        if self.queued {
            false
        } else {
            self.queued = true;
            true
        }
    }
    fn take(&mut self, active: bool) -> Option<Update> {
        self.queued = false;
        let update = std::mem::take(&mut self.update);
        active.then_some(update)
    }
}

#[derive(Clone)]
struct View {
    app: slint::Weak<App>,
    mailbox: Arc<Mutex<Mailbox>>,
    active: Arc<AtomicBool>,
}
impl View {
    fn publish(&self, change: impl FnOnce(&mut Update)) {
        if !self.active.load(Ordering::Acquire) {
            return;
        }
        let schedule = self.mailbox.lock().unwrap().publish(change);
        if !schedule {
            return;
        }
        let mailbox = self.mailbox.clone();
        let active = self.active.clone();
        // At most one pending callback. The latest owned frame replaces older
        // unpublished frames, not a growing event queue of images.
        if self
            .app
            .upgrade_in_event_loop(move |app| {
                let update = { mailbox.lock().unwrap().take(active.load(Ordering::Acquire)) };
                if let Some(update) = update {
                    apply_update(&app, update);
                }
            })
            .is_err()
        {
            self.active.store(false, Ordering::Release);
        }
    }
}
fn apply_update(app: &App, update: Update) {
    if let Some(catalog) = update.catalog {
        app.set_sessions(slint::ModelRc::new(slint::VecModel::from(
            catalog
                .iter()
                .map(|e| slint::SharedString::from(&e.name))
                .collect::<Vec<_>>(),
        )));
        app.set_server_connecting(false);
        app.set_server_connected(true);
        app.set_connection_detail("Server connection".into());
    }
    if update.clear_frame {
        app.set_terminal_frame(slint::Image::default());
    }
    if let Some((index, title)) = update.selected {
        app.set_selected_index(index as i32);
        app.set_selected_title(title.into());
        app.set_terminal_enabled(true);
    }
    if let Some(frame) = update.frame {
        app.set_terminal_frame(slint::Image::from_rgba8(frame));
    }
    if let Some(status) = update.status {
        app.set_terminal_status(status.into());
    }
    if update.finished {
        app.set_server_connecting(false);
        app.set_server_connected(false);
        app.set_terminal_enabled(false);
        app.set_selected_index(-1);
        app.set_sessions(slint::ModelRc::new(slint::VecModel::from(Vec::<
            slint::SharedString,
        >::new())));
        app.set_connection_detail("Disconnected".into());
    }
}

// Resize and Ready are coalesced facts. Wake is only a notification: if the
// bounded command queue is full, its receiver is already guaranteed work.
#[derive(Default)]
struct Pending {
    size: Option<(u32, u32)>,
    ready: Option<(u16, u16)>,
    ended: Option<Result<(), String>>,
}
enum Command {
    Select(usize),
    Key(Key),
    Wake,
    Stop,
}
struct Cancellation {
    stopping: AtomicBool,
    commands: Arc<Interrupt>,
    observer: Mutex<Option<Arc<Interrupt>>>,
}
impl Cancellation {
    fn stop(&self) {
        self.stopping.store(true, Ordering::Release);
        self.commands.cancel();
        if let Some(observer) = self.observer.lock().unwrap().as_ref() {
            observer.cancel();
        }
    }
    fn install_observer(&self, interrupt: Arc<Interrupt>) -> Result<(), String> {
        let mut observer = self.observer.lock().unwrap();
        if self.stopping.load(Ordering::Acquire) {
            return Err("Connection cancelled".into());
        }
        *observer = Some(interrupt);
        Ok(())
    }
}
struct Observer {
    interrupt: Arc<Interrupt>,
    worker: Option<JoinHandle<()>>,
}
impl Drop for Observer {
    fn drop(&mut self) {
        self.interrupt.cancel();
        if let Some(worker) = self.worker.take()
            && worker.join().is_err()
        {
            eprintln!("Server observer panicked");
        }
    }
}
struct Connection {
    cancellation: Arc<Cancellation>,
    sender: SyncSender<Command>,
    worker: Option<JoinHandle<()>>,
    pending: Arc<Mutex<Pending>>,
    view: View,
}
impl Drop for Connection {
    fn drop(&mut self) {
        self.view.active.store(false, Ordering::Release);
        self.cancellation.stop();
        let _ = self.sender.try_send(Command::Stop);
        // Cancel both native I/O lanes before joining the command owner, which
        // cancels/joins its observer. No owner can be stuck sending Ready.
        if let Some(worker) = self.worker.take()
            && worker.join().is_err()
        {
            eprintln!("Server command owner panicked");
        }
    }
}
pub struct Sessions {
    connection: Rc<RefCell<Option<Connection>>>,
}
impl Drop for Sessions {
    fn drop(&mut self) {
        self.connection.borrow_mut().take();
    }
}
impl Sessions {
    pub fn attach(app: &App) -> Self {
        let connection = Rc::new(RefCell::new(None::<Connection>));
        app.set_selected_index(-1);
        app.set_selected_title("No session selected".into());
        app.set_terminal_status("Connect to a Server, then choose a session".into());
        app.set_connection_detail("Disconnected".into());
        if let Ok(endpoint) = std::env::var("HOWL_SERVER") {
            app.set_server_endpoint(endpoint.into());
        }
        let slot = connection.clone();
        let weak = app.as_weak();
        app.on_connect_server(move |endpoint| {
            let Some(app) = weak.upgrade() else {
                return;
            };
            slot.borrow_mut().take();
            reset_view(&app);
            let endpoint = match CString::new(endpoint.trim()) {
                Ok(endpoint)
                    if !endpoint.as_bytes().is_empty() && endpoint.as_bytes().len() <= 1024 =>
                {
                    endpoint
                }
                _ => {
                    app.set_terminal_status(
                        "Enter a valid Server endpoint (up to 1024 bytes)".into(),
                    );
                    return;
                }
            };
            let interrupt = match Interrupt::new() {
                Ok(value) => Arc::new(value),
                Err(error) => {
                    app.set_terminal_status(error.into());
                    return;
                }
            };
            let style = app.get_style();
            let fonts = Fonts {
                patterns: [
                    style.terminal_regular,
                    style.terminal_italic,
                    style.terminal_bold,
                    style.terminal_bold_italic,
                ]
                .map(|v| v.to_string()),
                fallbacks: style
                    .terminal_fallbacks
                    .iter()
                    .map(|v| v.to_string())
                    .collect(),
                size: style.terminal_font_size.round().clamp(1.0, u16::MAX as f32) as u16,
            };
            let view = View {
                app: app.as_weak(),
                mailbox: Arc::new(Mutex::new(Mailbox::default())),
                active: Arc::new(AtomicBool::new(true)),
            };
            let pending = Arc::new(Mutex::new(Pending::default()));
            let cancellation = Arc::new(Cancellation {
                stopping: AtomicBool::new(false),
                commands: interrupt,
                observer: Mutex::new(None),
            });
            let (sender, receiver) = mpsc::sync_channel(64);
            let owner = cancellation.clone();
            let updates = view.clone();
            let facts = pending.clone();
            let wake = sender.clone();
            app.set_server_connecting(true);
            app.set_terminal_status("Connecting…".into());
            let worker =
                thread::spawn(move || run(endpoint, owner, receiver, wake, facts, updates, fonts));
            *slot.borrow_mut() = Some(Connection {
                cancellation,
                sender,
                worker: Some(worker),
                pending,
                view,
            });
        });
        let slot = connection.clone();
        let weak = app.as_weak();
        app.on_disconnect_server(move || {
            slot.borrow_mut().take();
            if let Some(app) = weak.upgrade() {
                reset_view(&app);
                app.set_terminal_status("Disconnected; Server sessions are unchanged".into());
            }
        });
        let slot = connection.clone();
        let weak = app.as_weak();
        app.on_select_session(move |index| {
            if let Ok(index) = usize::try_from(index) {
                send(&slot, Command::Select(index), &weak);
            }
        });
        let slot = connection.clone();
        let weak = app.as_weak();
        app.on_terminal_key(move |event, released| {
            if let Some(key) = key(event, released) {
                send(&slot, Command::Key(key), &weak);
            }
        });
        let slot = connection.clone();
        app.on_terminal_resize(move |w, h| {
            if let Some(connection) = slot.borrow().as_ref() {
                connection.pending.lock().unwrap().size = Some((w.max(0) as u32, h.max(0) as u32));
                let _ = connection.sender.try_send(Command::Wake);
            }
        });
        Self { connection }
    }
}
fn reset_view(app: &App) {
    app.set_server_connected(false);
    app.set_server_connecting(false);
    app.set_terminal_enabled(false);
    app.set_terminal_frame(slint::Image::default());
    app.set_selected_index(-1);
    app.set_selected_title("No session selected".into());
    app.set_sessions(slint::ModelRc::new(slint::VecModel::from(Vec::<
        slint::SharedString,
    >::new())));
    app.set_connection_detail("Disconnected".into());
}
fn send(slot: &RefCell<Option<Connection>>, command: Command, weak: &slint::Weak<App>) {
    if let Some(connection) = slot.borrow().as_ref()
        && let Err(error) = connection.sender.try_send(command)
        && let Some(app) = weak.upgrade()
    {
        app.set_terminal_status(format!("Request rejected: {error}").into());
    }
}
fn check(code: u32) -> Result<(), String> {
    match code {
        0 => Ok(()),
        4 => Err("Connection cancelled".into()),
        5 => Err("Server timed out".into()),
        6 | 7 => Err("Server connection closed; reconnect to refresh the session list".into()),
        13 => Err("Server data exceeds this host's current limits".into()),
        106 => {
            Err("This terminal contains images; remote image rendering is not supported yet".into())
        }
        9 => Err("Server restarted; reconnect and select the session again".into()),
        20 | 21 => Err("That Server session is no longer available; refresh the list".into()),
        10 => Err("Server transport failed; check the endpoint and reconnect".into()),
        code => Err(format!("Server client error {code}")),
    }
}
fn catalog(endpoint: &CString, interrupt: &Interrupt) -> Result<Vec<Entry>, String> {
    let mut raw = std::ptr::null_mut();
    check(unsafe { remote_open(endpoint.as_ptr(), interrupt.0, &mut raw) })?;
    let client = Client(raw);
    let count = unsafe { remote_count(client.0) };
    if count > 256 {
        return Err("Server catalog exceeds this host's 256-instance limit".into());
    }
    let mut entries = Vec::with_capacity(count);
    for index in 0..count {
        let mut name = [0u8; 256];
        let (mut length, mut server, mut session, mut instance) = (0, 0, 0, 0);
        check(unsafe {
            remote_item(
                client.0,
                index,
                name.as_mut_ptr().cast(),
                name.len(),
                &mut length,
                &mut server,
                &mut session,
                &mut instance,
            )
        })?;
        if length > name.len() {
            return Err("Invalid Server catalog label".into());
        }
        entries.push(Entry {
            name: format!("{} · {instance}", String::from_utf8_lossy(&name[..length])),
            server,
            session,
            instance,
        });
    }
    Ok(entries)
}
fn run(
    endpoint: CString,
    cancellation: Arc<Cancellation>,
    receiver: Receiver<Command>,
    sender: SyncSender<Command>,
    pending: Arc<Mutex<Pending>>,
    view: View,
    fonts: Fonts,
) {
    let result = (|| -> Result<(), String> {
        let entries = catalog(&endpoint, &cancellation.commands)?;
        view.publish(|update| {
            update.catalog = Some(entries.clone());
            update.status = Some(
                if entries.is_empty() {
                    "Server has no terminal instances"
                } else {
                    "Choose a session to attach"
                }
                .into(),
            );
        });
        let mut observer = None::<Observer>;
        let mut actions = None::<Actions>;
        let mut last_size = None;
        let mut cell = None;
        while let Ok(command) = receiver.recv() {
            if cancellation.stopping.load(Ordering::Acquire) {
                break;
            }
            match command {
                Command::Stop => break,
                Command::Select(index) if index < entries.len() => {
                    let entry = &entries[index];
                    // Join before clearing pending updates. Nothing from the old
                    // selection can repopulate this mailbox after this point.
                    observer.take();
                    actions.take();
                    cancellation.observer.lock().unwrap().take();
                    {
                        let mut facts = pending.lock().unwrap();
                        facts.ready = None;
                        facts.ended = None;
                    }
                    cell = None;
                    view.publish(|update| update.select(index, entry.name.clone()));
                    let mut raw = std::ptr::null_mut();
                    check(unsafe {
                        remote_actions_open(
                            endpoint.as_ptr(),
                            cancellation.commands.0,
                            entry.server,
                            entry.session,
                            entry.instance,
                            &mut raw,
                        )
                    })?;
                    actions = Some(Actions(raw));
                    let interrupt = Arc::new(Interrupt::new()?);
                    cancellation.install_observer(interrupt.clone())?;
                    let owner = interrupt.clone();
                    let target = entry.clone();
                    let address = endpoint.clone();
                    let fonts = fonts.clone();
                    let facts = pending.clone();
                    let wake = sender.clone();
                    let updates = view.clone();
                    let worker = thread::spawn(move || {
                        observe(address, target, owner, fonts, facts, wake, updates)
                    });
                    observer = Some(Observer {
                        interrupt,
                        worker: Some(worker),
                    });
                }
                Command::Key(key) => {
                    if let Some(actions) = actions.as_ref() {
                        check(unsafe {
                            remote_actions_key(
                                actions.0,
                                key.named,
                                key.scalar,
                                key.action,
                                key.modifiers,
                            )
                        })?;
                    }
                }
                Command::Wake | Command::Select(_) => {}
            }
            let (size, ready, ended) = {
                let mut facts = pending.lock().unwrap();
                (facts.size.take(), facts.ready.take(), facts.ended.take())
            };
            let resized = size.is_some() || ready.is_some();
            if let Some(size) = size {
                last_size = Some(size);
            }
            if let Some(ready) = ready {
                cell = Some(ready);
                view.publish(|update| update.status = Some("Connected".into()));
            }
            if let Some(result) = ended {
                observer.take();
                actions.take();
                cancellation.observer.lock().unwrap().take();
                cell = None;
                view.publish(|update| {
                    update.status =
                        Some(result.err().unwrap_or_else(|| "Remote shell exited".into()))
                });
            } else if resized
                && let (Some(actions), Some((width, height)), Some((cell_width, cell_height))) =
                    (actions.as_ref(), last_size, cell)
            {
                check(unsafe {
                    remote_actions_resize(actions.0, width, height, cell_width, cell_height)
                })?;
            }
        }
        Ok(())
    })();
    // Any Observer local has now cancelled/joined, and native action/catalog
    // handles have been released. Clearing registration cannot race their use.
    cancellation.observer.lock().unwrap().take();
    view.publish(|update| {
        if let Err(error) = result {
            update.status = Some(error);
        }
        update.finished = true;
    });
}
fn observe(
    endpoint: CString,
    entry: Entry,
    interrupt: Arc<Interrupt>,
    fonts: Fonts,
    pending: Arc<Mutex<Pending>>,
    sender: SyncSender<Command>,
    view: View,
) {
    let result = (|| -> Result<(), String> {
        let variables = [
            "HOWL_FONT",
            "HOWL_ITALIC_FONT",
            "HOWL_BOLD_FONT",
            "HOWL_BOLD_ITALIC_FONT",
        ];
        let resolved = fonts
            .patterns
            .iter()
            .zip(variables)
            .map(|(pattern, variable)| {
                let pattern = std::env::var(variable).unwrap_or_else(|_| pattern.clone());
                if pattern.is_empty() {
                    Ok(None)
                } else {
                    resolve_font(&pattern).map(Some)
                }
            })
            .collect::<Result<Vec<_>, String>>()?;
        if resolved[0].is_none() {
            return Err("A regular terminal font is required".into());
        }
        if fonts.fallbacks.len() > 24 {
            return Err("At most 24 fallback fonts are supported".into());
        }
        let fallbacks = fonts
            .fallbacks
            .iter()
            .map(|v| resolve_font(v))
            .collect::<Result<Vec<_>, _>>()?;
        let faces: Vec<_> = resolved
            .iter()
            .map(|v| v.as_ref().map_or(std::ptr::null(), |v| v.as_ptr()))
            .collect();
        let fallback_ptrs: Vec<_> = fallbacks.iter().map(|v| v.as_ptr()).collect();
        let mut raw = std::ptr::null_mut();
        check(unsafe { remote_open(endpoint.as_ptr(), interrupt.0, &mut raw) })?;
        let client = Client(raw);
        check(unsafe {
            remote_attach(
                client.0,
                entry.server,
                entry.session,
                entry.instance,
                faces.as_ptr(),
                fallback_ptrs.as_ptr(),
                fallback_ptrs.len(),
                fonts.size,
            )
        })?;
        let (mut cell_width, mut cell_height) = (0, 0);
        check(unsafe { remote_cell_size(client.0, &mut cell_width, &mut cell_height) })?;
        pending.lock().unwrap().ready = Some((cell_width, cell_height));
        let _ = sender.try_send(Command::Wake);
        let mut previous = None;
        loop {
            let (mut pixels, mut width, mut height, mut exited) = (std::ptr::null(), 0, 0, 0);
            check(unsafe {
                remote_step(client.0, &mut pixels, &mut width, &mut height, &mut exited)
            })?;
            if !pixels.is_null() {
                if width == 0 || height == 0 || width > 2048 || height > 2048 {
                    return Err("Invalid remote frame dimensions".into());
                }
                let pixels = unsafe {
                    std::slice::from_raw_parts(pixels, width as usize * height as usize * 4)
                };
                if let Some(frame) = changed_frame(&mut previous, pixels, width, height) {
                    view.publish(|update| update.frame = Some(frame));
                }
            }
            if exited != 0 {
                break;
            }
        }
        Ok(())
    })();
    pending.lock().unwrap().ended = Some(result);
    let _ = sender.try_send(Command::Wake);
}
// Compare rendered pixels, not terminal revisions: cursor animation can change
// without new PTY output. The retained buffer shares ownership with Slint; it is
// never mutated, and a new native borrow is copied only when its image differs.
fn changed_frame(
    previous: &mut Option<SharedPixelBuffer<Rgba8Pixel>>,
    pixels: &[u8],
    width: u32,
    height: u32,
) -> Option<SharedPixelBuffer<Rgba8Pixel>> {
    if previous.as_ref().is_some_and(|frame| {
        frame.width() == width && frame.height() == height && frame.as_bytes() == pixels
    }) {
        return None;
    }
    let frame = SharedPixelBuffer::clone_from_slice(pixels, width, height);
    *previous = Some(frame.clone());
    Some(frame)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn publications_coalesce_and_rearm_without_losing_work() {
        let mut mailbox = Mailbox::default();
        assert!(mailbox.publish(|update| update.status = Some("first".into())));
        assert!(!mailbox.publish(|update| update.status = Some("latest".into())));
        assert!(!mailbox.publish(|update| update.frame = Some(SharedPixelBuffer::new(2, 2))));
        let update = mailbox.take(true).unwrap();
        assert_eq!(update.status.as_deref(), Some("latest"));
        assert!(update.frame.is_some());
        // A producer racing after event extraction schedules the next event.
        assert!(mailbox.publish(|update| update.status = Some("next".into())));
        assert_eq!(mailbox.take(true).unwrap().status.as_deref(), Some("next"));
    }

    #[test]
    fn disconnected_view_discards_already_queued_updates() {
        let mut mailbox = Mailbox::default();
        assert!(mailbox.publish(|update| {
            update.frame = Some(SharedPixelBuffer::new(2, 2));
            update.selected = Some((0, "old session".into()));
        }));
        assert!(mailbox.take(false).is_none());
        assert!(!mailbox.queued);
        assert!(mailbox.update.frame.is_none());
        assert!(mailbox.update.selected.is_none());
    }

    #[test]
    fn selection_clears_old_unpublished_frame_before_new_owner_starts() {
        let mut mailbox = Mailbox::default();
        assert!(mailbox.publish(|update| update.frame = Some(SharedPixelBuffer::new(2, 2))));
        // Production calls select only after cancelling/joining the old producer.
        assert!(!mailbox.publish(|update| update.select(1, "new session".into())));
        let update = mailbox.take(true).unwrap();
        assert!(update.frame.is_none());
        assert!(update.clear_frame);
        assert_eq!(update.selected, Some((1, "new session".into())));
    }

    #[test]
    fn full_command_queue_still_delivers_latest_resize_and_ready() {
        let (sender, receiver) = mpsc::sync_channel(1);
        let mut pending = Pending::default();
        sender.try_send(Command::Wake).unwrap();
        pending.size = Some((640, 400));
        assert!(matches!(
            sender.try_send(Command::Wake),
            Err(mpsc::TrySendError::Full(_))
        ));
        pending.size = Some((800, 600));
        pending.ready = Some((9, 18));
        assert!(matches!(
            sender.try_send(Command::Wake),
            Err(mpsc::TrySendError::Full(_))
        ));
        assert!(matches!(receiver.recv().unwrap(), Command::Wake));
        assert_eq!(pending.size.take(), Some((800, 600)));
        assert_eq!(pending.ready.take(), Some((9, 18)));
        // A publication after the receiver consumed its facts supplies a new wake.
        pending.size = Some((900, 700));
        sender.try_send(Command::Wake).unwrap();
        assert!(matches!(receiver.recv().unwrap(), Command::Wake));
        assert_eq!(pending.size.take(), Some((900, 700)));
    }

    #[test]
    fn unchanged_frames_are_not_resubmitted() {
        let mut previous = None;
        let mut pixels = vec![23u8; 4 * 8 * 6];
        let displayed = changed_frame(&mut previous, &pixels, 8, 6).unwrap();
        assert!(changed_frame(&mut previous, &pixels, 8, 6).is_none());
        pixels[0] = 42; // Includes cursor-only changes.
        assert!(changed_frame(&mut previous, &pixels, 8, 6).is_some());
        assert_eq!(displayed.as_bytes()[0], 23); // Old UI image is immutable.
        assert!(changed_frame(&mut previous, &pixels, 6, 8).is_some());
        previous = None; // Selecting another session must present its first frame.
        assert!(changed_frame(&mut previous, &pixels, 6, 8).is_some());
    }

    #[test]
    fn frame_handoff_owns_pixels_across_threads() {
        let mut source = vec![23u8; 4 * 8 * 6];
        let frame = SharedPixelBuffer::<Rgba8Pixel>::clone_from_slice(&source, 8, 6);
        source.fill(0); // The native surface may be reused after the copy.
        let frame = std::thread::spawn(move || frame).join().unwrap();
        assert_eq!(frame.width(), 8);
        assert_eq!(frame.height(), 6);
        assert!(frame.as_bytes().iter().all(|&byte| byte == 23));
    }

    // Isolates the host handoff, not rendering or end-to-end terminal latency.
    #[test]
    #[ignore = "manual frame-copy benchmark"]
    fn frame_handoff_cost() {
        use std::{hint::black_box, time::Instant};
        for (width, height) in [(640, 400), (1600, 900), (2048, 2048)] {
            let source = vec![23u8; width as usize * height as usize * 4];
            let iterations = 200;
            let start = Instant::now();
            for _ in 0..iterations {
                let intermediate = black_box(&source).to_vec();
                black_box(SharedPixelBuffer::<Rgba8Pixel>::clone_from_slice(
                    &intermediate,
                    width,
                    height,
                ));
            }
            let old = start.elapsed();
            let start = Instant::now();
            for _ in 0..iterations {
                black_box(SharedPixelBuffer::<Rgba8Pixel>::clone_from_slice(
                    black_box(&source),
                    width,
                    height,
                ));
            }
            let new = start.elapsed();
            println!(
                "{width}x{height}: two copies {:?}/frame; one copy {:?}/frame",
                old / iterations,
                new / iterations
            );
        }
    }
}
