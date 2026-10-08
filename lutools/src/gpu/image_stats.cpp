#include "gpu/image_stats.h"

#include <cstddef>
#include <limits>
#include <utility>

namespace {

struct ImageLayout {
    const uint8_t* data = nullptr;
    size_t requiredBytes = 0;
    size_t pixelCount = 0;
    size_t maskBytes = 0;
    uint32_t channels = 0;
};

bool checkedMultiply(size_t left, size_t right, size_t& result) {
    if (left != 0 && right > std::numeric_limits<size_t>::max() / left) {
        return false;
    }
    result = left * right;
    return true;
}

bool checkedAdd(size_t left, size_t right, size_t& result) {
    if (right > std::numeric_limits<size_t>::max() - left) {
        return false;
    }
    result = left + right;
    return true;
}

bool validateBuffer(const sony2fuji_buffer& buffer, ImageLayout& layout) {
    if (!buffer.data || buffer.width == 0 || buffer.height == 0) {
        return false;
    }

    if (buffer.pixel_format == SONY2FUJI_PIXEL_RGB8) {
        layout.channels = 3;
    } else if (buffer.pixel_format == SONY2FUJI_PIXEL_RGBA8) {
        layout.channels = 4;
    } else {
        return false;
    }

    size_t widthBytes = 0;
    if (!checkedMultiply(static_cast<size_t>(buffer.width), layout.channels, widthBytes) ||
        buffer.stride_bytes < widthBytes) {
        return false;
    }

    size_t lastRowOffset = 0;
    if (!checkedMultiply(static_cast<size_t>(buffer.height - 1),
                         static_cast<size_t>(buffer.stride_bytes), lastRowOffset) ||
        !checkedAdd(lastRowOffset, widthBytes, layout.requiredBytes) ||
        layout.requiredBytes > buffer.size_bytes) {
        return false;
    }

    if (!checkedMultiply(static_cast<size_t>(buffer.width),
                         static_cast<size_t>(buffer.height), layout.pixelCount) ||
        layout.pixelCount > std::numeric_limits<uint32_t>::max() ||
        !checkedMultiply(layout.pixelCount, 4, layout.maskBytes)) {
        return false;
    }

    layout.data = static_cast<const uint8_t*>(buffer.data);
    return true;
}

} // namespace

namespace sony2fuji {

bool computeImageStatsCPU(const sony2fuji_buffer& buffer, ImageStats& output, bool includeClipping) {
    ImageLayout layout;
    if (!validateBuffer(buffer, layout)) {
        return false;
    }

    try {
        ImageStats result;
        if (includeClipping) result.clipping.assign(layout.maskBytes, 0);

        for (uint32_t y = 0; y < buffer.height; ++y) {
            const uint8_t* row = layout.data +
                static_cast<size_t>(y) * static_cast<size_t>(buffer.stride_bytes);
            for (uint32_t x = 0; x < buffer.width; ++x) {
                const size_t pixelOffset = static_cast<size_t>(x) * layout.channels;
                const uint8_t r = row[pixelOffset];
                const uint8_t g = row[pixelOffset + 1];
                const uint8_t b = row[pixelOffset + 2];
                ++result.histogram[r];
                ++result.histogram[256 + g];
                ++result.histogram[512 + b];

                const size_t maskOffset =
                    (static_cast<size_t>(y) * buffer.width + x) * 4;
                uint8_t* mask = includeClipping ? result.clipping.data() + maskOffset : nullptr;
                if (r == 255 || g == 255 || b == 255) {
                    ++result.highlights;
                    if (mask) { mask[0] = 255; mask[3] = 160; }
                } else if (r == 0 && g == 0 && b == 0) {
                    ++result.shadows;
                    if (mask) { mask[1] = 130; mask[2] = 255; mask[3] = 160; }
                }
            }
        }

        output = std::move(result);
        return true;
    } catch (...) {
        return false;
    }
}

#if !defined(SONY2FUJI_ENABLE_METAL)
bool computeImageStatsMetal(const sony2fuji_buffer&, ImageStats&) {
    return false;
}
#endif

} // namespace sony2fuji
