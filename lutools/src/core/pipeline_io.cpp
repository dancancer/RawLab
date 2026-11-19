#include "core/pipeline.h"

#include "sony2fuji/sony2fuji.h"
#include "core/parallel_pixels.h"
#include "core/photo_pipeline_stages.h"

#include <atomic>
#include <cstdlib>
#include <memory>

namespace sony2fuji {

RenderStatus Pipeline::loadBufferImage(
    const RenderParams& params,
    ImageData& image,
    ColorSpace* space,
    bool* isLinear
) {
    if (!params.inputPixels || params.inputWidth == 0 || params.inputHeight == 0 ||
        exceedsOutputPixelCap(params.inputWidth, params.inputHeight)) {
        return RenderStatus::InvalidArgument;
    }

    const bool rgba16 = params.inputType == RenderInputType::DisplayBuffer &&
        params.inputPixelFormat == PixelBufferFormat::RGBA16;
    if (params.inputPixelFormat != PixelBufferFormat::RGB8 &&
        params.inputPixelFormat != PixelBufferFormat::RGBA8 && !rgba16) {
        return RenderStatus::Unsupported;
    }

    image.width = static_cast<int>(params.inputWidth);
    image.height = static_cast<int>(params.inputHeight);
    image.pixels.resize(static_cast<size_t>(params.inputWidth) * params.inputHeight);

    const uint8_t* data = static_cast<const uint8_t*>(params.inputPixels);
    const size_t pixelBytes = rgba16 ? 8 : params.inputPixelFormat == PixelBufferFormat::RGBA8 ? 4 : 3;
    const auto read16 = [](const uint8_t* p) { return (p[0] | (p[1] << 8)) / 65535.0f; };

    std::atomic<bool> unsupported{false};
    parallelPixelRanges(image.pixels.size(), [&](size_t first, size_t last) {
        if (unsupported.load(std::memory_order_acquire)) return;
        for (size_t i = first; i < last; ++i) {
            const auto* pixel = data + i * pixelBytes;
            if (rgba16) {
                if (pixel[6] != 255 || pixel[7] != 255) {
                    unsupported.store(true, std::memory_order_release);
                    return;
                }
                image.pixels[i] = {read16(pixel), read16(pixel + 2), read16(pixel + 4)};
            } else {
                if (params.inputType == RenderInputType::DisplayBuffer && pixelBytes == 4 && pixel[3] != 255) {
                    unsupported.store(true, std::memory_order_release);
                    return;
                }
                image.pixels[i] = {pixel[0] / 255.0f, pixel[1] / 255.0f, pixel[2] / 255.0f};
            }
        }
    });
    if (unsupported.load(std::memory_order_acquire)) {
        return RenderStatus::Unsupported;
    }

    if (space) {
        *space = params.inputColorSpace;
    }
    if (isLinear) {
        *isLinear = params.inputIsLinear;
    }

    return RenderStatus::Ok;
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
    if ((params.intent != RenderIntent::Preview || params.outputTarget != RenderOutputTarget::Buffer) &&
        rawCache_.pixels.size() * sizeof(RGB) > WaveletRenderCache::defaultPreviewBudget) {
        rawCache_ = {};
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
