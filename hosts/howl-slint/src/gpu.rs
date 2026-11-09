//! Linux opt-in presentation using one host-created device/queue shared with Slint.
//! Only UI callbacks call `present` or submit work. The observer copies canonical
//! frames into a bounded mailbox; it never submits GPU commands. No notifier,
//! host TLS owner, second device, or initialization-order workaround is required.
use crate::frame::{Frame, MAX_COMMANDS};
use slint::wgpu_30::wgpu;
use std::{
    collections::BTreeMap,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};
use wgpu::util::DeviceExt;
fn bytes(values: &[u32]) -> Vec<u8> {
    values.iter().flat_map(|v| v.to_le_bytes()).collect()
}
pub struct Renderer {
    d: wgpu::Device,
    q: wgpu::Queue,
    pipeline: wgpu::RenderPipeline,
    dummy: wgpu::TextureView,
    atlas: BTreeMap<(u64, u64), (wgpu::TextureView, u64)>,
    namespace: Option<u64>,
    slots: [Option<wgpu::Texture>; 2],
    slot: usize,
    submitted: Option<usize>,
    ready: [Arc<AtomicBool>; 2],
    pub skipped: usize,
    vertex: Option<wgpu::Buffer>,
    capacity: usize,
    uniform: wgpu::Buffer,
    pub uploads: usize,
    pub renders: usize,
    pub target_creates: usize,
}
const SHADER: &str = include_str!("terminal.wgsl");
fn atlas_texture(
    d: &wgpu::Device,
    q: &wgpu::Queue,
    w: u32,
    h: u32,
    data: &[u8],
    format: u32,
) -> wgpu::TextureView {
    let t = d.create_texture_with_data(
        q,
        &wgpu::TextureDescriptor {
            label: Some("Howl canonical atlas"),
            size: wgpu::Extent3d {
                width: w,
                height: h,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: if format == 0 {
                wgpu::TextureFormat::R8Uint
            } else {
                wgpu::TextureFormat::Rgba8Uint
            },
            usage: wgpu::TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        },
        wgpu::util::TextureDataOrder::default(),
        data,
    );
    t.create_view(&Default::default())
}
impl Renderer {
    pub fn new(d: &wgpu::Device, q: &wgpu::Queue) -> Self {
        let shader = d.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("Howl canonical commands"),
            source: wgpu::ShaderSource::Wgsl(SHADER.into()),
        });
        let pipeline = d.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
        label: None,
        layout: None,
        vertex: wgpu::VertexState {
            module: &shader,
            entry_point: Some("vs"),
            buffers: &[Some(wgpu::VertexBufferLayout {
                array_stride: 80, step_mode: wgpu::VertexStepMode::Instance,
                attributes: &wgpu::vertex_attr_array![0=>Sint32x4,1=>Uint32x4,2=>Uint32x4,3=>Uint32x4,4=>Sint32x4],
            })],
            compilation_options: Default::default(),
        },
        fragment: Some(wgpu::FragmentState {
            module: &shader,
            entry_point: Some("fs"),
            compilation_options: Default::default(),
            targets: &[Some(wgpu::ColorTargetState {
                format: wgpu::TextureFormat::Rgba8Unorm,
                blend: Some(wgpu::BlendState {
                    color: wgpu::BlendComponent {
                        src_factor: wgpu::BlendFactor::SrcAlpha,
                        dst_factor: wgpu::BlendFactor::OneMinusSrcAlpha,
                        operation: wgpu::BlendOperation::Add,
                    },
                    alpha: wgpu::BlendComponent {
                        src_factor: wgpu::BlendFactor::Zero,
                        dst_factor: wgpu::BlendFactor::One,
                        operation: wgpu::BlendOperation::Add,
                    },
                }),
                write_mask: wgpu::ColorWrites::ALL,
            })],
        }),
        primitive: Default::default(),
        depth_stencil: None,
        multisample: Default::default(),
        multiview_mask: None,
        cache: None,
    });

        Self {
            d: d.clone(),
            q: q.clone(),
            pipeline,
            dummy: atlas_texture(d, q, 1, 1, &[0], 0),
            atlas: BTreeMap::new(),
            namespace: None,
            slots: [None, None],
            slot: 0,
            submitted: None,
            ready: [
                Arc::new(AtomicBool::new(true)),
                Arc::new(AtomicBool::new(true)),
            ],
            skipped: 0,
            vertex: None,
            capacity: 0,
            uniform: d.create_buffer(&wgpu::BufferDescriptor {
                label: None,
                size: 16,
                usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            }),
            uploads: 0,
            renders: 0,
            target_creates: 0,
        }
    }
    pub fn render(&mut self, f: &Frame) -> Result<Option<wgpu::Texture>, String> {
        let max = self.d.limits().max_texture_dimension_2d;
        if f.width > max
            || f.height > max
            || f.atlases.iter().any(|a| a.width > max || a.height > max)
        {
            return Err("Terminal exceeds this GPU's texture dimensions".into());
        }
        let d = &self.d;
        let q = &self.q;
        d.poll(wgpu::PollType::Poll).map_err(|e| e.to_string())?;
        let next = self.slot ^ 1;
        if !self.ready[next].load(Ordering::Acquire) {
            self.skipped += 1;
            return Ok(None);
        }
        assert!(self.ready[next].load(Ordering::Acquire));
        self.ready[next].store(false, Ordering::Release);
        if self.namespace != Some(f.namespace) {
            self.atlas.clear();
            self.namespace = Some(f.namespace);
        }
        let mut keys = std::collections::BTreeSet::new();
        for a in &f.atlases {
            keys.insert((a.resource, a.generation));
            let hash = a.fingerprint;
            if let Some(old) = self.atlas.get(&(a.resource, a.generation)) {
                if old.1 != hash {
                    return Err("Atlas changed within one generation".into());
                }
            } else {
                self.atlas.insert(
                    (a.resource, a.generation),
                    (
                        atlas_texture(d, q, a.width, a.height, &a.pixels, a.format.into()),
                        hash,
                    ),
                );
                self.uploads += 1;
            }
        }
        self.atlas.retain(|key, _| keys.contains(key));
        assert!(self.atlas.len() <= 9);
        self.slot ^= 1;
        if self.slots[self.slot]
            .as_ref()
            .is_none_or(|t| t.width() != f.width || t.height() != f.height)
        {
            self.slots[self.slot] = Some(d.create_texture(&wgpu::TextureDescriptor {
                label: Some("Howl terminal image"),
                size: wgpu::Extent3d {
                    width: f.width,
                    height: f.height,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Rgba8Unorm,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                    | wgpu::TextureUsages::TEXTURE_BINDING
                    | wgpu::TextureUsages::COPY_SRC,
                view_formats: &[],
            }));
            self.target_creates += 1;
        }
        let target = self.slots[self.slot].as_ref().unwrap().clone();
        let view = target.create_view(&Default::default());
        let fallback = f
            .commands
            .iter()
            .find(|c| c.tag != 0)
            .map(|c| (c.resource, c.generation))
            .unwrap_or((0, 0));
        let mut records = Vec::with_capacity(f.commands.len() * 20);
        let mut batches: Vec<((u64, u64), u32, u32)> = Vec::new();
        for (index, c) in f.commands.iter().enumerate() {
            let active = if c.tag == 0 {
                batches.last().map(|b| b.0).unwrap_or(fallback)
            } else {
                (c.resource, c.generation)
            };
            records.extend([
                c.destination_x as u32,
                c.destination_y as u32,
                u32::from(c.destination_width),
                u32::from(c.destination_height),
            ]);
            records.extend([
                u32::from(c.source_x),
                u32::from(c.source_y),
                u32::from(c.source_width),
                u32::from(c.source_height),
            ]);
            records.extend((0..4).map(|n| (c.color_rgba >> (n * 8)) & 255));
            records.extend([u32::from(c.tag), 0, 0, 0]);
            records.extend([
                c.clip_x as u32,
                c.clip_y as u32,
                u32::from(c.clip_width),
                u32::from(c.clip_height),
            ]);
            if let Some(last) = batches.last_mut().filter(|b| b.0 == active) {
                last.2 = index as u32 + 1;
            } else {
                batches.push((active, index as u32, index as u32 + 1));
            }
        }
        let data = bytes(&records);
        assert!(data.len() <= MAX_COMMANDS * 80);
        if data.len().max(80) > self.capacity {
            self.capacity = data.len().max(80).next_power_of_two();
            self.vertex = Some(d.create_buffer(&wgpu::BufferDescriptor {
                label: None,
                size: self.capacity as u64,
                usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            }));
        }
        q.write_buffer(self.vertex.as_ref().unwrap(), 0, &data);
        q.write_buffer(&self.uniform, 0, &bytes(&[f.width, f.height, 0, 0]));
        let layout = self.pipeline.get_bind_group_layout(0);
        let draws = batches
            .iter()
            .map(|(key, start, end)| {
                let atlas = if *key == (0, 0) {
                    &self.dummy
                } else {
                    &self.atlas.get(key).unwrap().0
                };
                (
                    d.create_bind_group(&wgpu::BindGroupDescriptor {
                        label: None,
                        layout: &layout,
                        entries: &[
                            wgpu::BindGroupEntry {
                                binding: 0,
                                resource: self.uniform.as_entire_binding(),
                            },
                            wgpu::BindGroupEntry {
                                binding: 1,
                                resource: wgpu::BindingResource::TextureView(atlas),
                            },
                        ],
                    }),
                    *start,
                    *end,
                )
            })
            .collect::<Vec<_>>();
        let mut encoder = d.create_command_encoder(&Default::default());
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: None,
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color {
                            r: (f.background & 255) as f64 / 255.,
                            g: ((f.background >> 8) & 255) as f64 / 255.,
                            b: ((f.background >> 16) & 255) as f64 / 255.,
                            a: 1.,
                        }),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                ..Default::default()
            });
            pass.set_pipeline(&self.pipeline);
            pass.set_vertex_buffer(0, self.vertex.as_ref().unwrap().slice(..));
            for (group, start, end) in &draws {
                pass.set_bind_group(0, group, &[]);
                pass.draw(0..6, *start..*end);
            }
        }
        q.submit([encoder.finish()]);
        self.renders += 1;
        self.submitted = Some(self.slot);
        Ok(Some(target))
    }
    // Bounds our composition backlog. Subsequent Slint sampling and writes
    // serialize on the same Queue; this is NOT a sampling/presentation fence.
    pub fn track_composition_completion(&mut self) {
        let Some(slot) = self.submitted.take() else {
            return;
        };
        let ready = self.ready[slot].clone();
        self.q
            .on_submitted_work_done(move || ready.store(true, Ordering::Release));
    }
}

use slint::ComponentHandle;
use std::sync::Mutex;

pub struct Frames {
    renderer: Mutex<Renderer>,
    failed: AtomicBool,
    retrying: AtomicBool,
    pending: Mutex<Option<(Frame, Arc<AtomicBool>)>>,
    queued: AtomicBool,
}
impl Frames {
    pub fn failed(&self) -> bool {
        self.failed.load(Ordering::Acquire)
    }
    pub fn publish(&self, frame: Frame, active: Arc<AtomicBool>) -> bool {
        let mut pending = self.pending.lock().unwrap();
        if self.failed.load(Ordering::Acquire) || !active.load(Ordering::Acquire) {
            return false;
        }
        *pending = Some((frame, active));
        !self.queued.swap(true, Ordering::AcqRel)
    }
}

pub fn enabled() -> bool {
    std::env::var_os("HOWL_GPU").is_some_and(|v| v == "1")
}

pub struct Context {
    device: wgpu::Device,
    queue: wgpu::Queue,
}
pub fn initialize() -> Result<Context, Box<dyn std::error::Error>> {
    // The Linux opt-in path uses Vulkan. Avoid loading unrelated EGL/GL
    // drivers merely to enumerate adapters that this presenter will not use.
    let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
        backends: wgpu::Backends::VULKAN,
        ..wgpu::InstanceDescriptor::new_without_display_handle()
    });
    let adapter =
        pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions::default()))?;
    eprintln!("Howl GPU adapter: {:?}", adapter.get_info());
    let descriptor = wgpu::DeviceDescriptor {
        required_limits: wgpu::Limits::downlevel_webgl2_defaults()
            .using_resolution(adapter.limits()),
        memory_hints: wgpu::MemoryHints::MemoryUsage,
        ..Default::default()
    };
    let (device, queue) = pollster::block_on(adapter.request_device(&descriptor))?;
    slint::BackendSelector::new()
        .require_wgpu_30(slint::wgpu_30::WGPUConfiguration::Manual {
            instance,
            adapter,
            device: device.clone(),
            queue: queue.clone(),
        })
        .select()?;
    Ok(Context { device, queue })
}
pub fn attach(context: &Context, app: &crate::App) -> Option<Arc<Frames>> {
    if !enabled() {
        return None;
    }
    let renderer = Renderer::new(&context.device, &context.queue);
    let frames = Arc::new(Frames {
        pending: Mutex::new(None),
        queued: AtomicBool::new(false),
        renderer: Mutex::new(renderer),
        failed: AtomicBool::new(false),
        retrying: AtomicBool::new(false),
    });
    // The Manual device belongs to this presentation owner. Slint 1.18.1 does
    // not install a device-loss callback on it. Do not destroy the shared device
    // to test this path: its loss also invalidates Slint's own presentation.
    let weak = Arc::downgrade(&frames);
    let window = app.as_weak();
    context
        .device
        .set_device_lost_callback(move |reason, detail| {
            let Some(frames) = weak.upgrade() else { return };
            frames.failed.store(true, Ordering::Release);
            let error =
                format!("GPU device lost ({reason:?}): {detail}. Restart Howl to reconnect.");
            eprintln!("{error}");
            let _ = window.upgrade_in_event_loop(move |app| {
                app.invoke_disconnect_server();
                app.set_terminal_status(error.into());
            });
        });
    Some(frames)
}
impl Frames {
    pub fn present(self: &Arc<Self>, app: &crate::App) {
        let mut pending = self.pending.lock().unwrap();
        self.queued.store(false, Ordering::Release);
        if self.failed.load(Ordering::Acquire) {
            pending.take();
            return;
        }
        let Some((frame, active)) = pending.as_ref() else {
            return;
        };
        if !active.load(Ordering::Acquire) {
            pending.take();
            return;
        }
        let mut renderer = self.renderer.lock().unwrap();
        match renderer.render(frame) {
            Ok(Some(texture)) => {
                let image = match slint::Image::try_from(texture) {
                    Ok(image) => image,
                    Err(error) => {
                        self.failed.store(true, Ordering::Release);
                        pending.take();
                        drop(renderer);
                        drop(pending);
                        app.invoke_disconnect_server();
                        app.set_terminal_status(
                            format!("GPU image rejected: {error}. Restart Howl to reconnect.")
                                .into(),
                        );
                        return;
                    }
                };
                app.set_terminal_frame(image);
                pending.take();
                // This is a composition completion bound, not a sampling fence.
                // Later writes and Slint sampling serialize on this same queue;
                // UI image replacement and Slint scene encoding serialize on UI.
                // Never rewrite the currently published texture.
                renderer.track_composition_completion();
            }
            Ok(None) => {
                if !self.retrying.swap(true, Ordering::AcqRel) {
                    let frames = self.clone();
                    let weak = app.as_weak();
                    slint::Timer::single_shot(std::time::Duration::from_millis(16), move || {
                        frames.retrying.store(false, Ordering::Release);
                        if let Some(app) = weak.upgrade() {
                            frames.present(&app);
                        }
                    });
                }
            }
            Err(error) => {
                self.failed.store(true, Ordering::Release);
                pending.take();
                // Disconnect joins the observer. Never do that while holding a
                // mutex the observer may need in publish().
                drop(renderer);
                drop(pending);
                app.invoke_disconnect_server();
                app.set_terminal_status(
                    format!("GPU presentation stopped: {error}. Restart Howl to reconnect.").into(),
                );
            }
        }
    }
}

#[cfg(test)]
impl Drop for Renderer {
    fn drop(&mut self) {
        eprintln!(
            "GPU_TEST renders={} busy={} atlas_uploads={} targets={}",
            self.renders, self.skipped, self.uploads, self.target_creates
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::frame::{Atlas, Command};
    use std::{cell::Cell, rc::Rc};
    fn fixture(n: u64) -> Frame {
        let (width, height) = if n % 3 == 2 { (37, 29) } else { (64, 48) };
        let solid = Command {
            color_rgba: 0x8040a0f0,
            destination_x: -2,
            destination_y: 3,
            destination_width: 25,
            destination_height: 20,
            clip_x: 2,
            clip_y: 4,
            clip_width: 20,
            clip_height: 30,
            ..Default::default()
        };
        let mask = Command {
            resource: 1,
            generation: n + 1,
            tag: 1,
            color_rgba: 0xc0e03080,
            destination_x: 4,
            destination_y: 5,
            destination_width: 20,
            destination_height: 20,
            clip_width: width as u16,
            clip_height: height as u16,
            source_width: 2,
            source_height: 2,
            resource_width: 2,
            resource_height: 2,
            ..Default::default()
        };
        let rgba = Command {
            resource: 2,
            generation: n + 1,
            tag: 2,
            format: 1,
            destination_x: 12,
            destination_y: 9,
            destination_width: 16,
            destination_height: 16,
            clip_width: width as u16,
            clip_height: height as u16,
            source_width: 2,
            source_height: 2,
            resource_width: 2,
            resource_height: 2,
            ..Default::default()
        };
        let mut commands = vec![solid, mask, rgba];
        if !n.is_multiple_of(2) {
            commands.reverse();
        }
        Frame {
            namespace: 1,
            width,
            height,
            background: 0xff201008,
            commands,
            atlases: vec![
                Arc::new(Atlas::new(
                    1,
                    n + 1,
                    2,
                    2,
                    0,
                    vec![0, 64, (n * 17) as u8, 255],
                )),
                Arc::new(Atlas::new(
                    2,
                    n + 1,
                    2,
                    2,
                    1,
                    vec![255, 0, 0, 128, 0, 255, 0, 64, 0, 0, 255, 255, 9, 18, 27, 0],
                )),
            ],
        }
    }
    slint::slint! { export component TestWindow inherits Window {in-out property<image> frame; Image {source:root.frame;} } }
    #[test]
    #[ignore = "requires HOWL_GPU=1 and headless WGPU compositor"]
    fn cancelled_frames_and_presentation_failure() {
        let context = initialize().unwrap();
        let app = crate::App::new().unwrap();
        let frames = attach(&context, &app).unwrap();
        let sessions = crate::sessions::Sessions::attach_presenter(&app, Some(frames.clone()));
        let active = Arc::new(AtomicBool::new(true));
        assert!(frames.publish(fixture(0), active.clone()));
        assert!(!frames.publish(fixture(1), active.clone()));
        assert_eq!(
            frames.pending.lock().unwrap().as_ref().unwrap().0.atlases[0].generation,
            2
        );
        active.store(false, Ordering::Release);
        frames.present(&app);
        assert!(frames.pending.lock().unwrap().is_none());
        assert_eq!(frames.renderer.lock().unwrap().renders, 0);
        assert!(!frames.publish(fixture(2), active.clone()));

        // Reject a frame before GPU submission. This tests host failure handling,
        // not device loss, and never destroys Slint's shared device.
        active.store(true, Ordering::Release);
        let mut invalid = fixture(0);
        invalid.width = context.device.limits().max_texture_dimension_2d + 1;
        app.set_terminal_enabled(true);
        assert!(frames.publish(invalid, active.clone()));
        frames.present(&app);
        assert!(frames.failed());
        assert!(!app.get_terminal_enabled());
        assert!(app.get_terminal_status().contains("Restart Howl"));
        assert!(frames.pending.lock().unwrap().is_none());
        assert!(!frames.publish(fixture(0), active));
        drop(sessions);
        drop(frames);
        drop(app);
        drop(context);
    }

    #[test]
    #[ignore = "requires headless WGPU compositor"]
    fn window_parity_and_reuse() {
        let context = initialize().unwrap();
        let app = TestWindow::new().unwrap();
        let mut painter = Renderer::new(&context.device, &context.queue);
        let first = fixture(0);
        let texture = painter.render(&first).unwrap().unwrap();
        app.set_frame(slint::Image::try_from(texture).unwrap());
        painter.track_composition_completion();
        app.window()
            .set_size(slint::PhysicalSize::new(first.width, first.height));
        let verified = Rc::new(Cell::new(0));
        let passed = verified.clone();
        let weak = app.as_weak();
        let mut index = 0u64;
        let mut setup_retries = 0;
        let mut resize_retries = 0;
        let timer = slint::Timer::default();
        timer.start(
            slint::TimerMode::Repeated,
            std::time::Duration::from_millis(60),
            move || {
                let app = weak.upgrade().unwrap();
                let f = fixture(index);
                let snapshot = match app.window().take_snapshot() {
                    Ok(v) => v,
                    Err(e) if index == 0 && setup_retries < 20 => {
                        setup_retries += 1;
                        eprintln!("waiting initial window: {e}");
                        app.window().request_redraw();
                        return;
                    }
                    Err(e) => panic!("window snapshot failed: {e}"),
                };
                if snapshot.width() != f.width || snapshot.height() != f.height {
                    resize_retries += 1;
                    assert!(resize_retries <= 20, "window resize did not settle");
                    app.window()
                        .set_size(slint::PhysicalSize::new(f.width, f.height));
                    app.window().request_redraw();
                    return;
                }
                resize_retries = 0;
                assert_eq!(
                    snapshot.as_bytes(),
                    crate::frame::reference(&f),
                    "manual window frame {index}"
                );
                passed.set(passed.get() + 1);
                if passed.get() == 24 {
                    slint::quit_event_loop().unwrap();
                    return;
                }
                // Queue two updates before Slint draws. It must sample only the
                // latest Image; prior queued commands retain their resources.
                for _ in 0..2 {
                    let next = fixture(index + 1);
                    if let Some(texture) = painter.render(&next).unwrap() {
                        app.set_frame(slint::Image::try_from(texture).unwrap());
                        painter.track_composition_completion();
                        index += 1;
                    }
                }
                let current = fixture(index);
                app.window()
                    .set_size(slint::PhysicalSize::new(current.width, current.height));
            },
        );
        app.run().unwrap();
        timer.stop();
        drop(timer);
        assert_eq!(verified.get(), 24);
        drop(app);
        drop(context);
    }
}
