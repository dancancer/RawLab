mod dp1s;
mod native;
mod native_settings;
mod settings;

#[cfg(test)]
mod benchmark;

use std::{
    ffi::{c_char, CStr, CString},
    fs::File,
    io::Read,
    panic::{catch_unwind, AssertUnwindSafe},
    path::Path,
    ptr,
    sync::atomic::{AtomicBool, Ordering},
};
use x3f_core::{DenoiseBackend, SceneLinearOptions};

#[repr(C)]
pub struct RawlabX3fImage {
    pixels: *const f32,
    sample_count: usize,
    width: u32,
    height: u32,
    encoding: u32,
    orientation: u32,
}

pub struct RawlabX3fHandle {
    pixels: Vec<f32>,
    error: CString,
}

pub struct RawlabX3fCancel {
    cancelled: AtomicBool,
}
#[no_mangle]
pub extern "C" fn rawlab_x3f_cancel_create() -> *mut RawlabX3fCancel {
    Box::into_raw(Box::new(RawlabX3fCancel {
        cancelled: AtomicBool::new(false),
    }))
}
#[no_mangle]
pub unsafe extern "C" fn rawlab_x3f_cancel(token: *const RawlabX3fCancel) {
    if let Some(token) = unsafe { token.as_ref() } {
        token.cancelled.store(true, Ordering::Relaxed);
    }
}
#[no_mangle]
pub unsafe extern "C" fn rawlab_x3f_cancel_free(token: *mut RawlabX3fCancel) {
    if !token.is_null() {
        drop(unsafe { Box::from_raw(token) });
    }
}

#[no_mangle]
pub extern "C" fn rawlab_x3f_create() -> *mut RawlabX3fHandle {
    Box::into_raw(Box::new(RawlabX3fHandle {
        pixels: Vec::new(),
        error: CString::default(),
    }))
}

#[no_mangle]
pub unsafe extern "C" fn rawlab_x3f_free(handle: *mut RawlabX3fHandle) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

#[no_mangle]
pub unsafe extern "C" fn rawlab_x3f_error(handle: *const RawlabX3fHandle) -> *const c_char {
    if handle.is_null() {
        c"Invalid X3F decoder handle".as_ptr()
    } else {
        unsafe { (*handle).error.as_ptr() }
    }
}

fn decode(
    path: &Path,
    pipeline: u32,
    orientation: u32,
    cancel: &AtomicBool,
) -> Result<(Vec<f32>, u32, u32, u32), String> {
    if cancel.load(Ordering::Relaxed) {
        return Err("X3F conversion cancelled".into());
    }
    if pipeline > 2 || !(1..=8).contains(&orientation) {
        return Err("Invalid X3F pipeline or orientation".into());
    }
    // 不能清除宿主环境中的变量；拒绝会暗改固定显影身份的研究开关。
    if std::env::vars_os().any(|(key, _)| key.to_string_lossy().starts_with("X3F_")) {
        return Err(
            "X3F research environment overrides are not supported by the fixed RawLab renderer"
                .into(),
        );
    }
    let mut header = [0_u8; 424];
    File::open(path)
        .map_err(|e| e.to_string())?
        .read_exact(&mut header)
        .map_err(|e| e.to_string())?;
    if &header[..4] != b"FOVb" {
        return Err("Invalid X3F signature".into());
    }
    let merrill = if pipeline == 2 {
        let settings = settings::parse_merrill(&header)?;
        Some(native_settings::merrill(&settings)?)
    } else {
        None
    };
    if pipeline == 1 {
        native_settings::validate_quattro(path)?;
    }
    if pipeline == 0 {
        let settings = settings::parse(&header)?;
        let scene = x3f_core::prepare_scene_linear(
            path,
            &SceneLinearOptions {
                denoise_backend: DenoiseBackend::Cpu,
                denoise_intensity: 10,
                highlight_recovery: false,
                ..Default::default()
            },
            cancel,
            |_| {},
        )
        .map_err(|e| e.to_string())?;
        if (scene.width, scene.height) != (settings.width, settings.height) {
            return Err("DP1S active crop does not match its saved settings".into());
        }
        let pixels = dp1s::render(
            &scene.data,
            scene.width as usize,
            scene.height as usize,
            &settings,
            cancel,
        )?;
        let orientation = match settings.rotation {
            90 => 6,
            180 => 3,
            270 => 8,
            _ => 1,
        };
        return Ok((pixels, scene.width, scene.height, orientation));
    }
    let (pixels, width, height) =
        native::render(path, merrill.as_ref(), cancel).map_err(|e| e.to_string())?;
    Ok((pixels, width, height, orientation))
}

fn format_panic_message(payload: Box<dyn std::any::Any + Send>) -> String {
    let detail = if let Some(s) = payload.downcast_ref::<&'static str>() {
        *s
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.as_str()
    } else {
        ""
    };
    if detail.is_empty() {
        "X3F decoder failed; no output was published".into()
    } else {
        format!("X3F decoder panicked: {detail}")
    }
}

unsafe fn rawlab_x3f_decode_with<F>(
    handle: *mut RawlabX3fHandle,
    path: *const c_char,
    token: *const RawlabX3fCancel,
    output: *mut RawlabX3fImage,
    run: F,
) -> i32
where
    F: FnOnce(&Path, &AtomicBool) -> Result<(Vec<f32>, u32, u32, u32), String>,
{
    if handle.is_null() || output.is_null() {
        return 1;
    }
    unsafe {
        ptr::write(
            output,
            RawlabX3fImage {
                pixels: ptr::null(),
                sample_count: 0,
                width: 0,
                height: 0,
                encoding: 0,
                orientation: 0,
            },
        );
    }
    let handle = unsafe { &mut *handle };
    handle.pixels.clear();
    handle.error = CString::default();
    if path.is_null() {
        handle.error = c"Missing X3F source path".into();
        return 1;
    }
    let never_cancel = AtomicBool::new(false);
    let cancel = unsafe { token.as_ref() }
        .map(|token| &token.cancelled)
        .unwrap_or(&never_cancel);
    let result = catch_unwind(AssertUnwindSafe(|| {
        let path = unsafe { CStr::from_ptr(path) }
            .to_str()
            .map_err(|_| "Invalid UTF-8 X3F path".to_string())?;
        run(Path::new(path), cancel)
    }));
    if cancel.load(Ordering::Relaxed) {
        handle.error = c"X3F conversion cancelled".into();
        return 4;
    }
    match result {
        Ok(Ok((pixels, width, height, orientation))) if pixels.iter().all(|v| v.is_finite()) => {
            handle.pixels = pixels;
            unsafe {
                ptr::write(
                    output,
                    RawlabX3fImage {
                        pixels: handle.pixels.as_ptr(),
                        sample_count: handle.pixels.len(),
                        width,
                        height,
                        encoding: 1,
                        orientation,
                    },
                );
            }
            0
        }
        other => {
            let message = match other {
                Ok(Err(e)) => e,
                Ok(Ok(_)) => "Nonfinite X3F pixels".into(),
                Err(payload) => format_panic_message(payload),
            };
            let sanitized = message.replace('\0', "?");
            handle.error = CString::new(sanitized)
                .unwrap_or_else(|_| c"X3F decoder failed; no output was published".to_owned());
            3
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn rawlab_x3f_decode(
    handle: *mut RawlabX3fHandle,
    path: *const c_char,
    pipeline: u32,
    orientation: u32,
    token: *const RawlabX3fCancel,
    output: *mut RawlabX3fImage,
) -> i32 {
    unsafe {
        rawlab_x3f_decode_with(handle, path, token, output, |path, cancel| {
            decode(path, pipeline, orientation, cancel)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ffi_error_clears_output_and_handle_can_be_reused() {
        unsafe {
            let h = rawlab_x3f_create();
            let mut output = RawlabX3fImage {
                pixels: ptr::dangling(),
                sample_count: 9,
                width: 1,
                height: 3,
                encoding: 99,
                orientation: 1,
            };
            assert_eq!(
                rawlab_x3f_decode(h, ptr::null(), 0, 1, ptr::null(), &mut output),
                1
            );
            assert!(output.pixels.is_null());
            assert_eq!(output.sample_count, 0);
            assert!(!CStr::from_ptr(rawlab_x3f_error(h)).to_bytes().is_empty());
            assert_ne!(
                rawlab_x3f_decode(
                    h,
                    c"/nonexistent/rawlab.x3f".as_ptr(),
                    0,
                    1,
                    ptr::null(),
                    &mut output
                ),
                0
            );
            assert!(output.pixels.is_null());
            let token = rawlab_x3f_cancel_create();
            rawlab_x3f_cancel(token);
            assert_eq!(
                rawlab_x3f_decode(
                    h,
                    c"/nonexistent/rawlab.x3f".as_ptr(),
                    0,
                    1,
                    token,
                    &mut output
                ),
                4
            );
            assert!(output.pixels.is_null());
            rawlab_x3f_cancel_free(token);
            rawlab_x3f_free(h);
            rawlab_x3f_free(ptr::null_mut());
        }
    }

    #[test]
    fn ffi_panic_payload_is_preserved_and_nul_sanitized() {
        unsafe {
            let h = rawlab_x3f_create();
            let mut output = RawlabX3fImage {
                pixels: ptr::dangling(),
                sample_count: 7,
                width: 2,
                height: 2,
                encoding: 1,
                orientation: 1,
            };

            let rc_str = rawlab_x3f_decode_with(
                h,
                c"/nonexistent/panic_str.x3f".as_ptr(),
                ptr::null(),
                &mut output,
                |_, _| panic!("dp1s\0calibration boom"),
            );
            assert_eq!(rc_str, 3);
            assert!(output.pixels.is_null());
            assert_eq!(output.sample_count, 0);
            assert_eq!(
                CStr::from_ptr(rawlab_x3f_error(h)).to_str().unwrap(),
                "X3F decoder panicked: dp1s?calibration boom"
            );

            let rc_string = rawlab_x3f_decode_with(
                h,
                c"/nonexistent/panic_string.x3f".as_ptr(),
                ptr::null(),
                &mut output,
                |_, _| panic!("dynamic {} failure\0detail", 42),
            );
            assert_eq!(rc_string, 3);
            assert!(output.pixels.is_null());
            assert_eq!(
                CStr::from_ptr(rawlab_x3f_error(h)).to_str().unwrap(),
                "X3F decoder panicked: dynamic 42 failure?detail"
            );

            let rc_empty = rawlab_x3f_decode_with(
                h,
                c"/nonexistent/panic_empty.x3f".as_ptr(),
                ptr::null(),
                &mut output,
                |_, _| panic!(""),
            );
            assert_eq!(rc_empty, 3);
            assert_eq!(
                CStr::from_ptr(rawlab_x3f_error(h)).to_str().unwrap(),
                "X3F decoder failed; no output was published"
            );

            let rc_non_string = rawlab_x3f_decode_with(
                h,
                c"/nonexistent/panic_any.x3f".as_ptr(),
                ptr::null(),
                &mut output,
                |_, _| std::panic::panic_any(99_u32),
            );
            assert_eq!(rc_non_string, 3);
            assert_eq!(
                CStr::from_ptr(rawlab_x3f_error(h)).to_str().unwrap(),
                "X3F decoder failed; no output was published"
            );

            rawlab_x3f_free(h);
        }
    }
}
