//! Own the native reader so cancellation reaches decode and processing, without
//! changing or depending on the private layout of x3f_core::Reader.
use std::{ffi::CString, path::Path, ptr, sync::atomic::AtomicBool};
use x3f_sys::{self as sys, Control};

struct Reader {
    file: *mut libc::FILE,
    raw: *mut sys::x3f_t,
}
impl Drop for Reader {
    fn drop(&mut self) {
        unsafe {
            if !self.raw.is_null() {
                sys::x3f_delete(self.raw);
            }
            libc::fclose(self.file);
        }
    }
}
struct Area(sys::x3f_area16_t);
impl Drop for Area {
    fn drop(&mut self) {
        unsafe {
            libc::free(self.0.buf.cast());
        }
    }
}

fn open(path: &Path, control: Control<'_>) -> Result<Reader, sys::Error> {
    control.check()?;
    #[cfg(not(windows))]
    let file = {
        #[cfg(unix)]
        use std::os::unix::ffi::OsStrExt;
        let path = CString::new(path.as_os_str().as_bytes())
            .map_err(|_| sys::Error::InvalidData("path contains NUL"))?;
        unsafe { libc::fopen(path.as_ptr(), c"rb".as_ptr()) }
    };
    #[cfg(windows)]
    let file = {
        use std::os::windows::ffi::OsStrExt;
        let mut path: Vec<u16> = path.as_os_str().encode_wide().collect();
        if path.contains(&0) {
            return Err(sys::Error::InvalidData("path contains NUL"));
        }
        path.push(0);
        unsafe extern "C" {
            fn _wfopen(path: *const u16, mode: *const u16) -> *mut libc::FILE;
        }
        unsafe { _wfopen(path.as_ptr(), [b'r' as u16, b'b' as u16, 0].as_ptr()) }
    };
    if file.is_null() {
        return Err(std::io::Error::last_os_error().into());
    }
    let mut reader = Reader {
        file,
        raw: ptr::null_mut(),
    };
    reader.raw = unsafe { sys::new_from_file(file.cast(), control) }?;
    if reader.raw.is_null() {
        return Err(sys::Error::InvalidData("missing X3F reader"));
    }
    Ok(reader)
}

pub fn render(
    path: &Path,
    spp: bool,
    cancel: &AtomicBool,
) -> Result<(Vec<f32>, u32, u32), sys::Error> {
    let control = Control::new(cancel).with_denoise_backend(sys::DenoiseBackend::Cpu);
    let reader = open(path, control)?;
    unsafe {
        for entry in [
            sys::x3f_get_camf(reader.raw),
            sys::x3f_get_prop(reader.raw),
            sys::x3f_get_thumb_jpeg(reader.raw),
            sys::x3f_get_raw(reader.raw),
        ] {
            if !entry.is_null() {
                sys::load_data(reader.raw, entry, control)?;
            }
        }
    }
    let mut area = Area(sys::x3f_area16_t::default());
    let mut levels = sys::x3f_image_levels_t::default();
    unsafe {
        sys::get_image_controlled(
            reader.raw,
            &mut area.0,
            &mut levels,
            sys::x3f_color_encoding_e_SRGB,
            1,
            1,
            10,
            i32::from((*reader.raw).header.version < 0x40000),
            ptr::null_mut(),
            sys::ProcessingOptions {
                color_mode: Some(sys::ColorMode::AsShot),
                spp_denoise: spp,
                rgb_chroma_lut: Some(!spp),
                ..Default::default()
            },
            control,
        )?;
    }
    let image = &area.0;
    if image.channels != 3
        || image.columns == 0
        || image.rows == 0
        || image.data.is_null()
        || u64::from(image.columns) * u64::from(image.rows) > 128_000_000
        || u64::from(image.row_stride) < u64::from(image.columns) * 3
    {
        return Err(sys::Error::InvalidData("invalid native X3F dimensions"));
    }
    let mut pixels = Vec::new();
    pixels
        .try_reserve_exact(image.columns as usize * image.rows as usize * 3)
        .map_err(|_| sys::Error::Allocation)?;
    for y in 0..image.rows as usize {
        control.check()?;
        let row = unsafe {
            std::slice::from_raw_parts(
                image.data.add(y * image.row_stride as usize),
                image.columns as usize * 3,
            )
        };
        pixels.extend(row.iter().map(|v| *v as f32 / 65535.0));
    }
    Ok((pixels, image.columns, image.rows))
}
