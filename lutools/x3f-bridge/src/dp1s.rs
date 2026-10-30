use crate::settings::SavedSettings;
use serde::Deserialize;
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicBool, Ordering},
        OnceLock,
    },
};

#[derive(Deserialize)]
struct Curve {
    x: Vec<f64>,
    y: Vec<f64>,
}
#[derive(Deserialize)]
struct Tone {
    amount: f64,
    positive: Curve,
    negative: Curve,
}
#[derive(Deserialize)]
struct Fill {
    scale: f64,
    weights: Vec<[f64; 3]>,
}
#[derive(Deserialize)]
struct Profile {
    axis: Vec<f64>,
    nodes: Vec<[f64; 3]>,
    color_log_gain_matrix: [[f64; 3]; 3],
    tone_curves: HashMap<String, Tone>,
    tone_order: Vec<String>,
    fill: Fill,
}

pub(crate) fn srgb_decode(x: f64) -> f64 {
    if x <= 0.04045 {
        x / 12.92
    } else {
        ((x + 0.055) / 1.055).powf(2.4)
    }
}

fn srgb_encode(x: f64) -> f64 {
    if x <= 0.0031308 {
        x * 12.92
    } else {
        1.055 * x.powf(1.0 / 2.4) - 0.055
    }
}

fn interpolate(x: f64, curve: &Curve) -> f64 {
    let last = curve.x.len() - 1;
    if x <= curve.x[0] {
        return curve.y[0];
    }
    if x >= curve.x[last] {
        return curve.y[last];
    }
    let lo = curve.x.partition_point(|v| *v <= x) - 1;
    let t = (x - curve.x[lo]) / (curve.x[lo + 1] - curve.x[lo]);
    curve.y[lo] + t * (curve.y[lo + 1] - curve.y[lo])
}

fn response(input: &[f32], gain: &[f64; 3], p: &Profile) -> [f64; 3] {
    let n = p.axis.len();
    let mut lo = [0_usize; 3];
    let mut t = [0_f64; 3];
    for c in 0..3 {
        let v = input[c] as f64 * gain[c];
        let x =
            (v.signum() * srgb_encode(v.abs() / (1.0 + v.abs()))).clamp(p.axis[0], p.axis[n - 1]);
        lo[c] = p
            .axis
            .partition_point(|v| *v <= x)
            .saturating_sub(1)
            .min(n - 2);
        t[c] = (x - p.axis[lo[c]]) / (p.axis[lo[c] + 1] - p.axis[lo[c]]);
    }
    let mut out = [0_f64; 3];
    for r in 0..2 {
        for g in 0..2 {
            for b in 0..2 {
                let corner = [r, g, b];
                let mut weight = 1.0;
                for c in 0..3 {
                    weight *= if corner[c] == 1 { t[c] } else { 1.0 - t[c] };
                }
                let node = &p.nodes[((lo[0] + r) * n + lo[1] + g) * n + lo[2] + b];
                for c in 0..3 {
                    out[c] += node[c] * weight;
                }
            }
        }
    }
    // 冻结原型在基础响应后保存 float32；后续色调计算使用 double。
    out.map(|v| v as f32 as f64)
}

fn box_mean(values: &[f64], width: usize, height: usize, scale: f64) -> Vec<f64> {
    let mut kernel = ((width.max(height) as f64 * scale).round_ties_even() as usize).max(1);
    if kernel % 2 == 0 {
        kernel += 1;
    }
    let radius = kernel / 2;
    let mut horizontal = vec![0.0; values.len()];
    let mut out = vec![0.0; values.len()];
    for y in 0..height {
        let row = &values[y * width..(y + 1) * width];
        let mut sum = (radius + 1) as f64 * row[0];
        for x in 1..=radius {
            sum += row[x.min(width - 1)];
        }
        for x in 0..width {
            horizontal[y * width + x] = sum / kernel as f64;
            sum += row[(x + radius + 1).min(width - 1)] - row[x.saturating_sub(radius)];
        }
    }
    for x in 0..width {
        let mut sum = (radius + 1) as f64 * horizontal[x];
        for y in 1..=radius {
            sum += horizontal[y.min(height - 1) * width + x];
        }
        for y in 0..height {
            out[y * width + x] = sum / kernel as f64;
            sum += horizontal[(y + radius + 1).min(height - 1) * width + x]
                - horizontal[y.saturating_sub(radius) * width + x];
        }
    }
    out
}

pub fn render(
    scene: &[f32],
    width: usize,
    height: usize,
    s: &SavedSettings,
    cancel: &AtomicBool,
) -> Result<Vec<f32>, String> {
    let check = || {
        if cancel.load(Ordering::Relaxed) {
            Err("X3F conversion cancelled".to_string())
        } else {
            Ok(())
        }
    };
    check()?;
    if width == 0
        || height == 0
        || width.checked_mul(height).and_then(|v| v.checked_mul(3)) != Some(scene.len())
        || scene.iter().any(|v| !v.is_finite())
    {
        return Err("Invalid DP1S scene pixels".into());
    }
    if s.white_balance == "Monochrome"
        || !s.unknown.is_empty()
        || s.sharpness != 0.0
        || [s.contrast, s.shadow, s.highlight, s.saturation]
            .iter()
            .any(|v| !v.is_finite() || v.abs() > 0.500001)
        || !(-0.500001..=0.600001).contains(&s.fill_light)
        || !s.exposure.is_finite()
        || s.exposure.abs() > 8.0
        || s.color_adjustment
            .iter()
            .any(|v| !v.is_finite() || *v <= 0.0)
    {
        return Err("This X3F contains saved adjustments outside the supported DP1S profile; use legacy mode or reset those settings in a separate copy".into());
    }
    static PROFILE: OnceLock<Result<Profile, String>> = OnceLock::new();
    let p = PROFILE
        .get_or_init(|| {
            serde_json::from_str(include_str!("../profiles/dp1s-v1.json"))
                .map_err(|e| format!("Invalid bundled DP1S profile: {e}"))
        })
        .as_ref()
        .map_err(Clone::clone)?;
    let mut gain = [0_f64; 3];
    for c in 0..3 {
        let color: f64 = (0..3)
            .map(|k| p.color_log_gain_matrix[c][k] * s.color_adjustment[k].log2())
            .sum();
        gain[c] = (color + s.exposure).exp2();
        if !gain[c].is_finite() {
            return Err("Invalid saved X3F exposure gain".into());
        }
    }
    let mut image = Vec::new();
    image
        .try_reserve_exact(width * height)
        .map_err(|_| "Insufficient memory for DP1S response")?;
    for row in scene.chunks_exact(width * 3) {
        check()?;
        image.extend(row.chunks_exact(3).map(|v| response(v, &gain, p)));
    }
    for name in &p.tone_order {
        check()?;
        let amount = match name.as_str() {
            "contrast" => s.contrast,
            "shadow" => s.shadow,
            "highlight" => s.highlight,
            _ => return Err("Invalid bundled DP1S control order".into()),
        };
        if amount == 0.0 {
            continue;
        }
        let curve = &p.tone_curves[name];
        let f = amount / curve.amount;
        for (i, rgb) in image.iter_mut().enumerate() {
            if i % width == 0 {
                check()?;
            }
            for v in rgb {
                let positive = interpolate(*v, &curve.positive) - *v;
                let negative = interpolate(*v, &curve.negative) - *v;
                *v += 0.5 * f * (positive - negative) + 0.5 * f * f * (positive + negative);
            }
        }
    }
    if s.saturation != 0.0 {
        for (i, rgb) in image.iter_mut().enumerate() {
            if i % width == 0 {
                check()?;
            }
            let linear = rgb.map(srgb_decode);
            let luma = linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722;
            for c in 0..3 {
                rgb[c] = srgb_encode(luma + (1.0 + 0.5 * s.saturation) * (linear[c] - luma));
            }
        }
    }
    for rgb in &mut image {
        for v in rgb {
            *v = v.clamp(0.0, 1.0);
        }
    }
    if s.fill_light != 0.0 {
        check()?;
        let luma: Vec<f64> = image
            .iter()
            .map(|rgb| {
                srgb_decode(rgb[0]) * 0.2126
                    + srgb_decode(rgb[1]) * 0.7152
                    + srgb_decode(rgb[2]) * 0.0722
            })
            .collect();
        let local = box_mean(&luma, width, height, p.fill.scale);
        let amount = s.fill_light;
        for (i, rgb) in image.iter_mut().enumerate() {
            if i % width == 0 {
                check()?;
            }
            let light = luma[i];
            let pixel = [
                1.0,
                rgb[0],
                rgb[1],
                rgb[2],
                light,
                light * light,
                rgb[0] * (1.0 - rgb[0]),
                rgb[1] * (1.0 - rgb[1]),
                rgb[2] * (1.0 - rgb[2]),
            ];
            let mut features = [0.0; 20];
            for k in 0..9 {
                features[k] = amount * pixel[k];
                features[9 + k] = amount * amount * pixel[k];
            }
            features[18] = amount * (local[i] - light);
            features[19] = amount * amount * (local[i] - light);
            for c in 0..3 {
                rgb[c] += (0..20)
                    .map(|k| features[k] * p.fill.weights[k][c])
                    .sum::<f64>();
            }
        }
    }
    check()?;
    let mut out = Vec::new();
    out.try_reserve_exact(scene.len())
        .map_err(|_| "Insufficient memory for DP1S output")?;
    out.extend(image.into_iter().flat_map(|rgb| rgb.map(|v| v as f32)));
    if out.iter().any(|v| !v.is_finite()) {
        return Err("Nonfinite DP1S response".into());
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;

    #[derive(Deserialize)]
    struct Case {
        settings: SavedSettings,
        expected: Vec<f32>,
    }
    #[derive(Deserialize)]
    struct Fixture {
        width: usize,
        height: usize,
        scene: Vec<f32>,
        cases: Vec<Case>,
    }

    #[test]
    fn calibrated_response_matches_independent_python_fixture() {
        let fixture: Fixture =
            serde_json::from_str(include_str!("../tests/fixtures/dp1s-response.json")).unwrap();
        for case in fixture.cases {
            let actual = render(
                &fixture.scene,
                fixture.width,
                fixture.height,
                &case.settings,
                &AtomicBool::new(false),
            )
            .unwrap();
            let max = actual
                .iter()
                .zip(&case.expected)
                .map(|(a, b)| (a - b).abs())
                .fold(0_f32, f32::max);
            assert!(max < 0.000002, "response differs by {max}");
        }
    }
}
