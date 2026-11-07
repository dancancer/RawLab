#pragma once
#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <stdexcept>

#define STB_IMAGE_IMPLEMENTATION
#define STBIDEF static inline
#define STBI_ONLY_PNG
#define STBI_NO_LINEAR
#define STBI_NO_HDR
#include "../../../../../lutools/src/core/stb_image.h"

namespace rawlab {
struct Png16Deleter {
    void operator()(uint16_t* pixels) const { stbi_image_free(pixels); }
};
using Png16Pixels = std::unique_ptr<uint16_t, Png16Deleter>;

inline Png16Pixels decodePng16(const char* path, int width, int height, int orientation) {
    if (!path || width <= 0 || height <= 0 || uint64_t(width) * height > 128000000 ||
        orientation < 1 || orientation > 8)
        throw std::invalid_argument("Invalid PNG dimensions or orientation");
    int actualWidth = 0, actualHeight = 0, channels = 0;
    if (!stbi_info(path, &actualWidth, &actualHeight, &channels) || !stbi_is_16_bit(path) ||
        actualWidth != width || actualHeight != height || (channels != 3 && channels != 4))
        throw std::runtime_error("PNG must be opaque 16-bit RGB");
    Png16Pixels pixels(stbi_load_16(path, &actualWidth, &actualHeight, &channels, 4));
    if (!pixels) {
        if (stbi_failure_reason() && std::strstr(stbi_failure_reason(), "outofmem")) throw std::bad_alloc();
        throw std::runtime_error("Unable to decode 16-bit PNG");
    }
    if (actualWidth != width || actualHeight != height)
        throw std::runtime_error("Image dimensions changed during decode");
    const size_t count = size_t(width) * height;
    for (size_t i = 0; i < count; ++i) {
        if (pixels.get()[i * 4 + 3] != 65535) throw std::runtime_error("Transparent PNG is not supported");
    }
    if (orientation == 1) return pixels;
    Png16Pixels oriented(static_cast<uint16_t*>(std::malloc(count * 8)));
    if (!oriented) throw std::bad_alloc();
    const int outputWidth = orientation >= 5 ? height : width;
    for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
        int dx = x, dy = y;
        switch (orientation) {
            case 2: dx = width - 1 - x; break;
            case 3: dx = width - 1 - x; dy = height - 1 - y; break;
            case 4: dy = height - 1 - y; break;
            case 5: dx = y; dy = x; break;
            case 6: dx = height - 1 - y; dy = x; break;
            case 7: dx = height - 1 - y; dy = width - 1 - x; break;
            case 8: dx = y; dy = width - 1 - x; break;
        }
        // 整个 RGBA16 像素移动，方向变换不经过 8 位或半精度浮点中间图。
        std::memcpy(oriented.get() + (size_t(dy) * outputWidth + dx) * 4,
            pixels.get() + (size_t(y) * width + x) * 4, 8);
    }
    return oriented;
}
}
