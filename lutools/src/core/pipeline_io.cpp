#include "core/pipeline.h"

#include "sony2fuji/sony2fuji.h"
#include "core/parallel_pixels.h"
#include "core/photo_pipeline_stages.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <memory>

namespace sony2fuji {

namespace {

RenderStatus validateBufferInputParams(const RenderParams& params, size_t& outPixelBytes, bool& outRgba16) {
    if (!params.inputPixels || params.inputWidth == 0 || params.inputHeight == 0 ||
        exceedsOutputPixelCap(params.inputWidth, params.inputHeight)) {
        return RenderStatus::InvalidArgument;
    }
    outRgba16 = params.inputType == RenderInputType::DisplayBuffer &&
        params.inputPixelFormat == PixelBufferFormat::RGBA16;
    if (params.inputPixelFormat != PixelBufferFormat::RGB8 &&
        params.inputPixelFormat != PixelBufferFormat::RGBA8 && !outRgba16) {
        return RenderStatus::Unsupported;
    }
    outPixelBytes = outRgba16 ? 8 : (params.inputPixelFormat == PixelBufferFormat::RGBA8 ? 4 : 3);
    return RenderStatus::Ok;
}

inline bool decodeBufferPixel(const uint8_t* pixel, bool rgba16, size_t pixelBytes, bool displayBuffer, RGB& out) {
    auto read16 = [](const uint8_t* p) { return (p[0] | (p[1] << 8)) / 65535.0f; };
    if (rgba16) {
        if (pixel[6] != 255 || pixel[7] != 255) return false;
        out = {read16(pixel), read16(pixel + 2), read16(pixel + 4)};
        return true;
    }
    if (displayBuffer && pixelBytes == 4 && pixel[3] != 255) return false;
    out = {pixel[0] / 255.0f, pixel[1] / 255.0f, pixel[2] / 255.0f};
    return true;
}

} // namespace

RenderStatus Pipeline::loadBufferImage(
    const RenderParams& params,
    ImageData& image,
    ColorSpace* space,
    bool* isLinear
) {
    size_t pixelBytes = 0;
    bool rgba16 = false;
    const auto valid = validateBufferInputParams(params, pixelBytes, rgba16);
    if (valid != RenderStatus::Ok) return valid;

    image.width = static_cast<int>(params.inputWidth);
    image.height = static_cast<int>(params.inputHeight);
    image.pixels.resize(static_cast<size_t>(params.inputWidth) * params.inputHeight);

    const uint8_t* data = static_cast<const uint8_t*>(params.inputPixels);
    const bool displayBuffer = params.inputType == RenderInputType::DisplayBuffer;

    std::atomic<bool> unsupported{false};
    parallelPixelRanges(image.pixels.size(), [&](size_t first, size_t last) {
        if (unsupported.load(std::memory_order_acquire)) return;
        for (size_t i = first; i < last; ++i) {
            if (!decodeBufferPixel(data + i * pixelBytes, rgba16, pixelBytes, displayBuffer, image.pixels[i])) {
                unsupported.store(true, std::memory_order_release);
                return;
            }
        }
    });
    if (unsupported.load(std::memory_order_acquire)) {
        return RenderStatus::Unsupported;
    }

    if (space) *space = params.inputColorSpace;
    if (isLinear) *isLinear = params.inputIsLinear;
    return RenderStatus::Ok;
}

RenderStatus Pipeline::loadBufferImageROI(
    const RenderParams& params,
    const RoiSubRect& rect,
    ImageData& image,
    ColorSpace* space,
    bool* isLinear
) {
    size_t pixelBytes = 0;
    bool rgba16 = false;
    const auto valid = validateBufferInputParams(params, pixelBytes, rgba16);
    if (valid != RenderStatus::Ok) return valid;
    if (rect.empty() || rect.x0 < 0 || rect.y0 < 0 ||
        rect.x1 > static_cast<int>(params.inputWidth) || rect.y1 > static_cast<int>(params.inputHeight)) {
        return RenderStatus::InvalidArgument;
    }

    const int rw = rect.width();
    const int rh = rect.height();
    image.width = rw;
    image.height = rh;
    image.pixels.resize(static_cast<size_t>(rw) * rh);

    const uint8_t* data = static_cast<const uint8_t*>(params.inputPixels);
    const bool displayBuffer = params.inputType == RenderInputType::DisplayBuffer;
    const size_t fullWidth = static_cast<size_t>(params.inputWidth);

    std::atomic<bool> unsupported{false};
    parallelRowRanges(rh, rw, [&](int firstRow, int lastRow) {
        if (unsupported.load(std::memory_order_acquire)) return;
        for (int y = firstRow; y < lastRow; ++y) {
            const size_t srcRow = (static_cast<size_t>(rect.y0 + y) * fullWidth + static_cast<size_t>(rect.x0)) * pixelBytes;
            RGB* dst = image.pixels.data() + static_cast<size_t>(y) * rw;
            for (int x = 0; x < rw; ++x) {
                if (!decodeBufferPixel(data + srcRow + static_cast<size_t>(x) * pixelBytes,
                        rgba16, pixelBytes, displayBuffer, dst[x])) {
                    unsupported.store(true, std::memory_order_release);
                    return;
                }
            }
        }
    });
    if (unsupported.load(std::memory_order_acquire)) {
        return RenderStatus::Unsupported;
    }

    if (space) *space = params.inputColorSpace;
    if (isLinear) *isLinear = params.inputIsLinear;
    return RenderStatus::Ok;
}

RenderStatus Pipeline::loadBufferImageDownsampled(
    const RenderParams& params,
    uint32_t maxLongEdge,
    ImageData& image,
    ColorSpace* space,
    bool* isLinear
) {
    size_t pixelBytes = 0;
    bool rgba16 = false;
    const auto valid = validateBufferInputParams(params, pixelBytes, rgba16);
    if (valid != RenderStatus::Ok) return valid;

    const uint32_t srcW = params.inputWidth;
    const uint32_t srcH = params.inputHeight;
    const uint32_t longest = std::max(srcW, srcH);
    if (maxLongEdge == 0 || longest <= maxLongEdge) {
        return loadBufferImage(params, image, space, isLinear);
    }

    const double scale = double(maxLongEdge) / double(longest);
    const int dstW = std::max(1, int(std::lround(srcW * scale)));
    const int dstH = std::max(1, int(std::lround(srcH * scale)));
    image.width = dstW;
    image.height = dstH;
    image.pixels.resize(static_cast<size_t>(dstW) * dstH);

    const uint8_t* data = static_cast<const uint8_t*>(params.inputPixels);
    const bool displayBuffer = params.inputType == RenderInputType::DisplayBuffer;

    std::atomic<bool> unsupported{false};
    parallelRowRanges(dstH, dstW, [&](int firstRow, int lastRow) {
        if (unsupported.load(std::memory_order_acquire)) return;
        for (int y = firstRow; y < lastRow; ++y) {
            const double sy = std::clamp((double(y) + 0.5) * double(srcH) / dstH - 0.5, 0.0, double(srcH - 1));
            const int y0 = int(std::floor(sy));
            const int y1 = std::min(int(srcH) - 1, y0 + 1);
            const float wy = float(sy - y0);
            for (int x = 0; x < dstW; ++x) {
                const double sx = std::clamp((double(x) + 0.5) * double(srcW) / dstW - 0.5, 0.0, double(srcW - 1));
                const int x0 = int(std::floor(sx));
                const int x1 = std::min(int(srcW) - 1, x0 + 1);
                const float wx = float(sx - x0);
                RGB p00, p10, p01, p11;
                if (!decodeBufferPixel(data + (size_t(y0) * srcW + size_t(x0)) * pixelBytes, rgba16, pixelBytes, displayBuffer, p00) ||
                    !decodeBufferPixel(data + (size_t(y0) * srcW + size_t(x1)) * pixelBytes, rgba16, pixelBytes, displayBuffer, p10) ||
                    !decodeBufferPixel(data + (size_t(y1) * srcW + size_t(x0)) * pixelBytes, rgba16, pixelBytes, displayBuffer, p01) ||
                    !decodeBufferPixel(data + (size_t(y1) * srcW + size_t(x1)) * pixelBytes, rgba16, pixelBytes, displayBuffer, p11)) {
                    unsupported.store(true, std::memory_order_release);
                    return;
                }
                auto lerp = [](float a, float b, float t) { return a + (b - a) * t; };
                const RGB top{lerp(p00.r, p10.r, wx), lerp(p00.g, p10.g, wx), lerp(p00.b, p10.b, wx)};
                const RGB bot{lerp(p01.r, p11.r, wx), lerp(p01.g, p11.g, wx), lerp(p01.b, p11.b, wx)};
                image.at(x, y) = {lerp(top.r, bot.r, wy), lerp(top.g, bot.g, wy), lerp(top.b, bot.b, wy)};
            }
        }
    });
    if (unsupported.load(std::memory_order_acquire)) {
        return RenderStatus::Unsupported;
    }

    if (space) *space = params.inputColorSpace;
    if (isLinear) *isLinear = params.inputIsLinear;
    return RenderStatus::Ok;
}

ImageData Pipeline::extractImageSubRect(const ImageData& source, const RoiSubRect& rect) {
    if (source.width <= 0 || source.height <= 0 || rect.empty() ||
        rect.x0 < 0 || rect.y0 < 0 || rect.x1 > source.width || rect.y1 > source.height) {
        return {};
    }
    const int rw = rect.width();
    const int rh = rect.height();
    ImageData out(rw, rh);
    parallelRowRanges(rh, rw, [&](int firstRow, int lastRow) {
        for (int y = firstRow; y < lastRow; ++y) {
            const RGB* src = source.pixels.data() + static_cast<size_t>(rect.y0 + y) * source.width + rect.x0;
            RGB* dst = out.pixels.data() + static_cast<size_t>(y) * rw;
            std::copy_n(src, rw, dst);
        }
    });
    return out;
}

RenderStatus Pipeline::writeOutputFile(const RenderParams& params, const ImageData& image) {
    if (params.outputPath.empty()) {
        return RenderStatus::InvalidArgument;
    }

    OutputFormat format = OutputFormat::JPEG;
    if (params.outputFormat == RenderOutputFormat::PNG) {
        format = OutputFormat::PNG;
    } else if (params.outputFormat == RenderOutputFormat::DNG) {
        format = OutputFormat::DNG;
    }

    int quality = static_cast<int>(params.jpegQuality);
    if (quality <= 0 || quality > 100) {
        quality = 95;
    }

    ErrorCode result = ImageEncoder::saveImage(image, params.outputPath, format, quality);
    return mapErrorCode(result);
}

RenderStatus Pipeline::writeOutputBuffer(
    const RenderParams& params,
    const ImageData& image,
    OwnedPixelBuffer* outBuffer
) {
    if (!outBuffer) {
        return RenderStatus::InvalidArgument;
    }

    uint32_t channels = params.outputFormat == RenderOutputFormat::RGBA8 ? 4 : 3;
    size_t stride = static_cast<size_t>(image.width) * channels;
    size_t total = stride * static_cast<size_t>(image.height);

    std::unique_ptr<void, decltype(&std::free)> buffer(std::malloc(total), std::free);
    if (!buffer) {
        return RenderStatus::OutOfMemory;
    }

    uint8_t* dst = static_cast<uint8_t*>(buffer.get());
    parallelRowRanges(image.height, image.width, [&](int firstRow, int lastRow) {
        for (int y = firstRow; y < lastRow; ++y) {
            for (int x = 0; x < image.width; ++x) {
                const RGB& pixel = image.at(x, y);
                size_t offset = static_cast<size_t>(y) * stride + static_cast<size_t>(x) * channels;
                dst[offset] = static_cast<uint8_t>(clampFloat(pixel.r, 0.0f, 1.0f) * 255.0f + 0.5f);
                dst[offset + 1] = static_cast<uint8_t>(clampFloat(pixel.g, 0.0f, 1.0f) * 255.0f + 0.5f);
                dst[offset + 2] = static_cast<uint8_t>(clampFloat(pixel.b, 0.0f, 1.0f) * 255.0f + 0.5f);
                if (channels == 4) {
                    dst[offset + 3] = 255;
                }
            }
        }
    });

    outBuffer->data = buffer.release();
    outBuffer->sizeBytes = total;
    outBuffer->width = static_cast<uint32_t>(image.width);
    outBuffer->height = static_cast<uint32_t>(image.height);
    outBuffer->strideBytes = static_cast<uint32_t>(stride);
    outBuffer->format = (channels == 4) ? PixelBufferFormat::RGBA8 : PixelBufferFormat::RGB8;

    return RenderStatus::Ok;
}

RenderStatus Pipeline::finishOutput(
    const RenderParams& params,
    ImageData& image,
    OwnedPixelBuffer* outBuffer,
    uint32_t nativeWidth,
    uint32_t nativeHeight,
    MigrationFrame* migrationFrame
) {
    // 预览保留唯一 RAW 缓存供连续调整复用；导出前由 Swift 释放预览 session。
    if (params.intent != RenderIntent::Preview || params.outputTarget != RenderOutputTarget::Buffer) {
        roiGuideCache_ = {};
        if (rawCache_.pixels.size() * sizeof(RGB) > WaveletRenderCache::defaultPreviewBudget) {
            rawCache_ = {};
            rawProcessor_.reset();
            processorKey_.clear();
            rawCacheWbValid_ = false;
            rawCacheAnchoredPreview_ = false;
        }
    }
    const auto status = finishGeometry(params, image, nativeWidth, nativeHeight);
    if (status != RenderStatus::Ok) return status;
    if (geometry_.active()) lastBackend_ = RenderBackend::Cpu;
    if (migrationFrame) {
        *migrationFrame = captureMigrationFrame(image, migrationFrame->retainNativePixels, migrationFrame->validationReference);
        return RenderStatus::Ok;
    }
    const auto written = params.outputTarget == RenderOutputTarget::File
        ? writeOutputFile(params, image)
        : writeOutputBuffer(params, image, outBuffer);
    if (written == RenderStatus::Ok) {
        geometryWidth_ = nativeWidth;
        geometryHeight_ = nativeHeight;
    }
    return written;
}

} // namespace sony2fuji
