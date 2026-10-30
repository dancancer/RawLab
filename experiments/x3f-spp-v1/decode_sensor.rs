// 放到固定版本 x3f-core/examples；仅导出同方向、同有效区域的原始感光层证据。
use std::{fs, path::Path};
use x3f_core::{ColorEncoding, ProcessOptions, Reader};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        return Err("decode_sensor INPUT.X3F OUTPUT_DIRECTORY".into());
    }
    let output = Path::new(&args[2]);
    // 独占创建新的输出目录，正常失败时只清理本次拥有的产物。
    fs::create_dir(output)?;
    let result = decode(&args[1], output);
    if result.is_err() {
        fs::remove_dir_all(output)?;
    }
    result
}

fn decode(input: &str, output: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let pixels = output.join("sensor.tif");
    let metadata = output.join("sensor-metadata.txt");
    let protocol = output.join("sensor-protocol.json");
    let mut reader = Reader::open(input)?;
    if ![0x00020001, 0x00020002].contains(&reader.header_version()) {
        return Err("Only classic X3F 2.1/2.2 is supported".into());
    }
    reader.load_camf()?;
    reader.load_property_list()?;
    reader.load_raw()?;
    reader.dump_meta(&metadata)?;
    reader.dump_tiff(&pixels, &ProcessOptions {
        color_encoding: ColorEncoding::Unprocessed,
        crop: true,
        compress: false,
        ..Default::default()
    })?;
    fs::write(protocol, serde_json::to_string_pretty(&serde_json::json!({
        "schema": "rawlab-sensor-evidence-v1",
        "decoder_revision": "00f9ef206a2d629bca35ceead4b3951833b85d3d",
        "source_path": Path::new(input).canonicalize()?,
        "active_area_cropped": true,
        "orientation_applied": false,
        "processing": "unprocessed"
    }))?)?;
    Ok(())
}
