#pragma once

#include <algorithm>
#include <cstdint>

namespace sony2fuji {

// Deterministic pixel-coordinate-hashed monochrome TPDF dithering in (-0.498, +0.498) LSB.
// Preserves exact 0 and 255 boundaries with zero noise and keeps 0..255 sRGB integers exact.
inline uint8_t quantizeFloatToUint8Dithered(float value, uint32_t x, uint32_t y) noexcept {
    if (!(value > 0.0f)) {
        return 0;
    }
    if (value >= 1.0f) {
        return 255;
    }
    uint32_t h = x * 0x9E3779B1u ^ y * 0x85EBCA77u;
    h ^= h >> 16;
    h *= 0x7FEB352Du;
    h ^= h >> 15;
    h *= 0x846CA68Bu;
    h ^= h >> 16;
    const float u1 = static_cast<float>(h & 0xFFFFu) / 65536.0f;
    const float u2 = static_cast<float>(h >> 16) / 65536.0f;
    const float dither = (u1 - u2) * 0.498f;
    const float scaled = value * 255.0f + dither + 0.5f;
    return static_cast<uint8_t>(std::clamp(static_cast<int>(scaled), 0, 255));
}

} // namespace sony2fuji
