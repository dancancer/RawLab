use super::*;

// 相邻 worker 的 151 行窗口会重叠；每行超过 20 次贡献，确实执行校正。
fn fixture() -> Vec<f32> {
    let mut state = 12345_u32;
    (0..520 * 1024 * 3)
        .map(|i| {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            100.0 + (state % 400) as f32 + 50.0 * (i % 3) as f32
        })
        .collect()
}

fn run(input: &[f32]) -> (Vec<f32>, OffsetStats) {
    let mut image = input.to_vec();
    let stats = correct(
        &mut image,
        520,
        1024,
        520 * 3,
        100.0,
        [1.0; 3],
        [8, 4, 512, 900],
        Control::none(),
    )
    .unwrap();
    (image, stats)
}

fn hash(image: &[f32]) -> u64 {
    image
        .iter()
        .flat_map(|v| v.to_bits().to_le_bytes())
        .fold(0xcbf29ce484222325, |h, byte| {
            (h ^ u64::from(byte)).wrapping_mul(0x100000001b3)
        })
}

#[test]
fn overlapping_workers_preserve_pixels_and_statistics() {
    let input = fixture();
    let serial = rayon::ThreadPoolBuilder::new()
        .num_threads(1)
        .build()
        .unwrap()
        .install(|| run(&input));
    assert_ne!(serial.0, input, "fixture must apply nonzero offsets");
    // 固定 hash 来自 ARM64 macOS 上的上游串行实现；其他 libm/FMA 实现的
    // 末位可能不同，但同一平台的并行结果必须逐位等于其原有串行路径。
    if cfg!(all(target_arch = "aarch64", target_os = "macos")) {
        assert_eq!(hash(&serial.0), 0x66e2505b33d028c9);
    }
    for threads in [2, 4] {
        let pool = rayon::ThreadPoolBuilder::new()
            .num_threads(threads)
            .build()
            .unwrap();
        let (image, stats) = pool.install(|| run(&input));
        assert!(
            image
                .iter()
                .zip(&serial.0)
                .all(|(a, b)| a.to_bits() == b.to_bits()),
            "parallel row accumulation differs at {threads} threads"
        );
        assert_eq!(stats, serial.1);
        assert_eq!(
            stats,
            OffsetStats {
                patches: 607,
                accepted: 516,
                rows: 22296
            }
        );
    }
}

#[test]
#[ignore = "manual scalability benchmark; run alone on an idle machine with four CPU cores"]
fn offset_correction_scales_to_four_workers() {
    let input = fixture();
    let mut times = Vec::new();
    for threads in [1, 4] {
        let pool = rayon::ThreadPoolBuilder::new()
            .num_threads(threads)
            .build()
            .unwrap();
        pool.install(|| run(&input));
        let mut samples = Vec::new();
        for _ in 0..5 {
            let start = std::time::Instant::now();
            for _ in 0..20 {
                std::hint::black_box(pool.install(|| run(&input)));
            }
            samples.push(start.elapsed().as_secs_f64());
        }
        samples.sort_by(f64::total_cmp);
        times.push(samples[2]);
    }
    println!(
        "one_worker={} four_workers={} speedup={}",
        times[0],
        times[1],
        times[0] / times[1]
    );
    assert!(
        times[1] < times[0] * 0.65,
        "offset correction remains serial"
    );
}
