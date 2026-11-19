#include "core/render_params.h"

#include "core/rendered_dng.h"

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <limits>
#include <system_error>

namespace sony2fuji {
namespace {

// 输出像素数上限取有符号 32 位上限（约 2.14G 像素），防止尺寸相乘或核心 int 像素计数溢出。
constexpr uint64_t kMaxOutputPixels = static_cast<uint64_t>(std::numeric_limits<int32_t>::max());
// 与 libjpeg-turbo JPEG_MAX_DIMENSION、解码端 jdinput.c、Android BitmapFactory 及 preview_exposure 一致。
constexpr uint32_t kMaxJpegDimension = 65500u;

} // namespace

bool exceedsOutputPixelCap(uint32_t width, uint32_t height) {
    return uint64_t(width) * uint64_t(height) > kMaxOutputPixels;
}

bool isJpegFileOutput(const RenderParams& params) {
    return params.outputTarget == RenderOutputTarget::File &&
           params.outputFormat == RenderOutputFormat::JPEG;
}

bool isDngFileOutput(const RenderParams& params) {
    return params.outputTarget == RenderOutputTarget::File &&
           params.outputFormat == RenderOutputFormat::DNG;
}

bool exceedsOutputTargetCap(const RenderParams& params, uint32_t width, uint32_t height) {
    if (exceedsOutputPixelCap(width, height)) {
        return true;
    }
    if (isJpegFileOutput(params) && (width > kMaxJpegDimension || height > kMaxJpegDimension)) {
        return true;
    }
    // Rendered DNG uses a Classic TIFF container (<= 2^32 - 1 bytes) storing 16-bit 3-channel
    // strips, strip offset/byte-count tables, 64 KiB metadata reservation, and neutral XMP.
    if (isDngFileOutput(params) && exceedsRenderedDngCapacity(width, height)) {
        return true;
    }
    if (params.outputTarget == RenderOutputTarget::Buffer) {
        const uint64_t channels = params.outputFormat == RenderOutputFormat::RGBA8 ? 4u : 3u;
        if (uint64_t(width) * channels > std::numeric_limits<uint32_t>::max()) {
            return true;
        }
    }
    return false;
}

bool needsSourceSizePreflight(const RenderParams& params) {
    RenderSizeMode mode = params.sizeMode;
    uint32_t longEdge = params.longEdge;
    if (params.intent == RenderIntent::Preview && params.previewLongEdge > 0) {
        mode = RenderSizeMode::FitLongEdge;
        longEdge = params.previewLongEdge;
    }
    if (mode == RenderSizeMode::Exact) {
        return false;
    }
    if ((mode == RenderSizeMode::FitLongEdge || mode == RenderSizeMode::LimitLongEdge) &&
        longEdge > 0 && !exceedsOutputTargetCap(params, longEdge, longEdge)) {
        return false;
    }
    return true;
}

RenderStatus validateRenderParamsSize(const RenderParams& params) {
    RenderSizeMode mode = params.sizeMode;
    uint32_t longEdge = params.longEdge;
    uint32_t shortEdge = params.shortEdge;

    if (params.intent == RenderIntent::Preview && params.previewLongEdge > 0) {
        mode = RenderSizeMode::FitLongEdge;
        longEdge = params.previewLongEdge;
    }

    switch (mode) {
        case RenderSizeMode::Native:
            return RenderStatus::Ok;
        case RenderSizeMode::Exact:
            if (params.targetWidth == 0 || params.targetHeight == 0 ||
                exceedsOutputTargetCap(params, params.targetWidth, params.targetHeight)) {
                return RenderStatus::InvalidArgument;
            }
            return RenderStatus::Ok;
        case RenderSizeMode::FitLongEdge:
            if (longEdge == 0 ||
                (exceedsOutputTargetCap(params, longEdge, 1) &&
                 exceedsOutputTargetCap(params, 1, longEdge))) {
                return RenderStatus::InvalidArgument;
            }
            return RenderStatus::Ok;
        case RenderSizeMode::LimitLongEdge:
            if (longEdge == 0) {
                return RenderStatus::InvalidArgument;
            }
            return RenderStatus::Ok;
        case RenderSizeMode::FitShortEdge:
            if (shortEdge == 0 || exceedsOutputTargetCap(params, shortEdge, shortEdge)) {
                return RenderStatus::InvalidArgument;
            }
            return RenderStatus::Ok;
        default:
            return RenderStatus::Unsupported;
    }
}

RenderStatus validateRenderParams(const RenderParams& params, bool hasOutputBuffer) {
    const float controls[] = {params.exposureEV, params.brightness, params.contrast,
        params.saturation, params.temperature, params.tint, params.lutStrength,
        params.highlights, params.shadows, params.toneCurve, params.noiseReduction,
        params.sharpening};
    for (float value : controls) {
        if (!std::isfinite(value)) return RenderStatus::InvalidArgument;
    }
    if (std::abs(params.exposureEV) > 20 || params.brightness <= 0) {
        return RenderStatus::InvalidArgument;
    }
    if (params.wbMode == RenderWhiteBalanceMode::Temperature &&
        (params.inputType != RenderInputType::Raw || params.temperature < 2000 ||
         params.temperature > 50000 || std::abs(params.tint) > 150)) {
        return RenderStatus::InvalidArgument;
    }
    if (params.wbMode == RenderWhiteBalanceMode::Custom) {
        for (int c = 0; c < 3; ++c) {
            if (!std::isfinite(params.wbMul[c]) || params.wbMul[c] <= 0) {
                return RenderStatus::InvalidArgument;
            }
        }
    }

    if (params.inputType == RenderInputType::Raw) {
        if (params.inputPath.empty()) {
            return RenderStatus::InvalidArgument;
        }
    } else if (params.inputType == RenderInputType::Buffer ||
               params.inputType == RenderInputType::DisplayBuffer) {
        if (!params.inputPixels || params.inputWidth == 0 || params.inputHeight == 0 ||
            exceedsOutputPixelCap(params.inputWidth, params.inputHeight)) {
            return RenderStatus::InvalidArgument;
        }
        if (params.inputType == RenderInputType::DisplayBuffer &&
            (params.inputColorSpace != ColorSpace::sRGB || params.inputIsLinear ||
             params.wbMode != RenderWhiteBalanceMode::Camera ||
             params.temperature != 6500.0f || params.tint != 0.0f)) {
            return RenderStatus::Unsupported;
        }
    } else {
        return RenderStatus::Unsupported;
    }

    if (params.outputTarget == RenderOutputTarget::File) {
        if (params.outputPath.empty()) {
            return RenderStatus::InvalidArgument;
        }
        const auto overwrites = [&](const std::string& source) {
            std::error_code error;
            const auto inputPath = std::filesystem::u8path(source);
            const auto outputPath = std::filesystem::u8path(params.outputPath);
            return std::filesystem::equivalent(inputPath, outputPath, error) ||
                   std::filesystem::weakly_canonical(inputPath) == std::filesystem::weakly_canonical(outputPath);
        };
        if (((params.inputType == RenderInputType::Raw || params.inputType == RenderInputType::DisplayBuffer) &&
             !params.inputPath.empty() && overwrites(params.inputPath)) ||
            (!params.lutPath.empty() && overwrites(params.lutPath))) {
            return RenderStatus::InvalidArgument;
        }
    } else if (params.outputTarget == RenderOutputTarget::Buffer) {
        if (!hasOutputBuffer) {
            return RenderStatus::InvalidArgument;
        }
    } else {
        return RenderStatus::Unsupported;
    }

    return RenderStatus::Ok;
}

RenderStatus validateRenderOutputFormat(const RenderParams& params) {
    if (params.outputFormat == RenderOutputFormat::DNG &&
        params.intent != RenderIntent::Final) {
        return RenderStatus::Unsupported;
    }
    if (params.outputTarget == RenderOutputTarget::File) {
        if (params.outputFormat == RenderOutputFormat::JPEG ||
            params.outputFormat == RenderOutputFormat::PNG ||
            params.outputFormat == RenderOutputFormat::DNG) {
            return RenderStatus::Ok;
        }
        return RenderStatus::Unsupported;
    }

    if (params.outputFormat == RenderOutputFormat::RGB8 ||
        params.outputFormat == RenderOutputFormat::RGBA8) {
        return RenderStatus::Ok;
    }

    return RenderStatus::Unsupported;
}

RenderStatus computeTargetSize(const RenderParams& params,
                               uint32_t srcWidth,
                               uint32_t srcHeight,
                               uint32_t* outWidth,
                               uint32_t* outHeight) {
    if (!outWidth || !outHeight || srcWidth == 0 || srcHeight == 0) {
        return RenderStatus::InvalidArgument;
    }

    RenderSizeMode mode = params.sizeMode;
    uint32_t longEdge = params.longEdge;
    uint32_t shortEdge = params.shortEdge;

    if (params.intent == RenderIntent::Preview && params.previewLongEdge > 0) {
        mode = RenderSizeMode::FitLongEdge;
        longEdge = params.previewLongEdge;
    }

    // Exact rational round-half-up scaling: floor(src * num / den + 0.5), clamped to >= 1.
    // Avoids binary32 intermediate scale rounding (e.g. 127x93467 at short_edge=89 -> exact 65500, not 65501).
    auto scaleEdgeHalfUp = [](uint32_t src, uint32_t num, uint32_t den, uint32_t& out) -> bool {
        const uint64_t scaled =
            (static_cast<uint64_t>(src) * static_cast<uint64_t>(num) + static_cast<uint64_t>(den / 2u)) /
            static_cast<uint64_t>(den);
        if (scaled > static_cast<uint64_t>(UINT32_MAX)) {
            return false;
        }
        out = static_cast<uint32_t>(std::max<uint64_t>(1u, scaled));
        return true;
    };

    uint32_t width = 0;
    uint32_t height = 0;
    switch (mode) {
        case RenderSizeMode::Native:
            width = srcWidth;
            height = srcHeight;
            break;
        case RenderSizeMode::Exact:
            if (params.targetWidth == 0 || params.targetHeight == 0) {
                return RenderStatus::InvalidArgument;
            }
            width = params.targetWidth;
            height = params.targetHeight;
            break;
        case RenderSizeMode::FitLongEdge:
        case RenderSizeMode::LimitLongEdge: {
            if (longEdge == 0 || (mode == RenderSizeMode::FitLongEdge &&
                (exceedsOutputPixelCap(longEdge, 1) || (isJpegFileOutput(params) && longEdge > kMaxJpegDimension)))) {
                return RenderStatus::InvalidArgument;
            }
            const uint32_t maxEdge = std::max(srcWidth, srcHeight);
            if (mode == RenderSizeMode::LimitLongEdge && longEdge >= maxEdge) {
                width = srcWidth;
                height = srcHeight;
            } else if (!scaleEdgeHalfUp(srcWidth, longEdge, maxEdge, width) ||
                       !scaleEdgeHalfUp(srcHeight, longEdge, maxEdge, height)) {
                return RenderStatus::InvalidArgument;
            }
            break;
        }
        case RenderSizeMode::FitShortEdge: {
            if (shortEdge == 0 || exceedsOutputTargetCap(params, shortEdge, shortEdge)) {
                return RenderStatus::InvalidArgument;
            }
            const uint32_t minEdge = std::min(srcWidth, srcHeight);
            if (!scaleEdgeHalfUp(srcWidth, shortEdge, minEdge, width) ||
                !scaleEdgeHalfUp(srcHeight, shortEdge, minEdge, height)) {
                return RenderStatus::InvalidArgument;
            }
            break;
        }
        default:
            return RenderStatus::Unsupported;
    }

    // 所有 size mode 共用的收口上限与目标格式尺寸检查。
    if (exceedsOutputTargetCap(params, width, height)) {
        return RenderStatus::InvalidArgument;
    }

    *outWidth = width;
    *outHeight = height;
    return RenderStatus::Ok;
}

} // namespace sony2fuji
