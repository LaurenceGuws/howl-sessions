//! Reproduces wgpu-core's TLS destruction ordering without a Slint window.
#[cfg(target_os = "linux")]
mod linux {
    use slint::wgpu_30::wgpu;
    use std::cell::RefCell;
    thread_local! { static OWNER: RefCell<Option<(wgpu::Device, wgpu::Queue)>> = const { RefCell::new(None) }; }
    pub fn run() {
        std::thread::spawn(|| {
            let instance =
                wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle());
            let adapter =
                pollster::block_on(instance.request_adapter(&Default::default())).unwrap();
            let (device, queue) =
                pollster::block_on(adapter.request_device(&Default::default())).unwrap();
            OWNER.with(|owner| *owner.borrow_mut() = Some((device.clone(), queue.clone())));
            queue.submit(std::iter::empty());
            device.poll(wgpu::PollType::Poll).unwrap();
            eprintln!("TLS_REPRO_BODY_DONE");
        })
        .join()
        .unwrap();
        eprintln!("TLS_REPRO_CLEAN_EXIT");
    }
}
#[cfg(target_os = "linux")]
fn main() {
    linux::run();
}
#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("The Howl WGPU regression is qualified on Linux only.");
}
