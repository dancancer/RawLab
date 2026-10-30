// 编译为固定版本 x3f-core 的 example；只生成离线对照，不调用 Sigma 私有库。
use std::{env, fs, path::Path, time::Instant};
use x3f_core::{ColorEncoding, ColorMode, DenoiseBackend, ProcessOptions, Reader};

fn decode(pipeline: &str, input: &Path, output: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let started = Instant::now();
    let mut reader = Reader::open(input)?;
    reader.load_camf()?;
    reader.load_property_list()?;
    reader.dump_meta(output.join("metadata.txt"))?;
    reader.load_raw()?;
    let options = ProcessOptions {
        color_encoding: ColorEncoding::Srgb,
        denoise_backend: DenoiseBackend::Cpu,
        denoise_intensity: 10,
        color_mode: (pipeline != "native").then_some(ColorMode::AsShot),
        spp_denoise: pipeline == "merrill-spp",
        rgb_chroma_lut: Some(pipeline != "merrill-spp"),
        // 对照固定设置；不把这个接口描述成完整的 SPP 保存参数重放。
        ..Default::default()
    };
    reader.dump_tiff(output.join("render.tif"), &options)?;
    let protocol = serde_json::json!({
        "schema": "rawlab-family-render-v1",
        "decoder_revision": "00f9ef206a2d629bca35ceead4b3951833b85d3d",
        "source_path": input.canonicalize()?,
        "header_version": reader.header_version(),
        "pipeline": pipeline,
        "color_encoding": "sRGB",
        "denoise_backend": "cpu",
        "denoise_intensity": 10,
        "spp_denoise": options.spp_denoise,
        "camera_mode": if pipeline == "native" { None } else { Some("as-shot") },
        "environment_policy": "x3f-tunables-cleared",
        "settings_policy": "fixed-native-settings-not-saved-adjustments",
        "elapsed_ms": started.elapsed().as_secs_f64() * 1000.0
    });
    fs::write(
        output.join("protocol.json"),
        serde_json::to_string_pretty(&protocol)?,
    )?;
    Ok(())
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = env::args_os().collect();
    if args.len() != 4 {
        return Err(
            "decode_family native|as-shot|merrill-spp INPUT.X3F NEW_OUTPUT_DIRECTORY".into(),
        );
    }
    let pipeline = args[1].to_str().ok_or("Invalid pipeline name")?;
    if !["native", "as-shot", "merrill-spp"].contains(&pipeline) {
        return Err("Unknown pipeline; no automatic fallback is available".into());
    }
    // 在创建 Reader/工作线程前清理本进程的研究开关，避免同一路径被继承环境暗改。
    for (key, _) in env::vars_os().collect::<Vec<_>>() {
        if key.to_string_lossy().starts_with("X3F_") {
            env::remove_var(key);
        }
    }
    let output = Path::new(&args[3]);
    fs::create_dir(output)?;
    let result = decode(pipeline, Path::new(&args[2]), output);
    if result.is_err() {
        fs::remove_dir_all(output)?;
    }
    result
}
