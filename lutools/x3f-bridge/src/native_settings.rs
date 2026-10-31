use crate::settings::SavedSettings;
use serde::Deserialize;
use std::{
    collections::BTreeMap,
    fs::File,
    io::{Read, Seek, SeekFrom},
    path::Path,
};

#[derive(Deserialize, PartialEq, Debug)]
struct Entry {
    tag: u16,
    kind: u16,
    count: u32,
    data: Vec<u8>,
}
#[derive(Deserialize)]
struct QuattroProfile {
    header: Vec<u8>,
    groups: Vec<Vec<Entry>>,
}
#[derive(Deserialize)]
struct MerrillProfile {
    extensions: Vec<(u8, f64)>,
}

pub fn validate_merrill(s: &SavedSettings) -> Result<(), String> {
    let p: MerrillProfile =
        serde_json::from_str(include_str!("../profiles/merrill-neutral-v1.json"))
            .map_err(|e| e.to_string())?;
    let extensions: BTreeMap<_, _> = s.extensions.iter().copied().collect();
    if [
        s.exposure,
        s.contrast,
        s.shadow,
        s.highlight,
        s.saturation,
        s.sharpness,
        s.fill_light,
    ]
    .iter()
    .any(|v| *v != 0.0)
        || s.color_adjustment != [1.0; 3]
        || s.color_mode != "Neutral"
        || extensions.len() != s.extensions.len()
        || extensions != p.extensions.into_iter().collect()
    {
        return Err("Merrill saved adjustments differ from the supported neutral profile; they have not been silently reset".into());
    }
    Ok(())
}

fn word(data: &[u8], offset: usize) -> Result<u32, String> {
    let bytes = data
        .get(offset..offset.checked_add(4).ok_or("X3F offset overflow")?)
        .ok_or("Truncated SPPA data")?;
    Ok(u32::from_le_bytes(bytes.try_into().unwrap()))
}

pub fn validate_sppa(data: &[u8]) -> Result<(), String> {
    let profile: QuattroProfile =
        serde_json::from_str(include_str!("../profiles/quattro-neutral-v1.json"))
            .map_err(|e| e.to_string())?;
    let unsupported = || {
        "Quattro saved SPPA adjustments differ from the verified neutral profile; no settings were silently ignored".to_string()
    };
    if data.get(..20) != Some(profile.header.as_slice()) {
        return Err(unsupported());
    }
    let mut offset = 20;
    for (group, expected) in profile.groups.iter().enumerate() {
        let magic = format!("APD{}", group + 1);
        if data.get(offset..offset + 4) != Some(magic.as_bytes()) {
            return Err(unsupported());
        }
        let count = word(data, offset + 4)? as usize;
        if count != expected.len() || count > 1024 {
            return Err(unsupported());
        }
        let table_end = offset
            .checked_add(8 + count * 12)
            .ok_or("SPPA table overflow")?;
        let next = word(data, table_end)? as usize;
        let mut end = table_end + 4;
        let mut entries = Vec::with_capacity(count);
        for i in 0..count {
            let position = offset + 8 + i * 12;
            let tag_kind = word(data, position)?;
            let tag = tag_kind as u16;
            let kind = (tag_kind >> 16) as u16;
            let count = word(data, position + 4)?;
            let item_size = match kind {
                1 | 2 | 6 | 7 => 1,
                3 | 8 => 2,
                4 | 9 | 11 => 4,
                5 | 10 | 12 => 8,
                _ => return Err(unsupported()),
            };
            let length = (count as usize)
                .checked_mul(item_size)
                .ok_or("SPPA value overflow")?;
            if length == 0 || length > 65536 {
                return Err(unsupported());
            }
            let value_offset = if length <= 4 {
                position + 8
            } else {
                let p = word(data, position + 8)? as usize;
                if p < table_end + 4 {
                    return Err("SPPA value overlaps its directory".into());
                }
                p
            };
            let value_end = value_offset
                .checked_add(length)
                .ok_or("SPPA offset overflow")?;
            let value = data
                .get(value_offset..value_end)
                .ok_or("Truncated SPPA value")?;
            if length > 4 {
                end = end.max(value_end);
            }
            entries.push(Entry {
                tag,
                kind,
                count,
                data: value.to_vec(),
            });
        }
        entries.sort_by_key(|e| e.tag);
        if entries != *expected {
            return Err(unsupported());
        }
        if next
            != if group + 1 == profile.groups.len() {
                0
            } else {
                end
            }
        {
            return Err(unsupported());
        }
        offset = end;
    }
    if offset != data.len() {
        return Err(unsupported());
    }
    Ok(())
}

pub fn validate_quattro(path: &Path) -> Result<(), String> {
    let mut file = File::open(path).map_err(|e| e.to_string())?;
    let length = file.metadata().map_err(|e| e.to_string())?.len();
    if length < 16 {
        return Err("Truncated X3F directory".into());
    }
    file.seek(SeekFrom::End(-4)).map_err(|e| e.to_string())?;
    let mut tail = [0; 4];
    file.read_exact(&mut tail).map_err(|e| e.to_string())?;
    let directory = u32::from_le_bytes(tail) as u64;
    if directory + 12 > length - 4 {
        return Err("Invalid X3F directory offset".into());
    }
    file.seek(SeekFrom::Start(directory))
        .map_err(|e| e.to_string())?;
    let mut header = [0; 12];
    file.read_exact(&mut header).map_err(|e| e.to_string())?;
    let count = word(&header, 8)? as u64;
    if &header[..4] != b"SECd" || count > 1024 || directory + 12 + count * 12 > length - 4 {
        return Err("Invalid X3F directory".into());
    }
    let mut entries = vec![0; count as usize * 12];
    file.read_exact(&mut entries).map_err(|e| e.to_string())?;
    let mut found = None;
    for entry in entries.chunks_exact(12) {
        if &entry[8..12] != b"SPPA" {
            continue;
        }
        let offset = word(entry, 0)? as u64;
        let size = word(entry, 4)? as u64;
        if found.is_some() || size < 20 || size > 16 * 1024 * 1024 || offset + size > directory {
            return Err("Invalid or duplicate SPPA section".into());
        }
        found = Some((offset, size));
    }
    if let Some((offset, size)) = found {
        file.seek(SeekFrom::Start(offset))
            .map_err(|e| e.to_string())?;
        let mut data = vec![0; size as usize];
        file.read_exact(&mut data).map_err(|e| e.to_string())?;
        validate_sppa(&data)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn merrill_non_neutral_color_mode_is_rejected() {
        let profile: MerrillProfile =
            serde_json::from_str(include_str!("../profiles/merrill-neutral-v1.json")).unwrap();
        let mut settings = SavedSettings {
            color_mode: "Neutral".into(),
            color_adjustment: [1.0; 3],
            extensions: profile.extensions,
            ..Default::default()
        };
        assert!(validate_merrill(&settings).is_ok());
        settings.color_mode = "Vivid".into();
        assert!(validate_merrill(&settings).is_err());
        settings.color_mode.clear();
        assert!(validate_merrill(&settings).is_err());
    }

    #[test]
    fn verified_neutral_sppa_is_accepted_and_changes_are_rejected() {
        let original = include_bytes!("../tests/fixtures/quattro-neutral.sppa");
        assert!(validate_sppa(original).is_ok());
        let mut changed = original.to_vec();
        changed[0x3f8..0x3fc].copy_from_slice(&5_i32.to_le_bytes());
        assert!(
            validate_sppa(&changed).is_err(),
            "nonzero exposure cannot be ignored"
        );
        changed = original.to_vec();
        changed[0x528] ^= 1;
        assert!(
            validate_sppa(&changed).is_err(),
            "unknown stored control cannot be ignored"
        );
        assert!(validate_sppa(&original[..0x400]).is_err());
    }
}
