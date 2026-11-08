//! Server owns the PTY. One command owner services input/geometry; one observer
//! blocks for snapshots and renders. Both sleep on work, never a polling timer.
use crate::{
    App, ServerProfile, SessionRow,
    input::{Key, key, resolve_font},
    settings::Profile,
};
use slint::{ComponentHandle, Model, Rgba8Pixel, SharedPixelBuffer};
use std::{
    cell::{Cell, RefCell},
    collections::HashMap,
    ffi::{CString, c_char, c_void},
    rc::Rc,
    sync::{
        Arc, Condvar, Mutex,
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
// Immutable selection snapshot: later profile edits cannot retarget live I/O.
struct Target {
    endpoint: CString,
    entry: Entry,
}
#[derive(Clone)]
struct Fonts {
    patterns: [String; 4],
    fallbacks: Vec<String>,
    size: u16,
}

// Style font sizes are logical; Howl rasterizes in integer physical pixels.
fn raster_font_size(logical: f32, scale: f32) -> u16 {
    (logical * scale).round().clamp(1.0, u16::MAX as f32) as u16
}

#[derive(Default)]
struct Update {
    frame: Option<SharedPixelBuffer<Rgba8Pixel>>,
    selected: Option<String>,
    status: Option<String>,
    clear_frame: bool,
    finished: bool,
}
impl Update {
    fn select(&mut self, name: String) {
        self.frame = None;
        self.clear_frame = true;
        self.selected = Some(name);
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
    if update.clear_frame {
        app.set_terminal_frame(slint::Image::default());
    }
    if let Some(title) = update.selected {
        app.set_server_connecting(false);
        app.set_server_connected(true);
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
        app.set_connection_detail("Disconnected".into());
    }
}

// Resize and Ready are coalesced facts. Wake is only a notification: if the
// bounded command queue is full, its receiver is already guaranteed work.
#[derive(Default)]
struct Pending {
    size: Option<(u32, u32)>,
    font_pixels: Option<u16>,
    ready: Option<(u16, u16)>,
    ended: Option<Result<(), String>>,
}
enum Command {
    Rebuild,
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
// A fresh renderer waits for the action lane to acknowledge its geometry.
// Cancellation releases this wait too, before joining the observer.
#[derive(Default)]
struct FirstGeometry {
    result: Mutex<Option<bool>>,
    changed: Condvar,
}
impl FirstGeometry {
    fn finish(&self, ready: bool) {
        let mut result = self.result.lock().unwrap();
        if result.is_none() {
            *result = Some(ready);
            self.changed.notify_one();
        }
    }
    fn wait(&self) -> bool {
        let result = self.result.lock().unwrap();
        self.changed
            .wait_while(result, |value| value.is_none())
            .unwrap()
            .unwrap()
    }
}
struct ObserverStartup {
    interrupt: Arc<Interrupt>,
    geometry: Arc<FirstGeometry>,
}
struct Observer {
    geometry: Arc<FirstGeometry>,
    interrupt: Arc<Interrupt>,
    worker: Option<JoinHandle<()>>,
}
impl Drop for Observer {
    fn drop(&mut self) {
        self.geometry.finish(false);
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
// Catalogs are short-lived discoveries, not terminal connections. Sixteen saved
// profiles bound concurrent discovery, native handles and queued completions.
struct Catalog {
    profile: Profile,
    generation: u64,
    entries: Vec<Entry>,
    status: String,
}
struct Discovery {
    interrupt: Arc<Interrupt>,
    worker: Option<JoinHandle<()>>,
}
impl Drop for Discovery {
    fn drop(&mut self) {
        self.interrupt.cancel();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}
struct Catalogs {
    app: slint::Weak<App>,
    rows: Arc<Mutex<Vec<Catalog>>>,
    jobs: RefCell<HashMap<u32, Discovery>>,
    generation: Cell<u64>,
}
impl Catalogs {
    fn refresh(&self, id: u32) {
        self.jobs.borrow_mut().remove(&id);
        let generation = self
            .generation
            .get()
            .checked_add(1)
            .expect("catalog generation exhausted");
        self.generation.set(generation);
        let endpoint = {
            let mut rows = self.rows.lock().unwrap();
            let Some(row) = rows
                .iter_mut()
                .find(|row| row.profile.id == id && row.profile.visible)
            else {
                return;
            };
            row.generation = generation;
            row.status = "Connecting…".into();
            row.entries.clear();
            CString::new(row.profile.endpoint.clone())
        };
        let result = endpoint
            .map_err(|_| "Invalid endpoint".to_string())
            .and_then(|endpoint| Interrupt::new().map(|interrupt| (endpoint, Arc::new(interrupt))));
        let (endpoint, interrupt) = match result {
            Ok(value) => value,
            Err(error) => {
                accept_catalog(&mut self.rows.lock().unwrap(), id, generation, Err(error));
                self.publish();
                return;
            }
        };
        self.publish();
        let rows = self.rows.clone();
        let app = self.app.clone();
        let owner = interrupt.clone();
        let worker = thread::spawn(move || {
            let result = catalog(&endpoint, &owner);
            if !accept_catalog(&mut rows.lock().unwrap(), id, generation, result) {
                return;
            }
            let _ =
                app.upgrade_in_event_loop(move |app| publish_catalogs(&app, &rows.lock().unwrap()));
        });
        self.jobs.borrow_mut().insert(
            id,
            Discovery {
                interrupt,
                worker: Some(worker),
            },
        );
    }
    fn publish(&self) {
        if let Some(app) = self.app.upgrade() {
            publish_catalogs(&app, &self.rows.lock().unwrap());
        }
    }
    fn synchronize(&self, profiles: &[Profile]) {
        if profiles.len() > 16 {
            return;
        } // Settings validates this bound too.
        let cancelled = {
            let rows = self.rows.lock().unwrap();
            rows.iter()
                .filter(|row| {
                    !profiles.iter().any(|profile| {
                        profile.id == row.profile.id
                            && profile.endpoint == row.profile.endpoint
                            && profile.visible == row.profile.visible
                    })
                })
                .map(|row| row.profile.id)
                .collect::<Vec<_>>()
        };
        // Never join under the result lock: a cancelled discovery may be
        // completing its final result. Unchanged discoveries keep running.
        for id in cancelled {
            self.jobs.borrow_mut().remove(&id);
        }
        // Keep the same lock throughout replacement. An unchanged completion
        // must see either complete old rows or complete new rows, never a gap.
        let refresh = replace_profiles(&mut self.rows.lock().unwrap(), profiles);
        self.publish();
        for id in refresh {
            self.refresh(id);
        }
    }
}
fn replace_profiles(rows: &mut Vec<Catalog>, profiles: &[Profile]) -> Vec<u32> {
    let mut old = std::mem::take(rows);
    let mut refresh = Vec::new();
    for profile in profiles {
        let previous = old
            .iter()
            .position(|row| row.profile.id == profile.id)
            .map(|i| old.remove(i));
        if let Some(mut row) = previous.filter(|row| {
            row.profile.endpoint == profile.endpoint && row.profile.visible == profile.visible
        }) {
            row.profile = profile.clone();
            rows.push(row);
        } else {
            rows.push(Catalog {
                profile: profile.clone(),
                generation: 0,
                entries: Vec::new(),
                status: String::new(),
            });
            if profile.visible {
                refresh.push(profile.id);
            }
        }
    }
    refresh
}
fn accept_catalog(
    rows: &mut [Catalog],
    id: u32,
    generation: u64,
    result: Result<Vec<Entry>, String>,
) -> bool {
    let Some(row) = rows
        .iter_mut()
        .find(|row| row.profile.id == id && row.profile.visible && row.generation == generation)
    else {
        return false;
    };
    match result {
        Ok(entries) => {
            row.status = if entries.is_empty() {
                "No running sessions".into()
            } else {
                format!("{} sessions", entries.len())
            };
            row.entries = entries;
        }
        Err(error) => {
            row.status = error;
            row.entries.clear();
        }
    }
    true
}
fn publish_catalogs(app: &App, rows: &[Catalog]) {
    app.set_servers(slint::ModelRc::new(slint::VecModel::from(
        rows.iter()
            .map(|row| ServerProfile {
                id: row.profile.id.to_string().into(),
                name: row.profile.name.clone().into(),
                endpoint: row.profile.endpoint.clone().into(),
                visible: row.profile.visible,
                status: row.status.clone().into(),
                sessions: slint::ModelRc::new(slint::VecModel::from(
                    row.entries
                        .iter()
                        .map(|entry| SessionRow {
                            server_id: entry.server.to_string().into(),
                            session_id: entry.session.to_string().into(),
                            instance_id: entry.instance.to_string().into(),
                            title: entry.name.clone().into(),
                        })
                        .collect::<Vec<_>>(),
                )),
            })
            .collect::<Vec<_>>(),
    )));
}
pub struct Sessions {
    connection: Rc<RefCell<Option<Connection>>>,
    catalogs: Rc<Catalogs>,
}
impl Drop for Sessions {
    fn drop(&mut self) {
        self.connection.borrow_mut().take();
        self.catalogs.jobs.borrow_mut().clear();
    }
}
impl Sessions {
    pub fn refresh_profiles(&self, profiles: &[Profile]) {
        self.catalogs.synchronize(profiles);
    }
    pub fn attach(app: &App) -> Self {
        let connection = Rc::new(RefCell::new(None::<Connection>));
        let catalogs = Rc::new(Catalogs {
            app: app.as_weak(),
            rows: Arc::new(Mutex::new(Vec::new())),
            jobs: RefCell::new(HashMap::new()),
            generation: Cell::new(0),
        });
        reset_view(app);
        app.set_terminal_status("Show a Server, then choose a session".into());
        let owner = catalogs.clone();
        app.on_refresh_server(move |id| {
            if let Ok(id) = id.parse() {
                owner.refresh(id);
            }
        });
        let slot = connection.clone();
        let rows = catalogs.rows.clone();
        let weak = app.as_weak();
        app.on_select_instance(move |profile_id, server_id, session_id, instance_id| {
            let Some(app) = weak.upgrade() else { return };
            let (Ok(id), Ok(server), Ok(session), Ok(instance)) = (
                profile_id.parse::<u32>(),
                server_id.parse::<u64>(),
                session_id.parse::<u64>(),
                instance_id.parse::<u64>(),
            ) else {
                return;
            };
            let target = {
                let rows = rows.lock().unwrap();
                rows.iter()
                    .find(|row| row.profile.id == id && row.profile.visible)
                    .and_then(|row| {
                        row.entries
                            .iter()
                            .find(|entry| {
                                entry.server == server
                                    && entry.session == session
                                    && entry.instance == instance
                            })
                            .map(|entry| {
                                (
                                    row.profile.endpoint.clone(),
                                    row.profile.name.clone(),
                                    entry.clone(),
                                )
                            })
                    })
            };
            let Some((endpoint, profile_name, entry)) = target else {
                return;
            };
            let Ok(endpoint) = CString::new(endpoint) else {
                return;
            };
            // Profile mutations affect discovery only. This connection owns its
            // exact endpoint and remote identities until explicit replacement.
            slot.borrow_mut().take();
            reset_view(&app);
            app.set_selected_profile_id(profile_id);
            app.set_selected_server_id(server_id);
            app.set_selected_session_id(session_id);
            app.set_selected_instance_id(instance_id);
            app.set_connection_detail(profile_name.into());
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
                size: raster_font_size(app.get_terminal_font_size(), app.window().scale_factor()),
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
            let worker = thread::spawn(move || {
                run(
                    Target { endpoint, entry },
                    owner,
                    receiver,
                    wake,
                    facts,
                    updates,
                    fonts,
                )
            });
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
        app.on_terminal_key(move |event, released| {
            if let Some(key) = key(event, released) {
                send(&slot, Command::Key(key), &weak);
            }
        });
        let slot = connection.clone();
        app.on_terminal_resize(move |w, h, pixels| {
            if let Some(connection) = slot.borrow().as_ref() {
                {
                    let mut pending = connection.pending.lock().unwrap();
                    pending.size = Some((w.max(0) as u32, h.max(0) as u32));
                    pending.font_pixels = Some(pixels.clamp(1, u16::MAX as i32) as u16);
                }
                let _ = connection.sender.try_send(Command::Wake);
            }
        });
        Self {
            connection,
            catalogs,
        }
    }
}
fn reset_view(app: &App) {
    app.set_server_connected(false);
    app.set_server_connecting(false);
    app.set_terminal_enabled(false);
    app.set_terminal_frame(slint::Image::default());
    app.set_selected_profile_id("".into());
    app.set_selected_server_id("".into());
    app.set_selected_session_id("".into());
    app.set_selected_instance_id("".into());
    app.set_selected_title("No session selected".into());
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
    target: Target,
    cancellation: Arc<Cancellation>,
    receiver: Receiver<Command>,
    sender: SyncSender<Command>,
    pending: Arc<Mutex<Pending>>,
    view: View,
    mut fonts: Fonts,
) {
    let Target { endpoint, entry } = target;
    let result = (|| -> Result<(), String> {
        let mut observer = None::<Observer>;
        let mut actions = None::<Actions>;
        let mut last_size = None;
        let mut cell = None;
        // DPI changes replace only the observer/font owner. The action lane
        // and remote shell remain alive; a normal resize publishes new geometry.
        let mut rebuild = true;
        loop {
            let command = if rebuild {
                rebuild = false;
                Command::Rebuild
            } else {
                let Ok(command) = receiver.recv() else { break };
                command
            };
            if cancellation.stopping.load(Ordering::Acquire) {
                break;
            }
            match command {
                Command::Stop => break,
                Command::Rebuild => {
                    // Join the old renderer before a font/DPI rebuild. The exact
                    // selected target and action connection remain unchanged.
                    observer.take();
                    cancellation.observer.lock().unwrap().take();
                    {
                        let mut facts = pending.lock().unwrap();
                        facts.ready = None;
                        facts.ended = None;
                    }
                    cell = None;
                    view.publish(|update| update.select(entry.name.clone()));
                    if actions.is_none() {
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
                    }
                    let interrupt = Arc::new(Interrupt::new()?);
                    cancellation.install_observer(interrupt.clone())?;
                    let owner = interrupt.clone();
                    let target = entry.clone();
                    let address = endpoint.clone();
                    let fonts = fonts.clone();
                    let facts = pending.clone();
                    let wake = sender.clone();
                    let updates = view.clone();
                    let geometry = Arc::new(FirstGeometry::default());
                    let first = geometry.clone();
                    let worker = thread::spawn(move || {
                        observe(
                            address,
                            target,
                            ObserverStartup {
                                interrupt: owner,
                                geometry: first,
                            },
                            fonts,
                            facts,
                            wake,
                            updates,
                        )
                    });
                    observer = Some(Observer {
                        geometry,
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
                Command::Wake => {}
            }
            let (size, font_pixels, ready, ended) = {
                let mut facts = pending.lock().unwrap();
                (
                    facts.size.take(),
                    facts.font_pixels.take(),
                    facts.ready.take(),
                    facts.ended.take(),
                )
            };
            if let Some(pixels) = font_pixels
                && pixels != fonts.size
            {
                fonts.size = pixels;
                rebuild = true;
            }
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
            } else if !rebuild
                && resized
                && let (Some(actions), Some((width, height)), Some((cell_width, cell_height))) =
                    (actions.as_ref(), last_size, cell)
            {
                check(unsafe {
                    remote_actions_resize(actions.0, width, height, cell_width, cell_height)
                })?;
                if width >= u32::from(cell_width)
                    && height >= u32::from(cell_height)
                    && let Some(observer) = observer.as_ref()
                {
                    observer.geometry.finish(true);
                }
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
    startup: ObserverStartup,
    fonts: Fonts,
    pending: Arc<Mutex<Pending>>,
    sender: SyncSender<Command>,
    view: View,
) {
    let ObserverStartup {
        interrupt,
        geometry: first_geometry,
    } = startup;
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
        if !first_geometry.wait() {
            return Ok(());
        }
        let mut previous = None;
        // Resize acknowledgment precedes the first observe request.
        loop {
            let (mut pixels, mut width, mut height, mut exited) = (std::ptr::null(), 0, 0, 0);
            check(unsafe {
                remote_step(client.0, &mut pixels, &mut width, &mut height, &mut exited)
            })?;
            if !pixels.is_null() {
                if width == 0 || height == 0 || width > 4096 || height > 4096 {
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

    fn profile(id: u32, visible: bool) -> Profile {
        Profile {
            id,
            name: format!("Server {id}"),
            endpoint: "tcp://127.0.0.1:43180".into(),
            visible,
        }
    }
    fn entry(server: u64) -> Entry {
        Entry {
            name: "shell".into(),
            server,
            session: 1,
            instance: 1,
        }
    }
    #[test]
    fn unchanged_discovery_completion_survives_profile_replacement_in_either_order() {
        for complete_before in [true, false] {
            let mut rows = vec![Catalog {
                profile: profile(7, true),
                generation: 4,
                entries: vec![],
                status: "Connecting…".into(),
            }];
            if complete_before {
                assert!(accept_catalog(&mut rows, 7, 4, Ok(vec![entry(9)])));
            }
            let mut renamed = profile(7, true);
            renamed.name = "Renamed".into();
            assert!(replace_profiles(&mut rows, &[renamed]).is_empty());
            if !complete_before {
                assert!(accept_catalog(&mut rows, 7, 4, Ok(vec![entry(9)])));
            }
            assert_eq!(rows[0].entries[0].server, 9);
            assert_eq!(rows[0].profile.name, "Renamed");
            assert_ne!(rows[0].status, "Connecting…");
        }
    }

    #[test]
    fn catalog_completion_requires_exact_visible_profile_generation() {
        let mut rows = vec![Catalog {
            profile: profile(7, true),
            generation: 3,
            entries: vec![],
            status: String::new(),
        }];
        assert!(!accept_catalog(&mut rows, 8, 3, Ok(vec![entry(9)])));
        assert!(!accept_catalog(&mut rows, 7, 2, Ok(vec![entry(9)])));
        assert!(accept_catalog(&mut rows, 7, 3, Ok(vec![entry(u64::MAX)])));
        assert_eq!(rows[0].entries[0].server, u64::MAX);
        rows[0].profile.visible = false;
        assert!(!accept_catalog(&mut rows, 7, 3, Err("late failure".into())));
        assert_eq!(rows[0].entries.len(), 1);
        rows.clear();
        assert!(!accept_catalog(&mut rows, 7, 3, Ok(vec![entry(9)])));
    }
    #[test]
    fn one_catalog_failure_cannot_clear_another_server() {
        let mut rows = vec![
            Catalog {
                profile: profile(1, true),
                generation: 1,
                entries: vec![entry(10)],
                status: String::new(),
            },
            Catalog {
                profile: profile(2, true),
                generation: 2,
                entries: vec![entry(20)],
                status: String::new(),
            },
        ];
        assert!(accept_catalog(&mut rows, 1, 1, Err("unavailable".into())));
        assert!(rows[0].entries.is_empty());
        assert_eq!(rows[1].entries[0].server, 20);
    }

    #[test]
    fn first_geometry_wait_is_released_by_ack_or_cancellation() {
        for ready in [true, false] {
            let first = Arc::new(FirstGeometry::default());
            let waiter = first.clone();
            let worker = std::thread::spawn(move || waiter.wait());
            first.finish(ready);
            assert_eq!(worker.join().unwrap(), ready);
            first.finish(!ready); // Once settled, later cleanup cannot change it.
            assert_eq!(first.wait(), ready);
        }
    }

    #[test]
    fn dropping_observer_before_resize_ack_cancels_pending_wait() {
        let geometry = Arc::new(FirstGeometry::default());
        let waiting = geometry.clone();
        let (sent, received) = mpsc::channel();
        let observer = Observer {
            geometry,
            interrupt: Arc::new(Interrupt::new().unwrap()),
            worker: Some(std::thread::spawn(move || {
                sent.send(waiting.wait()).unwrap();
            })),
        };
        // Selection replacement, connection close, and resize-error unwind all
        // take this same Drop path, even before any resize succeeds.
        drop(observer);
        assert!(!received.recv().unwrap());
    }

    #[test]
    fn logical_font_preference_maps_to_physical_pixels() {
        assert_eq!(raster_font_size(18.0, 1.0), 18);
        assert_eq!(raster_font_size(18.0, 2.0), 36);
        assert_eq!(raster_font_size(18.0, 3.5), 63);
        assert_eq!(raster_font_size(17.0, 1.5), 26); // Expected pixel quantization.
        assert_eq!(raster_font_size(0.0, 2.0), 1);
    }

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
            update.selected = Some("old session".into());
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
        assert!(!mailbox.publish(|update| update.select("new session".into())));
        let update = mailbox.take(true).unwrap();
        assert!(update.frame.is_none());
        assert!(update.clear_frame);
        assert_eq!(update.selected, Some("new session".into()));
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

    // Supply two distinct live Servers containing a disposable, idle shell named
    // multi-server-qualification. This exercises the actual App callbacks and
    // native owners without requiring a visible window or touching saved profiles.
    #[test]
    #[ignore = "requires HOWL_TEST_SERVER_A/B and a headless Slint backend"]
    fn live_multi_server_catalog_and_active_ownership() {
        use std::time::{Duration, Instant};
        fn wait(mut ready: impl FnMut() -> bool) {
            let start = Instant::now();
            while !ready() {
                assert!(
                    start.elapsed() < Duration::from_secs(8),
                    "live owner did not settle"
                );
                thread::sleep(Duration::from_millis(10));
            }
        }
        let app = App::new().unwrap();
        let sessions = Sessions::attach(&app);
        let mut profiles = vec![
            Profile {
                id: 1,
                name: "A".into(),
                endpoint: std::env::var("HOWL_TEST_SERVER_A").unwrap(),
                visible: true,
            },
            Profile {
                id: 2,
                name: "B".into(),
                endpoint: std::env::var("HOWL_TEST_SERVER_B").unwrap(),
                visible: true,
            },
        ];
        let endpoints: Vec<_> = profiles.iter().map(|p| p.endpoint.clone()).collect();
        sessions.refresh_profiles(&profiles);
        wait(|| {
            sessions
                .catalogs
                .rows
                .lock()
                .unwrap()
                .iter()
                .all(|r| !r.entries.is_empty())
        });
        let entries: Vec<Entry> = sessions
            .catalogs
            .rows
            .lock()
            .unwrap()
            .iter()
            .map(|r| {
                r.entries
                    .iter()
                    .find(|e| e.name.contains("multi-server-qualification"))
                    .unwrap()
                    .clone()
            })
            .collect();
        assert_ne!(entries[0].server, entries[1].server);
        println!(
            "live Servers: {} and {}",
            entries[0].server, entries[1].server
        );
        let select = |profile: u32, e: &Entry| {
            app.invoke_select_instance(
                profile.to_string().into(),
                e.server.to_string().into(),
                e.session.to_string().into(),
                e.instance.to_string().into(),
            );
            app.invoke_terminal_resize(640, 400, 18);
            wait(|| {
                sessions
                    .connection
                    .borrow()
                    .as_ref()
                    .is_some_and(|c| c.view.mailbox.lock().unwrap().update.frame.is_some())
            });
            assert_eq!(app.get_selected_server_id().as_str(), e.server.to_string());
            assert_eq!(
                app.get_selected_session_id().as_str(),
                e.session.to_string()
            );
        };
        select(1, &entries[0]);
        select(2, &entries[1]);
        let active = sessions
            .connection
            .borrow()
            .as_ref()
            .unwrap()
            .view
            .active
            .clone();
        let same_owner = || {
            let connection = sessions.connection.borrow();
            let c = connection
                .as_ref()
                .expect("catalog mutation dropped active terminal");
            assert!(Arc::ptr_eq(&active, &c.view.active));
            assert!(active.load(Ordering::Acquire));
            assert!(!c.worker.as_ref().unwrap().is_finished());
        };

        // Wrong Server identity cannot select a same-number Session elsewhere.
        app.invoke_select_instance(
            "1".into(),
            entries[1].server.to_string().into(),
            entries[0].session.to_string().into(),
            entries[0].instance.to_string().into(),
        );
        same_owner();
        profiles[1].visible = false;
        sessions.refresh_profiles(&profiles);
        same_owner();
        profiles[1].endpoint = "unix:/nonexistent/howl-test-missing.sock".into();
        profiles[1].visible = true;
        sessions.refresh_profiles(&profiles);
        wait(|| sessions.catalogs.rows.lock().unwrap()[1].status != "Connecting…");
        same_owner();
        assert!(!sessions.catalogs.rows.lock().unwrap()[0].entries.is_empty());
        assert!(sessions.catalogs.rows.lock().unwrap()[1].entries.is_empty());
        profiles.remove(1);
        sessions.refresh_profiles(&profiles);
        same_owner();
        {
            let mut rows = sessions.catalogs.rows.lock().unwrap();
            let generation = rows[0].generation;
            assert!(!accept_catalog(
                &mut rows,
                1,
                generation + 1,
                Err("stale".into())
            ));
            assert!(!rows[0].entries.is_empty());
        }
        // A fresh geometry observation proves the preserved owner still does
        // real I/O/rendering after hide, endpoint edit, failure and deletion.
        sessions
            .connection
            .borrow()
            .as_ref()
            .unwrap()
            .view
            .mailbox
            .lock()
            .unwrap()
            .update
            .frame = None;
        app.invoke_terminal_resize(720, 420, 18);
        wait(|| {
            sessions
                .connection
                .borrow()
                .as_ref()
                .unwrap()
                .view
                .mailbox
                .lock()
                .unwrap()
                .update
                .frame
                .is_some()
        });
        same_owner();
        app.invoke_disconnect_server();
        assert!(sessions.connection.borrow().is_none());
        for (endpoint, expected) in endpoints.iter().zip(entries.iter()) {
            let found = catalog(
                &CString::new(endpoint.as_str()).unwrap(),
                &Interrupt::new().unwrap(),
            )
            .unwrap();
            assert!(
                found
                    .iter()
                    .any(|e| e.server == expected.server && e.session == expected.session)
            );
        }
        println!(
            "PASS: independent real catalogs; exact selection; hide/edit/remove/failure preserve active native rendering; disconnect preserves remote session"
        );
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
