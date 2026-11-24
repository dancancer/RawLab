#include "ffi/session_internal.h"

#include "core/bsh_diagnostics.h"
#include "gpu/image_stats.h"
#include "platform/display_image.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <new>
#include <vector>

sony2fuji_status sony2fuji_validate_look(
    const char* path,
    sony2fuji_look_format* format,
    uint32_t* format_version
) {
    sony2fuji::LookFormat coreFormat = sony2fuji::LookFormat::Unknown;
    const auto status = sony2fuji::Pipeline::validateLook(path, &coreFormat, format_version);
    if (format) *format = static_cast<sony2fuji_look_format>(coreFormat);
    return toFfiStatus(status);
}

sony2fuji_lut_color_state sony2fuji_inspect_lut_color(const char* path) {
    return static_cast<sony2fuji_lut_color_state>(sony2fuji::Pipeline::inspectLutColor(path));
}

sony2fuji_status sony2fuji_load_display_image(const char* path, sony2fuji_buffer* out_buffer) {
    if (!out_buffer) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    *out_buffer = {};
    try {
        sony2fuji::OwnedPixelBuffer owned;
        const auto status = sony2fuji::loadDisplayImage(path, owned);
        if (status != sony2fuji::RenderStatus::Ok) return toFfiStatus(status);
        *out_buffer = toFfiBuffer(owned);
        return SONY2FUJI_STATUS_OK;
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

#ifdef _WIN32
extern "C" sony2fuji_status rawlab_display_preview(
    const char* path,
    uint32_t edge,
    sony2fuji_buffer* out_buffer,
    uint32_t* oriented_source_width,
    uint32_t* oriented_source_height
) {
    if (oriented_source_width) *oriented_source_width = 0;
    if (oriented_source_height) *oriented_source_height = 0;
    if (!out_buffer) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    *out_buffer = {};
    try {
        sony2fuji::OwnedPixelBuffer owned;
        const auto status = sony2fuji::loadDisplayPreview(
            path, edge, owned, oriented_source_width, oriented_source_height);
        if (status != sony2fuji::RenderStatus::Ok) return toFfiStatus(status);
        *out_buffer = toFfiBuffer(owned);
        return SONY2FUJI_STATUS_OK;
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}
#endif

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
        buffer->pixel_format != SONY2FUJI_PIXEL_RGBA8 &&
        buffer->pixel_format != SONY2FUJI_PIXEL_BGRA8) {
        return SONY2FUJI_STATUS_UNSUPPORTED;
    }
    const bool bgra = buffer->pixel_format == SONY2FUJI_PIXEL_BGRA8;
    const uint32_t channels = (buffer->pixel_format == SONY2FUJI_PIXEL_RGBA8 || bgra) ? 4u : 3u;
    const uint64_t rowBytes = static_cast<uint64_t>(buffer->width) * channels;
    if (rowBytes > static_cast<uint64_t>(buffer->stride_bytes) ||
        static_cast<uint64_t>(buffer->stride_bytes) * (buffer->height - 1u) + rowBytes > buffer->size_bytes) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }

    try {
        const uint8_t* data = static_cast<const uint8_t*>(buffer->data);
        std::vector<uint32_t> counts(bins, 0);

        for (uint32_t y = 0; y < buffer->height; ++y) {
            const uint8_t* row = data + static_cast<size_t>(y) * buffer->stride_bytes;
            for (uint32_t x = 0; x < buffer->width; ++x) {
                size_t offset = static_cast<size_t>(x) * channels;
                float r = row[offset + (bgra ? 2 : 0)] / 255.0f;
                float g = row[offset + 1] / 255.0f;
                float b = row[offset + (bgra ? 0 : 2)] / 255.0f;
                float l = 0.2126f * r + 0.7152f * g + 0.0722f * b;
                uint32_t bin = static_cast<uint32_t>(l * static_cast<float>(bins - 1));
                if (bin >= bins) bin = bins - 1;
                counts[bin] += 1;
            }
        }

        float maxValue = 0.0f;
        for (uint32_t i = 0; i < bins; ++i) {
            float value = static_cast<float>(counts[i]);
            out_bins[i] = value;
            if (value > maxValue) maxValue = value;
        }
        if (maxValue > 0.0f) {
            for (uint32_t i = 0; i < bins; ++i) out_bins[i] /= maxValue;
        }
        return SONY2FUJI_STATUS_OK;
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

sony2fuji_status sony2fuji_analyze_image(
    const sony2fuji_buffer* image,
    sony2fuji_gpu_mode mode,
    uint32_t* rgb_bins,
    uint32_t* shadows,
    uint32_t* highlights,
    sony2fuji_buffer* clipping_mask
) {
    if (!image || !image->data || !rgb_bins || !shadows || !highlights ||
        mode < SONY2FUJI_GPU_OFF || mode > SONY2FUJI_GPU_FORCE || image->width == 0 || image->height == 0 ||
        image->width > UINT32_MAX / 4 || static_cast<uint64_t>(image->width) * image->height > UINT32_MAX) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    const size_t channels =
        (image->pixel_format == SONY2FUJI_PIXEL_RGBA8 || image->pixel_format == SONY2FUJI_PIXEL_BGRA8)
            ? 4
            : (image->pixel_format == SONY2FUJI_PIXEL_RGB8 ? 3 : 0);
    if (!channels || static_cast<size_t>(image->width) * channels > image->stride_bytes ||
        static_cast<uint64_t>(image->stride_bytes) * (image->height - 1) +
            static_cast<uint64_t>(image->width) * channels > image->size_bytes) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    try {
        const sony2fuji::PixelBufferView view{
            image->data,
            image->size_bytes,
            image->width,
            image->height,
            image->stride_bytes,
            static_cast<sony2fuji::PixelBufferFormat>(image->pixel_format)
        };
        sony2fuji::ImageStats stats;
#if defined(SONY2FUJI_ENABLE_METAL)
        // These pixels already live on the CPU. Upload/readback costs more than
        // the optimized counting loop on measured Apple Silicon workloads.
        const bool complete = mode == SONY2FUJI_GPU_FORCE && sony2fuji::computeImageStatsMetal(view, stats);
        if (!complete) {
            if (mode == SONY2FUJI_GPU_FORCE) return SONY2FUJI_STATUS_PROCESSING_ERROR;
            if (!sony2fuji::computeImageStatsCPU(view, stats, clipping_mask != nullptr)) {
                return SONY2FUJI_STATUS_INVALID_ARGUMENT;
            }
        }
#else
        if (mode == SONY2FUJI_GPU_FORCE) return SONY2FUJI_STATUS_UNSUPPORTED;
        if (!sony2fuji::computeImageStatsCPU(view, stats, clipping_mask != nullptr)) {
            return SONY2FUJI_STATUS_INVALID_ARGUMENT;
        }
#endif
        if (clipping_mask) {
            void* data = std::malloc(stats.clipping.size());
            if (!data) return SONY2FUJI_STATUS_OUT_OF_MEMORY;
            std::memcpy(data, stats.clipping.data(), stats.clipping.size());
            *clipping_mask = {data, stats.clipping.size(), image->width, image->height,
                image->width * 4, SONY2FUJI_PIXEL_RGBA8};
        }
        std::copy(stats.histogram.begin(), stats.histogram.end(), rgb_bins);
        *shadows = stats.shadows;
        *highlights = stats.highlights;
        return SONY2FUJI_STATUS_OK;
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

namespace {

bool validBshImageBuffer(const sony2fuji_buffer* image, uint32_t& outChannels, uint32_t& outBitDepth) {
    if (!image || !image->data || image->width == 0 || image->height == 0 ||
        image->width > UINT32_MAX / 8 ||
        static_cast<uint64_t>(image->width) * image->height > UINT32_MAX) {
        return false;
    }
    size_t bytesPerPixel = 0;
    switch (image->pixel_format) {
        case SONY2FUJI_PIXEL_RGB8:
            outChannels = 3;
            outBitDepth = 8;
            bytesPerPixel = 3;
            break;
        case SONY2FUJI_PIXEL_RGBA8:
            outChannels = 4;
            outBitDepth = 8;
            bytesPerPixel = 4;
            break;
        case SONY2FUJI_PIXEL_RGBA16:
            outChannels = 4;
            outBitDepth = 16;
            bytesPerPixel = 8;
            break;
        default:
            return false;
    }
    const uint64_t rowBytes = static_cast<uint64_t>(image->width) * bytesPerPixel;
    if (rowBytes > static_cast<uint64_t>(image->stride_bytes)) return false;
    const uint64_t requiredBytes = static_cast<uint64_t>(image->stride_bytes) * (image->height - 1u) + rowBytes;
    return requiredBytes <= image->size_bytes;
}

} // namespace

sony2fuji_status sony2fuji_diagnose_image(
    const sony2fuji_buffer* image,
    const sony2fuji_bsh_diagnose_options* options,
    sony2fuji_bsh_diagnosis* out_diagnosis
) {
    uint32_t channels = 0;
    uint32_t bitDepth = 0;
    if (!validBshImageBuffer(image, channels, bitDepth) || !out_diagnosis ||
        out_diagnosis->version != SONY2FUJI_BSH_DIAGNOSIS_VERSION ||
        out_diagnosis->struct_size < sizeof(*out_diagnosis)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    if (options && (options->version != SONY2FUJI_BSH_DIAGNOSIS_VERSION ||
        options->struct_size != sizeof(*options) || options->reserved != 0)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    try {
        const sony2fuji::PixelBufferView view{
            image->data,
            image->size_bytes,
            image->width,
            image->height,
            image->stride_bytes,
            static_cast<sony2fuji::PixelBufferFormat>(image->pixel_format)
        };
        const uint32_t stride = options ? options->sample_stride : 0u;
        return toFfiStatus(sony2fuji::diagnosePixelBuffer(view, stride, *out_diagnosis));
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

sony2fuji_status sony2fuji_sample_region_bsh(
    const sony2fuji_buffer* image,
    const sony2fuji_bsh_sample_query* query,
    sony2fuji_bsh_sample_result* out_result
) {
    uint32_t channels = 0;
    uint32_t bitDepth = 0;
    if (!validBshImageBuffer(image, channels, bitDepth) || !query || !out_result ||
        query->version != SONY2FUJI_BSH_SAMPLE_VERSION ||
        query->struct_size != sizeof(*query) ||
        query->reserved != 0 ||
        !std::isfinite(query->norm_x) || query->norm_x < 0.0f || query->norm_x > 1.0f ||
        !std::isfinite(query->norm_y) || query->norm_y < 0.0f || query->norm_y > 1.0f ||
        !std::isfinite(query->radius_norm) || query->radius_norm < 0.0f ||
        out_result->version != SONY2FUJI_BSH_SAMPLE_VERSION ||
        out_result->struct_size < sizeof(*out_result)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    try {
        const sony2fuji::PixelBufferView view{
            image->data,
            image->size_bytes,
            image->width,
            image->height,
            image->stride_bytes,
            static_cast<sony2fuji::PixelBufferFormat>(image->pixel_format)
        };
        return toFfiStatus(sony2fuji::sampleRegionBshBuffer(
            view, query->norm_x, query->norm_y, query->radius_norm, *out_result));
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

void sony2fuji_release_buffer(sony2fuji_buffer* buffer) {
    if (!buffer || !buffer->data) return;
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
        case SONY2FUJI_STATUS_OK: return "ok";
        case SONY2FUJI_STATUS_INVALID_ARGUMENT: return "invalid argument";
        case SONY2FUJI_STATUS_UNSUPPORTED: return "unsupported";
        case SONY2FUJI_STATUS_IO_ERROR: return "io error";
        case SONY2FUJI_STATUS_OUTPUT_IO_ERROR: return "output io error";
        case SONY2FUJI_STATUS_PROCESSING_ERROR: return "processing error";
        case SONY2FUJI_STATUS_OUT_OF_MEMORY: return "out of memory";
        case SONY2FUJI_STATUS_CANCELLED: return "cancelled";
        case SONY2FUJI_STATUS_AI_NOT_READY: return "AI denoising result is not ready";
        default: return "unknown";
    }
}
