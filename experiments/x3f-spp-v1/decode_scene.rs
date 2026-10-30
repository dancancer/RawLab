// 放到固定版本 x3f-core 的 examples/ 下构建；只输出实验数据，不修改源 RAW。
use std::{fs::{self, File}, io::{BufWriter, Read, Write}, path::Path, sync::atomic::AtomicBool, time::Instant};
use x3f_core::{prepare_scene_linear, SceneLinearOptions};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 6 { return Err("decode_scene BLOCK_SIZE DENOISE RECOVERY OUTPUT_DIRECTORY INPUT.X3F...".into()); }
    let block: u32 = args[1].parse()?;
    if block == 0 || block > 64 { return Err("BLOCK_SIZE must be in 1..=64".into()); }
    let denoise: u8 = args[2].parse()?;
    if denoise > 10 { return Err("DENOISE must be in 0..=10".into()); }
    let recovery: u8 = args[3].parse()?;
    if recovery > 1 { return Err("RECOVERY must be 0 or 1".into()); }
    let output = Path::new(&args[4]);
    fs::create_dir_all(output)?;
    for input in &args[5..] {
        let path = Path::new(input);
        let stem = path.file_stem().ok_or("Missing file name")?.to_string_lossy();
        let mut header = [0u8; 72];
        File::open(path)?.read_exact(&mut header)?;
        let version = u32::from_le_bytes(header[4..8].try_into()?);
        if &header[..4] != b"FOVb" || ![0x00020001, 0x00020002].contains(&version) {
            return Err("This experiment only supports classic X3F 2.1/2.2".into());
        }
        let wb_bytes = header[40..72].split(|b| *b == 0).next().unwrap_or(&[]);
        let header_wb = std::str::from_utf8(wb_bytes)?;
        let start = Instant::now();
        let options = SceneLinearOptions {
            denoise_intensity: denoise,
            denoise_backend: x3f_core::DenoiseBackend::Cpu,
            highlight_recovery: recovery != 0,
            ..Default::default()
        };
        let image = prepare_scene_linear(path, &options, &AtomicBool::new(false), |_| {})?;
        let elapsed = start.elapsed().as_secs_f64() * 1000.;
        if image.data.iter().any(|v| !v.is_finite()) { return Err("Nonfinite scene pixels".into()); }
        let width = image.width.div_ceil(block);
        let height = image.height.div_ceil(block);
        let mut writer = BufWriter::new(File::create(output.join(format!("{stem}.f32")))?);
        for y in 0..height { for x in 0..width {
            let mut sum = [0f64; 3];
            let mut count = 0u32;
            for sy in y*block..((y+1)*block).min(image.height) {
                for sx in x*block..((x+1)*block).min(image.width) {
                    let index = ((sy*image.width+sx)*3) as usize;
                    for c in 0..3 { sum[c] += image.data[index+c] as f64; }
                    count += 1;
                }
            }
            for v in sum { writer.write_all(&((v/f64::from(count)) as f32).to_le_bytes())?; }
        }}
        let report = serde_json::json!({
            "width": width, "height": height, "block": block,
            "source_width": image.width, "source_height": image.height,
            "source_path": path.canonicalize()?, "source_version": version,
            "saved_header_white_balance": header_wb,
            "decoder_revision": "00f9ef206a2d629bca35ceead4b3951833b85d3d",
            "decoder_orientation": image.orientation, "decode_ms": elapsed,
            "minimum": image.data.iter().copied().fold(f32::INFINITY, f32::min),
            "maximum": image.data.iter().copied().fold(f32::NEG_INFINITY, f32::max),
            "camera_to_rgb": image.white_balance.camera_to_rgb,
            "xyz_to_camera": image.white_balance.xyz_to_camera,
            "as_shot_neutral": image.white_balance.as_shot_neutral,
            "has_native_color_mode": image.color_mode_calibration.is_some(),
            "denoise_intensity": denoise,
            "denoise_backend": "cpu",
            "highlight_recovery": recovery != 0
        });
        fs::write(output.join(format!("{stem}.json")), serde_json::to_string_pretty(&report)?)?;
        println!("{stem}: {}x{}, {:.1} ms", image.width, image.height, elapsed);
    }
    Ok(())
}
