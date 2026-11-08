//! One explicit Server connection. Server keeps the PTY; this host owns only
//! cancellable client I/O, rendering and UI copies. No implicit reconnect/create.
use crate::{
    App,
    input::{Key, key, resolve_font},
};
use slint::{ComponentHandle, Model, Rgba8Pixel, SharedPixelBuffer, Timer, TimerMode};
use std::sync::atomic::{AtomicBool, Ordering};
use std::{
    cell::RefCell,
    ffi::{CString, c_char, c_void},
    rc::Rc,
    sync::{
        Arc, Mutex,
        mpsc::{self, Receiver, SyncSender},
    },
    thread::{self, JoinHandle},
    time::Duration,
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
    fn remote_key(client: *mut c_void, key: u8, scalar: u32, action: u8, mods: u8) -> u32;
    fn remote_resize(client: *mut c_void, width: u32, height: u32) -> u32;
    fn remote_step(
        client: *mut c_void,
        pixels: *mut *const u8,
        width: *mut u32,
        height: *mut u32,
        exited: *mut i32,
    ) -> u32;
    fn remote_close(client: *mut c_void) -> u32;
}

// This is the one native object allowed across threads: the published Client
// contract explicitly permits cancel concurrently with its borrowing calls.
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
#[derive(Clone)]
struct Entry {
    name: String,
    server: u64,
    session: u64,
    instance: u64,
}
#[derive(Default)]
struct Mailbox {
    frame: Option<SharedPixelBuffer<Rgba8Pixel>>,
    size: Option<(u32, u32)>,
    catalog: Option<Vec<Entry>>,
    selected: Option<(usize, String)>,
    status: Option<String>,
    finished: bool,
}
enum Command {
    Select(usize),
    Key(Key),
}
struct Fonts {
    patterns: [String; 4],
    fallbacks: Vec<String>,
    size: u16,
}
struct Connection {
    interrupt: Arc<Interrupt>,
    stopping: Arc<AtomicBool>,
    sender: SyncSender<Command>,
    worker: Option<JoinHandle<()>>,
    shared: Arc<Mutex<Mailbox>>,
}
impl Drop for Connection {
    fn drop(&mut self) {
        self.stopping.store(true, Ordering::Relaxed);
        self.interrupt.cancel();
        // Cancel wakes Client I/O. All handles/borrows are released by that owner
        // before the interrupt can be destroyed or another connection replaces it.
        if let Some(worker) = self.worker.take()
            && worker.join().is_err()
        {
            eprintln!("Server worker panicked");
        }
    }
}

pub struct Sessions {
    connection: Rc<RefCell<Option<Connection>>>,
    _timer: Timer,
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
        let weak = app.as_weak();
        let slot = connection.clone();
        app.on_connect_server(move |endpoint| {
            let Some(app) = weak.upgrade() else { return };
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
                Ok(interrupt) => Arc::new(interrupt),
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
            let shared = Arc::new(Mutex::new(Mailbox::default()));
            let (sender, receiver) = mpsc::sync_channel(64);
            let stopping = Arc::new(AtomicBool::new(false));
            let worker_stop = stopping.clone();
            let owner = interrupt.clone();
            let mailbox = shared.clone();
            let worker =
                thread::spawn(move || run(endpoint, owner, worker_stop, receiver, mailbox, fonts));
            *slot.borrow_mut() = Some(Connection {
                interrupt,
                stopping,
                sender,
                worker: Some(worker),
                shared,
            });
            app.set_server_connecting(true);
            app.set_terminal_status("Connecting…".into());
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
                connection.shared.lock().unwrap().size = Some((w.max(0) as u32, h.max(0) as u32));
            }
        });
        let slot = connection.clone();
        let weak = app.as_weak();
        let timer = Timer::default();
        timer.start(TimerMode::Repeated, Duration::from_millis(16), move || {
            let Some(app) = weak.upgrade() else { return };
            let connection = slot.borrow();
            let Some(connection) = connection.as_ref() else {
                return;
            };
            let (frame, catalog, selected, status, finished) = {
                let mut mailbox = connection.shared.lock().unwrap();
                (
                    mailbox.frame.take(),
                    mailbox.catalog.take(),
                    mailbox.selected.take(),
                    mailbox.status.take(),
                    std::mem::take(&mut mailbox.finished),
                )
            };
            if let Some(catalog) = catalog {
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
            if let Some((index, title)) = selected {
                app.set_selected_index(index as i32);
                app.set_selected_title(title.into());
                app.set_terminal_frame(slint::Image::default());
                app.set_terminal_enabled(true);
            }
            if let Some(frame) = frame {
                app.set_terminal_frame(slint::Image::from_rgba8(frame));
            }
            if let Some(status) = status {
                app.set_terminal_status(status.into());
            }
            if finished {
                app.set_server_connecting(false);
                app.set_server_connected(false);
                app.set_terminal_enabled(false);
                app.set_selected_index(-1);
                app.set_sessions(slint::ModelRc::new(slint::VecModel::from(Vec::<
                    slint::SharedString,
                >::new(
                ))));
                app.set_connection_detail("Disconnected".into());
            }
        });
        Self {
            connection,
            _timer: timer,
        }
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
fn run(
    endpoint: CString,
    interrupt: Arc<Interrupt>,
    stopping: Arc<AtomicBool>,
    receiver: Receiver<Command>,
    shared: Arc<Mutex<Mailbox>>,
    fonts: Fonts,
) {
    let result = (|| -> Result<(), String> {
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
        {
            let mut mailbox = shared.lock().unwrap();
            mailbox.catalog = Some(entries.clone());
            mailbox.status = Some(
                if entries.is_empty() {
                    "Server has no terminal instances"
                } else {
                    "Choose a session to attach"
                }
                .into(),
            );
        }
        let mut attached = false;
        let mut last_size = None;
        let mut resize_pending = false;
        while !stopping.load(Ordering::Relaxed) {
            let first = match receiver.recv_timeout(Duration::from_millis(16)) {
                Ok(command) => Some(command),
                Err(mpsc::RecvTimeoutError::Timeout) => None,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            };
            for command in first.into_iter().chain(receiver.try_iter()).take(64) {
                match command {
                    Command::Select(index) => {
                        let Some(entry) = entries.get(index) else {
                            continue;
                        };
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
                                let pattern =
                                    std::env::var(variable).unwrap_or_else(|_| pattern.clone());
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
                        attached = true;
                        resize_pending = true;
                        let mut mailbox = shared.lock().unwrap();
                        mailbox.selected = Some((index, entry.name.clone()));
                        mailbox.status = Some("Connected".into());
                    }
                    Command::Key(key) if attached => {
                        check(unsafe {
                            remote_key(client.0, key.named, key.scalar, key.action, key.modifiers)
                        })?;
                    }
                    _ => {}
                }
            }
            // The stop flag covers idle catalogs; Interrupt covers blocked I/O.
            if !attached {
                continue;
            }
            if let Some(size) = shared.lock().unwrap().size.take() {
                last_size = Some(size);
                resize_pending = true;
            }
            if resize_pending && let Some((w, h)) = last_size {
                check(unsafe { remote_resize(client.0, w, h) })?;
                resize_pending = false;
            }
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
                // Copy the native borrow once, on its owning worker. The UI moves
                // this shared pixel buffer into Image without another full copy.
                shared.lock().unwrap().frame =
                    Some(SharedPixelBuffer::clone_from_slice(pixels, width, height));
            }
            if exited != 0 {
                // Retain its final frame without polling a dead shell forever.
                attached = false;
                shared.lock().unwrap().status = Some("Remote shell exited".into());
            }
        }
        Ok(())
    })();
    let mut mailbox = shared.lock().unwrap();
    if let Err(error) = result {
        mailbox.status = Some(error);
    }
    mailbox.finished = true;
}

#[cfg(test)]
mod tests {
    use super::*;

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
