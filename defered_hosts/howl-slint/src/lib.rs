#[cfg(all(feature = "gpu", target_os = "linux"))]
mod frame;
#[cfg(all(feature = "gpu", target_os = "linux"))]
mod gpu;
mod input;
#[cfg(target_os = "ios")]
mod ios;
mod sessions;
mod settings;

use slint::ComponentHandle;

slint::include_modules!();

pub fn run() -> Result<(), slint::PlatformError> {
    #[cfg(all(feature = "gpu", target_os = "linux"))]
    let context = if gpu::enabled() {
        Some(gpu::initialize().map_err(|error| slint::PlatformError::Other(error.to_string()))?)
    } else {
        None
    };
    let app = App::new()?;
    #[cfg(target_os = "ios")]
    ios::configure_fonts(&app).map_err(slint::PlatformError::Other)?;
    #[cfg(target_os = "ios")]
    let settings_path = ios::settings_path();
    #[cfg(not(target_os = "ios"))]
    let settings_path = settings::desktop_path();
    run_window(
        app,
        settings_path,
        #[cfg(all(feature = "gpu", target_os = "linux"))]
        context.as_ref(),
    )
}

fn run_window(
    app: App,
    settings_path: Result<std::path::PathBuf, String>,
    #[cfg(all(feature = "gpu", target_os = "linux"))] context: Option<&gpu::Context>,
) -> Result<(), slint::PlatformError> {
    let sessions = std::rc::Rc::new(sessions::Sessions::attach_presenter(
        &app,
        #[cfg(all(feature = "gpu", target_os = "linux"))]
        context.and_then(|context| gpu::attach(context, &app)),
    ));
    let profile_sessions = sessions.clone();
    settings::attach(&app, settings_path, move |profiles| {
        profile_sessions.refresh_profiles(profiles);
    });
    #[cfg(target_os = "ios")]
    let _lifecycle = ios::Lifecycle::attach(&app);
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

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;
    use std::{cell::Cell, rc::Rc, time::Duration};

    // Native live tests prove cell geometry. This proves the real App allocates
    // that viewport and places its physical raster at the top-left, unscaled.
    #[test]
    #[ignore = "requires private compositor"]
    fn terminal_fills_allocated_viewport() {
        let app = App::new().unwrap();
        app.set_show_sessions(false);
        let requested = Rc::new(Cell::new((0, 0)));
        let observed = requested.clone();
        let weak = app.as_weak();
        app.on_terminal_resize(move |width, height, _| {
            observed.set((width, height));
            if width < 10 || height < 20 {
                return;
            }
            let mut pixels = slint::SharedPixelBuffer::<slint::Rgba8Pixel>::new(
                (width as u32 / 10) * 10,
                (height as u32 / 20) * 20,
            );
            pixels.make_mut_slice().fill(slint::Rgba8Pixel {
                r: 181,
                g: 41,
                b: 121,
                a: 255,
            });
            weak.upgrade()
                .unwrap()
                .set_terminal_frame(slint::Image::from_rgba8(pixels));
        });
        app.set_terminal_enabled(true);
        let sizes = [(3448, 1078), (1300, 2200), (640, 480), (3448, 1078)];
        app.window()
            .set_size(slint::PhysicalSize::new(sizes[0].0, sizes[0].1));
        let passed = Rc::new(Cell::new(0));
        let completed = passed.clone();
        let weak = app.as_weak();
        let mut retries = 0;
        let timer = slint::Timer::default();
        timer.start(slint::TimerMode::Repeated, Duration::from_millis(100), move || {
            let app = weak.upgrade().unwrap();
            let (width, height) = sizes[completed.get()];
            retries += 1;
            assert!(retries < 50, "viewport resize did not settle");
            let Ok(snapshot) = app.window().take_snapshot() else {
                return;
            };
            if snapshot.width() != width || snapshot.height() != height {
                app.window().set_size(slint::PhysicalSize::new(width, height));
                return;
            }
            let (viewport_width, viewport_height) = requested.get();
            assert_eq!(viewport_width as u32, width);
            assert!(viewport_height > 0 && viewport_height < height as i32);
            let raster = app.get_terminal_frame().size();
            assert_eq!(raster.width, width / 10 * 10);
            assert_eq!(raster.height, viewport_height as u32 / 20 * 20);
            let mut bounds = None;
            for (y, row) in snapshot.as_slice().chunks(width as usize).enumerate() {
                for (x, pixel) in row.iter().enumerate() {
                    if (pixel.r, pixel.g, pixel.b) == (181, 41, 121) {
                        let b = bounds.get_or_insert((x, y, x, y, 0usize));
                        b.2 = b.2.max(x);
                        b.3 = y;
                        b.4 += 1;
                    }
                }
            }
            let Some((left, top, right, bottom, count)) = bounds else { return };
            assert_eq!(left, 0, "terminal raster is horizontally centered");
            assert!(top > 0); // The tab bar is immediately above the viewport.
            let above = snapshot.as_slice()[(top - 1) * width as usize];
            let background = app.get_style().palette.terminal;
            assert_ne!(
                (above.r, above.g, above.b),
                (background.red(), background.green(), background.blue()),
                "terminal raster is vertically centered"
            );
            assert_eq!(right + 1, raster.width as usize);
            assert_eq!(bottom - top + 1, raster.height as usize);
            assert_eq!(count, raster.width as usize * raster.height as usize);
            println!("VIEWPORT_PASS window={width}x{height} viewport={viewport_width}x{viewport_height} raster={}x{} origin={left},{top}", raster.width, raster.height);
            completed.set(completed.get() + 1);
            retries = 0;
            if completed.get() == sizes.len() {
                slint::quit_event_loop().unwrap();
            } else {
                let next = sizes[completed.get()];
                app.window().set_size(slint::PhysicalSize::new(next.0, next.1));
            }
        });
        app.run().unwrap();
        timer.stop();
        assert_eq!(passed.get(), sizes.len());
    }
}
