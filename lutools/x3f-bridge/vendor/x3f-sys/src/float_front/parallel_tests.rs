use super::*;

const WIDTH: usize = 67;
const HEIGHT: usize = 73;
const STRIDE: usize = WIDTH * 3 + 7;
const PADDING: f32 = -12345.25;

fn fixture() -> Vec<f32> {
    let mut state = 0x43000_u32;
    let mut image = vec![PADDING; STRIDE * HEIGHT];
    for row in image.chunks_exact_mut(STRIDE) {
        for value in &mut row[..WIDTH * 3] {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            *value = (state % 120_000) as f32 * 0.125;
        }
    }
    image
}

fn pool(threads: usize) -> rayon::ThreadPool {
    rayon::ThreadPoolBuilder::new()
        .num_threads(threads)
        .build()
        .unwrap()
}

fn assert_bits_and_padding(actual: &[f32], expected: &[f32]) {
    assert_eq!(actual.len(), expected.len());
    assert!(actual
        .iter()
        .zip(expected)
        .all(|(a, b)| a.to_bits() == b.to_bits()));
    assert!(actual
        .chunks_exact(STRIDE)
        .all(|row| row[WIDTH * 3..].iter().all(|&v| v == PADDING)));
}

#[test]
fn highlight_rows_preserve_pixels_maps_and_padding() {
    let input = fixture();
    let marks: Vec<_> = (0..WIDTH * HEIGHT * 3)
        .map(|i| u8::from((i / 3 + i % 3) % 7 < 3))
        .collect();
    let render = || {
        let mut image = input.clone();
        let mut sat = marks.clone();
        let mut dense = vec![0; WIDTH * HEIGHT];
        let stats = HighlightRestoration::new(0.0, 0.0)
            .restore(
                &mut image,
                WIDTH,
                HEIGHT,
                STRIDE,
                &mut sat,
                &mut dense,
                [3, 3, WIDTH as i32 - 4, HEIGHT as i32 - 4],
                Control::none(),
            )
            .unwrap();
        (image, sat, dense, stats)
    };
    let serial = pool(1).install(render);
    assert_ne!(serial.0, input);
    assert!(serial.3.have_lut && serial.3.dense_pixels > 0);
    for threads in [2, 4] {
        let actual = pool(threads).install(render);
        assert_bits_and_padding(&actual.0, &serial.0);
        assert_eq!(actual.1, serial.1);
        assert_eq!(actual.2, serial.2);
        assert_eq!(actual.3, serial.3);
    }
}

#[test]
fn despeckle_preserves_record_order_repaired_pixels_and_padding() {
    let input = fixture();
    let filter = Despeckle::new(
        [0.731, 1.831, 3.173],
        [10.0, 10.0, 5.0],
        [8, 8, WIDTH as u32 - 8, HEIGHT as u32 - 8],
    )
    .unwrap();
    let render = || {
        let records = filter
            .detect(&input, WIDTH, HEIGHT, STRIDE, Control::none())
            .unwrap();
        let mut image = input.clone();
        let count = filter
            .apply(&mut image, WIDTH, HEIGHT, STRIDE, Control::none())
            .unwrap();
        assert_eq!(count, records.len());
        (image, records)
    };
    let serial = pool(1).install(render);
    assert!(!serial.1.is_empty());
    assert_ne!(serial.0, input);
    for threads in [2, 4] {
        let actual = pool(threads).install(render);
        assert_eq!(actual.1, serial.1);
        assert_bits_and_padding(&actual.0, &serial.0);
    }
}
