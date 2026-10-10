#include "sony2fuji/ffi/sony2fuji_c.h"

#include "sony2fuji/sony2fuji.h"
#include "sony2fuji/dcp_look.h"
#include "core/photo_rendering.h"
#include "core/chroma_denoise.h"
#include "core/wavelet_denoise.h"
#include "core/photo_effects.h"
#include "core/photo_lut.h"
#include "gpu/image_stats.h"
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
    sony2fuji::WaveletDenoiseOptions wavelet_denoise;
    sony2fuji::PhotoEffectsOptions photo_effects;
    sony2fuji::ImageData wavelet_cache;
    std::string wavelet_key;
    sony2fuji::WaveletDenoiseOptions wavelet_cache_options;
    sony2fuji::GpuMode wavelet_cache_mode = sony2fuji::GpuMode::Off;
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
    sony2fuji_render_backend last_backend = SONY2FUJI_BACKEND_CPU;
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

namespace {

// ============================================================================
// Utilities
// ============================================================================

bool isEmptyString(const char* value) {
    return value == nullptr || value[0] == '\0';
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
    } else if (request->input_type == SONY2FUJI_INPUT_BUFFER) {
        if (!request->input_pixels || request->input_width == 0 || request->input_height == 0) {
            return SONY2FUJI_STATUS_INVALID_ARGUMENT;
        }
    } else {
        return SONY2FUJI_STATUS_UNSUPPORTED;
    }

    if (request->output_target == SONY2FUJI_TARGET_FILE) {
        if (isEmptyString(request->output_path)) {
            return SONY2FUJI_STATUS_INVALID_ARGUMENT;
        }
        if (request->input_type == SONY2FUJI_INPUT_RAW) {
            std::error_code error;
            const auto inputPath = std::filesystem::u8path(request->input_path);
            const auto outputPath = std::filesystem::u8path(request->output_path);
            const bool sameFile = std::filesystem::equivalent(inputPath, outputPath, error);
            if (sameFile || std::filesystem::weakly_canonical(inputPath) ==
                std::filesystem::weakly_canonical(outputPath))
                return SONY2FUJI_STATUS_INVALID_ARGUMENT;
        }
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
    if (request.output_target == SONY2FUJI_TARGET_FILE) {
        if (request.output_format == SONY2FUJI_OUTPUT_JPEG ||
            request.output_format == SONY2FUJI_OUTPUT_PNG) {
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

void applyToneAdjustments(sony2fuji::ImageData& image, const sony2fuji_request& request) {
    if (!needsToneAdjustments(request)) {
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
        if (use_curve) {
            pixel.r = applyToneCurve(pixel.r, curve);
            pixel.g = applyToneCurve(pixel.g, curve);
            pixel.b = applyToneCurve(pixel.b, curve);
        }
        if (contrast != 1.0f || saturation != 1.0f) {
            applyContrastSaturation(pixel, contrast, saturation);
        }
    }
}

sony2fuji::RGB sumRow3(const sony2fuji::ImageData& image, int y, int x0, int x1, int x2) {
    const sony2fuji::RGB& c0 = image.at(x0, y);
    const sony2fuji::RGB& c1 = image.at(x1, y);
    const sony2fuji::RGB& c2 = image.at(x2, y);
    return sony2fuji::RGB(c0.r + c1.r + c2.r, c0.g + c1.g + c2.g, c0.b + c1.b + c2.b);
}

std::vector<sony2fuji::RGB> blurImage(const sony2fuji::ImageData& image) {
    std::vector<sony2fuji::RGB> output(image.pixels.size());
    int width = image.width;
    int height = image.height;
    if (width <= 0 || height <= 0) {
        return output;
    }

    for (int y = 0; y < height; ++y) {
        int y0 = std::max(0, y - 1);
        int y1 = y;
        int y2 = std::min(height - 1, y + 1);
        for (int x = 0; x < width; ++x) {
            int x0 = std::max(0, x - 1);
            int x1 = x;
            int x2 = std::min(width - 1, x + 1);
            sony2fuji::RGB sum = sumRow3(image, y0, x0, x1, x2);
            sony2fuji::RGB row1 = sumRow3(image, y1, x0, x1, x2);
            sony2fuji::RGB row2 = sumRow3(image, y2, x0, x1, x2);
            sum.r += row1.r + row2.r;
            sum.g += row1.g + row2.g;
            sum.b += row1.b + row2.b;
            output[static_cast<size_t>(y) * width + x] = sony2fuji::RGB(
                sum.r / 9.0f,
                sum.g / 9.0f,
                sum.b / 9.0f
            );
        }
    }

    return output;
}

void applyNoiseReduction(sony2fuji::ImageData& image, float amount) {
    float strength = clampFloat(amount, 0.0f, 1.0f);
    if (strength <= 0.0f) {
        return;
    }

    std::vector<sony2fuji::RGB> blurred = blurImage(image);
    float blend = strength * 0.4f;
    for (size_t i = 0; i < image.pixels.size(); ++i) {
        image.pixels[i] = lerpRGB(image.pixels[i], blurred[i], blend);
    }
}

void applySharpening(sony2fuji::ImageData& image, float amount) {
    float strength = clampFloat(amount, 0.0f, 2.0f);
    if (strength <= 0.0f) {
        return;
    }

    std::vector<sony2fuji::RGB> blurred = blurImage(image);
    for (size_t i = 0; i < image.pixels.size(); ++i) {
        sony2fuji::RGB current = image.pixels[i];
        sony2fuji::RGB blur = blurred[i];
        current.r = clamp01(current.r + strength * (current.r - blur.r));
        current.g = clamp01(current.g + strength * (current.g - blur.g));
        current.b = clamp01(current.b + strength * (current.b - blur.b));
        image.pixels[i] = current;
    }
}

void applyDetailAdjustments(sony2fuji::ImageData& image, const sony2fuji_request& request) {
    if (request.noise_reduction > 0.0f) {
        applyNoiseReduction(image, request.noise_reduction);
    }
    if (request.sharpening > 0.0f) {
        applySharpening(image, request.sharpening);
    }
}

bool isLutDiagnosticsEnabled() {
    const char* value = std::getenv("SONY2FUJI_LUT_DIAG");
    return value != nullptr && value[0] != '\0';
}

void applyFLog2Encoding(sony2fuji::ImageData& image, bool clamp_only) {
    sony2fuji::GammaConverter::FLog2Options options;
    options.normalizeToRange = !clamp_only;
    options.clampOnly = clamp_only;
    options.enableDiagnostics = isLutDiagnosticsEnabled();

    sony2fuji::GammaConverter::FLog2Diagnostics diagnostics =
        sony2fuji::GammaConverter::applyFLog2ToImage(image, options);
    if (options.enableDiagnostics) {
        std::fprintf(
            stderr,
            "F-Log2 diagnostics: min=%f max=%f scale=%f offset=%f neg=%zu over=%zu\n",
            diagnostics.min_linear,
            diagnostics.max_linear,
            diagnostics.scale,
            diagnostics.offset,
            diagnostics.negative_pixels,
            diagnostics.over_pixels
        );
    }
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

sony2fuji_status loadRawImage(
    sony2fuji_session* session, const sony2fuji_request& request,
    sony2fuji::ImageData& image, sony2fuji_color_space* space, bool* is_linear,
    bool copyImage = true
) {
    std::error_code fileError;
    const auto inputPath = std::filesystem::u8path(request.input_path);
    const auto modified = std::filesystem::last_write_time(inputPath, fileError);
    if (fileError) return SONY2FUJI_STATUS_IO_ERROR;
    const auto fileSize = std::filesystem::file_size(inputPath, fileError);
    if (fileError) return SONY2FUJI_STATUS_IO_ERROR;
    const auto modifiedNanoseconds = std::chrono::duration_cast<std::chrono::nanoseconds>(
        modified.time_since_epoch()).count();
    const std::string fileKey = std::string(request.input_path) + ":" +
        std::to_string(modifiedNanoseconds) + ":" + std::to_string(fileSize);
    const bool interactive = session->interactive_preview && session->raw_noise_reduction == 0 && session->chroma_denoise == 0 &&
        !session->photo_effects.active() &&
        request.intent == SONY2FUJI_INTENT_PREVIEW &&
        request.output_target == SONY2FUJI_TARGET_BUFFER &&
        !(session->raw_exposure_mode == SONY2FUJI_EXPOSURE_PREVIEW && request.wb_mode == SONY2FUJI_WB_CAMERA);
    std::string key = fileKey + ":" + std::to_string(request.wb_mode) +
        ":" + std::to_string(session->raw_exposure_mode) + ":" + std::to_string(session->raw_noise_reduction);
    for (float multiplier : request.wb_mul) key += ":" + std::to_string(multiplier);
    if (request.wb_mode == SONY2FUJI_WB_TEMPERATURE)
        key += ":" + std::to_string(request.temperature) + ":" + std::to_string(request.tint);
    // A full-quality cache can serve a proxy, but never the reverse. Non-WB
    // sliders should not trigger another demosaic just because dragging began.
    const std::string exactKey = key + ":exact";
    key += interactive && session->raw_key != exactKey ? ":interactive" : ":exact";
    if (session->raw_key != key || session->raw_cache.pixels.empty()) {
        session->wavelet_cache = {};
        session->wavelet_key.clear();
        const bool anchoredPreview = session->raw_exposure_mode == SONY2FUJI_EXPOSURE_PREVIEW &&
            request.wb_mode == SONY2FUJI_WB_TEMPERATURE;
        if (anchoredPreview && session->preview_exposure_key != fileKey) {
            auto reference = request;
            reference.wb_mode = SONY2FUJI_WB_CAMERA;
            const auto status = loadRawImage(session, reference, image, space, is_linear);
            image = {};
            if (status != SONY2FUJI_STATUS_OK) return status;
        }
        if (!session->raw_processor || session->processor_key != fileKey) {
            auto processor = std::make_unique<sony2fuji::RAWProcessor>();
            const auto loaded = processor->loadFile(request.input_path);
            if (loaded != sony2fuji::ErrorCode::Success) return mapError(loaded);
            session->raw_processor = std::move(processor);
            session->processor_key = fileKey;
        }
        auto& processor = *session->raw_processor;
        sony2fuji::RAWProcessOptions options;
        options.halfSize = interactive;
        options.rawNoiseReduction = session->raw_noise_reduction;
        options.outputLinear = true;
        options.outputAdobe = true;
        options.matchEmbeddedPreviewExposure = session->raw_exposure_mode == SONY2FUJI_EXPOSURE_PREVIEW && !anchoredPreview;
        options.applyBaselineExposure = session->raw_exposure_mode != SONY2FUJI_EXPOSURE_SENSOR && !anchoredPreview;
        if (anchoredPreview) options.exposure = session->preview_camera_ev;
        options.useCameraWhiteBalance = request.wb_mode == SONY2FUJI_WB_CAMERA;
        options.useAutoWhiteBalance = request.wb_mode == SONY2FUJI_WB_AUTO;
        options.useCustomWhiteBalance = request.wb_mode == SONY2FUJI_WB_CUSTOM;
        options.useTemperatureWhiteBalance = request.wb_mode == SONY2FUJI_WB_TEMPERATURE;
        options.temperature=request.temperature; options.tint=request.tint;
        std::copy(std::begin(request.wb_mul), std::end(request.wb_mul), options.customWhiteBalance);
        sony2fuji::ImageData decoded;
        auto result = processor.process(options, decoded);
        if (result != sony2fuji::ErrorCode::Success) {
            session->raw_processor.reset(); session->processor_key.clear();
            return mapError(result);
        }
        session->raw_cache = std::move(decoded);
#if defined(SONY2FUJI_ENABLE_GLES) || defined(SONY2FUJI_ENABLE_D3D11)
        ++session->raw_revision;
#endif
        session->raw_key = key;
        session->raw_noise_reduction_supported = processor.supportsNoiseReduction();
        session->baseline_ev = anchoredPreview ? session->preview_camera_ev : processor.getBaselineExposureEV();
        session->metadata_ev = processor.getMetadataExposureEV();
        session->calibrated_wb = processor.getAsShotWhiteBalance(session->as_shot_temperature,session->as_shot_tint);
        if (session->raw_exposure_mode == SONY2FUJI_EXPOSURE_PREVIEW && request.wb_mode == SONY2FUJI_WB_CAMERA) {
            session->preview_exposure_key = fileKey;
            session->preview_camera_ev = session->baseline_ev;
        }
    }
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

sony2fuji_status sony2fuji_session_set_interactive_preview(sony2fuji_session* session, int32_t enabled) {
    if (!session || (enabled != 0 && enabled != 1)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    session->interactive_preview = enabled != 0;
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
    const sony2fuji::WaveletDenoiseOptions options{config->enabled != 0,config->luma,config->chroma,config->coarse};
    if (!sony2fuji::validWaveletDenoiseOptions(options)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    if (options.active() && !sony2fuji::waveletDenoiseAvailable()) return SONY2FUJI_STATUS_UNSUPPORTED;
    if (!(options == session->wavelet_denoise)) {
        session->wavelet_cache = {};
        session->wavelet_key.clear();
    }
    session->wavelet_denoise = options;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_get_raw_noise_reduction_support(
    const sony2fuji_session* session, int32_t* supported
) {
    if (!session || !supported || session->raw_cache.pixels.empty())
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    *supported = session->raw_noise_reduction_supported ? 1 : 0;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_get_raw_exposure(
    const sony2fuji_session* session, float* baseline_ev, float* metadata_ev
) {
    if (!session || !baseline_ev || !metadata_ev || session->raw_cache.pixels.empty())
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    *baseline_ev = session->baseline_ev;
    *metadata_ev = session->metadata_ev;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_get_raw_white_balance(
    const sony2fuji_session* session, float* temperature, float* tint
) {
    if (!session || !temperature || !tint || session->raw_cache.pixels.empty())
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

static sony2fuji_status processImpl(
    sony2fuji_session* session,
    const sony2fuji_request* request,
    sony2fuji_buffer* out_buffer
) {
    if (!session) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }

    sony2fuji_status status = validateRequest(request, out_buffer);
    if (status != SONY2FUJI_STATUS_OK) {
        return status;
    }

    status = validateOutputFormat(*request);
    if (status != SONY2FUJI_STATUS_OK) {
        return status;
    }

    sony2fuji_request local = *request;
    local.lut_strength = clampFloat(local.lut_strength, 0.0f, 2.0f);
    session->last_backend = SONY2FUJI_BACKEND_CPU;
    const bool waveletActive = session->wavelet_denoise.active();
    const bool effectsActive = session->photo_effects.active();
#if defined(SONY2FUJI_ENABLE_METAL)
    const bool cpuOnlyStages = false;
#else
    const bool cpuOnlyStages = effectsActive || waveletActive || session->chroma_denoise != 0;
#endif
    const bool fastWavelet = waveletActive && !effectsActive && session->chroma_denoise == 0 && session->interactive_preview &&
        local.intent == SONY2FUJI_INTENT_PREVIEW && local.output_target == SONY2FUJI_TARGET_BUFFER;
    if (cpuOnlyStages && session->gpu_config.mode == sony2fuji::GpuMode::Force)
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
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
    bool gpuPipeline = session->gpu_config.mode != sony2fuji::GpuMode::Off;
#elif defined(SONY2FUJI_ENABLE_GLES) || defined(SONY2FUJI_ENABLE_D3D11)
    bool gpuPipeline = session->chroma_denoise == 0 && !waveletActive && !effectsActive && !dcp && session->gpu_config.mode != sony2fuji::GpuMode::Off;
#else
    bool gpuPipeline = false;
#endif

    sony2fuji::ImageData image;
    sony2fuji_color_space color_space = SONY2FUJI_COLOR_SRGB;
    bool is_linear = false;
    if (local.input_type == SONY2FUJI_INPUT_RAW) {
        status = loadRawImage(session, local, image, &color_space, &is_linear, !gpuPipeline || waveletActive);
    } else {
        status = loadBufferImage(local, image, &color_space, &is_linear);
    }
    if (status != SONY2FUJI_STATUS_OK) return status;
    status = ensureLinear(image, color_space, &is_linear);
    if (status != SONY2FUJI_STATUS_OK) return status;
    if (color_space == SONY2FUJI_COLOR_SONY_NATIVE) return SONY2FUJI_STATUS_UNSUPPORTED;

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
        sony2fuji::ColorConverter converter;
        converter.convertImage(image, toCoreColorSpace(color_space), sony2fuji::ColorSpace::sRGB);
        color_space = SONY2FUJI_COLOR_SRGB;
        const bool cacheable = local.input_type == SONY2FUJI_INPUT_RAW && !fastWavelet;
        if (cacheable && session->wavelet_key == session->raw_key &&
            session->wavelet_cache_options == session->wavelet_denoise &&
            session->wavelet_cache_mode == session->gpu_config.mode && !session->wavelet_cache.pixels.empty()) {
            image = session->wavelet_cache;
        } else {
            const auto mode = gpuPipeline ? sony2fuji::GpuMode::Force : sony2fuji::GpuMode::Off;
            auto result = sony2fuji::applyWaveletDenoise(image, session->wavelet_denoise, nullptr, mode);
            const bool fallback = result != sony2fuji::ErrorCode::Success && session->gpu_config.mode == sony2fuji::GpuMode::Auto;
            if (fallback) {
                gpuPipeline = false;
                result = sony2fuji::applyWaveletDenoise(image, session->wavelet_denoise);
            }
            if (result != sony2fuji::ErrorCode::Success) return mapError(result);
            if (cacheable && !fallback) {
                session->wavelet_cache = image;
                session->wavelet_key = session->raw_key;
                session->wavelet_cache_options = session->wavelet_denoise;
                session->wavelet_cache_mode = session->gpu_config.mode;
            }
        }
    }
#if defined(SONY2FUJI_ENABLE_METAL)
    if (gpuPipeline) {
        uint32_t width, height;
        status = computeTargetSize(local, image.width, image.height, &width, &height);
        if (status != SONY2FUJI_STATUS_OK) return status;
        const auto& source = local.input_type == SONY2FUJI_INPUT_RAW && !waveletActive ? session->raw_cache : image;
        sony2fuji::ImageData rendered;
        if (sony2fuji::renderPhotoMetal(source, toCoreColorSpace(color_space), local, lut, wb, width, height, rendered,
                dcp, session->photo_effects, session->chroma_denoise, waveletActive)) {
            session->last_backend = SONY2FUJI_BACKEND_METAL;
            if (local.output_target == SONY2FUJI_TARGET_FILE) return writeOutputFile(local, rendered);
            return writeOutputBuffer(local, rendered, out_buffer);
        }
        if (session->gpu_config.mode == sony2fuji::GpuMode::Force) return SONY2FUJI_STATUS_PROCESSING_ERROR;
        if (local.input_type == SONY2FUJI_INPUT_RAW && !waveletActive) image = session->raw_cache;
    }
#endif
#if defined(SONY2FUJI_ENABLE_GLES)
    if (gpuPipeline) {
        uint32_t width, height;
        status = computeTargetSize(local, image.width, image.height, &width, &height);
        if (status != SONY2FUJI_STATUS_OK) return status;
        if (!session->gles_renderer) session->gles_renderer = std::make_unique<sony2fuji::GlesPhotoRenderer>();
        const bool raw = local.input_type == SONY2FUJI_INPUT_RAW;
        const auto& source = raw ? session->raw_cache : image;
        sony2fuji::ImageData rendered;
        if (session->gles_renderer->render(source, toCoreColorSpace(color_space), local, lut, wb,
                width, height, raw ? session->raw_revision : 0, rendered)) {
            session->last_backend = SONY2FUJI_BACKEND_GLES;
            if (local.output_target == SONY2FUJI_TARGET_FILE) return writeOutputFile(local, rendered);
            return writeOutputBuffer(local, rendered, out_buffer);
        }
        if (session->gpu_config.mode == sony2fuji::GpuMode::Force) return SONY2FUJI_STATUS_PROCESSING_ERROR;
        if (raw) image = session->raw_cache;
    }
#endif
#if defined(SONY2FUJI_ENABLE_D3D11)
    if (gpuPipeline) {
        uint32_t width, height;
        status = computeTargetSize(local, image.width, image.height, &width, &height);
        if (status != SONY2FUJI_STATUS_OK) return status;
        if (!session->d3d_renderer) session->d3d_renderer = std::make_unique<sony2fuji::D3D11PhotoRenderer>();
        const bool raw = local.input_type == SONY2FUJI_INPUT_RAW;
        const auto& source = raw ? session->raw_cache : image;
        sony2fuji::ImageData rendered;
        if (session->d3d_renderer->render(source, toCoreColorSpace(color_space), local, lut, wb,
                width, height, raw ? session->raw_revision : 0, rendered)) {
            session->last_backend = SONY2FUJI_BACKEND_D3D11;
            if (local.output_target == SONY2FUJI_TARGET_FILE) return writeOutputFile(local, rendered);
            return writeOutputBuffer(local, rendered, out_buffer);
        }
        if (session->gpu_config.mode == sony2fuji::GpuMode::Force) return SONY2FUJI_STATUS_PROCESSING_ERROR;
        if (raw) image = session->raw_cache;
    }
#endif
    // A pixel-radius filter must run at source resolution for preview/export parity.
    if (local.intent == SONY2FUJI_INTENT_PREVIEW && local.sharpening <= 0 && session->chroma_denoise == 0 && !effectsActive &&
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

    sony2fuji::ImageData base = image;
    for (auto& p : base.pixels) {
        p.r = sony2fuji::neutralDisplay(p.r);
        p.g = sony2fuji::neutralDisplay(p.g);
        p.b = sony2fuji::neutralDisplay(p.b);
    }
    if (use_lut) {
        if (dcp) {
            const size_t count = image.pixels.size();
#ifdef _OPENMP
#pragma omp parallel for if (count >= (1u << 16))
#endif
            for (size_t i = 0; i < count; ++i) image.pixels[i] = dcp->apply(image.pixels[i]);
        } else {
            if (lut->inputTransfer() != sony2fuji::LUTTransfer::FLog2) {
                sony2fuji::encodePhotoLUTInput(image, lut->inputTransfer());
            } else {
                converter.convertImage(image, sony2fuji::ColorSpace::sRGB, sony2fuji::ColorSpace::FujiFilm_FGamut);
                applyFLog2Encoding(image, false);
            }
            auto config = session->gpu_config;
            if (gpuPipeline || session->chroma_denoise != 0 || waveletActive || effectsActive) config.mode = sony2fuji::GpuMode::Off;
            auto result = sony2fuji::applyLUTWithConfig(lut, image, config);
            if (result != sony2fuji::ErrorCode::Success) return mapError(result);
            sony2fuji::renderPhotoLUTOutput(image, lut->outputTransfer());
        }
        for (size_t i=0; i<image.pixels.size(); ++i)
            image.pixels[i] = lerpRGB(base.pixels[i], image.pixels[i], local.lut_strength);
    } else {
        image = std::move(base);
    }
    applyToneAdjustments(image, local);
    const auto chromaResult = sony2fuji::applyChromaDenoise(image, session->chroma_denoise);
    if (chromaResult != sony2fuji::ErrorCode::Success) return mapError(chromaResult);
    applyDetailAdjustments(image, local);
    sony2fuji::applyPhotoEffects(image, session->photo_effects);

    uint32_t target_width = static_cast<uint32_t>(image.width);
    uint32_t target_height = static_cast<uint32_t>(image.height);
    status = computeTargetSize(local, target_width, target_height, &target_width, &target_height);
    if (status != SONY2FUJI_STATUS_OK) {
        return status;
    }

    if (target_width != static_cast<uint32_t>(image.width) ||
        target_height != static_cast<uint32_t>(image.height)) {
        image = resizeBilinear(image, target_width, target_height);
    }

    if (local.output_target == SONY2FUJI_TARGET_FILE) {
        return writeOutputFile(local, image);
    }

    return writeOutputBuffer(local, image, out_buffer);
}

sony2fuji_status sony2fuji_process(sony2fuji_session* session,
    const sony2fuji_request* request, sony2fuji_buffer* buffer) {
    try {
        return processImpl(session, request, buffer);
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (const std::exception&) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

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
        case SONY2FUJI_STATUS_PROCESSING_ERROR:
            return "processing error";
        case SONY2FUJI_STATUS_OUT_OF_MEMORY:
            return "out of memory";
        default:
            return "unknown";
    }
}
