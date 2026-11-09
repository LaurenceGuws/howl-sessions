//! Owned canonical Render data. Only `capture` borrows the native frame lease.
use std::{
    ffi::c_void,
    hash::{Hash, Hasher},
    mem::{offset_of, size_of},
    slice,
    sync::Arc,
};

// Pinned HRC_MAX_* constants, checked against the canonical C header in remote.c.
pub const MAX_COMMANDS: usize = 114_689;
const MAX_ATLASES: usize = 9;
const MAX_PIXELS: usize = 80 * 1024 * 1024;

#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct Command {
    pub resource: u64,
    pub generation: u64,
    pub color_rgba: u32,
    pub destination_x: i32,
    pub destination_y: i32,
    pub clip_x: i32,
    pub clip_y: i32,
    pub destination_width: u16,
    pub destination_height: u16,
    pub clip_width: u16,
    pub clip_height: u16,
    pub source_x: u16,
    pub source_y: u16,
    pub source_width: u16,
    pub source_height: u16,
    pub resource_width: u16,
    pub resource_height: u16,
    pub tag: u8,
    pub format: u8,
    pub cursor_component: u8,
    pub reserved: u8,
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Resource {
    resource: u64,
    generation: u64,
    pixel_count: u64,
    stride: u64,
    width: u16,
    height: u16,
    format: u8,
    reserved: [u8; 3],
}
#[repr(C)]
struct Upload {
    info: Resource,
    pixels: *const u8,
    len: usize,
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Info {
    revision: u64,
    content_revision: u64,
    terminal_revision: u64,
    command_count: u32,
    content_command_count: u32,
    upload_count: u32,
    removal_count: u32,
    history_offset: u32,
    history_count: u32,
    history_row_base: u32,
    background_rgba: u32,
    width: u16,
    height: u16,
    cell_width: u16,
    cell_height: u16,
    alternate: u8,
    reserved: [u8; 7],
}
#[repr(C)]
struct View {
    info: Info,
    commands: *const Command,
    uploads: *const Upload,
    removals: *const Removal,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Residency {
    resource: u64,
    generation: u64,
    width: u16,
    height: u16,
    format: u8,
    reserved: [u8; 3],
}
#[repr(C)]
#[derive(Clone, Copy)]
struct Removal {
    resource: u64,
    generation: u64,
}

pub struct Atlas {
    pub resource: u64,
    pub generation: u64,
    pub width: u32,
    pub height: u32,
    pub format: u8,
    pub pixels: Vec<u8>,
    pub fingerprint: u64,
}
impl Atlas {
    pub fn new(
        resource: u64,
        generation: u64,
        width: u32,
        height: u32,
        format: u8,
        pixels: Vec<u8>,
    ) -> Self {
        let mut hash = std::collections::hash_map::DefaultHasher::new();
        (width, height, format, &pixels).hash(&mut hash);
        Self {
            resource,
            generation,
            width,
            height,
            format,
            pixels,
            fingerprint: hash.finish(),
        }
    }
}
pub struct Frame {
    pub namespace: u64,
    pub width: u32,
    pub height: u32,
    pub background: u32,
    pub commands: Vec<Command>,
    pub atlases: Vec<Arc<Atlas>>,
}

// C's canonical header is the authority. Native tests compare these complete
// layouts as well as offsets; the dependency is pinned, not discovered at runtime.
const _: () = {
    assert!(size_of::<Command>() == 64);
    assert!(size_of::<Resource>() == 40);
    assert!(size_of::<Residency>() == 24);
    assert!(size_of::<Removal>() == 16);
    assert!(size_of::<Info>() == 72);
    assert!(size_of::<Upload>() == 56);
    assert!(size_of::<View>() == 96);
    assert!(offset_of!(Command, tag) == 56);
    assert!(offset_of!(Resource, width) == 32);
    assert!(offset_of!(Upload, pixels) == 40);
    assert!(offset_of!(Info, width) == 56);
    assert!(offset_of!(View, commands) == 72);
};

unsafe extern "C" {
    fn remote_visit(
        client: *mut c_void,
        residency: *const Residency,
        count: usize,
        consume: unsafe extern "C" fn(*mut c_void, *const View) -> u32,
        context: *mut c_void,
        exited: *mut i32,
    ) -> u32;
}

/// One serial observer owns real CPU residency, independently of GPU delivery.
/// Frames retain complete immutable resources, so replacing pending frames is safe.
pub struct Cache {
    namespace: u64,
    atlases: Vec<Arc<Atlas>>,
}
impl Cache {
    pub fn new(namespace: u64) -> Self {
        Self {
            namespace,
            atlases: Vec::new(),
        }
    }
    fn residencies(&self) -> [Residency; MAX_ATLASES] {
        let mut output = [Residency::default(); MAX_ATLASES];
        for (slot, atlas) in output.iter_mut().zip(&self.atlases) {
            *slot = Residency {
                resource: atlas.resource,
                generation: atlas.generation,
                width: atlas.width as u16,
                height: atlas.height as u16,
                format: atlas.format,
                reserved: [0; 3],
            };
        }
        output
    }
    /// No raw native memory escapes. A failed callback leaves residency unchanged.
    pub unsafe fn capture(&mut self, client: *mut c_void) -> Result<(Frame, bool), u32> {
        let residency = self.residencies();
        let mut context = Capture {
            cache: self,
            output: None,
        };
        let mut exited = 0;
        let status = unsafe {
            remote_visit(
                client,
                residency.as_ptr(),
                context.cache.atlases.len(),
                copy_frame,
                (&mut context as *mut Capture<'_>).cast(),
                &mut exited,
            )
        };
        if status != 0 {
            return Err(status);
        }
        let frame = context.output.ok_or(8u32)?;
        Ok((self.accept(frame), exited != 0))
    }
    fn accept(&mut self, mut frame: Frame) -> Frame {
        frame.namespace = self.namespace;
        self.atlases.clone_from(&frame.atlases);
        frame
    }
}
struct Capture<'a> {
    cache: &'a Cache,
    output: Option<Frame>,
}
unsafe extern "C" fn copy_frame(context: *mut c_void, view: *const View) -> u32 {
    if context.is_null() || view.is_null() {
        return 8;
    }
    let context = unsafe { &mut *context.cast::<Capture<'_>>() };
    // Never unwind through C; malformed lengths precede pointer dereferences.
    let result = std::panic::catch_unwind(|| unsafe { copy_view(&*view, &context.cache.atlases) });
    match result {
        Ok(Ok(frame)) => {
            context.output = Some(frame);
            0
        }
        Ok(Err(code)) => code,
        Err(_) => 8,
    }
}
fn reserve<T>(length: usize) -> Result<Vec<T>, u32> {
    let mut values = Vec::new();
    values.try_reserve_exact(length).map_err(|_| 3u32)?;
    Ok(values)
}
unsafe fn copy_view(view: &View, cached: &[Arc<Atlas>]) -> Result<Frame, u32> {
    let info = view.info;
    if info.width == 0
        || info.height == 0
        || info.width > 4096
        || info.height > 4096
        || info.command_count as usize > MAX_COMMANDS
        || info.upload_count as usize > MAX_ATLASES
        || info.removal_count as usize > MAX_ATLASES
    {
        return Err(13);
    }
    if (info.command_count != 0 && view.commands.is_null())
        || (info.upload_count != 0 && view.uploads.is_null())
        || (info.removal_count != 0 && view.removals.is_null())
    {
        return Err(8);
    }
    let mut commands = reserve(info.command_count as usize)?;
    if info.command_count != 0 {
        commands.extend_from_slice(unsafe {
            slice::from_raw_parts(view.commands, info.command_count as usize)
        });
    }
    let mut atlases = reserve(MAX_ATLASES)?;
    atlases.extend(cached.iter().cloned());
    for index in 0..info.removal_count as usize {
        let removal = unsafe { &*view.removals.add(index) };
        let Some(at) = atlases
            .iter()
            .position(|a| a.resource == removal.resource && a.generation == removal.generation)
        else {
            return Err(8);
        };
        atlases.remove(at);
    }
    let mut total = 0usize;
    for index in 0..info.upload_count as usize {
        let upload = unsafe { &*view.uploads.add(index) };
        let r = upload.info;
        if r.resource == 0 || r.generation == 0 || r.width == 0 || r.height == 0 || r.format > 1 {
            return Err(8);
        }
        let row = r.width as usize * if r.format == 0 { 1 } else { 4 };
        let stride = usize::try_from(r.stride).map_err(|_| 13u32)?;
        let bytes = stride.checked_mul(r.height as usize).ok_or(13u32)?;
        total = total.checked_add(bytes).ok_or(13u32)?;
        if total > MAX_PIXELS {
            return Err(13);
        }
        if stride < row
            || upload.len < bytes
            || r.pixel_count != upload.len as u64
            || upload.pixels.is_null()
            || (0..index).any(|i| unsafe { (*view.uploads.add(i)).info.resource == r.resource })
            || (0..info.removal_count as usize)
                .any(|i| unsafe { (*view.removals.add(i)).resource == r.resource })
            || atlases
                .iter()
                .any(|a| a.resource == r.resource && a.generation >= r.generation)
        {
            return Err(8);
        }
        // Admit the complete post-replacement set before copying any new bytes.
        let mut retained = atlases.iter().filter(|a| a.resource != r.resource);
        let retained_count = retained.clone().count();
        let retained_bytes = retained
            .try_fold(0usize, |sum, a| sum.checked_add(a.pixels.len()))
            .ok_or(13u32)?;
        resource_budget(
            retained_count + 1,
            retained_bytes
                .checked_add(row * r.height as usize)
                .ok_or(13u32)?,
        )?;
        let mut pixels = reserve(row * r.height as usize)?;
        for y in 0..r.height as usize {
            pixels.extend_from_slice(unsafe {
                slice::from_raw_parts(upload.pixels.add(y * stride), row)
            });
        }
        atlases.retain(|a| a.resource != r.resource);
        atlases.push(Arc::new(Atlas::new(
            r.resource,
            r.generation,
            r.width.into(),
            r.height.into(),
            r.format,
            pixels,
        )));
        validate_resources(&atlases)?;
    }
    validate_resources(&atlases)?;
    for c in &commands {
        if c.destination_x
            .checked_add(c.destination_width.into())
            .is_none()
            || c.destination_y
                .checked_add(c.destination_height.into())
                .is_none()
            || c.clip_x.checked_add(c.clip_width.into()).is_none()
            || c.clip_y.checked_add(c.clip_height.into()).is_none()
        {
            return Err(8);
        }
        if c.tag > 2 {
            return Err(8);
        }
        if c.tag == 0 {
            continue;
        }
        if c.source_width == 0 || c.source_height == 0 {
            return Err(8);
        }
        let a = atlases
            .iter()
            .find(|a| a.resource == c.resource && a.generation == c.generation)
            .ok_or(8u32)?;
        if a.format != if c.tag == 1 { 0 } else { 1 }
            || c.format != a.format
            || u32::from(c.resource_width) != a.width
            || u32::from(c.resource_height) != a.height
            || c.source_x as u32 + c.source_width as u32 > a.width
            || c.source_y as u32 + c.source_height as u32 > a.height
        {
            return Err(8);
        }
    }
    Ok(Frame {
        namespace: 0,
        width: info.width.into(),
        height: info.height.into(),
        background: info.background_rgba,
        commands,
        atlases,
    })
}

fn validate_resources(atlases: &[Arc<Atlas>]) -> Result<(), u32> {
    let total = atlases
        .iter()
        .try_fold(0usize, |total, a| total.checked_add(a.pixels.len()))
        .ok_or(13u32)?;
    resource_budget(atlases.len(), total)
}
fn resource_budget(count: usize, bytes: usize) -> Result<(), u32> {
    if count > MAX_ATLASES || bytes > MAX_PIXELS {
        return Err(13);
    }
    Ok(())
}

#[cfg(test)]
pub fn reference(frame: &Frame) -> Vec<u8> {
    #[repr(C)]
    struct Surface {
        pixels: *mut u8,
        width: u32,
        height: u32,
    }
    unsafe extern "C" {
        fn cpu_paint(
            surface: *mut Surface,
            info: *const Info,
            commands: *const Command,
            uploads: *const Upload,
        ) -> u32;
    }
    let uploads: Vec<_> = frame
        .atlases
        .iter()
        .map(|a| Upload {
            info: Resource {
                resource: a.resource,
                generation: a.generation,
                width: a.width as u16,
                height: a.height as u16,
                stride: a.width as u64 * if a.format == 0 { 1 } else { 4 },
                format: a.format,
                ..Default::default()
            },
            pixels: a.pixels.as_ptr(),
            len: a.pixels.len(),
        })
        .collect();
    let info = Info {
        width: frame.width as u16,
        height: frame.height as u16,
        command_count: frame.commands.len() as u32,
        upload_count: uploads.len() as u32,
        background_rgba: frame.background,
        ..Default::default()
    };
    let mut pixels = vec![0; frame.width as usize * frame.height as usize * 4];
    let mut surface = Surface {
        pixels: pixels.as_mut_ptr(),
        width: 0,
        height: 0,
    };
    assert_eq!(
        unsafe {
            cpu_paint(
                &mut surface,
                &info,
                frame.commands.as_ptr(),
                uploads.as_ptr(),
            )
        },
        0
    );
    pixels
}

#[cfg(test)]
mod tests {
    use super::*;
    fn atlas_view<'a>(
        command: &'a Command,
        uploads: &'a [Upload],
        removals: &'a [Removal],
    ) -> View {
        View {
            info: Info {
                width: 4,
                height: 4,
                command_count: 1,
                upload_count: uploads.len() as u32,
                removal_count: removals.len() as u32,
                ..Default::default()
            },
            commands: command,
            uploads: uploads.as_ptr(),
            removals: removals.as_ptr(),
        }
    }
    fn mask(generation: u64) -> Command {
        Command {
            resource: 1,
            generation,
            tag: 1,
            color_rgba: u32::MAX,
            destination_width: 2,
            destination_height: 2,
            clip_width: 4,
            clip_height: 4,
            source_width: 2,
            source_height: 2,
            resource_width: 2,
            resource_height: 2,
            ..Default::default()
        }
    }
    fn upload(generation: u64, pixels: &[u8]) -> Upload {
        Upload {
            info: Resource {
                resource: 1,
                generation,
                width: 2,
                height: 2,
                stride: 2,
                pixel_count: pixels.len() as u64,
                ..Default::default()
            },
            pixels: pixels.as_ptr(),
            len: pixels.len(),
        }
    }
    unsafe fn deliver(cache: &mut Cache, view: &View) -> Result<Frame, u32> {
        let mut context = Capture {
            cache,
            output: None,
        };
        let status = unsafe { copy_frame((&mut context as *mut Capture<'_>).cast(), view) };
        if status != 0 {
            return Err(status);
        }
        let frame = context.output.take().unwrap();
        Ok(cache.accept(frame))
    }
    #[test]
    fn cached_frames_survive_dropped_delivery_cancel_and_resize() {
        let pixels = [0, 255, 128, 64];
        let command = mask(1);
        let uploads = [upload(1, &pixels)];
        let mut cache = Cache::new(7);
        let first = unsafe { deliver(&mut cache, &atlas_view(&command, &uploads, &[])) }.unwrap();
        let expected = reference(&first);
        let weak = Arc::downgrade(&first.atlases[0]);
        let mut view = atlas_view(&command, &[], &[]);
        view.info.width = 8;
        let second = unsafe { deliver(&mut cache, &view) }.unwrap();
        assert!(Arc::ptr_eq(&first.atlases[0], &second.atlases[0]));
        assert_eq!(second.namespace, 7);
        assert_eq!(cache.residencies()[0].generation, 1);
        drop(first); // The UI never presented this initial upload.
        drop(cache); // Cancellation drops the observer, not queued frame pixels.
        assert!(weak.upgrade().is_some());
        assert_eq!(&reference(&second)[..8], &expected[..8]);
        drop(second);
        assert!(weak.upgrade().is_none());
        let mut fresh = Cache::new(8); // Reattach/font rebuild has a fresh namespace.
        assert_eq!(unsafe { deliver(&mut fresh, &view) }.err(), Some(8));
        let frame = unsafe { deliver(&mut fresh, &atlas_view(&command, &uploads, &[])) }.unwrap();
        assert_eq!(frame.namespace, 8);
    }
    #[test]
    fn replacement_is_immutable_and_failed_decode_does_not_commit_residency() {
        let pixels = [1, 2, 3, 4];
        let mut cache = Cache::new(1);
        let first = unsafe {
            deliver(
                &mut cache,
                &atlas_view(&mask(1), &[upload(1, &pixels)], &[]),
            )
        }
        .unwrap();
        let mut replacement = upload(2, &pixels);
        replacement.info.width = 1;
        replacement.info.height = 1;
        replacement.info.stride = 4;
        replacement.info.format = 1;
        let mut rgba = mask(2);
        rgba.tag = 2;
        rgba.format = 1;
        rgba.source_width = 1;
        rgba.source_height = 1;
        rgba.resource_width = 1;
        rgba.resource_height = 1;
        // New upload plus stale command is an invalid complete transaction.
        assert_eq!(
            unsafe { deliver(&mut cache, &atlas_view(&mask(1), &[replacement], &[])) }.err(),
            Some(8)
        );
        assert!(Arc::ptr_eq(&cache.atlases[0], &first.atlases[0]));
        assert_eq!(cache.residencies()[0].generation, 1);
        let mut replacement = upload(2, &pixels);
        replacement.info.width = 1;
        replacement.info.height = 1;
        replacement.info.stride = 4;
        replacement.info.format = 1;
        let second =
            unsafe { deliver(&mut cache, &atlas_view(&rgba, &[replacement], &[])) }.unwrap();
        assert_eq!(second.atlases[0].generation, 2);
        assert_eq!(second.atlases[0].format, 1);
        assert_eq!(first.atlases[0].width, 2);
        assert_ne!(first.atlases[0].fingerprint, second.atlases[0].fingerprint);
        assert_eq!(
            unsafe {
                deliver(
                    &mut cache,
                    &atlas_view(&mask(1), &[upload(1, &pixels)], &[]),
                )
            }
            .err(),
            Some(8)
        );
        assert_eq!(
            unsafe {
                deliver(
                    &mut cache,
                    &atlas_view(
                        &rgba,
                        &[],
                        &[Removal {
                            resource: 1,
                            generation: 1,
                        }],
                    ),
                )
            }
            .err(),
            Some(8)
        );
        assert_eq!(cache.residencies()[0].generation, 2);
        let empty = unsafe {
            deliver(
                &mut cache,
                &atlas_view(
                    &Command::default(),
                    &[],
                    &[Removal {
                        resource: 1,
                        generation: 2,
                    }],
                ),
            )
        }
        .unwrap();
        assert!(empty.atlases.is_empty());
        assert!(cache.atlases.is_empty());
        assert_eq!(second.atlases[0].pixels, pixels);
    }
    #[test]
    fn resource_limits_include_cached_bytes_and_reject_duplicate_transactions() {
        assert_eq!(resource_budget(9, MAX_PIXELS), Ok(()));
        assert_eq!(resource_budget(10, 0), Err(13));
        assert_eq!(resource_budget(1, MAX_PIXELS + 1), Err(13));
        let mut cache = Cache::new(1);
        for resource in 1..=MAX_ATLASES as u64 {
            cache
                .atlases
                .push(Arc::new(Atlas::new(resource, 1, 1, 1, 0, vec![0])));
        }
        let pixels = [0; 4];
        let mut extra = upload(1, &pixels);
        extra.info.resource = 10;
        assert_eq!(
            unsafe { deliver(&mut cache, &atlas_view(&Command::default(), &[extra], &[])) }.err(),
            Some(13)
        );
        assert_eq!(cache.atlases.len(), 9);
        let removals = [Removal {
            resource: 1,
            generation: 1,
        }; 2];
        assert_eq!(
            unsafe { deliver(&mut cache, &atlas_view(&Command::default(), &[], &removals)) }.err(),
            Some(8)
        );
        let duplicate = [upload(2, &pixels), upload(2, &pixels)];
        assert_eq!(
            unsafe {
                deliver(
                    &mut cache,
                    &atlas_view(&Command::default(), &duplicate, &[]),
                )
            }
            .err(),
            Some(8)
        );
        let same_generation = [upload(1, &pixels)];
        assert_eq!(
            unsafe {
                deliver(
                    &mut cache,
                    &atlas_view(&Command::default(), &same_generation, &[]),
                )
            }
            .err(),
            Some(8)
        );
        assert_eq!(cache.atlases.len(), 9);
    }
    #[test]
    fn copied_frame_outlives_borrow_and_preserves_stride() {
        let mut bytes = vec![1, 2, 99, 3, 4, 99];
        let upload = Upload {
            info: Resource {
                resource: 1,
                generation: 2,
                width: 2,
                height: 2,
                stride: 3,
                pixel_count: 6,
                ..Default::default()
            },
            pixels: bytes.as_ptr(),
            len: bytes.len(),
        };
        let view = View {
            info: Info {
                width: 4,
                height: 4,
                upload_count: 1,
                ..Default::default()
            },
            commands: std::ptr::null(),
            uploads: &upload,
            removals: std::ptr::null(),
        };
        let owned = unsafe { copy_view(&view, &[]) }.unwrap();
        bytes.fill(0);
        drop(bytes);
        assert_eq!(owned.atlases[0].pixels, [1, 2, 3, 4]);
    }
    #[test]
    fn null_callback_arguments_are_rejected() {
        assert_eq!(
            unsafe { copy_frame(std::ptr::null_mut(), std::ptr::null()) },
            8
        );
    }

    #[test]
    fn malformed_atlas_metadata_is_rejected_before_copy() {
        let pixels = [0u8; 4];
        let mut upload = Upload {
            info: Resource {
                resource: 1,
                generation: 1,
                pixel_count: 4,
                stride: 2,
                width: 2,
                height: 2,
                ..Default::default()
            },
            pixels: pixels.as_ptr(),
            len: pixels.len(),
        };
        let mut view = View {
            info: Info {
                width: 4,
                height: 4,
                upload_count: 1,
                ..Default::default()
            },
            commands: std::ptr::null(),
            uploads: &upload,
            removals: std::ptr::null(),
        };
        // C-derived pointers borrow the current record; every malformed case
        // must fail before following its pixel pointer or allocating its size.
        assert!(unsafe { copy_view(&view, &[]) }.is_ok());
        upload.info.stride = 1;
        view.uploads = &upload;
        assert_eq!(unsafe { copy_view(&view, &[]) }.err(), Some(8));
        upload.info.stride = u64::MAX;
        view.uploads = &upload;
        assert_eq!(unsafe { copy_view(&view, &[]) }.err(), Some(13));
        upload.info.stride = 2;
        upload.info.pixel_count = 3;
        view.uploads = &upload;
        assert_eq!(unsafe { copy_view(&view, &[]) }.err(), Some(8));
        upload.info.pixel_count = 4;
        upload.pixels = std::ptr::null();
        view.uploads = &upload;
        assert_eq!(unsafe { copy_view(&view, &[]) }.err(), Some(8));
    }

    #[test]
    fn command_must_match_exact_atlas_generation_and_dimensions() {
        let pixels = [255u8; 4];
        let upload = Upload {
            info: Resource {
                resource: 1,
                generation: 2,
                pixel_count: 4,
                stride: 2,
                width: 2,
                height: 2,
                ..Default::default()
            },
            pixels: pixels.as_ptr(),
            len: pixels.len(),
        };
        let mut command = Command {
            resource: 1,
            generation: 2,
            tag: 1,
            destination_width: 2,
            destination_height: 2,
            clip_width: 4,
            clip_height: 4,
            source_width: 2,
            source_height: 2,
            resource_width: 2,
            resource_height: 2,
            ..Default::default()
        };
        let mut view = View {
            info: Info {
                width: 4,
                height: 4,
                command_count: 1,
                upload_count: 1,
                ..Default::default()
            },
            commands: &command,
            uploads: &upload,
            removals: std::ptr::null(),
        };
        assert!(unsafe { copy_view(&view, &[]) }.is_ok());
        command.generation = 3;
        view.commands = &command;
        assert_eq!(unsafe { copy_view(&view, &[]) }.err(), Some(8));
        command.generation = 2;
        command.resource_width = 3;
        view.commands = &command;
        assert_eq!(unsafe { copy_view(&view, &[]) }.err(), Some(8));
        command.resource_width = 2;
        command.source_x = 1;
        view.commands = &command;
        assert_eq!(unsafe { copy_view(&view, &[]) }.err(), Some(8));
        command.source_x = 0;
        command.destination_x = i32::MAX;
        view.commands = &command;
        assert_eq!(unsafe { copy_view(&view, &[]) }.err(), Some(8));
        view.info.removal_count = MAX_ATLASES as u32 + 1;
        view.commands = &command;
        assert_eq!(unsafe { copy_view(&view, &[]) }.err(), Some(13));
    }

    #[test]
    fn rejects_bounds_and_missing_epoch() {
        let command = Command {
            tag: 1,
            resource: 1,
            generation: 2,
            ..Default::default()
        };
        let mut view = View {
            info: Info {
                width: 4,
                height: 4,
                command_count: 1,
                ..Default::default()
            },
            commands: &command,
            uploads: std::ptr::null(),
            removals: std::ptr::null(),
        };
        assert_eq!(unsafe { copy_view(&view, &[]) }.err(), Some(8));
        view.info.command_count = MAX_COMMANDS as u32 + 1;
        assert_eq!(unsafe { copy_view(&view, &[]) }.err(), Some(13));
        view.info.command_count = 1;
        view.commands = std::ptr::null();
        assert_eq!(unsafe { copy_view(&view, &[]) }.err(), Some(8));
    }
}
