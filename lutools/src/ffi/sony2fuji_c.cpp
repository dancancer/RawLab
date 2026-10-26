#include "sony2fuji/ffi/sony2fuji_c.h"

#include "sony2fuji/sony2fuji.h"
#include "sony2fuji/dcp_look.h"
#include "core/photo_rendering.h"
#include "core/chroma_denoise.h"
#include "core/wavelet_denoise.h"
#include "core/wavelet_cache.h"
#include "core/photo_effects.h"
#include "core/photo_color.h"
#include "core/photo_tone_controls.h"
#include "core/photo_atmosphere.h"
#include "core/photo_color_grading.h"
#include "core/photo_tone_curve.h"
#include "core/photo_geometry.h"
#include "core/photo_lut.h"
#include "gpu/image_stats.h"
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
#include "ai/ai_session.h"
#endif
#if defined(SONY2FUJI_ENABLE_D3D11)
#include "gpu/d3d11_photo.h"
#endif
#if defined(SONY2FUJI_ENABLE_GLES)
#include "gpu/gles_photo.h"
#endif
#if defined(SONY2FUJI_ENABLE_METAL)
#include "gpu/photo_gpu.h"
#endif

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <cctype>
#include <memory>
#include <limits>
#include <string>
#include <vector>
#include <filesystem>
#include <fstream>
#include <sys/stat.h>

struct sony2fuji_session {
    sony2fuji::GpuConfig gpu_config;
    sony2fuji::ImageData raw_cache;
    std::string raw_key;
    sony2fuji_raw_exposure_mode raw_exposure_mode = SONY2FUJI_EXPOSURE_SCENE;
    int32_t raw_noise_reduction = 0;
    int32_t chroma_denoise = 0;
    sony2fuji::ProcessingVersion processing_version = sony2fuji::ProcessingVersion::Legacy;
    sony2fuji::WaveletDenoiseOptions wavelet_denoise{false,40,46,50,sony2fuji::ProcessingVersion::Legacy};
    sony2fuji::PhotoEffectsOptions photo_effects;
    sony2fuji::HslOptions hsl;
    sony2fuji::ToneControlsOptions tone_controls;
    sony2fuji::AtmosphereOptions atmosphere;
    sony2fuji::DehazeAnalysis dehaze_analysis;
    sony2fuji::ColorGradingOptions color_grading;
    sony2fuji::ToneCurve tone_curve;
    sony2fuji::GeometryOptions geometry;
    uint32_t geometry_width = 0, geometry_height = 0;
    sony2fuji::WaveletRenderCache wavelet_cache;
    sony2fuji::LensCorrectionOptions lens_correction;
    std::shared_ptr<sony2fuji::LensCorrectionDatabase> lens_database;
    bool lens_database_tried = false;
    uint64_t lens_database_revision = 0;
    sony2fuji::LensCorrectionReport lens_report;
    sony2fuji::LensCorrectionReport raw_lens_report;
    bool raw_noise_reduction_supported = false;
    float baseline_ev = 0;
    float metadata_ev = 0;
    float as_shot_temperature = 6500, as_shot_tint = 0;
    bool calibrated_wb = false;
    std::string preview_exposure_key;
    float preview_camera_ev = 0;
    std::unique_ptr<sony2fuji::RAWProcessor> raw_processor;
    std::string processor_key;
    bool interactive_preview = false;
    bool viewport_preview = false;
    sony2fuji_render_backend last_backend = SONY2FUJI_BACKEND_CPU;
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    std::unique_ptr<sony2fuji::ai::AISession> ai;
#endif
#if defined(SONY2FUJI_ENABLE_GLES)
    std::unique_ptr<sony2fuji::GlesPhotoRenderer> gles_renderer;
#endif
#if defined(SONY2FUJI_ENABLE_D3D11)
    std::unique_ptr<sony2fuji::D3D11PhotoRenderer> d3d_renderer;
#endif
#if defined(SONY2FUJI_ENABLE_GLES) || defined(SONY2FUJI_ENABLE_D3D11)
    uint64_t raw_revision = 0;
#endif
};

struct sony2fuji_hsl_probe {
    sony2fuji::ImageData image;
    uint64_t source_revision = 0, request_revision = 0;
    sony2fuji_hsl_probe_quality quality = SONY2FUJI_HSL_PROBE_EXACT_CPU;
};

namespace sony2fuji {
WaveletCacheDiagnostics waveletCacheDiagnostics(const sony2fuji_session* session) {
    if (!session) return {};
    auto result = session->wavelet_cache.diagnostics;
    result.previewBytes = session->wavelet_cache.previewBytes();
    return result;
}
}

namespace {

// ============================================================================
// Utilities
// ============================================================================

bool isEmptyString(const char* value) {
    return value == nullptr || value[0] == '\0';
}

bool aiEnabled(const sony2fuji_session* session) {
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    return session && session->ai && session->ai->enabled;
#else
    (void)session; return false;
#endif
}

void ensureLensDatabase(sony2fuji_session* session) {
    if (!session->lens_database_tried) {
        session->lens_database_tried = true;
        session->lens_database = sony2fuji::LensCorrectionDatabase::load();
    }
}

template<size_t N> void copyLensText(char (&destination)[N], const std::string& source) {
    const size_t length = std::min(N - 1, source.size());
    std::copy_n(source.data(), length, destination);
    destination[length] = 0;
}

sony2fuji_lens_profile lensProfile(const sony2fuji::LensProfile& profile) {
    sony2fuji_lens_profile result{};
    copyLensText(result.id, profile.id); copyLensText(result.maker, profile.maker); copyLensText(result.model, profile.model);
    result.has_distortion = profile.hasDistortion; result.has_tca = profile.hasTCA; result.is_match = profile.isMatch;
    return result;
}

sony2fuji_lens_report lensReport(const sony2fuji::LensCorrectionReport& report) {
    sony2fuji_lens_report result{};
    result.state = static_cast<sony2fuji_lens_state>(report.state);
    copyLensText(result.camera_make, report.metadata.cameraMake);
    copyLensText(result.camera_model, report.metadata.cameraModel);
    copyLensText(result.lens_model, report.metadata.lensModel);
    result.focal_length = report.metadata.focalLength;
    result.profile = lensProfile(report.profile);
    result.applied_distortion = report.appliedDistortion; result.applied_tca = report.appliedTCA;
    result.crop_scale = report.cropScale;
    return result;
}


float clampFloat(float value, float low, float high) {
    return std::max(low, std::min(high, value));
}

float clamp01(float value) {
    return clampFloat(value, 0.0f, 1.0f);
}

float signedPow(float value, float power) {
    float sign = value >= 0.0f ? 1.0f : -1.0f;
    return sign * std::pow(std::abs(value), power);
}

float lerpFloat(float a, float b, float t) {
    return a + (b - a) * t;
}

sony2fuji::RGB lerpRGB(const sony2fuji::RGB& a, const sony2fuji::RGB& b, float t) {
    return sony2fuji::RGB(
        lerpFloat(a.r, b.r, t),
        lerpFloat(a.g, b.g, t),
        lerpFloat(a.b, b.b, t)
    );
}

float luminance(const sony2fuji::RGB& pixel) {
    return 0.2126f * pixel.r + 0.7152f * pixel.g + 0.0722f * pixel.b;
}

struct ToneCurvePoints {
    float p1;
    float p2;
    float p3;
};

ToneCurvePoints buildToneCurve(float tone_curve) {
    float curve_strength = signedPow(tone_curve, 1.2f);
    float lift = curve_strength * 0.2f;
    float mid = curve_strength * 0.05f;

    ToneCurvePoints points;
    points.p1 = clamp01(0.25f - lift);
    points.p2 = clamp01(0.5f + mid);
    points.p3 = clamp01(0.75f + lift);
    return points;
}

float applyToneCurve(float x, const ToneCurvePoints& curve) {
    float value = clamp01(x);
    if (value <= 0.25f) {
        return lerpFloat(0.0f, curve.p1, value / 0.25f);
    }
    if (value <= 0.5f) {
        return lerpFloat(curve.p1, curve.p2, (value - 0.25f) / 0.25f);
    }
    if (value <= 0.75f) {
        return lerpFloat(curve.p2, curve.p3, (value - 0.5f) / 0.25f);
    }
    return lerpFloat(curve.p3, 1.0f, (value - 0.75f) / 0.25f);
}

float adjustShadows(float value, float shadows) {
    if (shadows == 0.0f) {
        return value;
    }
    float t = clampFloat(shadows, -1.0f, 1.0f);
    float gamma = t > 0.0f ? (1.0f - t * 0.5f) : (1.0f + (-t) * 0.5f);
    return std::pow(clamp01(value), gamma);
}

float adjustHighlights(float value, float highlights) {
    if (highlights == 0.0f) {
        return value;
    }
    float t = clampFloat(highlights, -1.0f, 1.0f);
    float inv = 1.0f - clamp01(value);
    float gamma = t > 0.0f ? (1.0f - t * 0.5f) : (1.0f + (-t) * 0.5f);
    return 1.0f - std::pow(inv, gamma);
}

float applyHighlightsShadows(float value, float highlights, float shadows) {
    float shadowed = adjustShadows(value, shadows);
    return adjustHighlights(shadowed, highlights);
}

sony2fuji::RGB normalizeWhiteBalance(float r, float g, float b) {
    float max_value = std::max(r, std::max(g, b));
    if (max_value <= 0.0f) {
        return sony2fuji::RGB(1.0f, 1.0f, 1.0f);
    }
    return sony2fuji::RGB(r / max_value, g / max_value, b / max_value);
}

sony2fuji::RGB temperatureToRGB(float temperature) {
    float temp = clampFloat(temperature, 1000.0f, 40000.0f) / 100.0f;
    float r;
    float g;
    float b;

    if (temp <= 66.0f) {
        r = 1.0f;
        g = clamp01(0.3900816f * std::log(temp) - 0.6318414f);
        if (temp <= 19.0f) {
            b = 0.0f;
        } else {
            b = clamp01(0.5432068f * std::log(temp - 10.0f) - 1.1962541f);
        }
    } else {
        r = clamp01(1.2929362f * std::pow(temp - 60.0f, -0.1332048f));
        g = clamp01(1.1298909f * std::pow(temp - 60.0f, -0.0755148f));
        b = 1.0f;
    }

    return normalizeWhiteBalance(r, g, b);
}

sony2fuji::RGB applyTint(const sony2fuji::RGB& base, float tint) {
    float t = clampFloat(tint / 100.0f, -1.0f, 1.0f);
    float g = base.g * (1.0f + t * 0.1f);
    return normalizeWhiteBalance(base.r, g, base.b);
}

sony2fuji::RGB whiteBalanceForTempTint(float temperature, float tint) {
    if (temperature <= 0.0f) {
        return sony2fuji::RGB(1.0f, 1.0f, 1.0f);
    }
    return applyTint(temperatureToRGB(temperature), tint);
}

void applyExposureAndWhiteBalance(
    sony2fuji::RGB& pixel,
    float exposure_scale,
    const sony2fuji::RGB& wb
) {
    pixel.r *= exposure_scale * wb.r;
    pixel.g *= exposure_scale * wb.g;
    pixel.b *= exposure_scale * wb.b;
}

void applyHighlightsShadowsToPixel(
    sony2fuji::RGB& pixel,
    float highlights,
    float shadows
) {
    float l = luminance(pixel);
    float adjusted = applyHighlightsShadows(l, highlights, shadows);
    if (l > 0.0f) {
        float ratio = adjusted / l;
        pixel.r *= ratio;
        pixel.g *= ratio;
        pixel.b *= ratio;
        return;
    }
    pixel.r = adjusted;
    pixel.g = adjusted;
    pixel.b = adjusted;
}

void applyContrastSaturation(
    sony2fuji::RGB& pixel,
    float contrast,
    float saturation
) {
    pixel.r = (pixel.r - 0.5f) * contrast + 0.5f;
    pixel.g = (pixel.g - 0.5f) * contrast + 0.5f;
    pixel.b = (pixel.b - 0.5f) * contrast + 0.5f;

    float l = luminance(pixel);
    pixel.r = l + (pixel.r - l) * saturation;
    pixel.g = l + (pixel.g - l) * saturation;
    pixel.b = l + (pixel.b - l) * saturation;
}

bool needsToneAdjustments(const sony2fuji_request& request) {
    if (request.exposure_ev != 0.0f || request.brightness != 1.0f) {
        return true;
    }
    if (request.contrast != 1.0f || request.saturation != 1.0f) {
        return true;
    }
    if (request.temperature != 6500.0f || request.tint != 0.0f) {
        return true;
    }
    if (request.wb_mode == SONY2FUJI_WB_CUSTOM) {
        return true;
    }
    if (request.highlights != 0.0f || request.shadows != 0.0f) {
        return true;
    }
    return request.tone_curve != 0.0f;
}
sony2fuji_status mapError(sony2fuji::ErrorCode code) {
    switch (code) {
        case sony2fuji::ErrorCode::Success:
            return SONY2FUJI_STATUS_OK;
        case sony2fuji::ErrorCode::FileNotFound:
            return SONY2FUJI_STATUS_IO_ERROR;
        case sony2fuji::ErrorCode::IOError:
            return SONY2FUJI_STATUS_OUTPUT_IO_ERROR;
        case sony2fuji::ErrorCode::ParseError:
        case sony2fuji::ErrorCode::InvalidFormat:
            return SONY2FUJI_STATUS_UNSUPPORTED;
        case sony2fuji::ErrorCode::OutOfMemory:
            return SONY2FUJI_STATUS_OUT_OF_MEMORY;
        case sony2fuji::ErrorCode::ProcessingError:
        default:
            return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

sony2fuji::ColorSpace toCoreColorSpace(sony2fuji_color_space space) {
    switch (space) {
        case SONY2FUJI_COLOR_FGAMUT:
            return sony2fuji::ColorSpace::FujiFilm_FGamut;
        case SONY2FUJI_COLOR_SONY_NATIVE:
            return sony2fuji::ColorSpace::SonyNative;
        case SONY2FUJI_COLOR_ACESCG:
            return sony2fuji::ColorSpace::ACEScg;
        case SONY2FUJI_COLOR_ADOBE_RGB:
            return sony2fuji::ColorSpace::AdobeRGB;
        case SONY2FUJI_COLOR_SRGB:
        default:
            return sony2fuji::ColorSpace::sRGB;
    }
}

sony2fuji::GpuMode toCoreGpuMode(sony2fuji_gpu_mode mode) {
    switch (mode) {
        case SONY2FUJI_GPU_AUTO:
            return sony2fuji::GpuMode::Auto;
        case SONY2FUJI_GPU_FORCE:
            return sony2fuji::GpuMode::Force;
        case SONY2FUJI_GPU_OFF:
        default:
            return sony2fuji::GpuMode::Off;
    }
}

sony2fuji_status validateRequest(
    const sony2fuji_request* request,
    const sony2fuji_buffer* out_buffer
) {
    if (!request) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }

    if (request->version != SONY2FUJI_REQUEST_VERSION) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }

    if (request->struct_size < sizeof(sony2fuji_request)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    const float controls[] = {request->exposure_ev, request->brightness, request->contrast,
        request->saturation, request->temperature, request->tint, request->lut_strength,
        request->highlights, request->shadows, request->tone_curve, request->noise_reduction,
        request->sharpening};
    for (float value : controls)
        if (!std::isfinite(value)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    if (std::abs(request->exposure_ev) > 20 || request->brightness <= 0)
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    if (request->wb_mode == SONY2FUJI_WB_TEMPERATURE &&
        (request->input_type != SONY2FUJI_INPUT_RAW || request->temperature < 2000 ||
         request->temperature > 50000 || std::abs(request->tint) > 150))
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    if (request->wb_mode == SONY2FUJI_WB_CUSTOM) {
        for (int c=0; c<3; ++c)
            if (!std::isfinite(request->wb_mul[c]) || request->wb_mul[c] <= 0)
                return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }

    if (request->input_type == SONY2FUJI_INPUT_RAW) {
        if (isEmptyString(request->input_path)) {
            return SONY2FUJI_STATUS_INVALID_ARGUMENT;
        }
    } else if (request->input_type == SONY2FUJI_INPUT_BUFFER || request->input_type == SONY2FUJI_INPUT_DISPLAY_BUFFER) {
        if (!request->input_pixels || request->input_width == 0 || request->input_height == 0) {
            return SONY2FUJI_STATUS_INVALID_ARGUMENT;
        }
        if (request->input_type == SONY2FUJI_INPUT_DISPLAY_BUFFER &&
            (request->input_color_space != SONY2FUJI_COLOR_SRGB || request->input_is_linear != 0 ||
             request->wb_mode != SONY2FUJI_WB_CAMERA || request->temperature != 6500 || request->tint != 0))
            return SONY2FUJI_STATUS_UNSUPPORTED;
    } else {
        return SONY2FUJI_STATUS_UNSUPPORTED;
    }

    if (request->output_target == SONY2FUJI_TARGET_FILE) {
        if (isEmptyString(request->output_path)) {
            return SONY2FUJI_STATUS_INVALID_ARGUMENT;
        }
        const auto overwrites = [&](const char* source) {
            std::error_code error;
            const auto inputPath = std::filesystem::u8path(source);
            const auto outputPath = std::filesystem::u8path(request->output_path);
            return std::filesystem::equivalent(inputPath, outputPath, error) ||
                std::filesystem::weakly_canonical(inputPath) == std::filesystem::weakly_canonical(outputPath);
        };
        if (((request->input_type == SONY2FUJI_INPUT_RAW || request->input_type == SONY2FUJI_INPUT_DISPLAY_BUFFER) &&
             !isEmptyString(request->input_path) && overwrites(request->input_path)) ||
            (!isEmptyString(request->lut_path) && overwrites(request->lut_path)))
            return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    } else if (request->output_target == SONY2FUJI_TARGET_BUFFER) {
        if (!out_buffer) {
            return SONY2FUJI_STATUS_INVALID_ARGUMENT;
        }
    } else {
        return SONY2FUJI_STATUS_UNSUPPORTED;
    }

    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status validateGpuConfig(const sony2fuji_gpu_config* config) {
    if (!config) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    if (config->version != SONY2FUJI_GPU_CONFIG_VERSION) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    if (config->struct_size < sizeof(sony2fuji_gpu_config)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status validateOutputFormat(const sony2fuji_request& request) {
    if (request.output_format == SONY2FUJI_OUTPUT_DNG &&
        request.intent != SONY2FUJI_INTENT_FINAL) {
        return SONY2FUJI_STATUS_UNSUPPORTED;
    }
    if (request.output_target == SONY2FUJI_TARGET_FILE) {
        if (request.output_format == SONY2FUJI_OUTPUT_JPEG ||
            request.output_format == SONY2FUJI_OUTPUT_PNG ||
            request.output_format == SONY2FUJI_OUTPUT_DNG) {
            return SONY2FUJI_STATUS_OK;
        }
        return SONY2FUJI_STATUS_UNSUPPORTED;
    }

    if (request.output_format == SONY2FUJI_OUTPUT_RGB8 ||
        request.output_format == SONY2FUJI_OUTPUT_RGBA8) {
        return SONY2FUJI_STATUS_OK;
    }

    return SONY2FUJI_STATUS_UNSUPPORTED;
}

sony2fuji_status computeTargetSize(
    const sony2fuji_request& request,
    uint32_t src_width,
    uint32_t src_height,
    uint32_t* out_width,
    uint32_t* out_height
) {
    if (!out_width || !out_height || src_width == 0 || src_height == 0) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }

    sony2fuji_size_mode mode = request.size_mode;
    uint32_t long_edge = request.long_edge;
    uint32_t short_edge = request.short_edge;

    if (request.intent == SONY2FUJI_INTENT_PREVIEW && request.preview_long_edge > 0) {
        mode = SONY2FUJI_SIZE_FIT_LONG_EDGE;
        long_edge = request.preview_long_edge;
    }

    switch (mode) {
        case SONY2FUJI_SIZE_NATIVE:
            *out_width = src_width;
            *out_height = src_height;
            return SONY2FUJI_STATUS_OK;
        case SONY2FUJI_SIZE_EXACT:
            if (request.target_width == 0 || request.target_height == 0) {
                return SONY2FUJI_STATUS_INVALID_ARGUMENT;
            }
            *out_width = request.target_width;
            *out_height = request.target_height;
            return SONY2FUJI_STATUS_OK;
        case SONY2FUJI_SIZE_FIT_LONG_EDGE:
        case SONY2FUJI_SIZE_LIMIT_LONG_EDGE: {
            if (long_edge == 0) {
                return SONY2FUJI_STATUS_INVALID_ARGUMENT;
            }
            uint32_t max_edge = std::max(src_width, src_height);
            float scale = static_cast<float>(long_edge) / static_cast<float>(max_edge);
            if (mode == SONY2FUJI_SIZE_LIMIT_LONG_EDGE) scale = std::min(1.0f, scale);
            *out_width = std::max(1u, static_cast<uint32_t>(std::round(src_width * scale)));
            *out_height = std::max(1u, static_cast<uint32_t>(std::round(src_height * scale)));
            return SONY2FUJI_STATUS_OK;
        }
        case SONY2FUJI_SIZE_FIT_SHORT_EDGE: {
            if (short_edge == 0) {
                return SONY2FUJI_STATUS_INVALID_ARGUMENT;
            }
            uint32_t min_edge = std::min(src_width, src_height);
            float scale = static_cast<float>(short_edge) / static_cast<float>(min_edge);
            *out_width = std::max(1u, static_cast<uint32_t>(std::round(src_width * scale)));
            *out_height = std::max(1u, static_cast<uint32_t>(std::round(src_height * scale)));
            return SONY2FUJI_STATUS_OK;
        }
        default:
            return SONY2FUJI_STATUS_UNSUPPORTED;
    }
}

sony2fuji::RGB sampleBilinear(const sony2fuji::ImageData& image, float x, float y) {
    int x0 = static_cast<int>(std::floor(x));
    int y0 = static_cast<int>(std::floor(y));
    int x1 = std::min(x0 + 1, image.width - 1);
    int y1 = std::min(y0 + 1, image.height - 1);

    float tx = x - static_cast<float>(x0);
    float ty = y - static_cast<float>(y0);

    const sony2fuji::RGB& c00 = image.at(x0, y0);
    const sony2fuji::RGB& c10 = image.at(x1, y0);
    const sony2fuji::RGB& c01 = image.at(x0, y1);
    const sony2fuji::RGB& c11 = image.at(x1, y1);

    sony2fuji::RGB cx0 = lerpRGB(c00, c10, tx);
    sony2fuji::RGB cx1 = lerpRGB(c01, c11, tx);

    return lerpRGB(cx0, cx1, ty);
}

sony2fuji::ImageData resizeBilinear(
    const sony2fuji::ImageData& source,
    uint32_t target_width,
    uint32_t target_height
) {
    sony2fuji::ImageData output(static_cast<int>(target_width), static_cast<int>(target_height));

    if (source.width == 0 || source.height == 0) {
        return output;
    }

    float scale_x = (target_width == 1)
        ? 0.0f
        : static_cast<float>(source.width - 1) / static_cast<float>(target_width - 1);
    float scale_y = (target_height == 1)
        ? 0.0f
        : static_cast<float>(source.height - 1) / static_cast<float>(target_height - 1);

    for (uint32_t y = 0; y < target_height; ++y) {
        float src_y = static_cast<float>(y) * scale_y;
        for (uint32_t x = 0; x < target_width; ++x) {
            float src_x = static_cast<float>(x) * scale_x;
            output.pixels[static_cast<size_t>(y) * target_width + x] = sampleBilinear(source, src_x, src_y);
        }
    }

    return output;
}

void applyToneAdjustments(sony2fuji::ImageData& image, const sony2fuji_request& request,
    const sony2fuji::ToneCurve& customCurve) {
    if (!needsToneAdjustments(request) && !customCurve.active()) {
        return;
    }

    float exposure_scale = 1.0f;
    float contrast = clampFloat(request.contrast, 0.0f, 2.0f);
    float saturation = clampFloat(request.saturation, 0.0f, 2.0f);
    float highlights = clampFloat(request.highlights, -1.0f, 1.0f);
    float shadows = clampFloat(request.shadows, -1.0f, 1.0f);
    bool use_curve = request.tone_curve != 0.0f;
    ToneCurvePoints curve = buildToneCurve(request.tone_curve);
    sony2fuji::RGB wb(1, 1, 1);

    for (auto& pixel : image.pixels) {
        applyExposureAndWhiteBalance(pixel, exposure_scale, wb);
        if (highlights != 0.0f || shadows != 0.0f) {
            applyHighlightsShadowsToPixel(pixel, highlights, shadows);
        }
        if (customCurve.active()) {
            pixel.r = static_cast<float>(customCurve.evaluate(pixel.r));
            pixel.g = static_cast<float>(customCurve.evaluate(pixel.g));
            pixel.b = static_cast<float>(customCurve.evaluate(pixel.b));
        } else if (use_curve) {
            pixel.r = applyToneCurve(pixel.r, curve);
            pixel.g = applyToneCurve(pixel.g, curve);
            pixel.b = applyToneCurve(pixel.b, curve);
        }
        if (contrast != 1.0f || saturation != 1.0f) {
            applyContrastSaturation(pixel, contrast, saturation);
        }
    }
}

// 保存两行原像素，避免已写回的行进入下一行的 3x3 邻域。
template <typename Apply>
void applyBlurredDetail(sony2fuji::ImageData& image, Apply apply) {
    const int width = image.width, height = image.height;
    if (width <= 0 || height <= 0) return;
    std::vector<sony2fuji::RGB> previous(width), current(width);
    std::copy_n(image.pixels.data(), width, previous.data());
    const auto sumRow = [](const sony2fuji::RGB* row, int a, int b, int c) {
        return sony2fuji::RGB(row[a].r + row[b].r + row[c].r,
            row[a].g + row[b].g + row[c].g, row[a].b + row[b].b + row[c].b);
    };
    for (int y = 0; y < height; ++y) {
        auto* destination = image.pixels.data() + size_t(y) * width;
        std::copy_n(destination, width, current.data());
        const auto* next = y + 1 < height ? destination + width : current.data();
        for (int x = 0; x < width; ++x) {
            const int a = std::max(0, x - 1), c = std::min(width - 1, x + 1);
            auto sum = sumRow(previous.data(), a, x, c);
            const auto middle = sumRow(current.data(), a, x, c);
            const auto bottom = sumRow(next, a, x, c);
            sum.r += middle.r + bottom.r;
            sum.g += middle.g + bottom.g;
            sum.b += middle.b + bottom.b;
            destination[x] = apply(current[x], sony2fuji::RGB(sum.r / 9.0f, sum.g / 9.0f, sum.b / 9.0f));
        }
        previous.swap(current);
    }
}

void applyNoiseReduction(sony2fuji::ImageData& image, float amount) {
    const float strength = clampFloat(amount, 0.0f, 1.0f);
    if (strength <= 0.0f) return;
    applyBlurredDetail(image, [strength](const auto& current, const auto& blur) {
        return lerpRGB(current, blur, strength * 0.4f);
    });
}

void applySharpening(sony2fuji::ImageData& image, float amount) {
    const float strength = clampFloat(amount, 0.0f, 2.0f);
    if (strength <= 0.0f) return;
    applyBlurredDetail(image, [strength](const auto& current, const auto& blur) {
        return sony2fuji::RGB(clamp01(current.r + strength * (current.r - blur.r)),
            clamp01(current.g + strength * (current.g - blur.g)),
            clamp01(current.b + strength * (current.b - blur.b)));
    });
}

void applyDetailAdjustments(sony2fuji::ImageData& image, const sony2fuji_request& request, float clarity) {
    if (request.noise_reduction > 0.0f) {
        applyNoiseReduction(image, request.noise_reduction);
    }
    sony2fuji::applyClarity(image, clarity);
    if (request.sharpening > 0.0f) {
        applySharpening(image, request.sharpening);
    }
}

bool isLutDiagnosticsEnabled() {
    const char* value = std::getenv("SONY2FUJI_LUT_DIAG");
    return value != nullptr && value[0] != '\0';
}

void logFLog2Diagnostics(const sony2fuji::GammaConverter::FLog2Diagnostics& diagnostics) {
    std::fprintf(stderr,
        "F-Log2 diagnostics: min=%f max=%f scale=%f offset=%f neg=%zu over=%zu\n",
        diagnostics.min_linear, diagnostics.max_linear, diagnostics.scale, diagnostics.offset,
        diagnostics.negative_pixels, diagnostics.over_pixels);
}

void applyFLog2Encoding(sony2fuji::ImageData& image, bool clamp_only,
    sony2fuji::GammaConverter::FLog2Diagnostics* total = nullptr) {
    sony2fuji::GammaConverter::FLog2Options options;
    options.normalizeToRange = !clamp_only;
    options.clampOnly = clamp_only;
    options.enableDiagnostics = isLutDiagnosticsEnabled();

    sony2fuji::GammaConverter::FLog2Diagnostics diagnostics =
        sony2fuji::GammaConverter::applyFLog2ToImage(image, options);
    if (options.enableDiagnostics) {
        if (total) {
            total->min_linear = std::min(total->min_linear, diagnostics.min_linear);
            total->max_linear = std::max(total->max_linear, diagnostics.max_linear);
            total->negative_pixels += diagnostics.negative_pixels;
            total->over_pixels += diagnostics.over_pixels;
        } else logFLog2Diagnostics(diagnostics);
    }
}

sony2fuji_status applyPhotoLook(sony2fuji::ImageData& image,
    const std::shared_ptr<sony2fuji::LUT3D>& lut, const std::shared_ptr<const sony2fuji::DcpLook>& dcp,
    float strength, bool displayInput, const sony2fuji::GpuConfig& config) {
    const auto encode = displayInput ? sony2fuji::GammaConverter::applySRGBGamma : sony2fuji::neutralDisplay;
    if (!lut && !dcp) {
        for (auto& p : image.pixels) p = sony2fuji::RGB(encode(p.r), encode(p.g), encode(p.b));
        return SONY2FUJI_STATUS_OK;
    }
    sony2fuji::GammaConverter::FLog2Diagnostics diagnostics;
    diagnostics.min_linear = std::numeric_limits<float>::max();
    diagnostics.max_linear = std::numeric_limits<float>::lowest();
    const bool diagnosticBlocks = config.mode == sony2fuji::GpuMode::Off && lut &&
        lut->inputTransfer() == sony2fuji::LUTTransfer::FLog2 && isLutDiagnosticsEnabled();
    auto render = [&](sony2fuji::ImageData& working) {
        auto base = working;
        for (auto& p : base.pixels) p = sony2fuji::RGB(encode(p.r), encode(p.g), encode(p.b));
        if (dcp) {
            const size_t count = working.pixels.size();
#ifdef _OPENMP
#pragma omp parallel for if (count >= (1u << 16))
#endif
            for (size_t i = 0; i < count; ++i) working.pixels[i] = dcp->apply(working.pixels[i]);
        } else {
            if (lut->inputTransfer() == sony2fuji::LUTTransfer::SRGB) working = base;
            else if (lut->inputTransfer() != sony2fuji::LUTTransfer::FLog2)
                sony2fuji::encodePhotoLUTInput(working, lut->inputTransfer());
            else {
                sony2fuji::ColorConverter().convertImage(working, sony2fuji::ColorSpace::sRGB, sony2fuji::ColorSpace::FujiFilm_FGamut);
                applyFLog2Encoding(working, false, diagnosticBlocks ? &diagnostics : nullptr);
            }
            const auto result = sony2fuji::applyLUTWithConfig(lut, working, config);
            if (result != sony2fuji::ErrorCode::Success) return mapError(result);
            sony2fuji::renderPhotoLUTOutput(working, lut->outputTransfer());
        }
        for (size_t i = 0; i < working.pixels.size(); ++i)
            working.pixels[i] = lerpRGB(base.pixels[i], working.pixels[i], strength);
        return SONY2FUJI_STATUS_OK;
    };
    // 独立 LUT GPU 仍以整次调用为事务；CPU 混合只保留两块各 3 MiB 的工作区。
    if (config.mode != sony2fuji::GpuMode::Off) return render(image);
    constexpr size_t blockPixels = 1u << 18;
    sony2fuji::ImageData block;
    block.height = 1;
    for (size_t first = 0; first < image.pixels.size(); first += blockPixels) {
        const size_t count = std::min(blockPixels, image.pixels.size() - first);
        block.width = static_cast<int>(count);
        block.pixels.assign(image.pixels.begin() + first, image.pixels.begin() + first + count);
        const auto status = render(block);
        if (status != SONY2FUJI_STATUS_OK) return status;
        std::copy(block.pixels.begin(), block.pixels.end(), image.pixels.begin() + first);
    }
    if (diagnosticBlocks) logFLog2Diagnostics(diagnostics);
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status ensureLinear(
    sony2fuji::ImageData& image,
    sony2fuji_color_space space,
    bool* is_linear
) {
    if (!is_linear || *is_linear) {
        return SONY2FUJI_STATUS_OK;
    }

    if (space != SONY2FUJI_COLOR_SRGB) {
        return SONY2FUJI_STATUS_UNSUPPORTED;
    }

    for (auto& pixel : image.pixels) {
        pixel.r = sony2fuji::GammaConverter::removeSRGBGamma(pixel.r);
        pixel.g = sony2fuji::GammaConverter::removeSRGBGamma(pixel.g);
        pixel.b = sony2fuji::GammaConverter::removeSRGBGamma(pixel.b);
    }

    *is_linear = true;
    return SONY2FUJI_STATUS_OK;
}


sony2fuji_status loadLUT(
    const char* lut_path,
    std::shared_ptr<sony2fuji::LUT3D>* out_lut
) {
    if (!out_lut || isEmptyString(lut_path)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }

    auto lut = sony2fuji::LUTParser::loadLUTCached(lut_path);
    if (!lut) {
        return SONY2FUJI_STATUS_UNSUPPORTED;
    }

    *out_lut = lut;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji::RAWProcessOptions rawWhiteBalanceOptions(const sony2fuji_session* session, const sony2fuji_request& request) {
    sony2fuji::RAWProcessOptions options;
    options.bayerDemosaic = session->processing_version == sony2fuji::ProcessingVersion::Legacy ?
        sony2fuji::BayerDemosaicMethod::Legacy : sony2fuji::BayerDemosaicMethod::VNG;
    options.useCameraWhiteBalance = request.wb_mode == SONY2FUJI_WB_CAMERA;
    options.useAutoWhiteBalance = request.wb_mode == SONY2FUJI_WB_AUTO;
    options.useCustomWhiteBalance = request.wb_mode == SONY2FUJI_WB_CUSTOM;
    options.useTemperatureWhiteBalance = request.wb_mode == SONY2FUJI_WB_TEMPERATURE;
    options.temperature = request.temperature; options.tint = request.tint;
    std::copy(std::begin(request.wb_mul), std::end(request.wb_mul), options.customWhiteBalance);
    options.lensDatabase = session->lens_database;
    options.lensCorrection = session->lens_correction;
    return options;
}

sony2fuji_status loadRawImage(
    sony2fuji_session* session, const sony2fuji_request& request,
    sony2fuji::ImageData& image, sony2fuji_color_space* space, bool* is_linear,
    bool copyImage = true, bool applyAI = true
) {
    std::error_code fileError;
    const auto inputPath = std::filesystem::u8path(request.input_path);
    const auto modified = std::filesystem::last_write_time(inputPath, fileError);
    if (fileError) return SONY2FUJI_STATUS_IO_ERROR;
    const auto fileSize = std::filesystem::file_size(inputPath, fileError);
    if (fileError) return SONY2FUJI_STATUS_IO_ERROR;
    const auto modifiedNanoseconds = std::chrono::duration_cast<std::chrono::nanoseconds>(
        modified.time_since_epoch()).count();
    std::string fileKey = std::string(request.input_path) + ":" +
        std::to_string(modifiedNanoseconds) + ":" + std::to_string(fileSize);
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    const auto aiSourceIdentity = aiEnabled(session) ? sony2fuji::ai::sourceIdentityKey(request.input_path) : std::string();
    if (aiEnabled(session)) fileKey += ":ai-source:" + aiSourceIdentity;
#endif
    const bool useAI = applyAI && aiEnabled(session);
    const int rawNoiseReduction = aiEnabled(session) ? 0 : session->raw_noise_reduction;
    if (session->lens_correction.active()) ensureLensDatabase(session);
    auto wbOptions = rawWhiteBalanceOptions(session, request);
    std::string aiKey;
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    if (useAI) aiKey = ":ai:" + session->ai->renderKey(request.input_path, wbOptions, aiSourceIdentity);
#endif
    const bool interactive = !useAI && session->interactive_preview && session->raw_noise_reduction == 0 && session->chroma_denoise == 0 &&
        !session->photo_effects.active() &&
        request.intent == SONY2FUJI_INTENT_PREVIEW &&
        request.output_target == SONY2FUJI_TARGET_BUFFER &&
        !(session->raw_exposure_mode == SONY2FUJI_EXPOSURE_PREVIEW && request.wb_mode == SONY2FUJI_WB_CAMERA);
    const std::string processingKey = ":processing:" + std::to_string(static_cast<int>(session->processing_version));
    std::string key = fileKey + processingKey + ":" + std::to_string(request.wb_mode) +
        ":" + std::to_string(session->raw_exposure_mode) + ":" + std::to_string(rawNoiseReduction);
    for (float multiplier : request.wb_mul) key += ":" + std::to_string(multiplier);
    key += aiKey;
    if (request.wb_mode == SONY2FUJI_WB_TEMPERATURE)
        key += ":" + std::to_string(request.temperature) + ":" + std::to_string(request.tint);
    std::string lensKey;
    if (session->lens_correction.active()) {
        ensureLensDatabase(session);
        lensKey = ":lens:" + std::to_string(session->lens_database_revision) + ":" +
            std::to_string(session->lens_correction.distortion) + ":" + std::to_string(session->lens_correction.tca) + ":" +
            std::to_string(session->lens_correction.autoCrop) + ":" + session->lens_correction.profileID;
    }
    key += lensKey;
    // AI 沿用原片的拍摄白平衡预览锚点，不能因去噪/改 WB 再次改变基础曝光。
    const std::string previewExposureKey = fileKey + processingKey + lensKey;
    // A full-quality cache can serve a proxy, but never the reverse. Non-WB
    // sliders should not trigger another demosaic just because dragging began.
    const std::string exactKey = key + ":exact";
    key += interactive && session->raw_key != exactKey ? ":interactive" : ":exact";
    if (session->raw_key != key || session->raw_cache.pixels.empty()) {
        const bool anchoredPreview = session->raw_exposure_mode == SONY2FUJI_EXPOSURE_PREVIEW &&
            (request.wb_mode == SONY2FUJI_WB_TEMPERATURE || useAI);
        if (anchoredPreview && session->preview_exposure_key != previewExposureKey) {
            auto reference = request;
            reference.wb_mode = SONY2FUJI_WB_CAMERA;
            const auto status = loadRawImage(session, reference, image, space, is_linear, false, false);
            image = {};
            if (status != SONY2FUJI_STATUS_OK) return status;
        }
        // 失效的整图缓存必须在下一次解码之前释放，WB/照片切换不能叠加两张 RAW。
        session->raw_cache = {};
        session->raw_key.clear();
        if (!session->raw_processor || session->processor_key != fileKey) {
            session->raw_processor.reset();
            session->processor_key.clear();
            auto processor = std::make_unique<sony2fuji::RAWProcessor>();
            const auto loaded = processor->loadFile(request.input_path);
            if (loaded != sony2fuji::ErrorCode::Success) return mapError(loaded);
            session->raw_processor = std::move(processor);
            session->processor_key = fileKey;
        }
        auto& processor = *session->raw_processor;
        auto options = wbOptions;
        options.halfSize = interactive;
        options.rawNoiseReduction = rawNoiseReduction;
        options.outputLinear = true;
        options.outputAdobe = true;
        options.lensDatabase = session->lens_database;
        options.lensCorrection = session->lens_correction;
        options.matchEmbeddedPreviewExposure = session->raw_exposure_mode == SONY2FUJI_EXPOSURE_PREVIEW && !anchoredPreview;
        options.applyBaselineExposure = session->raw_exposure_mode != SONY2FUJI_EXPOSURE_SENSOR && !anchoredPreview;
        if (anchoredPreview) options.exposure = session->preview_camera_ev;
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
        const sony2fuji::ai::PreparedDenoise* prepared = nullptr;
        if (useAI) {
            sony2fuji::RAWBayerSource metadata;
            const bool bayer = processor.getBayerMetadata(metadata);
            prepared = &session->ai->result(request.input_path,wbOptions,bayer ? &metadata : nullptr,aiSourceIdentity);
            if (!prepared->isSceneRGB()) options.bayerOverride = &prepared->bayer;
        }
#endif
        sony2fuji::ImageData decoded;
        auto result = processor.process(options, decoded);
        if (result != sony2fuji::ErrorCode::Success) {
            session->raw_processor.reset(); session->processor_key.clear();
            return mapError(result);
        }
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
        if (prepared && prepared->isSceneRGB())
            sony2fuji::ai::applySceneRGBCorrection(decoded,prepared->scene,sony2fuji::ColorSpace::AdobeRGB,
                std::exp2(processor.getBaselineExposureEV()+options.exposure)*options.brightness);
#endif
        session->raw_cache = std::move(decoded);
        session->raw_lens_report = processor.getLensCorrectionReport();
#if defined(SONY2FUJI_ENABLE_GLES) || defined(SONY2FUJI_ENABLE_D3D11)
        ++session->raw_revision;
#endif
        session->raw_key = key;
        session->raw_noise_reduction_supported = processor.supportsNoiseReduction();
        session->baseline_ev = anchoredPreview ? session->preview_camera_ev : processor.getBaselineExposureEV();
        session->metadata_ev = processor.getMetadataExposureEV();
        session->calibrated_wb = processor.getAsShotWhiteBalance(session->as_shot_temperature,session->as_shot_tint);
        if (session->raw_exposure_mode == SONY2FUJI_EXPOSURE_PREVIEW && request.wb_mode == SONY2FUJI_WB_CAMERA) {
            session->preview_exposure_key = previewExposureKey;
            session->preview_camera_ev = session->baseline_ev;
        }
    }
    // 大图已保存全部元数据，后续调色不再需要 LibRaw 的解包像素。
    if (session->raw_cache.pixels.size() * sizeof(sony2fuji::RGB) > sony2fuji::WaveletRenderCache::defaultPreviewBudget) {
        session->raw_processor.reset();
        session->processor_key.clear();
    }
    session->lens_report = session->raw_lens_report;
    if (copyImage) image = session->raw_cache;
    else { image.width = session->raw_cache.width; image.height = session->raw_cache.height; }
    *space = SONY2FUJI_COLOR_ADOBE_RGB;
    *is_linear = true;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status loadBufferImage(
    const sony2fuji_request& request,
    sony2fuji::ImageData& image,
    sony2fuji_color_space* space,
    bool* is_linear
) {
    if (!request.input_pixels || request.input_width == 0 || request.input_height == 0) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }

    if (request.input_pixel_format != SONY2FUJI_PIXEL_RGB8 &&
        request.input_pixel_format != SONY2FUJI_PIXEL_RGBA8) {
        return SONY2FUJI_STATUS_UNSUPPORTED;
    }

    image.width = static_cast<int>(request.input_width);
    image.height = static_cast<int>(request.input_height);
    image.pixels.resize(static_cast<size_t>(request.input_width) * request.input_height);

    const uint8_t* data = static_cast<const uint8_t*>(request.input_pixels);
    uint32_t channels = request.input_pixel_format == SONY2FUJI_PIXEL_RGBA8 ? 4 : 3;

    for (size_t i = 0; i < image.pixels.size(); ++i) {
        size_t offset = i * channels;
        if (request.input_type == SONY2FUJI_INPUT_DISPLAY_BUFFER && channels == 4 && data[offset + 3] != 255)
            return SONY2FUJI_STATUS_UNSUPPORTED;
        image.pixels[i].r = data[offset] / 255.0f;
        image.pixels[i].g = data[offset + 1] / 255.0f;
        image.pixels[i].b = data[offset + 2] / 255.0f;
    }

    if (space) {
        *space = request.input_color_space;
    }
    if (is_linear) {
        *is_linear = request.input_is_linear != 0;
    }

    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status writeOutputFile(
    const sony2fuji_request& request,
    const sony2fuji::ImageData& image
) {
    if (isEmptyString(request.output_path)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }

    sony2fuji::OutputFormat format = sony2fuji::OutputFormat::JPEG;
    if (request.output_format == SONY2FUJI_OUTPUT_PNG) {
        format = sony2fuji::OutputFormat::PNG;
    } else if (request.output_format == SONY2FUJI_OUTPUT_DNG) {
        format = sony2fuji::OutputFormat::DNG;
    }

    int quality = static_cast<int>(request.jpeg_quality);
    if (quality <= 0 || quality > 100) {
        quality = 95;
    }

    sony2fuji::ErrorCode result = sony2fuji::ImageEncoder::saveImage(
        image,
        request.output_path,
        format,
        quality
    );

    return mapError(result);
}

sony2fuji_status writeOutputBuffer(
    const sony2fuji_request& request,
    const sony2fuji::ImageData& image,
    sony2fuji_buffer* out_buffer
) {
    if (!out_buffer) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }

    uint32_t channels = request.output_format == SONY2FUJI_OUTPUT_RGBA8 ? 4 : 3;
    size_t stride = static_cast<size_t>(image.width) * channels;
    size_t total = stride * static_cast<size_t>(image.height);

    void* buffer = std::malloc(total);
    if (!buffer) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    }

    uint8_t* dst = static_cast<uint8_t*>(buffer);
    for (int y = 0; y < image.height; ++y) {
        for (int x = 0; x < image.width; ++x) {
            const sony2fuji::RGB& pixel = image.at(x, y);
            size_t offset = static_cast<size_t>(y) * stride + static_cast<size_t>(x) * channels;
            dst[offset] = static_cast<uint8_t>(clampFloat(pixel.r, 0.0f, 1.0f) * 255.0f + 0.5f);
            dst[offset + 1] = static_cast<uint8_t>(clampFloat(pixel.g, 0.0f, 1.0f) * 255.0f + 0.5f);
            dst[offset + 2] = static_cast<uint8_t>(clampFloat(pixel.b, 0.0f, 1.0f) * 255.0f + 0.5f);
            if (channels == 4) {
                dst[offset + 3] = 255;
            }
        }
    }

    out_buffer->data = buffer;
    out_buffer->size_bytes = total;
    out_buffer->width = static_cast<uint32_t>(image.width);
    out_buffer->height = static_cast<uint32_t>(image.height);
    out_buffer->stride_bytes = static_cast<uint32_t>(stride);
    out_buffer->pixel_format = (channels == 4) ? SONY2FUJI_PIXEL_RGBA8 : SONY2FUJI_PIXEL_RGB8;

    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status finishGeometry(sony2fuji_session* session, const sony2fuji_request& request,
    sony2fuji::ImageData& image, uint32_t native_width, uint32_t native_height) {
    const auto transformed = sony2fuji::applyGeometry(image, session->geometry);
    if (transformed != sony2fuji::ErrorCode::Success) return mapError(transformed);
    uint32_t width, height;
    const auto status = computeTargetSize(request, native_width, native_height, &width, &height);
    if (status != SONY2FUJI_STATUS_OK) return status;
    if (width != static_cast<uint32_t>(image.width) || height != static_cast<uint32_t>(image.height))
        image = resizeBilinear(image, width, height);
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status finishOutput(
    sony2fuji_session* session,
    const sony2fuji_request& request,
    sony2fuji::ImageData& image,
    sony2fuji_buffer* out_buffer,
    uint32_t native_width,
    uint32_t native_height
) {
    // 预览保留唯一 RAW 缓存供连续调整复用；导出前由 Swift 释放预览 session。
    if ((request.intent != SONY2FUJI_INTENT_PREVIEW || request.output_target != SONY2FUJI_TARGET_BUFFER) &&
        session->raw_cache.pixels.size() * sizeof(sony2fuji::RGB) > sony2fuji::WaveletRenderCache::defaultPreviewBudget)
        session->raw_cache = {};
    const auto status = finishGeometry(session, request, image, native_width, native_height);
    if (status != SONY2FUJI_STATUS_OK) return status;
    if (session->geometry.active()) session->last_backend = SONY2FUJI_BACKEND_CPU;
    const auto written = request.output_target == SONY2FUJI_TARGET_FILE ?
        writeOutputFile(request, image) : writeOutputBuffer(request, image, out_buffer);
    if (written == SONY2FUJI_STATUS_OK) {
        session->geometry_width = native_width; session->geometry_height = native_height;
    }
    return written;
}

} // namespace

sony2fuji_status sony2fuji_validate_look(
    const char* path, sony2fuji_look_format* format, uint32_t* format_version
) {
    if (format) *format = SONY2FUJI_LOOK_UNKNOWN;
    if (format_version) *format_version = 0;
    if (isEmptyString(path)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    try {
        const auto file = std::filesystem::u8path(path);
        std::error_code error;
        if (!std::filesystem::is_regular_file(file, error) || error)
            return SONY2FUJI_STATUS_IO_ERROR;
        std::ifstream readable(file, std::ios::binary);
        if (!readable) return SONY2FUJI_STATUS_IO_ERROR;
        readable.close();
        const auto kind = sony2fuji::LUTParser::detectFormat(path);
        if (kind == "rlook") {
            const auto look = sony2fuji::DcpLook::loadCached(path);
            if (!look) return SONY2FUJI_STATUS_UNSUPPORTED;
            if (format_version) *format_version = look->formatVersion();
            if (format) *format = SONY2FUJI_LOOK_RLOOK;
        } else if (kind == "cube") {
            std::shared_ptr<sony2fuji::LUT3D> lut;
            const auto status = loadLUT(path, &lut);
            if (status != SONY2FUJI_STATUS_OK) return status;
            if (!lut->isPhotoLUT()) return SONY2FUJI_STATUS_UNSUPPORTED;
            if (format) *format = SONY2FUJI_LOOK_CUBE;
        } else {
            return SONY2FUJI_STATUS_UNSUPPORTED;
        }
        return SONY2FUJI_STATUS_OK;
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (const std::filesystem::filesystem_error&) {
        return SONY2FUJI_STATUS_IO_ERROR;
    } catch (const std::exception&) {
        return SONY2FUJI_STATUS_UNSUPPORTED;
    }
}

// ============================================================================
// C API
// ============================================================================

sony2fuji_status sony2fuji_session_create(sony2fuji_session** out_session) {
    if (!out_session) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }

    *out_session = new (std::nothrow) sony2fuji_session();
    if (!*out_session) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    }
    (*out_session)->gpu_config = sony2fuji::defaultGpuConfig();

    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_destroy(sony2fuji_session* session) {
    delete session;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_set_lens_database(sony2fuji_session* session, const char* path) {
    if (!session) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    if (!sony2fuji::LensCorrectionDatabase::available()) return SONY2FUJI_STATUS_UNSUPPORTED;
    try {
        auto database = sony2fuji::LensCorrectionDatabase::load(path ? path : "");
        if (!database) return SONY2FUJI_STATUS_IO_ERROR;
        session->lens_database = std::move(database);
        session->lens_database_tried = true;
        ++session->lens_database_revision;
        session->raw_key.clear();
        return SONY2FUJI_STATUS_OK;
    } catch (const std::bad_alloc&) { return SONY2FUJI_STATUS_OUT_OF_MEMORY; }
    catch (...) { return SONY2FUJI_STATUS_IO_ERROR; }
}

sony2fuji_status sony2fuji_session_set_lens_correction(sony2fuji_session* session, const sony2fuji_lens_correction_config* config) {
    if (!session || !config || config->version != SONY2FUJI_LENS_CORRECTION_CONFIG_VERSION || config->struct_size != sizeof(*config) ||
        (config->distortion != 0 && config->distortion != 1) || (config->tca != 0 && config->tca != 1) ||
        (config->auto_crop != 0 && config->auto_crop != 1)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    if ((config->distortion || config->tca) && !sony2fuji::LensCorrectionDatabase::available()) return SONY2FUJI_STATUS_UNSUPPORTED;
    try {
        std::string profile = config->profile_id ? config->profile_id : "";
        if (profile.size() >= sizeof(sony2fuji_lens_profile::id)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
        session->lens_correction = {config->distortion != 0, config->tca != 0, config->auto_crop != 0, std::move(profile)};
        return SONY2FUJI_STATUS_OK;
    } catch (const std::bad_alloc&) { return SONY2FUJI_STATUS_OUT_OF_MEMORY; }
}

sony2fuji_status sony2fuji_session_inspect_lens(sony2fuji_session* session, const char* input_path,
    sony2fuji_lens_report* report, sony2fuji_lens_profile* profiles, uint32_t capacity, uint32_t* count) {
    if (!session || isEmptyString(input_path) || !report || !count || (!profiles && capacity != 0)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    *count = 0; *report = {};
    try {
        sony2fuji::LensMetadata metadata;
        const auto status = sony2fuji::RAWProcessor::readLensMetadata(input_path, metadata);
        if (status != sony2fuji::ErrorCode::Success) return mapError(status);
        ensureLensDatabase(session);
        sony2fuji::LensCorrectionReport inspected;
        inspected.metadata = metadata;
        if (!session->lens_database) {
            inspected.state = session->lens_correction.active() ? sony2fuji::LensCorrectionState::NoDatabase : sony2fuji::LensCorrectionState::Off;
            *report = lensReport(inspected); return SONY2FUJI_STATUS_OK;
        }
        inspected = session->lens_database->inspect(metadata, session->lens_correction);
        *report = lensReport(inspected);
        const auto catalog = session->lens_database->profiles(metadata);
        *count = static_cast<uint32_t>(catalog.size());
        if (profiles) {
            if (capacity < catalog.size()) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
            for (size_t i = 0; i < catalog.size(); ++i) profiles[i] = lensProfile(catalog[i]);
        }
        return SONY2FUJI_STATUS_OK;
    } catch (const std::bad_alloc&) { return SONY2FUJI_STATUS_OUT_OF_MEMORY; }
    catch (...) { return SONY2FUJI_STATUS_PROCESSING_ERROR; }
}

sony2fuji_status sony2fuji_session_get_lens_report(sony2fuji_session* session, sony2fuji_lens_report* report) {
    if (!session || !report) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    *report = lensReport(session->lens_report);
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_set_interactive_preview(sony2fuji_session* session, int32_t enabled) {
    if (!session || (enabled != 0 && enabled != 1)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    session->interactive_preview = enabled != 0;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_set_viewport_preview(sony2fuji_session* session, int32_t enabled) {
    if (!session || (enabled != 0 && enabled != 1)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    session->viewport_preview = enabled != 0;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_render_backend sony2fuji_session_get_last_backend(const sony2fuji_session* session) {
    return session ? session->last_backend : SONY2FUJI_BACKEND_CPU;
}

sony2fuji_status sony2fuji_session_set_gpu_config(
    sony2fuji_session* session,
    const sony2fuji_gpu_config* config
) {
    if (!session) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    sony2fuji_status status = validateGpuConfig(config);
    if (status != SONY2FUJI_STATUS_OK) {
        return status;
    }
    session->gpu_config.mode = toCoreGpuMode(config->mode);
#if defined(SONY2FUJI_ENABLE_D3D11)
    if (session->gpu_config.mode == sony2fuji::GpuMode::Off) session->d3d_renderer.reset();
#endif
#if defined(SONY2FUJI_ENABLE_GLES)
    if (session->gpu_config.mode == sony2fuji::GpuMode::Off) session->gles_renderer.reset();
#endif
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_set_processing_version(
    sony2fuji_session* session, sony2fuji_processing_version version
) {
    const auto processing = static_cast<sony2fuji::ProcessingVersion>(version);
    if (!session || !sony2fuji::validProcessingVersion(processing)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    session->processing_version = processing;
    session->wavelet_denoise.processingVersion = processing;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_set_raw_exposure_mode(
    sony2fuji_session* session, sony2fuji_raw_exposure_mode mode
) {
    if (!session || mode < SONY2FUJI_EXPOSURE_SCENE || mode > SONY2FUJI_EXPOSURE_SENSOR)
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    session->raw_exposure_mode = mode;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_set_raw_noise_reduction(sony2fuji_session* session, int32_t level) {
    if (!session || level < 0 || level > 2) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    session->raw_noise_reduction = level;
    return SONY2FUJI_STATUS_OK;
}

int32_t sony2fuji_ai_available(void) {
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    return 1;
#else
    return 0;
#endif
}

sony2fuji_status sony2fuji_session_set_ai_denoise(sony2fuji_session* session, const sony2fuji_ai_denoise_config* config) {
    if (!session || !config || config->version != SONY2FUJI_AI_DENOISE_CONFIG_VERSION || config->struct_size < sizeof(*config) ||
        (config->enabled != 0 && config->enabled != 1) || config->backend < SONY2FUJI_AI_CPU || config->backend > SONY2FUJI_AI_DIRECTML ||
        (config->enabled && (isEmptyString(config->model_directory) || isEmptyString(config->cache_directory))))
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    if (config->enabled && config->backend == SONY2FUJI_AI_CPU) return SONY2FUJI_STATUS_UNSUPPORTED;
    try {
        if (!session->ai) session->ai = std::make_unique<sony2fuji::ai::AISession>();
        const auto backend = config->backend == SONY2FUJI_AI_CPU ? sony2fuji::ai::Backend::Cpu :
            config->backend == SONY2FUJI_AI_COREML ? sony2fuji::ai::Backend::CoreML :
            config->backend == SONY2FUJI_AI_DIRECTML ? sony2fuji::ai::Backend::DirectML : sony2fuji::ai::Backend::Auto;
        session->ai->enabled = config->enabled != 0;
        session->ai->configure(config->model_directory ? config->model_directory : "", config->cache_directory ? config->cache_directory : "", backend);
        return SONY2FUJI_STATUS_OK;
    } catch (const std::bad_alloc&) { return SONY2FUJI_STATUS_OUT_OF_MEMORY; }
    catch (const std::exception&) { return SONY2FUJI_STATUS_INVALID_ARGUMENT; }
#else
    return config->enabled ? SONY2FUJI_STATUS_UNSUPPORTED : SONY2FUJI_STATUS_OK;
#endif
}

const char* sony2fuji_session_get_ai_error(const sony2fuji_session* session) {
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    if (session && session->ai) return session->ai->lastError.c_str();
#else
    (void)session;
#endif
    return "";
}

const char* sony2fuji_session_get_ai_backend(const sony2fuji_session* session) {
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    if (session && session->ai) return session->ai->lastBackend.c_str();
#else
    (void)session;
#endif
    return "";
}

sony2fuji_status sony2fuji_session_prepare_ai(sony2fuji_session* session, const sony2fuji_request* request,
    sony2fuji_ai_progress_callback progress, void* context) {
    if (!session || !request || request->version != SONY2FUJI_REQUEST_VERSION || request->struct_size < sizeof(*request) ||
        request->input_type != SONY2FUJI_INPUT_RAW || request->wb_mode < SONY2FUJI_WB_CAMERA || request->wb_mode > SONY2FUJI_WB_TEMPERATURE)
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    if (!session->ai) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    auto local = *request;
    local.output_target = SONY2FUJI_TARGET_BUFFER;
    local.output_format = SONY2FUJI_OUTPUT_RGB8;
    sony2fuji_buffer buffer{};
    const auto valid = validateRequest(&local, &buffer);
    if (valid != SONY2FUJI_STATUS_OK) return valid;
    try {
        if (session->lens_correction.active()) ensureLensDatabase(session);
        session->ai->prepare(local.input_path, rawWhiteBalanceOptions(session, local),
            [&](sony2fuji::ai::Phase phase, size_t done, size_t total) {
                return !progress || progress(context, static_cast<int32_t>(phase), done, total) != 0;
            });
        return SONY2FUJI_STATUS_OK;
    } catch (const sony2fuji::ai::Cancelled& error) {
        session->ai->lastError = error.what(); return SONY2FUJI_STATUS_CANCELLED;
    } catch (const sony2fuji::ai::DecodeError& error) {
        session->ai->lastError = error.what(); return mapError(error.code);
    } catch (const std::bad_alloc&) {
        session->ai->lastError = "AI denoising ran out of memory"; return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (const std::invalid_argument& error) {
        session->ai->lastError = error.what(); return SONY2FUJI_STATUS_UNSUPPORTED;
    } catch (const std::filesystem::filesystem_error& error) {
        session->ai->lastError = error.what(); return SONY2FUJI_STATUS_IO_ERROR;
    } catch (const std::exception& error) {
        session->ai->lastError = error.what(); return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
#else
    (void)progress; (void)context; return SONY2FUJI_STATUS_UNSUPPORTED;
#endif
}

sony2fuji_status sony2fuji_session_set_chroma_denoise(sony2fuji_session* session, int32_t mode) {
    if (!session || mode < 0 || mode > 2) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    if (mode != 0 && !sony2fuji::chromaDenoiseAvailable()) return SONY2FUJI_STATUS_UNSUPPORTED;
    session->chroma_denoise = mode;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_set_wavelet_denoise(
    sony2fuji_session* session, const sony2fuji_wavelet_denoise_config* config
) {
    if (!session || !config || config->version != SONY2FUJI_WAVELET_DENOISE_CONFIG_VERSION ||
        config->struct_size < sizeof(*config) || (config->enabled != 0 && config->enabled != 1))
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    const sony2fuji::WaveletDenoiseOptions options{config->enabled != 0,config->luma,config->chroma,config->coarse,
        session->processing_version};
    if (!sony2fuji::validWaveletDenoiseOptions(options)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    if (options.active() && !sony2fuji::waveletDenoiseAvailable()) return SONY2FUJI_STATUS_UNSUPPORTED;
    session->wavelet_denoise = options;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_get_raw_noise_reduction_support(
    const sony2fuji_session* session, int32_t* supported
) {
    if (!session || !supported || session->raw_key.empty())
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    *supported = session->raw_noise_reduction_supported ? 1 : 0;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_get_raw_exposure(
    const sony2fuji_session* session, float* baseline_ev, float* metadata_ev
) {
    if (!session || !baseline_ev || !metadata_ev || session->raw_key.empty())
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    *baseline_ev = session->baseline_ev;
    *metadata_ev = session->metadata_ev;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_get_raw_white_balance(
    const sony2fuji_session* session, float* temperature, float* tint
) {
    if (!session || !temperature || !tint || session->raw_key.empty())
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    if (!session->calibrated_wb) return SONY2FUJI_STATUS_UNSUPPORTED;
    *temperature=session->as_shot_temperature; *tint=session->as_shot_tint;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_set_photo_effects(
    sony2fuji_session* session, const sony2fuji_photo_effects_config* config
) {
    if (!session || !config || config->version != SONY2FUJI_PHOTO_EFFECTS_CONFIG_VERSION ||
        config->struct_size != sizeof(*config)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    sony2fuji::PhotoEffectsOptions options{config->vignette_amount, config->vignette_midpoint,
        config->vignette_roundness, config->vignette_feather, config->vignette_highlights,
        config->grain_amount, config->grain_size, config->grain_roughness};
    if (!options.valid()) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    session->photo_effects = options;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_set_hsl(
    sony2fuji_session* session, const sony2fuji_hsl_config* config
) {
    if (!session || !config || config->version != SONY2FUJI_HSL_CONFIG_VERSION ||
        config->struct_size != sizeof(*config)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    sony2fuji::HslOptions options;
    std::copy(std::begin(config->hue), std::end(config->hue), options.hue.begin());
    std::copy(std::begin(config->saturation), std::end(config->saturation), options.saturation.begin());
    std::copy(std::begin(config->lightness), std::end(config->lightness), options.lightness.begin());
    if (!options.valid()) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    session->hsl = options;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_set_tone_controls(
    sony2fuji_session* session, const sony2fuji_tone_controls_config* config
) {
    if (!session || !config || config->version != SONY2FUJI_TONE_CONTROLS_CONFIG_VERSION ||
        config->struct_size != sizeof(*config)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    const sony2fuji::ToneControlsOptions options{config->black_point,config->white_point,config->vibrance};
    if (!options.valid()) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    session->tone_controls = options;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_set_atmosphere(
    sony2fuji_session* session, const sony2fuji_atmosphere_config* config
) {
    static_assert(sizeof(sony2fuji_atmosphere_config)==16,"Atmosphere C ABI layout");
    if (!session || !config || config->version!=SONY2FUJI_ATMOSPHERE_CONFIG_VERSION ||
        config->struct_size!=sizeof(*config)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    const sony2fuji::AtmosphereOptions options{config->clarity,config->dehaze};
    if (!options.valid()) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    session->atmosphere=options;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_set_color_grading(
    sony2fuji_session* session, const sony2fuji_color_grading_config* config
) {
    static_assert(sizeof(sony2fuji_color_grading_config)==32,"Color grading C ABI layout");
    if (!session || !config || config->version!=SONY2FUJI_COLOR_GRADING_CONFIG_VERSION ||
        config->struct_size!=sizeof(*config)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    sony2fuji::ColorGradingOptions options;
    options.wheels={sony2fuji::ColorGradingWheel{config->shadows_hue,config->shadows_saturation},
        sony2fuji::ColorGradingWheel{config->midtones_hue,config->midtones_saturation},
        sony2fuji::ColorGradingWheel{config->highlights_hue,config->highlights_saturation}};
    if (!options.valid()) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    session->color_grading=options;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_set_tone_curve(
    sony2fuji_session* session, const sony2fuji_tone_curve_config* config
) {
    static_assert(sizeof(sony2fuji_tone_curve_config) == 544, "Tone curve C ABI layout");
    if (!session || !config || !sony2fuji::validToneCurve(*config)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    session->tone_curve = sony2fuji::ToneCurve(*config);
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_sample_tone_curve(const sony2fuji_tone_curve_config* config,
    const double* x, double* y, uint32_t count) {
    if (!config || !x || !y || count == 0 || !sony2fuji::validToneCurve(*config) || config->mode != SONY2FUJI_CURVE_CUSTOM)
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    for (uint32_t i = 0; i < count; ++i) if (!std::isfinite(x[i])) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    const sony2fuji::ToneCurve curve(*config);
    for (uint32_t i = 0; i < count; ++i) y[i] = curve.evaluate(x[i]);
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_set_geometry(
    sony2fuji_session* session, const sony2fuji_geometry_config* config
) {
    static_assert(sizeof(sony2fuji_geometry_config) == 40, "Geometry C ABI layout");
    if (!session || !config || config->version != SONY2FUJI_GEOMETRY_CONFIG_VERSION ||
        config->struct_size != sizeof(*config) || config->flip_horizontal < 0 ||
        config->flip_horizontal > 1 || config->flip_vertical < 0 || config->flip_vertical > 1)
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    auto options = session->geometry;
    options.crop_x = config->crop_x; options.crop_y = config->crop_y;
    options.crop_width = config->crop_width; options.crop_height = config->crop_height;
    options.quarter_turns = config->quarter_turns;
    options.flip_horizontal = config->flip_horizontal != 0;
    options.flip_vertical = config->flip_vertical != 0;
    options.straighten_degrees = config->straighten_degrees;
    if (!options.valid()) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    options.crop_width = std::min(options.crop_width, 1.0f - options.crop_x);
    options.crop_height = std::min(options.crop_height, 1.0f - options.crop_y);
    session->geometry = options;
    session->geometry_width = session->geometry_height = 0;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_set_perspective(
    sony2fuji_session* session, const sony2fuji_perspective_config* config
) {
    static_assert(sizeof(sony2fuji_perspective_config) == 16, "Perspective C ABI layout");
    if (!session || !config || config->version != SONY2FUJI_PERSPECTIVE_CONFIG_VERSION ||
        config->struct_size != sizeof(*config)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    auto options = session->geometry;
    options.perspective_horizontal = config->horizontal;
    options.perspective_vertical = config->vertical;
    if (!options.valid()) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    session->geometry = options;
    session->geometry_width = session->geometry_height = 0;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_get_geometry_size(
    const sony2fuji_session* session, uint32_t* width, uint32_t* height
) {
    if (width) *width = 0;
    if (height) *height = 0;
    if (!session || !width || !height) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    if (session->geometry_width == 0 || session->geometry_height == 0)
        return SONY2FUJI_STATUS_UNSUPPORTED;
    *width = session->geometry_width; *height = session->geometry_height;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_estimate_auto_exposure(
    sony2fuji_session* session, const sony2fuji_request* request, float* exposure_ev
) {
    if (!session || !request || !exposure_ev) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    if (request->version != SONY2FUJI_REQUEST_VERSION || request->struct_size < sizeof(*request))
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    if (request->wb_mode < SONY2FUJI_WB_CAMERA || request->wb_mode > SONY2FUJI_WB_TEMPERATURE ||
        (request->input_type == SONY2FUJI_INPUT_BUFFER &&
         (request->input_color_space < SONY2FUJI_COLOR_SRGB || request->input_color_space > SONY2FUJI_COLOR_ADOBE_RGB)))
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    sony2fuji_buffer buffer{};
    auto local = *request;
    local.output_target = SONY2FUJI_TARGET_BUFFER;
    local.intent = SONY2FUJI_INTENT_FINAL;
    const auto valid = validateRequest(&local, &buffer);
    if (valid != SONY2FUJI_STATUS_OK) return valid;
    try {
        sony2fuji::ImageData image;
        sony2fuji_color_space space = SONY2FUJI_COLOR_SRGB;
        bool linear = false;
        const bool raw = local.input_type == SONY2FUJI_INPUT_RAW;
        auto status = raw ? loadRawImage(session, local, image, &space, &linear, false) :
            loadBufferImage(local, image, &space, &linear);
        if (status != SONY2FUJI_STATUS_OK) return status;
        status = ensureLinear(image, space, &linear);
        if (status != SONY2FUJI_STATUS_OK) return status;
        if (space == SONY2FUJI_COLOR_SONY_NATIVE) return SONY2FUJI_STATUS_UNSUPPORTED;
        sony2fuji::RGB wb(1,1,1);
        if (local.wb_mode != SONY2FUJI_WB_TEMPERATURE) {
            const auto reference = whiteBalanceForTempTint(6500,0);
            const auto selected = whiteBalanceForTempTint(local.temperature,local.tint);
            wb = sony2fuji::RGB(reference.r/std::max(selected.r,1e-4f),
                reference.g/std::max(selected.g,1e-4f),reference.b/std::max(selected.b,1e-4f));
            wb.r /= wb.g; wb.b /= wb.g; wb.g = 1;
        }
        if (!raw && local.wb_mode == SONY2FUJI_WB_CUSTOM) {
            wb.r *= local.wb_mul[0]/local.wb_mul[1]; wb.b *= local.wb_mul[2]/local.wb_mul[1];
        }
        float ev;
        if (!sony2fuji::estimateAutoExposure(raw ? session->raw_cache : image, toCoreColorSpace(space), wb, ev))
            return SONY2FUJI_STATUS_UNSUPPORTED;
        *exposure_ev = ev;
        return SONY2FUJI_STATUS_OK;
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    } catch (const sony2fuji::ai::NotReady&) {
        return SONY2FUJI_STATUS_AI_NOT_READY;
    } catch (const sony2fuji::ai::Unsupported&) {
        return SONY2FUJI_STATUS_UNSUPPORTED;
#endif
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

static sony2fuji_status processImpl(
    sony2fuji_session* session,
    const sony2fuji_request* request,
    sony2fuji_buffer* out_buffer,
    sony2fuji::ImageData* pre_hsl = nullptr
) {
    if (!session) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    session->geometry_width = session->geometry_height = 0;

    sony2fuji_status status = validateRequest(request, out_buffer);
    if (status != SONY2FUJI_STATUS_OK) {
        return status;
    }

    status = validateOutputFormat(*request);
    if (status != SONY2FUJI_STATUS_OK) {
        return status;
    }

    sony2fuji_request local = *request;
    if (session->tone_curve.custom() && local.tone_curve != 0) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    const bool displayInput = local.input_type == SONY2FUJI_INPUT_DISPLAY_BUFFER;
    const bool useAI = aiEnabled(session);
    if (useAI && local.input_type != SONY2FUJI_INPUT_RAW) return SONY2FUJI_STATUS_UNSUPPORTED;
    if (displayInput && (session->raw_noise_reduction != 0 || session->lens_correction.active() ||
        session->gpu_config.mode == sony2fuji::GpuMode::Force)) return SONY2FUJI_STATUS_UNSUPPORTED;
    local.lut_strength = clampFloat(local.lut_strength, 0.0f, 2.0f);
    session->last_backend = SONY2FUJI_BACKEND_CPU;
    if (local.input_type != SONY2FUJI_INPUT_RAW) {
        session->lens_report = {};
        if (session->lens_correction.active()) session->lens_report.state = sony2fuji::LensCorrectionState::UnsupportedInput;
    }
    const bool waveletActive = !useAI && session->wavelet_denoise.active();
    const int chromaMode = useAI ? 0 : session->chroma_denoise;
    const bool effectsActive = session->photo_effects.active();
    const bool hslActive = session->hsl.active();
    const bool toneControlsActive = session->tone_controls.active();
    const bool atmosphereActive = session->atmosphere.active();
    const bool colorGradingActive = session->color_grading.active();
    const bool geometryActive = session->geometry.active();
    if (geometryActive && session->gpu_config.mode == sony2fuji::GpuMode::Force)
        return SONY2FUJI_STATUS_UNSUPPORTED;
    const bool viewportPreview = !atmosphereActive && session->viewport_preview && local.intent == SONY2FUJI_INTENT_PREVIEW &&
        local.output_target == SONY2FUJI_TARGET_BUFFER;
#if defined(SONY2FUJI_ENABLE_METAL) || defined(SONY2FUJI_ENABLE_GLES) || defined(SONY2FUJI_ENABLE_D3D11)
    const bool cpuOnlyStages = atmosphereActive || !session->tone_curve.gpuSupported();
#else
    const bool cpuOnlyStages = atmosphereActive || session->tone_curve.active() || colorGradingActive || toneControlsActive || hslActive || effectsActive || waveletActive || chromaMode != 0;
#endif
    const bool fastWavelet = !atmosphereActive && !geometryActive && waveletActive && !effectsActive && chromaMode == 0 && session->interactive_preview &&
        local.intent == SONY2FUJI_INTENT_PREVIEW && local.output_target == SONY2FUJI_TARGET_BUFFER;
    if (cpuOnlyStages && session->gpu_config.mode == sony2fuji::GpuMode::Force)
        return SONY2FUJI_STATUS_UNSUPPORTED;
    const bool use_lut = !isEmptyString(local.lut_path) && local.lut_strength > 0;
    std::shared_ptr<sony2fuji::LUT3D> lut;
    std::shared_ptr<const sony2fuji::DcpLook> dcp;
    if (use_lut) {
        if (sony2fuji::LUTParser::detectFormat(local.lut_path) == "rlook") {
            dcp = sony2fuji::DcpLook::loadCached(local.lut_path);
            if (!dcp) return SONY2FUJI_STATUS_UNSUPPORTED;
#if !defined(SONY2FUJI_ENABLE_METAL)
            if (session->gpu_config.mode == sony2fuji::GpuMode::Force) return SONY2FUJI_STATUS_PROCESSING_ERROR;
#endif
        } else {
            status = loadLUT(local.lut_path, &lut);
            if (status != SONY2FUJI_STATUS_OK) return status;
            if (!lut->isPhotoLUT()) return SONY2FUJI_STATUS_UNSUPPORTED;
        }
    }
#if defined(SONY2FUJI_ENABLE_METAL)
    bool gpuPipeline = !cpuOnlyStages && session->gpu_config.mode != sony2fuji::GpuMode::Off;
#elif defined(SONY2FUJI_ENABLE_GLES) || defined(SONY2FUJI_ENABLE_D3D11)
    bool gpuPipeline = !cpuOnlyStages && !dcp && session->gpu_config.mode != sony2fuji::GpuMode::Off;
#else
    bool gpuPipeline = false;
#endif
    // Reuse the reference stages; scene-view GPU shaders retain their existing
    // contract. Auto explicitly falls back for display-referred input.
    if (displayInput) gpuPipeline = false;

    sony2fuji::ImageData image;
    sony2fuji_color_space color_space = SONY2FUJI_COLOR_SRGB;
    bool is_linear = false;
    if (local.input_type == SONY2FUJI_INPUT_RAW) {
        auto raw_request = local;
        if (geometryActive || atmosphereActive) raw_request.intent = SONY2FUJI_INTENT_FINAL;
        status = loadRawImage(session, raw_request, image, &color_space, &is_linear, false);
        if (status == SONY2FUJI_STATUS_OK && !viewportPreview && (!gpuPipeline || waveletActive)) {
            const bool large = session->raw_cache.pixels.size() * sizeof(sony2fuji::RGB) >
                sony2fuji::WaveletRenderCache::defaultPreviewBudget;
            // C5 失败不会破坏工作图；Legacy 的 GPU 重试仍需要原始 RAW。
            const bool reloadableWavelet = waveletActive &&
                session->wavelet_denoise.processingVersion != sony2fuji::ProcessingVersion::C5V2;
            if (large && !reloadableWavelet && !pre_hsl) image = std::move(session->raw_cache);
            else image = session->raw_cache;
        }
    } else {
        status = loadBufferImage(local, image, &color_space, &is_linear);
    }
    if (status != SONY2FUJI_STATUS_OK) return status;
    status = ensureLinear(image, color_space, &is_linear);
    if (status != SONY2FUJI_STATUS_OK) return status;
    if (color_space == SONY2FUJI_COLOR_SONY_NATIVE) return SONY2FUJI_STATUS_UNSUPPORTED;
    const auto native = sony2fuji::geometryOutputSize(image.width, image.height, session->geometry);
    const uint32_t native_width = native.first, native_height = native.second;

    if (viewportPreview) {
        uint32_t width, height;
        status = computeTargetSize(local, native_width, native_height, &width, &height);
        if (status != SONY2FUJI_STATUS_OK) return status;
        const auto& source = local.input_type == SONY2FUJI_INPUT_RAW ? session->raw_cache : image;
        std::pair<int, int> sourceSize;
        if (geometryActive) {
            sourceSize = sony2fuji::geometryViewportSourceSize(source.width, source.height,
                session->geometry, width, height);
        } else {
            const double scale = std::min({1.0, double(source.width) / width, double(source.height) / height});
            width = std::max(1u, static_cast<uint32_t>(std::lround(width * scale)));
            height = std::max(1u, static_cast<uint32_t>(std::lround(height * scale)));
            sourceSize = {width, height};
        }
        // 新图可能比上一次视口需求小；后续阶段也必须沿用已限制的尺寸。
        local.preview_long_edge = 0;
        local.size_mode = SONY2FUJI_SIZE_EXACT;
        local.target_width = width; local.target_height = height;
        // RAW 缓存保持不变，直接读取源像素，避免先拷贝完整大图。
        if (sourceSize.first != source.width || sourceSize.second != source.height)
            image = resizeBilinear(source, sourceSize.first, sourceSize.second);
        else if (local.input_type == SONY2FUJI_INPUT_RAW)
            image = source;
    }

    // Absolute RAW WB already ran in camera space. Legacy RGB controls compensate
    // for the chosen illuminant (inverse response), not paint its color onto RGB.
    const auto reference = whiteBalanceForTempTint(6500, 0);
    const auto selected = whiteBalanceForTempTint(local.temperature, local.tint);
    const float exposure = std::pow(2.0f, local.exposure_ev) * local.brightness;
    sony2fuji::RGB wb(1,1,1);
    if (local.wb_mode != SONY2FUJI_WB_TEMPERATURE) {
        wb=sony2fuji::RGB(reference.r/std::max(selected.r,1e-4f),
            reference.g/std::max(selected.g,1e-4f),reference.b/std::max(selected.b,1e-4f));
        wb.r/=wb.g; wb.b/=wb.g; wb.g=1;
    }
    if (local.input_type == SONY2FUJI_INPUT_BUFFER && local.wb_mode == SONY2FUJI_WB_CUSTOM) {
        wb.r *= local.wb_mul[0]/local.wb_mul[1];
        wb.b *= local.wb_mul[2]/local.wb_mul[1];
    }
    if (waveletActive) {
        if (fastWavelet) {
            uint32_t width, height;
            status = computeTargetSize(local, image.width, image.height, &width, &height);
            if (status != SONY2FUJI_STATUS_OK) return status;
            if (width != static_cast<uint32_t>(image.width) || height != static_cast<uint32_t>(image.height))
                image = resizeBilinear(image, width, height);
        }
        const bool cacheable = local.input_type == SONY2FUJI_INPUT_RAW && (!fastWavelet || viewportPreview);
        // 相机 WB/FBDD 往返会改变实际曝光锚点，即使 RAW 参数 key 恢复旧值。
        uint32_t baselineBits = 0;
        static_assert(sizeof(baselineBits) == sizeof(session->baseline_ev));
        std::memcpy(&baselineBits, &session->baseline_ev, sizeof(baselineBits));
        const auto waveletKey = session->raw_key + ":baseline:" + std::to_string(baselineBits) + (viewportPreview ? ":viewport:" +
            std::to_string(image.width) + "x" + std::to_string(image.height) : "");
        auto* entry = cacheable ? &session->wavelet_cache.select(waveletKey, viewportPreview) : nullptr;
        if (entry && entry->matches(session->wavelet_denoise, session->gpu_config.mode)) {
            image = entry->image;
            ++session->wavelet_cache.diagnostics.outputHits;
        } else {
            if (entry) {
                // 失效的整图输出先释放，避免与重算峰值叠加；分析模型仍可复用。
                entry->image = {};
                entry->completed = false;
            }
            sony2fuji::ColorConverter converter;
            converter.convertImage(image, toCoreColorSpace(color_space), sony2fuji::ColorSpace::sRGB);
            const bool cpuC5 = session->wavelet_denoise.processingVersion == sony2fuji::ProcessingVersion::C5V2 &&
                session->gpu_config.mode != sony2fuji::GpuMode::Force;
            const auto mode = gpuPipeline && !cpuC5 ? sony2fuji::GpuMode::Force : sony2fuji::GpuMode::Off;
            sony2fuji::WaveletDenoiseDiagnostics diagnostics;
            auto filter = [&](sony2fuji::GpuMode backend) {
                ++session->wavelet_cache.diagnostics.filterRuns;
                const auto result = sony2fuji::applyWaveletDenoise(image, session->wavelet_denoise, &diagnostics,
                    backend, entry ? &entry->analysis : nullptr, waveletKey,
                    local.input_type == SONY2FUJI_INPUT_RAW && !viewportPreview && !fastWavelet &&
                        !session->raw_cache.pixels.empty() ? &session->raw_cache : nullptr,
                    toCoreColorSpace(color_space));
                if (diagnostics.analysisReused) ++session->wavelet_cache.diagnostics.analysisHits;
                return result;
            };
            auto result = filter(mode);
            const bool fallback = result != sony2fuji::ErrorCode::Success && session->gpu_config.mode == sony2fuji::GpuMode::Auto;
            if (fallback) {
                gpuPipeline = false;
                result = filter(sony2fuji::GpuMode::Off);
            }
            if (result != sony2fuji::ErrorCode::Success) return mapError(result);
            if (entry && !fallback)
                session->wavelet_cache.store(*entry, image, session->wavelet_denoise, session->gpu_config.mode);
        }
        // 小波及其重试已完成；viewport 仍需缓存 RAW 供下一次滑杆调整复用。
        if (!viewportPreview && !pre_hsl &&
            session->raw_cache.pixels.size() * sizeof(sony2fuji::RGB) > sony2fuji::WaveletRenderCache::defaultPreviewBudget)
            session->raw_cache = {};
        color_space = SONY2FUJI_COLOR_SRGB;
    }
#if defined(SONY2FUJI_ENABLE_METAL)
    if (gpuPipeline) {
        uint32_t width = image.width, height = image.height;
        if (!geometryActive) {
            status = computeTargetSize(local, image.width, image.height, &width, &height);
            if (status != SONY2FUJI_STATUS_OK) return status;
        }
        const auto& source = local.input_type == SONY2FUJI_INPUT_RAW && !waveletActive && !viewportPreview ? session->raw_cache : image;
        sony2fuji::ImageData rendered;
        if (sony2fuji::renderPhotoMetal(source, toCoreColorSpace(color_space), local, lut, wb, width, height, rendered,
                dcp, session->photo_effects, chromaMode, waveletActive || geometryActive, session->hsl, session->tone_controls, session->color_grading, session->tone_curve)) {
            session->last_backend = SONY2FUJI_BACKEND_METAL;
            return finishOutput(session, local, rendered, out_buffer, native_width, native_height);
        }
        if (session->gpu_config.mode == sony2fuji::GpuMode::Force) return SONY2FUJI_STATUS_PROCESSING_ERROR;
        if (local.input_type == SONY2FUJI_INPUT_RAW && !waveletActive && !viewportPreview) {
            if (session->raw_cache.pixels.size() * sizeof(sony2fuji::RGB) > sony2fuji::WaveletRenderCache::defaultPreviewBudget)
                image = std::move(session->raw_cache);
            else image = session->raw_cache;
        }
    }
#endif
#if defined(SONY2FUJI_ENABLE_GLES)
    if (gpuPipeline) {
        uint32_t width = image.width, height = image.height;
        if (!geometryActive) {
            status = computeTargetSize(local, image.width, image.height, &width, &height);
            if (status != SONY2FUJI_STATUS_OK) return status;
        }
        if (!session->gles_renderer) session->gles_renderer = std::make_unique<sony2fuji::GlesPhotoRenderer>();
        const bool raw = local.input_type == SONY2FUJI_INPUT_RAW && !viewportPreview;
        const auto& source = raw && !waveletActive ? session->raw_cache : image;
        sony2fuji::ImageData rendered;
        if (session->gles_renderer->render(source, toCoreColorSpace(color_space), local, lut, wb,
                width, height, raw && !waveletActive ? session->raw_revision : 0, rendered,
                session->photo_effects, chromaMode, waveletActive || geometryActive, session->hsl, session->tone_controls, session->color_grading, session->tone_curve)) {
            session->last_backend = SONY2FUJI_BACKEND_GLES;
            return finishOutput(session, local, rendered, out_buffer, native_width, native_height);
        }
        if (session->gpu_config.mode == sony2fuji::GpuMode::Force) return SONY2FUJI_STATUS_PROCESSING_ERROR;
        if (raw && !waveletActive) image = session->raw_cache;
    }
#endif
#if defined(SONY2FUJI_ENABLE_D3D11)
    if (gpuPipeline) {
        uint32_t width = image.width, height = image.height;
        if (!geometryActive) {
            status = computeTargetSize(local, image.width, image.height, &width, &height);
            if (status != SONY2FUJI_STATUS_OK) return status;
        }
        if (!session->d3d_renderer) session->d3d_renderer = std::make_unique<sony2fuji::D3D11PhotoRenderer>();
        const bool raw = local.input_type == SONY2FUJI_INPUT_RAW && !viewportPreview;
        const auto& source = raw && !waveletActive ? session->raw_cache : image;
        sony2fuji::ImageData rendered;
        if (session->d3d_renderer->render(source, toCoreColorSpace(color_space), local, lut, wb,
                width, height, raw && !waveletActive ? session->raw_revision : 0, rendered,
                session->photo_effects, chromaMode, waveletActive || geometryActive, session->hsl, session->tone_controls, session->color_grading, session->tone_curve)) {
            session->last_backend = SONY2FUJI_BACKEND_D3D11;
            return finishOutput(session, local, rendered, out_buffer, native_width, native_height);
        }
        if (session->gpu_config.mode == sony2fuji::GpuMode::Force) return SONY2FUJI_STATUS_PROCESSING_ERROR;
        if (raw && !waveletActive) image = session->raw_cache;
    }
#endif
    // A pixel-radius filter must run at source resolution for preview/export parity.
    if (!atmosphereActive && !geometryActive && local.intent == SONY2FUJI_INTENT_PREVIEW && local.sharpening <= 0 && chromaMode == 0 && !effectsActive &&
        (!waveletActive || fastWavelet)) {
        uint32_t width, height;
        status = computeTargetSize(local, image.width, image.height, &width, &height);
        if (status != SONY2FUJI_STATUS_OK) return status;
        if (width != static_cast<uint32_t>(image.width) || height != static_cast<uint32_t>(image.height))
            image = resizeBilinear(image, width, height);
    }
    sony2fuji::ColorConverter converter;
    converter.convertImage(image, toCoreColorSpace(color_space), sony2fuji::ColorSpace::sRGB);
    color_space = SONY2FUJI_COLOR_SRGB;
    for (auto& pixel : image.pixels) applyExposureAndWhiteBalance(pixel, exposure, wb);

    auto lookConfig = session->gpu_config;
    if (gpuPipeline || atmosphereActive || hslActive || toneControlsActive || colorGradingActive || chromaMode != 0 || waveletActive || effectsActive)
        lookConfig.mode = sony2fuji::GpuMode::Off;
    status = applyPhotoLook(image, lut, dcp, local.lut_strength, displayInput, lookConfig);
    if (status != SONY2FUJI_STATUS_OK) return status;
    sony2fuji::applyDehaze(image, session->atmosphere.dehaze, &session->dehaze_analysis);
    sony2fuji::applyBlackWhite(image, session->tone_controls);
    applyToneAdjustments(image, local, session->tone_curve);
    sony2fuji::applyVibrance(image, session->tone_controls);
    if (pre_hsl) {
        status = finishGeometry(session, local, image, native_width, native_height);
        if (status == SONY2FUJI_STATUS_OK) *pre_hsl = std::move(image);
        return status;
    }
    sony2fuji::applyHsl(image, session->hsl);
    sony2fuji::applyColorGrading(image, session->color_grading);
    const auto chromaResult = sony2fuji::applyChromaDenoiseWorking(image, chromaMode);
    if (chromaResult != sony2fuji::ErrorCode::Success) return mapError(chromaResult);
    applyDetailAdjustments(image, local, session->atmosphere.clarity);
    sony2fuji::applyPhotoEffects(image, session->photo_effects);

    return finishOutput(session, local, image, out_buffer, native_width, native_height);
}

sony2fuji_status sony2fuji_process(sony2fuji_session* session,
    const sony2fuji_request* request, sony2fuji_buffer* buffer) {
    try {
        return processImpl(session, request, buffer);
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    } catch (const sony2fuji::ai::NotReady&) {
        return SONY2FUJI_STATUS_AI_NOT_READY;
    } catch (const sony2fuji::ai::Unsupported&) {
        return SONY2FUJI_STATUS_UNSUPPORTED;
#endif
    } catch (const std::exception&) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

sony2fuji_status sony2fuji_session_create_hsl_probe(sony2fuji_session* session,
    const sony2fuji_request* request, uint64_t source_revision, uint64_t request_revision,
    sony2fuji_hsl_probe** out_probe) {
    if (out_probe) *out_probe = nullptr;
    if (!session || !request || !out_probe || request->output_target != SONY2FUJI_TARGET_BUFFER)
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    // 分析明确使用 CPU；临时策略和已发布渲染的元信息不能泄漏到后续调用。
    struct Restore {
        sony2fuji_session& session;
        sony2fuji::GpuConfig gpu;
        sony2fuji_render_backend backend;
        uint32_t width, height;
        ~Restore() {
            session.gpu_config = gpu; session.last_backend = backend;
            session.geometry_width = width; session.geometry_height = height;
        }
    } restore{*session, session->gpu_config, session->last_backend,
        session->geometry_width, session->geometry_height};
    session->gpu_config.mode = sony2fuji::GpuMode::Off;
    try {
        auto probe = std::make_unique<sony2fuji_hsl_probe>();
        sony2fuji_buffer unused{};
        const auto status = processImpl(session, request, &unused, &probe->image);
        if (status != SONY2FUJI_STATUS_OK) return status;
        probe->source_revision = source_revision; probe->request_revision = request_revision;
        probe->quality = request->intent == SONY2FUJI_INTENT_PREVIEW ?
            SONY2FUJI_HSL_PROBE_PREVIEW_CPU : SONY2FUJI_HSL_PROBE_EXACT_CPU;
        *out_probe = probe.release();
        return SONY2FUJI_STATUS_OK;
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    } catch (const sony2fuji::ai::NotReady&) {
        return SONY2FUJI_STATUS_AI_NOT_READY;
    } catch (const sony2fuji::ai::Unsupported&) {
        return SONY2FUJI_STATUS_UNSUPPORTED;
#endif
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

sony2fuji_status sony2fuji_hsl_probe_sample(const sony2fuji_hsl_probe* probe,
    const sony2fuji_hsl_probe_query* query, sony2fuji_hsl_probe_result* result) {
    if (result) *result = {};
    if (!probe || !query || !result || query->version != SONY2FUJI_HSL_PROBE_VERSION ||
        query->struct_size != sizeof(*query)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    result->version = SONY2FUJI_HSL_PROBE_VERSION; result->struct_size = sizeof(*result);
    result->source_revision = probe->source_revision; result->request_revision = probe->request_revision;
    result->width = probe->image.width; result->height = probe->image.height; result->quality = probe->quality;
    if (query->source_revision != probe->source_revision || query->request_revision != probe->request_revision) {
        result->availability = SONY2FUJI_HSL_PROBE_STALE; return SONY2FUJI_STATUS_OK;
    }
    if (!std::isfinite(query->x) || !std::isfinite(query->y) || query->x < 0 || query->x > 1 ||
        query->y < 0 || query->y > 1) {
        result->availability = SONY2FUJI_HSL_PROBE_OUTSIDE; return SONY2FUJI_STATUS_OK;
    }
    const auto& image = probe->image;
    const double x = double(query->x) * (image.width-1), y = double(query->y) * (image.height-1);
    const int left = static_cast<int>(x), top = static_cast<int>(y);
    const int right = std::min(left+1, image.width-1), bottom = std::min(top+1, image.height-1);
    const float dx = static_cast<float>(x-left), dy = static_cast<float>(y-top);
    const auto mix = [](const sony2fuji::RGB& a, const sony2fuji::RGB& b, float t) {
        return sony2fuji::RGB(a.r+(b.r-a.r)*t, a.g+(b.g-a.g)*t, a.b+(b.b-a.b)*t);
    };
    const auto pixel = mix(mix(image.at(left,top),image.at(right,top),dx),
        mix(image.at(left,bottom),image.at(right,bottom),dx),dy);
    if (!std::isfinite(pixel.r) || !std::isfinite(pixel.g) || !std::isfinite(pixel.b)) {
        result->availability = SONY2FUJI_HSL_PROBE_NONFINITE; return SONY2FUJI_STATUS_OK;
    }
    result->rgb[0] = pixel.r; result->rgb[1] = pixel.g; result->rgb[2] = pixel.b;
    const auto color = sony2fuji::analyzeHslColor(pixel);
    if (!color.valid || color.spread < 1.f/255) {
        result->availability = SONY2FUJI_HSL_PROBE_NEAR_GRAY; return SONY2FUJI_STATUS_OK;
    }
    result->hsl[0] = color.hue; result->hsl[1] = std::clamp(color.saturation,0.f,1.f);
    result->hsl[2] = color.lightness;
    const auto weights = color.weights(); std::copy(weights.begin(), weights.end(), result->weights);
    result->availability = SONY2FUJI_HSL_PROBE_AVAILABLE;
    return SONY2FUJI_STATUS_OK;
}

void sony2fuji_hsl_probe_destroy(sony2fuji_hsl_probe* probe) { delete probe; }

sony2fuji_status sony2fuji_compute_histogram(
    const sony2fuji_buffer* buffer,
    uint32_t bins,
    float* out_bins
) {
    if (!buffer || !buffer->data || !out_bins || bins == 0) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    if (buffer->width == 0 || buffer->height == 0 || buffer->stride_bytes == 0) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    if (buffer->pixel_format != SONY2FUJI_PIXEL_RGB8 &&
        buffer->pixel_format != SONY2FUJI_PIXEL_RGBA8) {
        return SONY2FUJI_STATUS_UNSUPPORTED;
    }

    uint32_t channels = buffer->pixel_format == SONY2FUJI_PIXEL_RGBA8 ? 4 : 3;
    const uint8_t* data = static_cast<const uint8_t*>(buffer->data);
    std::vector<uint32_t> counts(bins, 0);

    for (uint32_t y = 0; y < buffer->height; ++y) {
        const uint8_t* row = data + static_cast<size_t>(y) * buffer->stride_bytes;
        for (uint32_t x = 0; x < buffer->width; ++x) {
            size_t offset = static_cast<size_t>(x) * channels;
            float r = row[offset] / 255.0f;
            float g = row[offset + 1] / 255.0f;
            float b = row[offset + 2] / 255.0f;
            float l = 0.2126f * r + 0.7152f * g + 0.0722f * b;
            uint32_t bin = static_cast<uint32_t>(l * static_cast<float>(bins - 1));
            if (bin >= bins) {
                bin = bins - 1;
            }
            counts[bin] += 1;
        }
    }

    float max_value = 0.0f;
    for (uint32_t i = 0; i < bins; ++i) {
        float value = static_cast<float>(counts[i]);
        out_bins[i] = value;
        if (value > max_value) {
            max_value = value;
        }
    }

    if (max_value > 0.0f) {
        for (uint32_t i = 0; i < bins; ++i) {
            out_bins[i] = out_bins[i] / max_value;
        }
    }

    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_analyze_image(
    const sony2fuji_buffer* image, sony2fuji_gpu_mode mode, uint32_t* rgb_bins,
    uint32_t* shadows, uint32_t* highlights, sony2fuji_buffer* clipping_mask
) {
    if (!image || !image->data || !rgb_bins || !shadows || !highlights ||
        mode < SONY2FUJI_GPU_OFF || mode > SONY2FUJI_GPU_FORCE || image->width == 0 || image->height == 0 ||
        image->width > UINT32_MAX / 4 || static_cast<uint64_t>(image->width)*image->height > UINT32_MAX)
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    const size_t channels = image->pixel_format == SONY2FUJI_PIXEL_RGBA8 ? 4 :
        (image->pixel_format == SONY2FUJI_PIXEL_RGB8 ? 3 : 0);
    if (!channels || static_cast<size_t>(image->width)*channels > image->stride_bytes ||
        static_cast<uint64_t>(image->stride_bytes)*(image->height-1) +
            static_cast<uint64_t>(image->width)*channels > image->size_bytes)
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    try {
        sony2fuji::ImageStats stats;
        bool complete = false;
#if defined(SONY2FUJI_ENABLE_METAL)
        // These pixels already live on the CPU. Upload/readback costs more than
        // the optimized counting loop on measured Apple Silicon workloads.
        if (mode == SONY2FUJI_GPU_FORCE) complete = sony2fuji::computeImageStatsMetal(*image, stats);
#endif
        if (!complete) {
            if (mode == SONY2FUJI_GPU_FORCE) return SONY2FUJI_STATUS_PROCESSING_ERROR;
            if (!sony2fuji::computeImageStatsCPU(*image, stats, clipping_mask != nullptr)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
        }
        if (clipping_mask) {
            void* data = std::malloc(stats.clipping.size());
            if (!data) return SONY2FUJI_STATUS_OUT_OF_MEMORY;
            std::memcpy(data, stats.clipping.data(), stats.clipping.size());
            *clipping_mask = {data, stats.clipping.size(), image->width, image->height,
                image->width*4, SONY2FUJI_PIXEL_RGBA8};
        }
        std::copy(stats.histogram.begin(), stats.histogram.end(), rgb_bins);
        *shadows = stats.shadows; *highlights = stats.highlights;
        return SONY2FUJI_STATUS_OK;
    } catch (const std::bad_alloc&) { return SONY2FUJI_STATUS_OUT_OF_MEMORY; }
      catch (const std::exception&) { return SONY2FUJI_STATUS_PROCESSING_ERROR; }
}

void sony2fuji_release_buffer(sony2fuji_buffer* buffer) {
    if (!buffer || !buffer->data) {
        return;
    }

    std::free(buffer->data);
    buffer->data = nullptr;
    buffer->size_bytes = 0;
    buffer->width = 0;
    buffer->height = 0;
    buffer->stride_bytes = 0;
    buffer->pixel_format = SONY2FUJI_PIXEL_RGB8;
}

const char* sony2fuji_status_message(sony2fuji_status status) {
    switch (status) {
        case SONY2FUJI_STATUS_OK:
            return "ok";
        case SONY2FUJI_STATUS_INVALID_ARGUMENT:
            return "invalid argument";
        case SONY2FUJI_STATUS_UNSUPPORTED:
            return "unsupported";
        case SONY2FUJI_STATUS_IO_ERROR:
            return "io error";
        case SONY2FUJI_STATUS_OUTPUT_IO_ERROR:
            return "output io error";
        case SONY2FUJI_STATUS_PROCESSING_ERROR:
            return "processing error";
        case SONY2FUJI_STATUS_OUT_OF_MEMORY:
            return "out of memory";
        case SONY2FUJI_STATUS_CANCELLED:
            return "cancelled";
        case SONY2FUJI_STATUS_AI_NOT_READY:
            return "AI denoising result is not ready";
        default:
            return "unknown";
    }
}
