#pragma once
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <spng.h>

namespace rawlab {
struct Png16Deleter {
    void operator()(uint16_t* pixels) const { std::free(pixels); }
};
using Png16Pixels = std::unique_ptr<uint16_t, Png16Deleter>;

inline Png16Pixels decodePng16(const char* path, int width, int height, int orientation) {
    if (!path || width <= 0 || height <= 0 || uint64_t(width) * height > 128000000 ||
        orientation < 1 || orientation > 8)
        throw std::invalid_argument("Invalid PNG dimensions or orientation");
    if (uint64_t(width) * height > 32000000)
        throw std::invalid_argument("16-bit PNG exceeds the 32 MP decode limit");
    const auto check = [](int error) {
        if (error == SPNG_EMEM) throw std::bad_alloc();
        if (error) throw std::runtime_error("Unable to decode 16-bit PNG");
    };
    std::unique_ptr<FILE, decltype(&std::fclose)> file(std::fopen(path, "rb"), std::fclose);
    if (!file) throw std::runtime_error("Unable to open 16-bit PNG");
    std::unique_ptr<spng_ctx, decltype(&spng_ctx_free)> decoder(spng_ctx_new(0), spng_ctx_free);
    if (!decoder) throw std::bad_alloc();
    check(spng_set_png_file(decoder.get(), file.get()));
    spng_ihdr header{};
    check(spng_get_ihdr(decoder.get(), &header));
    if (header.width != uint32_t(width) || header.height != uint32_t(height) ||
        header.bit_depth != 16 ||
        (header.color_type != SPNG_COLOR_TYPE_TRUECOLOR &&
         header.color_type != SPNG_COLOR_TYPE_TRUECOLOR_ALPHA))
        throw std::runtime_error("PNG must be opaque 16-bit RGB");
    const size_t count = size_t(width) * height;
    Png16Pixels pixels(static_cast<uint16_t*>(std::malloc(count * 8)));
    if (!pixels) throw std::bad_alloc();
    // RGBA16 is native-endian, with no gamma or ICC conversion here. Preserve
    // tRNS as alpha too, so transparent RGB cannot silently become opaque.
    check(spng_decode_image(decoder.get(), pixels.get(), count * 8,
                            SPNG_FMT_RGBA16, SPNG_DECODE_TRNS));
    for (size_t i = 0; i < count; ++i) {
        if (pixels.get()[i * 4 + 3] != 65535)
            throw std::runtime_error("Transparent PNG is not supported");
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
        // Apply orientation without changing decoded channel values.
        auto* destination = oriented.get() + (size_t(dy) * outputWidth + dx) * 4;
        std::memcpy(destination, pixels.get() + (size_t(y) * width + x) * 4, 8);
    }
    return oriented;
}
}
