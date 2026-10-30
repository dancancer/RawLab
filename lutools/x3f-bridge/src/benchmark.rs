//! 手动真实 RAW 基准，默认测试不依赖私人样片或机器性能。
use super::*;
use std::time::Instant;

fn source() -> CString {
    CString::new(
        std::env::var("RAWLAB_X3F_BENCH_RAW")
            .expect("set RAWLAB_X3F_BENCH_RAW to an admitted neutral Merrill X3F"),
    )
    .unwrap()
}

#[test]
#[ignore = "requires RAWLAB_X3F_BENCH_RAW; run alone for performance measurements"]
fn merrill_render() {
    let path = source();
    let repeats: usize = std::env::var("RAWLAB_X3F_BENCH_REPEATS")
        .unwrap_or_else(|_| "3".into())
        .parse()
        .unwrap();
    assert!((1..=20).contains(&repeats));
    let reference =
        std::env::var_os("RAWLAB_X3F_BENCH_REFERENCE").map(|path| std::fs::read(path).unwrap());
    let handle = rawlab_x3f_create();
    for iteration in 0..repeats {
        let mut image = std::mem::MaybeUninit::<RawlabX3fImage>::uninit();
        let start = Instant::now();
        let code = unsafe {
            rawlab_x3f_decode(handle, path.as_ptr(), 2, 1, ptr::null(), image.as_mut_ptr())
        };
        let seconds = start.elapsed().as_secs_f64();
        assert_eq!(
            code,
            0,
            "{}",
            unsafe { CStr::from_ptr(rawlab_x3f_error(handle)) }.to_string_lossy()
        );
        let image = unsafe { image.assume_init() };
        let bytes = unsafe {
            std::slice::from_raw_parts(
                image.pixels.cast::<u8>(),
                image.sample_count * std::mem::size_of::<f32>(),
            )
        };
        let hash = bytes.iter().fold(0xcbf29ce484222325_u64, |h, &byte| {
            (h ^ u64::from(byte)).wrapping_mul(0x100000001b3)
        });
        println!(
            "{}",
            serde_json::json!({"iteration": iteration, "seconds": seconds,
            "width": image.width, "height": image.height, "bytes": bytes.len(),
            "fnv1a": format!("{hash:016x}")})
        );
        if let Some(reference) = &reference {
            assert_eq!(bytes.len(), reference.len());
            assert!(
                bytes == reference,
                "rendered pixels differ from the serial baseline"
            );
        }
        if iteration == 0 {
            if let Some(output) = std::env::var_os("RAWLAB_X3F_BENCH_OUTPUT") {
                std::fs::write(output, bytes).unwrap();
            }
        }
    }
    unsafe { rawlab_x3f_free(handle) };
}

#[test]
#[ignore = "requires RAWLAB_X3F_BENCH_RAW"]
fn merrill_cancel_does_not_publish_pixels() {
    let path = source();
    let handle = rawlab_x3f_create();
    let token = RawlabX3fCancel {
        cancelled: AtomicBool::new(false),
    };
    let mut image = std::mem::MaybeUninit::<RawlabX3fImage>::uninit();
    let code = std::thread::scope(|scope| {
        scope.spawn(|| {
            std::thread::sleep(std::time::Duration::from_millis(100));
            token.cancelled.store(true, Ordering::Relaxed);
        });
        unsafe { rawlab_x3f_decode(handle, path.as_ptr(), 2, 1, &token, image.as_mut_ptr()) }
    });
    assert_eq!(code, 4);
    let image = unsafe { image.assume_init() };
    assert!(image.pixels.is_null());
    assert_eq!(image.sample_count, 0);
    unsafe { rawlab_x3f_free(handle) };
}
