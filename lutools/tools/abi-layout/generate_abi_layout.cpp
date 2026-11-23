#include "sony2fuji/ffi/sony2fuji_c.h"
#include "sony2fuji/ffi/sony2fuji_hdr.h"

#include <cstddef>
#include <iostream>
#include <vector>

static_assert(sizeof(void*) == 8, "64-bit C ABI target required");
static_assert(sizeof(size_t) == 8, "64-bit size_t required");

namespace {

struct FieldLayout {
    const char* name;
    size_t offset;
    size_t size;
};

struct StructLayout {
    const char* name;
    size_t size;
    std::vector<FieldLayout> fields;
};

#define ABI_FIELD(Type, Member) \
    FieldLayout{#Member, offsetof(Type, Member), sizeof(Type::Member)}

bool validateLayouts(const std::vector<StructLayout>& structs) {
    for (const auto& entry : structs) {
        if (entry.size == 0 || entry.fields.empty()) {
            std::cerr << "Invalid empty layout for " << entry.name << "\n";
            return false;
        }
        if (entry.fields[0].offset != 0) {
            std::cerr << "First field of " << entry.name << " does not start at offset 0\n";
            return false;
        }
        for (size_t i = 0; i < entry.fields.size(); ++i) {
            if (entry.fields[i].size == 0) {
                std::cerr << "Zero-sized field in " << entry.name << ": "
                          << entry.fields[i].name << "\n";
                return false;
            }
            if (i > 0 && entry.fields[i - 1].offset + entry.fields[i - 1].size > entry.fields[i].offset) {
                std::cerr << "Overlapping or non-increasing field offset in " << entry.name << ": "
                          << entry.fields[i].name << "\n";
                return false;
            }
        }
        if (entry.fields.back().offset + entry.fields.back().size > entry.size) {
            std::cerr << "Field span out of bounds in " << entry.name << "\n";
            return false;
        }
    }
    return true;
}

} // namespace

int main() {
    // Ordering contract for byte-identical regeneration:
    // 1. Complete structs from sony2fuji_c.h in header declaration order.
    // 2. Complete structs from sony2fuji_hdr.h in header declaration order.
    // 3. Fields within each struct in C declaration order.
    const std::vector<StructLayout> structs = {
        // lutools/include/sony2fuji/ffi/sony2fuji_c.h
        {
            "sony2fuji_blob",
            sizeof(sony2fuji_blob),
            {
                ABI_FIELD(sony2fuji_blob, data),
                ABI_FIELD(sony2fuji_blob, size_bytes),
            },
        },
        {
            "sony2fuji_request",
            sizeof(sony2fuji_request),
            {
                ABI_FIELD(sony2fuji_request, version),
                ABI_FIELD(sony2fuji_request, struct_size),
                ABI_FIELD(sony2fuji_request, input_path),
                ABI_FIELD(sony2fuji_request, input_type),
                ABI_FIELD(sony2fuji_request, input_pixels),
                ABI_FIELD(sony2fuji_request, input_width),
                ABI_FIELD(sony2fuji_request, input_height),
                ABI_FIELD(sony2fuji_request, input_pixel_format),
                ABI_FIELD(sony2fuji_request, input_color_space),
                ABI_FIELD(sony2fuji_request, input_is_linear),
                ABI_FIELD(sony2fuji_request, lut_path),
                ABI_FIELD(sony2fuji_request, lut_strength),
                ABI_FIELD(sony2fuji_request, wb_mode),
                ABI_FIELD(sony2fuji_request, wb_mul),
                ABI_FIELD(sony2fuji_request, exposure_ev),
                ABI_FIELD(sony2fuji_request, brightness),
                ABI_FIELD(sony2fuji_request, contrast),
                ABI_FIELD(sony2fuji_request, saturation),
                ABI_FIELD(sony2fuji_request, temperature),
                ABI_FIELD(sony2fuji_request, tint),
                ABI_FIELD(sony2fuji_request, highlights),
                ABI_FIELD(sony2fuji_request, shadows),
                ABI_FIELD(sony2fuji_request, tone_curve),
                ABI_FIELD(sony2fuji_request, noise_reduction),
                ABI_FIELD(sony2fuji_request, sharpening),
                ABI_FIELD(sony2fuji_request, size_mode),
                ABI_FIELD(sony2fuji_request, target_width),
                ABI_FIELD(sony2fuji_request, target_height),
                ABI_FIELD(sony2fuji_request, long_edge),
                ABI_FIELD(sony2fuji_request, short_edge),
                ABI_FIELD(sony2fuji_request, output_target),
                ABI_FIELD(sony2fuji_request, output_path),
                ABI_FIELD(sony2fuji_request, output_format),
                ABI_FIELD(sony2fuji_request, jpeg_quality),
                ABI_FIELD(sony2fuji_request, intent),
                ABI_FIELD(sony2fuji_request, preview_long_edge),
            },
        },
        {
            "sony2fuji_buffer",
            sizeof(sony2fuji_buffer),
            {
                ABI_FIELD(sony2fuji_buffer, data),
                ABI_FIELD(sony2fuji_buffer, size_bytes),
                ABI_FIELD(sony2fuji_buffer, width),
                ABI_FIELD(sony2fuji_buffer, height),
                ABI_FIELD(sony2fuji_buffer, stride_bytes),
                ABI_FIELD(sony2fuji_buffer, pixel_format),
            },
        },
        {
            "sony2fuji_gpu_config",
            sizeof(sony2fuji_gpu_config),
            {
                ABI_FIELD(sony2fuji_gpu_config, version),
                ABI_FIELD(sony2fuji_gpu_config, struct_size),
                ABI_FIELD(sony2fuji_gpu_config, mode),
            },
        },
        {
            "sony2fuji_wavelet_denoise_config",
            sizeof(sony2fuji_wavelet_denoise_config),
            {
                ABI_FIELD(sony2fuji_wavelet_denoise_config, version),
                ABI_FIELD(sony2fuji_wavelet_denoise_config, struct_size),
                ABI_FIELD(sony2fuji_wavelet_denoise_config, enabled),
                ABI_FIELD(sony2fuji_wavelet_denoise_config, luma),
                ABI_FIELD(sony2fuji_wavelet_denoise_config, chroma),
                ABI_FIELD(sony2fuji_wavelet_denoise_config, coarse),
            },
        },
        {
            "sony2fuji_photo_effects_config",
            sizeof(sony2fuji_photo_effects_config),
            {
                ABI_FIELD(sony2fuji_photo_effects_config, version),
                ABI_FIELD(sony2fuji_photo_effects_config, struct_size),
                ABI_FIELD(sony2fuji_photo_effects_config, vignette_amount),
                ABI_FIELD(sony2fuji_photo_effects_config, vignette_midpoint),
                ABI_FIELD(sony2fuji_photo_effects_config, vignette_roundness),
                ABI_FIELD(sony2fuji_photo_effects_config, vignette_feather),
                ABI_FIELD(sony2fuji_photo_effects_config, vignette_highlights),
                ABI_FIELD(sony2fuji_photo_effects_config, grain_amount),
                ABI_FIELD(sony2fuji_photo_effects_config, grain_size),
                ABI_FIELD(sony2fuji_photo_effects_config, grain_roughness),
            },
        },
        {
            "sony2fuji_hsl_config",
            sizeof(sony2fuji_hsl_config),
            {
                ABI_FIELD(sony2fuji_hsl_config, version),
                ABI_FIELD(sony2fuji_hsl_config, struct_size),
                ABI_FIELD(sony2fuji_hsl_config, hue),
                ABI_FIELD(sony2fuji_hsl_config, saturation),
                ABI_FIELD(sony2fuji_hsl_config, lightness),
            },
        },
        {
            "sony2fuji_tone_controls_config",
            sizeof(sony2fuji_tone_controls_config),
            {
                ABI_FIELD(sony2fuji_tone_controls_config, version),
                ABI_FIELD(sony2fuji_tone_controls_config, struct_size),
                ABI_FIELD(sony2fuji_tone_controls_config, black_point),
                ABI_FIELD(sony2fuji_tone_controls_config, white_point),
                ABI_FIELD(sony2fuji_tone_controls_config, vibrance),
            },
        },
        {
            "sony2fuji_atmosphere_config",
            sizeof(sony2fuji_atmosphere_config),
            {
                ABI_FIELD(sony2fuji_atmosphere_config, version),
                ABI_FIELD(sony2fuji_atmosphere_config, struct_size),
                ABI_FIELD(sony2fuji_atmosphere_config, clarity),
                ABI_FIELD(sony2fuji_atmosphere_config, dehaze),
            },
        },
        {
            "sony2fuji_color_grading_config",
            sizeof(sony2fuji_color_grading_config),
            {
                ABI_FIELD(sony2fuji_color_grading_config, version),
                ABI_FIELD(sony2fuji_color_grading_config, struct_size),
                ABI_FIELD(sony2fuji_color_grading_config, shadows_hue),
                ABI_FIELD(sony2fuji_color_grading_config, shadows_saturation),
                ABI_FIELD(sony2fuji_color_grading_config, midtones_hue),
                ABI_FIELD(sony2fuji_color_grading_config, midtones_saturation),
                ABI_FIELD(sony2fuji_color_grading_config, highlights_hue),
                ABI_FIELD(sony2fuji_color_grading_config, highlights_saturation),
            },
        },
        {
            "sony2fuji_color_grading_v2_config",
            sizeof(sony2fuji_color_grading_v2_config),
            {
                ABI_FIELD(sony2fuji_color_grading_v2_config, version),
                ABI_FIELD(sony2fuji_color_grading_v2_config, struct_size),
                ABI_FIELD(sony2fuji_color_grading_v2_config, shadows_hue),
                ABI_FIELD(sony2fuji_color_grading_v2_config, shadows_saturation),
                ABI_FIELD(sony2fuji_color_grading_v2_config, shadows_luminance),
                ABI_FIELD(sony2fuji_color_grading_v2_config, midtones_hue),
                ABI_FIELD(sony2fuji_color_grading_v2_config, midtones_saturation),
                ABI_FIELD(sony2fuji_color_grading_v2_config, midtones_luminance),
                ABI_FIELD(sony2fuji_color_grading_v2_config, highlights_hue),
                ABI_FIELD(sony2fuji_color_grading_v2_config, highlights_saturation),
                ABI_FIELD(sony2fuji_color_grading_v2_config, highlights_luminance),
                ABI_FIELD(sony2fuji_color_grading_v2_config, global_hue),
                ABI_FIELD(sony2fuji_color_grading_v2_config, global_saturation),
                ABI_FIELD(sony2fuji_color_grading_v2_config, global_luminance),
                ABI_FIELD(sony2fuji_color_grading_v2_config, blending),
                ABI_FIELD(sony2fuji_color_grading_v2_config, balance),
            },
        },
        {
            "sony2fuji_curve_point",
            sizeof(sony2fuji_curve_point),
            {
                ABI_FIELD(sony2fuji_curve_point, x),
                ABI_FIELD(sony2fuji_curve_point, y),
            },
        },
        {
            "sony2fuji_tone_curve_config",
            sizeof(sony2fuji_tone_curve_config),
            {
                ABI_FIELD(sony2fuji_tone_curve_config, version),
                ABI_FIELD(sony2fuji_tone_curve_config, struct_size),
                ABI_FIELD(sony2fuji_tone_curve_config, mode),
                ABI_FIELD(sony2fuji_tone_curve_config, count),
                ABI_FIELD(sony2fuji_tone_curve_config, points),
            },
        },
        {
            "sony2fuji_tone_curve_set_config",
            sizeof(sony2fuji_tone_curve_set_config),
            {
                ABI_FIELD(sony2fuji_tone_curve_set_config, version),
                ABI_FIELD(sony2fuji_tone_curve_set_config, struct_size),
                ABI_FIELD(sony2fuji_tone_curve_set_config, curves),
            },
        },
        {
            "sony2fuji_tone_curve_parametric_config",
            sizeof(sony2fuji_tone_curve_parametric_config),
            {
                ABI_FIELD(sony2fuji_tone_curve_parametric_config, version),
                ABI_FIELD(sony2fuji_tone_curve_parametric_config, struct_size),
                ABI_FIELD(sony2fuji_tone_curve_parametric_config, highlights),
                ABI_FIELD(sony2fuji_tone_curve_parametric_config, lights),
                ABI_FIELD(sony2fuji_tone_curve_parametric_config, darks),
                ABI_FIELD(sony2fuji_tone_curve_parametric_config, shadows),
                ABI_FIELD(sony2fuji_tone_curve_parametric_config, split_shadow),
                ABI_FIELD(sony2fuji_tone_curve_parametric_config, split_midtone),
                ABI_FIELD(sony2fuji_tone_curve_parametric_config, split_highlight),
                ABI_FIELD(sony2fuji_tone_curve_parametric_config, reserved),
            },
        },
        {
            "sony2fuji_tone_curve_set_v2_config",
            sizeof(sony2fuji_tone_curve_set_v2_config),
            {
                ABI_FIELD(sony2fuji_tone_curve_set_v2_config, version),
                ABI_FIELD(sony2fuji_tone_curve_set_v2_config, struct_size),
                ABI_FIELD(sony2fuji_tone_curve_set_v2_config, apply_to_luminosity),
                ABI_FIELD(sony2fuji_tone_curve_set_v2_config, reserved),
                ABI_FIELD(sony2fuji_tone_curve_set_v2_config, curves),
                ABI_FIELD(sony2fuji_tone_curve_set_v2_config, parametric),
            },
        },
        {
            "sony2fuji_geometry_config",
            sizeof(sony2fuji_geometry_config),
            {
                ABI_FIELD(sony2fuji_geometry_config, version),
                ABI_FIELD(sony2fuji_geometry_config, struct_size),
                ABI_FIELD(sony2fuji_geometry_config, crop_x),
                ABI_FIELD(sony2fuji_geometry_config, crop_y),
                ABI_FIELD(sony2fuji_geometry_config, crop_width),
                ABI_FIELD(sony2fuji_geometry_config, crop_height),
                ABI_FIELD(sony2fuji_geometry_config, quarter_turns),
                ABI_FIELD(sony2fuji_geometry_config, flip_horizontal),
                ABI_FIELD(sony2fuji_geometry_config, flip_vertical),
                ABI_FIELD(sony2fuji_geometry_config, straighten_degrees),
            },
        },
        {
            "sony2fuji_perspective_config",
            sizeof(sony2fuji_perspective_config),
            {
                ABI_FIELD(sony2fuji_perspective_config, version),
                ABI_FIELD(sony2fuji_perspective_config, struct_size),
                ABI_FIELD(sony2fuji_perspective_config, horizontal),
                ABI_FIELD(sony2fuji_perspective_config, vertical),
            },
        },
        {
            "sony2fuji_lens_correction_config",
            sizeof(sony2fuji_lens_correction_config),
            {
                ABI_FIELD(sony2fuji_lens_correction_config, version),
                ABI_FIELD(sony2fuji_lens_correction_config, struct_size),
                ABI_FIELD(sony2fuji_lens_correction_config, distortion),
                ABI_FIELD(sony2fuji_lens_correction_config, tca),
                ABI_FIELD(sony2fuji_lens_correction_config, auto_crop),
                ABI_FIELD(sony2fuji_lens_correction_config, profile_id),
            },
        },
        {
            "sony2fuji_lens_correction_config_v2",
            sizeof(sony2fuji_lens_correction_config_v2),
            {
                ABI_FIELD(sony2fuji_lens_correction_config_v2, base),
                ABI_FIELD(sony2fuji_lens_correction_config_v2, vignetting),
            },
        },
        {
            "sony2fuji_lens_metadata",
            sizeof(sony2fuji_lens_metadata),
            {
                ABI_FIELD(sony2fuji_lens_metadata, version),
                ABI_FIELD(sony2fuji_lens_metadata, struct_size),
                ABI_FIELD(sony2fuji_lens_metadata, camera_make),
                ABI_FIELD(sony2fuji_lens_metadata, camera_model),
                ABI_FIELD(sony2fuji_lens_metadata, lens_make),
                ABI_FIELD(sony2fuji_lens_metadata, lens_model),
                ABI_FIELD(sony2fuji_lens_metadata, focal_length),
                ABI_FIELD(sony2fuji_lens_metadata, aperture),
                ABI_FIELD(sony2fuji_lens_metadata, crop_factor),
                ABI_FIELD(sony2fuji_lens_metadata, embedded_geometry),
                ABI_FIELD(sony2fuji_lens_metadata, source_orientation),
            },
        },
        {
            "sony2fuji_lens_profile",
            sizeof(sony2fuji_lens_profile),
            {
                ABI_FIELD(sony2fuji_lens_profile, id),
                ABI_FIELD(sony2fuji_lens_profile, maker),
                ABI_FIELD(sony2fuji_lens_profile, model),
                ABI_FIELD(sony2fuji_lens_profile, has_distortion),
                ABI_FIELD(sony2fuji_lens_profile, has_tca),
                ABI_FIELD(sony2fuji_lens_profile, is_match),
            },
        },
        {
            "sony2fuji_lens_report",
            sizeof(sony2fuji_lens_report),
            {
                ABI_FIELD(sony2fuji_lens_report, state),
                ABI_FIELD(sony2fuji_lens_report, camera_make),
                ABI_FIELD(sony2fuji_lens_report, camera_model),
                ABI_FIELD(sony2fuji_lens_report, lens_model),
                ABI_FIELD(sony2fuji_lens_report, focal_length),
                ABI_FIELD(sony2fuji_lens_report, profile),
                ABI_FIELD(sony2fuji_lens_report, applied_distortion),
                ABI_FIELD(sony2fuji_lens_report, applied_tca),
                ABI_FIELD(sony2fuji_lens_report, crop_scale),
            },
        },
        {
            "sony2fuji_lens_profile_v2",
            sizeof(sony2fuji_lens_profile_v2),
            {
                ABI_FIELD(sony2fuji_lens_profile_v2, base),
                ABI_FIELD(sony2fuji_lens_profile_v2, has_vignetting),
            },
        },
        {
            "sony2fuji_lens_report_v2",
            sizeof(sony2fuji_lens_report_v2),
            {
                ABI_FIELD(sony2fuji_lens_report_v2, base),
                ABI_FIELD(sony2fuji_lens_report_v2, has_vignetting),
                ABI_FIELD(sony2fuji_lens_report_v2, applied_vignetting),
            },
        },
        {
            "sony2fuji_hsl_probe_query",
            sizeof(sony2fuji_hsl_probe_query),
            {
                ABI_FIELD(sony2fuji_hsl_probe_query, version),
                ABI_FIELD(sony2fuji_hsl_probe_query, struct_size),
                ABI_FIELD(sony2fuji_hsl_probe_query, source_revision),
                ABI_FIELD(sony2fuji_hsl_probe_query, request_revision),
                ABI_FIELD(sony2fuji_hsl_probe_query, x),
                ABI_FIELD(sony2fuji_hsl_probe_query, y),
            },
        },
        {
            "sony2fuji_hsl_probe_result",
            sizeof(sony2fuji_hsl_probe_result),
            {
                ABI_FIELD(sony2fuji_hsl_probe_result, version),
                ABI_FIELD(sony2fuji_hsl_probe_result, struct_size),
                ABI_FIELD(sony2fuji_hsl_probe_result, source_revision),
                ABI_FIELD(sony2fuji_hsl_probe_result, request_revision),
                ABI_FIELD(sony2fuji_hsl_probe_result, width),
                ABI_FIELD(sony2fuji_hsl_probe_result, height),
                ABI_FIELD(sony2fuji_hsl_probe_result, availability),
                ABI_FIELD(sony2fuji_hsl_probe_result, quality),
                ABI_FIELD(sony2fuji_hsl_probe_result, rgb),
                ABI_FIELD(sony2fuji_hsl_probe_result, hsl),
                ABI_FIELD(sony2fuji_hsl_probe_result, weights),
            },
        },
        {
            "sony2fuji_ai_denoise_config",
            sizeof(sony2fuji_ai_denoise_config),
            {
                ABI_FIELD(sony2fuji_ai_denoise_config, version),
                ABI_FIELD(sony2fuji_ai_denoise_config, struct_size),
                ABI_FIELD(sony2fuji_ai_denoise_config, enabled),
                ABI_FIELD(sony2fuji_ai_denoise_config, backend),
                ABI_FIELD(sony2fuji_ai_denoise_config, model_directory),
                ABI_FIELD(sony2fuji_ai_denoise_config, cache_directory),
            },
        },
        {
            "sony2fuji_viewport_roi",
            sizeof(sony2fuji_viewport_roi),
            {
                ABI_FIELD(sony2fuji_viewport_roi, struct_size),
                ABI_FIELD(sony2fuji_viewport_roi, enabled),
                ABI_FIELD(sony2fuji_viewport_roi, norm_x0),
                ABI_FIELD(sony2fuji_viewport_roi, norm_y0),
                ABI_FIELD(sony2fuji_viewport_roi, norm_x1),
                ABI_FIELD(sony2fuji_viewport_roi, norm_y1),
                ABI_FIELD(sony2fuji_viewport_roi, max_output_long_edge),
            },
        },
        {
            "sony2fuji_viewport_roi_result",
            sizeof(sony2fuji_viewport_roi_result),
            {
                ABI_FIELD(sony2fuji_viewport_roi_result, struct_size),
                ABI_FIELD(sony2fuji_viewport_roi_result, active),
                ABI_FIELD(sony2fuji_viewport_roi_result, native_x0),
                ABI_FIELD(sony2fuji_viewport_roi_result, native_y0),
                ABI_FIELD(sony2fuji_viewport_roi_result, native_x1),
                ABI_FIELD(sony2fuji_viewport_roi_result, native_y1),
                ABI_FIELD(sony2fuji_viewport_roi_result, full_native_width),
                ABI_FIELD(sony2fuji_viewport_roi_result, full_native_height),
            },
        },
        {
            "sony2fuji_bsh_diagnose_options",
            sizeof(sony2fuji_bsh_diagnose_options),
            {
                ABI_FIELD(sony2fuji_bsh_diagnose_options, version),
                ABI_FIELD(sony2fuji_bsh_diagnose_options, struct_size),
                ABI_FIELD(sony2fuji_bsh_diagnose_options, sample_stride),
                ABI_FIELD(sony2fuji_bsh_diagnose_options, reserved),
            },
        },
        {
            "sony2fuji_bsh_hsl_channel_stats",
            sizeof(sony2fuji_bsh_hsl_channel_stats),
            {
                ABI_FIELD(sony2fuji_bsh_hsl_channel_stats, coverage_pct),
                ABI_FIELD(sony2fuji_bsh_hsl_channel_stats, mean_hue_deg),
                ABI_FIELD(sony2fuji_bsh_hsl_channel_stats, mean_sat_pct),
                ABI_FIELD(sony2fuji_bsh_hsl_channel_stats, mean_brightness_pct),
                ABI_FIELD(sony2fuji_bsh_hsl_channel_stats, active),
            },
        },
        {
            "sony2fuji_bsh_diagnosis",
            sizeof(sony2fuji_bsh_diagnosis),
            {
                ABI_FIELD(sony2fuji_bsh_diagnosis, version),
                ABI_FIELD(sony2fuji_bsh_diagnosis, struct_size),
                ABI_FIELD(sony2fuji_bsh_diagnosis, width),
                ABI_FIELD(sony2fuji_bsh_diagnosis, height),
                ABI_FIELD(sony2fuji_bsh_diagnosis, bit_depth),
                ABI_FIELD(sony2fuji_bsh_diagnosis, channels),
                ABI_FIELD(sony2fuji_bsh_diagnosis, sampled_pixels),
                ABI_FIELD(sony2fuji_bsh_diagnosis, blacks_0_10_pct),
                ABI_FIELD(sony2fuji_bsh_diagnosis, shadows_10_35_pct),
                ABI_FIELD(sony2fuji_bsh_diagnosis, midtones_35_65_pct),
                ABI_FIELD(sony2fuji_bsh_diagnosis, lights_65_90_pct),
                ABI_FIELD(sony2fuji_bsh_diagnosis, highlights_90_100_pct),
                ABI_FIELD(sony2fuji_bsh_diagnosis, mean_luma_0_1),
                ABI_FIELD(sony2fuji_bsh_diagnosis, luma_p01),
                ABI_FIELD(sony2fuji_bsh_diagnosis, luma_p05),
                ABI_FIELD(sony2fuji_bsh_diagnosis, luma_p25),
                ABI_FIELD(sony2fuji_bsh_diagnosis, luma_p50),
                ABI_FIELD(sony2fuji_bsh_diagnosis, luma_p75),
                ABI_FIELD(sony2fuji_bsh_diagnosis, luma_p95),
                ABI_FIELD(sony2fuji_bsh_diagnosis, luma_p99),
                ABI_FIELD(sony2fuji_bsh_diagnosis, dynamic_spread_p95_minus_p05),
                ABI_FIELD(sony2fuji_bsh_diagnosis, shadow_crush_pct),
                ABI_FIELD(sony2fuji_bsh_diagnosis, white_blowout_pct),
                ABI_FIELD(sony2fuji_bsh_diagnosis, channel_clip_high_any_pct),
                ABI_FIELD(sony2fuji_bsh_diagnosis, channel_clip_high_r_pct),
                ABI_FIELD(sony2fuji_bsh_diagnosis, channel_clip_high_g_pct),
                ABI_FIELD(sony2fuji_bsh_diagnosis, channel_clip_high_b_pct),
                ABI_FIELD(sony2fuji_bsh_diagnosis, neutral_midtone_coverage_pct),
                ABI_FIELD(sony2fuji_bsh_diagnosis, r_over_g),
                ABI_FIELD(sony2fuji_bsh_diagnosis, b_over_g),
                ABI_FIELD(sony2fuji_bsh_diagnosis, cast_hint),
                ABI_FIELD(sony2fuji_bsh_diagnosis, mean_s_pct),
                ABI_FIELD(sony2fuji_bsh_diagnosis, p95_s_pct),
                ABI_FIELD(sony2fuji_bsh_diagnosis, low_sat_pct),
                ABI_FIELD(sony2fuji_bsh_diagnosis, melting_saturation_pct),
                ABI_FIELD(sony2fuji_bsh_diagnosis, melting_warning),
                ABI_FIELD(sony2fuji_bsh_diagnosis, reserved),
                ABI_FIELD(sony2fuji_bsh_diagnosis, hsl_channels),
            },
        },
        {
            "sony2fuji_bsh_sample_query",
            sizeof(sony2fuji_bsh_sample_query),
            {
                ABI_FIELD(sony2fuji_bsh_sample_query, version),
                ABI_FIELD(sony2fuji_bsh_sample_query, struct_size),
                ABI_FIELD(sony2fuji_bsh_sample_query, norm_x),
                ABI_FIELD(sony2fuji_bsh_sample_query, norm_y),
                ABI_FIELD(sony2fuji_bsh_sample_query, radius_norm),
                ABI_FIELD(sony2fuji_bsh_sample_query, reserved),
            },
        },
        {
            "sony2fuji_bsh_sample_result",
            sizeof(sony2fuji_bsh_sample_result),
            {
                ABI_FIELD(sony2fuji_bsh_sample_result, version),
                ABI_FIELD(sony2fuji_bsh_sample_result, struct_size),
                ABI_FIELD(sony2fuji_bsh_sample_result, width),
                ABI_FIELD(sony2fuji_bsh_sample_result, height),
                ABI_FIELD(sony2fuji_bsh_sample_result, pixel_x),
                ABI_FIELD(sony2fuji_bsh_sample_result, pixel_y),
                ABI_FIELD(sony2fuji_bsh_sample_result, sample_count),
                ABI_FIELD(sony2fuji_bsh_sample_result, nearest_hsl_channel),
                ABI_FIELD(sony2fuji_bsh_sample_result, linear_rgb),
                ABI_FIELD(sony2fuji_bsh_sample_result, srgb_rgb),
                ABI_FIELD(sony2fuji_bsh_sample_result, hsb),
                ABI_FIELD(sony2fuji_bsh_sample_result, rgb_8bit),
            },
        },
        {
            "sony2fuji_recipe_wb_request",
            sizeof(sony2fuji_recipe_wb_request),
            {
                ABI_FIELD(sony2fuji_recipe_wb_request, version),
                ABI_FIELD(sony2fuji_recipe_wb_request, struct_size),
                ABI_FIELD(sony2fuji_recipe_wb_request, input_path),
                ABI_FIELD(sony2fuji_recipe_wb_request, processing_version),
                ABI_FIELD(sony2fuji_recipe_wb_request, x3f_mode),
                ABI_FIELD(sony2fuji_recipe_wb_request, exposure_mode),
                ABI_FIELD(sony2fuji_recipe_wb_request, recipe_active),
                ABI_FIELD(sony2fuji_recipe_wb_request, recipe_strength),
                ABI_FIELD(sony2fuji_recipe_wb_request, custom_wb),
                ABI_FIELD(sony2fuji_recipe_wb_request, temperature),
                ABI_FIELD(sony2fuji_recipe_wb_request, tint),
            },
        },
        {
            "sony2fuji_recipe_wb_result",
            sizeof(sony2fuji_recipe_wb_result),
            {
                ABI_FIELD(sony2fuji_recipe_wb_result, version),
                ABI_FIELD(sony2fuji_recipe_wb_result, struct_size),
                ABI_FIELD(sony2fuji_recipe_wb_result, wb_mode),
                ABI_FIELD(sony2fuji_recipe_wb_result, temperature),
                ABI_FIELD(sony2fuji_recipe_wb_result, tint),
                ABI_FIELD(sony2fuji_recipe_wb_result, camera_temperature),
                ABI_FIELD(sony2fuji_recipe_wb_result, camera_tint),
                ABI_FIELD(sony2fuji_recipe_wb_result, camera_calibrated),
            },
        },
        {
            "sony2fuji_wb_probe_query",
            sizeof(sony2fuji_wb_probe_query),
            {
                ABI_FIELD(sony2fuji_wb_probe_query, version),
                ABI_FIELD(sony2fuji_wb_probe_query, struct_size),
                ABI_FIELD(sony2fuji_wb_probe_query, norm_x),
                ABI_FIELD(sony2fuji_wb_probe_query, norm_y),
                ABI_FIELD(sony2fuji_wb_probe_query, window_size),
                ABI_FIELD(sony2fuji_wb_probe_query, reserved),
            },
        },
        {
            "sony2fuji_wb_probe_result",
            sizeof(sony2fuji_wb_probe_result),
            {
                ABI_FIELD(sony2fuji_wb_probe_result, version),
                ABI_FIELD(sony2fuji_wb_probe_result, struct_size),
                ABI_FIELD(sony2fuji_wb_probe_result, availability),
                ABI_FIELD(sony2fuji_wb_probe_result, valid_pixel_count),
                ABI_FIELD(sony2fuji_wb_probe_result, rejected_overexposed_count),
                ABI_FIELD(sony2fuji_wb_probe_result, temperature),
                ABI_FIELD(sony2fuji_wb_probe_result, tint),
                ABI_FIELD(sony2fuji_wb_probe_result, sampled_rgb),
                ABI_FIELD(sony2fuji_wb_probe_result, wb_mul),
                ABI_FIELD(sony2fuji_wb_probe_result, reserved),
            },
        },
        {
            "sony2fuji_processing_migration_result",
            sizeof(sony2fuji_processing_migration_result),
            {
                ABI_FIELD(sony2fuji_processing_migration_result, version),
                ABI_FIELD(sony2fuji_processing_migration_result, struct_size),
                ABI_FIELD(sony2fuji_processing_migration_result, source_version),
                ABI_FIELD(sony2fuji_processing_migration_result, target_version),
                ABI_FIELD(sony2fuji_processing_migration_result, disposition),
                ABI_FIELD(sony2fuji_processing_migration_result, evaluation_count),
                ABI_FIELD(sony2fuji_processing_migration_result, exposure_ev),
                ABI_FIELD(sony2fuji_processing_migration_result, contrast),
                ABI_FIELD(sony2fuji_processing_migration_result, highlights),
                ABI_FIELD(sony2fuji_processing_migration_result, shadows),
                ABI_FIELD(sony2fuji_processing_migration_result, saturation),
                ABI_FIELD(sony2fuji_processing_migration_result, black_point),
                ABI_FIELD(sony2fuji_processing_migration_result, white_point),
                ABI_FIELD(sony2fuji_processing_migration_result, vibrance),
                ABI_FIELD(sony2fuji_processing_migration_result, clarity),
                ABI_FIELD(sony2fuji_processing_migration_result, dehaze),
                ABI_FIELD(sony2fuji_processing_migration_result, rgb_rmse),
                ABI_FIELD(sony2fuji_processing_migration_result, p99_error),
                ABI_FIELD(sony2fuji_processing_migration_result, worst_tile_rmse),
                ABI_FIELD(sony2fuji_processing_migration_result, detail_rmse),
            },
        },

        // lutools/include/sony2fuji/ffi/sony2fuji_hdr.h
        {
            "sony2fuji_hdr_diagnostic_v1",
            sizeof(sony2fuji_hdr_diagnostic_v1),
            {
                ABI_FIELD(sony2fuji_hdr_diagnostic_v1, version),
                ABI_FIELD(sony2fuji_hdr_diagnostic_v1, struct_size),
                ABI_FIELD(sony2fuji_hdr_diagnostic_v1, reason),
                ABI_FIELD(sony2fuji_hdr_diagnostic_v1, field),
            },
        },
        {
            "sony2fuji_hdr_source_info_v1",
            sizeof(sony2fuji_hdr_source_info_v1),
            {
                ABI_FIELD(sony2fuji_hdr_source_info_v1, version),
                ABI_FIELD(sony2fuji_hdr_source_info_v1, struct_size),
                ABI_FIELD(sony2fuji_hdr_source_info_v1, width),
                ABI_FIELD(sony2fuji_hdr_source_info_v1, height),
                ABI_FIELD(sony2fuji_hdr_source_info_v1, orientation),
                ABI_FIELD(sony2fuji_hdr_source_info_v1, container),
                ABI_FIELD(sony2fuji_hdr_source_info_v1, protocol),
                ABI_FIELD(sony2fuji_hdr_source_info_v1, color_description),
                ABI_FIELD(sony2fuji_hdr_source_info_v1, content_headroom),
                ABI_FIELD(sony2fuji_hdr_source_info_v1, headroom_kind),
                ABI_FIELD(sony2fuji_hdr_source_info_v1, source_sha256),
            },
        },
        {
            "sony2fuji_hdr_camera_source_info_v1",
            sizeof(sony2fuji_hdr_camera_source_info_v1),
            {
                ABI_FIELD(sony2fuji_hdr_camera_source_info_v1, base),
                ABI_FIELD(sony2fuji_hdr_camera_source_info_v1, capabilities),
            },
        },
        {
            "sony2fuji_hdr_decode_options_v1",
            sizeof(sony2fuji_hdr_decode_options_v1),
            {
                ABI_FIELD(sony2fuji_hdr_decode_options_v1, version),
                ABI_FIELD(sony2fuji_hdr_decode_options_v1, struct_size),
                ABI_FIELD(sony2fuji_hdr_decode_options_v1, intent),
                ABI_FIELD(sony2fuji_hdr_decode_options_v1, long_edge),
            },
        },
        {
            "sony2fuji_hdr_camera_development_v1",
            sizeof(sony2fuji_hdr_camera_development_v1),
            {
                ABI_FIELD(sony2fuji_hdr_camera_development_v1, version),
                ABI_FIELD(sony2fuji_hdr_camera_development_v1, struct_size),
                ABI_FIELD(sony2fuji_hdr_camera_development_v1, white_balance),
                ABI_FIELD(sony2fuji_hdr_camera_development_v1, exposure_reference),
                ABI_FIELD(sony2fuji_hdr_camera_development_v1, temperature),
                ABI_FIELD(sony2fuji_hdr_camera_development_v1, tint),
                ABI_FIELD(sony2fuji_hdr_camera_development_v1, fbdd_level),
                ABI_FIELD(sony2fuji_hdr_camera_development_v1, lens_flags),
                ABI_FIELD(sony2fuji_hdr_camera_development_v1, lens_profile_id),
            },
        },
        {
            "sony2fuji_hdr_camera_development_v2",
            sizeof(sony2fuji_hdr_camera_development_v2),
            {
                ABI_FIELD(sony2fuji_hdr_camera_development_v2, base),
                ABI_FIELD(sony2fuji_hdr_camera_development_v2, profile_path),
                ABI_FIELD(sony2fuji_hdr_camera_development_v2, profile_sha256),
            },
        },
        {
            "sony2fuji_hdr_camera_profile_info_v1",
            sizeof(sony2fuji_hdr_camera_profile_info_v1),
            {
                ABI_FIELD(sony2fuji_hdr_camera_profile_info_v1, version),
                ABI_FIELD(sony2fuji_hdr_camera_profile_info_v1, struct_size),
                ABI_FIELD(sony2fuji_hdr_camera_profile_info_v1, camera_model),
                ABI_FIELD(sony2fuji_hdr_camera_profile_info_v1, sha256),
            },
        },
        {
            "sony2fuji_hdr_buffer_v1",
            sizeof(sony2fuji_hdr_buffer_v1),
            {
                ABI_FIELD(sony2fuji_hdr_buffer_v1, version),
                ABI_FIELD(sony2fuji_hdr_buffer_v1, struct_size),
                ABI_FIELD(sony2fuji_hdr_buffer_v1, data),
                ABI_FIELD(sony2fuji_hdr_buffer_v1, size_bytes),
                ABI_FIELD(sony2fuji_hdr_buffer_v1, width),
                ABI_FIELD(sony2fuji_hdr_buffer_v1, height),
                ABI_FIELD(sony2fuji_hdr_buffer_v1, stride_bytes),
                ABI_FIELD(sony2fuji_hdr_buffer_v1, pixel_format),
                ABI_FIELD(sony2fuji_hdr_buffer_v1, color_encoding),
                ABI_FIELD(sony2fuji_hdr_buffer_v1, content_headroom),
                ABI_FIELD(sony2fuji_hdr_buffer_v1, headroom_kind),
            },
        },
        {
            "sony2fuji_hdr_image_pair_v1",
            sizeof(sony2fuji_hdr_image_pair_v1),
            {
                ABI_FIELD(sony2fuji_hdr_image_pair_v1, version),
                ABI_FIELD(sony2fuji_hdr_image_pair_v1, struct_size),
                ABI_FIELD(sony2fuji_hdr_image_pair_v1, hdr),
                ABI_FIELD(sony2fuji_hdr_image_pair_v1, sdr),
                ABI_FIELD(sony2fuji_hdr_image_pair_v1, native_width),
                ABI_FIELD(sony2fuji_hdr_image_pair_v1, native_height),
                ABI_FIELD(sony2fuji_hdr_image_pair_v1, orientation_applied),
                ABI_FIELD(sony2fuji_hdr_image_pair_v1, source_intent),
                ABI_FIELD(sony2fuji_hdr_image_pair_v1, render_intent),
                ABI_FIELD(sony2fuji_hdr_image_pair_v1, is_proxy),
                ABI_FIELD(sony2fuji_hdr_image_pair_v1, decode_revision),
                ABI_FIELD(sony2fuji_hdr_image_pair_v1, source_headroom),
                ABI_FIELD(sony2fuji_hdr_image_pair_v1, source_headroom_kind),
                ABI_FIELD(sony2fuji_hdr_image_pair_v1, source_sha256),
                ABI_FIELD(sony2fuji_hdr_image_pair_v1, owner_token),
                ABI_FIELD(sony2fuji_hdr_image_pair_v1, output_native_width),
                ABI_FIELD(sony2fuji_hdr_image_pair_v1, output_native_height),
            },
        },
        {
            "sony2fuji_hdr_request_v1",
            sizeof(sony2fuji_hdr_request_v1),
            {
                ABI_FIELD(sony2fuji_hdr_request_v1, version),
                ABI_FIELD(sony2fuji_hdr_request_v1, struct_size),
                ABI_FIELD(sony2fuji_hdr_request_v1, hdr_processing_version),
                ABI_FIELD(sony2fuji_hdr_request_v1, intent),
                ABI_FIELD(sony2fuji_hdr_request_v1, exposure_ev),
                ABI_FIELD(sony2fuji_hdr_request_v1, temperature),
                ABI_FIELD(sony2fuji_hdr_request_v1, tint),
                ABI_FIELD(sony2fuji_hdr_request_v1, contrast),
                ABI_FIELD(sony2fuji_hdr_request_v1, highlights),
                ABI_FIELD(sony2fuji_hdr_request_v1, shadows),
                ABI_FIELD(sony2fuji_hdr_request_v1, saturation),
                ABI_FIELD(sony2fuji_hdr_request_v1, crop_x),
                ABI_FIELD(sony2fuji_hdr_request_v1, crop_y),
                ABI_FIELD(sony2fuji_hdr_request_v1, crop_width),
                ABI_FIELD(sony2fuji_hdr_request_v1, crop_height),
                ABI_FIELD(sony2fuji_hdr_request_v1, quarter_turns),
                ABI_FIELD(sony2fuji_hdr_request_v1, flip_horizontal),
                ABI_FIELD(sony2fuji_hdr_request_v1, flip_vertical),
                ABI_FIELD(sony2fuji_hdr_request_v1, straighten_degrees),
                ABI_FIELD(sony2fuji_hdr_request_v1, perspective_horizontal),
                ABI_FIELD(sony2fuji_hdr_request_v1, perspective_vertical),
                ABI_FIELD(sony2fuji_hdr_request_v1, long_edge),
            },
        },
        {
            "sony2fuji_hdr_request_v2",
            sizeof(sony2fuji_hdr_request_v2),
            {
                ABI_FIELD(sony2fuji_hdr_request_v2, base),
                ABI_FIELD(sony2fuji_hdr_request_v2, black_point),
                ABI_FIELD(sony2fuji_hdr_request_v2, white_point),
                ABI_FIELD(sony2fuji_hdr_request_v2, curve_strength),
                ABI_FIELD(sony2fuji_hdr_request_v2, reserved),
                ABI_FIELD(sony2fuji_hdr_request_v2, curve),
            },
        },
        {
            "sony2fuji_hdr_request_v3",
            sizeof(sony2fuji_hdr_request_v3),
            {
                ABI_FIELD(sony2fuji_hdr_request_v3, base),
                ABI_FIELD(sony2fuji_hdr_request_v3, vibrance),
                ABI_FIELD(sony2fuji_hdr_request_v3, reserved),
                ABI_FIELD(sony2fuji_hdr_request_v3, hsl),
                ABI_FIELD(sony2fuji_hdr_request_v3, grading),
            },
        },
        {
            "sony2fuji_hdr_request_v4",
            sizeof(sony2fuji_hdr_request_v4),
            {
                ABI_FIELD(sony2fuji_hdr_request_v4, base),
                ABI_FIELD(sony2fuji_hdr_request_v4, peak_limit_ev),
                ABI_FIELD(sony2fuji_hdr_request_v4, sdr_exposure_ev),
                ABI_FIELD(sony2fuji_hdr_request_v4, sdr_contrast),
                ABI_FIELD(sony2fuji_hdr_request_v4, sdr_saturation),
            },
        },
        {
            "sony2fuji_hdr_request_v5",
            sizeof(sony2fuji_hdr_request_v5),
            {
                ABI_FIELD(sony2fuji_hdr_request_v5, base),
                ABI_FIELD(sony2fuji_hdr_request_v5, effects),
            },
        },
        {
            "sony2fuji_hdr_request_v6",
            sizeof(sony2fuji_hdr_request_v6),
            {
                ABI_FIELD(sony2fuji_hdr_request_v6, base),
                ABI_FIELD(sony2fuji_hdr_request_v6, sharpening),
                ABI_FIELD(sony2fuji_hdr_request_v6, clarity),
                ABI_FIELD(sony2fuji_hdr_request_v6, dehaze),
                ABI_FIELD(sony2fuji_hdr_request_v6, denoise),
            },
        },
        {
            "sony2fuji_hdr_request_v7",
            sizeof(sony2fuji_hdr_request_v7),
            {
                ABI_FIELD(sony2fuji_hdr_request_v7, base),
                ABI_FIELD(sony2fuji_hdr_request_v7, look_path),
                ABI_FIELD(sony2fuji_hdr_request_v7, look_strength),
                ABI_FIELD(sony2fuji_hdr_request_v7, reserved),
                ABI_FIELD(sony2fuji_hdr_request_v7, look_sha256),
            },
        },
        {
            "sony2fuji_hdr_request_v8",
            sizeof(sony2fuji_hdr_request_v8),
            {
                ABI_FIELD(sony2fuji_hdr_request_v8, base),
                ABI_FIELD(sony2fuji_hdr_request_v8, channels),
            },
        },
        {
            "sony2fuji_hdr_request_v9",
            sizeof(sony2fuji_hdr_request_v9),
            {
                ABI_FIELD(sony2fuji_hdr_request_v9, base),
                ABI_FIELD(sony2fuji_hdr_request_v9, curve_apply_to_luminosity),
                ABI_FIELD(sony2fuji_hdr_request_v9, output_sharpening),
                ABI_FIELD(sony2fuji_hdr_request_v9, parametric_curve),
                ABI_FIELD(sony2fuji_hdr_request_v9, grading_v2),
            },
        },
        {
            "sony2fuji_hdr_look_info_v1",
            sizeof(sony2fuji_hdr_look_info_v1),
            {
                ABI_FIELD(sony2fuji_hdr_look_info_v1, version),
                ABI_FIELD(sony2fuji_hdr_look_info_v1, struct_size),
                ABI_FIELD(sony2fuji_hdr_look_info_v1, grid_size),
                ABI_FIELD(sony2fuji_hdr_look_info_v1, reserved),
                ABI_FIELD(sony2fuji_hdr_look_info_v1, domain_min),
                ABI_FIELD(sony2fuji_hdr_look_info_v1, domain_max),
                ABI_FIELD(sony2fuji_hdr_look_info_v1, sha256),
            },
        },
        {
            "sony2fuji_hdr_export_config_v1",
            sizeof(sony2fuji_hdr_export_config_v1),
            {
                ABI_FIELD(sony2fuji_hdr_export_config_v1, version),
                ABI_FIELD(sony2fuji_hdr_export_config_v1, struct_size),
                ABI_FIELD(sony2fuji_hdr_export_config_v1, jpeg_quality),
                ABI_FIELD(sony2fuji_hdr_export_config_v1, base_color),
                ABI_FIELD(sony2fuji_hdr_export_config_v1, metadata_policy),
                ABI_FIELD(sony2fuji_hdr_export_config_v1, metadata_source_path),
                ABI_FIELD(sony2fuji_hdr_export_config_v1, source_sha256),
            },
        },
        {
            "sony2fuji_hdr_sdr_export_config_v1",
            sizeof(sony2fuji_hdr_sdr_export_config_v1),
            {
                ABI_FIELD(sony2fuji_hdr_sdr_export_config_v1, version),
                ABI_FIELD(sony2fuji_hdr_sdr_export_config_v1, struct_size),
                ABI_FIELD(sony2fuji_hdr_sdr_export_config_v1, output_format),
                ABI_FIELD(sony2fuji_hdr_sdr_export_config_v1, quality),
                ABI_FIELD(sony2fuji_hdr_sdr_export_config_v1, metadata_source_path),
                ABI_FIELD(sony2fuji_hdr_sdr_export_config_v1, source_sha256),
            },
        },
        {
            "sony2fuji_hdr_stream_source_v1",
            sizeof(sony2fuji_hdr_stream_source_v1),
            {
                ABI_FIELD(sony2fuji_hdr_stream_source_v1, version),
                ABI_FIELD(sony2fuji_hdr_stream_source_v1, struct_size),
                ABI_FIELD(sony2fuji_hdr_stream_source_v1, native_width),
                ABI_FIELD(sony2fuji_hdr_stream_source_v1, native_height),
                ABI_FIELD(sony2fuji_hdr_stream_source_v1, orientation_applied),
                ABI_FIELD(sony2fuji_hdr_stream_source_v1, source_intent),
                ABI_FIELD(sony2fuji_hdr_stream_source_v1, decode_revision),
                ABI_FIELD(sony2fuji_hdr_stream_source_v1, decoder_identifier),
                ABI_FIELD(sony2fuji_hdr_stream_source_v1, source_sha256),
                ABI_FIELD(sony2fuji_hdr_stream_source_v1, context),
                ABI_FIELD(sony2fuji_hdr_stream_source_v1, read_rows),
                ABI_FIELD(sony2fuji_hdr_stream_source_v1, finish_decode),
                ABI_FIELD(sony2fuji_hdr_stream_source_v1, is_cancelled),
            },
        },
        {
            "sony2fuji_hdr_stream_result_v1",
            sizeof(sony2fuji_hdr_stream_result_v1),
            {
                ABI_FIELD(sony2fuji_hdr_stream_result_v1, version),
                ABI_FIELD(sony2fuji_hdr_stream_result_v1, struct_size),
                ABI_FIELD(sony2fuji_hdr_stream_result_v1, width),
                ABI_FIELD(sony2fuji_hdr_stream_result_v1, height),
                ABI_FIELD(sony2fuji_hdr_stream_result_v1, native_width),
                ABI_FIELD(sony2fuji_hdr_stream_result_v1, native_height),
                ABI_FIELD(sony2fuji_hdr_stream_result_v1, output_native_width),
                ABI_FIELD(sony2fuji_hdr_stream_result_v1, output_native_height),
                ABI_FIELD(sony2fuji_hdr_stream_result_v1, decode_revision),
                ABI_FIELD(sony2fuji_hdr_stream_result_v1, source_headroom),
                ABI_FIELD(sony2fuji_hdr_stream_result_v1, edited_headroom),
            },
        },
        {
            "sony2fuji_hdr_roi_v1",
            sizeof(sony2fuji_hdr_roi_v1),
            {
                ABI_FIELD(sony2fuji_hdr_roi_v1, version),
                ABI_FIELD(sony2fuji_hdr_roi_v1, struct_size),
                ABI_FIELD(sony2fuji_hdr_roi_v1, norm_x0),
                ABI_FIELD(sony2fuji_hdr_roi_v1, norm_y0),
                ABI_FIELD(sony2fuji_hdr_roi_v1, norm_x1),
                ABI_FIELD(sony2fuji_hdr_roi_v1, norm_y1),
                ABI_FIELD(sony2fuji_hdr_roi_v1, max_output_long_edge),
                ABI_FIELD(sony2fuji_hdr_roi_v1, base_content_headroom),
                ABI_FIELD(sony2fuji_hdr_roi_v1, source_x0),
                ABI_FIELD(sony2fuji_hdr_roi_v1, source_y0),
                ABI_FIELD(sony2fuji_hdr_roi_v1, full_source_width),
                ABI_FIELD(sony2fuji_hdr_roi_v1, full_source_height),
            },
        },
        {
            "sony2fuji_hdr_roi_result_v1",
            sizeof(sony2fuji_hdr_roi_result_v1),
            {
                ABI_FIELD(sony2fuji_hdr_roi_result_v1, version),
                ABI_FIELD(sony2fuji_hdr_roi_result_v1, struct_size),
                ABI_FIELD(sony2fuji_hdr_roi_result_v1, native_x0),
                ABI_FIELD(sony2fuji_hdr_roi_result_v1, native_y0),
                ABI_FIELD(sony2fuji_hdr_roi_result_v1, native_x1),
                ABI_FIELD(sony2fuji_hdr_roi_result_v1, native_y1),
                ABI_FIELD(sony2fuji_hdr_roi_result_v1, full_native_width),
                ABI_FIELD(sony2fuji_hdr_roi_result_v1, full_native_height),
                ABI_FIELD(sony2fuji_hdr_roi_result_v1, is_proxy),
            },
        },
        {
            "sony2fuji_hdr_roi_source_bounds_v1",
            sizeof(sony2fuji_hdr_roi_source_bounds_v1),
            {
                ABI_FIELD(sony2fuji_hdr_roi_source_bounds_v1, version),
                ABI_FIELD(sony2fuji_hdr_roi_source_bounds_v1, struct_size),
                ABI_FIELD(sony2fuji_hdr_roi_source_bounds_v1, source_x0),
                ABI_FIELD(sony2fuji_hdr_roi_source_bounds_v1, source_y0),
                ABI_FIELD(sony2fuji_hdr_roi_source_bounds_v1, source_x1),
                ABI_FIELD(sony2fuji_hdr_roi_source_bounds_v1, source_y1),
                ABI_FIELD(sony2fuji_hdr_roi_source_bounds_v1, native_x0),
                ABI_FIELD(sony2fuji_hdr_roi_source_bounds_v1, native_y0),
                ABI_FIELD(sony2fuji_hdr_roi_source_bounds_v1, native_x1),
                ABI_FIELD(sony2fuji_hdr_roi_source_bounds_v1, native_y1),
                ABI_FIELD(sony2fuji_hdr_roi_source_bounds_v1, full_native_width),
                ABI_FIELD(sony2fuji_hdr_roi_source_bounds_v1, full_native_height),
                ABI_FIELD(sony2fuji_hdr_roi_source_bounds_v1, output_width),
                ABI_FIELD(sony2fuji_hdr_roi_source_bounds_v1, output_height),
            },
        },
    };

    if (!validateLayouts(structs)) {
        return 1;
    }

    std::cout << "{\n"
              << "  \"version\": 1,\n"
              << "  \"fixture_version\": 3,\n"
              << "  \"source\": [\n"
              << "    \"lutools/include/sony2fuji/ffi/sony2fuji_c.h\",\n"
              << "    \"lutools/include/sony2fuji/ffi/sony2fuji_hdr.h\"\n"
              << "  ],\n"
              << "  \"structs\": [\n";

    for (size_t i = 0; i < structs.size(); ++i) {
        const auto& s = structs[i];
        std::cout << "    {\n"
                  << "      \"name\": \"" << s.name << "\",\n"
                  << "      \"size\": " << s.size << ",\n"
                  << "      \"fields\": [\n";
        for (size_t j = 0; j < s.fields.size(); ++j) {
            const auto& f = s.fields[j];
            std::cout << "        {\"name\": \"" << f.name
                      << "\", \"offset\": " << f.offset
                      << ", \"size\": " << f.size << "}"
                      << (j + 1 < s.fields.size() ? "," : "") << "\n";
        }
        std::cout << "      ]\n"
                  << "    }" << (i + 1 < structs.size() ? "," : "") << "\n";
    }

    std::cout << "  ]\n"
              << "}\n";
    return 0;
}
