#[derive(Debug, Default, serde::Deserialize)]
pub struct SavedSettings {
    pub width: u32,
    pub height: u32,
    pub rotation: u32,
    pub white_balance: String,
    #[serde(default)]
    pub color_mode: String,
    pub exposure: f64,
    pub contrast: f64,
    pub shadow: f64,
    pub highlight: f64,
    pub saturation: f64,
    pub sharpness: f64,
    pub fill_light: f64,
    pub color_adjustment: [f64; 3],
    #[serde(default, alias = "unknown_adjustments")]
    pub unknown: Vec<(u8, f64)>,
    #[serde(default)]
    pub extensions: Vec<(u8, f64)>,
}

pub fn parse(data: &[u8]) -> Result<SavedSettings, String> {
    if data.len() < 8 || &data[..4] != b"FOVb" {
        return Err("Truncated or invalid X3F header".into());
    }
    let word = |offset| u32::from_le_bytes(data[offset..offset + 4].try_into().unwrap());
    let (types, count) = match word(4) {
        0x20001 | 0x20002 => (72, 32),
        0x20003 => (104, 32),
        0x30000 => (104, 64),
        _ => return Err("Unsupported X3F saved-settings layout".into()),
    };
    if data.len() < types + count * 5 {
        return Err("Truncated X3F saved settings".into());
    }
    let mut s = SavedSettings {
        width: word(28),
        height: word(32),
        rotation: word(36),
        ..Default::default()
    };
    if s.width == 0 || s.height == 0 || u64::from(s.width) * u64::from(s.height) > 128_000_000 {
        return Err("Invalid X3F image dimensions".into());
    }
    if !matches!(s.rotation, 0 | 90 | 180 | 270) {
        return Err("Invalid saved X3F rotation".into());
    }
    let wb = data[40..72].split(|v| *v == 0).next().unwrap();
    if wb.is_empty() || wb.len() == 32 || !wb.is_ascii() {
        return Err("Invalid saved X3F white balance".into());
    }
    s.white_balance = String::from_utf8(wb.to_vec()).unwrap();
    if types == 104 {
        let mode = data[72..104].split(|v| *v == 0).next().unwrap();
        if mode.len() == 32 || !mode.is_ascii() {
            return Err("Invalid saved X3F color mode".into());
        }
        s.color_mode = String::from_utf8(mode.to_vec()).unwrap();
    }
    let mut seen = [false; 256];
    for (i, kind) in data[types..types + count].iter().copied().enumerate() {
        if kind == 0 {
            continue;
        }
        if seen[kind as usize] {
            return Err("Duplicate saved X3F adjustment".into());
        }
        seen[kind as usize] = true;
        let value = f32::from_bits(word(types + count + i * 4)) as f64;
        if !value.is_finite() {
            return Err("Nonfinite saved X3F adjustment".into());
        }
        match kind {
            1 => s.exposure = value,
            2 => s.contrast = value,
            3 => s.shadow = value,
            4 => s.highlight = value,
            5 => s.saturation = value,
            6 => s.sharpness = value,
            7..=9 => s.color_adjustment[(kind - 7) as usize] = value,
            10 => s.fill_light = value,
            _ => {
                s.extensions.push((kind, value));
                if value != 0.0 {
                    s.unknown.push((kind, value));
                }
            }
        }
    }
    // 未编辑的文件使用三个零槽位表示没有颜色轮调整。
    if s.color_adjustment == [0.0; 3] {
        s.color_adjustment = [1.0; 3];
    }
    if s.color_adjustment.iter().any(|v| *v <= 0.0) {
        return Err("Invalid saved X3F color adjustment".into());
    }
    Ok(s)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn header() -> Vec<u8> {
        let mut bytes = vec![0; 232];
        bytes[..4].copy_from_slice(b"FOVb");
        bytes[4..8].copy_from_slice(&0x20002_u32.to_le_bytes());
        bytes[28..32].copy_from_slice(&2640_u32.to_le_bytes());
        bytes[32..36].copy_from_slice(&1760_u32.to_le_bytes());
        bytes[36..40].copy_from_slice(&90_u32.to_le_bytes());
        bytes[40..48].copy_from_slice(b"Sunlight");
        bytes
    }

    #[test]
    fn classic_header_uses_saved_values_and_zero_color_is_identity() {
        let mut data = header();
        data[72] = 1;
        data[104..108].copy_from_slice(&(-0.5_f32).to_le_bytes());
        let s = parse(&data).expect("valid Classic saved settings");
        assert_eq!((s.width, s.height, s.rotation), (2640, 1760, 90));
        assert_eq!(s.white_balance, "Sunlight");
        assert_eq!(s.exposure, -0.5);
        assert_eq!(s.color_adjustment, [1.0; 3]);
    }

    #[test]
    fn malformed_headers_and_nonfinite_values_are_rejected() {
        let mut data = header();
        assert!(parse(&data[..231]).is_err());
        data[72] = 1;
        data[104..108].copy_from_slice(&f32::NAN.to_le_bytes());
        assert!(parse(&data).is_err());
        data = header();
        data[36..40].copy_from_slice(&12_u32.to_le_bytes());
        assert!(parse(&data).is_err());
    }

    #[test]
    fn merrill_layout_uses_sixty_four_slots_after_color_mode() {
        let mut bytes = header();
        bytes.resize(424, 0);
        bytes[4..8].copy_from_slice(&0x30000_u32.to_le_bytes());
        bytes[72..79].copy_from_slice(b"Neutral");
        bytes[104] = 1;
        bytes[105] = 12;
        bytes[168..172].copy_from_slice(&0.5_f32.to_le_bytes());
        bytes[172..176].copy_from_slice(&0.5_f32.to_le_bytes());
        let s = parse(&bytes).unwrap();
        assert_eq!(s.color_mode, "Neutral");
        assert_eq!(s.exposure, 0.5);
        assert_eq!(s.extensions, vec![(12, 0.5)]);
        assert!(parse(&bytes[..423]).is_err());
    }

    #[test]
    fn unknown_nonzero_controls_are_retained_for_explicit_rejection() {
        let mut data = header();
        data[72] = 31;
        data[104..108].copy_from_slice(&0.75_f32.to_le_bytes());
        assert_eq!(parse(&data).unwrap().unknown, vec![(31, 0.75)]);
    }

    #[test]
    fn duplicate_controls_cannot_hide_an_unsupported_saved_value() {
        let mut data = header();
        data[72] = 2;
        data[73] = 2;
        data[104..108].copy_from_slice(&2_f32.to_le_bytes());
        assert!(parse(&data).unwrap_err().contains("Duplicate"));
    }
}
